import 'package:http/http.dart' as http;
import 'package:serverpod_auth_server/serverpod_auth_server.dart';
import 'package:test/test.dart';

import 'apple_test_utils.dart';

/// Tests that a Sign in with Apple identity token is only accepted when Apple
/// minted it for *this* application, and while it is still current.
///
/// Apple signs the identity tokens of every developer team with the same set
/// of keys, published at a single global JWKS endpoint. A valid signature
/// therefore proves only that the token came from Apple - it says nothing
/// about which app the token was issued to. The `aud` claim is what carries
/// that, so without checking it any Apple developer can mint a token in their
/// own app and replay it here.
///
/// The invariant: a token verifies only if Apple issued it, for a configured
/// client id, and it has not expired.
void main() {
  setUp(() {
    AppleAuth.resetPublicKeyCache();
    AuthConfig.set(AuthConfig(appleClientIds: {appleClientId}));
  });

  tearDown(() {
    AppleAuth.resetPublicKeyCache();
    AuthConfig.set(AuthConfig());
  });

  group(
    'Given an identity token signed by Apple for another application, ',
    () {
      test(
        'when verifying it, then it is rejected for its audience.',
        () async {
          var token = signAppleIdentityToken(
            subject: '000123.abc.0001',
            audience: 'com.attacker.their-own-app',
          );

          await expectLater(
            _verify(token),
            throwsA(
              isA<AppleIdentityTokenException>().having(
                (e) => e.message,
                'message',
                contains('audience'),
              ),
            ),
            reason:
                'The signature verifies against Apple\'s global JWKS, so the '
                'audience is the only thing separating this token from one '
                'minted for this app.',
          );
        },
      );
    },
  );

  group('Given an identity token from an issuer other than Apple, ', () {
    test('when verifying it, then it is rejected.', () async {
      var token = signAppleIdentityToken(
        subject: '000123.abc.0001',
        issuer: 'https://login.attacker.example',
      );

      await expectLater(
        _verify(token),
        throwsA(isA<AppleIdentityTokenException>()),
      );
    });
  });

  group('Given an expired identity token, ', () {
    test('when verifying it, then it is rejected.', () async {
      var longAgo = DateTime.now().toUtc().subtract(const Duration(days: 30));
      var token = signAppleIdentityToken(
        subject: '000123.abc.0001',
        issuedAt: longAgo,
        expiresAt: longAgo.add(const Duration(minutes: 10)),
      );

      await expectLater(
        _verify(token),
        throwsA(
          isA<AppleIdentityTokenException>().having(
            (e) => e.message,
            'message',
            contains('expired'),
          ),
        ),
        reason:
            'Without an expiry check a token captured once stays valid '
            'forever.',
      );
    });

    test(
      'when it expired within the clock skew tolerance, then it is accepted.',
      () async {
        var token = signAppleIdentityToken(
          subject: '000123.abc.0001',
          expiresAt: DateTime.now().toUtc().subtract(
            const Duration(seconds: 5),
          ),
        );

        var verified = await _verify(token);

        expect(verified.subject, '000123.abc.0001');
      },
    );
  });

  group('Given an identity token issued in the future, ', () {
    test('when verifying it, then it is rejected.', () async {
      var soon = DateTime.now().toUtc().add(const Duration(hours: 1));
      var token = signAppleIdentityToken(
        subject: '000123.abc.0001',
        issuedAt: soon,
        expiresAt: soon.add(const Duration(minutes: 10)),
      );

      await expectLater(
        _verify(token),
        throwsA(
          isA<AppleIdentityTokenException>().having(
            (e) => e.message,
            'message',
            contains('future'),
          ),
        ),
      );
    });
  });

  group('Given an identity token not signed by Apple, ', () {
    test('when verifying it, then it is rejected.', () async {
      var token = signAppleIdentityToken(subject: '000123.abc.0001');
      var tampered = '${token.substring(0, token.length - 6)}AAAAAA';

      await expectLater(
        _verify(tampered),
        throwsA(isA<AppleIdentityTokenException>()),
      );
    });

    test('when it is not a JWT at all, then it is rejected.', () async {
      await expectLater(
        _verify('not-a-token'),
        throwsA(isA<AppleIdentityTokenException>()),
      );
    });
  });

  group('Given no configured Apple client ids, ', () {
    setUp(() => AuthConfig.set(AuthConfig()));

    test(
      'when verifying an otherwise valid token, then it is rejected.',
      () async {
        var token = signAppleIdentityToken(subject: '000123.abc.0001');

        await expectLater(
          _verify(token),
          throwsA(
            isA<AppleIdentityTokenException>().having(
              (e) => e.message,
              'message',
              contains('not configured'),
            ),
          ),
          reason:
              'An unconfigured server cannot tell its own tokens from any '
              'other developer team\'s, so it must refuse rather than accept '
              'both.',
        );
      },
    );
  });

  group('Given a current identity token minted for this application, ', () {
    test('when verifying it, then its claims are returned.', () async {
      var token = signAppleIdentityToken(
        subject: '000123.abc.0001',
        email: 'User@Example.com',
      );

      var verified = await _verify(token);

      expect(verified.subject, '000123.abc.0001');
      expect(verified.email, 'user@example.com');
      expect(verified.isEmailVerified, isTrue);
    });

    test(
      'when it is one of several configured client ids, then it is accepted.',
      () async {
        AuthConfig.set(
          AuthConfig(appleClientIds: {'dev.serverpod.other', appleClientId}),
        );
        var token = signAppleIdentityToken(subject: '000123.abc.0001');

        var verified = await _verify(token);

        expect(verified.subject, '000123.abc.0001');
      },
    );

    test(
      'when Apple sends `email_verified` as a string, then it is understood.',
      () async {
        var token = signAppleIdentityToken(
          subject: '000123.abc.0001',
          email: 'user@example.com',
          emailVerified: 'true',
        );

        var verified = await _verify(token);

        expect(
          verified.isEmailVerified,
          isTrue,
          reason:
              'Apple sends the boolean claims as JSON strings on some flows.',
        );
      },
    );
  });
}

/// Verifies [identityToken] with Apple's JWKS endpoint served locally.
///
/// The token is genuinely signed and genuinely verified; only the network is
/// stubbed.
Future<AppleIdentityToken> _verify(String identityToken) {
  return http.runWithClient(
    () => AppleAuth.verifyIdentityToken(identityToken),
    appleKeysClient,
  );
}

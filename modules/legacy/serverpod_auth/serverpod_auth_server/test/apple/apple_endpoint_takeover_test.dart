import 'package:http/http.dart' as http;
import 'package:serverpod_auth_server/serverpod_auth_server.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import 'apple_test_utils.dart';

/// Reproduces the Sign in with Apple account takeover, at the endpoint.
///
/// Apple publishes one global JWKS, so an identity token minted by any Apple
/// developer team carries a signature this server accepts. The endpoint then
/// looked the account up by the token's email address, which meant a token
/// obtained from a victim in the attacker's own Apple app - with "Share My
/// Email" - authenticated as whoever already held that address here, whether
/// they had ever used Apple sign-in or not.
///
/// The invariant: only a token Apple minted for this application can sign
/// anyone in.
void main() {
  const victimEmail = 'victim@example.com';
  const attackerAppleSubject = '000999.attacker.0001';

  withServerpod('Given an existing email/password account,', (
    final sessionBuilder,
    final endpoints,
  ) {
    setUp(() async {
      AppleAuth.resetPublicKeyCache();
      AuthConfig.set(AuthConfig(appleClientIds: {appleClientId}));

      final session = sessionBuilder.build();
      final user = await Emails.createUser(
        session,
        'victim',
        victimEmail,
        'a-password-the-attacker-does-not-know',
      );
      expect(user, isNotNull, reason: 'The victim account must exist.');
    });

    tearDown(() {
      AppleAuth.resetPublicKeyCache();
      AuthConfig.set(AuthConfig());
    });

    test(
      'when an Apple identity token minted for another application carries the account\'s email, '
      'then no session is issued.',
      () async {
        final response = await _authenticate(
          endpoints,
          sessionBuilder,
          identityToken: signAppleIdentityToken(
            subject: attackerAppleSubject,
            email: victimEmail,
            audience: 'com.attacker.their-own-app',
          ),
          userIdentifier: attackerAppleSubject,
          email: victimEmail,
        );

        expect(
          response.success,
          isFalse,
          reason:
              'The token verifies against Apple\'s global JWKS but was minted '
              'for a different Apple client, so it must not authenticate '
              'anyone here.',
        );
        expect(
          response.failReason,
          AuthenticationFailReason.invalidCredentials,
        );
      },
    );

    test(
      'when an expired Apple identity token for this application carries the account\'s email, '
      'then no session is issued.',
      () async {
        final longAgo = DateTime.now().toUtc().subtract(
          const Duration(days: 30),
        );

        final response = await _authenticate(
          endpoints,
          sessionBuilder,
          identityToken: signAppleIdentityToken(
            subject: attackerAppleSubject,
            email: victimEmail,
            issuedAt: longAgo,
            expiresAt: longAgo.add(const Duration(minutes: 10)),
          ),
          userIdentifier: attackerAppleSubject,
          email: victimEmail,
        );

        expect(
          response.success,
          isFalse,
          reason:
              'Apple identity tokens are short lived; a captured one must not '
              'stay usable indefinitely.',
        );
      },
    );

    test(
      'when Sign in with Apple is not configured, then no session is issued.',
      () async {
        AuthConfig.set(AuthConfig());

        final response = await _authenticate(
          endpoints,
          sessionBuilder,
          identityToken: signAppleIdentityToken(
            subject: attackerAppleSubject,
            email: victimEmail,
          ),
          userIdentifier: attackerAppleSubject,
          email: victimEmail,
        );

        expect(
          response.success,
          isFalse,
          reason:
              'Without configured client ids the server cannot tell its own '
              'tokens apart from any other team\'s, so it must refuse.',
        );
      },
    );
  });

  withServerpod('Given no existing account,', (
    final sessionBuilder,
    final endpoints,
  ) {
    setUp(() {
      AppleAuth.resetPublicKeyCache();
      AuthConfig.set(AuthConfig(appleClientIds: {appleClientId}));
    });

    tearDown(() {
      AppleAuth.resetPublicKeyCache();
      AuthConfig.set(AuthConfig());
    });

    test(
      'when an Apple identity token minted for this application is presented, '
      'then a session is issued.',
      () async {
        const subject = '000123.legitimate.0001';

        final response = await _authenticate(
          endpoints,
          sessionBuilder,
          identityToken: signAppleIdentityToken(
            subject: subject,
            email: 'new-user@example.com',
          ),
          userIdentifier: subject,
          email: 'new-user@example.com',
        );

        expect(response.success, isTrue, reason: response.failReason?.name);
        expect(response.userInfo?.userIdentifier, subject);
      },
    );
  });
}

/// Calls the Apple endpoint with Apple's JWKS endpoint served locally.
Future<AuthenticationResponse> _authenticate(
  final TestEndpoints endpoints,
  final TestSessionBuilder sessionBuilder, {
  required final String identityToken,
  required final String userIdentifier,
  required final String? email,
}) {
  return http.runWithClient(
    () => endpoints.apple.authenticate(
      sessionBuilder,
      AppleAuthInfo(
        userIdentifier: userIdentifier,
        email: email,
        fullName: 'Test User',
        nickname: 'test',
        identityToken: identityToken,
        authorizationCode: 'authorization-code',
      ),
    ),
    appleKeysClient,
  );
}

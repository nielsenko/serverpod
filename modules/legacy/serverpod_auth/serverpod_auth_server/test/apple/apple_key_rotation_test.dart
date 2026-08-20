import 'package:http/http.dart' as http;
import 'package:serverpod_auth_server/serverpod_auth_server.dart';
import 'package:test/test.dart';

import 'apple_test_utils.dart';

/// Tests that Apple's published signing keys are re-fetched rather than
/// cached for the lifetime of the process.
///
/// Apple rotates the keys behind `appleid.apple.com/auth/keys`. Caching the
/// first response forever means the first rotation breaks Sign in with Apple
/// until the server is restarted - a token signed with the new key is
/// indistinguishable, to a stale cache, from a forged one.
///
/// The invariant: a `kid` the cache does not know is a reason to re-fetch, not
/// a reason to reject.
void main() {
  setUp(() {
    AppleAuth.resetPublicKeyCache();
    AuthConfig.set(AuthConfig(appleClientIds: {appleClientId}));
  });

  tearDown(() {
    AppleAuth.resetPublicKeyCache();
    AuthConfig.set(AuthConfig());
  });

  group('Given Apple has rotated its signing keys, ', () {
    test(
      'when a token signed with the new key arrives, '
      'then the key set is re-fetched and the token verifies.',
      () async {
        var servedKeys = [appleTestRotatedPublicJwk];
        var fetches = 0;

        // The floor exists to keep an unknown key id from turning into a
        // request to Apple per token; it is not what this test is about.
        AppleAuth.minRefetchInterval = Duration.zero;

        http.Client client() => appleKeysClient(
          keys: servedKeys,
          onKeysRequested: () => fetches++,
        );

        // Warm the cache with the pre-rotation key set, which cannot verify
        // anything these tests sign.
        await expectLater(
          http.runWithClient(
            () => AppleAuth.verifyIdentityToken(
              signAppleIdentityToken(subject: '000123.abc.0001'),
            ),
            client,
          ),
          throwsA(isA<AppleIdentityTokenException>()),
        );

        servedKeys = [appleTestPublicJwk];

        var verified = await http.runWithClient(
          () => AppleAuth.verifyIdentityToken(
            signAppleIdentityToken(subject: '000123.abc.0001'),
          ),
          client,
        );

        expect(verified.subject, '000123.abc.0001');
        expect(
          fetches,
          greaterThan(1),
          reason:
              'A cache pinned to the first response would never see the '
              'rotated key and would reject valid tokens until restart.',
        );
      },
    );
  });

  group('Given a token whose key id is already in the cache, ', () {
    test(
      'when its signature is invalid, then Apple is not re-fetched.',
      () async {
        var fetches = 0;
        http.Client client() =>
            appleKeysClient(onKeysRequested: () => fetches++);

        var token = signAppleIdentityToken(subject: '000123.abc.0001');
        var tampered = '${token.substring(0, token.length - 6)}AAAAAA';

        await expectLater(
          http.runWithClient(
            () => AppleAuth.verifyIdentityToken(tampered),
            client,
          ),
          throwsA(isA<AppleIdentityTokenException>()),
        );

        expect(
          fetches,
          1,
          reason:
              'The cache already holds the key the token names, so a bad '
              'signature is a forgery, not a stale cache. Re-fetching here '
              'would let anyone drive traffic at Apple.',
        );
      },
    );
  });

  group('Given a stream of tokens naming key ids Apple never published, ', () {
    test('when they arrive, then Apple is not fetched for each.', () async {
      var fetches = 0;
      http.Client client() => appleKeysClient(
        keys: [appleTestRotatedPublicJwk],
        onKeysRequested: () => fetches++,
      );

      for (var i = 0; i < 20; i++) {
        await expectLater(
          http.runWithClient(
            () => AppleAuth.verifyIdentityToken(
              signAppleIdentityToken(subject: '000123.abc.000$i'),
            ),
            client,
          ),
          throwsA(isA<AppleIdentityTokenException>()),
        );
      }

      expect(
        fetches,
        lessThan(5),
        reason:
            'The key id comes out of the token, so an unbounded refresh on an '
            'unknown one lets anyone aim traffic at Apple through this '
            'server.',
      );
    });
  });

  group('Given Apple\'s key endpoint is unavailable, ', () {
    test(
      'when a token signed with a cached key arrives, then it still verifies.',
      () async {
        var token = signAppleIdentityToken(subject: '000123.abc.0001');

        // Prime the cache while the endpoint is healthy.
        await http.runWithClient(
          () => AppleAuth.verifyIdentityToken(token),
          appleKeysClient,
        );

        var verified = await http.runWithClient(
          () => AppleAuth.verifyIdentityToken(
            signAppleIdentityToken(subject: '000123.abc.0002'),
          ),
          () => appleKeysClient(statusCode: 503),
        );

        expect(
          verified.subject,
          '000123.abc.0002',
          reason:
              'Keys that verified a moment ago still verify tokens signed '
              'with them, so an outage at Apple must not take sign-in down.',
        );
      },
    );

    test(
      'when the cache is empty, then verification fails with the fetch error.',
      () async {
        await expectLater(
          http.runWithClient(
            () => AppleAuth.verifyIdentityToken(
              signAppleIdentityToken(subject: '000123.abc.0001'),
            ),
            () => appleKeysClient(statusCode: 503),
          ),
          throwsA(
            isA<AppleIdentityTokenException>().having(
              (e) => e.message,
              'message',
              contains('Failed to fetch'),
            ),
          ),
        );
      },
    );
  });
}

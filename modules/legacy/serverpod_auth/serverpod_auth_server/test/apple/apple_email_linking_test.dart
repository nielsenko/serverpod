import 'package:http/http.dart' as http;
import 'package:serverpod_auth_server/serverpod_auth_server.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import 'apple_test_utils.dart';

/// Tests which account a Sign in with Apple resolves to.
///
/// A shared email address is not proof that the caller already holds the
/// account carrying it, so by default an Apple sign-in is resolved by Apple's
/// subject alone. `AuthConfig.linkSocialSignInsByEmail` restores the older
/// behaviour for deployments that grew to depend on it.
///
/// The invariant: an account registered some other way is reached by email
/// only when the deployment has asked for that.
const existingEmail = 'existing@example.com';
const appleSubject = '000123.abc.0001';

void main() {
  withServerpod('Given an account registered with a password,', (
    final sessionBuilder,
    final endpoints,
  ) {
    setUp(() async {
      AppleAuth.resetPublicKeyCache();
      AuthConfig.set(AuthConfig(appleClientIds: {appleClientId}));

      final session = sessionBuilder.build();
      final user = await Emails.createUser(
        session,
        'existing',
        existingEmail,
        'the-existing-password',
      );
      expect(user, isNotNull);
    });

    tearDown(() {
      AppleAuth.resetPublicKeyCache();
      AuthConfig.set(AuthConfig());
    });

    test(
      'when an Apple sign in carries the same email, '
      'then a separate account is used.',
      () async {
        final response = await _authenticate(endpoints, sessionBuilder);

        expect(response.success, isTrue, reason: response.failReason?.name);
        expect(
          response.userInfo?.userIdentifier,
          appleSubject,
          reason:
              'The Apple subject is what identifies the caller; the shared '
              'address says nothing about who they are.',
        );
      },
    );

    test(
      'when account linking by email is enabled, '
      'then the existing account is used.',
      () async {
        AuthConfig.set(
          AuthConfig(
            appleClientIds: {appleClientId},
            linkSocialSignInsByEmail: true,
          ),
        );

        final response = await _authenticate(endpoints, sessionBuilder);

        expect(response.success, isTrue, reason: response.failReason?.name);
        expect(
          response.userInfo?.email,
          existingEmail,
          reason: 'The opt-in restores the pre-4.0.0-beta.4 behaviour.',
        );
        expect(response.userInfo?.userIdentifier, isNot(appleSubject));
      },
    );
  });

  withServerpod('Given an account created by an earlier Apple sign in,', (
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
      'when the same user signs in again, then the same account is used.',
      () async {
        final first = await _authenticate(endpoints, sessionBuilder);
        final second = await _authenticate(endpoints, sessionBuilder);

        expect(first.success, isTrue, reason: first.failReason?.name);
        expect(
          second.userInfo?.id,
          first.userInfo?.id,
          reason:
              'Accounts an Apple sign in created carry the Apple subject as '
              'their identifier, so they are found without the email lookup.',
        );
      },
    );
  });
}

Future<AuthenticationResponse> _authenticate(
  final TestEndpoints endpoints,
  final TestSessionBuilder sessionBuilder,
) {
  return http.runWithClient(
    () => endpoints.apple.authenticate(
      sessionBuilder,
      AppleAuthInfo(
        userIdentifier: appleSubject,
        email: existingEmail,
        fullName: 'Existing User',
        nickname: 'existing',
        identityToken: signAppleIdentityToken(
          subject: appleSubject,
          email: existingEmail,
        ),
        authorizationCode: 'authorization-code',
      ),
    ),
    appleKeysClient,
  );
}

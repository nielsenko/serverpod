import 'package:http/testing.dart';
import 'package:serverpod_auth_server/serverpod_auth_server.dart';
import 'package:serverpod_auth_server/src/business/firebase_auth.dart';
import 'package:serverpod_auth_server/src/firebase/firebase_auth_manager.dart';
import 'package:test/test.dart';

import '../integration/test_tools/serverpod_test_tools.dart';
import 'firebase_auth_mock.dart';

/// Tests that a Firebase sign-in cannot reach an existing account through an
/// email address Firebase has not verified.
///
/// The endpoint resolves the account by email before falling back to the
/// Firebase subject. Firebase issues perfectly valid tokens carrying
/// `email_verified: false` for addresses a user simply typed in at
/// registration, so an attacker who self-registers the victim's address in the
/// application's own Firebase project would be signed in as the victim.
///
/// The invariant: an unverified address identifies nobody.
void main() {
  const victimEmail = 'victim@example.com';
  const attackerUid = 'attacker-firebase-uid';

  withServerpod('Given an existing email/password account,', (
    final sessionBuilder,
    final endpoints,
  ) {
    setUp(() async {
      final session = sessionBuilder.build();
      final user = await Emails.createUser(
        session,
        'victim',
        victimEmail,
        'a-password-the-attacker-does-not-know',
      );
      expect(user, isNotNull, reason: 'The victim account must exist.');
    });

    tearDown(() => FirebaseAuth.authManagerOverride = null);

    test(
      'when a Firebase token carries the account\'s email unverified, '
      'then it does not sign in as that account.',
      () async {
        _installFirebaseAuthManager(uid: attackerUid);

        final response = await endpoints.firebase.authenticate(
          sessionBuilder,
          generateMockIdToken(
            uid: attackerUid,
            overrides: {'email': victimEmail, 'email_verified': false},
          ),
        );

        expect(
          response.userInfo?.email,
          isNot(victimEmail),
          reason:
              'Anyone can self-register an address in a Firebase project; '
              'only a verified one says anything about who the caller is.',
        );
      },
    );

    test(
      'when a Firebase token carries the account\'s email unverified, '
      'then the address is not stored on the new account.',
      () async {
        _installFirebaseAuthManager(uid: attackerUid);

        final response = await endpoints.firebase.authenticate(
          sessionBuilder,
          generateMockIdToken(
            uid: attackerUid,
            overrides: {'email': victimEmail, 'email_verified': false},
          ),
        );

        expect(
          response.userInfo?.email,
          isNull,
          reason:
              'Storing it would leave the address linkable by the next '
              'sign-in that looks accounts up by email.',
        );
      },
    );

    test(
      'when a Firebase token carries the account\'s email verified, '
      'then it signs in as that account.',
      () async {
        _installFirebaseAuthManager(uid: attackerUid);

        final response = await endpoints.firebase.authenticate(
          sessionBuilder,
          generateMockIdToken(
            uid: attackerUid,
            overrides: {'email': victimEmail, 'email_verified': true},
          ),
        );

        expect(response.success, isTrue, reason: response.failReason?.name);
        expect(
          response.userInfo?.email,
          victimEmail,
          reason:
              'A verified address is the documented way legacy Firebase '
              'sign-ins reach an existing account; that behaviour stands.',
        );
      },
    );
  });
}

/// Points [FirebaseAuth] at a manager whose Firebase and OpenID backends are
/// served locally, so tokens from [generateMockIdToken] verify.
void _installFirebaseAuthManager({required final String uid}) {
  FirebaseAuth.authManagerOverride = FirebaseAuthManager(
    testAccountServiceJson,
    authClient: MockClient(
      FirebaseAuthBackendMock(
        userJson: crateUserRecord(
          uuid: uid,
          validSince: DateTime.now().subtract(const Duration(days: 1)),
        ),
      ).onHttpCall,
    ),
    openIdClient: MockClient(FirebaseOpenIdBackendMock().onHttpCall),
  );
}

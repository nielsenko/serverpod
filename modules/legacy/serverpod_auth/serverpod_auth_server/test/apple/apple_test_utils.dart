import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jose/jose.dart';

/// The issuer Apple stamps on its identity tokens.
const appleIssuer = 'https://appleid.apple.com';

/// The client id these tests configure the server to accept tokens for.
const appleClientId = 'dev.serverpod.example';

/// A throwaway RSA key pair standing in for one of Apple's signing keys.
///
/// Generated for these tests only. Nothing outside them is signed with it.
final appleTestPrivateJwk = <String, dynamic>{
  'kty': 'RSA',
  'kid': 'apple-test-key',
  'use': 'sig',
  'alg': 'RS256',
  'n':
      'peQeURCzZ9pQX9UgLJ4BlxUtl9hqDkQ4tuCiburRzHE_0Q0cFcI_RUB6JfHt6-_C2HjLH6dF3u45gC1VtYbUB5gjRtRse8zcC0gUVmNwnLKrk42ji3HbyM7ZkZQudZmzXU1JuBD2M9wHRatg2hYTw6NfE4R_qb1dLP-Jsx8xltPXmENwYOMc8FZbPAa0rkVpCyYEgEuZYIxUZ6Cf0VdoU4EJu2H-jB2c442RMtL00jbXduq-4KkGe8dQrzghaMe8UHTvHIf2hj-yHnoFCmwHNSZzPQAGsn9u7pgmH08FXDAe2ivRvXNdIF1z2Uzbguv6nAxPTH0Wm5gZOn6heWPHDw',
  'e': 'AQAB',
  'd':
      'CmUFW0oDG9ZLo_2cQv9xlRBwJ2wZlSREM31W4EFZfQh5mbVLFbfys_mqzbbflCGVYXAMNkMKd0IRG0176eB1Z7ZqO3VzCLzY6uIM2C7p7v-pDZlZ7pJnValUa7FPyfGkEgwWOvDhJHW8hOqMqo2olmElw3jRcQbbEEdAzxb8yfkJSKsA1iOWjaLR_NMOjK_8uMeCXyluQdgm9DOZ53CIEyXymQuDFl-tkMA6eqG5y6nGdj77WdlpUPv6EuAeoZHf_W4_Lu5p_CcefbPXIczLy7SAi8d6Y2B81km17r1UnH70SdZQVYVDLcDIBVu_2gGxpi1eC1obw0qzgPlnDnm3xQ',
  'p':
      '3xExtqhn2jMqoSU4fX676iNKNaQCrqGaix4glSczc9SgK9gnmL0hNP2AheaxmreV8TlRFEWCyDvnE0A3cb39FSf9eYQiU36NUU4JTPsQ5crUvJHZZAWCfnQ-erWjiklrhw_kcw74BYqhXSaKLmxx9aroHkNEBERapy0fkAicDhU',
  'q':
      'vmH1fC6W9XxIVVabomVFpOKrhCKV8X4dx6TrKqx7ctkVT4jEAWK3NkfAOgey-7JcMVP74Jpqhsnw8YsrG7jZVJHGj9xPguO4UpydbV4glk2XzKg4LHzegQcUjT5DwYdPEF58eRfMrwQcSy4Va214M6SOL-5wNFKJG6tA9LWWLZM',
  'dp':
      'QLQ6GWOsDCz_VpL3Wd-jHn1yDzEt3f3eWDA6_0jJsfWhKFag1bs2oKpP14ddSSWrhrc7f4fSMca-dmUQMBwOB078RX1Af7ubvlPGet_wvNci8jfUOSEoAwow_WMmtvwpBppjh8R1yRW3TM_bETA_tiUHA5A7cIlrSkbaeuskaSk',
  'dq':
      'EUUfmLE9Pm2UvjEKEzQumiN5vZXJlkuDdg3Oy2M0G5n3pexZI2sKBaGCnYD_SnfGhy8AJUK8sRd2hOLD-VLOXC6RHZG1oMD5gnz0huxH9np5b7Y-ykJViMzUn29rhA27LVf04KM5DRNJYcR_auxWQBEIWO6_PO_Twi_Jx6kFQ4M',
  'qi':
      'eVTR-NGXcdXsZ5qRYIrrKAYI8ICEEnGW6PHoOsb3jn2HjFai_JHVjdpdWMEYp5GxU9Bm-vm2gFxBVFk184zo1qhyXqemXDWVcqaFRZR9RLrgfEJwLQFLAIY5NoIOjHyON43DqUBVAhZafyt-O83UPVoi4zXy9Eae3zJ7x3F-UIw',
};

/// The public half of [appleTestPrivateJwk], in the shape Apple's JWKS
/// endpoint publishes.
final appleTestPublicJwk = <String, dynamic>{
  'kty': 'RSA',
  'kid': 'apple-test-key',
  'use': 'sig',
  'alg': 'RS256',
  'n':
      'peQeURCzZ9pQX9UgLJ4BlxUtl9hqDkQ4tuCiburRzHE_0Q0cFcI_RUB6JfHt6-_C2HjLH6dF3u45gC1VtYbUB5gjRtRse8zcC0gUVmNwnLKrk42ji3HbyM7ZkZQudZmzXU1JuBD2M9wHRatg2hYTw6NfE4R_qb1dLP-Jsx8xltPXmENwYOMc8FZbPAa0rkVpCyYEgEuZYIxUZ6Cf0VdoU4EJu2H-jB2c442RMtL00jbXduq-4KkGe8dQrzghaMe8UHTvHIf2hj-yHnoFCmwHNSZzPQAGsn9u7pgmH08FXDAe2ivRvXNdIF1z2Uzbguv6nAxPTH0Wm5gZOn6heWPHDw',
  'e': 'AQAB',
};

/// Signs an Apple identity token with [appleTestPrivateJwk].
///
/// Every claim has a default that produces a token Apple itself would have
/// issued for [appleClientId], so a test only names the claim it is bending.
String signAppleIdentityToken({
  required String subject,
  String? email,
  Object? emailVerified = true,
  String issuer = appleIssuer,
  Object? audience = appleClientId,
  DateTime? issuedAt,
  DateTime? expiresAt,
}) {
  var now = DateTime.now().toUtc();
  var claims = <String, dynamic>{
    'iss': issuer,
    'aud': audience,
    'sub': subject,
    'iat': (issuedAt ?? now).millisecondsSinceEpoch ~/ 1000,
    'exp':
        (expiresAt ?? now.add(const Duration(minutes: 10)))
            .millisecondsSinceEpoch ~/
        1000,
    'email': ?email,
    if (email != null) 'email_verified': ?emailVerified,
  };

  var builder = JsonWebSignatureBuilder()
    ..jsonContent = claims
    ..addRecipient(
      JsonWebKey.fromJson(appleTestPrivateJwk),
      algorithm: 'RS256',
    );

  return builder.build().toCompactSerialization();
}

/// Serves Apple's JWKS endpoint so that tokens signed by
/// [signAppleIdentityToken] verify.
///
/// [keys] defaults to the public half of the test key pair. Pass a different
/// set to model key rotation, and [onKeysRequested] to count the fetches.
http.Client appleKeysClient({
  List<Map<String, dynamic>>? keys,
  void Function()? onKeysRequested,
  int statusCode = 200,
}) {
  var keysUrl = Uri.parse('https://appleid.apple.com/auth/keys');

  return MockClient((request) async {
    if (request.url != keysUrl) {
      return http.Response('Unexpected request to ${request.url}', 404);
    }

    onKeysRequested?.call();
    if (statusCode != 200) return http.Response('', statusCode);

    return http.Response(
      jsonEncode({
        'keys': keys ?? [appleTestPublicJwk],
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

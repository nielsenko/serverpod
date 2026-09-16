import 'dart:convert';
import 'dart:typed_data';

import 'package:serverpod/serverpod.dart';
import 'package:serverpod_auth_core_server/src/jwt/business/refresh_token_string.dart';
import 'package:test/test.dart';

void main() {
  final id = base64Encode(const Uuid().v4obj().toBytes());
  final secret = base64Encode(Uint8List.fromList(List.generate(32, (i) => i)));
  final corruptedSecret = '${secret.substring(0, secret.length - 1)}*';

  final malformedTokens = {
    'a missing prefix': 'xxxxx:$id:$secret:$secret',
    'a missing part': 'sajrt:$id:$secret',
    'an invalid base64 fixed secret': 'sajrt:$id:$corruptedSecret:$secret',
    'an invalid base64 rotating secret': 'sajrt:$id:$secret:$corruptedSecret',
  };

  for (final MapEntry(key: description, value: token)
      in malformedTokens.entries) {
    group('Given a refresh token with $description', () {
      test(
        'when parsing it, '
        'then the thrown FormatException does not contain the token',
        () {
          expect(
            () => RefreshTokenString.parseRefreshTokenString(token),
            throwsA(
              isA<FormatException>()
                  .having((e) => e.source, 'source', isNull)
                  .having(
                    (e) => e.toString(),
                    'toString()',
                    isNot(
                      anyOf(
                        contains(secret),
                        contains(corruptedSecret),
                      ),
                    ),
                  ),
            ),
          );
        },
      );
    });
  }
}

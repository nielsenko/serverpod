import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:serverpod/serverpod.dart';

import '../../common/utils/decode_base64_secret.dart';
import '../../generated/protocol.dart';

@internal
abstract final class RefreshTokenString {
  /// Prefix for refresh tokens
  /// "sajrt" being an abbreviation of "serverpod_auth_jwt Refresh Token"
  static const _refreshTokenPrefix = 'sajrt';

  /// Returns the external refresh token string
  static String buildRefreshTokenString({
    required final RefreshToken refreshToken,
    required final Uint8List rotatingSecret,
  }) {
    return '$_refreshTokenPrefix:${base64Encode(refreshToken.id!.toBytes())}:${base64Encode(Uint8List.sublistView(refreshToken.fixedSecret))}:${base64Encode(rotatingSecret)}';
  }

  static RefreshTokenStringData parseRefreshTokenString(
    final String refreshToken,
  ) {
    // Exceptions must not carry the token, as callers may log them.
    if (!refreshToken.startsWith('$_refreshTokenPrefix:')) {
      throw const FormatException(
        'Refresh token does not start with "$_refreshTokenPrefix".',
      );
    }

    final parts = refreshToken.split(':');
    if (parts.length != 4) {
      throw const FormatException(
        'Refresh token does not consist of 4 parts separated by ":".',
      );
    }

    return (
      id: UuidValue.fromByteList(decodeBase64Secret(parts[1])),
      fixedSecret: decodeBase64Secret(parts[2]),
      rotatingSecret: decodeBase64Secret(parts[3]),
    );
  }
}

/// The data obtained from reading in a refresh token string.
typedef RefreshTokenStringData = ({
  UuidValue id,
  Uint8List fixedSecret,
  Uint8List rotatingSecret,
});

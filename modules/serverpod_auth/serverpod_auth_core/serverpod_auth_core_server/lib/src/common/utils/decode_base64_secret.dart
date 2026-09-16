import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// Decodes base64 or base64url [encoded] like [base64Decode], but a
/// [FormatException] thrown for malformed input omits the input as its
/// `source`, so the secret cannot leak through `toString()`.
@internal
Uint8List decodeBase64Secret(final String encoded) {
  try {
    return base64Decode(encoded);
  } on FormatException catch (e) {
    throw FormatException(e.message);
  }
}

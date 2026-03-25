import 'dart:io';

/// Throws a [SocketException] if the current platform does not support Unix
/// domain sockets.
///
/// On Windows, AF_UNIX sockets require Dart 3.11+. On macOS and Linux they
/// are always available.
void requireUnixSocketSupport() {
  if (!hasUnixSocketSupport()) {
    throw SocketException(
      'Unix domain sockets require Dart 3.11+ on Windows '
      '(current: ${Platform.version.split(' ').first}).',
    );
  }
}

/// Returns `true` if the current platform supports Unix domain sockets.
///
/// On Windows, AF_UNIX sockets require Dart 3.11+. On macOS and Linux they
/// are always available.
bool hasUnixSocketSupport() {
  if (Platform.isWindows) {
    final parts = Platform.version.split(' ').first.split('.');
    final major = int.parse(parts[0]);
    final minor = parts.length > 1 ? int.parse(parts[1]) : 0;

    if (major < 3 || (major == 3 && minor < 11)) return false;
  }
  return true; // supported on other platforms if it compiles
}

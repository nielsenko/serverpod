import 'dart:io' show stderr;

/// Callback for writing error/warning messages.
///
/// Defaults to writing to stderr. Can be overridden to route messages
/// through a structured logging system (e.g., serverpod's Logger).
void Function(String message) writeError = _defaultWriteError;

void _defaultWriteError(String message) {
  stderr.writeln(message);
}

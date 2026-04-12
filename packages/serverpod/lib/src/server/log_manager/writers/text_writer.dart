import 'dart:io';

import '../log_types.dart';

/// Callback interface for text-based log rendering.
///
/// Allows the writer to delegate formatting to an external logger
/// (e.g., cli_tools StdOutLogger or IsolatedLogger) without depending
/// on that package directly.
abstract class TextWriterDelegate {
  void writeLog(LogLevel level, String message);
  Future<void> startProgress(String label);
  void completeProgress(bool success);
}

/// A simple [TextWriterDelegate] that writes directly to stdout/stderr.
/// Used when no external logger is available.
class StdioTextWriterDelegate implements TextWriterDelegate {
  @override
  void writeLog(LogLevel level, String message) {
    final prefix = switch (level) {
      LogLevel.debug => 'DEBUG: ',
      LogLevel.info => '',
      LogLevel.warning => 'WARNING: ',
      LogLevel.error || LogLevel.fatal => 'ERROR: ',
    };
    final output = '$prefix$message';
    if (level.index >= LogLevel.error.index) {
      stderr.writeln(output);
    } else {
      stdout.writeln(output);
    }
  }

  @override
  Future<void> startProgress(String label) async {
    stdout.write('$label...');
  }

  @override
  void completeProgress(bool success) {
    stdout.writeln(success ? ' done.' : ' failed.');
  }
}

/// A [LogWriter] that outputs formatted text via a [TextWriterDelegate].
///
/// In the CLI, the delegate wraps a `cli_tools.Logger` (StdOutLogger
/// or IsolatedLogger) for ANSI formatting and progress spinners.
/// In the server, the default [StdioTextWriterDelegate] writes plain text.
class TextWriter extends LogWriter {
  final TextWriterDelegate _delegate;

  TextWriter([TextWriterDelegate? delegate])
    : _delegate = delegate ?? StdioTextWriterDelegate();

  @override
  Future<void> log(LogEntry entry) async {
    _delegate.writeLog(entry.level, entry.message);
  }

  @override
  Future<void> openScope(LogScope scope) async {
    await _delegate.startProgress(scope.label);
  }

  @override
  Future<void> closeScope(
    LogScope scope, {
    required bool success,
    required Duration duration,
    Object? error,
    StackTrace? stackTrace,
  }) async {
    _delegate.completeProgress(success);
  }
}

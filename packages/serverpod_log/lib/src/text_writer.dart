import 'dart:io';

import 'log_types.dart';

/// A [LogWriter] that writes formatted text to stdout/stderr.
class TextWriter extends LogWriter {
  @override
  Future<void> log(LogEntry entry) async {
    final prefix = switch (entry.level) {
      LogLevel.debug => 'DEBUG: ',
      LogLevel.info => '',
      LogLevel.warning => 'WARNING: ',
      LogLevel.error || LogLevel.fatal => 'ERROR: ',
    };
    final output = '$prefix${entry.message}';
    if (entry.level.index >= LogLevel.error.index) {
      stderr.writeln(output);
      if (entry.error != null) stderr.writeln('${entry.error}');
      if (entry.stackTrace != null) stderr.writeln('${entry.stackTrace}');
    } else {
      stdout.writeln(output);
    }
  }

  @override
  Future<void> openScope(LogScope scope) async {
    stdout.writeln('${scope.label}...');
  }

  @override
  Future<void> closeScope(
    LogScope scope, {
    required bool success,
    required Duration duration,
    Object? error,
    StackTrace? stackTrace,
  }) async {
    final status = success ? 'done' : 'failed';
    stdout.writeln('${scope.label} $status.');
  }
}

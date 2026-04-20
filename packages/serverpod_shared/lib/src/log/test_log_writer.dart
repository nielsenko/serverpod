import 'package:meta/meta.dart';

import 'log_types.dart';

/// A completed scope record for test assertions.
class ClosedScope {
  ClosedScope({
    required this.scope,
    required this.success,
    required this.duration,
    this.error,
    this.stackTrace,
  });

  final LogScope scope;
  final bool success;
  final Duration duration;
  final Object? error;
  final StackTrace? stackTrace;
}

/// A [LogWriter] that collects entries and scopes for test assertions.
@visibleForTesting
class TestLogWriter extends LogWriter {
  final List<LogEntry> entries = [];
  final List<LogScope> openedScopes = [];
  final List<ClosedScope> closedScopes = [];

  @override
  Future<void> log(LogEntry entry) async => entries.add(entry);

  @override
  Future<void> openScope(LogScope scope) async => openedScopes.add(scope);

  @override
  Future<void> closeScope(
    LogScope scope, {
    required bool success,
    required Duration duration,
    Object? error,
    StackTrace? stackTrace,
  }) async {
    closedScopes.add(
      ClosedScope(
        scope: scope,
        success: success,
        duration: duration,
        error: error,
        stackTrace: stackTrace,
      ),
    );
  }
}

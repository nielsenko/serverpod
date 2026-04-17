import 'dart:async';

import 'log_types.dart';

/// Symbol used to store the current [LogScope] in Zone values.
const Symbol _logScopeKey = #_logScope;

int _scopeCounter = 0;
String _newScopeId(String label) =>
    '${label.hashCode}_${DateTime.now().millisecondsSinceEpoch}_${++_scopeCounter}';

/// A logger that delegates to a [LogWriter] and resolves the current
/// [LogScope] from the Zone.
///
/// The core method is [call], which checks the log level before
/// constructing the [LogEntry]. Convenience methods ([debug], [info],
/// [warning], [error]) are provided as extensions.
///
/// Usage:
/// ```dart
/// log.info('Server started');
/// await log.progress('Migration', () async {
///   log.info('Step 1');  // automatically scoped to Migration
/// });
/// ```
class Log {
  final LogWriter _writer;

  LogLevel logLevel;

  Log(this._writer, {this.logLevel = LogLevel.info});

  /// The current scope from the Zone. Falls back to a synthetic root
  /// if no scope has been set.
  LogScope get currentScope =>
      Zone.current[_logScopeKey] as LogScope? ?? _fallbackScope;

  static final _fallbackScope = LogScope.root('unknown');

  /// Core logging method. Checks level, then calls the factory and
  /// passes the entry to the writer.
  void call(LogLevel level, LogEntry Function() factory) {
    if (level.index < logLevel.index) return;
    unawaited(_writer.log(factory()));
  }
}

/// Convenience methods for common log levels.
extension LogConvenience on Log {
  void debug(String message, {Map<String, Object?>? metadata}) => this(
    LogLevel.debug,
    () => LogEntry(
      time: DateTime.now(),
      level: LogLevel.debug,
      message: message,
      scope: currentScope,
      metadata: metadata,
    ),
  );

  void info(String message, {Map<String, Object?>? metadata}) => this(
    LogLevel.info,
    () => LogEntry(
      time: DateTime.now(),
      level: LogLevel.info,
      message: message,
      scope: currentScope,
      metadata: metadata,
    ),
  );

  void warning(String message, {Map<String, Object?>? metadata}) => this(
    LogLevel.warning,
    () => LogEntry(
      time: DateTime.now(),
      level: LogLevel.warning,
      message: message,
      scope: currentScope,
      metadata: metadata,
    ),
  );

  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? metadata,
  }) => this(
    LogLevel.error,
    () => LogEntry(
      time: DateTime.now(),
      level: LogLevel.error,
      message: message,
      scope: currentScope,
      error: error,
      stackTrace: stackTrace,
      metadata: metadata,
    ),
  );

  bool get isDebugEnabled => logLevel.index <= LogLevel.debug.index;
}

/// Scope management: progress operations and manual scope control.
extension LogScoping on Log {
  /// Runs [runner] inside a new scope. The scope is automatically opened
  /// before the runner and closed after it completes (or fails).
  ///
  /// Log calls inside the runner are automatically scoped via the Zone.
  Future<T> progress<T>(
    String label,
    FutureOr<T> Function() runner, {
    Map<String, Object?>? metadata,
  }) async {
    final scope = currentScope.child(
      id: _newScopeId(label),
      label: label,
      metadata: metadata,
    );
    await _writer.openScope(scope);
    final stopwatch = Stopwatch()..start();
    try {
      final result = await runZoned(
        runner,
        zoneValues: {_logScopeKey: scope},
      );
      stopwatch.stop();
      await _writer.closeScope(
        scope,
        success: true,
        duration: stopwatch.elapsed,
      );
      return result;
    } catch (e, st) {
      stopwatch.stop();
      await _writer.closeScope(
        scope,
        success: false,
        duration: stopwatch.elapsed,
        error: e,
        stackTrace: st,
      );
      rethrow;
    }
  }
}

import 'dart:async';

import 'log_types.dart';

/// Symbol used to store the current [LogScope] in Zone values.
const Symbol logScopeKey = #_logScope;

/// Runs [body] with [rootScope] installed in the Zone.
Future<T> runWithRootScope<T>({
  required LogScope rootScope,
  required FutureOr<T> Function() body,
}) async {
  return runZoned(body, zoneValues: {logScopeKey: rootScope});
}

/// Runs [body] inside a child scope.
Future<T> runInScope<T>({
  required LogScope scope,
  required FutureOr<T> Function() body,
}) async {
  return runZoned(body, zoneValues: {logScopeKey: scope});
}

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
      Zone.current[logScopeKey] as LogScope? ?? _fallbackScope;

  static final _fallbackScope = LogScope.root('unknown');

  /// Core logging method. Checks level, then calls the factory and
  /// passes the entry to the writer.
  void call(LogLevel level, LogEntry Function() factory) {
    if (level.index < logLevel.index) return;
    _writer.log(factory());
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
      id: '${label.hashCode}_${DateTime.now().millisecondsSinceEpoch}',
      label: label,
      metadata: metadata,
    );
    await _writer.openScope(scope);
    final stopwatch = Stopwatch()..start();
    try {
      final result = await runZoned(
        runner,
        zoneValues: {logScopeKey: scope},
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

  /// Opens a child scope manually. The caller is responsible for closing
  /// it. Prefer [progress] when possible.
  ///
  /// Returns a [ScopedLog] that logs to the child scope and must be
  /// closed when done.
  ScopedLog openScope(
    String label, {
    Map<String, Object?>? metadata,
  }) {
    final scope = currentScope.child(
      id: '${label.hashCode}_${DateTime.now().millisecondsSinceEpoch}',
      label: label,
      metadata: metadata,
    );
    _writer.openScope(scope);
    return ScopedLog._(_writer, scope, logLevel);
  }
}

/// A logger bound to a specific scope. Created by [LogScoping.openScope].
/// Must be [close]d when done.
class ScopedLog extends Log {
  final LogScope _scope;
  final Stopwatch _stopwatch;

  ScopedLog._(LogWriter writer, this._scope, LogLevel level)
    : _stopwatch = Stopwatch()..start(),
      super(writer, logLevel: level);

  @override
  LogScope get currentScope => _scope;

  /// Closes this scope.
  Future<void> close({
    required bool success,
    Object? error,
    StackTrace? stackTrace,
  }) async {
    _stopwatch.stop();
    await _writer.closeScope(
      _scope,
      success: success,
      duration: _stopwatch.elapsed,
      error: error,
      stackTrace: stackTrace,
    );
  }
}

/// Generic logging types. Framework-agnostic, no serverpod-specific
/// dependencies. Eventually intended to live in a shared package
/// (e.g., cli_tools).

/// Log severity level.
enum LogLevel {
  debug,
  info,
  warning,
  error,
  fatal,
}

/// A scoped operation. Scopes form a tree - every scope has a parent
/// except the root scope.
///
/// A scope begins with [LogWriter.openScope] and ends with
/// [LogWriter.closeScope]. Log entries within the scope reference it
/// via [LogEntry.scope].
class LogScope {
  final String id;
  final String label;
  final DateTime startTime;
  final LogScope? parent;
  final Map<String, Object?>? metadata;

  const LogScope({
    required this.id,
    required this.label,
    required this.startTime,
    this.parent,
    this.metadata,
  });

  /// Creates a root scope for a process.
  factory LogScope.root(String label) => LogScope(
    id: 'root',
    label: label,
    startTime: DateTime.now(),
  );

  /// Creates a child scope under this scope.
  LogScope child({
    required String id,
    required String label,
    Map<String, Object?>? metadata,
  }) => LogScope(
    id: id,
    label: label,
    startTime: DateTime.now(),
    parent: this,
    metadata: metadata,
  );
}

/// A single log entry. Always belongs to a [LogScope].
class LogEntry {
  final DateTime time;
  final LogLevel level;
  final String message;
  final LogScope scope;
  final Object? error;
  final StackTrace? stackTrace;
  final Map<String, Object?>? metadata;

  const LogEntry({
    required this.time,
    required this.level,
    required this.message,
    required this.scope,
    this.error,
    this.stackTrace,
    this.metadata,
  });
}

/// Transport layer for log output. Implementations decide where logs go
/// (terminal, database, VM service, TUI, etc.).
///
/// Use [MultiLogWriter] to fan out to multiple writers.
abstract class LogWriter {
  /// Writes a single log entry.
  Future<void> log(LogEntry entry);

  /// Begins a scoped operation.
  Future<void> openScope(LogScope scope);

  /// Ends a scoped operation.
  Future<void> closeScope(
    LogScope scope, {
    required bool success,
    required Duration duration,
    Object? error,
    StackTrace? stackTrace,
  });
}

/// A [LogWriter] that fans out to multiple child writers.
class MultiLogWriter extends LogWriter {
  final List<LogWriter> _writers;

  MultiLogWriter(this._writers);

  @override
  Future<void> log(LogEntry entry) =>
      Future.wait(_writers.map((w) => w.log(entry)));

  @override
  Future<void> openScope(LogScope scope) =>
      Future.wait(_writers.map((w) => w.openScope(scope)));

  @override
  Future<void> closeScope(
    LogScope scope, {
    required bool success,
    required Duration duration,
    Object? error,
    StackTrace? stackTrace,
  }) => Future.wait(
    _writers.map(
      (w) => w.closeScope(
        scope,
        success: success,
        duration: duration,
        error: error,
        stackTrace: stackTrace,
      ),
    ),
  );
}

import 'package:serverpod_log/serverpod_log.dart';

import 'bounded_queue_list.dart';

/// A sub-entry within a tracked operation (session log or query).
final class OperationSubEntry {
  OperationSubEntry({
    required this.timestamp,
    required this.message,
    this.level,
    this.duration,
  });

  final DateTime timestamp;
  final String message;
  final LogLevel? level;

  /// Query duration in seconds, if this is a query sub-entry.
  final double? duration;
}

/// A tracked operation (server session or CLI progress).
///
/// While active, rendered as a pinned entry with spinner at the bottom of the
/// log area. On completion, collapses into a divider-style summary line.
final class TrackedOperation {
  TrackedOperation({
    required this.id,
    required this.label,
  }) {
    stopwatch.start();
  }

  final String id;
  final String label;
  final Stopwatch stopwatch = Stopwatch();

  /// Null while active, set on completion.
  bool? success;

  /// Duration in seconds, set on completion.
  double? duration;

  /// Sub-entries (logs, queries) that occurred during this operation.
  final List<OperationSubEntry> entries = [];
}

/// Completed tracked operation, stored in the log history.
final class CompletedOperation {
  CompletedOperation({
    required this.label,
    required this.success,
    required this.duration,
    required this.entries,
    DateTime? completedAt,
  }) : completedAt = completedAt ?? DateTime.now();

  final String label;
  final bool success;
  final Duration duration;
  final DateTime completedAt;
  final List<OperationSubEntry> entries;

  /// Whether the user has expanded this entry to see sub-entries.
  bool expanded = false;
}

/// Central state for the TUI, mutated by the backend and rendered by nocterm.
final class ServerWatchState {
  ServerWatchState();

  /// Log history entries: [LogEntry] (from serverpod_log) or
  /// [CompletedOperation].
  final logHistory = BoundedQueueList<Object>(maxLogEntries);

  /// Raw stdout/stderr lines for the "Raw Output" tab.
  final rawLines = BoundedQueueList<String>(maxRawLines);

  /// Currently active tracked operations (keyed by ID).
  final Map<String, TrackedOperation> activeOperations = {};

  /// Currently selected tab index (0 = Log Messages, 1 = Raw Output).
  int selectedTab = 0;

  /// Whether a tracked action (hot reload, migration) is in progress.
  bool actionBusy = false;

  /// Whether the server is running and ready for actions.
  bool serverReady = false;

  /// Whether to show the splash overlay. Starts true, set to false
  /// after 5 seconds or explicitly by the backend.
  bool showSplash = true;

  /// Whether the help overlay is visible.
  bool showHelp = false;

  /// Whether completed operations are expanded to show sub-entries.
  bool expandOperations = false;

  /// Maximum number of log entries to keep.
  static const maxLogEntries = 10000;

  /// Maximum number of raw lines to keep.
  static const maxRawLines = 10000;
}

import '../log_types.dart';

/// Callback interface for the TUI to receive log events.
///
/// This decouples the writer from the TUI framework (nocterm) so the
/// log types can live in a shared package without depending on UI code.
abstract class TuiWriterDelegate {
  void onLog(LogEntry entry);
  void onScopeOpen(LogScope scope);
  void onScopeClose(LogScope scope, bool success, Duration duration);
  void markDirty();
}

/// A [LogWriter] that renders to a TUI via a [TuiWriterDelegate].
///
/// The delegate pushes entries into the TUI state and triggers rebuilds.
/// This replaces the previous `TuiLogger` class.
class TuiWriter extends LogWriter {
  final TuiWriterDelegate _delegate;

  TuiWriter(this._delegate);

  @override
  Future<void> log(LogEntry entry) async {
    _delegate.onLog(entry);
    _delegate.markDirty();
  }

  @override
  Future<void> openScope(LogScope scope) async {
    _delegate.onScopeOpen(scope);
    _delegate.markDirty();
  }

  @override
  Future<void> closeScope(
    LogScope scope, {
    required bool success,
    required Duration duration,
    Object? error,
    StackTrace? stackTrace,
  }) async {
    _delegate.onScopeClose(scope, success, duration);
    _delegate.markDirty();
  }
}

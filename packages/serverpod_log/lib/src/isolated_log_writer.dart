import 'isolated_object.dart';
import 'log_types.dart';

/// A [LogWriter] that wraps any [LogWriter] in a dedicated isolate.
///
/// This ensures that timer-driven animations (e.g. progress spinners) keep
/// updating even when the calling isolate's event loop is blocked by heavy
/// synchronous work.
///
/// All operations are forwarded to the isolate. [log] is fire-and-forget;
/// [openScope] and [closeScope] are awaited so callers can sequence scope
/// boundaries.
class IsolatedLogWriter extends IsolatedObject<LogWriter> implements LogWriter {
  /// Creates an [IsolatedLogWriter] that runs the writer produced by
  /// [factory] on a dedicated isolate.
  IsolatedLogWriter(LogWriter Function() factory) : super(factory);

  void _fireAndForget(void Function(LogWriter) fn) async {
    if (isClosed) return;
    await evaluate(fn);
  }

  @override
  Future<void> log(LogEntry entry) async {
    _fireAndForget((w) => w.log(entry));
  }

  @override
  Future<void> openScope(LogScope scope) async {
    await evaluate((w) => w.openScope(scope));
  }

  @override
  Future<void> closeScope(
    LogScope scope, {
    required bool success,
    required Duration duration,
    Object? error,
    StackTrace? stackTrace,
  }) async {
    await evaluate(
      (w) => w.closeScope(
        scope,
        success: success,
        duration: duration,
        error: error,
        stackTrace: stackTrace,
      ),
    );
  }
}

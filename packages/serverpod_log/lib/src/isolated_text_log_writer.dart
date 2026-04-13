import 'dart:async';

import 'isolated_object.dart';
import 'log_types.dart';
import 'text_log_writer.dart';

/// A [LogWriter] that wraps a [TextLogWriter] in a dedicated isolate.
///
/// This ensures that timer-driven animations (braille progress spinners) keep
/// updating even when the calling isolate's event loop is blocked by heavy
/// synchronous work.
///
/// All operations are forwarded to the isolate. [log] is fire-and-forget;
/// [openScope] and [closeScope] are awaited so callers can sequence scope
/// boundaries.
class IsolatedTextLogWriter extends IsolatedObject<TextLogWriter>
    implements LogWriter {
  IsolatedTextLogWriter() : super(TextLogWriter.new);

  void _fireAndForget(void Function(TextLogWriter) fn) async {
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

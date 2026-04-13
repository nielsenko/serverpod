import 'dart:developer' as developer;

import '../log_types.dart';

/// A [LogWriter] that posts structured log events via the VM service
/// extension `ext.serverpod.log`.
///
/// The CLI subscribes to these events via `vmService.onExtensionEvent`
/// to render them in the TUI. No session dependency - works for both
/// framework and session-scoped messages.
///
/// This writer is only effective when the VM service is enabled (dev
/// mode). In production, [developer.postEvent] is a no-op.
class VmServiceLogWriter extends LogWriter {
  @override
  Future<void> log(LogEntry entry) async {
    _postEvent({
      'type': 'log',
      'level': entry.level.name,
      'message': entry.message,
      'scopeId': entry.scope.id,
      'timestamp': entry.time.toUtc().toIso8601String(),
      'error': entry.error?.toString(),
      'stackTrace': entry.stackTrace?.toString(),
    });
  }

  @override
  Future<void> openScope(LogScope scope) async {
    _postEvent({
      'type': 'scope_start',
      'id': scope.id,
      'label': scope.label,
      'parentId': scope.parent?.id,
      'timestamp': scope.startTime.toUtc().toIso8601String(),
    });
  }

  @override
  Future<void> closeScope(
    LogScope scope, {
    required bool success,
    required Duration duration,
    Object? error,
    StackTrace? stackTrace,
  }) async {
    _postEvent({
      'type': 'scope_end',
      'id': scope.id,
      'success': success,
      'duration': duration.inMicroseconds / 1000000,
      'error': error?.toString(),
      'stackTrace': stackTrace?.toString(),
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });
  }

  static void _postEvent(Map<String, Object?> data) {
    data.removeWhere((_, v) => v == null);
    developer.postEvent('ext.serverpod.log', data);
  }
}

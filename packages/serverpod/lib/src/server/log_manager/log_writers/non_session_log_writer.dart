import 'package:meta/meta.dart';
import 'package:serverpod_log/serverpod_log.dart';

import '../session_log_keys.dart';

/// Forwards only non-session-tagged events to [_delegate]. Events whose
/// scope carries [SessionScopeKeys.sessionType] are dropped - the
/// session-echo writer (when installed) owns those.
@internal
class NonSessionLogWriter extends LogWriter {
  final LogWriter _delegate;

  NonSessionLogWriter(this._delegate);

  @override
  Future<void> log(LogEntry entry) {
    if (_isSessionScope(entry.scope)) return Future.value();
    return _delegate.log(entry);
  }

  @override
  Future<void> openScope(LogScope scope) {
    if (_isSessionScope(scope)) return Future.value();
    return _delegate.openScope(scope);
  }

  @override
  Future<void> closeScope(
    LogScope scope, {
    required bool success,
    required Duration duration,
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (_isSessionScope(scope)) return Future.value();
    return _delegate.closeScope(
      scope,
      success: success,
      duration: duration,
      error: error,
      stackTrace: stackTrace,
    );
  }

  @override
  Future<void> close() => _delegate.close();

  bool _isSessionScope(LogScope scope) =>
      scope.metadata?[SessionScopeKeys.sessionType] != null;
}

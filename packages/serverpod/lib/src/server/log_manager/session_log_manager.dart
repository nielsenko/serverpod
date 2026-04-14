import 'dart:async';

import 'package:meta/meta.dart';
import 'package:serverpod_log/serverpod_log.dart';

import '../../generated/protocol.dart' as proto;
import '../session.dart';

const double _microNormalizer = 1000 * 1000;

/// Manages logging for a single session using the new [LogWriter] chain.
///
/// Opens a scope when logging starts, routes entries through the writer
/// chain (which includes VmServiceLogWriter and TextLogWriter; a
/// DatabaseLogWriter is still TODO), and closes the scope when the session
/// ends.
@internal
class SessionLogManager {
  final Session _session;
  final LogWriter _writer;
  final proto.LogSettings Function(Session) _settingsForSession;
  final bool _disableSlowSessionLogging;
  final String _serverId;

  LogScope? _scope;
  final Stopwatch _stopwatch = Stopwatch();
  bool _scopeOpened = false;

  @internal
  SessionLogManager({
    required Session session,
    required LogWriter writer,
    required proto.LogSettings Function(Session) settingsForSession,
    required String serverId,
    bool disableSlowSessionLogging = false,
  }) : _session = session,
       _writer = writer,
       _settingsForSession = settingsForSession,
       _serverId = serverId,
       _disableSlowSessionLogging = disableSlowSessionLogging {
    _stopwatch.start();

    var settings = _settingsForSession(session);
    if (settings.logAllSessions) {
      unawaited(_openScope());
    }
  }

  String _buildLabel() {
    final endpoint = _session.endpoint;
    final method = _session.method;

    return switch (_session) {
      MethodCallSession() => '$endpoint${method != null ? '.$method' : ''}',
      StreamingSession() || MethodStreamSession() =>
        'STREAM $endpoint${method != null ? '.$method' : ''}',
      FutureCallSession s => 'FUTURE ${s.futureCallName}',
      WebCallSession() => 'WEB $endpoint',
      InternalSession() => 'INTERNAL',
      _ => endpoint,
    };
  }

  Future<void> _openScope() async {
    if (_scopeOpened) return;
    _scopeOpened = true;

    _scope = LogScope(
      id: '${_session.sessionId.hashCode}',
      label: _buildLabel(),
      startTime: _session.startTime,
      metadata: {
        'serverId': _serverId,
        'endpoint': _session.endpoint,
        'method': _session.method,
      },
    );
    await _writer.openScope(_scope!);
  }

  /// Logs an entry within this session.
  @internal
  Future<void> logEntry({
    proto.LogLevel? level,
    required String message,
    String? error,
    StackTrace? stackTrace,
  }) async {
    final logLevel = level ?? proto.LogLevel.info;
    var logSettings = _settingsForSession(_session);
    if (logLevel.index < logSettings.logLevel.index) return;

    if (!_scopeOpened) await _openScope();

    final scope = _scope;
    if (scope == null) return;

    final newLevel = switch (logLevel) {
      proto.LogLevel.debug => LogLevel.debug,
      proto.LogLevel.info => LogLevel.info,
      proto.LogLevel.warning => LogLevel.warning,
      proto.LogLevel.error => LogLevel.error,
      proto.LogLevel.fatal => LogLevel.fatal,
    };

    await _writer.log(
      LogEntry(
        time: DateTime.now(),
        level: newLevel,
        message: message,
        scope: scope,
        error: error,
        stackTrace: stackTrace,
      ),
    );
  }

  /// Logs a database query within this session.
  @internal
  Future<void> logQuery({
    required String query,
    required Duration duration,
    required int? numRowsAffected,
    required String? error,
    required StackTrace stackTrace,
  }) async {
    var executionTime = duration.inMicroseconds / _microNormalizer;
    var logSettings = _settingsForSession(_session);
    var slow = executionTime >= logSettings.slowQueryDuration;

    if (!logSettings.logAllQueries &&
        !(logSettings.logSlowQueries && slow) &&
        !(logSettings.logFailedQueries && error != null)) {
      return;
    }

    if (!_scopeOpened) await _openScope();

    final scope = _scope;
    if (scope == null) return;

    await _writer.log(
      LogEntry(
        time: DateTime.now(),
        level: LogLevel.debug,
        message: query,
        scope: scope,
        error: error,
        metadata: {
          'type': 'query',
          'duration': executionTime,
          'numRows': numRowsAffected,
          'slow': slow,
        },
      ),
    );
  }

  /// Logs a streaming message within this session.
  @internal
  Future<void> logMessage({
    required String endpointName,
    required String messageName,
    required int messageId,
    required Duration duration,
    required String? error,
    required StackTrace? stackTrace,
  }) async {
    var executionTime = duration.inMicroseconds / _microNormalizer;
    var slow =
        executionTime >= _settingsForSession(_session).slowSessionDuration;

    var logSettings = _settingsForSession(_session);
    if (!logSettings.logAllSessions &&
        !(logSettings.logSlowSessions && slow) &&
        !(logSettings.logFailedSessions && error != null)) {
      return;
    }

    if (!_scopeOpened) await _openScope();

    final scope = _scope;
    if (scope == null) return;

    await _writer.log(
      LogEntry(
        time: DateTime.now(),
        level: LogLevel.info,
        message: '$messageName ($endpointName)',
        scope: scope,
        error: error,
        stackTrace: stackTrace,
      ),
    );
  }

  /// Finalizes the session log. Called when the session closes.
  @internal
  Future<int?> finalizeLog(
    Session session, {
    String? authenticatedUserId,
    String? exception,
    StackTrace? stackTrace,
  }) async {
    _stopwatch.stop();
    var duration = session.duration;
    var logSettings = _settingsForSession(session);

    var slowMicros = (logSettings.slowSessionDuration * _microNormalizer)
        .toInt();
    var isSlow =
        duration > Duration(microseconds: slowMicros) &&
        !_disableSlowSessionLogging;

    if (logSettings.logAllSessions ||
        (logSettings.logSlowSessions && isSlow) ||
        (logSettings.logFailedSessions && exception != null) ||
        _scopeOpened) {
      if (!_scopeOpened) await _openScope();

      final scope = _scope;
      if (scope != null) {
        await _writer.closeScope(
          scope,
          success: exception == null,
          duration: _stopwatch.elapsed,
          error: exception != null ? Exception(exception) : null,
          stackTrace: stackTrace,
        );
        _scope = null;
      }
    }

    return null;
  }
}

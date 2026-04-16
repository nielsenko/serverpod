import 'dart:async';

import 'package:meta/meta.dart';
import 'package:serverpod_log/serverpod_log.dart';

import '../../generated/protocol.dart' as proto;
import '../serverpod.dart';
import '../session.dart';
import 'session_log_keys.dart';

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

  /// Fire-and-forget log/query/message writes tracked so [finalizeLog] can
  /// drain them before closing the scope. Without this, a writer's close
  /// path can tear down per-scope state while an in-flight entry is still
  /// on its way to it, silently dropping the entry.
  final Set<Future<void>> _pendingWrites = {};

  /// Monotonic per-session counter assigned to each log/query/message
  /// entry at *call* time (not at DB insert time) so the persisted order
  /// reflects caller order even when entries race through the writer
  /// chain.
  int _nextEntryOrder = 0;

  /// Total database queries observed for this session, counted
  /// unconditionally regardless of whether the query is persisted as a
  /// log entry. Attached to the closing scope so writers record the real
  /// count (used e.g. to report numQueries on sessions where individual
  /// query logging was turned off).
  int _queryCount = 0;

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

  String _sessionTypeValue() => switch (_session) {
    MethodCallSession() => SessionTypeValues.method,
    MethodStreamSession() => SessionTypeValues.methodStream,
    StreamingSession() => SessionTypeValues.stream,
    FutureCallSession() => SessionTypeValues.futureCall,
    WebCallSession() => SessionTypeValues.web,
    InternalSession() => SessionTypeValues.internal,
    _ => SessionTypeValues.unknown,
  };

  Future<void> _openScope() async {
    if (_scopeOpened) return;
    _scopeOpened = true;

    final session = _session;
    _scope = LogScope(
      id: '${session.sessionId.hashCode}',
      label: _buildLabel(),
      startTime: session.startTime,
      metadata: {
        SessionScopeKeys.sessionType: _sessionTypeValue(),
        SessionScopeKeys.sessionId: session.sessionId.toString(),
        SessionScopeKeys.endpoint: session.endpoint,
        SessionScopeKeys.method: session.method,
        SessionScopeKeys.serverId: _serverId,
        if (session is FutureCallSession)
          SessionScopeKeys.futureCallName: session.futureCallName,
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
  }) => _track(
    _logEntry(
      level: level,
      message: message,
      error: error,
      stackTrace: stackTrace,
    ),
  );

  Future<void> _logEntry({
    proto.LogLevel? level,
    required String message,
    String? error,
    StackTrace? stackTrace,
  }) async {
    final logLevel = level ?? proto.LogLevel.info;
    var logSettings = _settingsForSession(_session);
    if (logLevel.index < logSettings.logLevel.index) return;

    final order = ++_nextEntryOrder;
    final newLevel = switch (logLevel) {
      proto.LogLevel.debug => LogLevel.debug,
      proto.LogLevel.info => LogLevel.info,
      proto.LogLevel.warning => LogLevel.warning,
      proto.LogLevel.error => LogLevel.error,
      proto.LogLevel.fatal => LogLevel.fatal,
    };
    final metadata = <String, Object?>{
      SessionEntryKeys.type: SessionEntryTypeValues.log,
      SessionEntryKeys.order: order,
      SessionEntryKeys.messageId: ?_session.messageId,
    };

    if (!_scopeOpened) await _openScope();

    final scope = _scope;
    if (scope == null) return;

    await _writer.log(
      LogEntry(
        time: DateTime.now(),
        level: newLevel,
        message: message,
        scope: scope,
        error: error,
        stackTrace: stackTrace,
        metadata: metadata,
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
  }) => _track(
    _logQuery(
      query: query,
      duration: duration,
      numRowsAffected: numRowsAffected,
      error: error,
      stackTrace: stackTrace,
    ),
  );

  Future<void> _logQuery({
    required String query,
    required Duration duration,
    required int? numRowsAffected,
    required String? error,
    required StackTrace stackTrace,
  }) async {
    // Count every query unconditionally; the total is attached to the
    // closing scope so numQueries on the session row reflects reality
    // even when individual query entries are filtered out below.
    _queryCount++;

    var executionTime = duration.inMicroseconds / _microNormalizer;
    var logSettings = _settingsForSession(_session);
    var slow = executionTime >= logSettings.slowQueryDuration;

    if (!logSettings.logAllQueries &&
        !(logSettings.logSlowQueries && slow) &&
        !(logSettings.logFailedQueries && error != null)) {
      return;
    }

    final order = ++_nextEntryOrder;
    final metadata = <String, Object?>{
      SessionEntryKeys.type: SessionEntryTypeValues.query,
      SessionEntryKeys.order: order,
      SessionEntryKeys.queryDuration: executionTime,
      SessionEntryKeys.queryNumRows: numRowsAffected,
      SessionEntryKeys.querySlow: slow,
      SessionEntryKeys.messageId: ?_session.messageId,
    };

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
        metadata: metadata,
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
  }) => _track(
    _logMessage(
      endpointName: endpointName,
      messageName: messageName,
      messageId: messageId,
      duration: duration,
      error: error,
      stackTrace: stackTrace,
    ),
  );

  Future<void> _logMessage({
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

    final order = ++_nextEntryOrder;
    final metadata = <String, Object?>{
      SessionEntryKeys.type: SessionEntryTypeValues.message,
      SessionEntryKeys.order: order,
      SessionEntryKeys.messageEndpoint: endpointName,
      SessionEntryKeys.messageName: messageName,
      SessionEntryKeys.messageId: messageId,
      SessionEntryKeys.messageDuration: executionTime,
      SessionEntryKeys.messageSlow: slow,
    };

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
        metadata: metadata,
      ),
    );
  }

  Future<void> _track(Future<void> work) async {
    _pendingWrites.add(work);
    try {
      await work;
    } finally {
      _pendingWrites.remove(work);
      // Fire-and-forget cleanup check. Runs on every log entry attempt
      // so the cleanup interval is evaluated regularly, matching the
      // pre-revamp behavior; [LogCleanupManager.performCleanup] guards
      // with its own interval check so this is a no-op when not due.
      // Intentionally unawaited and not tracked: coupling session close
      // to a background cleanup's completion would risk wedging
      // shutdown if the cleanup DB query stalls while the pool is
      // being torn down.
      unawaited(
        _session.serverpod.logCleanupManager?.performCleanup(_session),
      );
    }
  }

  /// Finalizes the session log. Called when the session closes.
  @internal
  Future<void> finalizeLog(
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

      // Drain in-flight fire-and-forget writes before closing the scope.
      // Writers like DatabaseLogWriter remove per-scope state on closeScope,
      // so a log still routing through them at that moment would be dropped.
      //
      if (_pendingWrites.isNotEmpty) {
        await Future.wait(
          _pendingWrites.map((f) => f.catchError((_) {})).toList(),
        );
      }

      final scope = _scope;
      if (scope != null) {
        // Build a close-time scope copy with late-set metadata (slow flag,
        // authenticated user id). Same id so stateful writers can look up
        // their per-scope record; fresh metadata carries the final state.
        final closeScope = LogScope(
          id: scope.id,
          label: scope.label,
          startTime: scope.startTime,
          parent: scope.parent,
          metadata: {
            ...?scope.metadata,
            SessionScopeKeys.slow: isSlow,
            SessionScopeKeys.numQueries: _queryCount,
            SessionScopeKeys.authenticatedUserId: ?authenticatedUserId,
          },
        );
        await _writer.closeScope(
          closeScope,
          success: exception == null,
          duration: _stopwatch.elapsed,
          error: exception != null ? Exception(exception) : null,
          stackTrace: stackTrace,
        );
        _scope = null;
      }
    }
  }
}

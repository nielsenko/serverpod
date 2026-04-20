import 'dart:async';

import 'package:meta/meta.dart';
import 'package:serverpod_shared/serverpod_shared.dart';

import '../../generated/protocol.dart' as protocol;
import '../serverpod.dart';
import '../session.dart';
import 'session_log_keys.dart';

const double _microNormalizer = 1000 * 1000;

/// Per-session dispatcher for the [LogWriter] chain.
///
/// Each call is appended onto a rolling `_latest` Future via `.then`,
/// giving serialized writes in invocation order and a one-pointer drain
/// at [finalizeLog]. Long-lived streams with
/// `logStreamingSessionsContinuously: false` buffer entries in memory
/// and flush through the same chain at finalize.
@internal
class SessionLogManager {
  final Session _session;
  final LogWriter _writer;
  final protocol.LogSettings Function(Session) _settingsForSession;
  final bool _disableSlowSessionLogging;
  final String _serverId;

  late final LogScope _scope;

  Future<void> _latest = Future.value();
  bool _closed = false;

  bool _writerScopeOpened = false;
  bool _hasBufferedEvents = false;
  final List<LogEntry> _buffered = [];

  final Stopwatch _stopwatch = Stopwatch();

  /// Monotonic per-session counter, assigned at call time so persisted
  /// order reflects caller order even when writes race downstream.
  int _nextEntryOrder = 0;

  /// Total queries observed, counted before the filter so numQueries on
  /// the session row reflects reality when individual query logging is
  /// off.
  int _queryCount = 0;

  /// Long-lived streaming session with continuous logging off: defer
  /// every write to session close. Evaluated once at construction.
  final bool _bufferStreamingLogs;

  @internal
  SessionLogManager({
    required Session session,
    required LogWriter writer,
    required protocol.LogSettings Function(Session) settingsForSession,
    required String serverId,
    bool disableSlowSessionLogging = false,
  }) : _session = session,
       _writer = writer,
       _settingsForSession = settingsForSession,
       _serverId = serverId,
       _disableSlowSessionLogging = disableSlowSessionLogging,
       _bufferStreamingLogs =
           (session is StreamingSession || session is MethodStreamSession) &&
           !settingsForSession(session).logStreamingSessionsContinuously {
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

    _stopwatch.start();

    // Skipped for InternalSession: _internalLoggingSession is built
    // before pod.start applies migrations, and an eager INSERT would
    // crash on the missing serverpod_session_log table. Internal
    // sessions still get their row via finalizeLog's ensure-open path.
    if (session is! InternalSession &&
        !_bufferStreamingLogs &&
        settingsForSession(session).logAllSessions) {
      unawaited(_ensureWriterScopeOpened());
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

  Future<void> _ensureWriterScopeOpened() async {
    if (_writerScopeOpened) return;
    _writerScopeOpened = true;
    await _writer.openScope(_scope);
  }

  LogLevel _toSlogLevel(protocol.LogLevel level) => switch (level) {
    protocol.LogLevel.debug => LogLevel.debug,
    protocol.LogLevel.info => LogLevel.info,
    protocol.LogLevel.warning => LogLevel.warning,
    protocol.LogLevel.error => LogLevel.error,
    protocol.LogLevel.fatal => LogLevel.fatal,
  };

  void _dispatch(LogEntry entry) {
    if (_closed) return;
    if (_bufferStreamingLogs) {
      _buffered.add(entry);
      _hasBufferedEvents = true;
      return;
    }
    _enqueueWrite(entry);
  }

  void _enqueueWrite(LogEntry entry) {
    _latest = _latest.then((_) async {
      try {
        await _ensureWriterScopeOpened();
        await _writer.log(entry);
      } catch (_) {
        // Writer errors (e.g. DB pool closing during shutdown) are
        // expected; swallow so they don't surface as unhandled async
        // errors and the chain stays healthy.
      }
    });
  }

  /// Unawaited so shutdown isn't wedged if the cleanup DB query stalls
  /// while the pool is being torn down. [LogCleanupManager.performCleanup]
  /// guards with its own interval check, so this is a no-op when not due.
  void _triggerCleanup() {
    unawaited(
      _session.serverpod.logCleanupManager?.performCleanup(_session),
    );
  }

  /// Logs an entry within this session.
  @internal
  void logEntry({
    protocol.LogLevel? level,
    required String message,
    String? error,
    StackTrace? stackTrace,
  }) {
    _triggerCleanup();

    final logLevel = level ?? protocol.LogLevel.info;
    final logSettings = _settingsForSession(_session);
    if (logLevel.index < logSettings.logLevel.index) return;

    final order = ++_nextEntryOrder;
    _dispatch(
      LogEntry(
        time: DateTime.now(),
        level: _toSlogLevel(logLevel),
        message: message,
        scope: _scope,
        error: error,
        stackTrace: stackTrace,
        metadata: {
          SessionEntryKeys.type: SessionEntryTypeValues.log,
          SessionEntryKeys.order: order,
          SessionEntryKeys.messageId: ?_session.messageId,
        },
      ),
    );
  }

  /// Logs a database query within this session.
  @internal
  void logQuery({
    required String query,
    required Duration duration,
    required int? numRowsAffected,
    required String? error,
    required StackTrace stackTrace,
  }) {
    _triggerCleanup();
    _queryCount++;

    final executionTime = duration.inMicroseconds / _microNormalizer;
    final logSettings = _settingsForSession(_session);
    final slow = executionTime >= logSettings.slowQueryDuration;

    if (!logSettings.logAllQueries &&
        !(logSettings.logSlowQueries && slow) &&
        !(logSettings.logFailedQueries && error != null)) {
      return;
    }

    final order = ++_nextEntryOrder;
    _dispatch(
      LogEntry(
        time: DateTime.now(),
        level: LogLevel.debug,
        message: query,
        scope: _scope,
        error: error,
        metadata: {
          SessionEntryKeys.type: SessionEntryTypeValues.query,
          SessionEntryKeys.order: order,
          SessionEntryKeys.queryDuration: executionTime,
          SessionEntryKeys.queryNumRows: numRowsAffected,
          SessionEntryKeys.querySlow: slow,
          SessionEntryKeys.messageId: ?_session.messageId,
        },
      ),
    );
  }

  /// Logs a streaming message within this session.
  @internal
  void logMessage({
    required String endpointName,
    required String messageName,
    required int messageId,
    required Duration duration,
    required String? error,
    required StackTrace? stackTrace,
  }) {
    _triggerCleanup();

    final executionTime = duration.inMicroseconds / _microNormalizer;
    final logSettings = _settingsForSession(_session);
    final slow = executionTime >= logSettings.slowSessionDuration;

    if (!logSettings.logAllSessions &&
        !(logSettings.logSlowSessions && slow) &&
        !(logSettings.logFailedSessions && error != null)) {
      return;
    }

    final order = ++_nextEntryOrder;
    _dispatch(
      LogEntry(
        time: DateTime.now(),
        level: LogLevel.info,
        message: '$messageName ($endpointName)',
        scope: _scope,
        error: error,
        stackTrace: stackTrace,
        metadata: {
          SessionEntryKeys.type: SessionEntryTypeValues.message,
          SessionEntryKeys.order: order,
          SessionEntryKeys.messageEndpoint: endpointName,
          SessionEntryKeys.messageName: messageName,
          SessionEntryKeys.messageId: messageId,
          SessionEntryKeys.messageDuration: executionTime,
          SessionEntryKeys.messageSlow: slow,
        },
      ),
    );
  }

  /// Drains any in-flight writes without closing the session.
  @internal
  Future<void> flush() => _latest;

  /// Finalizes the session log. Called when the session closes.
  @internal
  Future<void> finalizeLog(
    Session session, {
    String? authenticatedUserId,
    String? exception,
    StackTrace? stackTrace,
  }) async {
    _stopwatch.stop();
    final duration = session.duration;
    final logSettings = _settingsForSession(session);

    final slowMicros = (logSettings.slowSessionDuration * _microNormalizer)
        .toInt();
    final isSlow =
        duration > Duration(microseconds: slowMicros) &&
        !_disableSlowSessionLogging;

    final shouldEmit =
        logSettings.logAllSessions ||
        (logSettings.logSlowSessions && isSlow) ||
        (logSettings.logFailedSessions && exception != null) ||
        _writerScopeOpened ||
        _hasBufferedEvents;

    if (shouldEmit) {
      try {
        await _ensureWriterScopeOpened();
      } catch (_) {}

      for (final entry in _buffered) {
        _enqueueWrite(entry);
      }
      _buffered.clear();
    }

    _closed = true;
    await _latest;

    if (!shouldEmit) return;

    // Fresh scope with the same id so stateful writers look up the same
    // per-scope record; metadata carries close-time fields.
    final closeScope = LogScope(
      id: _scope.id,
      label: _scope.label,
      startTime: _scope.startTime,
      parent: _scope.parent,
      metadata: {
        ...?_scope.metadata,
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
  }
}

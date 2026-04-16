import 'dart:async';

import 'package:meta/meta.dart';
import 'package:serverpod_log/serverpod_log.dart' as slog;

import '../../../generated/protocol.dart' as proto;
import '../../session.dart';
import '../session_log_keys.dart';

/// A [slog.LogWriter] that persists session-shaped scopes and their
/// child entries to the `serverpod_session_log` / `serverpod_log` /
/// `serverpod_query_log` / `serverpod_message_log` tables.
///
/// Consumes scope/entry metadata keyed by [SessionScopeKeys] and
/// [SessionEntryKeys], so any producer using that vocabulary gets
/// persistence.
@internal
class DatabaseLogWriter extends slog.LogWriter {
  /// Set via [attach]; while null, all operations are no-ops so the
  /// writer can sit in the chain before the database is up.
  Session? _internalSession;

  final Map<String, _SessionState> _sessions = {};

  /// In-flight DB write futures, drained by [close] before the pool is
  /// torn down.
  final Set<Future<Object?>> _inflight = {};

  /// Once true, new events are dropped; in-flight writes finish via
  /// [close]'s bounded drain.
  bool _closing = false;

  /// Upper bound on [close] drain. A stuck pool must not hang shutdown.
  static const _drainTimeout = Duration(seconds: 5);

  DatabaseLogWriter();

  /// Attaches the [Session] used to perform writes.
  void attach(Session session) {
    _internalSession = session;
  }

  @override
  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    final pending = _inflight.map((f) => f.catchError((_) => null)).toList();
    await Future.wait(pending).timeout(
      _drainTimeout,
      onTimeout: () => const <void>[],
    );
    _internalSession = null;
  }

  @override
  Future<void> openScope(slog.LogScope scope) async {
    final session = _internalSession;
    if (session == null || _closing) return;
    if (!_isSessionScope(scope)) return;
    if (_sessions.containsKey(scope.id)) return;

    final future = _insertOpenRow(session, scope);
    _sessions[scope.id] = _SessionState(future);

    // _log and _closeScope observe insert failures via the stored
    // future; silence here so openScope itself stays best-effort.
    await _track(future).catchError((_) => 0);
  }

  Future<int> _insertOpenRow(Session session, slog.LogScope scope) async {
    final row = _buildSessionRow(scope, isOpen: true);
    final inserted = await session.db.insertRow<proto.SessionLogEntry>(row);
    final id = inserted.id;
    if (id == null) {
      throw StateError('SessionLogEntry insert returned null id');
    }
    return id;
  }

  @override
  Future<void> log(slog.LogEntry entry) async {
    final session = _internalSession;
    if (session == null || _closing) return;
    final state = _sessions[entry.scope.id];
    if (state == null) return;

    final type = entry.metadata?[SessionEntryKeys.type] as String?;
    if (type == null) return;

    await _track(_log(session, entry, state, type));
  }

  Future<void> _log(
    Session session,
    slog.LogEntry entry,
    _SessionState state,
    String type,
  ) async {
    int sessionLogId;
    try {
      sessionLogId = await state.sessionLogId;
    } catch (_) {
      // Open failed; nothing to attach to.
      return;
    }

    // Order is assigned by the producer at call time so DB row order
    // matches caller order even when writes race downstream.
    final order = entry.metadata?[SessionEntryKeys.order] as int? ?? 0;
    switch (type) {
      case SessionEntryTypeValues.log:
        await session.db.insertRow<proto.LogEntry>(
          _buildLogRow(entry, sessionLogId, order),
        );
      case SessionEntryTypeValues.query:
        state.queryCount++;
        await session.db.insertRow<proto.QueryLogEntry>(
          _buildQueryRow(entry, sessionLogId, order),
        );
      case SessionEntryTypeValues.message:
        await session.db.insertRow<proto.MessageLogEntry>(
          _buildMessageRow(entry, sessionLogId, order),
        );
      default:
        return;
    }
  }

  @override
  Future<void> closeScope(
    slog.LogScope scope, {
    required bool success,
    required Duration duration,
    Object? error,
    StackTrace? stackTrace,
  }) async {
    final session = _internalSession;
    if (session == null || _closing) return;
    final state = _sessions.remove(scope.id);
    if (state == null) return;

    await _track(
      _closeScope(
        session,
        scope,
        state,
        duration: duration,
        error: error,
        stackTrace: stackTrace,
      ),
    );
  }

  Future<void> _closeScope(
    Session session,
    slog.LogScope scope,
    _SessionState state, {
    required Duration duration,
    Object? error,
    StackTrace? stackTrace,
  }) async {
    int sessionLogId;
    try {
      sessionLogId = await state.sessionLogId;
    } catch (_) {
      return;
    }

    final slowFlag = scope.metadata?[SessionScopeKeys.slow] as bool? ?? false;
    // Prefer the producer's count: state.queryCount only tracks
    // queries this writer persisted, which under-counts when query
    // logging is off.
    final numQueries =
        scope.metadata?[SessionScopeKeys.numQueries] as int? ??
        state.queryCount;
    final row = _buildSessionRow(
      scope,
      isOpen: false,
      id: sessionLogId,
      duration: duration.inMicroseconds / Duration.microsecondsPerSecond,
      numQueries: numQueries,
      slow: slowFlag,
      error: error?.toString(),
      stackTrace: stackTrace?.toString(),
    );
    await session.db.updateRow<proto.SessionLogEntry>(row);
  }

  Future<T> _track<T>(Future<T> work) async {
    _inflight.add(work);
    try {
      return await work;
    } finally {
      _inflight.remove(work);
    }
  }

  bool _isSessionScope(slog.LogScope scope) =>
      scope.metadata?[SessionScopeKeys.sessionType] != null;

  String _stringMeta(slog.LogScope scope, String key) =>
      scope.metadata?[key] as String? ?? '';

  String? _stringMetaOrNull(slog.LogScope scope, String key) =>
      scope.metadata?[key] as String?;

  proto.SessionLogEntry _buildSessionRow(
    slog.LogScope scope, {
    required bool isOpen,
    int? id,
    double? duration,
    int? numQueries,
    bool? slow,
    String? error,
    String? stackTrace,
  }) {
    final endpoint = _stringMetaOrNull(scope, SessionScopeKeys.endpoint);
    final method = _stringMetaOrNull(scope, SessionScopeKeys.method);
    final futureCall = _stringMetaOrNull(
      scope,
      SessionScopeKeys.futureCallName,
    );
    final userId = _stringMetaOrNull(
      scope,
      SessionScopeKeys.authenticatedUserId,
    );

    return proto.SessionLogEntry(
      id: id,
      serverId: _stringMeta(scope, SessionScopeKeys.serverId),
      time: scope.startTime,
      module: futureCall, // legacy: future calls populated module with name
      endpoint: endpoint,
      method: method,
      duration: duration,
      numQueries: numQueries,
      slow: slow,
      error: error,
      stackTrace: stackTrace,
      userId: userId,
      isOpen: isOpen,
      touched: DateTime.now(),
    );
  }

  proto.LogEntry _buildLogRow(
    slog.LogEntry entry,
    int sessionLogId,
    int order,
  ) {
    final m = entry.metadata ?? const {};
    return proto.LogEntry(
      sessionLogId: sessionLogId,
      serverId: _stringMeta(entry.scope, SessionScopeKeys.serverId),
      messageId: m[SessionEntryKeys.messageId] as int?,
      time: entry.time,
      logLevel: _toProtoLogLevel(entry.level),
      message: entry.message,
      error: entry.error?.toString(),
      stackTrace: entry.stackTrace?.toString(),
      order: order,
    );
  }

  proto.QueryLogEntry _buildQueryRow(
    slog.LogEntry entry,
    int sessionLogId,
    int order,
  ) {
    final m = entry.metadata ?? const {};
    return proto.QueryLogEntry(
      sessionLogId: sessionLogId,
      serverId: _stringMeta(entry.scope, SessionScopeKeys.serverId),
      messageId: m[SessionEntryKeys.messageId] as int?,
      query: entry.message,
      duration: (m[SessionEntryKeys.queryDuration] as num?)?.toDouble() ?? 0.0,
      numRows: m[SessionEntryKeys.queryNumRows] as int?,
      error: entry.error?.toString(),
      stackTrace: entry.stackTrace?.toString(),
      slow: m[SessionEntryKeys.querySlow] as bool? ?? false,
      order: order,
    );
  }

  proto.MessageLogEntry _buildMessageRow(
    slog.LogEntry entry,
    int sessionLogId,
    int order,
  ) {
    final m = entry.metadata ?? const {};
    return proto.MessageLogEntry(
      sessionLogId: sessionLogId,
      serverId: _stringMeta(entry.scope, SessionScopeKeys.serverId),
      messageId: m[SessionEntryKeys.messageId] as int? ?? 0,
      endpoint: m[SessionEntryKeys.messageEndpoint] as String? ?? '',
      messageName: m[SessionEntryKeys.messageName] as String? ?? '',
      duration:
          (m[SessionEntryKeys.messageDuration] as num?)?.toDouble() ?? 0.0,
      error: entry.error?.toString(),
      stackTrace: entry.stackTrace?.toString(),
      slow: m[SessionEntryKeys.messageSlow] as bool? ?? false,
      order: order,
    );
  }

  proto.LogLevel _toProtoLogLevel(slog.LogLevel level) => switch (level) {
    slog.LogLevel.debug => proto.LogLevel.debug,
    slog.LogLevel.info => proto.LogLevel.info,
    slog.LogLevel.warning => proto.LogLevel.warning,
    slog.LogLevel.error => proto.LogLevel.error,
    slog.LogLevel.fatal => proto.LogLevel.fatal,
  };
}

class _SessionState {
  _SessionState(this.sessionLogId) {
    // Pre-attach a handler so an insert rejection isn't flagged
    // unhandled before [_log]/[_closeScope] await it.
    sessionLogId.ignore();
  }

  /// Resolves to the inserted SessionLogEntry row id; awaited by log and
  /// closeScope before writing child rows / updating the parent.
  final Future<int> sessionLogId;

  int queryCount = 0;
}

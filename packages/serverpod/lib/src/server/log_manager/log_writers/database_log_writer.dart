import 'dart:async';

import 'package:meta/meta.dart';
import 'package:serverpod_log/serverpod_log.dart' as slog;

import '../../../generated/protocol.dart' as proto;
import '../../session.dart';
import '../session_log_keys.dart';

/// A [slog.LogWriter] that persists session-shaped scopes and their child
/// entries to the `serverpod_session_log` / `serverpod_log` /
/// `serverpod_query_log` / `serverpod_message_log` tables.
///
/// The writer is generic in its consumption of scope/entry metadata: it reads
/// [SessionScopeKeys] and [SessionEntryKeys] off `metadata` maps, so any
/// producer that follows the documented vocabulary (today
/// [SessionLogManager], potentially others later) gets persistence for free.
@internal
class DatabaseLogWriter extends slog.LogWriter {
  /// Internal session used to perform the writes. Set late via [attach];
  /// while null all operations are no-ops, letting the writer sit safely in
  /// the global chain before the database is initialised.
  Session? _internalSession;

  /// Per-scope state, keyed by [slog.LogScope.id].
  final Map<String, _SessionState> _sessions = {};

  /// In-flight DB write futures, tracked so [close] can drain them before the
  /// database pool is torn down. Each scope/log/closeScope entry registers
  /// itself here for the duration of its underlying query.
  final Set<Future<void>> _inflight = {};

  /// Once true, new events are dropped; in-flight writes are allowed to
  /// finish via [close]'s bounded drain. Prevents the writer from touching
  /// the pool while (or after) shutdown nulls it out.
  bool _closing = false;

  /// Upper bound on how long [close] waits for in-flight writes before giving
  /// up. A stuck pool must not be able to hang server shutdown.
  static const _drainTimeout = Duration(seconds: 5);

  DatabaseLogWriter();

  /// Attaches the [Session] used to perform writes. Until called, the writer
  /// silently drops every event so it can be installed in the writer chain
  /// before the database is up.
  void attach(Session session) {
    _internalSession = session;
  }

  @override
  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    // Drain writes that were already dispatched before shutdown so their
    // close rows reach the database; bounded so an unhealthy pool can't
    // block shutdown indefinitely. Errors on individual writes are expected
    // (the pool may be closing underneath us) and are swallowed.
    final pending = _inflight.map((f) => f.catchError((_) {})).toList();
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

    final state = _SessionState();
    _sessions[scope.id] = state;

    await _track(_openScope(session, scope, state));
  }

  Future<void> _openScope(
    Session session,
    slog.LogScope scope,
    _SessionState state,
  ) async {
    try {
      final row = _buildSessionRow(scope, isOpen: true);
      final inserted = await session.db.insertRow<proto.SessionLogEntry>(
        row,
      );
      final id = inserted.id;
      if (id == null) {
        state.sessionLogId.completeError(
          StateError('SessionLogEntry insert returned null id'),
        );
        return;
      }
      state.sessionLogId.complete(id);
    } catch (e, st) {
      state.sessionLogId.completeError(e, st);
      // Pre-attach a no-op handler so the rejection isn't flagged as
      // an unhandled async error before [_log]/[_closeScope] get a
      // chance to await. `ignore()` doesn't consume the error -
      // subsequent awaits still see it - but it satisfies Dart's
      // "was a handler attached?" check at microtask time.
      state.sessionLogId.future.ignore();
    }
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
      sessionLogId = await state.sessionLogId.future;
    } catch (_) {
      // Open failed; nothing to attach to.
      return;
    }

    // Order is assigned by the producer at call time and carried on
    // metadata; otherwise we'd record arrival order, which doesn't match
    // caller order when writes race through the chain.
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
        // Unknown discriminator; skip rather than guess.
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
      sessionLogId = await state.sessionLogId.future;
    } catch (_) {
      return;
    }

    final slowFlag = scope.metadata?[SessionScopeKeys.slow] as bool? ?? false;
    // Total query count comes from SessionLogManager via scope metadata
    // (counted unconditionally there); state.queryCount only tracks the
    // queries this writer actually persisted, which is wrong when query
    // logging is turned off.
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

  Future<void> _track(Future<void> work) async {
    _inflight.add(work);
    try {
      await work;
    } finally {
      _inflight.remove(work);
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

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
  /// Resolves to the inserted SessionLogEntry row id once openScope's insert
  /// completes. log/closeScope await this before persisting child rows /
  /// updating the parent.
  final Completer<int> sessionLogId = Completer<int>();

  /// Number of query entries seen, persisted on close as numQueries.
  int queryCount = 0;
}

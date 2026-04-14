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
  /// Internal session used to perform the writes.
  final Session _internalSession;

  /// Per-scope state, keyed by [slog.LogScope.id].
  final Map<String, _SessionState> _sessions = {};

  DatabaseLogWriter({required Session internalSession})
    : _internalSession = internalSession;

  @override
  Future<void> openScope(slog.LogScope scope) async {
    if (!_isSessionScope(scope)) return;
    if (_sessions.containsKey(scope.id)) return;

    final state = _SessionState();
    _sessions[scope.id] = state;

    try {
      final row = _buildSessionRow(scope, isOpen: true);
      final inserted = await _internalSession.db
          .insertRow<proto.SessionLogEntry>(
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
    }
  }

  @override
  Future<void> log(slog.LogEntry entry) async {
    final state = _sessions[entry.scope.id];
    if (state == null) return;

    final type = entry.metadata?[SessionEntryKeys.type] as String?;
    if (type == null) return;

    int sessionLogId;
    try {
      sessionLogId = await state.sessionLogId.future;
    } catch (_) {
      // Open failed; nothing to attach to.
      return;
    }

    state.entryOrder++;
    switch (type) {
      case SessionEntryTypeValues.log:
        await _internalSession.db.insertRow<proto.LogEntry>(
          _buildLogRow(entry, sessionLogId, state.entryOrder),
        );
      case SessionEntryTypeValues.query:
        state.queryCount++;
        await _internalSession.db.insertRow<proto.QueryLogEntry>(
          _buildQueryRow(entry, sessionLogId, state.entryOrder),
        );
      case SessionEntryTypeValues.message:
        await _internalSession.db.insertRow<proto.MessageLogEntry>(
          _buildMessageRow(entry, sessionLogId, state.entryOrder),
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
    final state = _sessions.remove(scope.id);
    if (state == null) return;

    int sessionLogId;
    try {
      sessionLogId = await state.sessionLogId.future;
    } catch (_) {
      return;
    }

    final slowFlag = scope.metadata?[SessionScopeKeys.slow] as bool? ?? false;
    final row = _buildSessionRow(
      scope,
      isOpen: false,
      id: sessionLogId,
      duration: duration.inMicroseconds / Duration.microsecondsPerSecond,
      numQueries: state.queryCount,
      slow: slowFlag,
      error: error?.toString(),
      stackTrace: stackTrace?.toString(),
    );
    await _internalSession.db.updateRow<proto.SessionLogEntry>(row);
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
    return proto.LogEntry(
      sessionLogId: sessionLogId,
      serverId: _stringMeta(entry.scope, SessionScopeKeys.serverId),
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

  /// Counter for ordering child rows in time of arrival.
  int entryOrder = 0;

  /// Number of query entries seen, persisted on close as numQueries.
  int queryCount = 0;
}

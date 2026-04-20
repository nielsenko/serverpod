import 'dart:io';

import 'package:meta/meta.dart';
import 'package:serverpod_shared/serverpod_shared.dart';

import '../../../generated/protocol.dart' as protocol;
import '../session_log_keys.dart';

/// Emits session-shaped scopes and child entries as single-line JSON
/// to stdout (stderr for errors/fatal). Every session opens and closes
/// with a [protocol.SessionLogEntry] row; log/query/message entries emit
/// the corresponding proto rows keyed by a synthetic per-scope
/// `sessionLogId` derived from the scope id hash.
@internal
class JsonStdOutLogWriter extends LogWriter {
  /// Per-scope synthetic session log ids so child rows can reference
  /// the same id as the opening row.
  final Map<String, int> _sessionLogIds = {};

  JsonStdOutLogWriter();

  @override
  Future<void> openScope(LogScope scope) async {
    if (!_isSessionScope(scope)) return;
    final id = _sessionLogIds.putIfAbsent(scope.id, () => scope.id.hashCode);
    _emit(_buildSessionRow(scope, isOpen: true, id: id));
  }

  @override
  Future<void> log(LogEntry entry) async {
    final sessionLogId = _sessionLogIds[entry.scope.id];
    if (sessionLogId == null) return;

    final type = entry.metadata?[SessionEntryKeys.type] as String?;
    if (type == null) return;

    final order = entry.metadata?[SessionEntryKeys.order] as int? ?? 0;
    switch (type) {
      case SessionEntryTypeValues.log:
        _emit(_buildLogRow(entry, sessionLogId, order));
      case SessionEntryTypeValues.query:
        _emit(_buildQueryRow(entry, sessionLogId, order));
      case SessionEntryTypeValues.message:
        _emit(_buildMessageRow(entry, sessionLogId, order));
    }
  }

  @override
  Future<void> closeScope(
    LogScope scope, {
    required bool success,
    required Duration duration,
    Object? error,
    StackTrace? stackTrace,
  }) async {
    final id = _sessionLogIds.remove(scope.id);
    if (id == null) return;

    final slowFlag = scope.metadata?[SessionScopeKeys.slow] as bool? ?? false;
    final numQueries = scope.metadata?[SessionScopeKeys.numQueries] as int?;
    _emit(
      _buildSessionRow(
        scope,
        isOpen: false,
        id: id,
        duration: duration.inMicroseconds / Duration.microsecondsPerSecond,
        numQueries: numQueries,
        slow: slowFlag,
        error: error?.toString(),
        stackTrace: stackTrace?.toString(),
      ),
    );
  }

  void _emit(Object row) {
    final line = row.toString();
    final isError = switch (row) {
      protocol.SessionLogEntry(:final error) => error != null,
      protocol.LogEntry(:final error, :final logLevel) =>
        error != null ||
            logLevel == protocol.LogLevel.error ||
            logLevel == protocol.LogLevel.fatal,
      protocol.QueryLogEntry(:final error) => error != null,
      protocol.MessageLogEntry(:final error) => error != null,
      _ => false,
    };
    if (isError) {
      stderr.writeln(line);
    } else {
      stdout.writeln(line);
    }
  }

  bool _isSessionScope(LogScope scope) =>
      scope.metadata?[SessionScopeKeys.sessionType] != null;

  String _stringMeta(LogScope scope, String key) =>
      scope.metadata?[key] as String? ?? '';

  String? _stringMetaOrNull(LogScope scope, String key) =>
      scope.metadata?[key] as String?;

  protocol.SessionLogEntry _buildSessionRow(
    LogScope scope, {
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

    return protocol.SessionLogEntry(
      id: id,
      serverId: _stringMeta(scope, SessionScopeKeys.serverId),
      time: scope.startTime,
      module: futureCall,
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

  protocol.LogEntry _buildLogRow(
    LogEntry entry,
    int sessionLogId,
    int order,
  ) {
    final m = entry.metadata ?? const {};
    return protocol.LogEntry(
      sessionLogId: sessionLogId,
      serverId: _stringMeta(entry.scope, SessionScopeKeys.serverId),
      messageId: m[SessionEntryKeys.messageId] as int?,
      time: entry.time,
      logLevel: _toProtocolLogLevel(entry.level),
      message: entry.message,
      error: entry.error?.toString(),
      stackTrace: entry.stackTrace?.toString(),
      order: order,
    );
  }

  protocol.QueryLogEntry _buildQueryRow(
    LogEntry entry,
    int sessionLogId,
    int order,
  ) {
    final m = entry.metadata ?? const {};
    return protocol.QueryLogEntry(
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

  protocol.MessageLogEntry _buildMessageRow(
    LogEntry entry,
    int sessionLogId,
    int order,
  ) {
    final m = entry.metadata ?? const {};
    return protocol.MessageLogEntry(
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

  protocol.LogLevel _toProtocolLogLevel(LogLevel level) => switch (level) {
    LogLevel.debug => protocol.LogLevel.debug,
    LogLevel.info => protocol.LogLevel.info,
    LogLevel.warning => protocol.LogLevel.warning,
    LogLevel.error => protocol.LogLevel.error,
    LogLevel.fatal => protocol.LogLevel.fatal,
  };
}

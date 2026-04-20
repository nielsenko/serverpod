import 'dart:io';

import 'package:meta/meta.dart';
import 'package:serverpod_shared/serverpod_shared.dart' as slog;

import '../session_log_keys.dart';

/// A [slog.LogWriter] that emits session-tagged scopes and child entries
/// as aligned columnar text (TIME / ID / TYPE / CONTEXT / DETAILS) to
/// stdout, matching the legacy pre-revamp `TextStdOutLogWriter` format.
///
/// Only handles events whose scope carries [SessionScopeKeys.sessionType].
/// Non-session events are ignored - those belong on a framework writer.
@internal
class SessionTextStdOutLogWriter extends slog.LogWriter {
  static bool _headersWritten = false;

  /// Synthetic session log id per scope, stable within a process and
  /// shared across the scope's child rows.
  final Map<String, int> _logIds = {};

  SessionTextStdOutLogWriter() {
    if (!_headersWritten) {
      _writeHeaders();
      _headersWritten = true;
    }
  }

  @override
  Future<void> openScope(slog.LogScope scope) async {
    if (!_isSessionScope(scope)) return;
    final logId = _logIds.putIfAbsent(scope.id, () => scope.id.hashCode);

    // Only streaming sessions log an explicit open row; other session
    // types are reported as a single closing row.
    final type = scope.metadata?[SessionScopeKeys.sessionType] as String?;
    if (type != SessionTypeValues.stream &&
        type != SessionTypeValues.methodStream) {
      return;
    }

    _writeFormattedLog(
      'STREAM OPEN',
      context: _endpointMethod(scope),
      id: logId,
      fields: {
        'user': scope.metadata?[SessionScopeKeys.authenticatedUserId],
      },
      time: scope.startTime,
    );
  }

  @override
  Future<void> log(slog.LogEntry entry) async {
    final logId = _logIds[entry.scope.id];
    if (logId == null) return;

    final type = entry.metadata?[SessionEntryKeys.type] as String?;
    final messageId = entry.metadata?[SessionEntryKeys.messageId] as int?;
    switch (type) {
      case SessionEntryTypeValues.log:
        _writeFormattedLog(
          'LOG',
          context: entry.level.name.toUpperCase(),
          id: logId,
          fields: {
            'messageId': ?messageId,
            'message': entry.message,
          },
          error: entry.error?.toString(),
          stackTrace: entry.stackTrace?.toString(),
          toStdErr: _isEntryError(entry),
          time: entry.time,
        );
      case SessionEntryTypeValues.query:
        final m = entry.metadata ?? const {};
        _writeFormattedLog(
          'QUERY',
          context: null,
          id: logId,
          fields: {
            'messageId': ?messageId,
            'duration': _printDuration(
              _secondsToDuration(
                (m[SessionEntryKeys.queryDuration] as num?)?.toDouble(),
              ),
            ),
            'query': entry.message,
          },
          error: entry.error?.toString(),
          stackTrace: entry.stackTrace?.toString(),
          time: entry.time,
        );
      case SessionEntryTypeValues.message:
        final m = entry.metadata ?? const {};
        _writeFormattedLog(
          'STREAM MESSAGE',
          context: m[SessionEntryKeys.messageEndpoint] as String?,
          id: logId,
          fields: {
            'id': m[SessionEntryKeys.messageId],
            'name': m[SessionEntryKeys.messageName],
          },
          error: entry.error?.toString(),
          stackTrace: entry.stackTrace?.toString(),
          time: entry.time,
        );
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
    final logId = _logIds.remove(scope.id);
    if (logId == null) return;

    final type = scope.metadata?[SessionScopeKeys.sessionType] as String?;
    final userId =
        scope.metadata?[SessionScopeKeys.authenticatedUserId] as String?;
    final numQueries = scope.metadata?[SessionScopeKeys.numQueries] as int?;
    final durStr = _printDuration(duration);

    final (line, context) = switch (type) {
      SessionTypeValues.method => ('METHOD', _endpointMethod(scope)),
      SessionTypeValues.futureCall => (
        'FUTURE',
        scope.metadata?[SessionScopeKeys.futureCallName] as String?,
      ),
      SessionTypeValues.web => (
        'WEB',
        scope.metadata?[SessionScopeKeys.endpoint] as String?,
      ),
      SessionTypeValues.stream || SessionTypeValues.methodStream => (
        'STREAM CLOSED',
        _endpointMethod(scope),
      ),
      SessionTypeValues.internal => ('INTERNAL', null),
      _ => ('UNKNOWN', null),
    };

    _writeFormattedLog(
      line,
      context: context,
      id: logId,
      fields: {
        if (type == SessionTypeValues.method ||
            type == SessionTypeValues.web ||
            type == SessionTypeValues.stream ||
            type == SessionTypeValues.methodStream)
          'user': userId,
        'queries': numQueries,
        'duration': durStr,
      },
      error: error?.toString(),
      stackTrace: stackTrace?.toString(),
    );
  }

  bool _isSessionScope(slog.LogScope scope) =>
      scope.metadata?[SessionScopeKeys.sessionType] != null;

  String? _endpointMethod(slog.LogScope scope) {
    final endpoint = scope.metadata?[SessionScopeKeys.endpoint] as String?;
    final method = scope.metadata?[SessionScopeKeys.method] as String?;
    if (endpoint == null) return null;
    if (method == null) return endpoint;
    return '$endpoint.$method';
  }

  bool _isEntryError(slog.LogEntry entry) =>
      entry.error != null ||
      entry.level == slog.LogLevel.error ||
      entry.level == slog.LogLevel.fatal;

  static void _writeHeaders() {
    stdout.writeln(
      '${'TIME'.padRight(27)}'
      ' ${'ID'.padRight(10)}'
      ' ${'TYPE'.padRight(14)}'
      ' ${'CONTEXT'.padRight(25)}'
      'DETAILS',
    );
    stdout.writeln(
      '${'-' * 27}'
      ' ${'-' * 10}'
      ' ${'-' * 14}'
      ' ${'-' * 24}'
      ' ${'-' * 30}',
    );
  }

  static void _writeFormattedLog(
    String type, {
    required String? context,
    required int id,
    required Map<String, Object?> fields,
    String? error,
    String? stackTrace,
    bool toStdErr = false,
    DateTime? time,
  }) {
    final now = (time ?? DateTime.now()).toUtc();
    final visibleFields = fields.entries.where((e) => e.value != null);
    _write(
      type,
      context: context,
      id: id,
      message: visibleFields.isNotEmpty
          ? visibleFields.map((e) => '${e.key}=${e.value}').join(', ')
          : '',
      now: now,
      toStdErr: toStdErr,
    );
    if (error != null) {
      _write(
        'ERROR',
        context: 'n/a',
        id: id,
        message: error,
        now: now,
        toStdErr: true,
      );
      if (stackTrace != null) {
        _write(
          'STACK TRACE',
          context: 'n/a',
          id: id,
          message: stackTrace,
          now: now,
          toStdErr: true,
        );
      }
    }
  }

  static void _write(
    String type, {
    required String? context,
    required int id,
    required String message,
    required DateTime now,
    required bool toStdErr,
  }) {
    final line = StringBuffer();
    line.write('$id'.padLeft(10));
    line.write(' $type'.padRight(15));
    line.write(' ${context ?? 'n/a'}'.padRight(25));
    line.write(' $message');
    if (toStdErr) {
      stderr.writeln('$now ${line.toString()}');
    } else {
      stdout.writeln('$now ${line.toString()}');
    }
  }

  static Duration? _secondsToDuration(double? seconds) {
    if (seconds == null) return null;
    final micros = seconds * Duration.microsecondsPerSecond;
    return Duration(microseconds: micros.round());
  }

  static String _printDuration(Duration? duration) {
    if (duration == null) return 'n/a';
    final micros = duration.inMicroseconds;
    // ignore: unnecessary_brace_in_string_interps
    if (micros < 1000) return '${micros}\u00B5s';
    if (micros < Duration.microsecondsPerSecond) {
      return _formatNumber(micros / 1000, 'ms');
    }
    return _formatNumber(micros / Duration.microsecondsPerSecond, 's');
  }

  static String _formatNumber(double value, String suffix) {
    String formatted;
    if (value >= 100) {
      formatted = value.toStringAsFixed(0);
    } else if (value >= 10) {
      formatted = value.toStringAsFixed(1);
    } else {
      formatted = value.toStringAsFixed(2);
    }
    if (formatted.contains('.')) {
      formatted = formatted
          .replaceFirst(RegExp(r'0+$'), '')
          .replaceFirst(RegExp(r'\.$'), '');
    }
    return '$formatted$suffix';
  }
}

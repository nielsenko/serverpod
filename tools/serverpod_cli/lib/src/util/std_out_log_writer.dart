import 'dart:io';

import 'package:cli_tools/cli_tools.dart' as cli;
// ignore: implementation_imports
import 'package:cli_tools/src/logger/helpers/progress.dart';
import 'package:serverpod_log/serverpod_log.dart';

/// Metadata key used to pass [cli.LogType] through [LogEntry.metadata].
const logTypeKey = 'serverpod:logType';

/// A [LogWriter] that delegates to a cli_tools [cli.StdOutLogger] for
/// terminal formatting, including [cli.LogType]-aware output (bullets,
/// headers, boxes, etc.) and braille progress spinners.
///
/// [cli.LogType] is read from [LogEntry.metadata] using [logTypeKey].
class StdOutLogWriter extends LogWriter {
  final cli.StdOutLogger _logger;
  Progress? _activeProgress;

  StdOutLogWriter({
    cli.LogLevel logLevel = cli.LogLevel.info,
    Map<String, String>? replacements,
  }) : _logger = cli.StdOutLogger(logLevel, replacements: replacements);

  @override
  Future<void> log(LogEntry entry) async {
    final cliLevel = _mapLevel(entry.level);
    final type =
        entry.metadata?[logTypeKey] as cli.LogType? ?? cli.TextLogType.normal;

    _stopProgress();
    _logger.log(entry.message, cliLevel, type: type);
    _redrawProgress();
  }

  @override
  Future<void> openScope(LogScope scope) async {
    _stopProgress();

    final progress = Progress(scope.label, stdout);
    _logger.trackedAnimationInProgress = progress;
    _activeProgress = progress;
  }

  @override
  Future<void> closeScope(
    LogScope scope, {
    required bool success,
    required Duration duration,
    Object? error,
    StackTrace? stackTrace,
  }) async {
    _logger.trackedAnimationInProgress = null;
    final p = _activeProgress;
    _activeProgress = null;
    success ? p?.complete() : p?.fail();
  }

  void _stopProgress() {
    if (_activeProgress != null) {
      _activeProgress!.stopAnimation();
      stdout.write('\n');
      _logger.trackedAnimationInProgress = null;
    }
  }

  void _redrawProgress() {
    // The timer on Progress handles redrawing automatically.
  }

  static cli.LogLevel _mapLevel(LogLevel level) => switch (level) {
    LogLevel.debug => cli.LogLevel.debug,
    LogLevel.info => cli.LogLevel.info,
    LogLevel.warning => cli.LogLevel.warning,
    LogLevel.error || LogLevel.fatal => cli.LogLevel.error,
  };
}

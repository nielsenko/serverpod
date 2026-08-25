import 'dart:async';
import 'dart:io';

import 'package:serverpod_cli/src/runner/log_codec.dart';
import 'package:serverpod_cli/src/runner/runner_client.dart';
import 'package:serverpod_cli/src/runner/runner_event.dart';
import 'package:serverpod_cli/src/runner/runner_snapshot.dart';
import 'package:serverpod_shared/log.dart';

/// Streams a runner's output as plain text, for `--no-tui`.
///
/// This is what CI, piped output, and `docker logs`-style workflows use: no
/// alternate screen, no cursor control, one line per entry so `grep` and a
/// scrollback buffer both work.
///
/// Returns the exit code to leave with. Ctrl+C detaches, leaving the runner
/// running; the stack is stopped with `serverpod stop`.
Future<int> attachWithLogStream(
  String socketPath, {
  IOSink? out,
  Stream<ProcessSignal>? interrupts,
}) async {
  final sink = out ?? stdout;
  final client = RunnerClient(socketPath: socketPath);
  await client.attach();

  // The snapshot first, so a session attached to a runner that has been up for
  // hours starts with what it missed rather than the next line only.
  final snapshot = client.snapshot();
  for (final line in snapshot.serverLines) {
    sink.writeln(line);
  }
  for (final entry in snapshot.serverEntries) {
    sink.writeln(_formatHistoryEntry(entry));
  }
  for (final entry in snapshot.flutterLines.entries) {
    for (final line in entry.value) {
      sink.writeln('[${entry.key}] $line');
    }
  }
  for (final active in snapshot.activeOperations) {
    sink.writeln('... ${active.operation.label} (in progress)');
  }
  sink.writeln(_stageLine(snapshot.stage));

  final done = Completer<int>();
  final signals = interrupts ?? ProcessSignal.sigint.watch();
  final signalSub = signals.listen((_) {
    if (!done.isCompleted) done.complete(0);
  });

  final eventSub = client.events.listen((event) {
    final line = _formatEvent(event);
    if (line != null) sink.writeln(line);
    // The runner said it is going away on purpose, so this session is over.
    // Without it a `serverpod start --no-tui` in CI reattaches forever after
    // the stack it was watching has stopped.
    if (event case StageChangedEvent(stage: RunnerStage.stopping)) {
      if (!done.isCompleted) done.complete(0);
    }
  });

  final connectionSub = client.connectionChanges.listen((connected) {
    sink.writeln(
      connected
          ? '--- reattached to the runner ---'
          : '--- lost the runner, reattaching ---',
    );
  });

  final exitCode = await done.future;
  await signalSub.cancel();
  await eventSub.cancel();
  await connectionSub.cancel();
  await client.close();
  return exitCode;
}

String _stageLine(RunnerStage stage) => switch (stage) {
  RunnerStage.starting => '--- runner starting ---',
  RunnerStage.running => '--- server running ---',
  RunnerStage.degraded =>
    '--- server not running: the project failed to build ---',
  RunnerStage.stopping => '--- runner stopping ---',
};

String? _formatEvent(RunnerEvent event) => switch (event) {
  ServerLogEvent(:final entry) => formatLogEntryLine(entry),
  // The pod's own stdout, already a finished line.
  ServerLineEvent(:final line) => line,
  FlutterLineEvent(:final appId, :final line) => '[$appId] $line',
  FlutterLogEntryEvent(:final appId, :final entry) =>
    '[$appId] ${formatLogEntryLine(entry)}',
  OperationStartedEvent(:final operation) => '... ${operation.label}',
  OperationCompletedEvent(:final operation) =>
    '${operation.success ? '✓' : '✗'} ${operation.label} '
        '(${operation.duration.inMilliseconds}ms)',
  StageChangedEvent(:final stage) => _stageLine(stage),
  FlutterAppStateEvent(:final appId, :final running, :final url) =>
    '[$appId] ${running ? 'running${url == null ? '' : ' at $url'}' : 'stopped'}',
  // Neither changes what a log reader sees.
  FlutterAppsChangedEvent() || ManifestChangedEvent() => null,
};

String _formatHistoryEntry(Object entry) => switch (entry) {
  LogEntry() => formatLogEntryLine(entry),
  _ => entry.toString(),
};


import 'dart:async';
import 'dart:io';

import 'package:serverpod_cli/src/runner/log_codec.dart';
import 'package:serverpod_cli/src/runner/runner_client.dart';
import 'package:serverpod_cli/src/runner/runner_event.dart';
import 'package:serverpod_cli/src/runner/runner_snapshot.dart';
import 'package:serverpod_shared/log.dart';
import 'package:serverpod_tui/serverpod_tui.dart' show CompletedOperation;

/// Streams a runner's output as plain text, for `--no-tui`.
///
/// This is what CI, piped output, and `docker logs`-style workflows use: no
/// alternate screen, no cursor control, one line per entry so `grep` and a
/// scrollback buffer both work. The account is the one the terminal UI shows:
/// the CLI's own entries and the pod's structured log, in the order they
/// happened.
///
/// Returns the exit code to leave with: the runner's own when it announces
/// that it is stopping, 1 for a stack that failed to build and has no way to
/// rebuild itself or a runner that stopped answering, and 0 on Ctrl+C, which
/// detaches and leaves the runner running - the stack is stopped with
/// `serverpod runner stop`.
///
/// [reconnectDeadline] bounds how long a lost runner is waited for. Unlike the
/// terminal UI, which reconnects for as long as a user leaves it open, nobody
/// is watching this: a runner that was killed outright announces nothing, and
/// waiting on it forever hangs the job that ran this.
Future<int> attachWithLogStream(
  String socketPath, {
  IOSink? out,
  Stream<ProcessSignal>? interrupts,
  Duration? waitForRunner,
  Duration reconnectDeadline = const Duration(seconds: 10),
}) async {
  final sink = out ?? stdout;
  final client = RunnerClient(
    socketPath: socketPath,
    reconnectDeadline: reconnectDeadline,
  );
  await client.attach(waitFor: waitForRunner);

  final history = client.history;
  for (final entry in history.serverEntries) {
    sink.writeln(formatHistoryEntry(entry));
  }
  for (final appId in history.flutterLines.keys) {
    for (final line in history.flutterLines[appId]!) {
      sink.writeln('[$appId] $line');
    }
  }
  for (final operation in history.activeOperations.values) {
    sink.writeln('... ${operation.label} (in progress)');
  }
  sink.writeln(_stageLine(client.stage));

  final done = Completer<int>();

  void leaveIfUnrecoverable(RunnerStage stage) {
    if (stage != RunnerStage.degraded || client.watchModeEnabled) return;
    if (done.isCompleted) return;
    // The runner stays up for a client to rebuild from, as `--no-attach`
    // also reports; leaving without saying so strands it in a session
    // nobody is watching.
    sink.writeln(
      '--- nothing will rebuild it from here: the runner is still up, '
      'rebuild it from `serverpod runner attach` once the errors are fixed, '
      'or stop it with `serverpod runner stop` ---',
    );
    done.complete(1);
  }

  leaveIfUnrecoverable(client.stage);

  unawaited(
    client.gone.then((_) {
      if (done.isCompleted) return;
      sink.writeln('--- the runner is gone ---');
      done.complete(1);
    }),
  );

  final signals = interrupts ?? ProcessSignal.sigint.watch();
  final signalSub = signals.listen((_) {
    if (!done.isCompleted) done.complete(0);
  });

  final eventSub = client.events.listen((event) {
    final line = _formatEvent(event);
    if (line != null) sink.writeln(line);
    if (event case StageChangedEvent(:final stage, :final exitCode)) {
      if (stage == RunnerStage.stopping) {
        if (!done.isCompleted) done.complete(exitCode ?? 0);
      } else {
        leaveIfUnrecoverable(stage);
      }
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
  // Raw pod output, rendered unless the runner marked it as the text form of
  // an entry that arrives on its own. The unmarked ones - `print`, a crash,
  // anything from before the structured log was live - are the only copy.
  ServerLineEvent(:final line, :final duplicatesEntry) =>
    duplicatesEntry ? null : line,
  FlutterLineEvent(:final appId, :final line) => '[$appId] $line',
  FlutterLogEntryEvent(:final appId, :final entry) =>
    '[$appId] ${formatLogEntryLine(entry)}',
  OperationStartedEvent(:final operation) => '... ${operation.label}',
  OperationCompletedEvent(:final operation) => _completedOperationLine(
    operation,
  ),
  StageChangedEvent(:final stage) => _stageLine(stage),
  FlutterAppStateEvent(:final appId, :final running, :final url) =>
    '[$appId] ${running ? 'running${url == null ? '' : ' at $url'}' : 'stopped'}',
  // None of these changes what a log reader sees.
  FlutterAppsChangedEvent() ||
  ManifestChangedEvent() ||
  OperationsDiscardedEvent() => null,
};

/// One retained history entry as a line, rendered the way the live event for
/// the same thing is.
///
/// [CompletedOperation] has to be named: it carries no meaningful `toString`,
/// so a replayed backlog printed `Instance of 'CompletedOperation'` where the
/// live stream showed the operation and its duration.
String formatHistoryEntry(Object entry) => switch (entry) {
  LogEntry() => formatLogEntryLine(entry),
  CompletedOperation() => _completedOperationLine(entry),
  _ => entry.toString(),
};

String _completedOperationLine(CompletedOperation operation) =>
    '${operation.success ? '✓' : '✗'} ${operation.label} '
    '(${operation.duration.inMilliseconds}ms)';

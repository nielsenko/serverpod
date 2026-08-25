import 'dart:async';
import 'dart:io';

import 'package:serverpod_cli/src/runner/migration_result.dart';
import 'package:serverpod_cli/src/runner/runner_client.dart';
import 'package:serverpod_cli/src/runner/runner_event.dart';
import 'package:serverpod_cli/src/runner/runner_snapshot.dart';
import 'package:serverpod_cli/src/runner/runner_socket_server.dart';
import 'package:serverpod_shared/log.dart';
import 'package:test/test.dart';

import '../test_util/fake_runner_api.dart';

void main() {
  group('Given a runner serving the attach socket,', () {
    late Directory tempDir;
    late RunnerSocketServer server;
    late FakeRunnerApi runner;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('rct');
      server = RunnerSocketServer(serverDir: tempDir.path);
      await server.start();
      runner = FakeRunnerApi();
      server.connect(runner);
    });

    tearDown(() async {
      await server.close();
      if (!runner.eventController.isClosed) {
        await runner.eventController.close();
      }
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {
        // Already gone.
      }
    });

    test(
      'when a client attaches, '
      'then the snapshot is materialized into its history.',
      () async {
        runner
          ..stage = RunnerStage.running
          ..logHistory = [
            LogEntry(
              time: DateTime.utc(2026, 8, 25),
              level: LogLevel.info,
              message: 'Server running.',
              scope: LogScope.root('server'),
            ),
          ]
          ..flutterAppIds = ['admin']
          ..flutterLogs = {
            'admin': ['app line'],
          };

        final client = RunnerClient(socketPath: server.socketPath);
        addTearDown(client.close);
        await client.connect();

        expect(client.stage, RunnerStage.running);
        expect(client.history.serverEntries, hasLength(1));
        expect(
          (client.history.serverEntries.first as LogEntry).message,
          'Server running.',
        );
        expect(client.history.flutterLinesFor('admin'), ['app line']);
        expect(client.flutterApps.single.id, 'admin');
      },
    );

    test(
      'when the runner emits a log entry, '
      'then it lands in the client history.',
      () async {
        final client = RunnerClient(socketPath: server.socketPath);
        addTearDown(client.close);
        await client.connect();

        runner.emit(
          ServerLogEvent(
            LogEntry(
              time: DateTime.utc(2026, 8, 25),
              level: LogLevel.error,
              message: 'Something broke.',
              scope: LogScope.root('server'),
            ),
          ),
        );
        await _waitFor(() => client.history.serverEntries.isNotEmpty);

        expect(
          (client.history.serverEntries.single as LogEntry).message,
          'Something broke.',
        );
      },
    );

    test(
      'when the runner reports a stage change, '
      'then the client mirrors it.',
      () async {
        final client = RunnerClient(socketPath: server.socketPath);
        addTearDown(client.close);
        await client.connect();

        runner.emit(
          const StageChangedEvent(RunnerStage.degraded, isRunning: false),
        );
        await _waitFor(() => client.stage == RunnerStage.degraded);

        expect(client.isRunning, isFalse);
      },
    );

    test(
      'when the client issues a command, '
      'then the runner runs it.',
      () async {
        var restarts = 0;
        runner.onHotRestart = () async => restarts++;

        final client = RunnerClient(socketPath: server.socketPath);
        addTearDown(client.close);
        await client.connect();

        await client.hotRestart();

        expect(restarts, 1);
      },
    );

    test(
      'when a migration stops for warnings, '
      'then the client sees the flag rather than a prompt.',
      () async {
        runner.onCreateMigration = ({String? tag, bool force = false}) async =>
            const MigrationResult(
              message: 'aborted',
              isError: true,
              abortedForWarnings: true,
            );

        final client = RunnerClient(socketPath: server.socketPath);
        addTearDown(client.close);
        await client.connect();

        final result = await client.createMigration();

        expect(result.isError, isTrue);
        expect(result.abortedForWarnings, isTrue);
      },
    );

    test(
      'when the runner restarts under the client, '
      'then the client reattaches and reloads the new snapshot.',
      () async {
        final client = RunnerClient(
          socketPath: server.socketPath,
          reconnectDelay: const Duration(milliseconds: 20),
        );
        addTearDown(client.close);
        await client.connect();
        expect(client.history.serverEntries, isEmpty);

        // The runner goes away and a new one takes over the same socket, which
        // is exactly what `serverpod stop` followed by `serverpod start` does.
        await server.close();
        await runner.eventController.close();

        final restarted = RunnerSocketServer(serverDir: tempDir.path);
        await restarted.start();
        addTearDown(restarted.close);
        final newRunner = FakeRunnerApi()
          ..logHistory = [
            LogEntry(
              time: DateTime.utc(2026, 8, 25),
              level: LogLevel.info,
              message: 'Fresh runner.',
              scope: LogScope.root('server'),
            ),
          ];
        addTearDown(newRunner.eventController.close);
        restarted.connect(newRunner);

        await _waitFor(() => client.isConnected);

        expect(
          (client.history.serverEntries.single as LogEntry).message,
          'Fresh runner.',
        );
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'when nothing is listening, '
      'then the first attach reports it rather than retrying silently.',
      () async {
        final client = RunnerClient(
          socketPath: '${tempDir.path}/absent.sock',
        );
        addTearDown(client.close);

        await expectLater(
          client.connect(),
          throwsA(isA<RunnerUnreachableException>()),
        );
      },
    );
  });
}

/// Polls [condition] until it holds.
///
/// Events cross a real socket here, so how many event-loop turns they take is
/// not something a test can assume - `pumpEventQueue` is not a barrier for
/// pending I/O.
Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Condition was not met within $timeout.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

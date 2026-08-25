import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:serverpod_cli/src/runner/runner_manifest.dart';
import 'package:serverpod_cli/src/runner/runner_manifest_publisher.dart';
import 'package:serverpod_cli/src/runner/runner_paths.dart';
import 'package:test/test.dart';

RunnerManifest _manifest({
  int pid = 4242,
  RunnerVmServiceUris? vmService,
  RunnerServerUris? servers,
  RunnerDocker? docker,
  RunnerConfig? config,
}) => RunnerManifest(
  pid: pid,
  sockets: const RunnerSockets(
    tui: '.dart_tool/serverpod/tui.sock',
    mcp: '.dart_tool/serverpod/mcp.sock',
  ),
  vmService: vmService,
  servers: servers,
  docker: docker,
  config:
      config ?? const RunnerConfig(watch: true, flutter: true, serverArgs: []),
);

void main() {
  group('Given a runner manifest,', () {
    test(
      'when it is encoded and decoded, '
      'then every published field survives the round trip.',
      () {
        final original = _manifest(
          vmService: const RunnerVmServiceUris(
            proxy: 'http://127.0.0.1:51234/abc=/',
          ),
          servers: const RunnerServerUris(
            api: 'http://localhost:8080',
            insights: 'http://localhost:8081',
            web: 'http://localhost:8082',
          ),
          docker: const RunnerDocker(
            startedByRunner: true,
            project: 'myproject',
          ),
          config: const RunnerConfig(
            watch: false,
            flutter: false,
            serverArgs: ['--mode', 'production'],
          ),
        );

        final decoded = RunnerManifest.fromJson(
          jsonDecode(jsonEncode(original.toJson())) as Map<String, Object?>,
        );

        expect(decoded.protocolVersion, original.protocolVersion);
        expect(decoded.cliVersion, original.cliVersion);
        expect(decoded.pid, 4242);
        expect(decoded.sockets.tui, original.sockets.tui);
        expect(decoded.sockets.mcp, original.sockets.mcp);
        expect(decoded.vmService?.proxy, original.vmService?.proxy);
        expect(decoded.servers?.api, 'http://localhost:8080');
        expect(decoded.servers?.insights, 'http://localhost:8081');
        expect(decoded.servers?.web, 'http://localhost:8082');
        expect(decoded.docker?.startedByRunner, isTrue);
        expect(decoded.docker?.project, 'myproject');
        expect(decoded.config.watch, isFalse);
        expect(decoded.config.flutter, isFalse);
        expect(decoded.config.serverArgs, ['--mode', 'production']);
      },
    );

    test(
      'when optional sections are absent, '
      'then decoding leaves them null rather than inventing addresses.',
      () {
        final decoded = RunnerManifest.fromJson(
          jsonDecode(jsonEncode(_manifest().toJson())) as Map<String, Object?>,
        );

        expect(decoded.vmService, isNull);
        expect(decoded.servers, isNull);
        expect(decoded.docker, isNull);
      },
    );
  });

  group('Given a runner configuration,', () {
    const running = RunnerConfig(
      watch: true,
      flutter: true,
      serverArgs: ['--mode', 'production'],
    );

    test(
      'when an invocation asks for the same options, '
      'then it names no differences.',
      () {
        const asked = RunnerConfig(
          watch: true,
          flutter: true,
          serverArgs: ['--mode', 'production'],
        );

        expect(running.differencesFrom(asked), isEmpty);
      },
    );

    test(
      'when an invocation asks for a different watch mode, '
      'then it names the option.',
      () {
        const asked = RunnerConfig(
          watch: false,
          flutter: true,
          serverArgs: ['--mode', 'production'],
        );

        expect(running.differencesFrom(asked), ['--watch']);
      },
    );

    test(
      'when an invocation asks for different server arguments, '
      'then it names them.',
      () {
        const asked = RunnerConfig(
          watch: true,
          flutter: true,
          serverArgs: ['--mode', 'development'],
        );

        expect(running.differencesFrom(asked), ['server arguments after --']);
      },
    );
  });

  group('Given a server directory,', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('rmt');
    });

    tearDown(() async {
      try {
        tempDir.deleteSync(recursive: true);
      } on FileSystemException {
        // Already gone.
      }
    });

    test(
      'when a manifest is written, '
      'then it lands at .dart_tool/serverpod/runner.json and reads back.',
      () async {
        await _manifest().writeTo(tempDir.path);

        expect(
          File(serverpodRunnerManifestPath(tempDir.path)).existsSync(),
          isTrue,
        );
        expect((await RunnerManifest.readFrom(tempDir.path))?.pid, 4242);
      },
    );

    test(
      'when there is no manifest, '
      'then reading returns null rather than throwing.',
      () async {
        expect(await RunnerManifest.readFrom(tempDir.path), isNull);
      },
    );

    test(
      'when the manifest is corrupt, '
      'then reading treats it as absent, since the next runner overwrites it.',
      () async {
        final file = File(serverpodRunnerManifestPath(tempDir.path));
        await file.parent.create(recursive: true);
        await file.writeAsString('{not json');

        expect(await RunnerManifest.readFrom(tempDir.path), isNull);
      },
    );

    test(
      'when a published manifest is disposed, '
      'then the file is removed so no stale manifest is left behind.',
      () async {
        final publisher = RunnerManifestPublisher(
          serverDir: tempDir.path,
          manifest: _manifest(),
        );
        await publisher.publish();
        expect(await RunnerManifest.readFrom(tempDir.path), isNotNull);

        await publisher.dispose();

        expect(await RunnerManifest.readFrom(tempDir.path), isNull);
      },
    );

    test(
      'when a published address changes, '
      'then the manifest on disk is rewritten with the new one.',
      () async {
        final changes = StreamController<void>();
        final publisher = RunnerManifestPublisher(
          serverDir: tempDir.path,
          manifest: _manifest(),
        );
        addTearDown(publisher.dispose);
        addTearDown(changes.close);

        await publisher.publish();
        publisher.republishOn(
          changes.stream,
          (current) => current.copyWith(
            vmService: const RunnerVmServiceUris(proxy: 'http://new/'),
          ),
        );

        changes.add(null);
        // Let the listener and its serialized write run.
        await pumpEventQueue();

        expect(
          (await RunnerManifest.readFrom(tempDir.path))?.vmService?.proxy,
          'http://new/',
        );
      },
    );

    test(
      'when a write fails, '
      'then later writes still land and disposing still completes.',
      () async {
        // A file where the tool directory belongs makes the write throw, the
        // way a `flutter clean` under a running runner would.
        final blocker = File(
          File(serverpodRunnerManifestPath(tempDir.path)).parent.path,
        );
        await blocker.parent.create(recursive: true);
        await blocker.writeAsString('not a directory');

        final publisher = RunnerManifestPublisher(
          serverDir: tempDir.path,
          manifest: _manifest(),
        );
        await publisher.publish();
        expect(await RunnerManifest.readFrom(tempDir.path), isNull);

        await blocker.delete();
        await publisher.publish();

        expect((await RunnerManifest.readFrom(tempDir.path))?.pid, 4242);
        await expectLater(publisher.dispose(), completes);
      },
    );
  });

  group('Given a server directory name,', () {
    test(
      'when the Docker Compose project name is derived, '
      'then it matches Compose\'s own lowercase, stripped default.',
      () {
        expect(composeProjectName('/tmp/My Project'), 'myproject');
        expect(composeProjectName('/tmp/my_project-1'), 'my_project-1');
        expect(composeProjectName('/tmp/__leading'), 'leading');
      },
    );
  });
}

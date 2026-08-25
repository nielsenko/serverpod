import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:serverpod_cli/src/runner/port_resolution.dart';
import 'package:serverpod_cli/src/runner/runner_manifest.dart';
import 'package:serverpod_cli/src/runner/runner_paths.dart';
import 'package:serverpod_shared/serverpod_shared.dart' show bindUnixSocket;
import 'package:test/test.dart';

void main() {
  group('Given configured ports and a server package,', () {
    late Directory root;
    late String serverDir;

    setUp(() async {
      // A repository with two worktrees beside each other, which is the layout
      // the fallback exists for.
      root = await Directory.systemTemp.createTemp('prt');
      serverDir = p.join(root.path, 'main', 'my_server');
      await Directory(serverDir).create(recursive: true);
      await Directory(p.join(root.path, 'main', '.git')).create();
    });

    tearDown(() async {
      try {
        root.deleteSync(recursive: true);
      } on FileSystemException {
        // Already gone.
      }
    });

    test(
      'when the configured ports are free, '
      'then the configured ports are kept.',
      () async {
        final resolution = await resolvePorts(
          serverDir: serverDir,
          ports: {'api': await _freePort(), 'web': await _freePort()},
        );

        expect(resolution.useEphemeral, isFalse);
        expect(resolution.hasConflicts, isFalse);
      },
    );

    test(
      'when a port is held by something that is not a runner, '
      'then it is a conflict rather than a reason to move aside.',
      () async {
        final occupied = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        addTearDown(occupied.close);

        final resolution = await resolvePorts(
          serverDir: serverDir,
          ports: {'api': occupied.port},
        );

        expect(resolution.hasConflicts, isTrue);
        expect(resolution.conflicts['api'], occupied.port);
        expect(resolution.useEphemeral, isFalse);
      },
    );

    test(
      'when a port is held while a sibling worktree has a live runner, '
      'then the stack falls back to ephemeral ports.',
      () async {
        final occupied = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        addTearDown(occupied.close);
        addTearDown(
          (await _startSiblingRunner(root.path, 'wt2', 'my_server')).close,
        );

        final resolution = await resolvePorts(
          serverDir: serverDir,
          ports: {'api': occupied.port},
        );

        expect(resolution.useEphemeral, isTrue);
        expect(resolution.hasConflicts, isFalse);
      },
    );

    test(
      'when a sibling worktree left a manifest but no live runner, '
      'then the held port is a conflict, not a reason to move aside.',
      () async {
        final occupied = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        addTearDown(occupied.close);
        // A manifest a crashed runner left behind proves nothing.
        await _writeDeadSiblingManifest(root.path, 'wt2', 'my_server');

        final resolution = await resolvePorts(
          serverDir: serverDir,
          ports: {'api': occupied.port},
        );

        expect(resolution.hasConflicts, isTrue);
        expect(resolution.useEphemeral, isFalse);
      },
    );

    test(
      'when one of several ports is held by another runner, '
      'then all three fall back together rather than splitting the stack.',
      () async {
        final occupied = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        addTearDown(occupied.close);
        addTearDown(
          (await _startSiblingRunner(root.path, 'wt2', 'my_server')).close,
        );

        final resolution = await resolvePorts(
          serverDir: serverDir,
          ports: {
            'api': occupied.port,
            'insights': await _freePort(),
            'web': await _freePort(),
          },
        );

        expect(resolution.useEphemeral, isTrue);
        // The overrides cover every listener, not just the one that clashed.
        expect(
          ephemeralPortEnvironment(const ['api', 'insights', 'web']).keys,
          hasLength(3),
        );
      },
    );

    test(
      'when a port is zero, '
      'then it is already ephemeral and needs no probe.',
      () async {
        final resolution = await resolvePorts(
          serverDir: serverDir,
          ports: {'api': 0},
        );

        expect(resolution.useEphemeral, isFalse);
        expect(resolution.hasConflicts, isFalse);
      },
    );
  });

  group('Given the ephemeral port overrides,', () {
    test(
      'when they are applied, '
      'then every configured listener is asked for port zero.',
      () {
        expect(ephemeralPortEnvironment(const ['api', 'insights', 'web']), {
          'SERVERPOD_API_SERVER_PORT': '0',
          'SERVERPOD_INSIGHTS_SERVER_PORT': '0',
          'SERVERPOD_WEB_SERVER_PORT': '0',
        });
      },
    );

    test(
      'when the project configures no insights or web server, '
      'then neither is given a port, which would start one.',
      () {
        expect(ephemeralPortEnvironment(const ['api']), {
          'SERVERPOD_API_SERVER_PORT': '0',
        });
      },
    );
  });
}

/// A port that was free a moment ago.
Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

/// Stands up a runner in a sibling worktree that actually answers.
///
/// A listening socket rather than a stray file: liveness is a real probe, so a
/// manifest alone would not count.
Future<ServerSocket> _startSiblingRunner(
  String root,
  String worktree,
  String serverPackage,
) async {
  final dir = await _prepareSibling(root, worktree, serverPackage);
  final socketPath = p.join(serverpodToolDirPath(dir), 'tui.sock');
  final socket = await bindUnixSocket(socketPath);
  socket.listen((client) => client.destroy());

  await _writeManifest(dir, socketPath);
  return socket;
}

/// Leaves behind the manifest of a runner that is no longer listening.
Future<void> _writeDeadSiblingManifest(
  String root,
  String worktree,
  String serverPackage,
) async {
  final dir = await _prepareSibling(root, worktree, serverPackage);
  await _writeManifest(dir, p.join(serverpodToolDirPath(dir), 'tui.sock'));
}

Future<String> _prepareSibling(
  String root,
  String worktree,
  String serverPackage,
) async {
  final dir = p.join(root, worktree, serverPackage);
  await Directory(dir).create(recursive: true);
  await Directory(p.join(root, worktree, '.git')).create(recursive: true);
  await Directory(serverpodToolDirPath(dir)).create(recursive: true);
  return dir;
}

Future<void> _writeManifest(String dir, String socketPath) => RunnerManifest(
  pid: 4242,
  sockets: RunnerSockets(tui: socketPath, mcp: ''),
  config: const RunnerConfig(watch: true, flutter: true, serverArgs: []),
).writeTo(dir);

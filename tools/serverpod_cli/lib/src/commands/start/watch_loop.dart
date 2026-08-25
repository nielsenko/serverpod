import 'dart:async';
import 'dart:io';

import 'package:serverpod_cli/src/commands/start/flutter_app_manager.dart';
import 'package:serverpod_cli/src/commands/start/mcp_socket.dart';
import 'package:serverpod_cli/src/commands/start/watch_session.dart';
import 'package:serverpod_cli/src/runner/runner_api.dart';
import 'package:serverpod_cli/src/runner/runner_lock.dart';
import 'package:serverpod_cli/src/runner/runner_manifest_publisher.dart';
import 'package:serverpod_cli/src/runner/runner_socket_server.dart';
import 'package:serverpod_cli/src/vm_proxy/proxy.dart';
import 'package:serverpod_shared/serverpod_shared.dart';

/// Mutable holder for `serverArgs` so the migration-fallback hook can
/// prepend `--apply-migrations` and have the next pod start observe it.
class ServerArgsRef {
  List<String> value;
  ServerArgsRef(this.value);
}

sealed class WatchLoopSetupResult {
  const WatchLoopSetupResult();
}

final class WatchLoopReady extends WatchLoopSetupResult {
  final WatchLoopContext ctx;
  const WatchLoopReady(this.ctx);
}

final class WatchLoopAborted extends WatchLoopSetupResult {
  final int exitCode;
  const WatchLoopAborted(this.exitCode);
}

/// Owns everything constructed by the watch-loop setup and provides a
/// single, idempotent [dispose] for cleanup.
class WatchLoopContext {
  final WatchSession session;

  /// The runner's capabilities over [session], for whichever surface renders
  /// this context.
  final RunnerApi runnerApi;

  /// Resolves the server VM-service proxy at call time. A function rather than
  /// a value because a degraded start has no proxy yet - it is mounted only
  /// when the server first boots, after this context is constructed.
  final VmServiceProxy? Function() proxy;
  final FlutterAppManager flutterManager;
  final McpSocketServer? mcpSocket;

  /// The attach socket clients render from. Null when it could not bind.
  final RunnerSocketServer? attachSocket;
  final Future<void> Function() closeAnalyzers;
  final Future<void> Function()? stopDocker;
  final void Function() stopFileWatcher;
  final String vmServiceInfoFile;

  /// Keeps `runner.json` current, and removes it on dispose. Null in tests
  /// that build a context without publishing one.
  final RunnerManifestPublisher? manifestPublisher;

  /// The one-runner-per-package lock, released last so nothing else can claim
  /// the package while this one is still tearing down.
  final RunnerLock? lock;

  bool _disposed = false;

  WatchLoopContext({
    required this.session,
    required this.runnerApi,
    required this.proxy,
    required this.flutterManager,
    required this.mcpSocket,
    required this.attachSocket,
    required this.closeAnalyzers,
    required this.stopDocker,
    required this.stopFileWatcher,
    required this.vmServiceInfoFile,
    this.manifestPublisher,
    this.lock,
  });

  /// Whether [dispose] has been called.
  bool get isDisposed => _disposed;

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    stopFileWatcher();
    await mcpSocket?.close();
    await attachSocket?.close();
    // After both sockets, so no client is served from buffers that are being
    // torn down, and before the session that feeds them.
    await runnerApi.close();
    await closeAnalyzers();
    await session.dispose();
    await proxy()?.close();
    await flutterManager.dispose();
    await File(vmServiceInfoFile).deleteIfExists();
    await manifestPublisher?.dispose();
    await stopDocker?.call();
    await lock?.release();
  }
}

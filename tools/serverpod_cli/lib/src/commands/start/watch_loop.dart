import 'dart:async';
import 'dart:io';

import 'package:serverpod_cli/src/commands/start/flutter_app_manager.dart';
import 'package:serverpod_cli/src/commands/start/flutter_runtime_info.dart';
import 'package:serverpod_cli/src/commands/start/mcp_socket.dart';
import 'package:serverpod_cli/src/commands/start/watch_session.dart';
import 'package:serverpod_cli/src/util/serverpod_cli_logger.dart';
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

  /// Resolves the server VM-service proxy at call time. A function rather than
  /// a value because a degraded start has no proxy yet - it is mounted only
  /// when the server first boots, after this context is constructed.
  final VmServiceProxy? Function() proxy;
  final FlutterAppManager flutterManager;
  final McpSocketServer? mcpSocket;
  final Future<void> Function() closeAnalyzers;
  final Future<void> Function()? stopDocker;
  final void Function() stopFileWatcher;
  final String vmServiceInfoFile;
  final String serverpodToolDir;
  bool _disposed = false;

  WatchLoopContext({
    required this.session,
    required this.proxy,
    required this.flutterManager,
    required this.mcpSocket,
    required this.closeAnalyzers,
    required this.stopDocker,
    required this.stopFileWatcher,
    required this.vmServiceInfoFile,
    required this.serverpodToolDir,
  });

  /// Whether [dispose] has been called.
  bool get isDisposed => _disposed;

  /// Tears down the watch session. When [shutdownFlutterApp] is true,
  /// the Flutter app is explicitly terminated via `app.stop` and the
  /// runtime-info file is removed. Default `false` leaves the app
  /// alive so the next `serverpod start` can reattach; a breadcrumb
  /// is logged at exit naming the surviving PID + attach URL.
  Future<void> dispose({bool shutdownFlutterApp = false}) async {
    if (_disposed) return;
    _disposed = true;
    stopFileWatcher();
    await mcpSocket?.close();
    await closeAnalyzers();
    await session.dispose(shutdownFlutterApp: shutdownFlutterApp);
    await proxy()?.close();
    await flutterManager.dispose();
    await File(vmServiceInfoFile).deleteIfExists();
    await stopDocker?.call();
    if (!shutdownFlutterApp) {
      await _logFlutterBreadcrumb();
    }
  }

  Future<void> _logFlutterBreadcrumb() async {
    for (final app in flutterManager.apps) {
      final info = await readFlutterRuntimeInfo(serverpodToolDir, app.id);
      if (info == null) continue;
      log.info(
        'Flutter app left running:\n'
        '  App:     ${app.name}\n'
        '  Device:  ${info.device}\n'
        '  PID:     ${info.pid}\n'
        '  Attach:  ${info.vmServiceUri}\n'
        '  Reattach by re-running serverpod start, or kill with: '
        'kill ${info.pid}',
      );
    }
  }
}

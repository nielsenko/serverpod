import 'dart:async';
import 'dart:io';

import 'package:serverpod_cli/src/mcp/socket_directory.dart';
import 'package:serverpod_cli/src/runner/runner_api.dart';
import 'package:serverpod_shared/serverpod_shared.dart';

import 'mcp_server.dart';

/// Manages a Unix socket that accepts MCP client connections.
///
/// Each runner listens on `<serverDir>/.dart_tool/serverpod/mcp.sock`. There is
/// at most one socket per server project; a stale file left behind by a crashed
/// previous run is unlinked before binding. Clients connect to interact with
/// the running dev environment via JSON-RPC (MCP protocol).
///
/// Several clients may be connected at once. A developer on the terminal UI and
/// an agent over MCP can already issue commands at the same time, so a
/// one-connection limit bought no exclusivity - it only prevented a second
/// agent. Conflicting commands are serialized by [RunnerApi] instead.
class McpSocketServer {
  /// Absolute path to this server's socket file.
  final String socketPath;

  ServerSocket? _serverSocket;
  final Set<ServerpodMcpServer> _mcpServers = {};
  final Set<Socket> _clientSockets = {};
  InProcessRunnerApi? _runner;
  bool _closing = false;

  McpSocketServer({required String serverDir})
    : socketPath = serverpodMcpSocketPath(serverDir);

  /// Start listening for connections. Creates the parent directory if
  /// missing; [bindUnixSocket] takes care of unlinking any stale socket
  /// file left by a crashed previous run.
  Future<void> start() async {
    File(socketPath).parent.createSync(recursive: true);
    _serverSocket = await bindUnixSocket(socketPath);
    _serverSocket!.listen(_handleConnection);
  }

  /// Wires the MCP servers to the runner.
  ///
  /// Can be called before or after clients connect; already-connected clients
  /// are updated in place.
  void connect(InProcessRunnerApi runner) {
    _runner = runner;
    for (final server in _mcpServers) {
      server.runner = runner;
    }
  }

  /// Shuts the socket server and every connected client down.
  Future<void> close() async {
    _closing = true;
    await Future.wait([
      for (final server in _mcpServers.toList()) server.shutdown(),
    ]);
    _mcpServers.clear();
    for (final socket in _clientSockets.toList()) {
      socket.destroy();
    }
    _clientSockets.clear();
    await _serverSocket?.close();
    try {
      File(socketPath).deleteSync();
    } on FileSystemException {
      // Already gone.
    }
  }

  void _handleConnection(Socket socket) {
    // Reject connections that arrive after close() has started.
    if (_closing) {
      socket.destroy();
      return;
    }

    _clientSockets.add(socket);

    final server = ServerpodMcpServer(socketChannel(socket))..runner = _runner;
    _mcpServers.add(server);

    // Clean up on disconnect.
    unawaited(
      server.done.then((_) {
        _mcpServers.remove(server);
        _clientSockets.remove(socket);
      }),
    );
  }
}

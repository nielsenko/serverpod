import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:stream_channel/stream_channel.dart';

import 'mcp_server.dart';

/// Manages a Unix socket that accepts MCP client connections.
///
/// The CLI process listens on a socket file (typically
/// `.dart_tool/serverpod/mcp.sock`). Clients connect to interact with the
/// running dev environment via JSON-RPC (MCP protocol). Only one client
/// connection is active at a time.
class McpSocketServer {
  final String socketPath;
  ServerSocket? _serverSocket;
  Socket? _clientSocket;
  ServerpodMcpServer? _mcpServer;
  Future<void>? _pendingShutdown;
  bool _closing = false;

  /// Callback wired once via [connect].
  Future<void> Function()? _onApplyMigration;

  McpSocketServer({required this.socketPath});

  /// Start listening for connections.
  Future<void> start() async {
    // Clean up stale socket file if it exists.
    if (FileSystemEntity.typeSync(socketPath) !=
        FileSystemEntityType.notFound) {
      File(socketPath).deleteSync();
    }

    // Use the shorter of absolute or relative path to stay within the Unix
    // domain socket path length limit (104 bytes on macOS, 108 on Linux).
    final bindPath = _shortestPath(socketPath);
    _serverSocket = await ServerSocket.bind(
      InternetAddress(bindPath, type: InternetAddressType.unix),
      0,
    );

    _serverSocket!.listen(_handleConnection);
  }

  /// Wire the MCP server to watch session callbacks. Can be called before or
  /// after a client connects.
  void connect({
    required Future<void> Function() onApplyMigration,
  }) {
    _onApplyMigration = onApplyMigration;
    _mcpServer?.onApplyMigration = onApplyMigration;
  }

  /// Shut down the socket server and clean up.
  Future<void> close() async {
    _closing = true;
    await _pendingShutdown;
    await _mcpServer?.shutdown();
    _clientSocket?.destroy();
    await _serverSocket?.close();
    try {
      File(socketPath).deleteSync();
    } on FileSystemException {
      // Already gone.
    }
  }

  Future<void> _handleConnection(Socket socket) async {
    // Serialize connection handling - wait for any in-flight shutdown.
    await _pendingShutdown;

    // Reject connections that arrive after close() has started.
    if (_closing) {
      socket.destroy();
      return;
    }

    // Only one client at a time - shut down previous.
    final shutdown = _mcpServer?.shutdown();
    if (shutdown != null) {
      _pendingShutdown = shutdown;
      await shutdown;
      _pendingShutdown = null;
    }

    // Re-check after awaiting - close() may have been called in the meantime.
    if (_closing) {
      socket.destroy();
      return;
    }

    _clientSocket?.destroy();
    _clientSocket = socket;

    final channel = _socketChannel(socket);
    final server = ServerpodMcpServer(channel);
    _mcpServer = server;

    // Wire callback if already connected.
    if (_onApplyMigration != null) {
      server.onApplyMigration = _onApplyMigration;
    }

    // Clean up on disconnect.
    unawaited(
      server.done.then((_) {
        if (_mcpServer == server) {
          _mcpServer = null;
          _clientSocket = null;
        }
      }),
    );
  }
}

/// Create a [StreamChannel<String>] from a [Socket] for MCP JSON-RPC.
///
/// Same line-delimited protocol as stdio transport.
StreamChannel<String> _socketChannel(Socket socket) {
  final inStream = socket
      .cast<List<int>>()
      .transform(utf8.decoder)
      .transform(const LineSplitter());

  final outController = StreamController<String>();
  outController.stream.listen(
    (line) => socket.write('$line\n'),
    onDone: () => socket.close(),
  );

  return StreamChannel<String>(inStream, outController.sink);
}

/// Returns the shorter of the absolute or relative form of [path].
///
/// Unix domain sockets have a path length limit (104 bytes on macOS, 108 on
/// Linux). Using a relative path helps when the project is deeply nested.
String _shortestPath(String path) {
  final relative = p.relative(path);
  return relative.length < path.length ? relative : path;
}

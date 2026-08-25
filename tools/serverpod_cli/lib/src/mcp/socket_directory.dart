import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:serverpod_cli/src/runner/runner_paths.dart';
import 'package:stream_channel/stream_channel.dart';

/// Canonical path of the MCP socket exposed by `serverpod start --watch`
/// for the server project rooted at [serverDir].
///
/// One socket per server project, kept inside the project's `.dart_tool/`
/// so it is scoped, easy to discover, and ignored by VCS. There can be at
/// most one `serverpod start --watch` process per project; a stale socket
/// file left behind by a crashed runner is unlinked before the next bind.
String serverpodMcpSocketPath(String serverDir) =>
    p.join(serverpodToolDirPath(serverDir), 'mcp.sock');

/// Wraps [socket] in a [StreamChannel<String>] using line-delimited messages.
///
/// Matches the framing used by `dart_mcp`'s stdio transport so the same
/// `MCPServer`/`MCPClient` plumbing works over a Unix socket.
StreamChannel<String> socketChannel(Socket socket) {
  final inStream = socket
      .cast<List<int>>()
      .transform(utf8.decoder)
      .transform(const LineSplitter());

  final outController = StreamController<String>();
  outController.stream.listen(
    (line) {
      // A peer that has gone away is ordinary: a client detaches whenever it
      // likes, and the runner may still be mid-broadcast. Writing to its
      // socket must not surface as an unhandled error and take down the
      // stream that serves everyone else.
      try {
        socket.write('$line\n');
      } on SocketException {
        // Nothing to deliver to; the connection's own done handler cleans up.
      }
    },
    onDone: () => socket.close().catchError((_) {}),
  );

  // Buffered writes report failure here rather than from `write`, so a broken
  // pipe arrives after the fact and needs absorbing too.
  unawaited(socket.done.catchError((Object _) => socket));

  return StreamChannel<String>(inStream, outController.sink);
}

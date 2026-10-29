import 'dart:async';
import 'dart:convert';

import 'package:serverpod/serverpod.dart';
import 'package:stream_channel/stream_channel.dart';

/// A stream of server-sent events, read by an `EventSource` in each page.
///
/// The event stream takes over the socket. Relic's dart:io adapter buffers a
/// streamed body, which would hold events back.
class SseEndpoint {
  final _sockets = <StreamChannel<List<int>>>{};

  /// The number of pages that listen.
  int get listeners => _sockets.length;

  /// Handles a request to the endpoint's URL.
  Result handle(Request request) =>
      request.method == Method.get ? Hijack(connect) : Response(405);

  /// Serves the event stream on [socket], a connection the endpoint took
  /// over, until the socket closes.
  void connect(StreamChannel<List<int>> socket) {
    socket.sink.add(
      utf8.encode(
        'HTTP/1.1 200 OK\r\n'
        'Content-Type: text/event-stream\r\n'
        'Cache-Control: no-cache\r\n'
        'Connection: keep-alive\r\n'
        '\r\n',
      ),
    );
    _sockets.add(socket);
    void close() {
      if (!_sockets.remove(socket)) return;
      unawaited(socket.sink.close().catchError((_) {}));
    }

    socket.stream.listen((_) {}, onDone: close, onError: (_) => close());
  }

  /// Sends [data] as one event to every page that listens.
  void send(String data) {
    assert(!data.contains('\n'), 'An event carries a single data line.');
    final event = utf8.encode('data: $data\n\n');
    for (final socket in _sockets) {
      socket.sink.add(event);
    }
  }
}

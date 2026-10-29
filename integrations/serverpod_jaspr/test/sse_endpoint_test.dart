import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:serverpod/serverpod.dart';
import 'package:serverpod_jaspr/src/sse_endpoint.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import 'test_pod.dart';

class _SseRoute extends Route {
  final SseEndpoint endpoint;

  _SseRoute(this.endpoint) : super(methods: {Method.get, Method.post});

  @override
  Future<Result> call(Request req) async => endpoint.handle(req);

  @override
  FutureOr<Result> handleCall(Session session, Request request) =>
      throw UnimplementedError();
}

void main() {
  late Serverpod pod;
  late SseEndpoint endpoint;
  late int port;
  late HttpClient client;

  setUp(() async {
    pod = createPod();
    endpoint = SseEndpoint();
    port = await startPod(pod, _SseRoute(endpoint), '/events');
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await pod.shutdown(exitProcess: false);
  });

  /// Opens the event stream as a page does and returns its `data:` lines.
  Future<Stream<String>> listen() async {
    final request = await client.getUrl(
      Uri.parse('http://localhost:$port/events'),
    );
    final response = await request.close();
    expect(response.headers.contentType?.mimeType, 'text/event-stream');
    return response
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .where((line) => line.startsWith('data: '))
        .map((line) => line.substring('data: '.length));
  }

  test(
    'Given a page that listens, '
    'when an event is sent, '
    'then the page receives it as a data line.',
    () async {
      final events = await listen();

      endpoint.send('{"hotReload":true,"restart":false}');

      expect(await events.first, '{"hotReload":true,"restart":false}');
    },
  );

  test(
    'Given two pages that listen, '
    'when an event is sent, '
    'then both pages receive it.',
    () async {
      final first = await listen();
      final second = await listen();

      endpoint.send('reload');

      expect(await Future.wait([first.first, second.first]), [
        'reload',
        'reload',
      ]);
    },
  );

  test(
    'Given a page that listens, '
    'when its connection closes, '
    'then the endpoint no longer counts it.',
    () async {
      final socket = StreamChannelController<List<int>>();
      endpoint.connect(socket.local);
      expect(endpoint.listeners, 1);

      await socket.foreign.sink.close();
      await pumpEventQueue();

      expect(endpoint.listeners, 0);
    },
  );

  test(
    'Given an event endpoint, '
    'when a page posts a message to it, '
    'then the response is 405.',
    () async {
      final response = await http.post(
        Uri.parse('http://localhost:$port/events'),
        body: 'hello',
      );

      expect(response.statusCode, 405);
    },
  );
}

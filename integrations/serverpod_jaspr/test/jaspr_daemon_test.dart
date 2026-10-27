import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:jaspr/dom.dart' show p;
import 'package:jaspr/server.dart' as jaspr;
import 'package:serverpod/serverpod.dart';
import 'package:serverpod_jaspr/serverpod_jaspr.dart';
import 'package:serverpod_jaspr/src/dev_daemon.dart';
import 'package:test/test.dart';

import 'test_pod.dart';

/// A stand-in for `jaspr daemon`, recording the host each request names.
Future<HttpServer> _startDaemon(List<String?> hosts) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) {
    hosts.add(request.headers.value('host'));
    final response = request.response;
    switch (request.uri.path) {
      case '/main.client.dart.js':
        response.headers.contentType = ContentType(
          'application',
          'javascript',
          charset: 'utf-8',
        );
        response.headers.set('etag', '"abc"');
        response.write('main(${request.uri.query});');
      case '/index.template.html':
        response.headers.contentType = ContentType.html;
        response.write(
          '<html><head><title>from the daemon</title></head>'
          '<body></body></html>',
        );
      default:
        response.statusCode = HttpStatus.notFound;
    }
    response.close();
  });
  return server;
}

JasprRoute _route({jaspr.Component? component}) => JasprRoute(
  'website',
  build: (session, request) => component ?? p([jaspr.Component.text('page')]),
  options: () => const jaspr.ServerOptions(),
);

void main() {
  late Serverpod pod;
  late HttpServer daemon;
  final hosts = <String?>[];

  setUp(() async {
    pod = createPod();
    hosts.clear();
    daemon = await _startDaemon(hosts);
    debugJasprProxyPort = daemon.port;
  });

  tearDown(() async {
    debugJasprProxyPort = null;
    await daemon.close(force: true);
    await pod.shutdown(exitProcess: false);
  });

  test(
    'Given a Jaspr route with a daemon, '
    'when a file below the mount is requested, '
    'then the daemon serves it with its headers and sees itself as the host.',
    () async {
      final port = await startPod(pod, _route(), '/app');

      final response = await http.get(
        Uri.parse('http://localhost:$port/app/main.client.dart.js?v=1'),
      );

      expect(response.statusCode, 200);
      expect(response.body, 'main(v=1);');
      expect(
        response.headers['content-type'],
        startsWith('application/javascript'),
      );
      expect(response.headers['etag'], '"abc"');
      expect(hosts, ['localhost:${daemon.port}']);
    },
  );

  test(
    'Given a Jaspr route with a daemon, '
    'when a file the daemon lacks is requested, '
    'then the response is 404.',
    () async {
      final port = await startPod(pod, _route(), '/app');

      final response = await http.get(
        Uri.parse('http://localhost:$port/app/missing.js'),
      );

      expect(response.statusCode, 404);
    },
  );

  test(
    'Given a Jaspr route with a daemon, '
    'when a page is requested, '
    'then it is rendered here with its template from the daemon and the '
    'restart script.',
    () async {
      final port = await startPod(
        pod,
        _route(
          component: jaspr.Document.template(
            name: 'index',
            child: p([jaspr.Component.text('page')]),
          ),
        ),
        '/app',
      );

      final response = await http.get(Uri.parse('http://localhost:$port/app/'));

      expect(response.statusCode, 200);
      expect(response.body, contains('<title>from the daemon</title>'));
      expect(response.body, contains('<p>page</p>'));
      expect(response.body, contains(r'$serverpodInstance'));
      expect(hosts, ['localhost:${daemon.port}']);
    },
  );

  test(
    'Given a Jaspr route whose daemon is down, '
    'when a file is requested, '
    'then the response is 503 and asks the browser to retry.',
    () async {
      await daemon.close(force: true);
      final port = await startPod(pod, _route(), '/app');

      final response = await http.get(
        Uri.parse('http://localhost:$port/app/main.client.dart.js'),
      );

      expect(response.statusCode, 503);
      expect(response.headers['retry-after'], '1');
    },
  );
}

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:jaspr/dom.dart' show p;
import 'package:jaspr/server.dart' as jaspr;
import 'package:serverpod/serverpod.dart';
import 'package:serverpod_jaspr/serverpod_jaspr.dart';
import 'package:test/test.dart';

import 'test_pod.dart';

/// Renders the URL and base path Jaspr sees for the request.
class _ShowRequest extends jaspr.StatelessComponent {
  const _ShowRequest();

  @override
  jaspr.Component build(jaspr.BuildContext context) {
    return p([
      jaspr.Component.text(
        'url=${context.url} base=${context.binding.basePath}',
      ),
    ]);
  }
}

/// Renders a request header, looked up in lowercase, and sets one on the
/// response.
class _Headers extends jaspr.StatelessComponent {
  const _Headers();

  @override
  jaspr.Component build(jaspr.BuildContext context) {
    context.setHeader('X-Served-By', 'jaspr');
    return p([jaspr.Component.text('custom=${context.headers['x-custom']}')]);
  }
}

void main() {
  late Serverpod pod;
  late Directory originalDirectory;
  late Directory tempDirectory;

  setUp(() {
    pod = createPod();
    originalDirectory = Directory.current;
    tempDirectory = Directory.systemTemp.createTempSync('serverpod_jaspr');
    Directory.current = tempDirectory;
  });

  tearDown(() async {
    await pod.shutdown(exitProcess: false);
    Directory.current = originalDirectory;
    tempDirectory.deleteSync(recursive: true);
  });

  test(
    'Given a Jaspr route at the root, '
    'when a page is requested, '
    'then the response is the HTML document Jaspr rendered.',
    () async {
      final port = await startPod(
        pod,
        JasprRoute(
          'website',
          build: (session, request) =>
              p([jaspr.Component.text('Hello from Jaspr')]),
          options: () => const jaspr.ServerOptions(),
        ),
        '/',
      );

      final response = await http.get(Uri.parse('http://localhost:$port/'));

      expect(response.statusCode, 200);
      expect(response.headers['content-type'], startsWith('text/html'));
      expect(response.body, startsWith('<!DOCTYPE html>'));
      expect(response.body, contains('<p>Hello from Jaspr</p>'));
    },
  );

  test(
    'Given a Jaspr route mounted at /app, '
    'when a nested page with a query is requested, '
    'then Jaspr sees the URL relative to the mount and the mount as its '
    'base path.',
    () async {
      final port = await startPod(
        pod,
        JasprRoute(
          'website',
          build: (session, request) => const _ShowRequest(),
          options: () => const jaspr.ServerOptions(),
        ),
        '/app',
      );

      final response = await http.get(
        Uri.parse('http://localhost:$port/app/about?tab=team'),
      );

      expect(response.body, contains('<p>url=/about?tab=team base=/app/</p>'));
    },
  );

  test(
    'Given a Jaspr route, '
    'when a page is requested with a header, '
    'then the component reads it by its lowercase name and the header it '
    'sets reaches the response next to the content type.',
    () async {
      final port = await startPod(
        pod,
        JasprRoute(
          'website',
          build: (session, request) => const _Headers(),
          options: () => const jaspr.ServerOptions(),
        ),
        '/',
      );

      final response = await http.get(
        Uri.parse('http://localhost:$port/'),
        headers: {'X-Custom': 'relic'},
      );

      expect(response.body, contains('<p>custom=relic</p>'));
      expect(response.headers['x-served-by'], 'jaspr');
      expect(response.headers['content-type'], startsWith('text/html'));
    },
  );

  test(
    'Given a Jaspr route whose builder reads the session, '
    'when a page is requested, '
    'then the builder receives the session of the web call.',
    () async {
      final port = await startPod(
        pod,
        JasprRoute(
          'website',
          build: (session, request) =>
              p([jaspr.Component.text('session=${session is WebCallSession}')]),
          options: () => const jaspr.ServerOptions(),
        ),
        '/',
      );

      final response = await http.get(Uri.parse('http://localhost:$port/'));

      expect(response.body, contains('<p>session=true</p>'));
    },
  );

  test(
    'Given a built app in the server\'s web/website directory, '
    'when one of its files is requested, '
    'then the file is served.',
    () async {
      Directory('web/website').createSync(recursive: true);
      File('web/website/main.client.dart.js').writeAsStringSync('main();');
      final port = await startPod(
        pod,
        JasprRoute(
          'website',
          build: (session, request) => p([jaspr.Component.text('page')]),
          options: () => const jaspr.ServerOptions(),
        ),
        '/',
      );

      final response = await http.get(
        Uri.parse('http://localhost:$port/main.client.dart.js'),
      );

      expect(response.statusCode, 200);
      expect(response.body, 'main();');
    },
  );

  test(
    'Given a Jaspr route without a file at a path, '
    'when that file is requested, '
    'then the response is 404 instead of a rendered page.',
    () async {
      final port = await startPod(
        pod,
        JasprRoute(
          'website',
          build: (session, request) => p([jaspr.Component.text('page')]),
          options: () => const jaspr.ServerOptions(),
        ),
        '/',
      );

      final response = await http.get(
        Uri.parse('http://localhost:$port/missing.js'),
      );

      expect(response.statusCode, 404);
    },
  );

  test(
    'Given a Jaspr route outside serverpod start, '
    'when the reload events are requested, '
    'then the response is 404.',
    () async {
      final port = await startPod(
        pod,
        JasprRoute(
          'website',
          build: (session, request) => p([jaspr.Component.text('page')]),
          options: () => const jaspr.ServerOptions(),
        ),
        '/',
      );

      final response = await http.get(
        Uri.parse('http://localhost:$port/\$serverpodReload'),
      );

      expect(response.statusCode, 404);
    },
  );
}

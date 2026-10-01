import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jaspr/server.dart' as jaspr;
import 'package:path/path.dart' as p;
import 'package:serverpod/serverpod.dart';
import 'package:serverpod_shared/serverpod_shared.dart' show JasprAppLocation;

import 'dev_apps.dart';
import 'dev_restart_script.dart';

/// Builds the root component of a Jaspr app for a page request.
typedef JasprAppBuilder = FutureOr<jaspr.Component> Function(
  Session session,
  Request request,
);

/// Renders a Jaspr app inside the server, at the path the route is added at.
///
/// ```dart
/// pod.webServer.addRoute(
///   JasprRoute('website', build: (session, request) => const App(),
///       options: () => defaultServerOptions),
///   '/',
/// );
/// ```
///
/// Page requests render [build] in-process, with the request's [Session].
/// File requests, the ones whose last path segment has an extension other
/// than `html`, `htm` or `xml`, are served from the app's files.
///
/// Under `serverpod start`, the files are the browser code the runner
/// compiles and the app package's `web` directory. Otherwise the files are
/// the output of `jaspr_build` in the server's `web/<appId>` directory.
class JasprRoute extends Route {
  /// The app's identifier in the server's `jaspr_apps` configuration.
  final String appId;

  final JasprAppBuilder _build;

  // A function rather than a value, so a hot reload picks up the options the
  // generator wrote for the new code.
  final jaspr.ServerOptions Function() _options;

  final JasprAppLocation? _devApp;

  /// [options] is usually the generated `defaultServerOptions` getter.
  JasprRoute(
    this.appId, {
    required JasprAppBuilder build,
    required jaspr.ServerOptions Function() options,
  }) : _build = build,
       _options = options,
       _devApp = devJasprApps?[appId],
       super(methods: {Method.get, Method.head, Method.post}, path: '/**');

  bool get _isDev => _devApp != null;

  late final List<Directory> _fileDirs = switch (_devApp) {
    final app? => [
      Directory(app.outputDir),
      Directory(p.join(app.packageDir, 'web')),
    ],
    null => [Directory(p.join('web', appId))],
  };

  final _fileHandlers = <String, StaticHandler>{};

  @override
  void injectIn(RelicRouter router) {
    // Relic replays this after every hot reload, so Jaspr clears the caches
    // it built from the old code here.
    jaspr.ServerApp.reassemble();
    super.injectIn(router);
  }

  @override
  Future<Result> call(Request req) async {
    final segments = req.remainingPath.segments;
    final last = segments.isEmpty ? '' : segments.last;

    if (last == serverInstancePath) {
      return _isDev ? serverInstanceResponse() : Response.notFound();
    }
    if (req.method == Method.post) return Response(405);
    if (_isFile(last)) return _serveFile(req);
    return handleCall(await req.session, req);
  }

  @override
  Future<Result> handleCall(Session session, Request request) async {
    final component = await _build(session, request);
    final query = request.url.hasQuery ? '?${request.url.query}' : '';
    final rendered = await jaspr.renderRequest(
      component,
      (
        url: '/${request.remainingPath.segments.join('/')}$query',
        basePath: _basePath(request),
        headers: _headersOf(request),
      ),
      options: _options(),
      loadFile: _loadFile,
    );
    if (!_isDev) return _toResponse(rendered);

    // Jaspr's client reloads the page itself, keeping its state. Only a new
    // server process, which drops its connection, needs a full reload.
    request.skipDevAutoRefresh();
    final isReload = request.headers['x-jaspr-reload']?.first == 'true';
    return _toResponse(
      isReload ? rendered : withDevRestartScript(rendered),
    );
  }

  // The same rule as Jaspr's own server handler, in
  // package:jaspr/src/server/server_handler.dart.
  static bool _isFile(String segment) {
    final dot = segment.lastIndexOf('.');
    if (dot == -1) return false;
    return !const {'html', 'htm', 'xml'}.contains(segment.substring(dot + 1));
  }

  // The mount is what the route did not consume of the URL. Serverpod routes
  // on the host as well, so `matchedPath` starts with it.
  static String _basePath(Request request) {
    final segments = request.url.pathSegments.where((s) => s.isNotEmpty);
    final mount = segments.take(
      segments.length - request.remainingPath.segments.length,
    );
    return mount.isEmpty ? '/' : '/${mount.join('/')}/';
  }

  Future<Result> _serveFile(Request req) async {
    for (final dir in _fileDirs) {
      final handler = _fileHandler(dir);
      if (handler == null) continue;
      final result = await handler.call(req);
      if (result is Response && result.statusCode == 404) continue;
      return result;
    }
    return Response.notFound();
  }

  StaticHandler? _fileHandler(Directory dir) {
    if (!dir.existsSync()) return null;
    return _fileHandlers[dir.path] ??= StaticHandler.directory(
      dir,
      cacheControl: (_, _) => _isDev ? CacheControlHeader(noCache: true) : null,
    );
  }

  // Used by Jaspr for `Document.template`, which reads
  // `<name>.template.html` from the app's files.
  Future<String?> _loadFile(String name) async {
    for (final dir in _fileDirs) {
      final file = File(p.join(dir.path, name));
      if (await file.exists()) return file.readAsString();
    }
    return null;
  }

  static Map<String, List<String>> _headersOf(Request request) => {
    for (final name in request.headers.names)
      name.lower: request.headers.values(name).toList(),
  };

  static Response _toResponse(jaspr.ResponseLike rendered) {
    final headers = _RenderedHeaders(rendered.headers);
    final contentType = headers.contentType;
    return Response(
      rendered.statusCode,
      body: Body.fromData(
        rendered.body,
        mimeType: contentType == null
            ? MimeType.html
            : MimeType(contentType.primaryType, contentType.subType),
        encoding: Encoding.getByName(contentType?.charset ?? 'utf-8') ?? utf8,
      ),
      headers: Headers.fromStore(headers),
    );
  }
}

/// A relic [HeaderStore] over the headers Jaspr rendered, without copying
/// them. The content type is left out, since the body carries it.
final class _RenderedHeaders extends HeaderStore {
  const _RenderedHeaders(this._headers);

  final Map<String, List<String>> _headers;

  /// The content type Jaspr rendered, or null when it set none.
  ContentType? get contentType {
    final value = _valuesIgnoringCase(HeaderName.contentType.lower);
    return value == null ? null : ContentType.parse(value.first);
  }

  @override
  Iterable<HeaderName> get names => _headers.keys
      .where((key) => key.toLowerCase() != HeaderName.contentType.lower)
      .where(HeaderName.isToken)
      .map(HeaderName.lookup);

  @override
  Iterable<String> values(HeaderName name) => name == HeaderName.contentType
      ? const []
      : _valuesIgnoringCase(name.lower) ?? const [];

  // Jaspr keys its map by the names components gave, in whatever case.
  List<String>? _valuesIgnoringCase(String lower) {
    for (final MapEntry(:key, :value) in _headers.entries) {
      if (key.toLowerCase() == lower && value.isNotEmpty) return value;
    }
    return null;
  }
}

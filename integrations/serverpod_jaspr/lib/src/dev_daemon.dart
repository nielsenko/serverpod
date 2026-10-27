import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:serverpod/serverpod.dart';

/// Takes the place of `JASPR_PROXY_PORT` in tests.
@visibleForTesting
int? debugJasprProxyPort;

/// The browser files of an app, served by `jaspr daemon --skip-server` on
/// the port in `JASPR_PROXY_PORT`.
///
/// Jaspr's own server reads the same variable, so `ServerApp.reloadClients`
/// reaches the daemon unchanged. The page's debug connection does not pass
/// through here: DWDS writes the daemon's own address into the bootstrap it
/// serves, and the browser connects to it directly.
final class JasprDaemon {
  JasprDaemon(this.port, {http.Client? client})
    : _client = client ?? http.Client();

  /// The daemon named by `JASPR_PROXY_PORT`, or null when there is none.
  static JasprDaemon? fromEnvironment() {
    final port =
        debugJasprProxyPort ??
        int.tryParse(Platform.environment['JASPR_PROXY_PORT'] ?? '');
    return port == null ? null : JasprDaemon(port);
  }

  final int port;
  final http.Client _client;

  // Headers that describe the body relic builds anew, and the encoding the
  // client already undid.
  static const _bodyHeaders = {
    'content-type',
    'content-length',
    'content-encoding',
    'transfer-encoding',
  };

  Uri _uri(String path, {String? query}) => Uri(
    scheme: 'http',
    host: 'localhost',
    port: port,
    path: path,
    query: query,
  );

  /// Forwards [request] for a file below the mount. The daemon sees itself
  /// as the host, so DWDS writes its own address into the bootstrap.
  Future<Response> forward(Request request) async {
    final upstream = http.Request(
      request.method.name.toUpperCase(),
      _uri(
        '/${request.remainingPath.segments.join('/')}',
        query: request.url.hasQuery ? request.url.query : null,
      ),
    );
    for (final name in request.headers.names) {
      if (name.lower == 'host' || name.lower == 'connection') continue;
      upstream.headers[name.lower] = request.headers.values(name).join(', ');
    }

    final http.StreamedResponse response;
    try {
      response = await _client.send(upstream);
    } on http.ClientException {
      return _unreachable();
    } on SocketException {
      return _unreachable();
    }

    final contentType = switch (response.headers['content-type']) {
      final value? => ContentType.parse(value),
      null => null,
    };
    return Response(
      response.statusCode,
      body: Body.fromDataStream(
        response.stream.map(_asBytes),
        mimeType: contentType == null
            ? null
            : MimeType(contentType.primaryType, contentType.subType),
        encoding: switch (contentType?.charset) {
          final charset? => Encoding.getByName(charset),
          null => null,
        },
        contentLength: response.contentLength,
      ),
      headers: Headers.fromMap({
        for (final MapEntry(:key, :value) in response.headers.entries)
          if (!_bodyHeaders.contains(key)) key: [value],
      }),
    );
  }

  /// The content of the daemon's file at [name], or null when it has none.
  Future<String?> loadFile(String name) async {
    try {
      final response = await _client.get(_uri('/$name'));
      return response.statusCode == 200 ? response.body : null;
    } on http.ClientException {
      return null;
    } on SocketException {
      return null;
    }
  }

  // The daemon takes a while to come up, and the browser retries on its own.
  Response _unreachable() => Response(
    503,
    body: Body.fromString('No Jaspr daemon answers on port $port.'),
    headers: Headers.fromMap({
      'retry-after': ['1'],
    }),
  );

  static Uint8List _asBytes(List<int> chunk) =>
      chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
}

import 'dart:convert';
import 'dart:math';

import 'package:jaspr/server.dart' as jaspr;
import 'package:serverpod/serverpod.dart';

/// The path below a Jaspr app's mount that returns [_serverInstance].
const serverInstancePath = r'$serverpodInstance';

// Survives hot reload and changes with every server process.
final String _serverInstance = Random.secure().nextInt(1 << 32).toString();

/// The response to [serverInstancePath].
Response serverInstanceResponse() => Response.ok(
  body: Body.fromString(_serverInstance),
  headers: Headers.build(
    (h) => h.cacheControl = CacheControlHeader(noStore: true),
  ),
);

/// [rendered] with a script that loads the page again when it cannot be
/// patched forward.
///
/// That is the case when the server process is replaced, such as after a
/// restart by `serverpod start`, because Jaspr's client reloads through a
/// connection to the process that rendered the page. And it is the case when
/// the browser code the page loaded is from another generation than
/// [generation], the one the server rendered the page with. A page that
/// loads while the runner is between writing new browser code and reloading
/// the server gets markup from one generation and code from the next, and
/// Jaspr's client cannot hydrate the markup with it.
jaspr.ResponseLike withDevRestartScript(
  jaspr.ResponseLike rendered, {
  int? generation,
}) {
  final html = utf8.decode(rendered.body, allowMalformed: true);
  final index = html.lastIndexOf('</body>');
  if (index == -1) return rendered;
  final script =
      '<script>(() => {'
      "const url = new URL('$serverInstancePath', document.baseURI);"
      'const generation = ${generation ?? 'null'};'
      'let checked = false;'
      'const check = () => {'
      'if (checked || generation === null) return;'
      'const loaded = window.\$dartLoadedGeneration;'
      'if (loaded === undefined) return;'
      'checked = true;'
      'if (loaded !== generation) location.reload();'
      '};'
      'const poll = () => { check(); return fetch(url, {cache: "no-store"})'
      '.then((r) => r.ok ? r.text() : Promise.reject())'
      ".then((id) => id === '$_serverInstance' ? setTimeout(poll, 1000)"
      ' : location.reload())'
      '.catch(() => setTimeout(poll, 500)); };'
      'setTimeout(poll, 1000);'
      '})();</script>';
  return (
    statusCode: rendered.statusCode,
    body: utf8.encode(
      '${html.substring(0, index)}$script${html.substring(index)}',
    ),
    headers: rendered.headers,
  );
}

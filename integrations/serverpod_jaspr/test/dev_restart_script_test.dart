import 'dart:convert';

import 'package:jaspr/server.dart' as jaspr;
import 'package:serverpod_jaspr/src/dev_restart_script.dart';
import 'package:test/test.dart';

jaspr.ResponseLike _page() => (
  statusCode: 200,
  body: utf8.encode('<html><body><p>page</p></body></html>'),
  headers: const <String, List<String>>{},
);

void main() {
  test(
    'Given a rendered page and the generation of its browser code, '
    'when the restart script is added, '
    'then the script before </body> compares the loaded code against it.',
    () {
      final html = utf8.decode(
        withDevRestartScript(_page(), generation: 7).body,
      );

      expect(html, contains('const generation = 7;'));
      expect(html, contains(r'window.$dartLoadedGeneration'));
      expect(html, contains('<p>page</p><script>'));
      expect(html, endsWith('</script></body></html>'));
    },
  );

  test(
    'Given a rendered page without a known generation, '
    'when the restart script is added, '
    'then the script skips the generation check.',
    () {
      final html = utf8.decode(withDevRestartScript(_page()).body);

      expect(html, contains('const generation = null;'));
    },
  );

  test(
    'Given a response without a body element, '
    'when the restart script is added, '
    'then the response is returned as it is.',
    () {
      final rendered = (
        statusCode: 200,
        body: utf8.encode('plain'),
        headers: const <String, List<String>>{},
      );

      expect(withDevRestartScript(rendered, generation: 1), same(rendered));
    },
  );
}

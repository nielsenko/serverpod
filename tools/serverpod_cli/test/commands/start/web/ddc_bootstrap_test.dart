import 'dart:typed_data';

import 'package:serverpod_cli/src/commands/start/web/ddc_bootstrap.dart';
import 'package:serverpod_cli/src/commands/start/web/ddc_output.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Given the modules of an app, '
    'when its main module script is generated, '
    'then it queues every module by its path relative to the app root '
    'and runs main in the entrypoint library.',
    () {
      final modules = [
        _module('packages/app/main.dart.lib.js', 'packages/app/main.dart'),
        _module('packages/app/label.dart.lib.js', 'packages/app/label.dart'),
      ];

      final script = ddcMainModuleScript(
        entrypointLibrary: 'package:app/main.dart',
        modules: modules,
      );

      expect(script, contains('const appName = "package:app/main.dart";'));
      expect(
        script,
        contains(
          'const scripts = ['
          '{"src":"packages/app/main.dart.lib.js","id":"packages/app/main.dart"},'
          '{"src":"packages/app/label.dart.lib.js","id":"packages/app/label.dart"}'
          '];',
        ),
      );
    },
  );

  test(
    'Given the browser code of an app, '
    'when its reload client script is generated, '
    'then it listens for reload events below the app root.',
    () {
      expect(
        ddcReloadClientScript(),
        contains(r"new EventSource(appRoot + '$serverpodReload')"),
      );
    },
  );

  test(
    'Given the browser code of an app, '
    'when its reload client script is generated, '
    'then it announces a debug service so service extensions register.',
    () {
      final script = ddcReloadClientScript();

      expect(script, contains(r"globalThis.$dwdsVersion ??= 'serverpod';"));
      expect(
        script,
        contains(r'globalThis.$emitRegisterEvent ??= function () {};'),
      );
    },
  );

  test(
    'Given modules at a hot reload generation, '
    'when the main module script is generated, '
    'then it records the generation the page loads at.',
    () {
      final script = ddcMainModuleScript(
        entrypointLibrary: 'package:app/main.dart',
        modules: [
          _module('packages/app/main.dart.lib.js', 'packages/app/main.dart'),
        ],
        generation: 7,
      );

      expect(script, contains(r'window.$dartLoadedGeneration = 7;'));
    },
  );
}

DdcModule _module(String path, String name) => DdcModule(
  path: path,
  code: Uint8List(0),
  sourceMap: Uint8List(0),
  metadata: DdcModuleMetadata(name: name, libraries: const []),
);

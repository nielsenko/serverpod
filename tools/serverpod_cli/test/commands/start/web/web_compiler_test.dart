import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:serverpod_cli/src/commands/start/web/web_compiler.dart';
import 'package:serverpod_shared/process_io.dart';
import 'package:test/test.dart';

import '../../../test_util/file_system_entity_helpers.dart';

void main() {
  // Compiling the Dart SDK to JavaScript takes seconds, so the tests share
  // one cache. Which SDK is cached does not change what a test describes.
  late Directory sdkCache;

  setUpAll(() async {
    sdkCache = await Directory.systemTemp.createTemp('web_compiler_sdk_');
  });

  tearDownAll(() async {
    await sdkCache.deleteWithRetry(recursive: true);
  });

  group('Given a web package', () {
    late Directory packageDir;
    late WebCompiler compiler;

    setUp(() async {
      packageDir = await Directory.systemTemp.createTemp('web_compiler_test_');
      await _createWebPackage(packageDir.path);
      compiler = _compilerFor(packageDir.path, sdkCache.path);
    });

    tearDown(() async {
      await compiler.dispose();
      await packageDir.deleteWithRetry(recursive: true);
    });

    test(
      'when it is compiled, '
      'then the output holds the entry script, the runtime and its modules.',
      () async {
        final result = await compiler.compile();

        expect(result.success, isTrue, reason: result.diagnostics.join('\n'));
        expect(_files(_outputDir(packageDir.path)), {
          'main.dart.js',
          'main_module.bootstrap.js',
          'on_load_end_bootstrap.js',
          'dart_hot_reload.js',
          'ddc_module_loader.js',
          'dart_stack_trace_mapper.js',
          'reloaded_sources.json',
          'dart_sdk.js',
          'dart_sdk.js.map',
          'packages/web_app/main.dart.lib.js',
          'packages/web_app/main.dart.lib.js.map',
          'packages/web_app/label.dart.lib.js',
          'packages/web_app/label.dart.lib.js.map',
          'packages/web_app/shape.dart.lib.js',
          'packages/web_app/shape.dart.lib.js.map',
        });
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      'when it is compiled, '
      'then the result asks for a restart.',
      () async {
        final result = await compiler.compile();

        expect(result.requiresRestart, isTrue);
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  });

  group('Given a compiled web package', () {
    late Directory packageDir;
    late WebCompiler compiler;

    setUp(() async {
      packageDir = await Directory.systemTemp.createTemp('web_compiler_test_');
      await _createWebPackage(packageDir.path);
      compiler = _compilerFor(packageDir.path, sdkCache.path);
      final result = await compiler.compile();
      expect(result.success, isTrue, reason: result.diagnostics.join('\n'));
    });

    tearDown(() async {
      await compiler.dispose();
      await packageDir.deleteWithRetry(recursive: true);
    });

    test(
      'when a function body changes and the library is recompiled, '
      'then the reloaded sources list that library for a hot reload.',
      () async {
        await _writeLabel(packageDir.path, 'v2');

        final result = await compiler.recompile([_labelUri(packageDir.path)]);

        expect(result.success, isTrue, reason: result.diagnostics.join('\n'));
        expect(result.requiresRestart, isFalse);
        final reloaded =
            jsonDecode(
                  File(
                    p.join(
                      _outputDir(packageDir.path),
                      'reloaded_sources.json',
                    ),
                  ).readAsStringSync(),
                )
                as Map<String, Object?>;
        expect(
          reloaded['entries'],
          contains(
            equals({
              'generation': 2,
              'src': 'packages/web_app/label.dart.lib.js?gen=2',
              'module': 'packages/web_app/label.dart',
              'libraries': ['package:web_app/label.dart'],
            }),
          ),
        );
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      'when a function body changes and the library is recompiled, '
      'then the module on disk holds the new code.',
      () async {
        await _writeLabel(packageDir.path, 'v2');

        await compiler.recompile([_labelUri(packageDir.path)]);

        expect(
          File(
            p.join(
              _outputDir(packageDir.path),
              'packages/web_app/label.dart.lib.js',
            ),
          ).readAsStringSync(),
          contains('label v2'),
        );
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      'when a new library is imported and recompiled, '
      'then the main module script loads the new module '
      'and the modules this compile did not change.',
      () async {
        await File(
          p.join(packageDir.path, 'lib', 'extra.dart'),
        ).writeAsString("String extra() => 'extra';\n");
        await File(p.join(packageDir.path, 'lib', 'main.dart')).writeAsString(
          "import 'extra.dart';\n"
          "import 'label.dart';\n"
          "import 'shape.dart';\n\n"
          'void main() => print([label(), describe(const Shape(3)), '
          'extra()]);\n',
        );

        final result = await compiler.recompile([
          Uri.file(p.join(packageDir.path, 'lib', 'main.dart')),
        ]);

        expect(result.success, isTrue, reason: result.diagnostics.join('\n'));
        final mainModule = File(
          p.join(_outputDir(packageDir.path), 'main_module.bootstrap.js'),
        ).readAsStringSync();
        expect(
          mainModule,
          allOf(
            contains(
              '{"src":"packages/web_app/extra.dart.lib.js",'
              '"id":"packages/web_app/extra.dart"}',
            ),
            contains(
              '{"src":"packages/web_app/shape.dart.lib.js",'
              '"id":"packages/web_app/shape.dart"}',
            ),
          ),
        );
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      'when a field is removed from a const class and recompiled, '
      'then the hot reload is rejected.',
      () async {
        await _removeShapeField(packageDir.path);

        final result = await compiler.recompile([_shapeUri(packageDir.path)]);

        expect(result.success, isFalse);
        expect(result.hotReloadRejected, isTrue);
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      'when a change that hot reload rejects is recompiled with a restart, '
      'then the compile succeeds and asks for a restart.',
      () async {
        await _removeShapeField(packageDir.path);
        await compiler.recompile([_shapeUri(packageDir.path)]);

        final result = await compiler.recompile([
          _shapeUri(packageDir.path),
        ], restart: true);

        expect(result.success, isTrue, reason: result.diagnostics.join('\n'));
        expect(result.requiresRestart, isTrue);
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      'when a library the app does not import is recompiled, '
      'then no module is written and the generation stays.',
      () async {
        final other = File(p.join(packageDir.path, 'lib', 'other.dart'));
        await other.writeAsString("String other() => 'other';\n");
        final before = _reloadedSources(packageDir.path);

        final result = await compiler.recompile([Uri.file(other.path)]);

        expect(result.success, isTrue, reason: result.diagnostics.join('\n'));
        expect(result.modules, isEmpty);
        expect(_reloadedSources(packageDir.path), before);
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      'when a hot reload is followed by a restart, '
      'then the reloaded sources start over at a generation past the hot '
      'reload.',
      () async {
        await _writeLabel(packageDir.path, 'v2');
        await compiler.recompile([_labelUri(packageDir.path)]);
        await _writeLabel(packageDir.path, 'v3');

        await compiler.recompile([_labelUri(packageDir.path)], restart: true);

        expect(
          _reloadedSources(packageDir.path),
          {'generation': 3, 'since': 3, 'entries': <Object>[]},
        );
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      'when a library with a syntax error is recompiled, '
      'then the compile fails with diagnostics and is not a rejected reload.',
      () async {
        await File(
          p.join(packageDir.path, 'lib', 'label.dart'),
        ).writeAsString("String label() => 'broken' +;\n");

        final result = await compiler.recompile([_labelUri(packageDir.path)]);

        expect(result.success, isFalse);
        expect(result.hotReloadRejected, isFalse);
        expect(result.diagnostics, contains(contains('label.dart')));
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      'when a syntax error is fixed after a failed compile, '
      'then the next recompile succeeds.',
      () async {
        await File(
          p.join(packageDir.path, 'lib', 'label.dart'),
        ).writeAsString("String label() => 'broken' +;\n");
        await compiler.recompile([_labelUri(packageDir.path)]);
        await _writeLabel(packageDir.path, 'v3');

        final result = await compiler.recompile([_labelUri(packageDir.path)]);

        expect(result.success, isTrue, reason: result.diagnostics.join('\n'));
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      'when a library is fixed after its failed compile '
      'and only another library is recompiled, '
      'then the fixed library is compiled too.',
      () async {
        await File(
          p.join(packageDir.path, 'lib', 'label.dart'),
        ).writeAsString("String label() => 'broken' +;\n");
        await compiler.recompile([_labelUri(packageDir.path)]);
        await _writeLabel(packageDir.path, 'v3');

        final result = await compiler.recompile([_shapeUri(packageDir.path)]);

        expect(result.success, isTrue, reason: result.diagnostics.join('\n'));
        final label = result.modules.singleWhere(
          (m) => m.path == 'packages/web_app/label.dart.lib.js',
        );
        expect(utf8.decode(label.code), contains('label v3'));
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  });
}

String _outputDir(String packageDir) =>
    p.join(packageDir, '.dart_tool', 'web', 'app');

Map<String, Object?> _reloadedSources(String packageDir) =>
    jsonDecode(
          File(
            p.join(_outputDir(packageDir), 'reloaded_sources.json'),
          ).readAsStringSync(),
        )
        as Map<String, Object?>;

WebCompiler _compilerFor(String packageDir, String sdkCacheDir) => WebCompiler(
  packageDir: packageDir,
  entrypoint: Uri.parse('package:web_app/main.dart'),
  packagesPath: p.join(packageDir, '.dart_tool', 'package_config.json'),
  outputDir: _outputDir(packageDir),
  sdkRoot: getSdkPath(),
  sdkCacheDir: sdkCacheDir,
);

Uri _labelUri(String packageDir) =>
    Uri.file(p.join(packageDir, 'lib', 'label.dart'));

Uri _shapeUri(String packageDir) =>
    Uri.file(p.join(packageDir, 'lib', 'shape.dart'));

Set<String> _files(String dir) => {
  for (final entity in Directory(dir).listSync(recursive: true))
    if (entity is File)
      p.posix.joinAll(p.split(p.relative(entity.path, from: dir))),
};

Future<void> _writeLabel(String packageDir, String version) => File(
  p.join(packageDir, 'lib', 'label.dart'),
).writeAsString("String label() => 'label $version';\n");

Future<void> _removeShapeField(String packageDir) =>
    File(
      p.join(packageDir, 'lib', 'shape.dart'),
    ).writeAsString('''
class Shape {
  const Shape(int sides);
}

String describe(Shape shape) => 'shape';
''');

/// A package without dependencies whose `main.dart` imports two libraries:
/// `label.dart` with a plain function and `shape.dart` with a const class.
Future<void> _createWebPackage(String dir) async {
  await Directory(p.join(dir, 'lib')).create(recursive: true);
  await Directory(p.join(dir, '.dart_tool')).create(recursive: true);
  await File(p.join(dir, 'pubspec.yaml')).writeAsString('''
name: web_app
environment:
  sdk: ^3.0.0
''');
  await File(p.join(dir, 'lib', 'main.dart')).writeAsString(
    "import 'label.dart';\n"
    "import 'shape.dart';\n\n"
    'void main() => print([label(), describe(const Shape(3))]);\n',
  );
  await _writeLabel(dir, 'v1');
  await File(p.join(dir, 'lib', 'shape.dart')).writeAsString('''
class Shape {
  final int sides;
  const Shape(this.sides);
}

String describe(Shape shape) => 'shape with \${shape.sides} sides';
''');
  await File(p.join(dir, '.dart_tool', 'package_config.json')).writeAsString('''
{
  "configVersion": 2,
  "packages": [
    {"name": "web_app", "rootUri": "..", "packageUri": "lib/"}
  ]
}
''');
}

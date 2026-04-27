import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:serverpod_cli/src/commands/start/native_assets_builder.dart';
import 'package:test/test.dart';

void main() {
  group('Given a project with no packages that have build hooks', () {
    late Directory tempDir;
    late NativeAssetsBuilder builder;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'native_assets_builder_test_',
      );
      await _createMinimalDartProject(tempDir.path);
      builder = NativeAssetsBuilder(
        dartExecutable: _dartExecutable(),
        serverDir: tempDir.path,
        packageConfigPath: p.join(
          tempDir.path,
          '.dart_tool',
          'package_config.json',
        ),
        outputDir: p.join(tempDir.path, '.dart_tool', 'serverpod', 'na'),
      );
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'when build is called, '
      'then it returns NativeAssetsBuildSkipped',
      () async {
        final outcome = await builder.build();
        expect(outcome, isA<NativeAssetsBuildSkipped>());
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'when build is called, '
      'then no manifest yaml is written',
      () async {
        await builder.build();
        expect(File(builder.manifestPath).existsSync(), isFalse);
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'when build is called twice, '
      'then both calls succeed without error',
      () async {
        final first = await builder.build();
        final second = await builder.build();
        expect(first, isA<NativeAssetsBuildSkipped>());
        expect(second, isA<NativeAssetsBuildSkipped>());
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });
}

/// Creates a minimal Dart project with `pubspec.yaml` and a
/// `package_config.json` that has no packages with `hook/` directories. This
/// is the smallest input the hook runner accepts.
Future<void> _createMinimalDartProject(String dir) async {
  await Directory('$dir/.dart_tool').create(recursive: true);

  await File('$dir/pubspec.yaml').writeAsString('''
name: test_server
environment:
  sdk: ^3.0.0
''');

  await File('$dir/.dart_tool/package_config.json').writeAsString('''
{
  "configVersion": 2,
  "packages": [
    {
      "name": "test_server",
      "rootUri": "..",
      "packageUri": "lib/"
    }
  ]
}
''');

  // hooks_runner asserts this file exists alongside package_config.json.
  await File('$dir/.dart_tool/package_graph.json').writeAsString('''
{
  "roots": ["test_server"],
  "packages": [
    {
      "name": "test_server",
      "version": "1.0.0",
      "dependencies": [],
      "devDependencies": []
    }
  ],
  "configVersion": 1
}
''');
}

/// Resolves the dart executable from the SDK currently running these tests.
String _dartExecutable() {
  final exe = Platform.resolvedExecutable;
  // When tests run under `dart test`, resolvedExecutable is dart itself.
  // When run under dartaotruntime (e.g. via the AOT serverpod CLI), prefer
  // the sibling `dart` binary in the same SDK bin directory.
  if (p.basenameWithoutExtension(exe) == 'dart') return exe;
  final dir = p.dirname(exe);
  return p.join(dir, Platform.isWindows ? 'dart.exe' : 'dart');
}

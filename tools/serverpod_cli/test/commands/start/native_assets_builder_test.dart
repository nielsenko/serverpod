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

  group('Given a workspace with the server as a member package', () {
    late Directory tempDir;
    late NativeAssetsBuilder builder;
    late String serverDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'native_assets_builder_workspace_test_',
      );
      serverDir = p.join(tempDir.path, 'server');
      await _createWorkspaceProject(
        rootDir: tempDir.path,
        memberDir: serverDir,
      );
      builder = NativeAssetsBuilder(
        dartExecutable: _dartExecutable(),
        serverDir: serverDir,
        outputDir: p.join(serverDir, '.dart_tool', 'serverpod', 'na'),
      );
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'when discoverPaths is called from the member dir, '
      'then it returns the workspace root pubspec and package_config',
      () async {
        final paths = await builder.discoverPaths();

        expect(
          p.equals(
            paths.workspacePubspecPath,
            p.join(tempDir.path, 'pubspec.yaml'),
          ),
          isTrue,
          reason:
              'workspacePubspecPath should be the root pubspec, not the '
              'member pubspec. Got: ${paths.workspacePubspecPath}',
        );
        expect(
          p.equals(
            paths.packageConfigPath,
            p.join(tempDir.path, '.dart_tool', 'package_config.json'),
          ),
          isTrue,
          reason:
              'packageConfigPath should be at the workspace root .dart_tool/. '
              'Got: ${paths.packageConfigPath}',
        );
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });
}

/// Creates a Dart workspace at [rootDir] with one member at [memberDir].
/// `.dart_tool/` lives only at the workspace root, matching real pub layout.
Future<void> _createWorkspaceProject({
  required String rootDir,
  required String memberDir,
}) async {
  final relMember = p.relative(memberDir, from: rootDir);

  await Directory('$rootDir/.dart_tool').create(recursive: true);
  await Directory(memberDir).create(recursive: true);

  await File('$rootDir/pubspec.yaml').writeAsString('''
name: test_workspace
environment:
  sdk: ^3.8.0
workspace:
  - $relMember
''');

  await File('$memberDir/pubspec.yaml').writeAsString('''
name: test_server
environment:
  sdk: ^3.8.0
resolution: workspace
''');

  await File('$rootDir/.dart_tool/package_config.json').writeAsString('''
{
  "configVersion": 2,
  "packages": [
    {
      "name": "test_workspace",
      "rootUri": "..",
      "packageUri": "lib/"
    },
    {
      "name": "test_server",
      "rootUri": "../$relMember",
      "packageUri": "lib/"
    }
  ]
}
''');

  await File('$rootDir/.dart_tool/package_graph.json').writeAsString('''
{
  "roots": ["test_workspace", "test_server"],
  "packages": [
    {
      "name": "test_workspace",
      "version": "1.0.0",
      "dependencies": [],
      "devDependencies": []
    },
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

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:serverpod_cli/src/commands/start/jaspr/jaspr_apps.dart';
import 'package:serverpod_cli/src/util/serverpod_cli_logger.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() async {
    initializeLogger();
    root = await Directory.systemTemp.createTemp('jaspr_apps_config_');
  });

  tearDown(() async {
    await closeLogger();
    await root.delete(recursive: true);
  });

  test(
    'Given a server pubspec declaring a Jaspr app whose path has no package, '
    'when the apps are loaded, '
    'then that app is left out and the others are kept.',
    () async {
      final serverDir = p.join(root.path, 'demo_server');
      final webDir = p.join(root.path, 'demo_web');
      await Directory(serverDir).create(recursive: true);
      await Directory(webDir).create(recursive: true);
      await File(
        p.join(webDir, 'pubspec.yaml'),
      ).writeAsString('name: demo_web\n');
      await File(p.join(serverDir, 'pubspec.yaml')).writeAsString('''
name: demo_server
serverpod:
  jaspr_apps:
    website:
      path: ../demo_web
    admin:
      path: ../demo_admin
''');

      final apps = loadJasprApps(
        serverDir: serverDir,
        serverpodToolDir: p.join(serverDir, '.dart_tool', 'serverpod'),
      );

      expect(apps.map((app) => app.id), ['website']);
      expect(apps.single.packageName, 'demo_web');
    },
  );
}

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:serverpod_cli/src/util/serverpod_cli_logger.dart';
import 'package:serverpod_shared/serverpod_shared.dart';
import 'package:yaml/yaml.dart';

import '../web/web_compiler.dart';
import 'build_daemon_codegen.dart';
import 'jaspr_shape.dart';

/// A Jaspr app from `serverpod.jaspr_apps` in the server's `pubspec.yaml`.
class JasprAppConfig {
  /// The app's identifier, which its `JasprRoute` uses too.
  final String id;

  /// The root of the app's package.
  final String packageDir;

  /// The name of the app's package.
  final String packageName;

  /// Where the runner writes the app's compiled browser code.
  final String outputDir;

  const JasprAppConfig({
    required this.id,
    required this.packageDir,
    required this.packageName,
    required this.outputDir,
  });

  /// The app's browser entrypoint.
  Uri get clientEntrypoint =>
      Uri.parse('package:$packageName/main.client.dart');

  /// The file Jaspr's generator writes for the browser entrypoint.
  String get clientOptionsPath =>
      p.join(packageDir, 'lib', 'main.client.options.dart');
}

/// Reads `serverpod.jaspr_apps` from the server's `pubspec.yaml`:
///
/// ```yaml
/// serverpod:
///   jaspr_apps:
///     website:
///       path: ../my_project_web
/// ```
List<JasprAppConfig> loadJasprApps({
  required String serverDir,
  required String serverpodToolDir,
}) {
  final pubspec = File(p.join(serverDir, 'pubspec.yaml'));
  if (!pubspec.existsSync()) return const [];
  final yaml = loadYaml(pubspec.readAsStringSync());
  if (yaml is! YamlMap) return const [];
  final serverpod = yaml['serverpod'];
  if (serverpod is! YamlMap) return const [];
  final apps = serverpod['jaspr_apps'];
  if (apps is! YamlMap) return const [];

  return [
    for (final MapEntry(:key, :value) in apps.entries)
      if (value is YamlMap && value['path'] is String)
        ?_appConfig(
          id: key as String,
          packageDir: p.normalize(
            p.absolute(serverDir, value['path'] as String),
          ),
          serverpodToolDir: serverpodToolDir,
        ),
  ];
}

/// Null, with the error logged, when there is no package at [packageDir].
JasprAppConfig? _appConfig({
  required String id,
  required String packageDir,
  required String serverpodToolDir,
}) {
  final pubspec = File(p.join(packageDir, 'pubspec.yaml'));
  if (!pubspec.existsSync()) {
    log.error(
      'The Jaspr app "$id" has no pubspec.yaml at $packageDir. '
      'Check its path under serverpod.jaspr_apps in the server\'s '
      'pubspec.yaml.',
    );
    return null;
  }
  final yaml = loadYaml(pubspec.readAsStringSync());
  return JasprAppConfig(
    id: id,
    packageDir: packageDir,
    packageName: (yaml as YamlMap)['name'] as String,
    outputDir: p.join(serverpodToolDir, 'jaspr', id),
  );
}

/// The value of [jasprAppsEnvironmentVariable] for [apps].
String jasprAppsEnvironment(Iterable<JasprAppConfig> apps) => encodeJasprApps({
  for (final app in apps)
    app.id: JasprAppLocation(
      packageDir: app.packageDir,
      outputDir: app.outputDir,
    ),
});

/// What the browsers of the Jaspr apps need after a change.
enum JasprClientUpdate {
  /// The browser code is unchanged.
  none,

  /// New browser code can be hot reloaded.
  hotReload,

  /// The browsers have to load the page again.
  restart,

  /// The browser code failed to compile. The browsers keep the old code.
  failed,
}

/// Generates and compiles the browser code of the Jaspr apps under
/// `serverpod start`.
class JasprApps {
  final List<JasprAppConfig> apps;
  final String _packagesPath;
  final String _sdkCacheDir;
  final _compilers = <String, WebCompiler>{};

  /// The build_runner daemon of each app, which generates its Jaspr code.
  final _codegens = <String, BuildDaemonCodegen>{};

  /// The [jasprShapeOf] of each source file, as of the last generation.
  final _shapes = <String, String?>{};

  /// The content of each generated source as the daemon last reported it.
  /// The daemon reports every output a build step wrote, changed or not.
  final _generatedSources = <String, String>{};

  /// The generated sources [generate] returned, with the content the cycle
  /// compiled. The watcher reports these files again afterwards.
  final _settledGenerated = <String, String>{};

  /// The Dart SDK the server compiles with.
  final String _sdkRoot;

  /// The `dart` executable of [_sdkRoot].
  final String _dartExecutable;

  JasprApps(
    this.apps, {
    required String packagesPath,
    required String sdkRoot,
    required String dartExecutable,
    required String sdkCacheDir,
  }) : _packagesPath = packagesPath,
       _sdkRoot = sdkRoot,
       _dartExecutable = dartExecutable,
       _sdkCacheDir = sdkCacheDir;

  /// The directories to watch: each app's sources and static files.
  Iterable<String> get watchPaths => [
    for (final app in apps) ...[
      p.join(app.packageDir, 'lib'),
      p.join(app.packageDir, 'web'),
    ],
  ];

  /// Whether [path] is one of the apps' static files.
  bool isStaticFile(String path) => apps.any(
    (app) => p.isWithin(p.join(app.packageDir, 'web'), path),
  );

  /// The generation of each app's browser code, by app id.
  Map<String, int> get generations => {
    for (final MapEntry(key: id, value: compiler) in _compilers.entries)
      id: compiler.generation,
  };

  /// Generates any missing Jaspr code, then compiles every app.
  Future<bool> start() async {
    var ok = true;
    for (final app in apps) {
      await _recordShapes(app);
      final codegen = await _startCodegen(app);
      if (codegen == null) {
        ok = false;
        continue;
      }
      _recordGeneratedSources(codegen.initialBuild.changedFiles);
      final compiler = _compilers[app.id] = WebCompiler(
        packageDir: app.packageDir,
        entrypoint: app.clientEntrypoint,
        packagesPath: _packagesPath,
        outputDir: app.outputDir,
        sdkRoot: _sdkRoot,
        sdkCacheDir: _sdkCacheDir,
      );
      final watch = Stopwatch()..start();
      final WebCompileResult result;
      try {
        result = await compiler.compile();
      } catch (e) {
        log.error('Compiling Jaspr app "${app.id}" for the browser failed: $e');
        ok = false;
        continue;
      }
      if (result.success) {
        log.info(
          'Compiled Jaspr app "${app.id}" for the browser '
          'in ${watch.elapsedMilliseconds} ms.',
        );
      } else {
        ok = false;
        _logFailure(app, result);
      }
    }
    return ok;
  }

  /// Starts the build_runner daemon of [app] and records its first build.
  /// Null, with the failure logged, when the daemon or its first build
  /// failed.
  Future<BuildDaemonCodegen?> _startCodegen(JasprAppConfig app) async {
    final watch = Stopwatch()..start();
    final BuildDaemonCodegen codegen;
    try {
      codegen = await BuildDaemonCodegen.start(
        packageDir: app.packageDir,
        packageName: app.packageName,
        dartExecutable: _dartExecutable,
      );
    } catch (e) {
      log.error('Starting build_runner for "${app.id}" failed: $e');
      return null;
    }
    _codegens[app.id] = codegen;
    if (!codegen.initialBuild.success) {
      log.error('The first build_runner build for "${app.id}" failed.');
      return null;
    }
    log.info(
      'Started build_runner for "${app.id}" '
      'in ${watch.elapsedMilliseconds} ms.',
    );
    return codegen;
  }

  /// Generates the Jaspr code of each app where a file among [dartFiles]
  /// changed what the generator reads. Returns the generated sources whose
  /// content changed.
  ///
  /// A daemon build costs about a second even when nothing needs generating,
  /// so an app whose shapes are unchanged skips it. Its next build picks the
  /// skipped files up. A daemon that exited is started again.
  Future<Set<String>> generate(Iterable<String> dartFiles) async {
    final generated = <String>{};
    for (final app in apps) {
      var codegen = _codegens[app.id];
      if (codegen == null) continue;
      final inputs = dartFiles
          .where((f) => p.isWithin(app.packageDir, f) && !_isGeneratedFile(f))
          .toSet();
      if (inputs.isEmpty || !await _shapesChanged(inputs)) continue;

      var build = codegen.daemonExited ? null : await codegen.build();
      if (build == null || build.daemonExited) {
        log.info('build_runner for "${app.id}" exited. Starting it again.');
        await codegen.dispose();
        codegen = await _startCodegen(app);
        if (codegen == null) continue;
        build = codegen.initialBuild;
      }
      if (!build.success) {
        log.error('Generating Jaspr code for "${app.id}" failed.');
        continue;
      }
      final outputs = _recordGeneratedSources(build.changedFiles);
      log.info(
        'Generated Jaspr code for "${app.id}" '
        'in ${build.elapsed.inMilliseconds} ms'
        '${outputs.isEmpty ? '' : ', changing ${outputs.map(p.basename).join(', ')}'}.',
      );
      for (final path in outputs) {
        generated.add(path);
        _settledGenerated[path] = _generatedSources[path]!;
      }
    }
    return generated;
  }

  /// The generated sources among [reported] whose content changed, recording
  /// the new content. The daemon reports the inputs of a build too, and
  /// outputs in the artifact tree, whose paths do not exist.
  Set<String> _recordGeneratedSources(Set<String> reported) {
    final changed = <String>{};
    for (final path in reported) {
      if (!_isGeneratedFile(path)) continue;
      final file = File(path);
      if (!file.existsSync()) continue;
      final content = file.readAsStringSync();
      if (_generatedSources[path] != content) changed.add(path);
      _generatedSources[path] = content;
    }
    return changed;
  }

  /// Whether the watcher reports [path] only because [generate] wrote it,
  /// with the content that was compiled then.
  bool isSettledGenerated(String path) {
    final content = _settledGenerated.remove(path);
    if (content == null) return false;
    try {
      return File(path).readAsStringSync() == content;
    } on FileSystemException {
      return false;
    }
  }

  /// Recompiles the apps' browser code for [dartFiles].
  Future<JasprClientUpdate> recompile(Iterable<String> dartFiles) async {
    if (dartFiles.isEmpty) return JasprClientUpdate.none;
    final invalidated = [for (final f in dartFiles) Uri.file(f)];
    var update = JasprClientUpdate.none;
    for (final app in apps) {
      final compiler = _compilers[app.id];
      if (compiler == null) continue;
      final watch = Stopwatch()..start();
      // The browser reads its client options once, in main, so new or
      // changed @client components need the page to load again.
      final optionsChanged = dartFiles.contains(app.clientOptionsPath);
      var result = await compiler.recompile(
        invalidated,
        restart: optionsChanged,
      );
      if (result.hotReloadRejected) {
        log.info('Hot reload of "${app.id}" rejected; restarting the page.');
        result = await compiler.recompile(invalidated, restart: true);
      }
      if (!result.success) {
        _logFailure(app, result);
        update = JasprClientUpdate.failed;
        continue;
      }
      if (result.modules.isEmpty) continue;
      log.info(
        'Compiled ${result.modules.length} Jaspr modules for "${app.id}" '
        'in ${watch.elapsedMilliseconds} ms.',
      );
      final appUpdate = result.requiresRestart
          ? JasprClientUpdate.restart
          : JasprClientUpdate.hotReload;
      if (update.index < appUpdate.index) update = appUpdate;
    }
    return update;
  }

  Future<void> dispose() async {
    for (final compiler in _compilers.values) {
      await compiler.dispose();
    }
    for (final codegen in _codegens.values) {
      await codegen.dispose();
    }
  }

  static bool _isGeneratedFile(String path) =>
      path.endsWith('.options.dart') ||
      path.endsWith('.sync.dart') ||
      path.endsWith('.imports.dart');

  Future<void> _recordShapes(JasprAppConfig app) async {
    final lib = Directory(p.join(app.packageDir, 'lib'));
    if (!lib.existsSync()) return;
    await for (final file in lib.list(recursive: true)) {
      if (file is File &&
          file.path.endsWith('.dart') &&
          !_isGeneratedFile(file.path)) {
        _shapes[file.path] = jasprShapeOf(await file.readAsString());
      }
    }
  }

  /// Whether any of [files] changed its [jasprShapeOf], recording the new
  /// shapes. A new, deleted or unparsable file counts as a change.
  Future<bool> _shapesChanged(Iterable<String> files) async {
    var changed = false;
    for (final path in files) {
      final file = File(path);
      final shape = await file.exists()
          ? jasprShapeOf(await file.readAsString())
          : null;
      final known = _shapes.containsKey(path);
      if (!known || shape == null || shape != _shapes[path]) changed = true;
      if (shape == null) {
        _shapes.remove(path);
      } else {
        _shapes[path] = shape;
      }
    }
    return changed;
  }

  void _logFailure(JasprAppConfig app, WebCompileResult result) {
    log.error(
      'Compiling Jaspr app "${app.id}" for the browser failed:\n'
      '${result.diagnostics.join('\n')}',
    );
  }
}

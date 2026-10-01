import 'dart:async';

import 'package:build_daemon/client.dart';
import 'package:build_daemon/constants.dart';
import 'package:build_daemon/data/build_status.dart';
import 'package:build_daemon/data/build_target.dart';
import 'package:build_daemon/data/server_log.dart';
import 'package:path/path.dart' as p;
import 'package:serverpod_cli/src/util/serverpod_cli_logger.dart';

/// What one build of a [BuildDaemonCodegen] did.
class CodegenBuild {
  /// Whether every target built.
  final bool success;

  /// The files the build wrote or changed in the package, and the inputs
  /// that triggered it, as absolute paths.
  final Set<String> changedFiles;

  /// How long the request took, from asking to the result.
  final Duration elapsed;

  /// Whether the daemon exited before the build finished.
  final bool daemonExited;

  const CodegenBuild({
    required this.success,
    required this.changedFiles,
    required this.elapsed,
    this.daemonExited = false,
  });
}

/// Runs a package's build_runner builders through `build_runner daemon` in
/// manual mode: it builds only when asked, and reports what changed.
///
/// The daemon keeps the build script, asset graph and analyzer warm between
/// builds. Manual mode leaves file watching to the caller, which asks for a
/// build after a change and compiles what the result lists.
///
/// A package with committed generated files needs build_runner's fix for the
/// daemon's first build, see docs/design/jaspr_in_process.md.
class BuildDaemonCodegen {
  final String packageDir;
  final String packageName;

  /// The build [start] ran.
  late final CodegenBuild initialBuild;

  final BuildDaemonClient _client;

  /// Whether the daemon exited or announced that it will. It exits by itself
  /// when its build script changes, such as after a pubspec.yaml edit.
  bool get daemonExited => _daemonExited;
  bool _daemonExited = false;
  late final Future<void> _exited = Future.any([
    _client.finished,
    _client.shutdownNotifications.first,
  ]).then((_) => _daemonExited = true);

  BuildDaemonCodegen._(this.packageDir, this.packageName, this._client) {
    _exited.ignore();
  }

  /// Starts or joins the daemon for [packageDir] with [dartExecutable] and
  /// runs a first build.
  static Future<BuildDaemonCodegen> start({
    required String packageDir,
    required String packageName,
    required String dartExecutable,
  }) async {
    final client = await BuildDaemonClient.connect(
      packageDir,
      [dartExecutable, 'run', 'build_runner', 'daemon'],
      buildMode: BuildMode.Manual,
      logHandler: _log,
    );
    // Only lib/. A Jaspr package's web/ is the job of build_web_compilers,
    // which the runner's own compiler replaces.
    client.registerBuildTarget(
      DefaultBuildTarget(
        (b) => b
          ..target = 'lib'
          ..reportChangedAssets = true,
      ),
    );
    final codegen = BuildDaemonCodegen._(packageDir, packageName, client);
    codegen.initialBuild = await codegen.build();
    return codegen;
  }

  /// Builds the package and waits for the result, or for the daemon to
  /// exit, which never completes a build.
  Future<CodegenBuild> build() async {
    final watch = Stopwatch()..start();
    final done = Completer<BuildResults?>();
    final results = _client.buildResults.listen((r) {
      if (r.results.every((t) => t.status != BuildStatus.started) &&
          !done.isCompleted) {
        done.complete(r);
      }
    });
    unawaited(
      _exited.then((_) {
        if (!done.isCompleted) done.complete(null);
      }),
    );
    if (!_daemonExited) _client.startBuild();
    final result = await done.future;
    await results.cancel();
    if (result == null) {
      return CodegenBuild(
        success: false,
        changedFiles: const {},
        elapsed: watch.elapsed,
        daemonExited: true,
      );
    }
    return CodegenBuild(
      success: result.results.every((t) => t.status == BuildStatus.succeeded),
      changedFiles: {
        for (final uri in result.changedAssets ?? const <Uri>[]) ?_pathOf(uri),
      },
      elapsed: watch.elapsed,
    );
  }

  Future<void> dispose() => _client.close();

  // The daemon reports `package:<name>/<path>` for files in lib/, and
  // `asset:<name>/<path>` for the rest of the package.
  String? _pathOf(Uri uri) {
    final segments = uri.pathSegments;
    if (segments.isEmpty || segments.first != packageName) return null;
    final rest = segments.skip(1);
    return switch (uri.scheme) {
      'package' => p.joinAll([packageDir, 'lib', ...rest]),
      'asset' => p.joinAll([packageDir, ...rest]),
      _ => null,
    };
  }

  static void _log(ServerLog entry) {
    final message = 'build_runner: ${entry.message}';
    if (entry.level >= Level.SEVERE) {
      log.error(message);
    } else if (entry.level >= Level.WARNING) {
      log.warning(message);
    } else {
      log.debug(message);
    }
  }
}

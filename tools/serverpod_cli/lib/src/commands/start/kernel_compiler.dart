import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:serverpod_cli/src/commands/messages.dart';
import 'package:serverpod_cli/src/util/serverpod_cli_logger.dart';
import 'package:serverpod_cli/src/vendored/frontend_server_client.dart';
import 'package:serverpod_shared/process_io.dart';
import 'package:serverpod_shared/serverpod_shared.dart';

export 'package:serverpod_cli/src/vendored/frontend_server_client.dart'
    show CompileResult;

/// Manages incremental Dart compilation using the Frontend Server.
///
/// Tracks whether a full or incremental compile is needed internally.
/// After [start], [reset], or [restart], the next [compile] will produce
/// a complete kernel. Otherwise, [compile] performs an incremental build
/// using the provided [changedPaths].
class KernelCompiler {
  final String entryPoint;
  final String outputDill;
  final String? packagesPath;
  final String target;
  final String? workingDirectory;
  final List<String> extraArgs;

  /// Native-assets manifest path forwarded as `--native-assets` to the
  /// Frontend Server on [start]. Mutable so callers can swap the manifest
  /// between Frontend Server restarts; the FES reads this only at startup,
  /// so changes require a [restart] to take effect.
  String? nativeAssetsPath;

  final String _dartSdk;
  final String _sdkRoot;
  final String _platformDill;
  late Future<FrontendServerClient> _client;

  bool _needsFullCompile = true;
  bool _started = false;

  /// True when the most recent [compile] call returned an "unchanged"
  /// result without touching FES. [accept] and [reject] then no-op
  /// (there's nothing for FES to accept or reject).
  bool _lastWasNoOp = false;

  KernelCompiler({
    required this.entryPoint,
    this.outputDill = '.dart_tool/serverpod/server.dill',
    this.packagesPath,
    this.nativeAssetsPath,
    this.target = 'vm',
    String? dartSdk,
    String? sdkRoot,
    String? platformDill,
    this.workingDirectory,
    this.extraArgs = const [],
  }) : _dartSdk = dartSdk ?? getSdkPath(),
       _sdkRoot = sdkRoot ?? dartSdk ?? getSdkPath(),
       _platformDill =
           platformDill ??
           p.join(
             sdkRoot ?? dartSdk ?? getSdkPath(),
             'lib',
             '_internal',
             'vm_platform_strong.dill',
           );

  /// Construct a compiler for `target: flutter`, using the dart runtime
  /// bundled with [flutterRoot] and its `flutter_patched_sdk` as the
  /// compile-time SDK.
  factory KernelCompiler.flutter({
    required String flutterRoot,
    required String entryPoint,
    required String outputDill,
    String? packagesPath,
    String? workingDirectory,
    List<String> extraArgs = const ['--track-widget-creation'],
  }) {
    final dartSdk = p.join(flutterRoot, 'bin', 'cache', 'dart-sdk');
    final patchedSdk = p.join(
      flutterRoot,
      'bin',
      'cache',
      'artifacts',
      'engine',
      'common',
      'flutter_patched_sdk',
    );
    return KernelCompiler(
      entryPoint: entryPoint,
      outputDill: outputDill,
      packagesPath: packagesPath,
      target: 'flutter',
      dartSdk: dartSdk,
      sdkRoot: patchedSdk,
      platformDill: p.join(patchedSdk, 'platform_strong.dill'),
      workingDirectory: workingDirectory,
      extraArgs: extraArgs,
    );
  }

  /// The path to the `dart` executable from the SDK used by this compiler.
  String get dartExecutable => p.join(_dartSdk, 'bin', 'dart');

  /// Whether [start] has run.
  bool get isStarted => _started;

  /// Whether the most recent [compile] short-circuited as unchanged without a
  /// FES round-trip. Callers that ship the dill elsewhere (e.g. a DevFS push)
  /// read this to decide whether there is new output to send.
  bool get lastCompileWasNoOp => _lastWasNoOp;

  /// Exists while the Frontend Server may be writing [outputDill]; left
  /// behind if the session dies mid-compile.
  String get _compileMarkerPath => '$outputDill.compiling';

  /// Start the Frontend Server process and kick off an initial compile
  /// in the background.
  ///
  /// When [outputDill] from a previous session exists, FES is started
  /// with `--initialize-from-dill` pointing at it - subsequent compiles
  /// then produce incremental deltas rather than a full kernel.
  ///
  /// The initial compile (pre-warm) runs in the background. Callers
  /// that need a fresh dill on disk before consumer code observes it
  /// (e.g. before booting the server from [outputDill]) should
  /// `await ensureWarm()`. Callers that just need the FES to be ready
  /// for subsequent incremental compiles (e.g. the Flutter side, where
  /// the native build runs in parallel) can ignore [ensureWarm] and
  /// let the first reload await it implicitly.
  Future<void> start() async {
    if (_started) return;

    final allArgs = [
      ...extraArgs,
      if (File(outputDill).existsSync()) ...[
        '--initialize-from-dill',
        outputDill,
      ],
    ];

    _client = FrontendServerClient.start(
      entryPoint,
      outputDill,
      _platformDill,
      dartSdk: _dartSdk,
      sdkRoot: _sdkRoot,
      target: target,
      packagesJson: packagesPath,
      nativeAssetsPath: nativeAssetsPath,
      workingDirectory: workingDirectory,
      extraArgs: allArgs,
    );
    _started = true;
    _needsFullCompile = true;
    _prewarmFuture = _runPrewarm();
  }

  /// Returns `true` if [outputDill] exists, is newer than every file under
  /// [watchDirs], is compatible with the current Dart SDK's kernel binary
  /// format, and the last compile that wrote it completed.
  Future<bool> isDillUpToDate(Set<String> watchDirs) async {
    if (File(_compileMarkerPath).existsSync()) return false;

    final dillFile = File(outputDill);
    if (!await dillFile.exists()) return false;

    if (!_dillHeadersMatch(outputDill, _platformDill)) return false;

    final dillMtime = (await dillFile.stat()).modified;

    for (final watchDir in watchDirs) {
      final dir = Directory(watchDir);
      if (!await dir.exists()) continue;
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File &&
            (await entity.stat()).modified.isAfter(dillMtime)) {
          return false;
        }
      }
    }

    return true;
  }

  /// Compiles the project if the cached dill is stale relative to [watchDirs].
  ///
  /// Returns `true` on success (including when no compilation was needed).
  /// Returns `false` if compilation failed.
  Future<bool> compileIfNeeded(Set<String> watchDirs) async {
    if (File(_compileMarkerPath).existsSync()) {
      log.warning(previousCompileInterrupted);
      await invalidateCachedDill();
      // Ensure a complete kernel, not an incremental delta.
      await reset();
    } else if (await isDillUpToDate(watchDirs)) {
      log.debug('Cached server.dill is up to date, skipping initial compile.');
      return true;
    }

    final result = await compileWithProgress('Compiling server', this);
    if (result == null) return false;
    await accept();
    return true;
  }

  /// Deletes the cached kernel outputs and the compile marker so the next
  /// compile starts fresh. Used when the cached build cannot be trusted.
  Future<void> invalidateCachedDill() async {
    await File(outputDill).deleteIfExists();
    await File('$outputDill.incremental.dill').deleteIfExists();
    await File(_compileMarkerPath).deleteIfExists();
  }

  /// Compile the project.
  ///
  /// If a full compile is needed (after [start], [reset], or [restart]),
  /// [changedPaths] is ignored and a complete kernel is produced.
  /// Otherwise, performs an incremental recompile for [changedPaths].
  ///
  /// When [changedPaths] is empty and a full compile isn't pending,
  /// returns a [CompileResult.unchanged] pointing at the existing
  /// [outputDill] without touching FES. The default fallback in
  /// `FrontendServerClient.compile` is to invalidate the entrypoint
  /// when no URIs are given - that triggers FES to re-walk the
  /// entire dependency graph for nothing. The short-circuit avoids it.
  ///
  /// When [invalidatePackageConfig] is `true`, the package-config file is
  /// added to the invalidated set. The Frontend Server's incremental compiler
  /// re-reads it and rebuilds its package map in place, so a `package_config`
  /// change is picked up without restarting the process.
  Future<CompileResult> compile({
    Set<String> changedPaths = const {},
    bool invalidatePackageConfig = false,
  }) async {
    final client = await _client;

    if (!_needsFullCompile && changedPaths.isEmpty) {
      log.debug('compile: no changes, reusing $outputDill');
      _lastWasNoOp = true;
      return CompileResult.unchanged(outputDill);
    }

    final marker = File(_compileMarkerPath)..createSync(recursive: true);
    _lastWasNoOp = false;

    final CompileResult result;
    if (_needsFullCompile) {
      log.debug('compile: full');
      result = await client.compile();
      _needsFullCompile = false;
    } else {
      // Invalidate the exact URI the FES was started with (see
      // [FrontendServerClient.packageConfigUri]) so the resident compiler
      // reloads its package map in place instead of the reload silently
      // no-op'ing on a mismatched URI.
      final packageConfigUri = invalidatePackageConfig
          ? client.packageConfigUri
          : null;
      log.debug(
        'compile: $changedPaths'
        '${packageConfigUri != null ? ' (+package_config.json)' : ''}',
      );
      final invalidatedUris = [
        ...changedPaths.map(Uri.file),
        ?packageConfigUri,
      ];
      result = await client.compile(invalidatedUris);
    }

    // A null dillOutput means the FES died mid-write; keep the marker.
    if (result.dillOutput != null) {
      try {
        marker.deleteSync();
      } on FileSystemException {
        // A stray marker only costs an extra full compile.
      }
    }
    return result;
  }

  /// Accept the last compile result. No-op when the last compile was
  /// short-circuited as unchanged (FES has no pending work to accept).
  ///
  /// Awaitable so callers can order it before disposing or reloading; the
  /// underlying FES `accept` is a fire-and-forget stdin write.
  Future<void> accept() async {
    if (_lastWasNoOp) return;
    final client = await _client;
    client.accept();
  }

  /// Reject the last compile result. No-op when the last compile was
  /// short-circuited as unchanged.
  Future<void> reject() async {
    if (_lastWasNoOp) return;
    final client = await _client;
    await client.reject();
  }

  /// Reset the compiler so the next [compile] produces a complete kernel.
  ///
  /// Use this when incremental state may be stale (e.g., an external reload
  /// happened without going through this compiler).
  Future<void> reset() async {
    if (_needsFullCompile) return; // No compile yet; already in full state.
    final client = await _client;
    client.reset();
    _needsFullCompile = true;
  }

  /// Restart the Frontend Server process.
  ///
  /// Required when the native-assets manifest (`--native-assets`) changes,
  /// since the FES reads that argument only at startup. Kills the existing
  /// process and starts a fresh one.
  ///
  /// A `package_config.json` change does *not* need a restart - pass
  /// `invalidatePackageConfig: true` to [compile] instead.
  Future<void> restart() async {
    await dispose();
    await start();
  }

  /// Stop the Frontend Server process.
  Future<void> dispose() async {
    if (_started) {
      final client = await _client;
      client.kill();
      _started = false;
    }
  }

  Future<CompileResult?>? _prewarmFuture;

  Future<CompileResult?> _runPrewarm() async {
    try {
      final result = await compile();
      if (result.errorCount > 0) {
        await reject();
      } else {
        await accept();
      }
      return result;
    } catch (e) {
      log.debug('FES pre-warm failed: $e (first compile will retry)');
      return null;
    }
  }

  /// Awaits the background pre-warm compile. Returns its
  /// [CompileResult], or `null` if pre-warm failed unexpectedly.
  ///
  /// Server boot path awaits this before `dart run <outputDill>` so
  /// the boot dill reflects current sources. Flutter side awaits it
  /// inside `_devFsReload` to avoid colliding with FES, which is
  /// serial.
  Future<CompileResult?> ensureWarm() => _prewarmFuture ?? Future.value(null);
}

/// Runs a compilation step with progress feedback.
///
/// Returns the [CompileResult] on success, or `null` if compilation failed.
/// On failure, logs compiler output. If [rejectOnFailure] is true, also
/// rejects the compile result via [compiler].
Future<CompileResult?> compileWithProgress(
  String message,
  KernelCompiler compiler, {
  Set<String> changedPaths = const {},
  bool invalidatePackageConfig = false,
  bool rejectOnFailure = false,
}) async {
  late CompileResult result;
  final success = await log.progress(message, () async {
    result = await compiler.compile(
      changedPaths: changedPaths,
      invalidatePackageConfig: invalidatePackageConfig,
    );
    return result.errorCount == 0;
  });

  if (!success) {
    for (final line in result.compilerOutputLines) {
      log.error(line);
    }
    if (rejectOnFailure) {
      await compiler.reject();
    }
    return null;
  }

  return result;
}

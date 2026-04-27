import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:data_assets/data_assets.dart';
import 'package:file/local.dart';
import 'package:hooks/hooks.dart';
// hooks_runner requires a `Logger` (from package:logging) on its constructor.
// We import the type only to satisfy the API and route every record through
// the serverpod CLI [log]; there are no log calls of our own against it.
import 'package:hooks_runner/hooks_runner.dart' as hr;
import 'package:logging/logging.dart' show Level, Logger, LogRecord;
import 'package:package_config/package_config.dart' as pc;
import 'package:path/path.dart' as p;
import 'package:serverpod_cli/src/util/serverpod_cli_logger.dart';
import 'package:serverpod_cli/src/vendored/native_assets_bundling.dart';

const _fileSystem = LocalFileSystem();

/// Outcome of a [NativeAssetsBuilder.build] invocation.
sealed class NativeAssetsBuildOutcome {
  const NativeAssetsBuildOutcome();
}

/// The project has no packages with native build hooks; nothing to do.
class NativeAssetsBuildSkipped extends NativeAssetsBuildOutcome {
  const NativeAssetsBuildSkipped();
}

/// The build ran (possibly cached). [manifestPath] is the path to the
/// `native_assets.yaml` to pass to `frontend_server` via `--native-assets`,
/// or `null` if the build produced no bundleable assets.
///
/// [manifestChanged] is `true` when the manifest content differs from the
/// previous successful build (or this is the first build). Callers should
/// restart `frontend_server` with the new manifest when this is `true`.
class NativeAssetsBuildSuccess extends NativeAssetsBuildOutcome {
  final String? manifestPath;
  final bool manifestChanged;
  final List<Uri> dependencies;

  const NativeAssetsBuildSuccess({
    required this.manifestPath,
    required this.manifestChanged,
    required this.dependencies,
  });
}

/// The build failed. [message] contains a short, user-facing summary; full
/// hook logs are emitted via the serverpod CLI logger as the build runs.
class NativeAssetsBuildFailed extends NativeAssetsBuildOutcome {
  final String message;
  const NativeAssetsBuildFailed(this.message);
}

/// Orchestrates `package:hooks_runner` on behalf of `serverpod start`.
///
/// `dart compile` refuses to run build hooks, and `frontend_server` does not
/// know how to find them - they live outside the kernel-compile pipeline.
/// This class fills that gap: invoke [build] once before each
/// `frontend_server` compile cycle, then feed [NativeAssetsBuildSuccess.manifestPath]
/// to `frontend_server` via `--native-assets`.
///
/// Hook execution is internally cached by `hooks_runner` keyed on hook
/// inputs/dependencies/environment, so re-invoking each watch cycle is cheap
/// when nothing changed.
class NativeAssetsBuilder {
  /// Path to the dart executable (used to compile and run individual hooks).
  final String dartExecutable;

  /// The server directory (the package whose hooks we recurse from).
  final String serverDir;

  /// Path to the `package_config.json` for the server's `.dart_tool` dir.
  final String packageConfigPath;

  /// Output directory for the assets and the manifest yaml (typically
  /// `<serverDir>/.dart_tool/serverpod/native_assets/`).
  final String outputDir;

  Future<hr.PackageLayout>? _packageLayoutFuture;
  Future<hr.NativeAssetsBuildRunner>? _runnerFuture;
  String? _lastManifestContent;

  /// Bridges `hooks_runner`'s `Logger` records into the serverpod CLI [log].
  /// Detached so it never escapes into the global `package:logging` hierarchy.
  late final Logger _logger = Logger.detached('hooks_runner')
    ..onRecord.listen(_forwardLogRecord);

  NativeAssetsBuilder({
    required this.dartExecutable,
    required this.serverDir,
    required this.packageConfigPath,
    required this.outputDir,
  });

  /// Path of the manifest yaml this builder writes (whether or not it has
  /// been written yet).
  String get manifestPath => p.join(outputDir, 'native_assets.yaml');

  /// Drops the cached package layout / runner so the next [build] reloads
  /// `package_config.json`. Call after a `pub get` or other change that
  /// adds or removes packages with build hooks.
  void reset() {
    _packageLayoutFuture = null;
    _runnerFuture = null;
    _lastManifestContent = null;
    _lastEncodedAssets = null;
  }

  Future<hr.PackageLayout> _loadPackageLayout() async {
    final pkgConfigUri = Uri.file(p.absolute(packageConfigPath));
    final packageConfig = await pc.loadPackageConfigUri(pkgConfigUri);

    // The server is the root package; we want to build hooks of the server
    // and all its (non-dev) transitive dependencies.
    final pubspecPath = p.join(serverDir, 'pubspec.yaml');
    final pubspecName = await _readPubspecName(pubspecPath);

    return hr.PackageLayout.fromPackageConfig(
      _fileSystem,
      packageConfig,
      pkgConfigUri,
      pubspecName,
      includeDevDependencies: false,
    );
  }

  Future<hr.NativeAssetsBuildRunner> _createRunner() async {
    final layout = await (_packageLayoutFuture ??= _loadPackageLayout());
    return hr.NativeAssetsBuildRunner(
      dartExecutable: Uri.file(dartExecutable),
      logger: _logger,
      fileSystem: _fileSystem,
      packageLayout: layout,
      userDefines: hr.UserDefines(
        workspacePubspec: Uri.file(p.absolute(serverDir, 'pubspec.yaml')),
      ),
    );
  }

  /// Runs build hooks for the server package and its transitive dependencies.
  Future<NativeAssetsBuildOutcome> build() async {
    final runner = await (_runnerFuture ??= _createRunner());

    final hookPackages = await runner.packagesWithBuildHooks();
    if (hookPackages.isEmpty) {
      return const NativeAssetsBuildSkipped();
    }

    final target = hr.Target.current;
    final extensions = <ProtocolExtension>[
      CodeAssetExtension(
        targetOS: target.os,
        linkModePreference: LinkModePreference.dynamic,
        targetArchitecture: target.architecture,
        macOS: target.os == OS.macOS
            ? MacOSCodeConfig(targetVersion: _minMacOSVersion)
            : null,
      ),
      DataAssetsExtension(),
    ];

    final result = await runner.build(
      extensions: extensions,
      linkingEnabled: false,
    );
    if (result.isFailure) {
      return NativeAssetsBuildFailed(
        'Native build hooks failed for: ${hookPackages.join(', ')}',
      );
    }

    final buildResult = result.success;
    final encodedAssets = buildResult.encodedAssets;

    // No bundleable assets -> no manifest needed. Tell the caller to ensure
    // FES is running without a --native-assets argument.
    if (encodedAssets.isEmpty) {
      final changed = _lastManifestContent != null;
      _lastManifestContent = null;
      // Best-effort cleanup of a stale manifest from a prior run.
      final stale = File(manifestPath);
      if (await stale.exists()) await stale.delete();
      return NativeAssetsBuildSuccess(
        manifestPath: null,
        manifestChanged: changed,
        dependencies: buildResult.dependencies,
      );
    }

    final outputUri = Directory(outputDir).uri;
    await Directory(outputDir).create(recursive: true);

    final kernelAssets = await bundleNativeAssets(
      encodedAssets,
      target,
      outputUri,
      relocatable: false,
    );

    // Render the manifest text (without writing it yet) so we can compare
    // against the previously written one before bouncing FES.
    const header =
        '# Native assets mapping for host OS in JIT mode.\n'
        '# Generated by serverpod_cli and package:hooks_runner.\n';
    final body = kernelAssets.toNativeAssetsFile();
    final newContent = '$header\n$body';

    final manifestFile = File(manifestPath);
    final exists = await manifestFile.exists();
    final priorContent = exists ? await manifestFile.readAsString() : null;
    final changed = priorContent != newContent;
    if (changed) {
      await manifestFile.create(recursive: true);
      await manifestFile.writeAsString(newContent);
    }
    _lastManifestContent = newContent;

    return NativeAssetsBuildSuccess(
      manifestPath: manifestPath,
      manifestChanged: changed,
      dependencies: buildResult.dependencies,
    );
  }
}

/// Minimum macOS deployment target. Matches dartdev's default for hosts that
/// only ever build for the current machine, so hooks compile against the same
/// floor as `dart run`.
const _minMacOSVersion = 13;

/// Routes a single `hooks_runner` log record into the serverpod CLI logger.
void _forwardLogRecord(LogRecord rec) {
  final v = rec.level.value;
  if (v >= Level.SEVERE.value) {
    log.error(rec.message);
  } else if (v >= Level.WARNING.value) {
    log.warning(rec.message);
  } else if (v >= Level.INFO.value) {
    log.info(rec.message);
  } else {
    log.debug(rec.message);
  }
}

Future<String> _readPubspecName(String pubspecPath) async {
  final lines = await File(pubspecPath).readAsLines();
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.startsWith('name:')) {
      final value = trimmed.substring('name:'.length).trim();
      // Strip optional surrounding quotes.
      return value.replaceAll(
        RegExp(
          r'^["'
          "'"
          r']|["'
          "'"
          r']$',
        ),
        '',
      );
    }
  }
  throw StateError('Could not find package name in $pubspecPath');
}

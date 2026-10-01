import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:serverpod_cli/src/vendored/frontend_server_client.dart';

import 'ddc_bootstrap.dart';
import 'ddc_output.dart';

/// What a [WebCompiler] compile produced.
class WebCompileResult {
  /// Whether the compile succeeded and its output was written.
  final bool success;

  /// Whether the frontend server rejected the change as a hot reload. The
  /// caller should compile again with `restart: true`.
  final bool hotReloadRejected;

  /// Compiler diagnostics, one message per line.
  final List<String> diagnostics;

  /// The modules written by this compile. After the first compile, these are
  /// the modules a hot reload loads.
  final List<DdcModule> modules;

  /// Whether the page must reload to run the new code. True for the first
  /// compile and for a restart, false for a hot reload.
  final bool requiresRestart;

  const WebCompileResult._({
    required this.success,
    required this.hotReloadRejected,
    required this.diagnostics,
    required this.modules,
    required this.requiresRestart,
  });
}

/// Compiles a web app with a resident frontend server to DDC's library
/// bundle format, which supports hot reload.
///
/// [outputDir] is served as the root of the app. It holds the entry script
/// named after the entrypoint (`main.client.dart.js` for
/// `main.client.dart`), the Dart SDK, the DDC module loader, the modules and
/// their source maps, and [DdcBootstrapFiles.reloadedSources] after each hot
/// reload compile. See [ddcReloadClientScript] for how a page reloads.
class WebCompiler {
  /// The directory of the package that holds [entrypoint].
  final String packageDir;

  /// The entrypoint library, such as `package:app/main.client.dart`.
  final Uri entrypoint;

  /// The `package_config.json` that resolves [entrypoint].
  final String packagesPath;

  final String outputDir;

  /// The Dart SDK whose frontend server and dev compiler compile the app,
  /// the one the server compiles with.
  final String sdkRoot;

  /// Where the compiled Dart SDK is kept, keyed by SDK version, so it is
  /// compiled once per SDK rather than once per app or session.
  final String sdkCacheDir;

  /// Environment declarations passed to the compiler as `-D`.
  final Map<String, String> defines;

  late final String _kernelDir = '$outputDir.kernel';

  FrontendServerClient? _client;
  final _errors = StringBuffer();
  final _modules = <String, DdcModule>{};
  int _generation = 0;

  /// The hot reload deltas since the last restart, at [_restartGeneration].
  final _deltas = <HotReloadDelta>[];
  int _restartGeneration = 0;

  /// The libraries of the last failed recompile. A rejected compile rolls
  /// the frontend server back to the code before it, so the next recompile
  /// invalidates them again.
  final _pendingInvalidated = <Uri>{};

  WebCompiler({
    required this.packageDir,
    required this.entrypoint,
    required this.packagesPath,
    required this.outputDir,
    required this.sdkRoot,
    required this.sdkCacheDir,
    this.defines = const {},
  });

  /// The name of the entry script in [outputDir], such as
  /// `main.client.dart.js`.
  String get entryScriptName => '${p.url.basename(entrypoint.path)}.js';

  /// The generation of the code in [outputDir], counting the compiles that
  /// wrote it. A page records the generation it loaded.
  int get generation => _generation;

  /// Compiles the whole app and writes [outputDir].
  ///
  /// Starts the frontend server on the first call. A later call starts over
  /// with a full compile.
  Future<WebCompileResult> compile() async {
    await dispose();
    _modules.clear();
    _pendingInvalidated.clear();
    await Directory(outputDir).create(recursive: true);
    await Directory(_kernelDir).create(recursive: true);

    // Runs alongside the app compile and is awaited after it. Until then,
    // `ignore` keeps an early failure from being reported as unhandled.
    final sdkReady = _writeRuntime()..ignore();
    final client = _client = await FrontendServerClient.start(
      entrypoint.toString(),
      p.join(_kernelDir, 'app.dill'),
      p.join(sdkRoot, 'lib', '_internal', 'ddc_outline.dill'),
      sdkRoot: sdkRoot,
      target: 'dartdevc',
      packagesJson: packagesPath,
      extraArguments: [
        '--dartdevc-module-format=ddc',
        '--dartdevc-canary',
        '--no-js-strongly-connected-components',
        '--experimental-emit-debug-metadata',
        '--filesystem-scheme=org-dartlang-app',
        '--filesystem-root=${p.absolute(packageDir)}',
        for (final MapEntry(:key, :value) in defines.entries) '-D$key=$value',
      ],
      errorSink: IOSink(_ErrorSinkConsumer(_errors)),
    );
    final result = await _finish(client, await client.compile(), restart: true);
    await sdkReady;
    return result;
  }

  /// Recompiles the libraries at [invalidated] and writes the changed
  /// modules.
  ///
  /// Prepares a hot reload unless [restart] is true. When the frontend
  /// server rejects the change as a hot reload, the result says so and
  /// nothing is written.
  Future<WebCompileResult> recompile(
    Iterable<Uri> invalidated, {
    bool restart = false,
  }) async {
    final client = _client;
    if (client == null) {
      throw StateError('Call compile() before recompile().');
    }
    final uris = {..._pendingInvalidated, ...invalidated};
    final result = await _finish(
      client,
      await client.compile(uris.toList(), restart),
      restart: restart,
    );
    if (result.success) {
      _pendingInvalidated.clear();
    } else {
      _pendingInvalidated.addAll(uris);
    }
    return result;
  }

  /// Stops the frontend server.
  Future<void> dispose() async {
    _client?.kill();
    _client = null;
  }

  Future<WebCompileResult> _finish(
    FrontendServerClient client,
    CompileResult result, {
    required bool restart,
  }) async {
    final diagnostics = [
      ...result.compilerOutputLines,
      ...const LineSplitter().convert(_errors.toString()),
    ];
    _errors.clear();

    final output = result.dillOutput;
    if (output == null || result.errorCount > 0) {
      await client.reject();
      return WebCompileResult._(
        success: false,
        hotReloadRejected: diagnostics.any(
          (line) => line.contains('Hot reload rejected'),
        ),
        diagnostics: diagnostics,
        modules: const [],
        requiresRestart: restart,
      );
    }
    client.accept();

    final modules = splitDdcOutput(
      code: await File('$output.sources').readAsBytes(),
      sourceMaps: await File('$output.map').readAsBytes(),
      metadata: await File('$output.metadata').readAsBytes(),
      manifest:
          jsonDecode(await File('$output.json').readAsString())
              as Map<String, Object?>,
    );
    // A change outside the app's libraries compiles nothing, and the pages
    // have nothing to load.
    if (!restart && modules.isEmpty) {
      return WebCompileResult._(
        success: true,
        hotReloadRejected: false,
        diagnostics: diagnostics,
        modules: modules,
        requiresRestart: false,
      );
    }
    for (final module in modules) {
      _modules[module.path] = module;
      await _writeBytes(module.path, module.code);
      await _writeBytes(module.sourceMapPath, module.sourceMap);
    }

    // A restart advances the generation too, so a page loaded before it is
    // older than `since` and loads again instead of hot reloading on top of
    // the code the restart replaced.
    _generation++;
    if (restart) {
      _deltas.clear();
      _restartGeneration = _generation;
    } else {
      _deltas.add(HotReloadDelta(_generation, modules));
    }
    await _write(
      DdcBootstrapFiles.reloadedSources,
      reloadedSourcesJson(
        generation: _generation,
        since: _restartGeneration,
        deltas: _deltas,
      ),
    );
    // A page that loads after this compile needs every module, including
    // ones added by it, and only deltas after it.
    await _write(
      DdcBootstrapFiles.mainModule,
      ddcMainModuleScript(
        entrypointLibrary: entrypoint.toString(),
        modules: _modules.values,
        generation: _generation,
      ),
    );

    return WebCompileResult._(
      success: true,
      hotReloadRejected: false,
      diagnostics: diagnostics,
      modules: modules,
      requiresRestart: restart,
    );
  }

  /// Writes the scripts that do not depend on the app's code.
  Future<void> _writeRuntime() async {
    final devCompiler = p.join(sdkRoot, 'lib', 'dev_compiler');
    await File(
      p.join(devCompiler, 'ddc', DdcBootstrapFiles.moduleLoader),
    ).copy(p.join(outputDir, DdcBootstrapFiles.moduleLoader));
    await File(
      p.join(devCompiler, 'web', DdcBootstrapFiles.stackTraceMapper),
    ).copy(p.join(outputDir, DdcBootstrapFiles.stackTraceMapper));
    await _write(entryScriptName, ddcEntryScript());
    await _write(DdcBootstrapFiles.onLoadEnd, ddcOnLoadEndScript());
    await _write(DdcBootstrapFiles.reloadClient, ddcReloadClientScript());

    final sdkDir = await _compiledSdk();
    for (final name in [
      DdcBootstrapFiles.dartSdk,
      '${DdcBootstrapFiles.dartSdk}.map',
    ]) {
      await File(p.join(sdkDir, name)).copy(p.join(outputDir, name));
    }
  }

  /// The directory holding `dart_sdk.js` for the running SDK, compiling it
  /// first if the cache has none.
  Future<String> _compiledSdk() async {
    final version = (await File(
      p.join(sdkRoot, 'version'),
    ).readAsString()).trim();
    final dir = p.join(sdkCacheDir, version);
    final sdkJs = File(p.join(dir, DdcBootstrapFiles.dartSdk));
    if (await sdkJs.exists()) return dir;

    // Compile next to the cache entry and rename it into place, so an
    // interrupted compile never leaves a partial SDK in the cache.
    await Directory(sdkCacheDir).create(recursive: true);
    final staging = await Directory(sdkCacheDir).createTemp('$version.');
    final exe = Platform.isWindows ? '.exe' : '';
    final result = await Process.run(
      p.join(sdkRoot, 'bin', 'dartaotruntime$exe'),
      [
        p.join(sdkRoot, 'bin', 'snapshots', 'dartdevc_aot.dart.snapshot'),
        '--multi-root-scheme=org-dartlang-sdk',
        '--modules=ddc',
        '--canary',
        '--module-name=dart_sdk',
        '-o',
        p.join(staging.path, DdcBootstrapFiles.dartSdk),
        p.join(sdkRoot, 'lib', '_internal', 'ddc_platform.dill'),
      ],
    );
    if (result.exitCode != 0) {
      await staging.delete(recursive: true);
      throw ProcessException(
        'dartdevc',
        const [],
        'Failed to compile the Dart SDK to JavaScript:\n'
            '${result.stdout}${result.stderr}',
        result.exitCode,
      );
    }
    try {
      await staging.rename(dir);
    } on FileSystemException {
      // Another session compiled it first.
      await staging.delete(recursive: true);
    }
    return dir;
  }

  Future<void> _write(String name, String content) =>
      _writeBytes(name, utf8.encode(content));

  // Through a temporary file, so a browser fetching the file meanwhile gets
  // the old or the new version, never a mix.
  Future<void> _writeBytes(String name, List<int> bytes) async {
    final file = File(p.join(outputDir, name));
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(file.path);
  }
}

/// Collects what the frontend server writes to stderr.
class _ErrorSinkConsumer implements StreamConsumer<List<int>> {
  final StringBuffer _buffer;

  _ErrorSinkConsumer(this._buffer);

  @override
  Future<void> addStream(Stream<List<int>> stream) =>
      stream.transform(utf8.decoder).forEach(_buffer.write);

  @override
  Future<void> close() async {}
}

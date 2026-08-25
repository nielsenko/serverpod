import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:cli_tools/cli_tools.dart';
import 'package:config/config.dart';
import 'package:meta/meta.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:serverpod_cli/analyzer.dart';
import 'package:serverpod_cli/src/analytics/cli_analytics.dart';
import 'package:serverpod_cli/src/analytics/session_metrics.dart';
import 'package:serverpod_cli/src/commands/attach.dart'
    show attachWithLogStream, attachWithTui, requireAttachSocket;
import 'package:serverpod_cli/src/commands/generate.dart';
import 'package:serverpod_cli/src/commands/messages.dart';
import 'package:serverpod_cli/src/commands/serverpod_command.dart';
import 'package:serverpod_cli/src/commands/serverpod_command_runner.dart';
import 'package:serverpod_cli/src/commands/start/file_watcher.dart';
import 'package:serverpod_cli/src/commands/start/flutter_app_manager.dart';
import 'package:serverpod_cli/src/commands/start/kernel_compiler.dart';
import 'package:serverpod_cli/src/commands/start/log_history.dart';
import 'package:serverpod_cli/src/commands/start/mcp_socket.dart';
import 'package:serverpod_cli/src/commands/start/native_assets_builder.dart';
import 'package:serverpod_cli/src/commands/start/package_dependency_tracker.dart';
import 'package:serverpod_cli/src/commands/start/server_process.dart';
import 'package:serverpod_cli/src/commands/start/watch_loop.dart';
import 'package:serverpod_cli/src/commands/start/watch_session.dart';
import 'package:serverpod_cli/src/commands/watcher.dart';
import 'package:serverpod_cli/src/config/config.dart';
import 'package:serverpod_cli/src/config/flutter_app_config.dart';
import 'package:serverpod_cli/src/config_info/config_info.dart';
import 'package:serverpod_cli/src/generator/generation_staleness.dart';
import 'package:serverpod_cli/src/generator/isolated_analyzers.dart';
import 'package:serverpod_cli/src/migrations/cli_migration_runner.dart';
import 'package:serverpod_cli/src/runner/local_runner_api.dart';
import 'package:serverpod_cli/src/runner/runner_discovery.dart';
import 'package:serverpod_cli/src/runner/runner_lock.dart';
import 'package:serverpod_cli/src/runner/runner_manifest.dart';
import 'package:serverpod_cli/src/runner/runner_manifest_publisher.dart';
import 'package:serverpod_cli/src/runner/runner_paths.dart';
import 'package:serverpod_cli/src/runner/runner_snapshot.dart';
import 'package:serverpod_cli/src/runner/runner_socket_server.dart';
import 'package:serverpod_cli/src/util/serverpod_cli_logger.dart';
import 'package:serverpod_cli/src/vm_proxy/proxy.dart';
import 'package:serverpod_cli/src/vm_proxy/serverpod_hooks.dart';
import 'package:serverpod_shared/serverpod_shared.dart' hide ExitException;
import 'package:stream_transform/stream_transform.dart';
import 'package:vm_service/vm_service.dart'
    show Event, EventStreams, RPCError, VmService;
import 'package:vm_service/vm_service_io.dart';

/// Options for the `start` command.
enum StartOption<V> implements OptionDefinition<V> {
  watch(
    FlagOption(
      argName: 'watch',
      argAbbrev: 'w',
      defaultsTo: true,
      negatable: true,
      helpText:
          'Watch files and use the Frontend Server for fast incremental compilation. '
          'With --no-watch, the server is started via `dart run`.',
    ),
  ),
  directory(
    StringOption(
      argName: 'directory',
      argAbbrev: 'd',
      defaultsTo: '',
      helpText:
          'The server directory (defaults to auto-detect from current directory).',
    ),
  ),
  docker(
    FlagOption(
      argName: 'docker',
      helpText:
          'Start Docker Compose services if a Docker Compose file exists. '
          'Defaults to on if the project has a Docker Compose file and the '
          'database is configured to PostgreSQL on localhost without a '
          'dataPath. Otherwise, defaults to off. Pass --docker or '
          '--no-docker to override the default behavior.',
    ),
  ),
  attach(
    FlagOption(
      argName: 'attach',
      defaultsTo: true,
      helpText:
          'Attach a UI once the stack is up. With --no-attach the runner is '
          'brought up, its address is printed, and the command returns.',
    ),
  ),
  tui(
    FlagOption(
      argName: 'tui',
      defaultsTo: true,
      helpText:
          'Show the interactive terminal UI when attaching. Ignored with '
          '--no-attach, since nothing renders.',
    ),
  ),
  flutter(
    FlagOption(
      argName: 'flutter',
      defaultsTo: true,
      helpText:
          'Auto-launch the companion Flutter apps as configured on the server '
          'pubspec.yaml with `auto_launch: true`. Use --no-flutter to disable '
          'auto-launch. Apps can still be started on demand from the TUI.',
    ),
  ),
  ;

  const StartOption(this.option);

  @override
  final ConfigOptionBase<V> option;
}

/// Command to generate code, start the server, and optionally watch for
/// changes.
class StartCommand extends ServerpodCommand<StartOption> {
  @override
  final name = 'start';

  @override
  final description =
      'Start the full development stack with hot reload: generates code, '
      'runs the server, and launches the companion Flutter apps in an '
      'interactive terminal UI.';

  @override
  String get invocation => 'serverpod start [-- <server-args>]';

  StartCommand() : super(options: StartOption.values);

  @override
  Configuration<StartOption> resolveConfiguration(ArgResults? argResults) {
    return Configuration.resolveNoExcept(
      options: options,
      argResults: argResults,
      env: envVariables,
      ignoreUnexpectedPositionalArgs: true,
    );
  }

  @override
  Future<void> runWithConfig(
    Configuration<StartOption> commandConfig,
  ) async {
    final config = await _loadConfig(commandConfig);
    final serverDir = p.joinAll(config.serverPackageDirectoryPathParts);
    final asked = RunnerConfig(
      watch: commandConfig.value(StartOption.watch),
      flutter: commandConfig.value(StartOption.flutter),
      serverArgs: argResults?.rest ?? const [],
    );

    // Idempotent: bring a runner up if there is none, and otherwise go straight
    // to attaching. A caller need not know whether the stack is already up in
    // this worktree; the stack is up when this returns zero.
    final manifest = await _ensureRunner(
      commandConfig: commandConfig,
      config: config,
      serverDir: serverDir,
      asked: asked,
      docker: commandConfig.optionalValue(StartOption.docker),
    );

    if (!commandConfig.value(StartOption.attach)) {
      // The path an agent takes: the address is printed and the command
      // returns, leaving the runner up.
      log.info('Runner ready (pid ${manifest.pid}).');
      log.info('Attach with `serverpod attach`, stop with `serverpod stop`.');
      return;
    }

    final socketPath = requireAttachSocket(manifest);
    final useTui = commandConfig.value(StartOption.tui) && stdout.hasTerminal;
    final exitCode = useTui
        ? await attachWithTui(socketPath)
        : await attachWithLogStream(socketPath);
    if (exitCode != 0) throw ExitException(exitCode);
  }

  Future<GeneratorConfig> _loadConfig(
    Configuration<StartOption> commandConfig,
  ) async {
    try {
      late final GeneratorConfig config;
      await log.progress('Loading project configuration', () async {
        config = await GeneratorConfig.load(
          serverRootDir: commandConfig.value(StartOption.directory),
          interactive: serverpodRunner.globalConfiguration.optionalValue(
            GlobalOption.interactive,
          ),
        );
        return true;
      });
      return config;
    } catch (e) {
      log.error('$e');
      throw ExitException(ServerpodCommand.commandInvokedCannotExecute);
    }
  }

  /// Returns the manifest of a runner serving [serverDir], starting one if
  /// there is none.
  ///
  /// Fails rather than attaching when a live runner disagrees with what this
  /// invocation asked for. Attaching anyway with a warning would leave a caller
  /// that reads only the exit status believing it got what it asked for.
  Future<RunnerManifest> _ensureRunner({
    required Configuration<StartOption> commandConfig,
    required GeneratorConfig config,
    required String serverDir,
    required RunnerConfig asked,
    required bool? docker,
  }) async {
    switch (await resolveRunner(serverDir)) {
      case IncompatibleRunner(:final message):
        log.error(message);
        throw ExitException.error();

      case LiveRunner(:final manifest, :final versionWarning):
        if (versionWarning != null) log.warning(versionWarning);
        final differences = manifest.config.differencesFrom(asked);
        if (differences.isNotEmpty) {
          log.error(
            'A serverpod runner is already running for "${config.name}", '
            'started with different options: ${differences.join(', ')}. '
            'Stop it with `serverpod stop` and start it again to change them.',
          );
          throw ExitException.error();
        }
        return manifest;

      case NoRunner():
        return _spawnRunner(
          commandConfig: commandConfig,
          config: config,
          serverDir: serverDir,
          asked: asked,
          docker: docker,
        );
    }
  }

  /// Spawns the runner detached and waits for it to publish its manifest.
  ///
  /// Detached, because the operating system delivers SIGINT to a whole process
  /// group: a runner spawned in this terminal's group would die on the next
  /// Ctrl+C in it. [ProcessStartMode.detached] puts it in a group of its own.
  Future<RunnerManifest> _spawnRunner({
    required Configuration<StartOption> commandConfig,
    required GeneratorConfig config,
    required String serverDir,
    required RunnerConfig asked,
    required bool? docker,
  }) async {
    // Fire-and-forget: analytics must never delay session start. Captured here
    // rather than in the runner so a stack is counted once however many clients
    // later attach to it.
    unawaited(
      _captureSessionStartAnalytics(
        config: config,
        commandConfig: commandConfig,
        useTui: commandConfig.value(StartOption.tui),
        launchFlutterApp: asked.flutter,
      ),
    );

    final process = await Process.start(
      Platform.resolvedExecutable,
      [
        // Re-invoke this same CLI. Run from source or from a pub-global
        // snapshot the executable is the Dart VM and the script has to be
        // passed; compiled to an executable it is the CLI itself, where
        // passing a script would make it the runner's first argument.
        if (_runsOnDartVm) Platform.script.toFilePath(),
        'runner',
        // No stdio to inherit once detached, so the runner writes its own log.
        '--detached',
        '--directory',
        serverDir,
        if (asked.watch) '--watch' else '--no-watch',
        if (asked.flutter) '--flutter' else '--no-flutter',
        if (docker == true) '--docker',
        if (docker == false) '--no-docker',
        if (asked.serverArgs.isNotEmpty) ...['--', ...asked.serverArgs],
      ],
      mode: ProcessStartMode.detached,
    );

    final manifest = await _awaitManifest(serverDir);
    if (manifest != null) return manifest;

    log.error(
      'The runner (pid ${process.pid}) did not come up in time. '
      'Its output, including why it stopped if it did, is in '
      '${serverpodRunnerLogPath(serverDir)}.',
    );
    throw ExitException.error();
  }

  /// Whether this process is the Dart VM running a script, rather than a
  /// compiled executable of the CLI itself.
  static bool get _runsOnDartVm =>
      p.basenameWithoutExtension(Platform.resolvedExecutable) == 'dart';

  /// Waits for the spawned runner to publish a manifest and answer on its
  /// socket, or gives up.
  ///
  /// The runner publishes only once the whole stack is up, so the wait has to
  /// cover code generation, a Docker Compose start and a cold compile. It also
  /// covers a runner that aborted before publishing - a held port, a held
  /// lock, a Docker failure - and there is no sign of that until the deadline
  /// passes, so the deadline stays as short as a legitimate cold start allows.
  Future<RunnerManifest?> _awaitManifest(
    String serverDir, {
    Duration timeout = const Duration(minutes: 2),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await resolveRunner(serverDir) case LiveRunner(:final manifest)) {
        return manifest;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return null;
  }
}

/// Constructs a [NativeAssetsBuilder] for the server at [serverDir]. The
/// builder discovers `package_config.json` itself (walking up to a workspace
/// root if needed).
NativeAssetsBuilder _createNativeAssetsBuilder({
  required String serverDir,
  required String projectRoot,
  required String serverpodToolDir,
  required String dartExecutable,
}) {
  return NativeAssetsBuilder(
    dartExecutable: dartExecutable,
    serverDir: serverDir,
    projectRoot: projectRoot,
    outputDir: p.join(serverpodToolDir, 'native_assets'),
  );
}

/// Runs build hooks via [builder] and applies the result to [compiler].
/// Returns false on hook failure (an error has been logged).
///
/// Wraps [NativeAssetsBuilder.applyTo] for the start.dart paths that don't
/// care about the restart-distinction (initial-build callers and the IDE
/// reload callback). The watch-loop and migration paths switch on the
/// outcome directly to read [NativeAssetsApplySuccess.restarted].
Future<bool> _runHooksFor(
  NativeAssetsBuilder builder,
  KernelCompiler compiler,
) async {
  final outcome = await builder.applyTo(compiler);
  switch (outcome) {
    case NativeAssetsApplySuccess():
      return true;
    case NativeAssetsApplyFailure(:final message):
      log.error(message);
      return false;
  }
}

Future<void> _captureSessionStartAnalytics({
  required GeneratorConfig config,
  required Configuration<StartOption> commandConfig,
  required bool useTui,
  required bool launchFlutterApp,
}) async {
  if (!cliAnalytics.enabled) return;

  await cliAnalytics.captureSessionStart(
    config: config,
    watchMode: commandConfig.value(StartOption.watch),
    tuiEnabled: useTui,
    flutterEnabled: launchFlutterApp,
    dockerMode: switch (commandConfig.optionalValue(StartOption.docker)) {
      true => DockerStartMode.on,
      false => DockerStartMode.off,
      null => DockerStartMode.auto,
    },
    dockerComposePresent:
        _findComposeFile(p.joinAll(config.serverPackageDirectoryPathParts)) !=
        null,
  );
}

/// Compose file names Docker Compose resolves by default, in its own lookup
/// order.
const _composeFileNames = [
  'compose.yaml',
  'compose.yml',
  'docker-compose.yaml',
  'docker-compose.yml',
];

File? _findComposeFile(String serverDir) {
  for (final name in _composeFileNames) {
    final file = File(p.join(serverDir, name));
    if (file.existsSync()) return file;
  }
  return null;
}

bool _resolveStartDocker({
  required bool? dockerFlag,
  required String serverDir,
  required String runMode,
}) {
  if (dockerFlag != null) return dockerFlag;

  // Projects without a compose file (e.g. using a remote or natively
  // installed database) have nothing for Docker Compose to start. Only an
  // explicit --docker treats a missing compose file as an error.
  if (_findComposeFile(serverDir) == null) return false;

  try {
    final passwords = PasswordManager(runMode: runMode).loadPasswords(
      serverDir: serverDir,
    );
    final serverConfig = ServerpodConfig.load(
      runMode,
      null,
      passwords,
      serverDir: serverDir,
    );
    final database = serverConfig.database;
    if (database is! PostgresDatabaseConfig || database.dataPath != null) {
      return false;
    }
    return database.host.toLowerCase() == 'localhost' ||
        database.host == '127.0.0.1';
  } catch (_) {
    // Config may be incomplete during early project setup; do not start
    // Docker automatically. Users can still pass --docker explicitly.
    return false;
  }
}

/// Ensures Docker Compose services are running.
///
/// Returns `true` if this method started the containers (meaning we should
/// stop them on shutdown), `false` if they were already running, and `null`
/// when Docker cannot be used.
Future<bool?> _ensureDockerServices(String serverDir) async {
  if (_findComposeFile(serverDir) == null) {
    log.error(dockerComposeFileMissing);
    return null;
  }

  // Check if containers are already running.
  final ps = await _runDocker(
    ['compose', 'ps', '--status', 'running', '-q'],
    serverDir,
  );

  if (ps == null) {
    log.error(dockerNotInstalled);
    return null;
  }

  if (ps.exitCode != 0) {
    log.error(dockerNotRunning);
    return null;
  }

  final running = (ps.stdout as String).trim();
  if (running.isNotEmpty) return false;

  // Start containers.
  final up = await _runDocker(['compose', 'up', '-d'], serverDir);

  if (up == null) {
    log.error(dockerNotInstalled);
    return null;
  }

  if (up.exitCode != 0) {
    final error = (up.stderr as String).trim();
    log.error('$dockerComposeStartFailed\n\n$error');
    return null;
  }

  log.info('Docker Compose services started.');
  return true;
}

/// Runs `docker` with [arguments] in [serverDir]. Returns `null` when the
/// binary cannot be launched (Docker not installed or not on PATH).
Future<ProcessResult?> _runDocker(
  List<String> arguments,
  String serverDir,
) async {
  try {
    return await Process.run(
      'docker',
      arguments,
      workingDirectory: serverDir,
    );
  } on ProcessException {
    return null;
  }
}

Future<void> _stopDockerServices(String serverDir) async {
  log.info('Stopping Docker Compose services...');
  await _runDocker(['compose', 'stop'], serverDir);
}

/// Prepends `--apply-migrations` to [serverArgs] unless it is already present.
///
/// Used for the **first** pod process started by `serverpod start` so pending
/// migrations run inside the server (without requiring the insights endpoint).
/// Also used when the CLI migration runner defers to the pod (e.g. missing
/// native database assets).
List<String> _withApplyMigrations(List<String> serverArgs) {
  if (serverArgs.contains('--apply-migrations')) return serverArgs;
  return ['--apply-migrations', ...serverArgs];
}

/// Watch-session [ApplyMigrationsAction] that applies pending and repair
/// migrations by calling the running pod's `applyMigrations` endpoint. The
/// pod itself runs the migration in-process; the CLI only triggers it.
Future<void> _applyMigrationsForSession({
  required String serverDir,
  required String runMode,
}) async {
  final client = ConfigInfo(
    runMode,
    serverDir: serverDir,
  ).createServiceClient();
  try {
    await client.insights.applyMigrations(
      applyRepairMigration: true,
      applyMigrations: true,
    );
  } finally {
    client.close();
  }
}

/// Brings the development stack up and returns the context that owns it.
///
/// Called only by the runner process: nothing renders here, and what a client
/// sees it gets from [RunnerApi]'s snapshot and events. The one thing that
/// still differs between invocations - where raw output is echoed, a terminal
/// in a foreground run and the log file when detached - is a parameter.
Future<WatchLoopSetupResult> setupWatchLoop({
  required GeneratorConfig config,
  required String serverDir,
  required ServerArgsRef serverArgs,
  required bool watch,
  required bool? docker,
  // When the project fails to generate or compile: if `true`, keep the session
  // open with no server running and recover later (the file watcher auto-boots
  // in watch mode; [WatchSession.retryStart] boots on demand otherwise). If
  // `false`, there is no way to recover (non-TUI `--no-watch`), so fail fast.
  required bool keepOpenOnFailure,
  required bool launchFlutterApp,
  required ShutdownSignal shutdown,
  // Session-wide log retention. Filled here rather than by the presentation
  // layer, so the MCP log tools serve the same content with and without the
  // TUI. See [StartLogHistory].
  required StartLogHistory logHistory,
  // Where raw Flutter output is echoed in addition to being recorded: the
  // terminal in a foreground session, the runner's log file when detached, and
  // null under the TUI, which owns the terminal and renders the recorded lines
  // itself.
  IOSink? flutterStdoutEcho,
  IOSink? flutterStderrEcho,
  IOSink? serverStdoutSink,
  IOSink? serverStderrSink,
}) async {
  log.info(watch ? 'Starting server in watch mode...' : 'Starting server...');

  // One runner per server package. Probing a socket is a check followed by a
  // use, so two runners racing can both find nothing and bind; this settles it
  // before either provisions anything. The kernel drops the lock when the
  // process dies, so a crash leaves nothing to clean up.
  final RunnerLock lock;
  try {
    lock = await RunnerLock.acquire(serverDir);
  } on RunnerLockedException catch (e) {
    log.error('$e');
    return const WatchLoopAborted(1);
  }

  final serverpodToolDir = serverpodToolDirPath(serverDir);
  final vmServiceInfoFile = p.join(serverpodToolDir, 'vm-service-info.json');
  // The pod always writes its raw VM service URI to a separate file; the
  // user-facing vm-service-info.json receives the proxy URI written by
  // _mountOrRetargetProxy.
  final podInfoFile = p.join(serverpodToolDir, 'vm-service-info.pod.json');

  // If a server is already running, abort so the IDE can attach to the
  // existing instance via the unchanged info file. Cheap local check; runs
  // before Docker Compose provisioning so we don't pay compose-up just to
  // discard it.
  final existingUri = await _checkExistingServer(vmServiceInfoFile);
  if (existingUri != null) {
    log.info('Existing server found.');
    log.info('VM service proxy listening on $existingUri');
    await lock.release();
    return const WatchLoopAborted(0);
  }

  final startDocker = _resolveStartDocker(
    dockerFlag: docker,
    serverDir: serverDir,
    runMode: runModeFromServerArgs(serverArgs.value),
  );

  var startedDocker = false;
  if (startDocker) {
    bool? dockerStarted;
    await log.progress(startingDockerServices, () async {
      dockerStarted = await _ensureDockerServices(serverDir);
      return dockerStarted != null;
    });
    if (dockerStarted == null) {
      await lock.release();
      return const WatchLoopAborted(1);
    }
    startedDocker = dockerStarted!;
  }

  Future<void> stopDockerIfStarted() async {
    if (startedDocker) await _stopDockerServices(serverDir);
  }

  // Every abort past this point routes through here, so the lock is released
  // exactly where the provisioning it guards is undone.
  Future<void> rollbackProvisioning() async {
    await stopDockerIfStarted();
    await lock.release();
  }

  // What the caller actually asked for, captured before the migration hook
  // rewrites it. The manifest publishes this rather than the mutated list, so
  // an identical second `start` compares like with like instead of disagreeing
  // with itself over an argument the runner added.
  final requestedServerArgs = [...serverArgs.value];

  // Apply pending migrations from the CLI before booting the pod.
  try {
    serverArgs.value = _withApplyMigrations(serverArgs.value);
  } catch (_) {
    await rollbackProvisioning();
    rethrow;
  }

  // prime: false - the single full prime happens inside generateIfStale; here
  // we only spawn the isolate eagerly so it overlaps the staleness check.
  final analyzersFuture = IsolatedAnalyzers.create(config, prime: false);
  Future<void> closeAnalyzers() async => (await analyzersFuture).close();

  // Tear down everything provisioned so far: the analyzer isolate and any
  // Docker services. A failed/in-flight analyzer future must not prevent the
  // Docker teardown, so closing it is guarded.
  Future<void> rollbackStartup() async {
    try {
      await closeAnalyzers();
    } catch (_) {}
    await rollbackProvisioning();
  }

  // keepPrimedWhenFresh: the analyzers are needed by the watch session even when
  // generation is up to date.
  late final ({bool upToDate, bool success}) genResult;
  try {
    genResult = await generateIfStale(
      config: config,
      keepPrimedWhenFresh: true,
      createAnalyzers: () async {
        late final IsolatedAnalyzers analyzers;
        await log.progress('Initializing analyzers', () async {
          analyzers = await analyzersFuture;
          return true;
        });
        return analyzers;
      },
    );
  } catch (_) {
    // Tear down even when analysis/generation throws, not just on a clean
    // failure.
    await rollbackStartup();
    rethrow;
  }

  // Whether the project is currently buildable. A clean generation failure no
  // longer aborts: in a recoverable session we keep watching with no server
  // and boot it once the user fixes the errors.
  var buildOk = genResult.success;
  if (!buildOk) {
    log.error('Code generation failed.');
    if (!keepOpenOnFailure) {
      await rollbackStartup();
      return const WatchLoopAborted(1);
    }
  } else if (genResult.upToDate) {
    log.info(generatedCodeAlreadyUpToDate, type: TextLogType.success);
  }

  // FES setup (watch mode only).
  KernelCompiler? compiler;
  NativeAssetsBuilder? nativeAssetsBuilder;
  String? dartExecutable;
  // The resolution's `.dart_tool` whose package_config.json the FES reads;
  // watched below so a dependency change is picked up in place.
  String? serverDartToolDir;
  // Scopes a shared (workspace) package_config.json change to the server's own
  // dependency closure so the pod reloads only when its closure actually
  // changed. Null disables the gate (always reload), matching prior behavior.
  PackageDependencyTracker? serverDependencyTracker;
  if (watch) {
    final entryPoint = p.join(serverDir, 'bin', 'main.dart');
    final initialDill = p.join(serverpodToolDir, 'server.dill');
    // Resolve the server's resolution root once and reuse it everywhere it is
    // needed: the compiler's `--packages` (so the in-place invalidation targets
    // the exact URI the CFE loaded, see KernelCompiler), the native-assets
    // builder, and the watch set below. Single walk, single source of truth.
    final projectRoot = await discoverProjectRootFrom(serverDir);
    serverDartToolDir = p.join(projectRoot, '.dart_tool');
    final packageConfigPath = p.join(serverDartToolDir, 'package_config.json');
    final localCompiler = KernelCompiler(
      entryPoint: entryPoint,
      outputDill: initialDill,
      packagesPath: packageConfigPath,
    );

    final localBuilder = _createNativeAssetsBuilder(
      serverDir: serverDir,
      projectRoot: projectRoot,
      serverpodToolDir: serverpodToolDir,
      dartExecutable: localCompiler.dartExecutable,
    );
    late final bool hooksOk;
    await log.progress('Running build hooks', () async {
      hooksOk = await _runHooksFor(localBuilder, localCompiler);
      return hooksOk;
    });
    if (!hooksOk) {
      await rollbackStartup();
      return const WatchLoopAborted(1);
    }

    await localCompiler.start();

    // Compile if the cached dill is stale. The FES starts in the background
    // (KernelCompiler gates compile/reset calls internally until start
    // completes), so if the dill is up to date we boot immediately.
    //
    // Skip the compile when generation already failed - the generated code is
    // invalid, so the compile would only fail noisily. The FES stays in its
    // fresh post-start state, ready for the watch session to compile from
    // scratch once the project is fixed.
    if (buildOk) {
      if (!await localCompiler.compileIfNeeded(
        config.watchPaths(includeWeb: true, includeClientPackage: true),
      )) {
        // Reject the failed compile so the FES returns to its last accepted
        // (empty) state, leaving it ready for a clean full compile on recovery.
        await localCompiler.reject();
        log.error('Initial compilation failed.');
        buildOk = false;
        if (!keepOpenOnFailure) {
          await localCompiler.dispose();
          await rollbackStartup();
          return const WatchLoopAborted(1);
        }
      }
    }

    compiler = localCompiler;
    nativeAssetsBuilder = localBuilder;
    dartExecutable = localCompiler.dartExecutable;

    // Seed the closure baseline now (before any file event) so the first
    // package_config.json change computes a real delta. resolveDartToolDir
    // validates the resolution lists the server package; a null disables the
    // gate. Reads the same `.dart_tool` the FES resolves, so no extra watch.
    final serverResolutionDartTool =
        PackageDependencyTracker.resolveDartToolDir(
          serverDir,
          packageName: config.serverPackage,
        );
    serverDependencyTracker = serverResolutionDartTool == null
        ? null
        : PackageDependencyTracker(
            dartToolDir: serverResolutionDartTool,
            packageName: config.serverPackage,
          );
  }

  // Set once the runner API is constructed below. The Flutter manager's
  // callbacks are wired before that, and an event raised earlier has no
  // attached client to reach, so a null here is not a lost event.
  LocalRunnerApi? runnerEvents;

  // IDE-facing Flutter VM-service proxies. Bound now so info files exist at
  // session start regardless of whether `--flutter` was passed.
  final runMode = runModeFromServerArgs(serverArgs.value);
  final serverPubspecFile = File(p.join(serverDir, 'pubspec.yaml'));
  final flutterManager = FlutterAppManager(
    runMode: runMode,
    projectName: config.name,
    // Auto-launch is armed when a UI first attaches, not now: a stack an
    // agent started with no UI should not spawn Flutter processes nobody is
    // watching, and `--flutter` must not mean different things depending on
    // which invocation spawned the runner.
    launchFlutterApp: false,
    serverpodToolDir: serverpodToolDir,
    serverPubspecFile: serverPubspecFile,
    serverPackageDirectoryPathParts: config.serverPackageDirectoryPathParts,
    onReady: (app, url) =>
        runnerEvents?.recordFlutterAppState(app.id, running: true, url: url),
    onStart: (app, process) => _recordExtensionEvents(
      process.vmService,
      (event) => logHistory.recordFlutterExtensionEvent(app.id, event),
    ),
    onStop: (app) =>
        runnerEvents?.recordFlutterAppState(app.id, running: false),
    onLaunchFailed: (app) =>
        runnerEvents?.recordFlutterAppState(app.id, running: false),
    onLog: (app, event) => logHistory.recordFlutterLogEvent(app.id, event),
    stdoutSinkFor: (app) =>
        logHistory.flutterOutputSink(app.id, forwardTo: flutterStdoutEcho),
    stderrSinkFor: (app) =>
        logHistory.flutterOutputSink(app.id, forwardTo: flutterStderrEcho),
  );
  await flutterManager.initialize();
  // No runner event here: nothing has attached this early, and the snapshot a
  // client gets on connect carries the app list.

  // Server process factory. Invoked for the initial start and for each
  // subsequent restart driven by the WatchSession
  late final WatchSession session;
  VmServiceProxy? proxy;
  Future<ServerProcess> serverProcessFactory(String? dillPath) async {
    final serverProcess = ServerProcess(
      serverDir: serverDir,
      serverArgs: serverArgs.value,
      dartExecutable: dartExecutable,
      enableVmService: true,
      vmServiceInfoFile: podInfoFile,
      stdoutSink: serverStdoutSink,
      stderrSink: serverStderrSink,
      onDispose: logHistory.discardActiveServerScopes,
    );
    await serverProcess.start(dillPath: dillPath);
    await serverProcess.connectToVmService();
    await _recordExtensionEvents(
      serverProcess.vmService,
      logHistory.recordServerLogEvent,
    );
    // Fires on the initial boot, on every restart, and on the first boot after
    // recovering from a degraded start.
    runnerEvents?.setStage(RunnerStage.running);
    proxy = await _mountOrRetargetProxy(
      serverProcess: serverProcess,
      existing: proxy,
      userInfoFile: vmServiceInfoFile,
      reload: watch ? () => session.forceReload() : null,
    );
    return serverProcess;
  }

  // Null in a degraded start: the project failed to build, so no server boots
  // now. The watch session brings it up once the project is fixed.
  ServerProcess? initialServerProcess;
  if (buildOk) {
    initialServerProcess = await bootInitialServer(
      initialDill: watch ? p.join(serverpodToolDir, 'server.dill') : null,
      startServer: serverProcessFactory,
      compiler: compiler,
    );
    if (initialServerProcess == null) {
      log.error('Initial compilation failed.');
      buildOk = false;
      if (!keepOpenOnFailure) {
        await compiler?.dispose();
        await flutterManager.dispose();
        await rollbackStartup();
        return const WatchLoopAborted(1);
      }
    }
  }
  if (!buildOk) {
    log.warning(watch ? startBlockedByErrorsWatch : startBlockedByErrorsManual);
  }

  StreamSubscription<void>? fileChangeSub;

  /// Sets up single watcher across server/shared/client/web/flutter.
  /// Changes serialize through session.handleFileChange via WatchSession._chain.
  void setupFileWatcher() {
    fileChangeSub?.cancel();
    if (!watch) return;
    final currentApps = flutterManager.apps.toList();
    final flutterPackageGraphPaths = [
      for (final app in currentApps)
        ?flutterManager.packageGraphPathFor(app.id),
    ];
    final watcher = FileWatcher(
      watchPaths: buildWatchPaths(
        config: config,
        flutterApps: currentApps,
        serverDartToolDir: serverDartToolDir,
        flutterPackageGraphPaths: flutterPackageGraphPaths,
      ),
      // Exact files so a change to one resolution's artifact never triggers the
      // other's action (matters only in a non-workspace layout). The server has
      // a single package_config.json; each Flutter app contributes its own
      // package_graph.json (they collapse to one entry in a workspace layout).
      packageConfigPath: serverDartToolDir == null
          ? null
          : p.join(serverDartToolDir, 'package_config.json'),
      packageGraphPaths: {
        ...flutterPackageGraphPaths,
      },
    );
    fileChangeSub = watcher.onFilesChanged
        .asyncMapBuffer((events) => session.handleFileChange(events.merge()))
        .listen((_) {});
  }

  // Construct the watch session.
  session = WatchSession(
    compiler: compiler,
    nativeAssetsBuilder: nativeAssetsBuilder,
    generate: (affectedPaths, requirements) async {
      return analyzeAndGenerate(
        analyzers: await analyzersFuture,
        config: config,
        affectedPaths: affectedPaths,
        incremental: true,
        requirements: requirements,
      );
    },
    // Full-project regeneration for on-demand recovery from a degraded start
    // (retryStart), where there is no incremental change event to scope it.
    fullGenerate: () async {
      final allSources = await enumerateSourceFiles(config);
      return analyzeAndGenerate(
        analyzers: await analyzersFuture,
        config: config,
        affectedPaths: allSources.keys.toSet(),
        incremental: false,
        verifyStaleness: false,
        sourceStats: allSources,
      );
    },
    createServer: serverProcessFactory,
    initialServer: initialServerProcess,
    generatedDirPaths: config.generatedDirPaths,
    serverDependencyTracker: serverDependencyTracker,
    flutterManager: flutterManager,
    flutterAppsLoader: () async {
      await flutterManager.loadApps();
      runnerEvents?.recordFlutterApps(flutterManager.apps.toList());
      setupFileWatcher();
    },
    applyMigrationsAction: () => _applyMigrationsForSession(
      serverDir: serverDir,
      runMode: runMode,
    ),
  );

  // Route IDE attach auto-launch through the session so it serializes with
  // reload/restart cycles.
  flutterManager.launchOnWaitingClient = session.spawnFlutterApp;

  // Forward server exit into the shutdown signal so the wait-for-exit
  // point only ever has to await [shutdown.future]
  unawaited(session.done.then(shutdown.complete));

  // The runner's capabilities, implemented once over the session and projected
  // by every surface: the MCP socket below, and the TUI via [WatchLoopContext].
  // Exposes the proxy URI (not the pod's) so MCP-initiated reloads flow through
  // the same interceptor that IDE attach uses.
  final runnerApi = LocalRunnerApi(
    session: session,
    flutterManager: flutterManager,
    logHistory: logHistory,
    config: config,
    runMode: runMode,
    vmServiceUri: () => proxy?.httpUri.toString(),
    requestShutdown: shutdown.complete,
    watchModeEnabled: watch,
  );
  runnerEvents = runnerApi;
  runnerApi.setStage(
    session.isRunning ? RunnerStage.running : RunnerStage.degraded,
  );

  // Start MCP socket server for AI agent integration.
  McpSocketServer? mcpSocket = McpSocketServer(serverDir: serverDir);
  try {
    await mcpSocket.start();
    mcpSocket.connect(runnerApi);
    log.info('MCP server listening on ${mcpSocket.socketPath}');
  } on SocketException catch (e) {
    log.warning('Failed to start MCP server: $e');
    mcpSocket = null;
  }

  // Start the attach socket, which a terminal UI or a plain log stream reads.
  RunnerSocketServer? attachSocket = RunnerSocketServer(serverDir: serverDir);
  try {
    await attachSocket.start();
    attachSocket.connect(runnerApi);
    if (launchFlutterApp) {
      attachSocket.onFirstClientAttached = () => unawaited(
        // Serialized behind any in-flight reload or restart, like every other
        // launch.
        session.launchAutoLaunchApps(),
      );
    }
  } on SocketException catch (e) {
    log.warning('Failed to start the attach server: $e');
    attachSocket = null;
  }

  setupFileWatcher();

  // Publish where to reach this runner and what it was started with, so
  // `status`, `attach` and a second `start` can find it. Written last, once
  // every socket is bound: a manifest naming a socket nothing answers on would
  // be indistinguishable from a crashed runner's.
  final publisher = RunnerManifestPublisher(
    serverDir: serverDir,
    manifest: RunnerManifest(
      pid: pid,
      sockets: RunnerSockets(
        tui: attachSocket?.socketPath ?? '',
        mcp: mcpSocket?.socketPath ?? '',
      ),
      vmService: RunnerVmServiceUris(proxy: proxy?.httpUri.toString()),
      docker: startDocker
          ? RunnerDocker(
              startedByRunner: startedDocker,
              project: composeProjectName(serverDir),
            )
          : null,
      config: RunnerConfig(
        watch: watch,
        flutter: launchFlutterApp,
        docker: startDocker,
        serverArgs: requestedServerArgs,
      ),
    ),
  );
  await publisher.publish();
  publisher.republishOn(session.vmServiceUriChanges, (current) {
    final updated = current.copyWith(
      vmService: RunnerVmServiceUris(proxy: proxy?.httpUri.toString()),
    );
    runnerApi.recordManifest(updated);
    return updated;
  });

  return WatchLoopReady(
    WatchLoopContext(
      session: session,
      runnerApi: runnerApi,
      proxy: () => proxy,
      flutterManager: flutterManager,
      mcpSocket: mcpSocket,
      attachSocket: attachSocket,
      closeAnalyzers: closeAnalyzers,
      announceStopping: () => runnerApi.setStage(RunnerStage.stopping),
      stopFileWatcher: () => fileChangeSub?.cancel(),
      stopDocker: startedDocker ? () => _stopDockerServices(serverDir) : null,
      vmServiceInfoFile: vmServiceInfoFile,
      manifestPublisher: publisher,
      lock: lock,
    ),
  );
}

/// Forwards [vmService]'s `Extension` events to [onEvent] for as long as the
/// process is connected.
///
/// This is where the structured logs of the server and of every Flutter app
/// enter the session's [StartLogHistory]. A stream that cannot be subscribed
/// to costs those logs, not the session, so it is warned about, not thrown.
Future<void> _recordExtensionEvents(
  VmService? vmService,
  void Function(Event event) onEvent,
) async {
  if (vmService == null) return;
  try {
    await vmService.streamListen(EventStreams.kExtension);
  } on RPCError catch (e) {
    log.warning('Could not subscribe to the VM service log stream: $e');
    return;
  }
  vmService.onExtensionEvent.listen(onEvent);
}

/// Boots the initial server process, recovering once from a corrupt cached
/// dill (a pod that dies before publishing its VM service URI never got past
/// kernel loading). Returns `null` if the recovery recompile fails.
@visibleForTesting
Future<ServerProcess?> bootInitialServer({
  required String? initialDill,
  required Future<ServerProcess> Function(String? dillPath) startServer,
  required KernelCompiler? compiler,
}) async {
  Future<ServerProcess> boot() async {
    late ServerProcess server;
    await log.progress('Starting server', () async {
      server = await startServer(initialDill);
      return true;
    });
    return server;
  }

  final server = await boot();
  if (compiler == null) return server;

  // exitCode is already completed whenever isRunning is false.
  final crashedLoadingKernel =
      server.vmServiceUri == null &&
      !server.isRunning &&
      await server.exitCode != 0;
  if (!crashedLoadingKernel) return server;

  log.warning(cachedBuildCrashedOnBoot);
  await compiler.invalidateCachedDill();
  // Ensure a complete kernel, not an incremental delta.
  await compiler.reset();
  final result = await compileWithProgress(
    'Compiling server',
    compiler,
    rejectOnFailure: true,
  );
  if (result == null) return null;
  await compiler.accept();
  return boot();
}

/// The paths the watch-mode [FileWatcher] observes: server/shared/client
/// source, the server's web dir, each Flutter app's lib and pubspec.yaml, and
/// the exact `package_config.json` / `package_graph.json` files of the
/// resolution `.dart_tool`(s).
///
/// [serverDartToolDir] is the server's resolution `.dart_tool` (workspace root
/// or the package itself); watching its `package_config.json` is what makes a
/// dependency change reload the server in place. [flutterPackageGraphPaths]
/// contains the resolved or expected graph path for every Flutter app.
///
/// The pub artifacts are watched as exact files rather than their `.dart_tool`
/// directories: those directories also hold large, churning build state (e.g.
/// `flutter_build` intermediates when a Flutter app builds, or the server's
/// dill), and a recursive directory watch has to scan and re-list that tree on
/// every build - heavy disk I/O for events that would all be discarded anyway.
@visibleForTesting
Set<String> buildWatchPaths({
  required GeneratorConfig config,
  List<FlutterAppConfig> flutterApps = const [],
  String? serverDartToolDir,
  Iterable<String> flutterPackageGraphPaths = const [],
}) {
  return {
    p.absolute(p.joinAll(config.libSourcePathParts)),
    ...config.sharedModelsLibSourcePaths.map(p.absolute),
    p.absolute(p.joinAll([...config.clientPackagePathParts, 'lib'])),
    p.absolute(p.joinAll([...config.serverPackageDirectoryPathParts, 'web'])),
    // The server's pubspec.yaml watched for changes to the flutter_apps config.
    p.absolute(
      p.joinAll([...config.serverPackageDirectoryPathParts, 'pubspec.yaml']),
    ),
    for (final app in flutterApps) ...[
      p.absolute(p.joinAll([...app.pathParts, 'lib'])),
      // The app's pubspec.yaml, watched as an exact file (it lives in the app
      // root, not under lib/) so an assets/fonts/dependency change triggers a
      // full Flutter relaunch.
      p.absolute(p.joinAll([...app.pathParts, 'pubspec.yaml'])),
    ],
    // The server resolution's package_config.json, reloaded into the FES in
    // place on dependency changes. The exact-file watcher persists across an
    // initial absence or deletion without scanning the rest of .dart_tool.
    if (serverDartToolDir != null)
      p.absolute(p.join(serverDartToolDir, 'package_config.json')),
    // Each Flutter resolution's package_graph.json, watched to detect Flutter
    // dependency changes (workspace root or, in a non-workspace project, the
    // Flutter package's own .dart_tool).
    ...flutterPackageGraphPaths.map(p.absolute),
  };
}

/// Mounts a fresh [VmServiceProxy] in front of [serverProcess] (writing
/// the proxy's URI to [userInfoFile]), or retargets [existing] in place
/// when called for a subsequent pod restart so the published proxy URI
/// stays stable across pod swaps.
///
/// When [reload] is non-null, IDE-initiated `reloadSources` requests are
/// intercepted and routed through it (so the FES + codegen pipeline runs
/// before the VM reloads). When `null` - i.e. `--no-watch` mode, where
/// there is no FES to drive - reloadSources passes through verbatim so
/// the IDE keeps full request/response fidelity (notices, `pause`, etc.)
/// against the VM's own kernel service.
///
/// Returns the (possibly retargeted) proxy on success, or [existing] when
/// the pod hasn't published a VM service URI - the watch session keeps
/// running without an attachable proxy in that case.
Future<VmServiceProxy?> _mountOrRetargetProxy({
  required ServerProcess serverProcess,
  required VmServiceProxy? existing,
  required String userInfoFile,
  required Future<void> Function()? reload,
}) async {
  final podHttp = serverProcess.vmServiceUri;
  if (podHttp == null) {
    log.warning(
      'Pod did not publish a VM service URI; IDE attach will not be '
      'available for this pod. (Reload, restart, and the rest of the '
      'watch loop continue to work.)',
    );
    return existing;
  }
  final podWs = Uri.parse(vmServiceWsUri(podHttp));

  if (existing != null) {
    await existing.setUpstream(podWs);
    return existing;
  }

  final proxy = VmServiceProxy(
    upstreamWs: podWs,
    interceptor: reload == null ? null : reloadSourcesInterceptor(reload),
  );
  await proxy.bind();
  await File(userInfoFile).writeAsString(
    jsonEncode({'uri': proxy.httpUri.toString()}),
  );
  log.info('VM service proxy listening on ${proxy.httpUri}');
  return proxy;
}

/// One-shot exit signal shared between the orchestrator, the
/// presentation layer, and `_setupWatchLoop`.
///
/// When [listenForSignals] is true (the default for non-TUI), SIGINT and
/// SIGTERM complete [future] with 0. The TUI passes `false` because
/// `runServerpodApp` already owns the signal subscriptions and forwards
/// them via its own callback. Either way, callers can [complete] the
/// signal directly (e.g. when the server crashes or the Quit button is
/// pressed) so the wait-for-exit point only ever has to await [future].
///
/// Call [dispose] to cancel the signal subscriptions, if any.
/// The single point every termination trigger funnels through.
///
/// In the runner, SIGINT and SIGTERM mean a graceful shutdown. In an attached
/// client, SIGINT only detaches - it cannot reach the runner, which is in a
/// process group of its own.
class ShutdownSignal {
  final Completer<int> _completer = Completer<int>();
  StreamSubscription<void>? _sigintSub;
  StreamSubscription<void>? _sigtermSub;

  ShutdownSignal({bool listenForSignals = true}) {
    if (!listenForSignals) return;
    _sigintSub = ProcessSignal.sigint.watch().listen(_completeFromSignal);
    if (!Platform.isWindows) {
      _sigtermSub = ProcessSignal.sigterm.watch().listen(_completeFromSignal);
    }
  }

  void _completeFromSignal(ProcessSignal _) => complete(0);

  /// Completes [future] with [code] if it isn't completed yet; no-op
  /// otherwise. Safe to call from multiple paths (signal handlers, the
  /// Quit button, server-exit forwarders).
  void complete([int code = 0]) {
    if (!_completer.isCompleted) _completer.complete(code);
  }

  /// Whether shutdown has been requested.
  bool get isShutdown => _completer.isCompleted;

  /// Completes with the requested exit code.
  Future<int> get future => _completer.future;

  /// Cancels the signal subscriptions.
  void dispose() {
    _sigintSub?.cancel();
    _sigtermSub?.cancel();
  }
}

/// Checks if a server is already running by reading the VM service info file
/// and attempting to connect. Returns the URI if reachable, `null` otherwise.
/// Cleans up stale files.
Future<String?> _checkExistingServer(String infoPath) async {
  final file = File(infoPath);
  if (!file.existsSync()) return null;

  try {
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final uri = json['uri'] as String?;
    if (uri == null) {
      await file.deleteIfExists();
      return null;
    }

    final vmService = await vmServiceConnectUri(vmServiceWsUri(uri)).timeout(
      const Duration(seconds: 3),
    );
    await vmService.dispose();
    return uri;
  } on Exception {
    // Stale or unreachable - clean up and proceed with normal startup.
    await file.deleteIfExists();
    return null;
  }
}

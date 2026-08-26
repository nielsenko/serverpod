import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:cli_tools/cli_tools.dart';
import 'package:config/config.dart';
import 'package:path/path.dart' as p;
import 'package:serverpod_cli/analyzer.dart';
import 'package:serverpod_cli/src/commands/attach.dart';
import 'package:serverpod_cli/src/commands/messages.dart';
import 'package:serverpod_cli/src/commands/serverpod_command.dart';
import 'package:serverpod_cli/src/commands/serverpod_command_runner.dart';
import 'package:serverpod_cli/src/commands/start.dart';
import 'package:serverpod_cli/src/commands/start/log_history.dart';
import 'package:serverpod_cli/src/commands/start/watch_loop.dart';
import 'package:serverpod_cli/src/commands/status.dart';
import 'package:serverpod_cli/src/commands/stop.dart';
import 'package:serverpod_cli/src/runner/runner_log_file.dart';
import 'package:serverpod_cli/src/runner/runner_manifest.dart';
import 'package:serverpod_cli/src/util/serverpod_cli_logger.dart';
import 'package:serverpod_logging_cli/serverpod_logging_cli.dart';
import 'package:serverpod_shared/log.dart' show MultiLogWriter;

/// The commands that act on the development stack: the runner itself, and the
/// clients that drive one.
///
/// A group rather than a command: `runner` names the thing being acted on, and
/// every verb under it - starting one, attaching to it, asking after it,
/// stopping it - reads as what it does to that runner.
class RunnerCommand extends ServerpodCommand<OptionDefinition> {
  RunnerCommand() : super(options: const []) {
    addSubcommand(RunnerStartCommand());
    addSubcommand(AttachCommand());
    addSubcommand(StatusCommand());
    addSubcommand(StopCommand());
    addSubcommand(RunnerServeCommand());
  }

  @override
  final name = 'runner';

  @override
  final description = 'Manage the development stack for this project.';

  @override
  void runWithConfig(Configuration<OptionDefinition> commandConfig) {}
}

/// Options for `serverpod runner start`.
///
/// The stack-shaping half of `start` and nothing else: this command brings a
/// runner up and returns, so the options that describe a UI - whether to
/// attach, whether to render one - have nothing to act on.
enum RunnerStartOption<V> implements OptionDefinition<V> {
  watch(
    FlagOption(
      argName: 'watch',
      argAbbrev: 'w',
      defaultsTo: true,
      negatable: true,
      helpText: 'Watch files and use the Frontend Server.',
    ),
  ),
  directory(
    StringOption(
      argName: 'directory',
      argAbbrev: 'd',
      defaultsTo: '',
      helpText: 'The server directory.',
    ),
  ),
  docker(
    FlagOption(
      argName: 'docker',
      helpText: 'Start Docker Compose services if a compose file exists.',
    ),
  ),
  flutter(
    FlagOption(
      argName: 'flutter',
      defaultsTo: true,
      helpText: 'Auto-launch companion Flutter apps on the first UI attach.',
    ),
  ),
  ;

  const RunnerStartOption(this.option);

  @override
  final ConfigOptionBase<V> option;
}

/// Brings a runner up for this project and returns, leaving it running.
///
/// The same work `serverpod start` does before it attaches, and idempotent in
/// the same way: a runner already serving this project is reported rather than
/// replaced. What it does not do is attach - that is `serverpod runner attach`,
/// or `serverpod start`, which does both.
class RunnerStartCommand extends ServerpodCommand<RunnerStartOption> {
  @override
  final name = 'start';

  @override
  final description =
      'Start the development stack for this project and return, leaving it '
      'running in the background.';

  @override
  String get invocation => 'serverpod runner start [-- <server-args>]';

  RunnerStartCommand() : super(options: RunnerStartOption.values);

  @override
  Configuration<RunnerStartOption> resolveConfiguration(
    ArgResults? argResults,
  ) {
    return Configuration.resolveNoExcept(
      options: options,
      argResults: argResults,
      env: envVariables,
      ignoreUnexpectedPositionalArgs: true,
    );
  }

  @override
  Future<void> runWithConfig(
    Configuration<RunnerStartOption> commandConfig,
  ) async {
    final config = await loadRunnerProjectConfig(
      directory: commandConfig.value(RunnerStartOption.directory),
      interactive: serverpodRunner.globalConfiguration.optionalValue(
        GlobalOption.interactive,
      ),
    );
    final serverDir = p.joinAll(config.serverPackageDirectoryPathParts);

    final manifest = await ensureRunner(
      config: config,
      serverDir: serverDir,
      asked: RunnerConfig(
        watch: commandConfig.value(RunnerStartOption.watch),
        flutter: commandConfig.value(RunnerStartOption.flutter),
        docker: commandConfig.optionalValue(RunnerStartOption.docker),
        serverArgs: argResults?.rest ?? const [],
      ),
      // Nothing renders here, whatever a later client chooses to do.
      useTui: false,
      awaitManifest: true,
    );

    log.info('Runner ready (pid ${manifest!.pid}).');
    log.info(
      'Attach with `serverpod runner attach`, '
      'stop with `serverpod runner stop`.',
    );
  }
}

/// Options for the hidden `runner serve` command.
///
/// Mirrors the stack-shaping half of `start`; the options that describe a
/// client have no meaning here.
enum RunnerServeOption<V> implements OptionDefinition<V> {
  watch(
    FlagOption(
      argName: 'watch',
      argAbbrev: 'w',
      defaultsTo: true,
      negatable: true,
      helpText: 'Watch files and use the Frontend Server.',
    ),
  ),
  directory(
    StringOption(
      argName: 'directory',
      argAbbrev: 'd',
      defaultsTo: '',
      helpText: 'The server directory.',
    ),
  ),
  docker(
    FlagOption(
      argName: 'docker',
      helpText: 'Start Docker Compose services if a compose file exists.',
    ),
  ),
  flutter(
    FlagOption(
      argName: 'flutter',
      defaultsTo: true,
      helpText: 'Auto-launch companion Flutter apps on the first UI attach.',
    ),
  ),
  detached(
    FlagOption(
      argName: 'detached',
      defaultsTo: false,
      helpText:
          'Write this process\'s output to .dart_tool/serverpod/runner.log '
          'instead of stdout. Passed by `serverpod start`, which spawns the '
          'runner with no stdio to inherit.',
    ),
  ),
  ;

  const RunnerServeOption(this.option);

  @override
  final ConfigOptionBase<V> option;
}

/// The long-lived development stack, with no UI attached.
///
/// This is what `serverpod runner start` spawns, detached and in a session of
/// its own.
/// It is not meant to be typed: it is hidden, and running it in a terminal is
/// only useful when debugging the runner itself, since it takes the terminal
/// without rendering anything to it.
///
/// Everything a client needs to find it goes into
/// `.dart_tool/serverpod/runner.json`; everything it says goes into
/// `.dart_tool/serverpod/runner.log`, because a detached process has no stdio
/// to inherit.
class RunnerServeCommand extends ServerpodCommand<RunnerServeOption> {
  @override
  final name = 'serve';

  @override
  final description =
      'Be the development stack. Spawned by `serverpod runner start`.';

  @override
  bool get hidden => true;

  @override
  String get invocation => 'serverpod runner serve [-- <server-args>]';

  RunnerServeCommand() : super(options: RunnerServeOption.values);

  @override
  Configuration<RunnerServeOption> resolveConfiguration(
    ArgResults? argResults,
  ) {
    return Configuration.resolveNoExcept(
      options: options,
      argResults: argResults,
      env: envVariables,
      ignoreUnexpectedPositionalArgs: true,
    );
  }

  @override
  Future<void> runWithConfig(
    Configuration<RunnerServeOption> commandConfig,
  ) async {
    final directory = commandConfig.value(RunnerServeOption.directory);
    final detached = commandConfig.value(RunnerServeOption.detached);

    // Taken from the argument rather than the loaded config, and opened before
    // the load: a detached process has no stdio, so a project that fails to
    // load reports into a closed file descriptor and leaves the log the
    // spawning CLI names empty. `serverpod start`, the only caller that
    // detaches, always passes the directory it spawned the runner for.
    final logFile = RunnerLogFile.forServer(directory);
    final logHistory = StartLogHistory();
    if (detached) {
      await logFile.open();
      await closeLogger();
      initializeLoggerWith(
        ServerpodCliLogger(
          MultiLogWriter([
            StartLogHistoryWriter(logHistory),
            RunnerLogFileWriter(logFile),
          ]),
        ),
      );
    }

    final config = await GeneratorConfig.load(
      serverRootDir: directory,
      interactive: false,
    );
    final serverDir = p.joinAll(config.serverPackageDirectoryPathParts);

    final shutdown = ShutdownSignal();
    try {
      final result = await setupWatchLoop(
        config: config,
        serverDir: serverDir,
        serverArgs: ServerArgsRef(argResults?.rest ?? []),
        watch: commandConfig.value(RunnerServeOption.watch),
        docker: commandConfig.optionalValue(RunnerServeOption.docker),
        launchFlutterApp: commandConfig.value(RunnerServeOption.flutter),
        shutdown: shutdown,
        logHistory: logHistory,
        serverStdoutSink: logHistory.serverOutputSink(
          forwardTo: detached ? RunnerLogFileSink(logFile) : stdout,
        ),
        serverStderrSink: logHistory.serverOutputSink(
          forwardTo: detached
              ? RunnerLogFileSink(logFile, prefix: 'stderr: ')
              : stderr,
        ),
        flutterStdoutEcho: detached
            ? RunnerLogFileSink(logFile, prefix: 'flutter: ')
            : stdout,
        flutterStderrEcho: detached
            ? RunnerLogFileSink(logFile, prefix: 'flutter: ')
            : stderr,
      );

      switch (result) {
        case WatchLoopAborted(:final exitCode):
          if (exitCode != 0) throw ExitException(exitCode);
          return;
        case WatchLoopReady(:final ctx):
          if (ctx.session.isRunning) log.info(serverRunning);
          final exitCode = await shutdown.future;
          log.info('Server stopped (exitCode: $exitCode).');
          await ctx.dispose(exitCode: exitCode);
          if (exitCode != 0) throw ExitException(exitCode);
      }
    } finally {
      shutdown.dispose();
      if (detached) await logFile.close();
    }
  }
}

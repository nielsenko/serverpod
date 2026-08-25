import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:cli_tools/cli_tools.dart';
import 'package:config/config.dart';
import 'package:path/path.dart' as p;
import 'package:serverpod_cli/analyzer.dart';
import 'package:serverpod_cli/src/commands/messages.dart';
import 'package:serverpod_cli/src/commands/serverpod_command.dart';
import 'package:serverpod_cli/src/commands/start.dart';
import 'package:serverpod_cli/src/commands/start/log_history.dart';
import 'package:serverpod_cli/src/commands/start/watch_loop.dart';
import 'package:serverpod_cli/src/runner/runner_log_file.dart';
import 'package:serverpod_cli/src/util/serverpod_cli_logger.dart';
import 'package:serverpod_logging_cli/serverpod_logging_cli.dart';

/// Options for the hidden `runner` command. Mirrors the stack-shaping half of
/// `start`; the options that describe a client have no meaning here.
enum RunnerOption<V> implements OptionDefinition<V> {
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

  const RunnerOption(this.option);

  @override
  final ConfigOptionBase<V> option;
}

/// The long-lived development stack, with no UI attached.
///
/// This is what `serverpod start` spawns, detached and in a session of its own.
/// It is not meant to be typed: it is hidden, and running it in a terminal is
/// only useful when debugging the runner itself, since it takes the terminal
/// without rendering anything to it.
///
/// Everything a client needs to find it goes into
/// `.dart_tool/serverpod/runner.json`; everything it says goes into
/// `.dart_tool/serverpod/runner.log`, because a detached process has no stdio
/// to inherit.
class RunnerCommand extends ServerpodCommand<RunnerOption> {
  @override
  final name = 'runner';

  @override
  final description =
      'Run the development stack headlessly. Spawned by `serverpod start`.';

  @override
  bool get hidden => true;

  @override
  String get invocation => 'serverpod runner [-- <server-args>]';

  RunnerCommand() : super(options: RunnerOption.values);

  @override
  Configuration<RunnerOption> resolveConfiguration(ArgResults? argResults) {
    return Configuration.resolveNoExcept(
      options: options,
      argResults: argResults,
      env: envVariables,
      ignoreUnexpectedPositionalArgs: true,
    );
  }

  @override
  Future<void> runWithConfig(Configuration<RunnerOption> commandConfig) async {
    final config = await GeneratorConfig.load(
      serverRootDir: commandConfig.value(RunnerOption.directory),
      interactive: false,
    );
    final serverDir = p.joinAll(config.serverPackageDirectoryPathParts);

    // Spawned detached there is no stdio to inherit, so this process's output
    // would be lost; redirect it to the log file before anything can log. Run
    // in a terminal - debugging the runner, or a test driving it in process -
    // the ambient logger is left alone and output appears where it is
    // expected.
    final detached = commandConfig.value(RunnerOption.detached);
    final logFile = RunnerLogFile.forServer(serverDir);
    if (detached) {
      await logFile.open();
      await closeLogger();
      initializeLoggerWith(ServerpodCliLogger(RunnerLogFileWriter(logFile)));
    }

    final shutdown = ShutdownSignal();
    try {
      final result = await setupWatchLoop(
        config: config,
        serverDir: serverDir,
        serverArgs: ServerArgsRef(argResults?.rest ?? []),
        watch: commandConfig.value(RunnerOption.watch),
        docker: commandConfig.optionalValue(RunnerOption.docker),
        // Nothing here can prompt a rebuild, so in watch mode the file watcher
        // recovers a broken project and without it there is nothing to wait
        // for.
        keepOpenOnFailure: commandConfig.value(RunnerOption.watch),
        launchFlutterApp: commandConfig.value(RunnerOption.flutter),
        shutdown: shutdown,
        logHistory: StartLogHistory(),
        serverStdoutSink: detached ? RunnerLogFileSink(logFile) : null,
        serverStderrSink: detached
            ? RunnerLogFileSink(logFile, prefix: 'stderr: ')
            : null,
        flutterStdoutEcho: detached
            ? RunnerLogFileSink(logFile, prefix: 'flutter: ')
            : stdout,
        flutterStderrEcho: detached
            ? RunnerLogFileSink(logFile, prefix: 'flutter: ')
            : stderr,
      );

      switch (result) {
        case WatchLoopAborted(:final exitCode):
          if (detached) await logFile.close();
          if (exitCode != 0) throw ExitException(exitCode);
          return;
        case WatchLoopReady(:final ctx):
          if (ctx.session.isRunning) log.info(serverRunning);
          final exitCode = await shutdown.future;
          log.info('Server stopped (exitCode: $exitCode).');
          await ctx.dispose();
          if (detached) await logFile.close();
          if (exitCode != 0) throw ExitException(exitCode);
      }
    } finally {
      shutdown.dispose();
    }
  }
}

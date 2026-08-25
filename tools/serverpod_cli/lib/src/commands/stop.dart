import 'dart:async';
import 'dart:io';

import 'package:cli_tools/cli_tools.dart';
import 'package:config/config.dart';
import 'package:serverpod_cli/src/commands/runner_options.dart';
import 'package:serverpod_cli/src/commands/serverpod_command.dart';
import 'package:serverpod_cli/src/commands/status.dart'
    show resolveServerDirectory;
import 'package:serverpod_cli/src/runner/runner_client.dart';
import 'package:serverpod_cli/src/runner/runner_discovery.dart';
import 'package:serverpod_cli/src/util/serverpod_cli_logger.dart';

/// Options for the `stop` command.
enum StopOption<V> implements OptionDefinition<V> {
  directory<String>(clientDirectoryOption),
  ;

  const StopOption(this.option);

  @override
  final ConfigOptionBase<V> option;
}

/// Shuts the runner down.
///
/// This, or `⇧+Q` in the UI, is the only thing that stops the stack.
/// Detaching a client never does, whoever started the runner: otherwise the
/// same keystroke would stop the server or not depending on how the session
/// began.
class StopCommand extends ServerpodCommand<StopOption> {
  @override
  final name = 'stop';

  @override
  final description = 'Stop the development stack running for this project.';

  @override
  String get invocation => 'serverpod runner stop';

  StopCommand() : super(options: StopOption.values);

  @override
  Future<void> runWithConfig(Configuration<StopOption> commandConfig) async {
    final serverDir = await resolveServerDirectory(
      commandConfig.optionalValue(StopOption.directory),
    );

    final resolution = await resolveRunner(serverDir.path);
    switch (resolution) {
      case NoRunner():
        log.info('No serverpod runner is running for this project.');
        return;

      case IncompatibleRunner(:final manifest):
        await _stopByPid(manifest.pid, serverDir.path);
        return;

      case LiveRunner(:final manifest):
        if (manifest.sockets.tui.isEmpty) {
          await _stopByPid(manifest.pid, serverDir.path);
          return;
        }
        await _stopOverSocket(manifest.sockets.tui, serverDir.path);
    }
  }

  Future<void> _stopOverSocket(String socketPath, String serverDir) async {
    final client = RunnerClient(socketPath: socketPath);
    try {
      await client.connect();
    } on RunnerUnreachableException {
      log.info('No serverpod runner is running for this project.');
      return;
    }

    try {
      await client.stop();
    } catch (_) {}
    await client.close();

    final stopped = await _waitForShutdown(serverDir);
    if (stopped) {
      log.info('Server stopped.');
    } else {
      log.warning(
        'The runner accepted the stop but is still shutting down. '
        'Check `serverpod runner status`.',
      );
    }
  }

  /// Signals the runner directly, for a runner this CLI cannot ask to stop.
  ///
  /// The pid comes from the manifest, which documents it as diagnostics: it
  /// names the process as the runner saw itself, and a runner in a container
  /// names one in a namespace this machine does not share. So the signal is
  /// sent - discovery has just proved something is listening - and then
  /// confirmed, rather than reported as a stop that may not have happened.
  Future<void> _stopByPid(int pid, String serverDir) async {
    if (pid <= 0) {
      log.error(
        'The runner cannot be reached and its manifest names no process. '
        'Stop it by hand and remove .dart_tool/serverpod/runner.json.',
      );
      throw ExitException.error();
    }
    log.info('Stopping the runner (pid $pid).');
    if (!Process.killPid(pid, ProcessSignal.sigterm)) {
      log.error(
        'Could not signal pid $pid. It may already be gone; '
        'check `serverpod runner status`.',
      );
      throw ExitException.error();
    }

    if (await _waitForShutdown(serverDir)) {
      log.info('Server stopped.');
      return;
    }
    log.error(
      'The runner is still running after the signal. Its manifest may name a '
      'process this machine cannot signal, such as a runner inside a '
      'container. Stop it where it runs and remove '
      '.dart_tool/serverpod/runner.json.',
    );
    throw ExitException.error();
  }

  /// Polls until the runner's manifest is gone, or [timeout] passes.
  Future<bool> _waitForShutdown(
    String serverDir, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await resolveRunner(serverDir) is NoRunner) return true;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return false;
  }
}

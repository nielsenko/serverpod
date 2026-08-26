import 'dart:async';
import 'dart:io';

import 'package:cli_tools/cli_tools.dart';
import 'package:config/config.dart';
import 'package:serverpod_cli/src/commands/attach/log_renderer.dart'
    show attachWithLogStream;
import 'package:serverpod_cli/src/commands/attach/state_binding.dart';
import 'package:serverpod_cli/src/commands/serverpod_command.dart';
import 'package:serverpod_cli/src/commands/start/tui/app.dart';
import 'package:serverpod_cli/src/commands/start/tui/state.dart';
import 'package:serverpod_cli/src/commands/status.dart'
    show resolveServerDirectory;
import 'package:serverpod_cli/src/runner/runner_client.dart';
import 'package:serverpod_cli/src/runner/runner_discovery.dart';
import 'package:serverpod_cli/src/runner/runner_manifest.dart';
import 'package:serverpod_cli/src/util/serverpod_cli_logger.dart';
import 'package:serverpod_tui/serverpod_tui.dart';

export 'package:serverpod_cli/src/commands/attach/log_renderer.dart'
    show attachWithLogStream;

/// Options for the `attach` command.
enum AttachOption<V> implements OptionDefinition<V> {
  directory(
    StringOption(
      argName: 'directory',
      argAbbrev: 'd',
      helpText:
          'The server directory (defaults to auto-detect from current '
          'directory).',
    ),
  ),
  tui(
    FlagOption(
      argName: 'tui',
      defaultsTo: true,
      helpText: 'Show the interactive terminal UI.',
    ),
  ),
  ;

  const AttachOption(this.option);

  @override
  final ConfigOptionBase<V> option;
}

/// Attaches a UI to a runner that is already up.
///
/// Holds no orchestration: it resolves the server directory, connects to a
/// socket, renders what arrives, and reconnects when the runner restarts.
///
/// Detaching does not stop the runner, whoever started it. The stack is
/// stopped with `serverpod stop`, or with `⇧+Q` in the UI, so the same
/// keystroke never means "stop the server" in one session and "leave it
/// running" in another.
class AttachCommand extends ServerpodCommand<AttachOption> {
  @override
  final name = 'attach';

  @override
  final description =
      'Attach to the development stack already running for this project.';

  @override
  String get invocation => 'serverpod attach';

  AttachCommand() : super(options: AttachOption.values);

  @override
  Future<void> runWithConfig(Configuration<AttachOption> commandConfig) async {
    final serverDir = await resolveServerDirectory(
      commandConfig.optionalValue(AttachOption.directory),
    );

    final resolution = await resolveRunner(serverDir.path);
    final String socketPath;
    switch (resolution) {
      case NoRunner():
        log.error(
          'No serverpod runner is running for this project. '
          'Start one with `serverpod start`.',
        );
        throw ExitException.error();
      case IncompatibleRunner(:final message):
        log.error(message);
        throw ExitException.error();
      case LiveRunner(:final manifest, :final versionWarning):
        if (versionWarning != null) log.warning(versionWarning);
        socketPath = requireAttachSocket(manifest);
    }

    final useTui = commandConfig.value(AttachOption.tui) && stdout.hasTerminal;
    final exitCode = useTui
        ? await attachWithTui(socketPath)
        : await attachWithLogStream(socketPath);
    if (exitCode != 0) throw ExitException(exitCode);
  }
}

/// The runner's attach socket, or an [ExitException] saying how to get one.
///
/// A runner whose attach socket failed to bind is still live - it answers on
/// the MCP socket - and still publishes a manifest, so this is reachable
/// wherever a manifest leads to an attach: `serverpod attach`, and `serverpod
/// start` finding or starting a runner. Without it the empty path reaches
/// [RunnerClient] and surfaces as an internal error rather than something to
/// act on.
String requireAttachSocket(RunnerManifest manifest) {
  if (manifest.sockets.tui.isEmpty) {
    log.error(
      'The running runner does not serve an attach socket. '
      'Stop it with `serverpod stop` and start it again.',
    );
    throw ExitException.error();
  }
  return manifest.sockets.tui;
}

/// Renders the runner in the terminal UI, returning the exit code to leave
/// with.
///
/// Shared with `serverpod start`, which attaches after bringing the runner up.
///
/// None of the in-process integration this used to need survives the split:
/// with the backend in another process there is no [Completer] handing state
/// back, no logger buffering messages emitted before the UI existed, and no
/// ordering dance to print a crash after the alternate screen is gone.
Future<int> attachWithTui(String socketPath, {Duration? waitForRunner}) async {
  final holder = StartAppStateHolder(ServerWatchState());
  final client = RunnerClient(
    socketPath: socketPath,
    history: holder.state.history,
  );
  await client.attach(waitFor: waitForRunner);

  final exitCompleter = Completer<int>();
  void requestExit([int code = 0]) {
    if (!exitCompleter.isCompleted) exitCompleter.complete(code);
  }

  final binding = RunnerStateBinding(
    client: client,
    holder: holder,
    onStopRequested: requestExit,
  )..bind();

  // SIGINT here detaches. It cannot reach the pod: the runner is in a session
  // of its own, so the terminal's signal never gets there.
  unawaited(
    exitCompleter.future.then((code) async {
      await binding.dispose();
      await client.close();
      shutdownTuiApp(code);
    }),
  );

  await runTuiApp(
    ServerpodWatchApp(holder: holder),
    backend: ServerpodTerminalBackend(preExit: (_) async {}),
    onShutdownSignal: requestExit,
  );

  return exitCompleter.future;
}

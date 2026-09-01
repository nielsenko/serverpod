import 'dart:async';

import 'package:serverpod_cli/src/commands/start/tui/app.dart';
import 'package:serverpod_cli/src/commands/start/tui/event_handler.dart';
import 'package:serverpod_cli/src/commands/start/tui/state.dart';
import 'package:serverpod_cli/src/commands/start/tui/tab_model.dart';
import 'package:serverpod_cli/src/config/flutter_app_config.dart';
import 'package:serverpod_cli/src/runner/migration_result.dart';
import 'package:serverpod_cli/src/runner/runner_client.dart';
import 'package:serverpod_cli/src/runner/runner_event.dart';
import 'package:serverpod_cli/src/runner/runner_snapshot.dart';
import 'package:serverpod_cli/src/util/serverpod_cli_logger.dart';

/// Drives a [ServerWatchState] from an attached [RunnerClient].
///
/// The terminal UI renders the same state object whether the backend runs in
/// this process or in a runner across a socket; the difference is only where
/// the state comes from. In-process it was mutated by the watch loop's
/// callbacks; here it is mutated by the runner's events.
///
/// Everything client-side stays client-side: scroll position, the selected
/// tab, and which operations are expanded are never sent anywhere, so two
/// attached clients scroll independently.
class RunnerStateBinding {
  RunnerStateBinding({
    required this.client,
    required this.holder,
    required this.onStopRequested,
    this.onRunnerStopped,
  });

  final RunnerClient client;
  final StartAppStateHolder holder;

  /// Invoked by the UI's quit binding.
  ///
  /// Detaching is not stopping: whether this stops the runner or just this
  /// client is the caller's decision.
  final void Function() onStopRequested;

  /// Invoked when the runner announces that it is stopping, with the exit
  /// code it named.
  ///
  /// An announced stop is the runner ending the session: it sends the code so
  /// that a client can leave with it. A connection that drops without one is
  /// a crash or a kill, which the client rides out by reconnecting.
  final void Function(int exitCode)? onRunnerStopped;

  final List<StreamSubscription<void>> _subs = [];

  ServerWatchState get _state => holder.state;

  /// Points the state at the client's buffers, wires the UI's actions to the
  /// runner, and starts following events.
  void bind() {
    client.history.attachHolder(holder);

    _bindActions();
    _applyRunnerState();

    _subs.add(client.events.listen(_onEvent));
    _subs.add(client.snapshotChanges.listen((_) => _applyRunnerState()));
    _subs.add(
      client.connectionChanges.listen((connected) {
        if (connected) _applyRunnerState();
        holder.markDirty();
      }),
    );
  }

  Future<void> dispose() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
  }

  void _bindActions() {
    _state.isAppRunning = client.isFlutterAppRunning;
    _state.isAppLaunching = client.isFlutterAppLaunching;

    holder.onQuit = onStopRequested;
    holder.onStopStack = () =>
        unawaited(client.stop().whenComplete(() => onStopRequested()));
    holder.onHotReload = () =>
        runTrackedAction(holder, 'Hot reload', client.hotReload);
    holder.onHotRestart = () {
      final running = client.isRunning;
      runTrackedAction(
        holder,
        running ? 'Hot restart' : 'Rebuild & start',
        running ? client.hotRestart : client.retryStart,
        allowWhenStartable: !running,
      );
    };
    holder.onRestartFlutterApp = () => runTrackedAction(
      holder,
      client.isAnyFlutterAppRunning
          ? 'Restart Flutter app'
          : 'Start Flutter app',
      client.restartFlutterApps,
    );
    holder.onApplyMigration = () =>
        runTrackedAction(holder, 'Applying migrations', client.applyMigrations);
    holder.onCreateMigration = ({bool force = false}) => runTrackedAction(
      holder,
      force ? 'Force-creating migration' : 'Creating migration',
      () => _createMigration(
        () => client.createMigration(force: force),
        forceHint: 'Use ⇧+M to force-create it anyway.',
      ),
    );
    holder.onCreateRepairMigration = ({bool force = false}) => runTrackedAction(
      holder,
      force ? 'Force-creating repair migration' : 'Creating repair migration',
      () => _createMigration(
        () => client.createRepairMigration(force: force),
        forceHint: 'Use ⇧+P to force-create it anyway.',
      ),
    );

    holder.onLaunchApp = (index) {
      final app = _appAt(index);
      if (app == null) return;
      final running = client.isFlutterAppRunning(app.id);
      runTrackedAction(
        holder,
        running ? 'Relaunch ${app.name}' : 'Launch ${app.name}',
        () => client.restartFlutterApp(app.id),
      );
    };
    holder.onStopApp = (index) {
      final app = _appAt(index);
      if (app == null || !client.isFlutterAppRunning(app.id)) return;
      runTrackedAction(
        holder,
        'Stop ${app.name}',
        () => client.stopFlutterApp(app.id),
      );
    };
  }

  /// Runs a migration command and reports it the way the in-process UI does:
  /// log the outcome, throw on failure so the tracked operation turns red.
  Future<void> _createMigration(
    Future<MigrationResult> Function() create, {
    required String forceHint,
  }) async {
    final result = await create();
    if (result.isError) {
      final hint = result.abortedForWarnings ? ' $forceHint' : '';
      throw Exception('${result.message}$hint');
    }
    log.info(result.message);
    try {
      await client.applyMigrations();
    } catch (e) {
      log.error('The migration was created but not applied: $e');
      log.info('Press A to apply it once the database is reachable.');
    }
  }

  FlutterAppConfig? _appAt(int index) {
    final apps = client.flutterApps;
    if (index < 0 || index >= apps.length) return null;
    return apps[index];
  }

  /// Redraws from what the client currently believes, on first bind and after
  /// every reconnect.
  ///
  /// Read off the client rather than from `client.snapshot()`: the five values
  /// below are all this needs, and a snapshot copies the whole retained
  /// history - up to ten thousand entries per buffer - to carry them.
  void _applyRunnerState() {
    final isRunning = client.isRunning;
    final stage = client.stage;
    _state.watchModeEnabled = client.watchModeEnabled;
    _state.serverReady = isRunning;
    _state.serverStartable = !isRunning && stage == RunnerStage.degraded;
    _state.showSplash = stage == RunnerStage.starting;
    _state.rawLines
      ..clear()
      ..addAll(client.history.serverLines);
    _syncApps(client.flutterApps);
    for (final app in client.flutterApps) {
      final running = client.isFlutterAppRunning(app.id);
      final launching = client.isFlutterAppLaunching(app.id);
      if (!running && !launching && _state.appLogTabFor(app.id) == null) {
        continue;
      }
      _markAppTab(
        app.id,
        running: running,
        launching: launching,
        url: client.flutterAppUrls[app.id],
      );
    }
    holder.markDirty();
  }

  void _onEvent(RunnerEvent event) {
    switch (event) {
      case StageChangedEvent(:final stage, :final isRunning, :final exitCode):
        _state.serverReady = isRunning;
        _state.serverStartable = !isRunning && stage == RunnerStage.degraded;
        if (stage != RunnerStage.starting) _state.showSplash = false;
        if (stage == RunnerStage.stopping) onRunnerStopped?.call(exitCode ?? 0);

      case FlutterAppsChangedEvent(:final apps):
        _syncApps(apps);

      case FlutterAppStateEvent(
        :final appId,
        :final running,
        :final launching,
        :final url,
        :final launchStage,
      ):
        _markAppTab(
          appId,
          running: running,
          launching: launching,
          url: url,
          launchStage: launchStage,
        );

      case ServerLogEvent() ||
          ServerLineEvent() ||
          OperationStartedEvent() ||
          OperationCompletedEvent() ||
          FlutterLineEvent() ||
          FlutterLogEntryEvent() ||
          OperationsDiscardedEvent() ||
          ManifestChangedEvent():
        // Already applied to the buffers the state renders.
        break;
    }
    holder.markDirty();
  }

  void _syncApps(List<FlutterAppConfig> apps) {
    final ids = {for (final app in apps) app.id};
    for (final existing in _state.launchableApps) {
      if (ids.contains(existing.id)) continue;
      _state.removeAppLogTab(existing.id);
    }
    _state
      ..launchableApps = apps
      ..canLaunchApps = apps.isNotEmpty && client.canLaunchFlutterApps;
    if (apps.isNotEmpty) _state.createAppsTabAreaIfNeeded();
  }

  /// Opens or updates the log tab for [appId].
  ///
  /// The tab renders the client's line buffer, so one opened after the app
  /// started shows everything it has produced.
  void _markAppTab(
    String appId, {
    required bool running,
    required bool launching,
    String? url,
    String? launchStage,
  }) {
    final app = client.flutterApps.where((a) => a.id == appId).firstOrNull;
    final tab = _state.getOrCreateAppLogTab(
      appId: appId,
      label: app?.name ?? appId,
    );
    tab
      ..runState = running
          ? AppRunState.ready
          : launching
          ? AppRunState.launching
          : AppRunState.stopped
      ..startupStage = launching ? (launchStage ?? tab.startupStage) : null
      ..url = url
      ..device = app?.device;
  }
}

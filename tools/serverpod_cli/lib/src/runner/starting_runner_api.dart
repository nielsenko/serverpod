import 'dart:async';

import 'package:serverpod_cli/src/commands/start/log_history.dart';
import 'package:serverpod_cli/src/config/flutter_app_config.dart';
import 'package:serverpod_cli/src/runner/migration_result.dart';
import 'package:serverpod_cli/src/runner/runner_api.dart';
import 'package:serverpod_cli/src/runner/runner_event.dart';
import 'package:serverpod_cli/src/runner/runner_snapshot.dart';

/// Thrown by every command a runner cannot serve until its stack is up.
class RunnerStartingException implements Exception {
  const RunnerStartingException(this.command);

  final String command;

  @override
  String toString() =>
      'The runner is still starting; $command is not available yet.';
}

/// [RunnerApi] for the window between acquiring the runner lock and having a
/// stack to drive.
///
/// The attach socket is bound at the start of that window rather than the end,
/// so a UI is watching for the minutes generation, Docker and the first
/// compile can take - which is exactly when a developer wants to see output,
/// and exactly when a failure ends the runner before the real API ever exists.
///
/// It serves the one thing that is real that early: the log history the runner
/// is already filling. Every command reports that the stack is not up yet,
/// except [stop], which has to work - a start that is going nowhere is the
/// most likely thing to want to abandon.
class StartingRunnerApi implements RunnerApi {
  StartingRunnerApi({
    required StartLogHistory logHistory,
    required void Function() requestShutdown,
  }) : _logHistory = logHistory,
       _requestShutdown = requestShutdown;

  final StartLogHistory _logHistory;
  final void Function() _requestShutdown;

  @override
  RunnerSnapshot snapshot() => RunnerSnapshot.from(
    history: _logHistory,
    stage: RunnerStage.starting,
    isRunning: false,
    watchModeEnabled: false,
    canLaunchFlutterApps: false,
    flutterApps: const [],
    runningFlutterApps: const {},
  );

  @override
  Stream<RunnerEvent> get events => _logHistory.events;

  @override
  Future<void> close() async {}

  @override
  RunnerStage get stage => RunnerStage.starting;

  @override
  bool get isRunning => false;

  @override
  Future<void> stop() async => _requestShutdown();

  @override
  Future<void> hotReload() => _notYet('hot reload');

  @override
  Future<void> hotRestart() => _notYet('hot restart');

  @override
  Future<void> retryStart() => _notYet('retrying the start');

  @override
  Future<MigrationResult> createMigration({String? tag, bool force = false}) =>
      _notYet('creating a migration');

  @override
  Future<MigrationResult> createRepairMigration({
    String? tag,
    bool force = false,
    String? targetVersion,
  }) => _notYet('creating a repair migration');

  @override
  Future<void> applyMigrations() => _notYet('applying migrations');

  @override
  List<FlutterAppConfig> get flutterApps => const [];

  @override
  bool get canLaunchFlutterApps => false;

  @override
  bool isFlutterAppRunning(String appId) => false;

  @override
  bool isFlutterAppLaunching(String appId) => false;

  @override
  bool get isAnyFlutterAppRunning => false;

  @override
  Future<bool> launchFlutterApp(String appId) => _notYet('launching an app');

  @override
  Future<void> restartFlutterApp(String appId) => _notYet('restarting an app');

  @override
  Future<void> stopFlutterApp(String appId) => _notYet('stopping an app');

  @override
  Future<void> restartFlutterApps() => _notYet('restarting the apps');

  @override
  Map<String, String?> get flutterDtdUris => const {};

  @override
  List<Object> get logHistory => _logHistory.serverEntries.toList();

  @override
  List<String> flutterLogHistory(String appId) => const [];

  @override
  String? get vmServiceUri => null;

  @override
  Stream<void> get vmServiceUriChanges => const Stream.empty();

  Future<Never> _notYet(String command) =>
      Future.error(RunnerStartingException(command));
}

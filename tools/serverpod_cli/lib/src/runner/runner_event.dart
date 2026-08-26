import 'package:serverpod_cli/src/config/flutter_app_config.dart';
import 'package:serverpod_cli/src/runner/log_codec.dart';
import 'package:serverpod_cli/src/runner/runner_manifest.dart';
import 'package:serverpod_cli/src/runner/runner_snapshot.dart';
import 'package:serverpod_shared/log.dart';
import 'package:serverpod_tui/serverpod_tui.dart'
    show CompletedOperation, TrackedOperation;

/// Everything that happens after the snapshot.
///
/// Needs no new vocabulary: the runner already receives framework and session
/// events over `ext.serverpod.log`, combines them with log calls originating in
/// the CLI, and feeds its history. These are the same entries, forwarded.
///
/// Clients compute elapsed durations from start timestamps, so an animating
/// spinner generates no traffic.
sealed class RunnerEvent {
  const RunnerEvent();

  Map<String, Object?> toJson();

  /// Decodes an event, or `null` for a kind this client does not know - a new
  /// runner may emit events an old client has never heard of, and skipping one
  /// is better than dropping the connection.
  static RunnerEvent? fromJson(Map<String, Object?> json) =>
      switch (json['event']) {
        'log' => ServerLogEvent(decodeLogEntry(json)),
        'operationStarted' => _operationStarted(json),
        'operationCompleted' => OperationCompletedEvent(
          decodeLogHistoryItem({...json, 'type': 'operation'})
              as CompletedOperation,
        ),
        'serverLine' => ServerLineEvent(json['line'] as String? ?? ''),
        'flutterLine' => FlutterLineEvent(
          appId: json['appId'] as String? ?? '',
          line: json['line'] as String? ?? '',
        ),
        'flutterLog' => FlutterLogEntryEvent(
          appId: json['appId'] as String? ?? '',
          entry: decodeLogEntry(json),
        ),
        'stage' => StageChangedEvent(
          RunnerStage.byName(json['stage'] as String?),
          isRunning: json['isRunning'] as bool? ?? false,
        ),
        'flutterApps' => FlutterAppsChangedEvent([
          for (final app in json['apps'] as List? ?? const [])
            if (app is Map<String, Object?>) decodeFlutterApp(app),
        ]),
        'flutterAppState' => FlutterAppStateEvent(
          appId: json['appId'] as String? ?? '',
          running: json['running'] as bool? ?? false,
          url: json['url'] as String?,
        ),
        'manifest' => ManifestChangedEvent(
          RunnerManifest.fromJson(
            json['manifest'] as Map<String, Object?>? ?? const {},
          ),
        ),
        _ => null,
      };
}

/// A structured entry appended to the server log.
final class ServerLogEvent extends RunnerEvent {
  const ServerLogEvent(this.entry);

  final LogEntry entry;

  @override
  Map<String, Object?> toJson() => {
    'event': 'log',
    ...encodeLogHistoryItem(entry),
  };
}

/// An operation - a hot reload, a migration, a server scope - has begun.
final class OperationStartedEvent extends RunnerEvent {
  const OperationStartedEvent(this.operation, {required this.startedAt});

  final TrackedOperation operation;
  final DateTime startedAt;

  @override
  Map<String, Object?> toJson() => {
    'event': 'operationStarted',
    ...encodeTrackedOperation(operation, startedAt: startedAt),
  };
}

/// An operation has finished, with the duration the runner measured.
final class OperationCompletedEvent extends RunnerEvent {
  const OperationCompletedEvent(this.operation);

  final CompletedOperation operation;

  @override
  Map<String, Object?> toJson() => {
    ...encodeLogHistoryItem(operation),
    // Overwrites the codec's `type` discriminator; the event name is what
    // routes this on the far side.
    'event': 'operationCompleted',
  };
}

/// A raw output line the pod printed.
final class ServerLineEvent extends RunnerEvent {
  const ServerLineEvent(this.line);

  final String line;

  @override
  Map<String, Object?> toJson() => {'event': 'serverLine', 'line': line};
}

/// A raw output line from a Flutter app.
final class FlutterLineEvent extends RunnerEvent {
  const FlutterLineEvent({required this.appId, required this.line});

  final String appId;
  final String line;

  @override
  Map<String, Object?> toJson() => {
    'event': 'flutterLine',
    'appId': appId,
    'line': line,
  };
}

/// A structured entry from a Flutter app.
final class FlutterLogEntryEvent extends RunnerEvent {
  const FlutterLogEntryEvent({required this.appId, required this.entry});

  final String appId;
  final LogEntry entry;

  @override
  Map<String, Object?> toJson() => {
    'event': 'flutterLog',
    'appId': appId,
    ...encodeLogHistoryItem(entry),
  };
}

/// The runner moved between startup stages.
final class StageChangedEvent extends RunnerEvent {
  const StageChangedEvent(this.stage, {required this.isRunning});

  final RunnerStage stage;
  final bool isRunning;

  @override
  Map<String, Object?> toJson() => {
    'event': 'stage',
    'stage': stage.name,
    'isRunning': isRunning,
  };
}

/// The set of configured Flutter apps changed, e.g. after the server pubspec
/// was edited.
final class FlutterAppsChangedEvent extends RunnerEvent {
  const FlutterAppsChangedEvent(this.apps);

  final List<FlutterAppConfig> apps;

  @override
  Map<String, Object?> toJson() => {
    'event': 'flutterApps',
    'apps': [for (final app in apps) encodeFlutterApp(app)],
  };
}

/// One Flutter app started, became ready, or stopped.
final class FlutterAppStateEvent extends RunnerEvent {
  const FlutterAppStateEvent({
    required this.appId,
    required this.running,
    this.url,
  });

  final String appId;
  final bool running;

  /// The app's URL once it is serving one; null on non-web devices and while
  /// it is still starting.
  final String? url;

  @override
  Map<String, Object?> toJson() => {
    'event': 'flutterAppState',
    'appId': appId,
    'running': running,
    if (url != null) 'url': url,
  };
}

/// A published address changed, so the manifest was rewritten.
///
/// This replaces the ad-hoc VM-service-URI-changed signal: the VM service URI
/// is not the only address that can change.
final class ManifestChangedEvent extends RunnerEvent {
  const ManifestChangedEvent(this.manifest);

  final RunnerManifest manifest;

  @override
  Map<String, Object?> toJson() => {
    'event': 'manifest',
    'manifest': manifest.toJson(),
  };
}

/// Rebuilds an [OperationStartedEvent] from the operation codec's record.
OperationStartedEvent _operationStarted(Map<String, Object?> json) {
  final decoded = decodeTrackedOperation(json);
  return OperationStartedEvent(decoded.operation, startedAt: decoded.startedAt);
}

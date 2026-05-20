import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:serverpod_cli/src/util/serverpod_cli_logger.dart';
import 'package:serverpod_shared/serverpod_shared.dart';

/// Snapshot of a running Flutter app, written by [FlutterProcess.start]
/// after the VM service comes up and used by the next session to decide
/// whether to spawn a fresh `flutter run` or attach to the existing app.
///
/// Liveness is checked by probing [vmServiceUri] over HTTP - if it
/// answers, an attach will work; if it doesn't, no PID-liveness check
/// would have helped anyway.
class FlutterRuntimeInfo {
  const FlutterRuntimeInfo({
    required this.vmServiceUri,
    required this.device,
    required this.flutterPackageDir,
    required this.createdAt,
  });

  final String vmServiceUri;
  final String device;
  final String flutterPackageDir;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
    'vmServiceUri': vmServiceUri,
    'device': device,
    'flutterPackageDir': flutterPackageDir,
    'createdAt': createdAt.toIso8601String(),
  };

  static FlutterRuntimeInfo? fromJson(Map<String, Object?> json) {
    try {
      return FlutterRuntimeInfo(
        vmServiceUri: json['vmServiceUri'] as String,
        device: json['device'] as String,
        flutterPackageDir: json['flutterPackageDir'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Path of the runtime-info file for the Flutter app [appId] inside
/// [serverpodToolDir]. Keyed per app so multiple companion apps don't
/// share (and clobber) a single reattach record.
String flutterRuntimeInfoPath(String serverpodToolDir, String appId) =>
    p.join(serverpodToolDir, 'flutter-runtime-$appId.json');

/// Reads [appId]'s runtime-info file. Returns `null` if missing or malformed.
Future<FlutterRuntimeInfo?> readFlutterRuntimeInfo(
  String serverpodToolDir,
  String appId,
) async {
  final file = File(flutterRuntimeInfoPath(serverpodToolDir, appId));
  if (!await file.exists()) return null;
  try {
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, Object?>) return null;
    return FlutterRuntimeInfo.fromJson(decoded);
  } catch (e) {
    log.debug('flutter-runtime-$appId.json unreadable: $e');
    return null;
  }
}

/// Writes [info] to [appId]'s runtime-info file. The id keys the file name
/// (`flutter-runtime-<appId>.json`) but is not part of the persisted payload.
Future<void> writeFlutterRuntimeInfo(
  String serverpodToolDir,
  String appId,
  FlutterRuntimeInfo info,
) async {
  final file = File(flutterRuntimeInfoPath(serverpodToolDir, appId));
  await file.parent.create(recursive: true);
  await file.writeAsString(jsonEncode(info.toJson()));
}

Future<void> deleteFlutterRuntimeInfo(
  String serverpodToolDir,
  String appId,
) async {
  await File(
    flutterRuntimeInfoPath(serverpodToolDir, appId),
  ).deleteIfExists();
}

/// True when [info]'s VM service URI is reachable AND it was spawned
/// against the same flutter package dir + device combination as the
/// caller is asking about. Used to decide reattach vs. fresh spawn.
///
/// Liveness is "can I open the URI" - that's what reattach actually
/// needs. A separate PID check would add nothing: native apps host
/// the VM service inside their own dart VM (URI dies with app); web
/// builds host it in DWDS inside flutter_tools (URI dies with that).
Future<bool> isFlutterRuntimeUsable(
  FlutterRuntimeInfo info, {
  required String currentFlutterPackageDir,
  required String currentDevice,
}) async {
  if (info.device != currentDevice) return false;
  if (p.normalize(info.flutterPackageDir) !=
      p.normalize(p.absolute(currentFlutterPackageDir))) {
    return false;
  }
  return _vmServiceReachable(info.vmServiceUri);
}

Future<bool> _vmServiceReachable(String httpUri) async {
  final uri = Uri.tryParse(httpUri);
  if (uri == null) return false;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
  try {
    final req = await client.getUrl(uri).timeout(const Duration(seconds: 1));
    final resp = await req.close().timeout(const Duration(seconds: 1));
    await resp.drain<void>();
    return true;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}

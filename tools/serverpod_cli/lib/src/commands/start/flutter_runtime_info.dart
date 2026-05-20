import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:serverpod_cli/src/util/serverpod_cli_logger.dart';
import 'package:serverpod_shared/process_io.dart';
import 'package:serverpod_shared/serverpod_shared.dart';

/// Snapshot of a running Flutter app, written by [FlutterProcess.start]
/// after the VM service comes up and used by the next session to decide
/// whether to spawn a fresh `flutter run` or attach to the existing app.
class FlutterRuntimeInfo {
  const FlutterRuntimeInfo({
    required this.appId,
    required this.vmServiceUri,
    required this.pid,
    required this.device,
    required this.flutterPackageDir,
    required this.createdAt,
  });

  final String appId;
  final String vmServiceUri;
  final int pid;
  final String device;
  final String flutterPackageDir;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
    'appId': appId,
    'vmServiceUri': vmServiceUri,
    'pid': pid,
    'device': device,
    'flutterPackageDir': flutterPackageDir,
    'createdAt': createdAt.toIso8601String(),
  };

  static FlutterRuntimeInfo? fromJson(Map<String, Object?> json) {
    try {
      return FlutterRuntimeInfo(
        appId: json['appId'] as String,
        vmServiceUri: json['vmServiceUri'] as String,
        pid: json['pid'] as int,
        device: json['device'] as String,
        flutterPackageDir: json['flutterPackageDir'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Path of the runtime-info file inside [serverpodToolDir].
String flutterRuntimeInfoPath(String serverpodToolDir) =>
    p.join(serverpodToolDir, 'flutter-runtime.json');

/// Reads the runtime-info file. Returns `null` if missing or malformed.
Future<FlutterRuntimeInfo?> readFlutterRuntimeInfo(
  String serverpodToolDir,
) async {
  final file = File(flutterRuntimeInfoPath(serverpodToolDir));
  if (!await file.exists()) return null;
  try {
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, Object?>) return null;
    return FlutterRuntimeInfo.fromJson(decoded);
  } catch (e) {
    log.debug('flutter-runtime.json unreadable: $e');
    return null;
  }
}

Future<void> writeFlutterRuntimeInfo(
  String serverpodToolDir,
  FlutterRuntimeInfo info,
) async {
  final file = File(flutterRuntimeInfoPath(serverpodToolDir));
  await file.parent.create(recursive: true);
  await file.writeAsString(jsonEncode(info.toJson()));
}

Future<void> deleteFlutterRuntimeInfo(String serverpodToolDir) async {
  await File(flutterRuntimeInfoPath(serverpodToolDir)).deleteIfExists();
}

/// True when [info] still refers to a live process whose VM service is
/// reachable AND it was spawned against the same flutter package dir
/// + device combination as the caller is asking about. Used to decide
/// reattach vs. fresh spawn.
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
  if (!isProcessAlive(info.pid)) return false;
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

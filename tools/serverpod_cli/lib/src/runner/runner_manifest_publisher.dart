import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:serverpod_cli/src/runner/runner_manifest.dart';
import 'package:serverpod_cli/src/util/serverpod_cli_logger.dart';

/// Keeps `runner.json` in step with the runner it describes.
///
/// Writes the manifest once the stack is up, rewrites it whenever a published
/// address changes, and removes it on a graceful shutdown. A crash skips the
/// removal, which is why liveness is a socket probe rather than the file
/// existing.
class RunnerManifestPublisher {
  RunnerManifestPublisher({
    required String serverDir,
    required RunnerManifest manifest,
  }) : _serverDir = serverDir,
       _manifest = manifest;

  final String _serverDir;
  RunnerManifest _manifest;
  StreamSubscription<void>? _addressSub;

  /// Serializes writes so a burst of address changes cannot interleave two
  /// encodings into one file.
  Future<void> _pending = Future.value();

  /// The manifest as last published.
  RunnerManifest get manifest => _manifest;

  /// Writes the manifest for the first time.
  Future<void> publish() => _write();

  /// Rewrites the manifest whenever [changes] fires, reading the current
  /// addresses through [resolve].
  ///
  /// [RunnerManifest.vmService] is not the only address that can change, so
  /// this takes a whole-manifest update rather than a URI.
  void republishOn(
    Stream<void> changes,
    RunnerManifest Function(RunnerManifest current) resolve,
  ) {
    _addressSub?.cancel();
    _addressSub = changes.listen((_) {
      _manifest = resolve(_manifest);
      unawaited(_write());
    });
  }

  /// Stops republishing and removes the manifest.
  Future<void> dispose() async {
    await _addressSub?.cancel();
    _addressSub = null;
    await _pending;
    await RunnerManifest.deleteFrom(_serverDir);
  }

  /// Writes the manifest, keeping a failure to itself.
  ///
  /// The chain has to survive one: a failed write - the tool directory removed
  /// under a running runner, say - would otherwise leave `_pending`
  /// permanently failed, so every later write is skipped and [dispose]
  /// rethrows into a teardown that still has Docker services and the lock to
  /// release.
  Future<void> _write() {
    return _pending = _pending
        .then((_) => _manifest.writeTo(_serverDir))
        .catchError((Object e) {
          log.warning('Failed to write the runner manifest: $e');
        });
  }
}

/// The Docker Compose project name for a stack rooted at [serverDir].
///
/// Mirrors Compose's own default, which it derives from the base name of the
/// directory it runs in: lowercased, with everything outside `[a-z0-9_-]`
/// dropped and any leading separators trimmed. Recorded in the manifest so
/// `serverpod status` can name the project a human would pass to
/// `docker compose -p`.
String composeProjectName(String serverDir) {
  final base = p.basename(p.canonicalize(serverDir)).toLowerCase();
  final kept = base.replaceAll(RegExp(r'[^a-z0-9_-]'), '');
  return kept.replaceFirst(RegExp(r'^[_-]+'), '');
}

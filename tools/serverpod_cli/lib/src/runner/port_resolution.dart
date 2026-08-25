import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:serverpod_cli/src/runner/runner_discovery.dart';

/// What the runner decided about the configured ports.
///
/// The two outcomes for an occupied port are settled for the whole set at
/// once, because what tells them apart is: another Serverpod runner being up
/// means a second worktree, which moves aside to ephemeral ports; anything
/// else - a stray pod from a previous run, an unrelated service on 8080 - is a
/// conflict to report rather than to hide.
class PortResolution {
  const PortResolution({required this.useEphemeral, required this.conflicts});

  /// Whether the pod should bind ephemeral ports instead of the configured
  /// ones.
  ///
  /// Decided for the three listeners as a block: an api server on 8080 with a
  /// web server on a port that moved is harder to reason about than a stack
  /// that is wholly where the manifest says.
  final bool useEphemeral;

  /// The ports held by something that is not a Serverpod runner. Non-empty
  /// means the runner must not start.
  final Map<String, int> conflicts;

  bool get hasConflicts => conflicts.isNotEmpty;
}

/// Decides whether the stack for [serverDir] can use [ports], or has to fall
/// back to ephemeral ones.
///
/// [ports] is keyed by listener name (`api`, `insights`, `web`) so a conflict
/// can be reported against the listener a developer configured.
Future<PortResolution> resolvePorts({
  required String serverDir,
  required Map<String, int> ports,
  Duration probeTimeout = const Duration(milliseconds: 300),
}) async {
  // Concurrently: each probe can sit out the whole timeout, and three of them
  // in a row is three timeouts on the path to starting a server.
  final entries = ports.entries.toList();
  final occupied = await Future.wait([
    for (final entry in entries)
      entry.value == 0
          // Already ephemeral; nothing to ask.
          ? Future.value(false)
          : _isListening(entry.value, probeTimeout),
  ]);

  if (!occupied.contains(true)) {
    return const PortResolution(useEphemeral: false, conflicts: {});
  }

  // Asked once for the whole set: the answer is about this machine, not about
  // a port, and finding it walks every sibling checkout probing its runner.
  final heldByRunner = await _anotherRunnerIsUp(serverDir);
  if (heldByRunner) {
    return const PortResolution(useEphemeral: true, conflicts: {});
  }

  return PortResolution(
    useEphemeral: false,
    conflicts: {
      for (var i = 0; i < entries.length; i++)
        if (occupied[i]) entries[i].key: entries[i].value,
    },
  );
}

Future<bool> _isListening(int port, Duration timeout) async {
  try {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: timeout,
    );
    socket.destroy();
    return true;
  } on SocketException {
    return false;
  }
}

/// Whether a live Serverpod runner other than this project's is up.
///
/// A port is attributed to a runner by finding a live one in a sibling
/// worktree, which is the only evidence the CLI has: the port itself says
/// nothing about who opened it. Siblings are looked for beside the repository
/// this server package sits in, which is where `git worktree` and a second
/// clone both put them.
Future<bool> _anotherRunnerIsUp(String serverDir) async {
  final canonical = p.canonicalize(serverDir);
  for (final candidate in _siblingServerDirs(canonical)) {
    if (candidate == canonical) continue;
    // The same liveness test the rest of the runner uses: a manifest left
    // behind by a crashed runner is not evidence of one. Being lenient here
    // would attribute a stray pod's port to a runner and silently move aside
    // instead of reporting the conflict.
    if (await resolveRunner(candidate) is LiveRunner) return true;
  }
  return false;
}

/// Server directories of other checkouts that might be running a stack.
///
/// Walks up from [serverDir] to the enclosing repository, then looks for the
/// same relative path under each sibling of that repository.
Iterable<String> _siblingServerDirs(String serverDir) sync* {
  final repoRoot = _repositoryRootOf(serverDir);
  if (repoRoot == null) return;

  final relative = p.relative(serverDir, from: repoRoot);
  final parent = Directory(p.dirname(repoRoot));
  if (!parent.existsSync()) return;

  for (final sibling in parent.listSync().whereType<Directory>()) {
    final candidate = p.canonicalize(p.join(sibling.path, relative));
    if (Directory(candidate).existsSync()) yield candidate;
  }
}

/// The nearest enclosing directory holding a `.git` entry, or null.
String? _repositoryRootOf(String from) {
  var dir = Directory(from);
  while (true) {
    if (Directory(p.join(dir.path, '.git')).existsSync() ||
        File(p.join(dir.path, '.git')).existsSync()) {
      return p.canonicalize(dir.path);
    }
    final parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
}

/// The environment overrides that make the pod bind ephemeral ports for
/// [listeners], named the way [resolvePorts] names them.
///
/// The pod derives its advertised port from the bound one when the configured
/// port is 0, so a client generated against the manifest reaches the stack
/// that actually answers.
///
/// Only the listeners the project configured are overridden. A port variable
/// is enough on its own to bring a listener into existence - the config merges
/// the environment over whatever the yaml holds, so an insights port set for a
/// project with no `insightsServer:` section would start an insights server
/// nobody asked for.
Map<String, String> ephemeralPortEnvironment(Iterable<String> listeners) => {
  for (final listener in listeners) ?portEnvironmentVariables[listener]: '0',
};

/// The environment variable that sets each listener's port.
const portEnvironmentVariables = {
  'api': 'SERVERPOD_API_SERVER_PORT',
  'insights': 'SERVERPOD_INSIGHTS_SERVER_PORT',
  'web': 'SERVERPOD_WEB_SERVER_PORT',
};

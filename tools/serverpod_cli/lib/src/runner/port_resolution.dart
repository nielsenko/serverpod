import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:serverpod_cli/src/runner/runner_discovery.dart';
import 'package:serverpod_cli/src/runner/runner_manifest.dart';
import 'package:serverpod_shared/serverpod_shared.dart';

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

  /// The ports held by something that is not a Serverpod runner.
  ///
  /// Non-empty means the runner must not start.
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
  final occupied = <String, int>{};
  await Future.wait([
    for (final entry in ports.entries)
      // A port of 0 is already ephemeral; nothing to ask.
      if (entry.value != 0)
        _isListening(entry.value, probeTimeout).then((listening) {
          if (listening) occupied[entry.key] = entry.value;
        }),
  ]);

  if (occupied.isEmpty) {
    return const PortResolution(useEphemeral: false, conflicts: {});
  }

  final heldByRunners = await _portsHeldByOtherRunners(serverDir);
  final conflicts = {
    for (final entry in occupied.entries)
      if (!heldByRunners.contains(entry.value)) entry.key: entry.value,
  };

  if (conflicts.isEmpty) {
    return const PortResolution(useEphemeral: true, conflicts: {});
  }

  return PortResolution(useEphemeral: false, conflicts: conflicts);
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

/// The ports other live Serverpod runners have published as theirs.
///
/// A runner's manifest names the addresses its listeners actually bound, so
/// that is what attributes a port to it. The alternative - taking any live
/// runner anywhere as proof - moves the whole stack aside for a sibling that
/// binds entirely different ports, and still calls a fellow runner a hard
/// conflict when it happens not to be a directory sibling.
///
/// Candidates are looked for beside the repository this server package sits
/// in, which is where `git worktree` and a second clone both put them.
Future<Set<int>> _portsHeldByOtherRunners(String serverDir) async {
  final canonical = p.canonicalize(serverDir);
  final runners = await Future.wait([
    for (final candidate in _siblingServerDirs(canonical))
      if (candidate != canonical) resolveRunner(candidate),
  ]);
  return {
    for (final runner in runners)
      if (runner is LiveRunner)
        for (final port in _publishedPorts(runner.manifest)) port,
  };
}

/// The ports named by a manifest's published server addresses.
Iterable<int> _publishedPorts(RunnerManifest manifest) sync* {
  final servers = manifest.servers;
  if (servers == null) return;
  for (final url in [servers.api, servers.insights, servers.web]) {
    if (url == null) continue;
    final port = Uri.tryParse(url)?.port;
    // `Uri.port` is 0 when the URL names no port and no known scheme default.
    if (port != null && port != 0) yield port;
  }
}

/// Returns the server directories of other checkouts that might be running a
/// stack.
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

/// Returns the nearest enclosing directory holding a `.git` entry, or null.
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

/// Returns the environment overrides that make the pod bind ephemeral ports
/// for [listeners], named the way [resolvePorts] names them.
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

/// The environment variable that sets each listener's port, by listener name.
final portEnvironmentVariables = {
  'api': ServerpodEnv.apiPort.envVariable,
  'insights': ServerpodEnv.insightsPort.envVariable,
  'web': ServerpodEnv.webPort.envVariable,
};

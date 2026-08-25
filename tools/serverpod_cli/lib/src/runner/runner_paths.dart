import 'package:path/path.dart' as p;

/// The directory holding every artifact the runner publishes for the server
/// project rooted at [serverDir].
///
/// Kept inside the project's `.dart_tool/` so it is scoped to one worktree,
/// easy to discover, and ignored by VCS.
String serverpodToolDirPath(String serverDir) =>
    p.join(serverDir, '.dart_tool', 'serverpod');

/// Where the runner records its sockets, addresses and effective configuration.
///
/// Written when the runner starts and removed when it shuts down. A crashed
/// runner leaves the file behind, so liveness is decided by connecting to the
/// socket it names rather than by the file's existence.
String serverpodRunnerManifestPath(String serverDir) =>
    p.join(serverpodToolDirPath(serverDir), 'runner.json');

/// The lock file whose exclusive advisory lock admits one runner per server
/// package.
///
/// Unlike the manifest and the socket files, this needs no cleanup: the kernel
/// releases the lock when the holding process dies.
String serverpodRunnerLockPath(String serverDir) =>
    p.join(serverpodToolDirPath(serverDir), 'runner.lock');

/// The socket a UI attaches to.
///
/// Separate from the MCP socket because MCP's request/response vocabulary of
/// tools and resources does not fit the continuous event stream a UI consumes.
String serverpodTuiSocketPath(String serverDir) =>
    p.join(serverpodToolDirPath(serverDir), 'tui.sock');

/// Where a detached runner writes its output.
///
/// The in-memory log history is bounded and dies with the process, so it cannot
/// record a run nobody attached to.
String serverpodRunnerLogPath(String serverDir) =>
    p.join(serverpodToolDirPath(serverDir), 'runner.log');

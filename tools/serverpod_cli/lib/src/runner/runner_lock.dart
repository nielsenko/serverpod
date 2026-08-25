import 'dart:io';

import 'package:serverpod_cli/src/runner/runner_paths.dart';

/// Thrown when a runner is already holding the lock for a server package.
class RunnerLockedException implements Exception {
  const RunnerLockedException(this.lockPath);

  /// The lock file whose lock could not be taken.
  final String lockPath;

  @override
  String toString() =>
      'Another serverpod runner is already running for this server package '
      '(lock: $lockPath).';
}

/// The exclusive advisory lock that admits one runner per server package.
///
/// Probing a socket is a check followed by a use: two runners starting at the
/// same moment can both probe, find nothing, and bind, and `bindUnixSocket`
/// unlinks the stale socket file, so the second silently displaces the first.
/// That matters because the resident Frontend Server writes a shared
/// `server.dill` and Docker Compose teardown is conditional on this runner
/// having started the services, so one runner per package has to be enforced
/// rather than left to a fixed socket path.
///
/// The lock lives on an open file descriptor, so the kernel releases it when
/// the process dies. Unlike the manifest and the socket files, a crashed runner
/// leaves nothing here to clean up.
///
/// POSIX advisory locks are held per process, so [acquire] succeeding is not a
/// mutex within one process - a second call in the same process takes the lock
/// again. That is not the contention this guards: two runners are two
/// processes.
class RunnerLock {
  RunnerLock._(this._file, this.lockPath);

  final RandomAccessFile _file;

  /// The locked file's path.
  final String lockPath;

  bool _released = false;

  /// Takes the lock for the server package at [serverDir].
  ///
  /// Throws [RunnerLockedException] immediately when another runner holds it -
  /// this never waits, because a caller that wanted to wait would be queuing
  /// behind a runner that is expected to stay up for days.
  static Future<RunnerLock> acquire(String serverDir) async {
    final lockPath = serverpodRunnerLockPath(serverDir);
    final file = File(lockPath);
    await file.parent.create(recursive: true);

    final handle = await file.open(mode: FileMode.write);
    try {
      // FileLock.exclusive is the non-blocking mode; blockingExclusive waits.
      await handle.lock(FileLock.exclusive);
    } on FileSystemException {
      await handle.close();
      throw RunnerLockedException(lockPath);
    }
    return RunnerLock._(handle, lockPath);
  }

  /// Releases the lock and closes the file. Idempotent.
  ///
  /// Only needed for a graceful shutdown, and in tests, where the process
  /// outlives the lock.
  Future<void> release() async {
    if (_released) return;
    _released = true;
    try {
      await _file.unlock();
    } on FileSystemException {
      // Already released, or the file went away with the lock.
    }
    await _file.close();
  }
}

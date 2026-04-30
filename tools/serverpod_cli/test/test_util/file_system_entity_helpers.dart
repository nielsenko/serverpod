import 'dart:io';

extension FileSystemEntityDeleteWithRetry on FileSystemEntity {
  /// Deletes this entity, retrying briefly on failures
  ///
  /// POSIX permits unlinking files with open handles, so this is effectively a
  /// single delete on macOS/Linux. On Windows that would raise a [PathAccessException].
  /// Hence, due to how file handles can linger a bit after a process exits a regular
  /// [delete] can race with process exit on Windows.
  Future<void> deleteWithRetry({
    bool recursive = false,
    int attempts = 10,
    Duration delay = const Duration(milliseconds: 200),
  }) async {
    if (!await exists()) return;
    for (var i = 0; i < attempts; i++) {
      try {
        await delete(recursive: recursive);
        return;
      } on PathAccessException {
        if (i == attempts - 1) rethrow;
        await Future<void>.delayed(delay);
      }
    }
  }
}

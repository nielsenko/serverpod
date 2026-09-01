import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:serverpod_cli/src/runner/line_sink.dart';
import 'package:serverpod_cli/src/runner/log_codec.dart';
import 'package:serverpod_cli/src/runner/runner_paths.dart';
import 'package:serverpod_cli/src/util/strip_ansi.dart';
import 'package:serverpod_shared/log.dart';

/// The runner's own log file.
///
/// A detached runner has no stdio: [ProcessStartMode.detached] gives the child
/// no streams, and piping through the parent would die with it. So the runner
/// writes its output here itself rather than relying on redirection.
///
/// Size-capped and rotated. The in-memory history a client renders is bounded
/// and dies with the process, so this is the only record of a run nobody
/// attached to - and the runner is expected to stay up for days.
class RunnerLogFile {
  RunnerLogFile({
    required this.path,
    this.maxBytes = defaultMaxBytes,
  });

  /// Opens the log for the server package at [serverDir].
  factory RunnerLogFile.forServer(String serverDir, {int? maxBytes}) =>
      RunnerLogFile(
        path: serverpodRunnerLogPath(serverDir),
        maxBytes: maxBytes ?? defaultMaxBytes,
      );

  /// The size past which the file is rotated.
  ///
  /// One previous generation is kept, as `runner.log.1`.
  static const defaultMaxBytes = 8 * 1024 * 1024;

  final String path;
  final int maxBytes;

  IOSink? _sink;
  int _written = 0;
  bool _rotating = false;

  /// The size at which the next rotation is attempted.
  ///
  /// [maxBytes], except after a rotation that could not rename the file: the
  /// log is then still full, and trying again on the very next line would
  /// spin - flush, close, rename, reopen - for as long as the rename keeps
  /// failing, holding every line back meanwhile. So the next attempt waits
  /// for another [maxBytes] of output.
  int _rotateAt = 0;

  /// The rotation in flight, so [close] can wait for it rather than racing it
  /// to the sink.
  Future<void>? _rotation;

  /// Lines with nowhere to go yet, flushed once the file is open again.
  ///
  /// Rotation is asynchronous while [writeLine] is not, so without this every
  /// line written across a rotation - the line that triggered it included - is
  /// lost, and at an 8 MB boundary that burst is as likely as not the crash
  /// output someone opened the log to read.
  final List<String> _pending = [];

  /// How many lines to hold across a rotation before dropping the oldest.
  ///
  /// A bound only a wedged rotation reaches, and unbounded is worse: this runs
  /// for days.
  static const _maxPendingLines = 4096;

  /// The path of the single retained previous generation.
  String get previousPath => '$path.1';

  /// Opens the file, appending to whatever a previous run left.
  Future<void> open() async {
    final file = File(path);
    await file.parent.create(recursive: true);
    _written = await file.exists() ? await file.length() : 0;
    _rotateAt = maxBytes;
    _sink = file.openWrite(mode: FileMode.append);
  }

  /// Appends [line], rotating first when the file has grown past [maxBytes].
  ///
  /// ANSI styling is stripped: nothing renders this file as a terminal, and
  /// escape codes in a log a human greps are noise.
  void writeLine(String line) {
    _write('${stripAnsi(line)}\n');
  }

  /// An [IOSink] that records everything written to it in this log file.
  ///
  /// Used for the pod's stdout and stderr, which are otherwise lost in a
  /// runner with no terminal.
  LineSink lineSink({String? prefix}) =>
      LineSink((line) => writeLine('${prefix ?? ''}$line'));

  void _write(String text) {
    final sink = _sink;
    if (sink == null || _rotating) {
      _hold(text);
      return;
    }
    // Encoded here rather than by the sink so the running total is in the
    // same unit as the size [open] reads off the file: a log carrying
    // non-ASCII is otherwise measured short of what it takes on disk, and
    // grows past [maxBytes] before anything rotates it.
    final bytes = utf8.encode(text);
    if (_written > 0 && _written + bytes.length > _rotateAt) {
      _hold(text);
      _rotation = _rotate();
      return;
    }
    _written += bytes.length;
    sink.add(bytes);
  }

  void _hold(String text) {
    if (_pending.length >= _maxPendingLines) _pending.removeAt(0);
    _pending.add(text);
  }

  Future<void> _rotate() async {
    if (_rotating) return;
    _rotating = true;
    final sink = _sink;
    _sink = null;
    await sink?.flush();
    await sink?.close();

    var rotated = true;
    try {
      final previous = File(previousPath);
      if (await previous.exists()) await previous.delete();
      await File(path).rename(previousPath);
    } on FileSystemException {
      // Losing a rotation is better than losing the runner.
      rotated = false;
    }
    await open();
    if (!rotated) _rotateAt = _written + maxBytes;
    _rotating = false;
    _flushPending();
  }

  /// Writes what was held across a rotation, oldest first.
  void _flushPending() {
    if (_pending.isEmpty) return;
    final held = List.of(_pending);
    _pending.clear();
    for (final text in held) {
      _write(text);
    }
  }

  Future<void> close() async {
    var rotation = _rotation;
    while (rotation != null) {
      _rotation = null;
      await rotation;
      rotation = _rotation;
    }
    final sink = _sink;
    _sink = null;
    for (final text in _pending) {
      sink?.write(text);
    }
    _pending.clear();
    await sink?.flush();
    await sink?.close();
  }
}

/// A [LogWriter] that appends the CLI's own log to the runner's log file.
///
/// Paired with the file sinks the pod and the Flutter apps write to, this is
/// what makes a detached runner's output survive the process.
class RunnerLogFileWriter extends LogWriter {
  RunnerLogFileWriter(this._file);

  final RunnerLogFile _file;

  @override
  Future<void> log(LogEntry entry) async {
    _file.writeLine(formatLogEntryLine(entry));
  }

  @override
  Future<void> openScope(LogScope scope) async {
    _file.writeLine(
      '${scope.startTime.toIso8601String()} [SCOPE] ${scope.label} started',
    );
  }

  @override
  Future<void> closeScope(
    LogScope scope, {
    required bool success,
    required Duration duration,
    Object? error,
    StackTrace? stackTrace,
  }) async {
    _file.writeLine(
      '[SCOPE] ${scope.label} '
      '${success ? 'succeeded' : 'failed'} in ${duration.inMilliseconds}ms',
    );
    if (error != null) _file.writeLine('$error');
  }

  @override
  Future<void> close() => _file.close();
}

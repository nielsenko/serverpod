import 'dart:async';
import 'dart:io';

import 'log_types.dart';

bool _isInteractive = stdout.hasTerminal;

bool _ansiSupported = _isInteractive && stdout.supportsAnsiEscapes;

String _green(String text) => _ansiSupported ? '\x1B[92m$text\x1B[0m' : text;

String _yellow(String text) => _ansiSupported ? '\x1B[93m$text\x1B[0m' : text;

String _red(String text) => _ansiSupported ? '\x1B[91m$text\x1B[0m' : text;

String _gray(String text) => _ansiSupported ? '\x1B[90m$text\x1B[0m' : text;

String _cyan(String text) => _ansiSupported ? '\x1B[36m$text\x1B[0m' : text;

const _clearLine = '\u001b[2K\r';

const _brailleFrames = '⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏';

String _formatElapsed(Duration d) {
  final ms = d.inMilliseconds;
  if (ms < 100) return '${ms}ms';
  return '${(ms / 1000).toStringAsFixed(1)}s';
}

/// State for a single in-progress scope with a braille spinner.
class _ActiveScope {
  _ActiveScope(this.scope) : stopwatch = Stopwatch()..start();

  final LogScope scope;
  final Stopwatch stopwatch;
  int frameIndex = 0;
}

/// A [LogWriter] that writes formatted text to stdout/stderr.
///
/// When stdout is a terminal, [openScope]/[closeScope] show a braille spinner
/// that animates on the last line. Log messages print above the spinner.
/// When stdout is not a terminal, output is plain text with no escape codes.
class TextLogWriter extends LogWriter {
  final List<_ActiveScope> _scopeStack = [];
  Timer? _timer;

  void _startTimer() {
    if (_timer != null) return;
    _timer = Timer.periodic(const Duration(milliseconds: 80), (_) {
      _drawSpinner();
    });
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _drawSpinner() {
    if (_scopeStack.isEmpty || !_isInteractive) return;
    final active = _scopeStack.last;
    active.frameIndex++;
    final frame = _brailleFrames[active.frameIndex % _brailleFrames.length];
    final elapsed = _gray('(${_formatElapsed(active.stopwatch.elapsed)})');
    stdout.write(
      '$_clearLine${_cyan(frame)} ${active.scope.label}... $elapsed',
    );
  }

  void _clearSpinnerLine() {
    if (_isInteractive && _scopeStack.isNotEmpty) {
      stdout.write(_clearLine);
    }
  }

  @override
  Future<void> log(LogEntry entry) async {
    _clearSpinnerLine();

    final prefix = switch (entry.level) {
      LogLevel.debug => _gray('DEBUG: '),
      LogLevel.info => '',
      LogLevel.warning => _yellow('WARNING: '),
      LogLevel.error || LogLevel.fatal => _red('ERROR: '),
    };
    final output = '$prefix${entry.message}';
    if (entry.level.index >= LogLevel.error.index) {
      stderr.writeln(output);
      if (entry.error != null) stderr.writeln('${entry.error}');
      if (entry.stackTrace != null) stderr.writeln('${entry.stackTrace}');
    } else {
      stdout.writeln(output);
    }

    _drawSpinner();
  }

  @override
  Future<void> openScope(LogScope scope) async {
    if (_isInteractive) {
      _clearSpinnerLine();
      final active = _ActiveScope(scope);
      _scopeStack.add(active);
      _drawSpinner();
      _startTimer();
    } else {
      stdout.writeln('${scope.label}...');
    }
  }

  @override
  Future<void> closeScope(
    LogScope scope, {
    required bool success,
    required Duration duration,
    Object? error,
    StackTrace? stackTrace,
  }) async {
    if (_isInteractive) {
      _clearSpinnerLine();
      _scopeStack.removeWhere((s) => s.scope.id == scope.id);
      if (_scopeStack.isEmpty) _stopTimer();

      final elapsed = _gray('(${_formatElapsed(duration)})');
      final icon = success ? _green('\u2713') : _red('\u2717');
      stdout.writeln('$icon ${scope.label} $elapsed');
    } else {
      final status = success ? 'done' : 'failed';
      stdout.writeln('${scope.label} $status. (${_formatElapsed(duration)})');
    }
  }
}

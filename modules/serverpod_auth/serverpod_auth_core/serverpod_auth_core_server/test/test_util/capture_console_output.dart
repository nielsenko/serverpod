import 'dart:convert';
import 'dart:io';

/// Runs [body] with `stdout` and `stderr` redirected and returns everything
/// written to either of them.
Future<String> captureConsoleOutput(final Future<void> Function() body) async {
  final console = _CapturingStdout();
  await IOOverrides.runZoned(
    body,
    stdout: () => console,
    stderr: () => console,
  );
  return console.output;
}

class _CapturingStdout implements Stdout {
  final _buffer = StringBuffer();

  String get output => _buffer.toString();

  @override
  Encoding encoding = utf8;

  @override
  String lineTerminator = '\n';

  @override
  void add(final List<int> data) => _buffer.write(utf8.decode(data));

  @override
  void write(final Object? object) => _buffer.write(object);

  @override
  void writeAll(final Iterable<Object?> objects, [final String sep = '']) =>
      _buffer.writeAll(objects, sep);

  @override
  void writeCharCode(final int charCode) => _buffer.writeCharCode(charCode);

  @override
  void writeln([final Object? object = '']) => _buffer.writeln(object);

  @override
  bool get hasTerminal => false;

  @override
  bool get supportsAnsiEscapes => false;

  @override
  Future<void> flush() async {}

  @override
  dynamic noSuchMethod(final Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

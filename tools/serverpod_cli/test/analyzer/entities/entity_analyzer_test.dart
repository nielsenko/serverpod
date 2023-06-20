import 'package:serverpod_cli/src/analyzer/entities/entity_analyzer.dart';
import 'package:serverpod_cli/src/generator/code_generation_collector.dart';
import 'package:test/test.dart';

void main() {
  group('Given a protocol without any defined entity type', () {
    test(
        'Then return a human readable error message informing the user that the entity type is missing.',
        () {
      var collector = CodeGenerationCollector();
      var analyzer = SerializableEntityAnalyzer(
        yaml: '''
invalid: Type 
fields:
  name: String
''',
        sourceFileName: 'lib/src/protocol/example.yaml',
        outFileName: 'example.yaml',
        subDirectoryParts: ['lib', 'src', 'protocol'],
        collector: collector,
      );

      analyzer.analyze();

      expect(collector.errors, hasLength(1));

      var error = collector.errors.first;
      expect(
          error.message, 'No "class", "exception" or "enum" type is defined.');
    });
  });

  group('Given a protocol with class and exception type defined.', () {
    test('Then return a human readable error message when analyzing.', () {
      var collector = CodeGenerationCollector();
      var analyzer = SerializableEntityAnalyzer(
        yaml: '''
class: Example
exception: ExampleException
fields:
  name: String
''',
        sourceFileName: 'lib/src/protocol/example.yaml',
        outFileName: 'example.yaml',
        subDirectoryParts: ['lib', 'src', 'protocol'],
        collector: collector,
      );

      analyzer.analyze();

      expect(collector.errors, hasLength(1));

      var error = collector.errors.first;
      expect(error.message,
          'Multiple entity types ("class", "exception") found for a single entity. Only one type per entity allowed.');
    });

    test('Then the second type is highlighted.', () {
      var collector = CodeGenerationCollector();
      var analyzer = SerializableEntityAnalyzer(
        yaml: '''
class: Example
exception: ExampleException
fields:
  name: String
''',
        sourceFileName: 'lib/src/protocol/example.yaml',
        outFileName: 'example.yaml',
        subDirectoryParts: ['lib', 'src', 'protocol'],
        collector: collector,
      );

      analyzer.analyze();

      expect(collector.errors, hasLength(1));
      var span = collector.errors.first.span;

      expect(span?.start.line, 1);
      expect(span?.start.column, 0);

      expect(span?.end.line, 1);
      expect(span?.end.column, 'exception'.length);
    });
  });

  group('Given a protocol with exception and enum type defined.', () {
    test('Then return a human readable error message when analyzing.', () {
      var collector = CodeGenerationCollector();
      var analyzer = SerializableEntityAnalyzer(
        yaml: '''
exception: ExampleException
enum: ExampleType
fields:
  name: String
''',
        sourceFileName: 'lib/src/protocol/example.yaml',
        outFileName: 'example.yaml',
        subDirectoryParts: ['lib', 'src', 'protocol'],
        collector: collector,
      );

      analyzer.analyze();

      expect(collector.errors.length, greaterThan(0));

      var error = collector.errors.first;
      expect(error.message,
          'Multiple entity types ("exception", "enum") found for a single entity. Only one type per entity allowed.');
    });
  });

  group('Given a protocol with three different types defined.', () {
    test('Then return a human readable error message when analyzing.', () {
      var collector = CodeGenerationCollector();
      var analyzer = SerializableEntityAnalyzer(
        yaml: '''
class: Example
exception: ExampleException
enum: ExampleType
fields:
  name: String
''',
        sourceFileName: 'lib/src/protocol/example.yaml',
        outFileName: 'example.yaml',
        subDirectoryParts: ['lib', 'src', 'protocol'],
        collector: collector,
      );

      analyzer.analyze();

      expect(collector.errors.length, greaterThan(0));

      var error = collector.errors.first;
      expect(error.message,
          'Multiple entity types ("class", "exception", "enum") found for a single entity. Only one type per entity allowed.');
    });

    test('Then the second and third type is highlighted.', () {
      var collector = CodeGenerationCollector();
      var analyzer = SerializableEntityAnalyzer(
        yaml: '''
class: Example
exception: ExampleException
enum: ExampleType
fields:
  name: String
''',
        sourceFileName: 'lib/src/protocol/example.yaml',
        outFileName: 'example.yaml',
        subDirectoryParts: ['lib', 'src', 'protocol'],
        collector: collector,
      );

      analyzer.analyze();

      expect(collector.errors.length, greaterThan(1));

      var span = collector.errors[0].span;

      expect(span?.start.line, 1);
      expect(span?.start.column, 0);
      expect(span?.end.line, 1);
      expect(span?.end.column, 'exception'.length);

      var span2 = collector.errors[1].span;

      expect(span2?.start.line, 2);
      expect(span2?.start.column, 0);
      expect(span2?.end.line, 2);
      expect(span2?.end.column, 'enum'.length);
    });
  });
}
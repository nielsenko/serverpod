import 'package:serverpod_cli/src/commands/start/jaspr/jaspr_shape.dart';
import 'package:test/test.dart';

const _counter = '''
import 'package:jaspr/jaspr.dart';

@client
class Counter extends StatefulComponent {
  const Counter({required this.start, super.key});

  final int start;

  @override
  State<Counter> createState() => _CounterState();
}

class _CounterState extends State<Counter> {
  @sync
  int count = 0;

  @css
  static List<StyleRule> get styles => [css('.counter').styles(padding: 1)];

  @override
  Component build(BuildContext context) => text('Count: \$count');
}
''';

void main() {
  test(
    'Given a @client component, '
    'when only a build method body changes, '
    'then its shape is unchanged.',
    () {
      final edited = _counter.replaceFirst("'Count: ", "'Clicks: ");

      expect(jasprShapeOf(edited), jasprShapeOf(_counter));
    },
  );

  test(
    'Given a @css member, '
    'when only its style value changes, '
    'then the shape is unchanged.',
    () {
      final edited = _counter.replaceFirst('padding: 1', 'padding: 2');

      expect(jasprShapeOf(edited), jasprShapeOf(_counter));
    },
  );

  test(
    'Given a @client component, '
    'when a constructor parameter is added, '
    'then its shape changes.',
    () {
      final edited = _counter.replaceFirst(
        'required this.start,',
        'required this.start, this.step = 1,',
      );

      expect(jasprShapeOf(edited), isNot(jasprShapeOf(_counter)));
    },
  );

  test(
    'Given a @client component, '
    'when the type of a field its constructor initializes changes, '
    'then its shape changes.',
    () {
      final edited = _counter.replaceFirst(
        'final int start;',
        'final String start;',
      );

      expect(jasprShapeOf(edited), isNot(jasprShapeOf(_counter)));
    },
  );

  test(
    'Given a component without annotations, '
    'when @client is added to it, '
    'then its shape changes.',
    () {
      final plain = _counter.replaceFirst('@client\n', '');

      expect(jasprShapeOf(_counter), isNot(jasprShapeOf(plain)));
    },
  );

  test(
    'Given a state class, '
    'when a @sync field is added, '
    'then the shape changes.',
    () {
      final edited = _counter.replaceFirst(
        'int count = 0;',
        'int count = 0;\n\n  @sync\n  String label = "";',
      );

      expect(jasprShapeOf(edited), isNot(jasprShapeOf(_counter)));
    },
  );

  test(
    'Given a source file, '
    'when an import is added, '
    'then the shape changes.',
    () {
      const edited = "import 'other.dart';\n$_counter";

      expect(jasprShapeOf(edited), isNot(jasprShapeOf(_counter)));
    },
  );
}

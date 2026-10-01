import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';

/// The parts of a Dart source file that Jaspr's generator reads, as a string
/// that changes only when they do.
///
/// The generator writes the client and server options, sync mixins and
/// platform imports from annotated declarations: the `@client` classes with
/// their constructor parameters and the fields those parameters initialize,
/// `@sync` fields, the names of `@css` members, `@encoder` and `@decoder`
/// functions, and `@Import` directives.
/// It also follows imports to find the components an entrypoint reaches, so
/// every directive is part of the shape. Editing a method body or a style's
/// value leaves the generated code as it is.
///
/// Null when the file does not parse, which callers treat as a change.
String? jasprShapeOf(String source) {
  final CompilationUnit unit;
  try {
    unit = parseString(content: source, throwIfDiagnostics: false).unit;
  } catch (_) {
    return null;
  }

  final shape = StringBuffer();
  for (final directive in unit.directives) {
    shape.writeln(directive.toSource());
  }
  for (final declaration in unit.declarations) {
    switch (declaration) {
      case ClassDeclaration(:final metadata) when metadata.isNotEmpty:
        _writeClass(shape, declaration);
      case ClassDeclaration():
        _writeAnnotatedMembers(shape, _className(declaration), declaration);
      case FunctionDeclaration(:final metadata) when metadata.isNotEmpty:
        shape.writeln('${_annotations(metadata)} ${declaration.name.lexeme}');
      case TopLevelVariableDeclaration(:final metadata)
          when metadata.isNotEmpty:
        shape.writeln(
          '${_annotations(metadata)} '
          '${declaration.variables.variables.map((v) => v.name.lexeme)}',
        );
      default:
        break;
    }
  }
  return shape.toString();
}

void _writeClass(StringBuffer shape, ClassDeclaration declaration) {
  shape.writeln(
    '${_annotations(declaration.metadata)} '
    'class ${declaration.namePart.toSource()}',
  );
  for (final member in _members(declaration)) {
    switch (member) {
      case ConstructorDeclaration():
        shape.writeln(
          '  ${member.name?.lexeme ?? ''}${member.parameters.toSource()}',
        );
      // A `this.x` parameter takes its type from the field.
      case FieldDeclaration(:final fields):
        shape.writeln(
          '  ${fields.type?.toSource() ?? ''} '
          '${fields.variables.map((v) => v.name.lexeme)}',
        );
      default:
        break;
    }
  }
  _writeAnnotatedMembers(shape, _className(declaration), declaration);
}

// Fields like `@sync int count` and members like `@css static List<...>`
// sit in classes that need not be annotated themselves.
void _writeAnnotatedMembers(
  StringBuffer shape,
  String className,
  ClassDeclaration declaration,
) {
  for (final member in _members(declaration)) {
    if (member.metadata.isEmpty) continue;
    switch (member) {
      case FieldDeclaration(:final fields):
        shape.writeln(
          '  $className ${_annotations(member.metadata)} '
          '${fields.type?.toSource() ?? ''} '
          '${fields.variables.map((v) => v.name.lexeme)}',
        );
      case MethodDeclaration(:final name):
        shape.writeln(
          '  $className ${_annotations(member.metadata)} ${name.lexeme}',
        );
      default:
        break;
    }
  }
}

String _annotations(NodeList<Annotation> metadata) =>
    metadata.map((a) => a.toSource()).join(' ');

String _className(ClassDeclaration declaration) =>
    declaration.namePart.typeName.lexeme;

List<ClassMember> _members(ClassDeclaration declaration) =>
    switch (declaration.body) {
      BlockClassBody(:final members) => members,
      EmptyClassBody() => const [],
    };

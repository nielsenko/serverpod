import 'package:serverpod_cli/analyzer.dart';
import 'package:serverpod_cli/src/util/model_helper.dart';

import 'model_source_builder.dart';

class RelationModelSourceBuilder {
  bool serverOnlyParent;
  bool serverOnlyChild;
  bool isOptionalOrNullable;
  bool isIdRelation;
  ModelFieldScopeDefinition? fieldScope;

  RelationModelSourceBuilder({
    this.serverOnlyParent = false,
    this.serverOnlyChild = false,
    this.isOptionalOrNullable = false,
    this.isIdRelation = false,
    this.fieldScope,
  });

  List<ModelSource> build() {
    var scope = fieldScope == null ? '' : ', scope=${fieldScope!.name}';
    String serverOnlyIf(bool condition) => condition ? 'serverOnly: true' : '';
    return [
      ModelSourceBuilder()
          .withFileName('parent')
          .withYaml(
            [
              'class: Parent',
              'table: parent',
              serverOnlyIf(serverOnlyParent),
            ].joinNonEmpty('\n'),
          )
          .build(),
      ModelSourceBuilder()
          .withFileName('child')
          .withYaml(
            [
              'class: Child',
              'table: child',
              serverOnlyIf(serverOnlyChild),
              'fields:',
              if (isIdRelation)
                '  parentId: int${isOptionalOrNullable ? '?' : ''}$scope'
              else
                '  parent: Parent?, relation${isOptionalOrNullable ? '(optional)' : ''}$scope',
            ].joinNonEmpty('\n'),
          )
          .build(),
    ];
  }
}

extension on List<String?> {
  String joinNonEmpty(String separator) =>
      where((s) => s != null && s.isNotEmpty).join(separator);
}

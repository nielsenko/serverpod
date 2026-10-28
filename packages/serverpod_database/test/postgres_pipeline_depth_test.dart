import 'package:serverpod_database/serverpod_database.dart';
import 'package:serverpod_database/src/adapters/postgres/postgres_pool_manager.dart';
import 'package:serverpod_shared/serverpod_shared.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Given a postgresPipelineDepth, '
    'when the pool manager is created, '
    'then its pool settings carry it',
    () {
      postgresPipelineDepth = 8;
      addTearDown(() => postgresPipelineDepth = 1);

      final poolManager = PostgresPoolManager(
        _TestSerializationManager(),
        null,
        PostgresDatabaseConfig(
          host: 'db.example.com',
          port: 5432,
          user: 'postgres',
          password: 'password',
          name: 'serverpod_test',
        ),
      );

      expect(poolManager.poolSettings.pipelineDepth, 8);
    },
  );
}

class _TestSerializationManager extends DatabaseSerializationManager {
  @override
  String getModuleName() => 'test';

  @override
  Table? getTableForType(Type t) => null;

  @override
  List<TableDefinition> getTargetTableDefinitions() => const [];
}

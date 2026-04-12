import 'dart:async';

import 'log_types.dart';
import 'logger.dart';

/// Runs [body] with a root [LogScope] installed in the Zone.
///
/// All logging within [body] (and any code it spawns) will use
/// [rootScope] as the default scope. The [logger] is available
/// for convenience but logging works via the Zone-stored scope
/// regardless of how the logger is accessed.
///
/// Typically called once at server startup:
/// ```dart
/// await runWithRootScope(
///   rootScope: LogScope.root('sw_server:$pid'),
///   logger: Logger(writerChain),
///   body: () => server.start(),
/// );
/// ```
Future<T> runWithRootScope<T>({
  required LogScope rootScope,
  required Logger logger,
  required FutureOr<T> Function() body,
}) async {
  return runZoned(
    body,
    zoneValues: {logScopeKey: rootScope},
  );
}

/// Runs [body] inside a child scope of the current Zone scope.
///
/// Used by serverpod to wrap session handlers, future calls, etc.
/// in their own scope. The parent is automatically the current
/// Zone scope.
Future<T> runInScope<T>({
  required LogScope scope,
  required FutureOr<T> Function() body,
}) async {
  return runZoned(
    body,
    zoneValues: {logScopeKey: scope},
  );
}

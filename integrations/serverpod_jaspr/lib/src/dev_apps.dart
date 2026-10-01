import 'dart:io';

import 'package:serverpod_shared/serverpod_shared.dart';

/// The apps `serverpod start` compiles, or null when the server runs outside
/// it.
final Map<String, JasprAppLocation>? devJasprApps = decodeJasprApps(
  Platform.environment[jasprAppsEnvironmentVariable],
);

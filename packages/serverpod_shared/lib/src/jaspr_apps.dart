import 'dart:convert';

/// The environment variable `serverpod start` sets to tell the server which
/// Jaspr apps it compiles, holding what [encodeJasprApps] writes.
const jasprAppsEnvironmentVariable = 'SERVERPOD_JASPR_APPS';

/// Where `serverpod start` keeps a Jaspr app.
class JasprAppLocation {
  /// The root of the app's package.
  final String packageDir;

  /// Where the runner writes the app's compiled browser code.
  final String outputDir;

  /// Creates the location of an app.
  const JasprAppLocation({required this.packageDir, required this.outputDir});

  @override
  bool operator ==(Object other) =>
      other is JasprAppLocation &&
      other.packageDir == packageDir &&
      other.outputDir == outputDir;

  @override
  int get hashCode => Object.hash(packageDir, outputDir);
}

/// The value of [jasprAppsEnvironmentVariable] for [apps], keyed by app id.
String encodeJasprApps(Map<String, JasprAppLocation> apps) => jsonEncode({
  for (final MapEntry(key: id, value: app) in apps.entries)
    id: {'packageDir': app.packageDir, 'outputDir': app.outputDir},
});

/// The apps in [value], a value of [jasprAppsEnvironmentVariable], or null
/// when the variable is unset.
Map<String, JasprAppLocation>? decodeJasprApps(String? value) {
  if (value == null || value.isEmpty) return null;
  final decoded = jsonDecode(value) as Map<String, dynamic>;
  return {
    for (final MapEntry(key: id, value: app) in decoded.entries)
      id: JasprAppLocation(
        packageDir: (app as Map<String, dynamic>)['packageDir'] as String,
        outputDir: app['outputDir'] as String,
      ),
  };
}

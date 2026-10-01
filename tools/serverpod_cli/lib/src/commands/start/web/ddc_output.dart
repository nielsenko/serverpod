import 'dart:convert';
import 'dart:typed_data';

/// One module from a frontend server `dartdevc` compile: a DDC library bundle
/// with its source map and debug metadata.
class DdcModule {
  /// The path of the module's JavaScript, relative to the app root, such as
  /// `packages/app/main.dart.lib.js`.
  final String path;
  final Uint8List code;
  final Uint8List sourceMap;
  final DdcModuleMetadata metadata;

  const DdcModule({
    required this.path,
    required this.code,
    required this.sourceMap,
    required this.metadata,
  });

  /// The path of the module's source map, relative to the app root.
  String get sourceMapPath => '$path.map';
}

/// The parts of DDC's module metadata that loading and reloading need.
class DdcModuleMetadata {
  /// The module name, which the DDC loader uses as the script id.
  final String name;

  /// The import URIs of the libraries compiled into the module, such as
  /// `package:app/main.dart`. The DDC embedder names libraries by these.
  final List<String> libraries;

  const DdcModuleMetadata({required this.name, required this.libraries});

  factory DdcModuleMetadata.fromJson(Map<String, Object?> json) {
    final libraries = json['libraries'] as List<Object?>;
    return DdcModuleMetadata(
      name: json['name'] as String,
      libraries: [
        for (final library in libraries.cast<Map<String, Object?>>())
          library['importUri'] as String,
      ],
    );
  }
}

/// Splits the concatenated output of a frontend server `dartdevc` compile
/// into modules.
///
/// The frontend server writes all modules' code, source maps and metadata
/// into one file each, plus a [manifest] that maps every module path to its
/// byte range in each file. Entries whose ranges do not fit the files are
/// skipped.
List<DdcModule> splitDdcOutput({
  required Uint8List code,
  required Uint8List sourceMaps,
  required Uint8List metadata,
  required Map<String, Object?> manifest,
}) {
  final modules = <DdcModule>[];
  for (final MapEntry(key: modulePath, :value) in manifest.entries) {
    final offsets = value as Map<String, Object?>;
    final codeRange = _range(offsets['code'], code);
    final sourceMapRange = _range(offsets['sourcemap'], sourceMaps);
    final metadataRange = _range(offsets['metadata'], metadata);
    if (codeRange == null || sourceMapRange == null || metadataRange == null) {
      continue;
    }
    modules.add(
      DdcModule(
        path: modulePath.startsWith('/') ? modulePath.substring(1) : modulePath,
        code: codeRange,
        sourceMap: sourceMapRange,
        metadata: DdcModuleMetadata.fromJson(
          jsonDecode(utf8.decode(metadataRange)) as Map<String, Object?>,
        ),
      ),
    );
  }
  return modules;
}

Uint8List? _range(Object? offsets, Uint8List bytes) {
  if (offsets is! List || offsets.length != 2) return null;
  final [start as int, end as int] = offsets;
  if (start < 0 || end > bytes.length || start > end) return null;
  return Uint8List.sublistView(bytes, start, end);
}

/// The modules one hot reload compile changed.
class HotReloadDelta {
  /// The generation the compile produced, counting hot reloads.
  final int generation;

  final List<DdcModule> modules;

  const HotReloadDelta(this.generation, this.modules);
}

/// The content of `reloaded_sources.json`: every hot reload delta since the
/// last restart, so a page can catch up from whichever generation it has.
///
/// [generation] is the latest generation, and [since] the generation of the
/// last restart. A page older than [since] has to load again. Each entry
/// names the file to load, relative to the app root, with its generation as
/// a query so the browser fetches it fresh, the module in it and the
/// libraries it defines.
String reloadedSourcesJson({
  required int generation,
  required int since,
  required Iterable<HotReloadDelta> deltas,
}) {
  return jsonEncode({
    'generation': generation,
    'since': since,
    'entries': [
      for (final delta in deltas)
        for (final module in delta.modules)
          {
            'generation': delta.generation,
            'src': '${module.path}?gen=${delta.generation}',
            'module': module.metadata.name,
            'libraries': module.metadata.libraries,
          },
    ],
  });
}

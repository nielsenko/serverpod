import 'dart:convert';
import 'dart:typed_data';

import 'package:serverpod_cli/src/commands/start/web/ddc_output.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Given the concatenated output of two modules with a manifest, '
    'when it is split, '
    'then each module gets its own code, source map and metadata.',
    () {
      final output = _concatenate([
        _module('/packages/app/main.dart.lib.js', 'package:app/main.dart'),
        _module('/packages/app/label.dart.lib.js', 'package:app/label.dart'),
      ]);

      final modules = splitDdcOutput(
        code: output.code,
        sourceMaps: output.sourceMaps,
        metadata: output.metadata,
        manifest: output.manifest,
      );

      expect(
        [
          for (final module in modules)
            (
              module.path,
              utf8.decode(module.code),
              utf8.decode(module.sourceMap),
              module.metadata.name,
              module.metadata.libraries.join(', '),
            ),
        ],
        [
          (
            'packages/app/main.dart.lib.js',
            'code of package:app/main.dart',
            'map of package:app/main.dart',
            'packages/app/main.dart',
            'package:app/main.dart',
          ),
          (
            'packages/app/label.dart.lib.js',
            'code of package:app/label.dart',
            'map of package:app/label.dart',
            'packages/app/label.dart',
            'package:app/label.dart',
          ),
        ],
      );
    },
  );

  test(
    'Given a manifest entry whose code range runs past the end of the code, '
    'when the output is split, '
    'then that entry is skipped and the others are kept.',
    () {
      final output = _concatenate([
        _module('/packages/app/main.dart.lib.js', 'package:app/main.dart'),
      ]);
      final manifest = {
        ...output.manifest,
        '/packages/app/broken.dart.lib.js': {
          'code': [0, output.code.length + 1],
          'sourcemap': [0, 1],
          'metadata': [0, 1],
        },
      };

      final modules = splitDdcOutput(
        code: output.code,
        sourceMaps: output.sourceMaps,
        metadata: output.metadata,
        manifest: manifest,
      );

      expect(modules.map((m) => m.path), ['packages/app/main.dart.lib.js']);
    },
  );

  test(
    'Given two hot reload deltas since a restart, '
    'when the reloaded sources are encoded, '
    'then each module is listed with its generation, its file with the '
    'generation as a query, its module and its libraries.',
    () {
      final json = reloadedSourcesJson(
        generation: 4,
        since: 2,
        deltas: [
          HotReloadDelta(3, [_ddcModule('label')]),
          HotReloadDelta(4, [_ddcModule('label'), _ddcModule('shape')]),
        ],
      );

      expect(jsonDecode(json), {
        'generation': 4,
        'since': 2,
        'entries': [
          _entry(3, 'label'),
          _entry(4, 'label'),
          _entry(4, 'shape'),
        ],
      });
    },
  );
}

DdcModule _ddcModule(String name) => DdcModule(
  path: 'packages/app/$name.dart.lib.js',
  code: Uint8List(0),
  sourceMap: Uint8List(0),
  metadata: DdcModuleMetadata(
    name: 'packages/app/$name.dart',
    libraries: ['package:app/$name.dart'],
  ),
);

Map<String, Object> _entry(int generation, String name) => {
  'generation': generation,
  'src': 'packages/app/$name.dart.lib.js?gen=$generation',
  'module': 'packages/app/$name.dart',
  'libraries': ['package:app/$name.dart'],
};

typedef _Module = ({String path, String library});

_Module _module(String path, String library) => (path: path, library: library);

/// Lays out [modules] the way the frontend server writes them: one file each
/// for code, source maps and metadata, and a manifest of byte ranges.
({
  Uint8List code,
  Uint8List sourceMaps,
  Uint8List metadata,
  Map<String, Object?> manifest,
})
_concatenate(List<_Module> modules) {
  final code = BytesBuilder();
  final sourceMaps = BytesBuilder();
  final metadata = BytesBuilder();
  final manifest = <String, Object?>{};

  List<int> append(BytesBuilder builder, String content) {
    final start = builder.length;
    builder.add(utf8.encode(content));
    return [start, builder.length];
  }

  for (final module in modules) {
    final name = module.path.substring(1).replaceAll('.lib.js', '');
    manifest[module.path] = {
      'code': append(code, 'code of ${module.library}'),
      'sourcemap': append(sourceMaps, 'map of ${module.library}'),
      'metadata': append(
        metadata,
        jsonEncode({
          'name': name,
          'libraries': [
            {'name': 'lib', 'importUri': module.library, 'partUris': []},
          ],
        }),
      ),
    };
  }
  return (
    code: code.toBytes(),
    sourceMaps: sourceMaps.toBytes(),
    metadata: metadata.toBytes(),
    manifest: manifest,
  );
}

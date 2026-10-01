import 'package:serverpod_shared/serverpod_shared.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Given Jaspr app locations, '
    'when they are encoded and decoded again, '
    'then the same locations come back under the same ids.',
    () {
      const apps = {
        'website': JasprAppLocation(
          packageDir: '/projects/demo/demo_web',
          outputDir:
              '/projects/demo/demo_server/.dart_tool/serverpod/jaspr/website',
        ),
        'admin': JasprAppLocation(
          packageDir: '/projects/demo/demo_admin',
          outputDir:
              '/projects/demo/demo_server/.dart_tool/serverpod/jaspr/admin',
        ),
      };

      expect(decodeJasprApps(encodeJasprApps(apps)), apps);
    },
  );

  test(
    'Given no value for the environment variable, '
    'when it is decoded, '
    'then the result is null.',
    () {
      expect(decodeJasprApps(null), isNull);
      expect(decodeJasprApps(''), isNull);
    },
  );
}

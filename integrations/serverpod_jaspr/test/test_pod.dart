import 'package:serverpod/serverpod.dart';
import 'package:serverpod/src/generated/protocol.dart' as internal;

class _EmptyEndpoints extends EndpointDispatch {
  @override
  void initializeEndpoints(Server server) {}
}

final _portZeroConfig = ServerConfig(
  port: 0,
  publicScheme: 'http',
  publicHost: 'localhost',
  publicPort: 0,
);

/// A pod with no endpoints, on free ports.
Serverpod createPod() => Serverpod(
  [],
  internal.Protocol(),
  _EmptyEndpoints(),
  config: ServerpodConfig(
    apiServer: _portZeroConfig,
    webServer: _portZeroConfig,
  ),
);

/// Starts [pod] with [route] added at [path] and returns its web server port.
Future<int> startPod(Serverpod pod, Route route, String path) async {
  pod.webServer.addRoute(route, path);
  await pod.start();
  return pod.webServer.port!;
}

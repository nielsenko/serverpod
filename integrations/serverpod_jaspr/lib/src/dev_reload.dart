import 'dart:convert';
import 'dart:developer';

import 'sse_endpoint.dart';

/// The service extension `serverpod start` calls to reload the browsers that
/// show a Jaspr app, once their code is compiled.
///
/// Parameters, all optional: `hotReload` and `restart`, `'true'` or
/// `'false'`, and `generations`, a JSON object with the generation of each
/// app's browser code by app id. The result reports how many clients were
/// asked to reload.
const jasprReloadClientsExtension = 'ext.serverpod.jaspr.reloadClients';

/// The path below a Jaspr app's mount where its pages listen for reloads.
///
/// Each event is a JSON object with `hotReload` and `restart` as booleans.
const devReloadPath = r'$serverpodReload';

/// The pages of every Jaspr app that listen for reloads.
final devReloadEvents = SseEndpoint();

/// The generation of each app's browser code by app id, as the runner last
/// reported it. Empty until the first report.
Map<String, int> get devGenerations => _devGenerations;
var _devGenerations = <String, int>{};

// A hot reload keeps this flag and the registration alike, and registering
// an extension twice throws.
var _registered = false;

/// Registers [jasprReloadClientsExtension] once per isolate.
void registerJasprDevReload() {
  if (_registered) return;
  _registered = true;
  registerExtension(jasprReloadClientsExtension, (method, params) async {
    if (params['generations'] case final json?) {
      _devGenerations = {
        for (final MapEntry(:key, :value)
            in (jsonDecode(json) as Map<String, dynamic>).entries)
          key: value as int,
      };
    }
    final clients = devReloadEvents.listeners;
    devReloadEvents.send(
      jsonEncode({
        'hotReload': params['hotReload'] == 'true',
        'restart': params['restart'] == 'true',
      }),
    );
    return ServiceExtensionResponse.result(jsonEncode({'clients': clients}));
  });
}

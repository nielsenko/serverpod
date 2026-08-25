import 'dart:developer' as developer;

/// The VM service extension event the pod posts once its listeners are bound.
///
/// The runner cannot know the addresses the pod resolved: with a configured
/// port of 0 they are only decided at bind time. It already subscribes to the
/// pod's `Extension` events for logs, so this rides the same channel rather
/// than adding a second one, and lands in the runner manifest that `serverpod
/// status` prints and pod clients read.
///
/// In production, where the VM service is disabled, [developer.postEvent] is a
/// no-op.
const serverpodAddressesEvent = 'ext.serverpod.addresses';

/// Posts the addresses the pod's listeners actually resolved to.
///
/// Each is the URL a client should use, built from the public scheme, host and
/// port, which follow the bind port when it was ephemeral.
void postServerpodAddresses({
  required String? api,
  required String? insights,
  required String? web,
}) {
  developer.postEvent(serverpodAddressesEvent, {
    'api': ?api,
    'insights': ?insights,
    'web': ?web,
  });
}

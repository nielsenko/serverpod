/// Which legacy `serverpod_auth` endpoints the bridge serves, and how.
///
/// Kept out of the package's public surface: this is the routing table behind
/// `enableLegacyClientSupport`, not something applications configure directly.
library;

const _legacyToBridgeEndpoint = <String, String>{
  'serverpod_auth.email': 'serverpod_auth_bridge.legacyEmail',
  'serverpod_auth.status': 'serverpod_auth_bridge.legacyStatus',
  'serverpod_auth.user': 'serverpod_auth_bridge.legacyUser',
};

/// The legacy `serverpod_auth` endpoints that have no bridge equivalent.
///
/// A server that depends on `serverpod_auth_migration_server` mounts the whole
/// legacy endpoint surface, including the sign-in endpoints of providers the
/// bridge does not forward. Those endpoints authenticate against the legacy tables
/// and hand out legacy session keys, so on a migrated deployment they are a
/// second way in that bypasses the new stack entirely - and they carry the
/// weaknesses the legacy module was retired for.
const _unbridgedLegacyEndpoints = <String>{
  'serverpod_auth.admin',
  'serverpod_auth.apple',
  'serverpod_auth.firebase',
  'serverpod_auth.google',
};

/// What legacy client support does with a request for a legacy endpoint.
sealed class LegacyEndpointDisposition {
  const LegacyEndpointDisposition();
}

/// The request is rewritten onto [bridgeEndpoint].
final class ForwardToBridge extends LegacyEndpointDisposition {
  /// The bridge endpoint serving this legacy endpoint.
  final String bridgeEndpoint;

  /// Forwards to [bridgeEndpoint].
  const ForwardToBridge(this.bridgeEndpoint);
}

/// The request is refused, as if the endpoint were not mounted.
final class BlockLegacyEndpoint extends LegacyEndpointDisposition {
  /// Blocks the request.
  const BlockLegacyEndpoint();
}

/// The request is none of the bridge's business and is passed through.
final class PassThrough extends LegacyEndpointDisposition {
  /// Passes the request on unchanged.
  const PassThrough();
}

/// Decides what happens to a request addressed to [endpoint].
LegacyEndpointDisposition dispositionFor(
  final String endpoint, {
  required final bool blockUnbridgedAuthEndpoints,
}) {
  final forwardedEndpoint = _legacyToBridgeEndpoint[endpoint];
  if (forwardedEndpoint != null) return ForwardToBridge(forwardedEndpoint);

  if (blockUnbridgedAuthEndpoints &&
      _unbridgedLegacyEndpoints.contains(endpoint)) {
    return const BlockLegacyEndpoint();
  }

  return const PassThrough();
}

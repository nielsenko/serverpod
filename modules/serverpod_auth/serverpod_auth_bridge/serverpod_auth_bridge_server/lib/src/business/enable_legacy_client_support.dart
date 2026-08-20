import 'package:serverpod/serverpod.dart';

import 'legacy_endpoint_disposition.dart';

/// Enables request-level forwarding from selected legacy `serverpod_auth`
/// endpoints to the bridge's `serverpod_auth_bridge.legacy*` endpoints.
extension LegacyClientSupport on Serverpod {
  /// Enables support for legacy `serverpod_auth` email and user/session routes.
  ///
  /// The legacy `email`, `status` and `user` endpoints are forwarded to their
  /// bridge equivalents, so existing clients keep working against the new
  /// stack.
  ///
  /// The legacy `admin`, `apple`, `firebase` and `google` endpoints have no
  /// bridge equivalent, but a server that depends on
  /// `serverpod_auth_migration_server` mounts them all the same, where they
  /// remain a way to obtain a legacy session that the new stack knows nothing
  /// about. They are refused by default; pass
  /// `blockUnbridgedAuthEndpoints: false` to keep serving them from the legacy
  /// module while a migration is still in progress.
  void enableLegacyClientSupport({
    final bool blockUnbridgedAuthEndpoints = true,
  }) {
    server.addMiddleware((final next) {
      return (final request) {
        final pathSegments = request.url.pathSegments;
        if (pathSegments.isEmpty) {
          return next(request);
        }

        final disposition = dispositionFor(
          pathSegments.first,
          blockUnbridgedAuthEndpoints: blockUnbridgedAuthEndpoints,
        );

        switch (disposition) {
          case PassThrough():
            return next(request);

          case BlockLegacyEndpoint():
            return Response.notFound();

          case ForwardToBridge(:final bridgeEndpoint):
            final forwardedRequest = request.copyWith(
              url: request.url.replace(
                pathSegments: [bridgeEndpoint, ...pathSegments.skip(1)],
              ),
            );

            return request.forwardTo(forwardedRequest);
        }
      };
    });
  }
}

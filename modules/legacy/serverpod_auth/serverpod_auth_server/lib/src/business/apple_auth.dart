import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:jose/jose.dart';
import 'package:meta/meta.dart';

import 'config.dart';

/// The issuer Apple stamps on every Sign in with Apple identity token.
const _appleIssuer = 'https://appleid.apple.com';

/// Where Apple publishes the public keys its identity tokens are signed with.
final _appleKeysUrl = Uri.parse('https://appleid.apple.com/auth/keys');

/// How long a fetched key set is served from cache before being refreshed.
const _keyCacheLifetime = Duration(hours: 24);

/// How long to wait before fetching again after a failed fetch, so that an
/// outage at Apple is not amplified into a request per sign in.
const _keyRefetchBackoff = Duration(minutes: 1);

/// The default for [AppleAuth.minRefetchInterval].
const _defaultMinRefetchInterval = Duration(minutes: 5);

/// The verified claims of a Sign in with Apple identity token.
class AppleIdentityToken {
  /// Apple's stable identifier for the user. Unique per developer team, so it
  /// only identifies the user within the apps of a single team.
  final String subject;

  /// The email address the token carries, if any. Lower-cased.
  ///
  /// This is either the user's real address or a per-app private relay
  /// address, depending on what the user shared at authorization time.
  final String? email;

  /// Whether Apple vouches for [email] being verified.
  final bool isEmailVerified;

  /// Whether [email] is one of Apple's private relay addresses.
  final bool isPrivateEmail;

  /// Creates verified identity token claims.
  AppleIdentityToken({
    required this.subject,
    required this.email,
    required this.isEmailVerified,
    required this.isPrivateEmail,
  });
}

/// Thrown when a Sign in with Apple identity token cannot be verified.
class AppleIdentityTokenException implements Exception {
  /// Description of why verification failed.
  final String message;

  /// Creates a verification failure with the given [message].
  AppleIdentityTokenException(this.message);

  @override
  String toString() => 'AppleIdentityTokenException: $message';
}

/// Convenience methods for handling authentication with Apple.
class AppleAuth {
  static _AppleKeySet? _publicKeys;
  static DateTime? _lastFetchFailedAt;

  /// The shortest interval between two fetches of Apple's key set.
  ///
  /// A key id the cache does not know triggers a refresh, and that key id
  /// comes out of the token, so without a floor a stream of tokens naming
  /// nonexistent keys would turn into one request to Apple each. Rotations are
  /// rare and Apple publishes a new key well before signing with it, so
  /// waiting costs nothing.
  @visibleForTesting
  static Duration minRefetchInterval = _defaultMinRefetchInterval;

  /// Verifies a Sign in with Apple identity token and returns its claims.
  ///
  /// The signature is checked against Apple's published keys, and the `iss`,
  /// `aud` and `exp`/`iat` claims are all validated. Apple signs the tokens of
  /// every developer team with the same set of keys, so a valid signature only
  /// proves the token came from Apple - the `aud` check against
  /// [AuthConfig.appleClientIds] is what proves it was minted for this
  /// application rather than replayed from someone else's.
  ///
  /// Throws an [AppleIdentityTokenException] if the token cannot be verified.
  static Future<AppleIdentityToken> verifyIdentityToken(
    String identityToken,
  ) async {
    var clientIds = AuthConfig.current.appleClientIds;
    if (clientIds.isEmpty) {
      throw AppleIdentityTokenException(
        'Sign in with Apple is not configured. Set `appleClientIds` on '
        '`AuthConfig` to the client identifiers (app bundle ids and services '
        'ids) this server accepts identity tokens for. Without it an identity '
        'token minted for any other Apple developer team would be accepted.',
      );
    }

    JsonWebSignature jws;
    try {
      jws = JsonWebSignature.fromCompactSerialization(identityToken);
    } catch (e) {
      throw AppleIdentityTokenException('Malformed identity token: $e');
    }

    if (!await _verifySignature(jws)) {
      throw AppleIdentityTokenException('Identity token signature is invalid');
    }

    // Named "unverified" because the type carries no proof on its own; the
    // signature over these exact bytes was checked just above.
    var claims = jws.unverifiedPayload.jsonContent;
    if (claims is! Map<String, dynamic>) {
      throw AppleIdentityTokenException('Identity token payload is not a map');
    }

    _validateClaims(claims, clientIds);

    var email = (claims['email'] as String?)?.toLowerCase();

    return AppleIdentityToken(
      subject: claims['sub'] as String,
      email: email,
      isEmailVerified:
          email != null && _appleBool(claims['email_verified']) == true,
      isPrivateEmail: _appleBool(claims['is_private_email']) == true,
    );
  }

  static void _validateClaims(
    Map<String, dynamic> claims,
    Set<String> clientIds,
  ) {
    if (claims['iss'] != _appleIssuer) {
      throw AppleIdentityTokenException(
        'Identity token was issued by "${claims['iss']}", expected '
        '"$_appleIssuer"',
      );
    }

    var audience = claims['aud'];
    var audiences = switch (audience) {
      String() => [audience],
      List() => audience.whereType<String>().toList(),
      _ => const <String>[],
    };
    if (!audiences.any(clientIds.contains)) {
      throw AppleIdentityTokenException(
        'Identity token audience $audiences is not one of the configured '
        'Apple client ids. The token was minted for a different application.',
      );
    }

    var subject = claims['sub'];
    if (subject is! String || subject.isEmpty) {
      throw AppleIdentityTokenException('Identity token has no subject');
    }

    var tolerance = AuthConfig.current.appleIdentityTokenClockSkewTolerance;
    var now = DateTime.now().toUtc();

    var expiresAt = _timestamp(claims['exp']);
    if (expiresAt == null) {
      throw AppleIdentityTokenException('Identity token has no expiry');
    }
    if (now.isAfter(expiresAt.add(tolerance))) {
      throw AppleIdentityTokenException(
        'Identity token expired at $expiresAt',
      );
    }

    var issuedAt = _timestamp(claims['iat']);
    if (issuedAt != null && issuedAt.subtract(tolerance).isAfter(now)) {
      throw AppleIdentityTokenException(
        'Identity token was issued in the future, at $issuedAt',
      );
    }
  }

  /// Verifies [jws] against Apple's published keys.
  ///
  /// Apple rotates its signing keys, so a token whose `kid` is absent from the
  /// cached set is not necessarily forged - the set may simply be stale. Fetch
  /// once more before rejecting, and let a successful fetch reset the cache.
  static Future<bool> _verifySignature(JsonWebSignature jws) async {
    var keyId = jws.commonHeader.keyId;

    var keys = await _loadPublicKeys();
    if (await _verifyAgainst(jws, keys, keyId)) return true;

    // The cache already holds the key the token names, so the signature is
    // simply bad. Re-fetching would let anyone drive traffic at Apple.
    if (keyId != null && keys.containsKeyId(keyId)) return false;
    if (keys.wasFetchedWithin(minRefetchInterval)) return false;

    var refreshed = await _loadPublicKeys(forceRefresh: true);
    if (identical(refreshed, keys)) return false;

    return _verifyAgainst(jws, refreshed, keyId);
  }

  static Future<bool> _verifyAgainst(
    JsonWebSignature jws,
    _AppleKeySet keys,
    String? keyId,
  ) async {
    for (var publicKey in keys.matching(keyId)) {
      var keyStore = JsonWebKeyStore()..addKey(JsonWebKey.fromJson(publicKey));
      if (await jws.verify(keyStore)) return true;
    }

    return false;
  }

  static Future<_AppleKeySet> _loadPublicKeys({
    bool forceRefresh = false,
  }) async {
    var publicKeys = _publicKeys;
    if (publicKeys != null && !forceRefresh && !publicKeys.isStale) {
      return publicKeys;
    }

    var lastFailure = _lastFetchFailedAt;
    if (publicKeys != null &&
        lastFailure != null &&
        DateTime.now().toUtc().difference(lastFailure) < _keyRefetchBackoff) {
      return publicKeys;
    }

    try {
      var fetched = await _fetchPublicKeys();
      _lastFetchFailedAt = null;
      return _publicKeys = fetched;
    } on AppleIdentityTokenException {
      _lastFetchFailedAt = DateTime.now().toUtc();

      // A key set that verified tokens a moment ago still verifies the ones
      // signed with those keys, so an outage at Apple should not take Sign in
      // with Apple down with it.
      if (publicKeys != null) return publicKeys;
      rethrow;
    }
  }

  static Future<_AppleKeySet> _fetchPublicKeys() async {
    http.Response response;
    try {
      response = await http.get(_appleKeysUrl);
    } catch (e) {
      throw AppleIdentityTokenException(
        'Failed to fetch Apple public keys: $e',
      );
    }

    if (response.statusCode != 200) {
      throw AppleIdentityTokenException(
        'Failed to fetch Apple public keys: HTTP ${response.statusCode}',
      );
    }

    try {
      var data = jsonDecode(response.body) as Map;
      return _AppleKeySet([
        for (Map key in data['keys'] as List) key.cast<String, dynamic>(),
      ]);
    } catch (e) {
      throw AppleIdentityTokenException(
        'Failed to parse Apple public keys: $e',
      );
    }
  }

  /// Apple sends the boolean claims of an identity token as either a JSON
  /// boolean or the strings `"true"`/`"false"`, depending on the flow.
  static bool? _appleBool(Object? value) => switch (value) {
    bool() => value,
    'true' => true,
    'false' => false,
    _ => null,
  };

  static DateTime? _timestamp(Object? value) {
    var seconds = switch (value) {
      int() => value,
      String() => int.tryParse(value),
      _ => null,
    };

    return seconds == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
  }

  /// Drops the cached Apple public keys.
  @visibleForTesting
  static void resetPublicKeyCache() {
    _publicKeys = null;
    _lastFetchFailedAt = null;
    minRefetchInterval = _defaultMinRefetchInterval;
  }
}

/// A snapshot of the keys Apple published, and when it was taken.
class _AppleKeySet {
  final List<Map<String, dynamic>> keys;
  final DateTime fetchedAt;

  _AppleKeySet(this.keys) : fetchedAt = DateTime.now().toUtc();

  bool get isStale =>
      DateTime.now().toUtc().difference(fetchedAt) > _keyCacheLifetime;

  bool wasFetchedWithin(final Duration duration) =>
      DateTime.now().toUtc().difference(fetchedAt) < duration;

  bool containsKeyId(String keyId) =>
      keys.any((final key) => key['kid'] == keyId);

  /// The keys worth trying for [keyId], most likely first.
  ///
  /// A token names the key it was signed with, but the claim is unverified
  /// until a signature checks out, so every key stays a candidate.
  Iterable<Map<String, dynamic>> matching(String? keyId) {
    if (keyId == null) return keys;

    return [
      ...keys.where((final key) => key['kid'] == keyId),
      ...keys.where((final key) => key['kid'] != keyId),
    ];
  }
}

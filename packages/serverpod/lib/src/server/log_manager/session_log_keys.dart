/// Metadata keys used by [SessionLogManager] (and any future producer of
/// session-shaped log scopes/entries) so consumers like `DatabaseLogWriter`
/// can recognise sessions without coupling to producer internals.
///
/// All keys are namespaced with `serverpod.` to avoid collisions with
/// arbitrary user-supplied metadata.
library;

/// Keys set on `LogScope.metadata` for scopes that represent a serverpod
/// [Session].
abstract final class SessionScopeKeys {
  /// String discriminating the session subtype: 'method', 'methodStream',
  /// 'stream', 'web', 'futureCall', 'internal'.
  static const sessionType = 'serverpod.sessionType';

  /// The session's [Session.sessionId] as a string.
  static const sessionId = 'serverpod.sessionId';

  /// Endpoint name (when applicable).
  static const endpoint = 'serverpod.endpoint';

  /// Method name on the endpoint (when applicable).
  static const method = 'serverpod.method';

  /// Server id of the serverpod instance handling the session.
  static const serverId = 'serverpod.serverId';

  /// Future-call name (only set for [FutureCallSession]).
  static const futureCallName = 'serverpod.futureCallName';

  /// Authenticated user identifier. Set late (typically at session close)
  /// since authentication may complete after the session opens.
  static const authenticatedUserId = 'serverpod.authenticatedUserId';
}

/// Keys set on `LogEntry.metadata` to discriminate log/query/message entries
/// produced by [SessionLogManager] and to carry their type-specific fields.
abstract final class SessionEntryKeys {
  /// Discriminator for the entry kind: 'log', 'query', 'message'.
  static const type = 'serverpod.entryType';

  /// 'query' entry: query duration in seconds.
  static const queryDuration = 'serverpod.queryDuration';

  /// 'query' entry: number of rows affected, if known.
  static const queryNumRows = 'serverpod.queryNumRows';

  /// 'query' entry: whether the query exceeded `slowQueryDuration`.
  static const querySlow = 'serverpod.querySlow';

  /// 'message' entry: endpoint that received the message.
  static const messageEndpoint = 'serverpod.messageEndpoint';

  /// 'message' entry: message class name.
  static const messageName = 'serverpod.messageName';

  /// 'message' entry: per-session message id.
  static const messageId = 'serverpod.messageId';

  /// 'message' entry: handler duration in seconds.
  static const messageDuration = 'serverpod.messageDuration';

  /// 'message' entry: whether the handler exceeded `slowSessionDuration`.
  static const messageSlow = 'serverpod.messageSlow';
}

/// Values used with [SessionScopeKeys.sessionType].
abstract final class SessionTypeValues {
  /// A method-call session (one-shot endpoint invocation).
  static const method = 'method';

  /// A streaming method-call session (server-streaming method).
  static const methodStream = 'methodStream';

  /// A long-lived streaming session (websocket endpoint).
  static const stream = 'stream';

  /// A web-server session (handling an HTTP request).
  static const web = 'web';

  /// A scheduled future-call session.
  static const futureCall = 'futureCall';

  /// An internal serverpod session (no client).
  static const internal = 'internal';

  /// Fallback for sessions of an unrecognised subtype.
  static const unknown = 'unknown';
}

/// Values used with [SessionEntryKeys.type].
abstract final class SessionEntryTypeValues {
  /// A free-form log message entry.
  static const log = 'log';

  /// A database query entry.
  static const query = 'query';

  /// A streaming-message handler entry.
  static const message = 'message';
}

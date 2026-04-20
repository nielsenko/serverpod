# Design: Unified Logging

This document describes the redesign of serverpod's logging system to consolidate all output through a single `LogWriter` abstraction, enabling structured log delivery to the CLI's TUI via the VM service.

## Problem

The server historically had three separate output paths:

1. **Session logs** - structured, per-session, routed through `LogWriter` implementations.
2. **Lifecycle messages** - direct `stdout.writeln()` calls for startup banners, shutdown notices, and similar.
3. **Ad-hoc stderr/stdout** - `stderr.writeln()` / `stdout.writeln()` / `print()` sprinkled across the framework for warnings, errors, and informational messages.

Only the first category was structured; the other two bypassed the writer chain entirely and never reached the TUI's structured log view.

The TUI can only display messages that arrive via the VM service extension protocol (`ext.serverpod.log`). Direct stderr/stdout writes go to the "Raw Output" tab, which is hidden by default and not actively monitored.

## Goals

- All server framework messages flow through a single logging abstraction.
- The CLI receives all messages as structured events (level, message, scope).
- Framework and session logging are first-class and typed - each with its own entry point (`log` vs `sessionLog`) - but share the same core primitives where that makes sense (`LogScope`, `LogLevel`, writer chain pattern).
- The generic types live in a shared package and carry no serverpod-specific semantics. Session-specific concepts (sessionId, endpoint, query duration, …) are typed fields on session-specific records, not stringly-typed metadata on generic entries.
- No serverpod-specific types (generated `TableRow` classes) in the logging interface.

## Implementation status

- Generic types (`LogLevel`, `LogScope`, `LogEntry`, `LogWriter`), the `Log` class, and shared writers live in `serverpod_shared/lib/src/log/`.
- `Serverpod` exposes two singletons: `log` (framework) and `sessionLog` (session), each backed by its own writer chain. Session events flow as typed `SessionOpen` / `SessionEntry` / `SessionClose` records, not as generic `LogEntry` values with metadata.
- The CLI bridges `cli_tools.Logger` to `Log` via `ServerpodCliLogger`.
- `DatabaseLogWriter`, `SessionTextLogWriter`, and `SessionJsonLogWriter` persist / echo session events; `VmServiceSessionLogWriter` surfaces them to the CLI on the same `ext.serverpod.log` wire channel as framework events.
- Cross-chain correlation is **not yet wired**: session events go through `sessionLog` correctly, but framework `log.info(...)` calls made from inside an endpoint body have no link back to the enclosing session. They resolve to the synthetic root `LogScope` on the framework chain, so consumers see them as unrelated to the session handling the request.

## Design

### Core types

Generic, framework-agnostic. In `packages/serverpod_shared/lib/src/log/log_types.dart`.

```dart
class LogScope {
  final String id;
  final String label;
  final DateTime startTime;
  final LogScope? parent;
  final Map<String, Object?>? metadata;

  factory LogScope.root(String label);
  LogScope child({required String id, required String label, Map<String, Object?>? metadata});
}

class LogEntry {
  final DateTime time;
  final LogLevel level;
  final String message;
  final LogScope scope;
  final Object? error;
  final StackTrace? stackTrace;
  final Map<String, Object?>? metadata;
}

abstract class LogWriter {
  Future<void> log(LogEntry entry);
  Future<void> openScope(LogScope scope);
  Future<void> closeScope(
    LogScope scope, {
    required bool success,
    required Duration duration,
    Object? error,
    StackTrace? stackTrace,
  });
  Future<void> close() async {}
}
```

### Log

`Log` in `packages/serverpod_shared/lib/src/log/log.dart` is the user-facing API. Named `Log` (not `Logger`) to avoid clashing with `cli_tools.Logger`.

```dart
class Log {
  Log(LogWriter writer, {LogLevel logLevel = LogLevel.info});

  LogLevel logLevel;

  LogScope get currentScope; // from Zone, fallback to synthetic root

  void call(LogLevel level, LogEntryFactory factory);
  Future<void> flush();
  Future<void> close();
}
```

Each call appends onto a rolling internal Future so writes serialize in invocation order. `flush()` awaits that tail; `close()` does the same and blocks further dispatches. Writer errors are swallowed - logging is best-effort.

Convenience methods (`debug`, `info`, `warning`, `error`, `isDebugEnabled`) are on `LogConvenience`. Scope management is on `LogScoping`.

### Scopes

Every log entry belongs to a scope. Scopes form a tree rooted at a process-level root scope.

The current scope is read from the current `Zone` via a library-private symbol `_logScopeKey`, with a synthetic `LogScope.root('unknown')` as fallback. Scope propagation is opt-in: callers wrap their code in `log.progress(...)` - or any other `runZoned` that sets `_logScopeKey` - for nested log calls to inherit the scope.

```dart
extension LogScoping on Log {
  Future<T> progress<T>(
    String label,
    FutureOr<T> Function() runner, {
    Map<String, Object?>? metadata,
    bool Function(T result)? isSuccess,
  });
}
```

`progress` opens a child of the current scope, runs `runner` inside `runZoned(..., zoneValues: {_logScopeKey: scope})`, and closes the scope when done. The success signal is:

- If `runner` throws -> `success: false`.
- Else if `isSuccess` is supplied -> its return value.
- Else if `T` is `bool` -> the return value directly.
- Otherwise -> `true`.

There is no separate `openScope()` / `ScopedLog` API - all scope creation goes through `progress`.

### Session-side types

Live in `packages/serverpod/lib/src/server/log_manager/session_log.dart`. Kept in the `serverpod` package (not promoted to `serverpod_shared`) because they carry serverpod-specific concepts (sessions).

```dart
enum SessionKind { method, methodStream, stream, web, futureCall, internal, unknown }
enum SessionEntryKind { log, query, message }

class SessionOpen {
  final String sessionId;
  final SessionKind kind;
  final String label;
  final DateTime startTime;
  final String serverId;
  final String? endpoint;
  final String? method;
  final String? futureCallName;
}

class SessionClose {
  final String sessionId;
  final Duration duration;
  final bool success;
  final bool slow;
  final int numQueries;
  final String? authenticatedUserId;
  final Object? error;
  final StackTrace? stackTrace;
}

sealed class SessionEntry { /* sessionId, order, time, messageId */ }
class SessionLogEntry extends SessionEntry { /* level, message, error, stackTrace */ }
class SessionQueryEntry extends SessionEntry { /* query, duration, slow, numRowsAffected, error, stackTrace */ }
class SessionMessageEntry extends SessionEntry { /* endpoint, messageName, duration, slow, error, stackTrace */ }

abstract class SessionLogWriter {
  Future<void> open(SessionOpen event);
  Future<void> record(SessionEntry entry);
  Future<void> close(SessionClose event);
  Future<void> dispose() async {}
}

class MultiSessionLogWriter extends SessionLogWriter { /* fan-out, add/remove */ }

class SessionLog {
  SessionLog(SessionLogWriter writer);
  void open(SessionOpen event);
  void record(SessionEntry entry);
  void close(SessionClose event);
  Future<void> flush();
  Future<void> shutdown();
}
```

### Why two chains (framework / session)

Serverpod exposes two logger singletons: `log` (framework) and `sessionLog` (session). Each is backed by its own writer chain. The split is deliberate.

A tempting alternative is a **single generic chain** where session-specific context travels as a `Map<String, Object?>` on `LogEntry` / `LogScope`, and writers cast-out-by-key to reach the fields they need (e.g. `scope.metadata[sessionType]`, `entry.metadata[queryDuration]`). That was the earlier shape of this design. Two problems surfaced:

- **Stringly-typed session data.** Consumers stringified everything on the way in and destructured on the way out. A `Map<String, SessionScopeKeys.*>` vocabulary grew alongside the writers to keep the keys consistent - an entire file of string constants (`SessionScopeKeys`, `SessionEntryKeys`, `SessionTypeValues`, `SessionEntryTypeValues`) that the current design deletes. Every writer effectively re-implemented a typed schema on top of untyped metadata.
- **Filter wrappers to undo cross-contamination.** Because every writer saw every event, the framework-terminal writer had to be wrapped in a `NonSessionLogWriter` that dropped session-tagged events, and the session writers each re-implemented an "only-if-session-tagged" gate. Removing the wrapper doubled every session entry on the framework terminal. The wrapper also deleted.

Alternatives considered and rejected for this refactor:

1. **Add a channel discriminator to the generic `LogWriter` interface** (e.g. a required `channel` field on `LogEntry` / `LogScope`). Leaks serverpod-specific semantics - what counts as a "session" - into `serverpod_shared`, which wants to stay usable as a generic logging library by other projects.
2. **Shared `VmServiceLogWriter` as the only cross-cutting sink, keep everything else unified on one chain.** Doesn't address the stringly-typed metadata problem; sessions still round-trip through `Map<String, Object?>`.

The two-chain design keeps `serverpod_shared` neutral (the generic types know nothing about sessions), while session data stays typed end-to-end inside the `serverpod` package. `VmServiceLogWriter` and its session-aware sibling `VmServiceSessionLogWriter` are two small classes - the overhead of maintaining them is dwarfed by what was deleted from both sides.

### Writer implementations

Writers live in three tiers:

- **Shared** (`serverpod_shared`) - framework-agnostic. Operate on `LogEntry` / `LogScope` values.
- **Server** (`serverpod`) - implement either `LogWriter` (framework chain) or `SessionLogWriter` (session chain). No writer implements both.
- **CLI** (`serverpod_cli`) - consumed by the serverpod CLI. `StdOutLogWriter` is the default writer for every command (`generate`, `create-migration`, etc.); `TuiLogWriter` is installed in place of it when `serverpod start --watch` runs in TUI mode.

#### Shared

**`SpinnerLogWriter`** - base class that manages braille progress spinners for terminal output. Handles the scope stack, timer animation, and clear-line/redraw lifecycle. Subclasses override `writeLogLine` and the spinner/completion formatters.

**`TextLogWriter`** - extends `SpinnerLogWriter`. Writes formatted text with ANSI level prefixes (`DEBUG:`, `WARNING:`, `ERROR:`) to stdout/stderr.

**`IsolatedLogWriter`** - wraps any `LogWriter` in a dedicated isolate via `IsolatedObject`. The writer factory runs on the isolate so timer-driven spinner animations keep updating even when the calling isolate is blocked.

**`MultiLogWriter`** / **`MultiSessionLogWriter`** - fan out to a mutable list of child writers. Support `add` / `remove` so the chain can be reconfigured after construction (used by the server's two-phase bootstrap; see "Writer chain (server)" below).

#### Server - framework chain (`LogWriter`)

**`VmServiceLogWriter`** - posts framework events via `developer.postEvent('ext.serverpod.log', ...)`:

- `log(entry)` -> `{type: 'log', level, message, scopeId, ...}`
- `openScope(scope)` -> `{type: 'scope_start', id, label, parentId, ...}`
- `closeScope(scope)` -> `{type: 'scope_end', id, success, duration, ...}`

Available to any VM-service client that subscribes to the `Extension` stream. The CLI's TUI mode is the current consumer.

#### Server - session chain (`SessionLogWriter`)

**`SessionTextLogWriter`** - emits session events as aligned columnar text (TIME / ID / TYPE / CONTEXT / DETAILS) directly to stdout (stderr for errors). Renamed from the previous `SessionTextStdOutLogWriter`; wire format unchanged.

**`SessionJsonLogWriter`** - emits session events as single-line JSON to stdout (stderr for errors). Every session opens and closes with a `protocol.SessionLogEntry` row; log/query/message entries emit `protocol.LogEntry` / `QueryLogEntry` / `MessageLogEntry` rows keyed by a synthetic per-session `sessionLogId`. Renamed from `JsonStdOutLogWriter`.

**`DatabaseLogWriter`** - persists typed session events to `serverpod_session_log` / `serverpod_log` / `serverpod_query_log` / `serverpod_message_log`. Consumes the typed records directly, so the generated `TableRow` classes stay internal to this writer. The writer is created before the database is up and attaches its internal `Session` later via `attach(session)`; before that it's a no-op.

**`VmServiceSessionLogWriter`** - session counterpart of `VmServiceLogWriter`. Emits session events on the same `ext.serverpod.log` wire channel, reusing the existing `scope_start` / `log` / `scope_end` event types so the current CLI `handleServerLogEvent` keeps working. Session-specific fields (kind, endpoint, method, duration, slow, numQueries, …) are namespaced under a top-level `session` sub-object that session-aware consumers can unpack.

#### CLI

**`StdOutLogWriter`** - extends `SpinnerLogWriter`. Delegates log formatting to `cli_tools.StdOutLogger` for `LogType`-aware output (bullets, headers, boxes, etc.). `LogType` is read from `LogEntry.metadata[logTypeKey]`. The underlying `StdOutLogger` accepts all levels - filtering is done by `Log`, not the writer.

**`TuiLogWriter`** - writer for the nocterm TUI. `log` appends a `LogEntry` to `AppStateHolder.state.logHistory`; `openScope` creates a `TrackedOperation` in `activeOperations`; `closeScope` completes it as `CompletedOperation`. Supports buffering before the TUI is mounted via `attach(holder)`.

### ServerpodCliLogger

Bridges `cli_tools.Logger` to `Log`. All serverpod CLI commands use `cli_tools.Logger` as their logging interface; `ServerpodCliLogger` implements it by delegating to a `Log` instance:

- `info(msg, type: TextLogType.bullet)` -> `Log.call()` with `LogType` stashed in `LogEntry.metadata[logTypeKey]`.
- `progress(msg, runner)` -> `Log.progress(msg, runner)`.

This lets the CLI use any `LogWriter`-based backend (TUI, terminal, …) while preserving `LogType` formatting.

### Writer chains (server)

Assembled in two phases by `Serverpod._initializeServerpod` / `_installConfiguredWriters`. Two independent chains live side by side: framework over `MultiLogWriter`, session over `MultiSessionLogWriter`.

**Phase 1 - bootstrap** (before config is loaded):

```
log         -> MultiLogWriter
                 -> bootstrapTextWriter  (TextLogWriter or IsolatedLogWriter(TextLogWriter.new))
                 -> VmServiceLogWriter

sessionLog  -> MultiSessionLogWriter
                 -> VmServiceSessionLogWriter
```

Only `bootstrapTextWriter` is tracked in `_bootstrapWriters`. The two VM-service writers stay in their chains for the process lifetime.

**Phase 2 - after config load**: `_installConfiguredWriters` swaps the tracked bootstrap writers for the configured ones.

Framework chain (`logWriter`) replaces `bootstrapTextWriter` with a terminal-size-appropriate writer:

```
+ TextLogWriter | IsolatedLogWriter(TextLogWriter.new)    -- lifecycle, errors, log.info outside a session
```

Session chain (`sessionLogWriter`) appends the configured echo / persistence writers:

```
+ SessionTextLogWriter | SessionJsonLogWriter             -- if sessionLogs.consoleEnabled
+ DatabaseLogWriter                                       -- if sessionLogs.persistentEnabled and non-sqlite
```

The two VM-service writers remain in their chains unchanged. A healthy shutdown drains `sessionLog.shutdown()` before `log.close()` on both the graceful-exit and exit-after-flush paths.

### Writer chain (CLI)

```
CLI headless mode:
  ServerpodCliLogger
    -> Log -> IsolatedLogWriter(StdOutLogWriter.new)        -- terminal

CLI TUI mode:
  ServerpodCliLogger
    -> Log -> TuiLogWriter                                  -- nocterm TUI
```

In TUI mode the CLI also subscribes to the server process's `ext.serverpod.log` VM-service events and dispatches them into the same `TuiLogWriter` via `handleServerLogEvent`, so the TUI shows CLI-side progress (code generation, hot-reload) and server-side events (lifecycle, sessions) on one timeline. Headless mode does not subscribe - the server's own stdout, produced by its `TextLogWriter`, is inherited by the CLI process and printed unchanged.

### Session integration

`SessionLogManager` builds a `SessionOpen` record in its constructor (sessionId, kind, label, serverId, endpoint, method, futureCallName) and dispatches it through `sessionLog.open(...)`. Query / message / log dispatches build `SessionQueryEntry` / `SessionMessageEntry` / `SessionLogEntry` records and call `sessionLog.record(...)`. At teardown `finalizeLog` builds a `SessionClose` (duration, success, slow, numQueries, authenticatedUserId, error, stackTrace) and calls `sessionLog.close(...)`. Order is assigned by the producer at call time so persisted order matches caller order even when writes race downstream.

Long-lived streaming sessions with `logStreamingSessionsContinuously: false` buffer `SessionEntry` records in memory and flush them at `finalizeLog`. The session-open `SessionOpen` is deferred to the same point so a session that produces no events is never advertised to the chain.

**Remaining gap - cross-chain correlation.** Framework `log.info(...)` calls made from inside an endpoint go to the framework chain (`log`), not the session chain. With no linkage between the chains they resolve to the framework's synthetic root `LogScope` and appear unrelated to the enclosing session. Closing this gap requires `SessionLogManager` to mint a framework-side `LogScope` that mirrors the session and wrap endpoint dispatch in `runZoned(..., zoneValues: {_logScopeKey: sessionScope})`, so framework log calls made during the session inherit that scope. Deferred because it touches session lifecycle, streaming sessions, and the existing `LogManager` wiring.

### Ad-hoc stdout/stderr migration

Framework code now routes through `log` in the common case. The remaining direct `stdout.writeln` / `stderr.writeln` calls are intentional last-resort paths that must not depend on the async log chain:

- `Serverpod` constructor catch block - fires before the log chain is drained and when `exit()` is about to be called; avoids losing the init error message to an un-flushed async pipeline.
- `_drainBeforeExit` / command-line help output (`--help`) - synchronous writes just before process exit or during argument parsing, where the async `Log` pipeline isn't a good fit.

Terminal writers (`TextLogWriter`, `SessionTextLogWriter`, `SessionJsonLogWriter`, `StdOutLogWriter`) also write to stdout/stderr, but that's their job - they are the sinks the chain hands events to, not ad-hoc bypasses.

### Multi-isolate

`Log` / `SessionLog` and their writer chains live on the main isolate. `IsolatedLogWriter` is the only writer that spans isolates: it moves a single underlying writer (typically `TextLogWriter`) onto a dedicated isolate so timer-driven spinner animations keep firing when the main isolate is blocked. For logs produced on *other* spawned isolates (hot-reload hosts, future-call workers, …), `VmServiceLogWriter.postEvent` is the escape hatch - `developer.postEvent` is process-wide, so posts from any isolate surface on the same `ext.serverpod.log` event stream.

## Open questions

1. **Recursion guard.** If a `LogWriter.log()` throws, `Log.call` currently swallows the error (`catch (_) {}`). That prevents recursion but also hides writer bugs. Consider a one-shot direct-to-stderr fallback for the first writer error per process, so the failure is visible without looping.

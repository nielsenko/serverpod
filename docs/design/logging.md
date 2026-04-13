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
- Session logging and framework logging share the same `LogWriter` chain.
- The abstraction is generic enough to live in a shared package.
- No serverpod-specific types (generated `TableRow` classes) in the logging interface.

## Implementation status

- Generic types, the `Log` class, and shared writers live in `serverpod_shared/lib/src/log/`.
- The CLI bridges to `cli_tools.Logger` via `ServerpodCliLogger`.
- Session logging flows through the unified writer chain, including `DatabaseLogWriter` persistence.
- Session integration is **partial**: per-session scopes are opened and closed on the writer chain, but not pushed into the surrounding `Zone`. Framework `log.info(...)` calls inside an endpoint body still resolve to the synthetic root scope rather than inheriting the session scope.

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

### Writer implementations

Writers live in three tiers:

- **Shared** (`serverpod_shared`) - framework-agnostic. Operate on `LogEntry` / `LogScope` values without inspecting metadata.
- **Server** (`serverpod`) - aware of the session-vs-framework split. Some filter on `LogScope.metadata[SessionScopeKeys.sessionType]`; see the following section for why.
- **CLI** (`serverpod_cli`) - consumed only by `serverpod start` / `serverpod start --watch`.

#### Shared

**`SpinnerLogWriter`** - base class that manages braille progress spinners for terminal output. Handles the scope stack, timer animation, and clear-line/redraw lifecycle. Subclasses override `writeLogLine` and the spinner/completion formatters.

**`TextLogWriter`** - extends `SpinnerLogWriter`. Writes formatted text with ANSI level prefixes (`DEBUG:`, `WARNING:`, `ERROR:`) to stdout/stderr.

**`IsolatedLogWriter`** - wraps any `LogWriter` in a dedicated isolate via `IsolatedObject`. The writer factory runs on the isolate so timer-driven spinner animations keep updating even when the calling isolate is blocked.

**`MultiLogWriter`** - fans out to a mutable list of child writers. Supports `add` / `remove` so the chain can be reconfigured after construction (used by the server's two-phase bootstrap; see "Writer chain (server)" below).

#### Server

**`VmServiceLogWriter`** - posts events via `developer.postEvent('ext.serverpod.log', ...)`:

- `log(entry)` -> `{type: 'log', level, message, scopeId, ...}`
- `openScope(scope)` -> `{type: 'scope_start', id, label, parentId, ...}`
- `closeScope(scope)` -> `{type: 'scope_end', id, success, duration, ...}`

Available to any VM-service client that subscribes to the `Extension` stream; the CLI's TUI mode is the current consumer.

**`NonSessionLogWriter`** - wraps a delegate writer and drops any event whose scope metadata carries `SessionScopeKeys.sessionType`. Lets us reuse a generic writer (like `TextLogWriter`) as the framework-only terminal writer without teaching it about sessions.

**`SessionTextStdOutLogWriter`** / **`JsonStdOutLogWriter`** - session-echo writers. The inverse filter of `NonSessionLogWriter`: accepts only session-tagged events and emits them to stdout in the selected format.

**`DatabaseLogWriter`** - persists session-tagged entries to `serverpod_session_log` / `serverpod_log` / `serverpod_query_log`. Applies the same session-tag filter, so framework messages are intentionally not persisted. The generated `TableRow` classes stay internal to this writer and do not appear in the `LogWriter` interface.

#### CLI

**`StdOutLogWriter`** - extends `SpinnerLogWriter`. Delegates log formatting to `cli_tools.StdOutLogger` for `LogType`-aware output (bullets, headers, boxes, etc.). `LogType` is read from `LogEntry.metadata[logTypeKey]`. The underlying `StdOutLogger` accepts all levels - filtering is done by `Log`, not the writer.

**`TuiLogWriter`** - writer for the nocterm TUI. `log` appends a `LogEntry` to `AppStateHolder.state.logHistory`; `openScope` creates a `TrackedOperation` in `activeOperations`; `closeScope` completes it as `CompletedOperation`. Supports buffering before the TUI is mounted via `attach(holder)`.

### Session-vs-framework filtering

`LogWriter` is deliberately generic: it carries `LogEntry` / `LogScope` values and has no notion of "session". The serverpod runtime, however, has strong reasons to split the stream:

- Session-tagged events belong in the session log tables (via `DatabaseLogWriter`) and in the session-echo format on stdout (columnar text or JSON) that external tooling scrapes.
- Framework events (lifecycle banners, errors, health checks, …) belong on the framework terminal only, and should not be persisted as session rows.

Two cleaner-sounding alternatives were rejected:

1. **Two independent writer chains**, one session and one framework. Doubles the plumbing - two `Log` instances, two teardown paths - and makes cross-cutting writers like `VmServiceLogWriter` awkward (they'd have to be duplicated or wrapped into both chains).
2. **Add a channel discriminator to the `LogWriter` interface.** Leaks serverpod-specific semantics into `serverpod_shared`, which defeats the point of a generic logging abstraction that other projects could use.

Instead, the split is implemented as a convention: `SessionLogManager` stamps `SessionScopeKeys.sessionType` into every session scope's `metadata`, and server-package writers inspect that key to decide whether the event is in their remit. `SessionTextStdOutLogWriter`, `JsonStdOutLogWriter`, and `DatabaseLogWriter` accept only session-tagged events; `NonSessionLogWriter` is the inverse filter and wraps the framework-terminal writer so session events don't reach it.

Without `NonSessionLogWriter`, every session log entry would print twice on stdout: once flat via `TextLogWriter` and once formatted via the session-echo writer.

This is a deliberate leaky abstraction. `serverpod_shared` stays neutral; the convention keys live in `SessionScopeKeys` in the `serverpod` package, giving a single source of truth for the metadata contract. Any future split (e.g. per-tenant, per-isolate) follows the same pattern - a metadata key defined in the consuming package, with filter writers as needed - without touching the generic types.

### ServerpodCliLogger

Bridges `cli_tools.Logger` to `Log`. All serverpod CLI commands use `cli_tools.Logger` as their logging interface; `ServerpodCliLogger` implements it by delegating to a `Log` instance:

- `info(msg, type: TextLogType.bullet)` -> `Log.call()` with `LogType` stashed in `LogEntry.metadata[logTypeKey]`.
- `progress(msg, runner)` -> `Log.progress(msg, runner)`.

This lets the CLI use any `LogWriter`-based backend (TUI, terminal, …) while preserving `LogType` formatting.

### Writer chain (server)

Assembled in two phases by `Serverpod._initializeServerpod` / `_installConfiguredWriters`.

**Phase 1 - bootstrap** (before config is loaded):

```
Log -> MultiLogWriter
         -> bootstrapTextWriter  (TextLogWriter or IsolatedLogWriter(TextLogWriter.new))
         -> VmServiceLogWriter
```

Only `bootstrapTextWriter` is tracked in `_bootstrapWriters`; `VmServiceLogWriter` stays in the chain for the process lifetime.

**Phase 2 - after config load**: `_installConfiguredWriters` removes the tracked bootstrap writers and appends:

```
+ NonSessionLogWriter(TextLogWriter | IsolatedLogWriter(TextLogWriter.new))  -- framework messages
+ SessionTextStdOutLogWriter | JsonStdOutLogWriter                           -- if sessionLogs.consoleEnabled
+ DatabaseLogWriter                                                          -- if sessionLogs.persistentEnabled and non-sqlite
```

`VmServiceLogWriter` is always present and is a no-op when no VM service is attached.

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

`SessionLogManager` creates a `LogScope` per session in its constructor, tagged with `SessionScopeKeys.sessionType`, `sessionId`, `endpoint`, `method`, `serverId` (and `futureCallName` for future-call sessions). It opens the scope on the writer chain via `LogWriter.openScope` (directly, not via `log.progress`) and closes it at session teardown.

This is enough for session-aware writers (`SessionTextStdOutLogWriter`, `JsonStdOutLogWriter`, `DatabaseLogWriter`) to key off the session scope, and for `NonSessionLogWriter` to drop those events so they aren't duplicated on the framework terminal stream.

**Remaining gap:** the session scope is not pushed into the surrounding `Zone`. Endpoint bodies that call `log.info(...)` see the synthetic root scope, not the session scope. Closing this gap requires wrapping endpoint/future-call dispatch in `runZoned(..., zoneValues: {_logScopeKey: sessionScope})` at the point `SessionLogManager` is constructed. Deferred because it touches session lifecycle, streaming sessions, and the existing `LogManager` wiring.

### Ad-hoc stdout/stderr migration

Framework code now routes through `log` in the common case. The remaining direct `stdout.writeln` / `stderr.writeln` calls are intentional last-resort paths that must not depend on the async log chain:

- `Serverpod` constructor catch block - fires before the log chain is drained and when `exit()` is about to be called; avoids losing the init error message to an un-flushed async pipeline.
- `_drainBeforeExit` / command-line help output (`--help`) - synchronous writes just before process exit or during argument parsing, where the async `Log` pipeline isn't a good fit.
- `SessionTextStdOutLogWriter` / `JsonStdOutLogWriter` - writing to stdio is the writer's job.

### Multi-isolate

- `developer.postEvent` is process-wide - works from any isolate.
- `stdout` / `stderr` are process-wide.
- `LogScope` values are sendable across isolates (all fields are simple values).
- Each isolate that needs logging initializes its own zone with a received scope.
- `IsolatedLogWriter` wraps any `LogWriter` in a dedicated isolate for non-blocking animation.

### Rendering

**Alternate-mode TUI (nocterm):**

- Root-scope entries render as flat log lines.
- Non-root scopes render as tracked operations (pinned while active, collapsed on completion).
- Nested scopes: each level as a separate tracked operation.
- `x` toggles expand/collapse of completed operations.

**Simple-mode TUI (future):**

- Last log line printed, followed by active scopes.
- No alternate screen buffer.
- Works in any terminal.

## Open questions

1. **Recursion guard.** If a `LogWriter.log()` throws, `Log.call` currently swallows the error (`catch (_) {}`). That prevents recursion but also hides writer bugs. Consider a one-shot direct-to-stderr fallback for the first writer error per process, so the failure is visible without looping.
2. **Session scope in Zone.** As described in "Session integration", endpoint bodies don't inherit the session scope. Closing this gap is the next step toward fully unified logging.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:serverpod_cli/src/commands/messages.dart';
import 'package:serverpod_cli/src/commands/start/flutter_log_event.dart';
import 'package:serverpod_cli/src/commands/start/flutter_runtime_info.dart';
import 'package:serverpod_cli/src/commands/start/kernel_compiler.dart';
import 'package:serverpod_cli/src/commands/start/server_process.dart'
    show vmServiceWsUri;
import 'package:serverpod_cli/src/util/browser_launcher.dart';
import 'package:serverpod_cli/src/util/serverpod_cli_logger.dart';
import 'package:serverpod_cli/src/util/strip_ansi.dart';
import 'package:serverpod_cli/src/vendored/flutter_daemon_protocol.dart';
import 'package:serverpod_cli/src/vendored/flutter_devfs.dart';
import 'package:serverpod_cli/src/vm_proxy/proxy.dart';
import 'package:serverpod_shared/log.dart' show LogLevel;
import 'package:serverpod_tui/serverpod_tui.dart' show BoundedQueueList;
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

/// Flutter's headless web device; serves the app but never opens a
/// browser, so a VM service attach waits for a human to open the URL.
const flutterDeviceWebServer = 'web-server';

const flutterDeviceWebServerWithBrowser = 'web-server-launch-browser';

/// Thrown by [FlutterProcess.start] when `flutter` cannot be launched.
class FlutterNotInstalledException implements Exception {
  /// Reason `flutter` could not be launched.
  final String message;

  /// Underlying [ProcessException] or other cause.
  final Object? cause;

  FlutterNotInstalledException(this.message, [this.cause]);

  @override
  String toString() => 'FlutterNotInstalledException: $message';
}

/// Manages a `flutter run --machine` subprocess. Mirrors [ServerProcess].
/// IDE attach flows through [flutterProxy] (which owns the stable
/// vm-service URI and the per-app `flutter-vm-service-info-<appId>.json`
/// file); reload/restart go via [FlutterDaemonProtocol] over daemon stdin.
class FlutterProcess {
  static const _rawLogDeduplicationWindow = Duration(seconds: 5);
  static const _maxRecentRawLogLines = 1000;

  final String _flutterPackageDir;
  final String _flutterExecutable;
  final String _device;
  final List<String> _extraArgs;
  final IOSink _stdout;
  final IOSink _stderr;
  final void Function(FlutterLogEvent event)? _onLog;

  /// IDE-facing proxy. When non-null, the process binds upstream on
  /// VM-service connect and unbinds on shutdown so the IDE sees a
  /// stable attach point regardless of whether the Flutter app is
  /// currently running.
  final VmServiceProxy? _flutterProxy;

  /// Fires `'launching'` on spawn, `'connecting'` before VM-service
  /// connect, plus verbatim `app.progress` messages in between.
  final void Function(String stage)? _onProgress;

  /// Fires on the daemon's `app.started` event, i.e. the app is fully up
  /// on its device. This is the only launch-complete signal on non-web
  /// devices, which never publish an `app.webLaunchUrl`.
  final void Function()? _onStarted;

  /// When true, open [flutterAppUrl] in the default browser once it is
  /// published by the daemon (`app.webLaunchUrl`).
  final bool _launchBrowser;

  /// Test-only spawn args override; replaces the default `flutter run`
  /// arg list when non-null.
  final List<String>? _argsOverrideForTesting;

  /// Production override for `flutter run --machine` arguments.
  final List<String>? _machineArgsOverride;

  /// Test-only override for [BrowserLauncher.openUrl].
  final Future<bool> Function(Uri url)? _openBrowserForTesting;

  Process? _process;
  StreamSubscription<ProcessSignal>? _sigtermSub;
  StreamSubscription<String>? _stdoutLinesSub;
  StreamSubscription<String>? _stderrLinesSub;
  StreamSubscription<Event>? _loggingSub;
  StreamSubscription<Event>? _stdoutEventSub;
  StreamSubscription<Event>? _stderrEventSub;
  Timer? _vmServiceHeartbeat;
  Timer? _logCoalesceTimer;
  _PendingFlutterLog? _pendingLog;
  _Utf8LineDecoder? _vmStdoutDecoder;
  _Utf8LineDecoder? _vmStderrDecoder;
  final Stopwatch _logClock = Stopwatch()..start();
  final _recentRawLogLines = BoundedQueueList<_RecentRawLogLine>(
    _maxRecentRawLogLines,
  );

  String? _daemonAppId;
  FlutterDaemonProtocol? _daemon;
  String? _vmServiceUri;
  String? _flutterAppUrl;
  String? _dtdUri;
  VmService? _vmService;
  bool _browserOpening = false;

  String? _isolateId;

  /// When non-null, reload uses our own FES + DevFS pipeline instead
  /// of the daemon-stdin `app.restart` round-trip. Set by [start] when
  /// [useDevFsReload] is on; nulled on failure to construct/bring up.
  KernelCompiler? _compiler;
  DevFS? _devFS;

  static const _devFsName = 'serverpod_flutter';

  static const _dillUri = 'main.dart.dill';

  final bool useDevFsReload;

  final String? _entryPoint;

  final String? _packagesPath;

  /// Directory where the per-app `flutter-runtime-<appId>.json` snapshot
  /// lives. When set together with [_runtimeInfoAppId], [FlutterProcess]
  /// writes the runtime snapshot here after the VM service comes up so the
  /// next session can detect a surviving app and reattach.
  final String? _runtimeInfoDir;

  /// Identifies which configured Flutter app this process belongs to; keys
  /// the per-app runtime-info file under [_runtimeInfoDir] so companion apps
  /// don't clobber each other's reattach state. Null disables the snapshot.
  final String? _runtimeInfoAppId;

  /// When non-null, [start] spawns `flutter attach --machine --debug-uri`
  /// at this URI instead of `flutter run` - reusing a surviving app
  /// from a previous session. Skips the native build entirely.
  final String? _attachToVmServiceUri;

  // `null` result means the process exited before publishing a URI.
  final Completer<String?> _vmServiceUriCompleter = Completer<String?>();
  final Completer<int> _exitCodeCompleter = Completer<int>();
  final Completer<void> _launchedCompleter = Completer<void>();
  final Completer<void> _appStartedCompleter = Completer<void>();

  Completer<void>? _cleanupCompleter;

  FlutterProcess({
    required String flutterPackageDir,
    required String device,
    String flutterExecutable = 'flutter',
    List<String> extraArgs = const [],
    VmServiceProxy? flutterProxy,
    void Function(String stage)? onProgress,
    void Function()? onStarted,
    void Function(FlutterLogEvent event)? onLog,
    IOSink? stdoutSink,
    IOSink? stderrSink,
    List<String>? machineArgsOverride,
    this.useDevFsReload = false,
    String? entryPoint,
    String? packagesPath,
    String? runtimeInfoDir,
    String? runtimeInfoAppId,
    String? attachToVmServiceUri,
    @visibleForTesting List<String>? argsOverrideForTesting,
    @visibleForTesting Future<bool> Function(Uri url)? openBrowserForTesting,
  }) : _flutterPackageDir = flutterPackageDir,
       _flutterExecutable = flutterExecutable,
       _device = device,
       _extraArgs = extraArgs,
       _flutterProxy = flutterProxy,
       _onProgress = onProgress,
       _onStarted = onStarted,
       _onLog = onLog,
       _stdout = stdoutSink ?? stdout,
       _stderr = stderrSink ?? stderr,
       _launchBrowser = device == flutterDeviceWebServerWithBrowser,
       _machineArgsOverride = machineArgsOverride,
       _entryPoint = entryPoint,
       _packagesPath = packagesPath,
       _runtimeInfoDir = runtimeInfoDir,
       _runtimeInfoAppId = runtimeInfoAppId,
       _attachToVmServiceUri = attachToVmServiceUri,
       _argsOverrideForTesting = argsOverrideForTesting,
       _openBrowserForTesting = openBrowserForTesting;

  /// True between [start] and [stop]/exit.
  bool get isRunning => _process != null;

  /// Target device id this process was created for (`flutter run -d`).
  String get device => _device;

  /// True once [connectToVmService] resolved the upstream VM service.
  bool get isVmServiceConnected => _vmService != null;

  /// HTTP VM service URI published by the daemon, or `null` before publication.
  String? get vmServiceUri => _vmServiceUri;

  /// Connected `vm_service` client; `null` outside connect..[stop].
  VmService? get vmService => _vmService;

  /// HTTP URL the Flutter app is served at (web targets only).
  String? get flutterAppUrl => _flutterAppUrl;

  /// DTD URI from the daemon's `app.dtd` event.
  String? get dtdUri => _dtdUri;

  /// First of `app.debugPort`, `app.webLaunchUrl`, or process exit.
  /// Decoupled from [connectToVmService]: on `-d web-server` the
  /// daemon withholds `app.debugPort` until a browser attaches.
  Future<void> get launched => _launchedCompleter.future;

  /// Exit code of the `flutter run` subprocess.
  Future<int> get exitCode => _exitCodeCompleter.future;

  /// Throws [FlutterNotInstalledException] when `flutter` isn't on PATH.
  Future<void> start() async {
    if (_process != null) {
      throw StateError('FlutterProcess is already running.');
    }

    final device = _launchBrowser ? flutterDeviceWebServer : _device;
    // --no-dds: publish the raw vm-service URI in `app.debugPort.wsUri`
    // instead of a DDS-fronted one. The raw URI lives in the app
    // process so it survives flutter_tools dying, which is what makes
    // reattach work across `serverpod start` cycles. Our VmServiceProxy
    // does the multi-client/lifecycle job DDS would normally do, so
    // there's no functional loss for our use case (also shaves the
    // DDS-spawn delay off the first-run wait).
    final args =
        _argsOverrideForTesting ??
        _machineArgsOverride ??
        (_attachToVmServiceUri != null
            ? <String>[
                'attach',
                '--machine',
                '--no-dds',
                '-d',
                device,
                '--debug-uri',
                _attachToVmServiceUri,
                ..._extraArgs,
              ]
            : <String>[
                'run',
                '--machine',
                '--no-dds',
                '-d',
                device,
                ..._extraArgs,
              ]);

    final invocation = await _resolveFlutterInvocation(_flutterExecutable);

    // Pre-resolve flutter pub deps when stale. flutter_tools' Xcode
    // assemble step has been seen to fail with 'Because pg1_flutter
    // requires the Flutter SDK, version solving failed' on workspaces
    // when its internal verify step uses `dart pub` instead of
    // `flutter pub`. Running flutter pub get up front sidesteps it
    // (and is a no-op when the lockfile is already current). Skipped
    // on reattach since no build runs.
    if (_attachToVmServiceUri == null) {
      await _ensurePubGetIfStale(invocation);
    }

    if (useDevFsReload) {
      await _startCompiler(invocation.flutterRoot);
    }

    Process process;
    try {
      process = await Process.start(
        invocation.executable,
        [...invocation.baseArgs, ...args],
        workingDirectory: _flutterPackageDir,
      );
    } on ProcessException catch (e) {
      throw FlutterNotInstalledException(
        'Failed to launch `${invocation.executable}`: ${e.message}. '
        'Install Flutter (https://flutter.dev) or pass `--no-flutter`.',
        e,
      );
    }
    _process = process;
    _daemon = FlutterDaemonProtocol(process);
    _onProgress?.call(flutterAppLaunching);

    // Forward SIGTERM as SIGINT for graceful shutdown.
    if (!Platform.isWindows) {
      _sigtermSub = ProcessSignal.sigterm.watch().listen(
        (_) => process.kill(ProcessSignal.sigint),
      );
    }

    // `[`-prefixed lines -> machine parser; rest -> _stdout as text.
    void routeLine(String line) {
      if (line.startsWith('[')) {
        handleMachineLine(line);
      } else if (line.isNotEmpty) {
        final accepted = _emitLog(
          FlutterLogEvent(
            time: DateTime.now(),
            level: LogLevel.info,
            message: line,
            source: FlutterLogSource.processStdout,
            levelIsInferred: true,
            timestampIsInferred: true,
            canCoalesce: true,
          ),
        );
        if (accepted) _stdout.writeln(line);
      }
    }

    _stdoutLinesSub = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(routeLine);

    void routeStderrLine(String line) {
      if (line.isEmpty) {
        _stderr.writeln();
        return;
      }
      final accepted = _emitLog(
        FlutterLogEvent(
          time: DateTime.now(),
          level: LogLevel.error,
          message: line,
          source: FlutterLogSource.processStderr,
          levelIsInferred: true,
          timestampIsInferred: true,
          canCoalesce: true,
        ),
      );
      if (accepted) _stderr.writeln(line);
    }

    _stderrLinesSub = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(routeStderrLine);

    unawaited(
      process.exitCode.then((code) async {
        if (!_vmServiceUriCompleter.isCompleted) {
          _vmServiceUriCompleter.complete(null);
        }
        if (!_launchedCompleter.isCompleted) {
          _launchedCompleter.complete();
        }
        if (!_appStartedCompleter.isCompleted) {
          _appStartedCompleter.complete();
        }
        // Abort before exitCode so request awaiters see the failure.
        _daemon?.abort();
        if (!_exitCodeCompleter.isCompleted) {
          _exitCodeCompleter.complete(code);
        }
        await _cleanup();
      }),
    );
  }

  /// Connects to the Flutter VM service.
  ///
  /// When set [timeout] caps the wait for the daemon to publish URI.
  ///
  /// Waits for `app.debugPort`, binds [flutterProxy] upstream so IDE
  /// clients can attach, then opens a `vm_service` client.
  Future<void> connectToVmService({Duration? timeout}) async {
    if (_vmService != null) return;
    _onProgress?.call('connecting');

    final String? maybeUri;
    try {
      final pending = _vmServiceUriCompleter.future;
      maybeUri = await (timeout == null ? pending : pending.timeout(timeout));
    } on TimeoutException {
      log.warning(
        'Flutter VM service did not publish within ${timeout!.inSeconds}s; '
        'continuing without an attached VM service. '
        '(Hot reload from the CLI/IDE for the Flutter app will be unavailable.)',
      );
      return;
    }
    if (maybeUri == null) return;

    final wsUri = vmServiceWsUri(maybeUri);
    await _flutterProxy?.setUpstream(Uri.parse(wsUri));

    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        final vm = await vmServiceConnectUri(wsUri);
        _vmService = vm;
        await _subscribeToVmStreams(vm);
        _startVmServiceHeartbeat(vm);
        if (_compiler != null) await _bringUpDevFs(_vmService!);
        await _writeRuntimeInfo();
        return;
      } on Exception {
        if (attempt == 4) {
          log.warning('Could not connect to Flutter VM service at $wsUri');
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
  }

  Future<void> _writeRuntimeInfo() async {
    final dir = _runtimeInfoDir;
    final appId = _runtimeInfoAppId;
    final uri = _vmServiceUri;
    // appId keys the per-app runtime-info file; dir and uri are the only
    // payload the reattach check needs (liveness is a URI probe, not a PID).
    if (dir == null || appId == null || uri == null) return;
    try {
      await writeFlutterRuntimeInfo(
        dir,
        appId,
        FlutterRuntimeInfo(
          vmServiceUri: uri,
          device: _device,
          flutterPackageDir: p.absolute(_flutterPackageDir),
          createdAt: DateTime.now(),
        ),
      );
      log.debug('Flutter runtime info written (uri=$uri)');
    } catch (e) {
      log.debug('Could not write flutter runtime info: $e');
    }
  }

  /// Periodic `getVM()` against the [vm].
  ///
  /// Belt-and-suspenders companion to the daemon `app.stop` event
  /// (missing on flutter web).
  void _startVmServiceHeartbeat(VmService vm) {
    _vmServiceHeartbeat?.cancel();
    // Tight loop because DWDS won't tell us when a browser tab
    // detaches (its keep-alive is hardcoded to ~3000 days). 2s
    // interval + 1s timeout lets us notice within ~3s.
    //
    // Both paths need two consecutive bad reads before tearing down
    // (~4s at 2s interval): a hot restart briefly empties the isolate
    // list, and a one-off getVM() failure - blip, GC pause - shouldn't
    // race-kill a live app.
    var emptyReads = 0;
    var failedReads = 0;
    _vmServiceHeartbeat = Timer.periodic(const Duration(seconds: 2), (
      timer,
    ) async {
      if (_vmService != vm) {
        timer.cancel();
        return;
      }
      try {
        final vmInfo = await vm.getVM().timeout(const Duration(seconds: 1));
        // A successful read means the connection is alive; clear failures.
        failedReads = 0;
        if (vmInfo.isolates?.isEmpty ?? true) {
          emptyReads++;
          if (emptyReads >= 2) {
            timer.cancel();
            log.info('Flutter heartbeat: no isolates; tearing down.');
            await _onAppStop();
          }
        } else {
          emptyReads = 0;
        }
      } catch (e) {
        // A failure breaks any empty-isolate streak; keep them consecutive.
        emptyReads = 0;
        failedReads++;
        if (failedReads >= 2) {
          timer.cancel();
          log.info('Flutter heartbeat failed ($e); tearing down.');
          await _onAppStop();
        }
      }
    });
  }

  /// Subscribes to a named [vmService] stream.
  /// - 'Logging' for _dart:developer.log()_,
  /// - 'Stdout' for [stdout] (includes [print])
  /// - 'Stderr' for [stderr]
  Future<void> _subscribeToVmStreams(VmService vmService) async {
    Future<bool> tryListen(String stream) async {
      try {
        await vmService.streamListen(stream);
        return true;
      } on RPCError catch (e) {
        log.warning('Could not subscribe to Flutter $stream stream: $e');
        return false;
      }
    }

    if (await tryListen('Logging')) {
      _loggingSub = vmService.onLoggingEvent.listen((event) {
        final record = event.logRecord;
        final message = _instanceValue(record?.message);
        if (message == null || message.isEmpty) return;
        final name = _instanceValue(record?.loggerName) ?? '';
        final line = name.isEmpty ? message : '[$name] $message';
        final vmLevel = record?.level;
        // Level 0 is dart:developer's default "unspecified" value.
        final hasVmLevel = vmLevel != null && vmLevel > 0;
        final level = _logLevelFromVmLevel(
          hasVmLevel ? vmLevel : null,
        );
        final sink = switch (level) {
          LogLevel.warning || LogLevel.error || LogLevel.fatal => _stderr,
          _ => _stdout,
        };
        final recordTime = record?.time;
        final hasRecordTime = recordTime != null && recordTime >= 0;
        _emitLog(
          FlutterLogEvent(
            time: hasRecordTime
                ? DateTime.fromMillisecondsSinceEpoch(recordTime)
                : DateTime.now(),
            level: level,
            message: message,
            source: FlutterLogSource.vmLogging,
            loggerName: name.isEmpty ? null : name,
            error: _instanceValue(record?.error),
            stackTrace: _instanceValue(record?.stackTrace),
            metadata: {
              'vmLevel': ?(hasVmLevel ? vmLevel : null),
              'sequenceNumber': ?record?.sequenceNumber,
              'zone': ?_instanceValue(record?.zone),
            },
            levelIsInferred: !hasVmLevel,
            timestampIsInferred: !hasRecordTime,
          ),
        );
        sink.writeln(line);
      });
    }

    if (await tryListen('Stdout')) {
      _vmStdoutDecoder = _Utf8LineDecoder(
        (line) => _forwardVmStreamLine(
          _stdout,
          line,
          level: LogLevel.info,
          source: FlutterLogSource.vmStdout,
        ),
      );
      _stdoutEventSub = vmService.onStdoutEvent.listen(
        (event) => _writeVmStreamEvent(_vmStdoutDecoder!, event),
      );
    }
    if (await tryListen('Stderr')) {
      _vmStderrDecoder = _Utf8LineDecoder(
        (line) => _forwardVmStreamLine(
          _stderr,
          line,
          level: LogLevel.error,
          source: FlutterLogSource.vmStderr,
        ),
      );
      _stderrEventSub = vmService.onStderrEvent.listen(
        (event) => _writeVmStreamEvent(_vmStderrDecoder!, event),
      );
    }
  }

  /// Adds a VM service stream [event] to its UTF-8 line decoder.
  void _writeVmStreamEvent(_Utf8LineDecoder decoder, Event event) {
    final encodedBytes = event.bytes;
    if (encodedBytes == null) return;
    try {
      decoder.add(base64.decode(encodedBytes));
    } catch (_) {
      // Ignore malformed VM service payloads.
    }
  }

  void _forwardVmStreamLine(
    IOSink sink,
    String line, {
    required LogLevel level,
    required FlutterLogSource source,
  }) {
    if (line.isEmpty) {
      sink.writeln();
      return;
    }
    final accepted = _emitLog(
      FlutterLogEvent(
        time: DateTime.now(),
        level: level,
        message: line,
        source: source,
        levelIsInferred: true,
        timestampIsInferred: true,
        canCoalesce: true,
      ),
    );
    if (accepted) sink.writeln(line);
  }

  /// Hot reload. Daemon-reported success; never throws.
  Future<bool> reload({Set<String> changedPaths = const {}}) {
    if (_compiler != null && _devFS != null && _isolateId != null) {
      return _devFsReload(changedPaths);
    }
    return _appRestart(fullRestart: false);
  }

  /// Hot restart: full app reinit, state lost.
  Future<bool> restart() => _appRestart(fullRestart: true);

  Future<void> _startCompiler(String? flutterRoot) async {
    if (flutterRoot == null) {
      log.warning(
        'Flutter DevFS reload requested but flutterRoot is unknown; '
        'falling back to daemon-stdin reload.',
      );
      return;
    }
    final pkgDir = p.normalize(p.absolute(_flutterPackageDir));
    final entry = p.normalize(
      p.absolute(_entryPoint ?? p.join(pkgDir, 'lib', 'main.dart')),
    );
    // Dart workspaces keep package_config.json at the workspace root,
    // not in each member package; walk up until we find it.
    final packages = p.normalize(
      p.absolute(_packagesPath ?? _findPackageConfig(pkgDir)),
    );
    final outputDill = p.normalize(
      p.absolute(p.join(pkgDir, '.dart_tool', 'serverpod', 'flutter.dill')),
    );
    log.debug(
      'Flutter FES: starting (target=flutter, sdk=$flutterRoot, '
      'entry=$entry, packages=$packages)',
    );
    try {
      final compiler = KernelCompiler.flutter(
        flutterRoot: flutterRoot,
        entryPoint: entry,
        outputDill: outputDill,
        packagesPath: packages,
        // Mirror flutter_tools: its FES inherits CWD from `flutter run`
        // which our spawn sets to the flutter package dir. Without this,
        // FES runs from wherever the user invoked serverpod_cli and
        // fails to read the package_config even when --packages is an
        // absolute path.
        workingDirectory: pkgDir,
      );
      // `compiler.start()` brings up FES and kicks off the pre-warm
      // compile in the background. The native build runs in parallel,
      // so the pre-warm cost is hidden. `_devFsReload` awaits
      // `compiler.ensureWarm()` before issuing its own compile.
      await compiler.start();
      _compiler = compiler;
      log.debug('Flutter FES: ready');
    } catch (e) {
      log.warning(
        'Flutter FES failed to start: $e. Falling back to daemon-stdin '
        'reload.',
      );
    }
  }

  /// Runs `flutter pub get` from the workspace/package dir that owns
  /// `pubspec.lock` when `.dart_tool/package_config.json` is missing
  /// or older than the lockfile. No-op when deps are current. Uses
  /// the same direct-dart invocation as the main spawn so puro
  /// wrappers don't sit between us and flutter_tools.
  Future<void> _ensurePubGetIfStale(_FlutterInvocation invocation) async {
    final pkgDir = p.normalize(p.absolute(_flutterPackageDir));
    final packageConfig = _findPackageConfig(pkgDir);
    final rootDir = p.dirname(p.dirname(packageConfig));
    final lockFile = File(p.join(rootDir, 'pubspec.lock'));
    final cfgFile = File(packageConfig);
    if (!await lockFile.exists()) return;
    if (await cfgFile.exists()) {
      final lockMtime = (await lockFile.stat()).modified;
      final cfgMtime = (await cfgFile.stat()).modified;
      if (!lockMtime.isAfter(cfgMtime)) return;
    }
    log.debug('flutter pub get: package_config stale, refreshing');
    try {
      final result = await Process.run(
        invocation.executable,
        [...invocation.baseArgs, 'pub', 'get'],
        workingDirectory: rootDir,
      );
      if (result.exitCode != 0) {
        log.warning(
          'flutter pub get exited ${result.exitCode}:\n'
          '${result.stdout}\n${result.stderr}',
        );
      }
    } catch (e) {
      log.warning('flutter pub get failed to spawn: $e');
    }
  }

  Future<void> _bringUpDevFs(VmService vmService) async {
    // Wait until flutter_tools' resident runner is settled. It also
    // calls `_createDevFS` and writes the initial dill between
    // `app.debugPort` and `app.started`; racing it kills the VM
    // ("Lost connection to device").
    log.debug('Flutter DevFS: waiting for app.started');
    try {
      await _appStartedCompleter.future.timeout(const Duration(minutes: 2));
    } on TimeoutException {
      log.warning('Flutter app.started never fired; DevFS reload disabled.');
      return;
    }
    if (_process == null) return;

    try {
      final vm = await vmService.getVM();
      final isolates = vm.isolates ?? const [];
      if (isolates.isEmpty) {
        log.warning('Flutter VM reports no isolates; DevFS reload disabled.');
        return;
      }
      _isolateId = isolates.first.id;
      log.debug('Flutter DevFS: isolate $_isolateId, creating $_devFsName');

      final devFS = DevFS(
        vmService: vmService,
        fsName: _devFsName,
        httpAddress: Uri.parse(_vmServiceUri!),
      );
      final baseUri = await devFS.create();
      _devFS = devFS;
      log.debug('Flutter DevFS: ready at $baseUri');
    } on RPCError catch (e) {
      log.warning('Flutter DevFS bring-up failed: $e');
    } catch (e) {
      log.warning('Flutter DevFS bring-up unexpected error: $e');
    }
  }

  Future<bool> _devFsReload(Set<String> changedPaths) async {
    final compiler = _compiler!;
    final devFS = _devFS!;
    final isolateId = _isolateId!;
    final vmService = _vmService!;
    // Block until any in-flight pre-warm compile is done; FES is
    // serial, so a user edit arriving mid-prewarm would otherwise
    // throw StateError from FrontendServerClient.
    await compiler.ensureWarm();
    try {
      final result = await compiler.compile(changedPaths: changedPaths);
      if (result.errorCount > 0) {
        log.error(
          'Flutter reload: compile failed:\n'
          '${result.compilerOutputLines.join('\n')}',
        );
        await compiler.reject();
        return false;
      }

      // No source changes -> dill on the VM is already current; skip
      // the DevFS push (~MB upload) and reloadSources (~100-500ms
      // VM-side rebind), just reassemble the widget tree. This is the
      // 'IDE Hot Reload button after no edits' path.
      if (changedPaths.isEmpty) {
        log.debug('Flutter reload: reassemble-only (no source changes)');
      } else {
        await devFS.writeFiles({
          Uri.parse(_dillUri): DevFSFileContent(File(result.dillOutput!)),
        });
        final reload = await vmService.reloadSources(
          isolateId,
          rootLibUri: '${devFS.baseUri}$_dillUri',
        );
        if (reload.success != true) {
          log.warning(
            'Flutter reload: reloadSources rejected: '
            '${reload.json?['notices']}',
          );
          await compiler.reject();
          return false;
        }
      }
      await vmService.callServiceExtension(
        'ext.flutter.reassemble',
        isolateId: isolateId,
      );
      compiler.accept();
      return true;
    } catch (e) {
      log.warning('Flutter DevFS reload failed: $e');
      try {
        await compiler.reject();
      } catch (_) {}
      return false;
    }
  }

  Future<bool> _appRestart({required bool fullRestart}) async {
    final op = fullRestart ? 'restart' : 'reload';
    final daemon = _daemon;
    final appId = _daemonAppId;
    if (daemon == null || appId == null) {
      log.warning('Flutter $op: daemon not running yet.');
      return false;
    }
    const requestTimeout = Duration(seconds: 30);
    try {
      await daemon
          .sendRequest('app.restart', <String, Object?>{
            'appId': appId,
            'fullRestart': fullRestart,
            'pause': false,
            'debounce': true,
          })
          .timeout(requestTimeout);
      return true;
    } on TimeoutException {
      log.warning('Flutter $op timed out after ${requestTimeout.inSeconds}s.');
      return false;
    } on FlutterDaemonException catch (e) {
      log.warning('Flutter $op failed: ${e.error}');
      return false;
    } catch (e) {
      log.warning('Flutter $op: unexpected error: $e');
      return false;
    }
  }

  /// Stop the Flutter process. By default the app is left running so the
  /// next session can reattach: we SIGKILL `flutter_tools` without letting
  /// its SIGINT handler call `exitApplication`, so the app (and its raw
  /// vm-service URI, thanks to `--no-dds`) survives. The runtime-info
  /// breadcrumb is kept. SIGKILL reaches flutter_tools directly because
  /// [start] spawns it without wrappers.
  ///
  /// When [shutdownApp] is true the app is torn down for good: `app.stop`
  /// is sent via the daemon so flutter_tools cleanly calls
  /// `exitApplication` - on web that also closes the browser window it
  /// spawned, which SIGKILL alone would orphan - then the breadcrumb is
  /// removed so the next session spawns fresh.
  Future<int> stop({
    Duration timeout = const Duration(seconds: 5),
    bool shutdownApp = false,
  }) async {
    final process = _process;
    if (process == null) {
      log.debug('Flutter stop: no process.');
      return 0;
    }

    await _sigtermSub?.cancel();
    _sigtermSub = null;

    // Only an explicit shutdown takes the app down. `app.stop` makes
    // flutter_tools call exitApplication on the device - on web that
    // closes the browser window it spawned, which a bare SIGKILL would
    // orphan. The breadcrumb is dropped so the next session spawns fresh.
    if (shutdownApp) {
      await _appStopOverDaemon(timeout);
      await _deleteRuntimeInfo();
    }

    // SIGKILL flutter_tools. On the default path the SIGINT handler is
    // deliberately bypassed so it can't call exitApplication, leaving the
    // app (and its raw vm-service URI, via --no-dds) alive for reattach.
    log.debug('Flutter stop: SIGKILL PID ${process.pid}');
    process.kill(ProcessSignal.sigkill);
    final exitCode = await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        log.warning(
          'Flutter did not exit within ${timeout.inSeconds}s of SIGKILL.',
        );
        return -1;
      },
    );
    log.debug('Flutter stop: PID ${process.pid} exited with $exitCode');

    await _cleanup();
    return exitCode;
  }

  Future<void> _appStopOverDaemon(Duration timeout) async {
    final daemon = _daemon;
    final appId = _daemonAppId;
    if (daemon == null || appId == null) {
      log.debug('Flutter app.stop: daemon not ready, skipping.');
      return;
    }
    try {
      await daemon
          .sendRequest('app.stop', <String, Object?>{'appId': appId})
          .timeout(timeout);
      log.debug('Flutter app.stop: device-side app terminated.');
    } on TimeoutException {
      log.warning(
        'Flutter app.stop timed out after ${timeout.inSeconds}s '
        '(app may still be alive).',
      );
    } on FlutterDaemonException catch (e) {
      log.warning('Flutter app.stop failed: ${e.error}');
    } catch (e) {
      log.warning('Flutter app.stop: unexpected error: $e');
    }
  }

  Future<void> _deleteRuntimeInfo() async {
    final dir = _runtimeInfoDir;
    final appId = _runtimeInfoAppId;
    if (dir == null || appId == null) return;
    try {
      await deleteFlutterRuntimeInfo(dir, appId);
    } catch (e) {
      log.debug('Could not remove flutter runtime info: $e');
    }
  }

  /// Parses one `flutter run --machine` line. Machine events are
  /// `[`-prefixed single-line JSON arrays; other lines are ignored.
  @visibleForTesting
  void handleMachineLine(String line) {
    if (!line.startsWith('[')) return;

    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      return;
    }
    if (decoded is! List) return;

    // Protocol allows multiple events per line.
    for (final entry in decoded) {
      if (entry is! Map) continue;

      // Response envelope (`id`, no `event`) -> pending request.
      final envelope = Map<String, Object?>.from(entry);
      if (_daemon?.tryHandleResponse(envelope) ?? false) continue;

      final event = entry['event'];
      if (event is! String) continue;

      final params = entry['params'];
      final paramMap = params is Map ? params : const {};

      log.debug('flutter[--machine] $event ${jsonEncode(paramMap)}');

      switch (event) {
        case 'app.start':
          final appId = paramMap['appId'];
          if (appId is String) _daemonAppId = appId;
        case 'app.debugPort':
          final wsUri = paramMap['wsUri'];
          if (wsUri is String && !_vmServiceUriCompleter.isCompleted) {
            // IDEs and callers expect the http form.
            final httpUri = httpFromWs(wsUri);
            _vmServiceUri = httpUri;
            _vmServiceUriCompleter.complete(httpUri);
          }
          if (!_launchedCompleter.isCompleted) _launchedCompleter.complete();
        case 'app.webLaunchUrl':
          final url = paramMap['url'];
          if (url is String) {
            _flutterAppUrl = url;
            if (!_launchedCompleter.isCompleted) _launchedCompleter.complete();
            if (_launchBrowser) {
              unawaited(_openBrowser(Uri.parse(url)));
            }
          }
        case 'app.dtd':
          final uri = paramMap['uri'];
          if (uri is String && uri.isNotEmpty) {
            _dtdUri = uri;
          }
        case 'app.progress':
          final message = paramMap['message'];
          if (message is String && message.isNotEmpty) {
            _onProgress?.call(message);
          }
        case 'app.started':
          _onStarted?.call();
          if (!_appStartedCompleter.isCompleted) {
            _appStartedCompleter.complete();
          }
        case 'app.stop':
          log.debug('Flutter daemon emitted app.stop; tearing down.');
          unawaited(_onAppStop());
        case 'app.log':
          // Native devices report application and platform output here. Keep
          // this alongside the VM streams, which are required for web targets.
          _forwardMachineLog(
            paramMap,
            messageKey: 'log',
            level: paramMap['error'] == true ? LogLevel.error : LogLevel.info,
            source: FlutterLogSource.appLog,
            levelIsInferred: true,
          );
        case 'daemon.logMessage':
          final daemonLevel = paramMap['level'];
          _forwardMachineLog(
            paramMap,
            messageKey: 'message',
            level: _logLevelFromDaemonLevel(daemonLevel),
            source: FlutterLogSource.daemon,
            levelIsInferred: !_isKnownDaemonLevel(daemonLevel),
          );
      }
    }
  }

  void _forwardMachineLog(
    Map<dynamic, dynamic> params, {
    required String messageKey,
    required LogLevel level,
    required FlutterLogSource source,
    bool levelIsInferred = false,
  }) {
    final message = params[messageKey];
    if (message is! String || message.isEmpty) return;

    final stackTrace = params['stackTrace'];
    final accepted = _emitLog(
      FlutterLogEvent(
        time: DateTime.now(),
        level: level,
        message: message,
        source: source,
        stackTrace: stackTrace is String && stackTrace.isNotEmpty
            ? stackTrace
            : null,
        metadata: source == FlutterLogSource.daemon
            ? {'daemonLevel': params['level']}
            : source == FlutterLogSource.appLog
            ? {'error': params['error'] == true}
            : null,
        levelIsInferred: levelIsInferred,
        timestampIsInferred: true,
      ),
    );
    if (!accepted) return;

    final sink = switch (level) {
      LogLevel.warning || LogLevel.error || LogLevel.fatal => _stderr,
      _ => _stdout,
    };
    sink.write(message);
    if (!message.endsWith('\n')) sink.writeln();

    if (stackTrace is String && stackTrace.isNotEmpty) {
      sink.write(stackTrace);
      if (!stackTrace.endsWith('\n')) sink.writeln();
    }
  }

  /// Returns whether [event] was accepted for structured and raw forwarding.
  bool _emitLog(FlutterLogEvent event) {
    if (_isDuplicateRawLog(event)) return false;
    if (_onLog == null) return true;

    final canCoalesce =
        event.canCoalesce && event.levelIsInferred && event.timestampIsInferred;
    if (!canCoalesce) {
      _flushPendingLog();
      _dispatchLog(event);
      return true;
    }

    final pending = _pendingLog;
    final receivedAtMilliseconds = _logClock.elapsedMilliseconds;
    if (pending == null ||
        !pending.canAppend(
          event,
          receivedAtMilliseconds: receivedAtMilliseconds,
        )) {
      _flushPendingLog();
      _pendingLog = _PendingFlutterLog(
        event,
        receivedAtMilliseconds: receivedAtMilliseconds,
      );
    } else {
      pending.append(event);
    }

    _logCoalesceTimer?.cancel();
    _logCoalesceTimer = Timer(
      const Duration(milliseconds: 50),
      _flushPendingLog,
    );
    return true;
  }

  bool _isDuplicateRawLog(FlutterLogEvent event) {
    final channel = _rawLogChannel(event);
    if (channel == null) return false;

    final now = _logClock.elapsedMilliseconds;
    _recentRawLogLines.removeWhere(
      (line) =>
          now - line.receivedAtMilliseconds >
          _rawLogDeduplicationWindow.inMilliseconds,
    );

    final lines = stripAnsi(event.message)
        .split('\n')
        .map(
          (line) =>
              line.endsWith('\r') ? line.substring(0, line.length - 1) : line,
        )
        .where((line) => line.isNotEmpty)
        .toList();
    if (lines.isEmpty) return false;

    final matchedIndexes = <int>[];
    final unmatchedMessages = <String>[];
    for (final message in lines) {
      var matchIndex = -1;
      for (var index = 0; index < _recentRawLogLines.length; index++) {
        final line = _recentRawLogLines[index];
        if (!matchedIndexes.contains(index) &&
            line.channel == channel &&
            line.message == message &&
            line.source != event.source &&
            !line.duplicateSources.contains(event.source)) {
          matchIndex = index;
          break;
        }
      }
      if (matchIndex == -1) {
        unmatchedMessages.add(message);
      } else {
        matchedIndexes.add(matchIndex);
      }
    }

    if (unmatchedMessages.isNotEmpty) {
      for (final message in unmatchedMessages) {
        _recentRawLogLines.add(
          _RecentRawLogLine(
            channel: channel,
            message: message,
            source: event.source,
            receivedAtMilliseconds: now,
          ),
        );
      }
      return false;
    }

    for (final index in matchedIndexes) {
      _recentRawLogLines[index].duplicateSources.add(event.source);
    }
    return true;
  }

  static _RawLogChannel? _rawLogChannel(FlutterLogEvent event) {
    return switch (event.source) {
      FlutterLogSource.processStdout ||
      FlutterLogSource.vmStdout => _RawLogChannel.stdout,
      FlutterLogSource.processStderr ||
      FlutterLogSource.vmStderr => _RawLogChannel.stderr,
      FlutterLogSource.appLog => switch (event.level) {
        LogLevel.warning ||
        LogLevel.error ||
        LogLevel.fatal => _RawLogChannel.stderr,
        _ => _RawLogChannel.stdout,
      },
      _ => null,
    };
  }

  void _flushPendingLog() {
    _logCoalesceTimer?.cancel();
    _logCoalesceTimer = null;
    final pending = _pendingLog;
    if (pending == null) return;
    _pendingLog = null;
    _dispatchLog(pending.toEvent());
  }

  void _dispatchLog(FlutterLogEvent event) {
    try {
      _onLog?.call(event);
    } catch (error, stackTrace) {
      log.warning('Flutter log listener failed: $error\n$stackTrace');
    }
  }

  static LogLevel _logLevelFromDaemonLevel(Object? level) {
    return switch (level) {
      'trace' || 'debug' => LogLevel.debug,
      'status' || 'info' => LogLevel.info,
      'warning' || 'warn' => LogLevel.warning,
      'error' => LogLevel.error,
      'fatal' => LogLevel.fatal,
      _ => LogLevel.info,
    };
  }

  static bool _isKnownDaemonLevel(Object? level) {
    return const {
      'trace',
      'debug',
      'status',
      'info',
      'warning',
      'warn',
      'error',
      'fatal',
    }.contains(level);
  }

  static LogLevel _logLevelFromVmLevel(int? level) {
    final value = level ?? 800;
    if (value >= 1200) return LogLevel.fatal;
    if (value >= 1000) return LogLevel.error;
    if (value >= 900) return LogLevel.warning;
    if (value >= 800) return LogLevel.info;
    return LogLevel.debug;
  }

  static String? _instanceValue(InstanceRef? instance) {
    if (instance == null || instance.kind == InstanceKind.kNull) return null;
    return instance.valueAsString;
  }

  Future<void> _openBrowser(Uri url) async {
    if (_browserOpening) return;
    _browserOpening = true;
    final open = _openBrowserForTesting ?? BrowserLauncher.openUrl;
    if (!await open(url)) {
      log.warning('Could not open browser at $url');
    }

    // Reset the flag so we can open the browser again if the app is restarted.
    _browserOpening = false;
  }

  bool _appStopHandled = false;
  Future<void> _onAppStop() async {
    if (_appStopHandled) return;
    _appStopHandled = true;
    log.debug('Flutter teardown begin.');
    await _flutterProxy?.setUpstream(null);
    final process = _process;
    if (process == null) return;
    process.kill(ProcessSignal.sigint);
    await process.exitCode.timeout(
      const Duration(seconds: 3),
      onTimeout: () {
        log.debug('Flutter did not exit on SIGINT; sending SIGKILL.');
        process.kill(ProcessSignal.sigkill);
        return process.exitCode;
      },
    );
    log.debug('Flutter teardown end.');
  }

  Future<void> _cleanup() async {
    // Completer guard: concurrent stop + exit-listener share one pass.
    if (_cleanupCompleter != null) return _cleanupCompleter!.future;
    if (_process == null) return;

    final completer = Completer<void>();
    _cleanupCompleter = completer;

    try {
      _process = null;
      await _stdoutLinesSub?.cancel();
      await _stderrLinesSub?.cancel();
      await _sigtermSub?.cancel();
      await _loggingSub?.cancel();
      await _stdoutEventSub?.cancel();
      await _stderrEventSub?.cancel();
      _vmStdoutDecoder?.close();
      _vmStderrDecoder?.close();
      _flushPendingLog();
      _vmServiceHeartbeat?.cancel();
      _stdoutLinesSub = null;
      _stderrLinesSub = null;
      _sigtermSub = null;
      _loggingSub = null;
      _stdoutEventSub = null;
      _stderrEventSub = null;
      _vmStdoutDecoder = null;
      _vmStderrDecoder = null;
      _vmServiceHeartbeat = null;

      try {
        await _devFS?.destroy();
      } catch (_) {}
      _devFS = null;
      await _compiler?.dispose();
      _compiler = null;
      _isolateId = null;

      await _vmService?.dispose();
      _vmService = null;
      _vmServiceUri = null;
      _dtdUri = null;

      await _flutterProxy?.setUpstream(null);
    } finally {
      completer.complete();
    }
  }

  static _FlutterInvocation? _cachedInvocation;

  /// Probe `flutter --version --machine` for `flutterRoot`, then return
  /// `dart <flutterRoot>/.../flutter_tools.dart` so signals bypass
  /// puro/fvm/asdf wrappers and reach the daemon. Falls back to
  /// invoking [flutterExecutable] verbatim if the SDK paths are missing.
  static Future<_FlutterInvocation> _resolveFlutterInvocation(
    String flutterExecutable,
  ) async {
    final cached = _cachedInvocation;
    if (cached != null) return cached;

    // Don't cache the fallback: a fake-executable test probe would
    // poison the cache for later real callers.
    final fallback = _FlutterInvocation(
      executable: flutterExecutable,
      baseArgs: const [],
      flutterRoot: null,
    );
    try {
      final result = await Process.run(
        flutterExecutable,
        ['--version', '--machine'],
        runInShell: Platform.isWindows,
      );
      if (result.exitCode != 0) return fallback;
      final decoded = jsonDecode(result.stdout as String);
      if (decoded is! Map || decoded['flutterRoot'] is! String) {
        return fallback;
      }
      final root = decoded['flutterRoot'] as String;
      final dartBin = p.join(
        root,
        'bin',
        'cache',
        'dart-sdk',
        'bin',
        Platform.isWindows ? 'dart.exe' : 'dart',
      );
      final packages = p.join(
        root,
        'packages',
        'flutter_tools',
        '.dart_tool',
        'package_config.json',
      );
      final entry = p.join(
        root,
        'packages',
        'flutter_tools',
        'bin',
        'flutter_tools.dart',
      );
      if (!File(dartBin).existsSync() ||
          !File(packages).existsSync() ||
          !File(entry).existsSync()) {
        return fallback;
      }
      return _cachedInvocation = _FlutterInvocation(
        executable: dartBin,
        baseArgs: ['--disable-dart-dev', '--packages=$packages', entry],
        flutterRoot: root,
      );
    } catch (_) {
      return fallback;
    }
  }

  /// `ws://host:port/ws` -> `http://host:port` (also wss -> https).
  @visibleForTesting
  static String httpFromWs(String wsUri) {
    final uri = Uri.parse(wsUri);
    final scheme = uri.isScheme('wss') ? 'https' : 'http';
    var path = uri.path;
    if (path.endsWith('/ws')) path = path.substring(0, path.length - 3);
    return uri.replace(scheme: scheme, path: path).toString();
  }
}

/// Walk up from [startDir] (absolute) until `.dart_tool/package_config.json`
/// is found; return its path. Falls back to the conventional location under
/// [startDir] when no ancestor has it (FES then surfaces the missing file
/// rather than us silently guessing).
String _findPackageConfig(String startDir) {
  var dir = startDir;
  while (true) {
    final candidate = p.join(dir, '.dart_tool', 'package_config.json');
    if (File(candidate).existsSync()) return candidate;
    final parent = p.dirname(dir);
    if (parent == dir) {
      return p.join(startDir, '.dart_tool', 'package_config.json');
    }
    dir = parent;
  }
}

class _PendingFlutterLog {
  _PendingFlutterLog(
    this.first, {
    required this.receivedAtMilliseconds,
  }) : _message = StringBuffer(first.message),
       _lineCount = _countLines(first.message);

  static const maxLines = 100;
  static const maxCharacters = 64 * 1024;
  static const maxAge = Duration(milliseconds: 250);

  final FlutterLogEvent first;
  final int receivedAtMilliseconds;
  final StringBuffer _message;
  int _lineCount;

  bool canAppend(
    FlutterLogEvent event, {
    required int receivedAtMilliseconds,
  }) {
    if (event.source != first.source || event.level != first.level) {
      return false;
    }
    if (receivedAtMilliseconds - this.receivedAtMilliseconds >=
        maxAge.inMilliseconds) {
      return false;
    }
    final additionalLines = _countLines(event.message);
    return _lineCount + additionalLines <= maxLines &&
        _message.length + event.message.length + 1 <= maxCharacters;
  }

  void append(FlutterLogEvent event) {
    if (_message.isNotEmpty) _message.writeln();
    _message.write(event.message);
    _lineCount += _countLines(event.message);
  }

  FlutterLogEvent toEvent() {
    return FlutterLogEvent(
      time: first.time,
      level: first.level,
      message: _message.toString(),
      source: first.source,
      loggerName: first.loggerName,
      error: first.error,
      stackTrace: first.stackTrace,
      metadata: {
        ...?first.metadata,
        'coalesced': _lineCount > _countLines(first.message),
        'lineCount': _lineCount,
      },
      levelIsInferred: first.levelIsInferred,
      timestampIsInferred: first.timestampIsInferred,
    );
  }

  static int _countLines(String message) => '\n'.allMatches(message).length + 1;
}

enum _RawLogChannel { stdout, stderr }

class _RecentRawLogLine {
  _RecentRawLogLine({
    required this.channel,
    required this.message,
    required this.source,
    required this.receivedAtMilliseconds,
  });

  final _RawLogChannel channel;
  final String message;
  final FlutterLogSource source;
  final int receivedAtMilliseconds;
  final Set<FlutterLogSource> duplicateSources = {};
}

class _Utf8LineDecoder {
  _Utf8LineDecoder(void Function(String line) onLine) {
    _sink = const Utf8Decoder(allowMalformed: true).startChunkedConversion(
      const LineSplitter().startChunkedConversion(
        _CallbackSink<String>(onLine),
      ),
    );
  }

  late final ByteConversionSink _sink;

  void add(List<int> bytes) => _sink.add(bytes);

  void close() => _sink.close();
}

class _CallbackSink<T> implements Sink<T> {
  const _CallbackSink(this._onData);

  final void Function(T data) _onData;

  @override
  void add(T data) => _onData(data);

  @override
  void close() {}
}

class _FlutterInvocation {
  const _FlutterInvocation({
    required this.executable,
    required this.baseArgs,
    required this.flutterRoot,
  });
  final String executable;
  final List<String> baseArgs;
  final String? flutterRoot;
}

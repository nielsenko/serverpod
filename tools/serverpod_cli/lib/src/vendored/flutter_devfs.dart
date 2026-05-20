/*
 * This file is adapted from `flutter_tools`' DevFS implementation:
 *   <flutter>/packages/flutter_tools/lib/src/devfs.dart
 * which ferries new dill bytes to a running dart VM over the
 * vm-service's HTTP endpoint.
 *
 * Vendored against Flutter 3.41.9 (frameworkRevision 00b0c91f06).
 * When re-syncing, diff the upstream file at the matching tag and
 * mirror any wire-format changes (headers, query, dev_fs name scheme).
 *
 * The scope of the below license ("Software") is limited to this
 * file only, which is a derivative work of the original. The license
 * does not apply to any other part of the codebase.
 *
 * Modifications: stripped of asset / shader / font-manifest paths -
 * we only push compiled dill. `_DevFSHttpWriter` renamed
 * `HttpDevFSWriter` and exposed publicly. Uses `package:vm_service`
 * directly instead of `flutter_tools`' `FlutterVmService` wrapper.
 *
 * Copyright 2014 The Flutter Authors. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 *     * Redistributions of source code must retain the above copyright
 *       notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above
 *       copyright notice, this list of conditions and the following
 *       disclaimer in the documentation and/or other materials provided
 *       with the distribution.
 *     * Neither the name of Google Inc. nor the names of its
 *       contributors may be used to endorse or promote products derived
 *       from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vm_service/vm_service.dart';

class DevFSException implements Exception {
  DevFSException(this.message, [this.error, this.stackTrace]);
  final String message;
  final Object? error;
  final StackTrace? stackTrace;
  @override
  String toString() => 'DevFSException: $message';
}

/// Content abstraction for what we ship to the VM.
abstract class DevFSContent {
  int get size;
  Stream<List<int>> contentsAsStream();

  Stream<List<int>> contentsAsCompressedStream() =>
      contentsAsStream().transform(gzip.encoder);
}

/// File-backed content (the typical case: a compiled `.dill`).
class DevFSFileContent extends DevFSContent {
  DevFSFileContent(this.file);
  final File file;

  @override
  int get size => file.lengthSync();

  @override
  Stream<List<int>> contentsAsStream() => file.openRead();
}

/// In-memory bytes; used for synthesized content where a file isn't handy.
class DevFSByteContent extends DevFSContent {
  DevFSByteContent(this.bytes);
  final List<int> bytes;

  @override
  int get size => bytes.length;

  @override
  Stream<List<int>> contentsAsStream() => Stream.value(bytes);
}

abstract class DevFSWriter {
  /// Writes [entries] (keyed by URI relative to [baseUri]) to the device.
  Future<void> write(Map<Uri, DevFSContent> entries, Uri baseUri);
}

/// Writer that PUTs entries to the vm-service's HTTP endpoint. The VM
/// stores them in the named DevFS, addressable at `<baseUri>/<uri>`.
class HttpDevFSWriter implements DevFSWriter {
  HttpDevFSWriter({
    required this.fsName,
    required this.httpAddress,
    HttpClient? httpClient,
    this.uploadRetryThrottle = const Duration(milliseconds: 500),
  }) : _client = httpClient ?? HttpClient();

  final String fsName;
  final Uri httpAddress;
  final HttpClient _client;
  final Duration uploadRetryThrottle;

  static const _kMaxInFlight = 3;

  var _inFlight = 0;
  late Map<Uri, DevFSContent> _outstanding;
  late Completer<void> _completer;

  @override
  Future<void> write(Map<Uri, DevFSContent> entries, Uri baseUri) async {
    try {
      _client.maxConnectionsPerHost = _kMaxInFlight;
      _completer = Completer<void>();
      _outstanding = Map<Uri, DevFSContent>.of(entries);
      _scheduleWrites();
      await _completer.future;
    } on SocketException catch (e, st) {
      throw DevFSException('Lost connection to device.', e, st);
    } catch (e, st) {
      throw DevFSException('Sync failed', e, st);
    }
  }

  void _scheduleWrites() {
    while (_inFlight < _kMaxInFlight &&
        !_completer.isCompleted &&
        _outstanding.isNotEmpty) {
      final deviceUri = _outstanding.keys.first;
      final content = _outstanding.remove(deviceUri)!;
      _inFlight++;
      _startWrite(deviceUri, content, retry: 10);
    }
    if (_inFlight == 0 && !_completer.isCompleted && _outstanding.isEmpty) {
      _completer.complete();
    }
  }

  Future<void> _startWrite(
    Uri deviceUri,
    DevFSContent content, {
    required int retry,
  }) async {
    while (true) {
      try {
        final request = await _client.putUrl(httpAddress);
        request.headers.removeAll(HttpHeaders.acceptEncodingHeader);
        request.headers.add('dev_fs_name', fsName);
        request.headers.add(
          'dev_fs_uri_b64',
          base64.encode(utf8.encode('$deviceUri')),
        );
        await request.addStream(content.contentsAsCompressedStream());
        try {
          // 60s guards against dart-lang/sdk#43525 (PUT response can hang).
          final response = await request.close().timeout(
            const Duration(seconds: 60),
          );
          response.listen(
            (_) {},
            onError: (Object _) {},
            cancelOnError: true,
          );
        } on TimeoutException {
          request.abort();
          await request.done;
          rethrow;
        }
        break;
      } catch (e, st) {
        if (_completer.isCompleted) break;
        if (retry > 0) {
          retry--;
          await Future<void>.delayed(uploadRetryThrottle);
          continue;
        }
        _completer.completeError(e, st);
      }
    }
    _inFlight--;
    _scheduleWrites();
  }
}

/// A named filesystem on the device, addressable at [baseUri].
///
/// Lifecycle: [create] once after vm-service connect, push deltas via
/// [writeFiles], call `reloadSources(rootLibUri: baseUri/<pathToReload>)`
/// to swap in the new code, then [destroy] on shutdown.
class DevFS {
  DevFS({
    required VmService vmService,
    required this.fsName,
    required Uri httpAddress,
    HttpClient? httpClient,
  }) : _vmService = vmService,
       _writer = HttpDevFSWriter(
         fsName: fsName,
         httpAddress: httpAddress,
         httpClient: httpClient,
       );

  final VmService _vmService;
  final HttpDevFSWriter _writer;
  final String fsName;

  Uri? _baseUri;
  Uri? get baseUri => _baseUri;

  /// Registers the filesystem with the VM. If a stale filesystem with
  /// the same name exists, destroys and recreates.
  Future<Uri> create() async {
    try {
      _baseUri = await _create();
    } on RPCError catch (e) {
      // kFileSystemAlreadyExists (1001).
      if (e.code != 1001) rethrow;
      await destroy();
      _baseUri = await _create();
    }
    return _baseUri!;
  }

  Future<Uri> _create() async {
    final response = await _vmService.callServiceExtension(
      '_createDevFS',
      args: {'fsName': fsName},
    );
    final uri = response.json?['uri'] as String?;
    if (uri == null) {
      throw DevFSException('_createDevFS returned no uri: ${response.json}');
    }
    return Uri.parse(uri);
  }

  Future<void> destroy() async {
    await _vmService.callServiceExtension(
      '_deleteDevFS',
      args: {'fsName': fsName},
    );
    _baseUri = null;
  }

  /// Uploads [entries] (URIs relative to [baseUri]) to the VM.
  Future<void> writeFiles(Map<Uri, DevFSContent> entries) async {
    final base = _baseUri;
    if (base == null) {
      throw StateError('DevFS.create() has not been called.');
    }
    await _writer.write(entries, base);
  }
}

// The scripts below are adapted from the DDC library bundle bootstrap in
// flutter_tools (packages/flutter_tools/lib/src/web/bootstrap.dart),
// Copyright 2014 The Flutter Authors, under a BSD-style license.
//
// They differ in two ways. Every URL resolves against the directory the entry
// script was loaded from, so an app works below a path prefix. And the module
// list is part of the main module, so no debug service has to supply it.

import 'dart:convert';

import 'ddc_output.dart';

/// File names of the scripts written next to the compiled modules.
abstract final class DdcBootstrapFiles {
  static const moduleLoader = 'ddc_module_loader.js';
  static const stackTraceMapper = 'dart_stack_trace_mapper.js';
  static const dartSdk = 'dart_sdk.js';
  static const mainModule = 'main_module.bootstrap.js';
  static const onLoadEnd = 'on_load_end_bootstrap.js';
  static const reloadClient = 'dart_hot_reload.js';
  static const reloadedSources = 'reloaded_sources.json';
}

/// The path below the app root where `serverpod_jaspr` sends the events that
/// reload a page.
const reloadEventsPath = r'$serverpodReload';

/// The entry script a page loads to start the app.
///
/// It loads the DDC module loader, the stack trace mapper and the reload
/// client, then the Dart SDK and [DdcBootstrapFiles.mainModule], all from
/// the entry script's own directory.
String ddcEntryScript() {
  return r'''
(function () {
  const appRoot = (function () {
    const url = document.currentScript.src;
    return url.substring(0, url.lastIndexOf('/') + 1);
  })();

  let policy = { createScriptURL: (src) => src };
  if (self.trustedTypes && self.trustedTypes.createPolicy) {
    policy = self.trustedTypes.createPolicy('dartDdcModuleUrl', policy);
  }

  if (!window.$dartCreateScript) {
    window.$dartCreateScript = (function () {
      const scripts = Array.from(document.getElementsByTagName('script'));
      let nonce;
      scripts.some((script) => (nonce = script.nonce || script.getAttribute('nonce')));
      return function () {
        const script = document.createElement('script');
        if (nonce) script.nonce = nonce;
        return script;
      };
    })();
  }

  function loadScript(relativeUrl) {
    return new Promise(function (resolve, reject) {
      const script = self.$dartCreateScript();
      script.onload = resolve;
      script.onerror = reject;
      script.src = policy.createScriptURL(appRoot + relativeUrl);
      document.head.appendChild(script);
    });
  }

  const prerequisites = [
    { src: '__MODULE_LOADER__', id: 'ddc_module_loader \x00' },
    { src: '__STACK_TRACE_MAPPER__', id: 'dart_stack_trace_mapper \x00' },
    { src: '__RELOAD_CLIENT__', id: 'dart_hot_reload \x00' },
  ];

  Promise.all(prerequisites.map((script) => loadScript(script.src))).then(function () {
    window.$dartLoader.rootDirectories.push(appRoot);
    const scripts = [
      { src: '__DART_SDK__', id: 'dart_sdk' },
      { src: '__MAIN_MODULE__', id: 'data-main' },
    ];

    const loadConfig = new window.$dartLoader.LoadConfiguration();
    loadConfig.root = appRoot.substring(0, appRoot.length - 1);
    loadConfig.bootstrapScript = scripts[scripts.length - 1];
    loadConfig.loadScriptFn = function (loader) {
      loader.addScriptsToQueue(scripts, null);
      loader.loadEnqueuedModules();
    };
    loadConfig.ddcEventForLoadStart = /* LOAD_ALL_MODULES_START */ 1;
    loadConfig.ddcEventForLoadedOk = /* LOAD_ALL_MODULES_END_OK */ 2;
    loadConfig.ddcEventForLoadedError = /* LOAD_ALL_MODULES_END_ERROR */ 3;

    const loader = new window.$dartLoader.DDCLoader(loadConfig);
    prerequisites.forEach((script) => loader.registerScript(script));
    window.$dartLoader.loadConfig = loadConfig;
    window.$dartLoader.loader = loader;
    loader.nextAttempt();

    if (window.$dartStackTraceUtility && !window.$dartStackTraceUtility.ready) {
      window.$dartStackTraceUtility.ready = true;
      window.$dartStackTraceUtility.setSourceMapProvider(function (url) {
        url = url.replace(appRoot, '');
        if (url == '__DART_SDK__') {
          return dartDevEmbedder.debugger.getSourceMap('dart_sdk');
        }
        return dartDevEmbedder.debugger.getSourceMap(url.replace('.lib.js', ''));
      });
    }
  });
})();
'''
      .replaceAll('__MODULE_LOADER__', DdcBootstrapFiles.moduleLoader)
      .replaceAll('__STACK_TRACE_MAPPER__', DdcBootstrapFiles.stackTraceMapper)
      .replaceAll('__RELOAD_CLIENT__', DdcBootstrapFiles.reloadClient)
      .replaceAll('__DART_SDK__', DdcBootstrapFiles.dartSdk)
      .replaceAll('__MAIN_MODULE__', DdcBootstrapFiles.mainModule);
}

/// The main module, which queues every module of the app and runs `main` in
/// [entrypointLibrary] once they have loaded.
///
/// [generation] is the hot reload generation the modules are at. The reload
/// client applies only newer deltas to a page loaded from this script.
String ddcMainModuleScript({
  required String entrypointLibrary,
  required Iterable<DdcModule> modules,
  int generation = 0,
}) {
  final scripts = [
    for (final module in modules)
      {'src': module.path, 'id': module.metadata.name},
  ];
  return '''
/* ENTRYPOINT_EXTENTION_MARKER */

(function () {
  const appName = ${jsonEncode(entrypointLibrary)};
  window.\$dartLoadedGeneration = $generation;

  dartDevEmbedder.debugger.registerDevtoolsFormatter();

  window.\$dartLoader.loadConfig.bootstrapScript = {
    src: '${DdcBootstrapFiles.onLoadEnd}',
    id: '${DdcBootstrapFiles.onLoadEnd}',
  };
  window.\$dartLoader.loadConfig.tryLoadBootstrapScript = true;

  // Called by ${DdcBootstrapFiles.onLoadEnd} once every module has loaded.
  window.\$onLoadEndCallback = function () {
    const child = {};
    child.main = function () {
      dartDevEmbedder.runMain(appName, { nativeNonNullAsserts: true });
    };
    /* MAIN_EXTENSION_MARKER */
    child.main();
  };

  const scripts = ${jsonEncode(scripts)};
  window.\$dartLoader.loadConfig.loadScriptFn = function (loader) {
    loader.addScriptsToQueue(scripts, null);
    loader.loadEnqueuedModules();
  };
  window.\$dartLoader.loader.nextAttempt();
})();
''';
}

/// The script that runs `main` once the main module has queued every module.
String ddcOnLoadEndScript() => r'window.$onLoadEndCallback();';

/// The reload client, loaded by [ddcEntryScript].
///
/// It defines `$dartHotReload()` for whatever tells the page that new code
/// was compiled. The function fetches [DdcBootstrapFiles.reloadedSources],
/// takes the deltas newer than the generation the page has, keeping the
/// latest file of each module, and loads them with
/// `dartDevEmbedder.hotReload`. Its promise resolves once the new code is in
/// place, with the number of reloaded libraries, and rejects if the reload
/// fails. Calls run one at a time, in order. A page older than the last
/// restart loads again instead.
///
/// It also listens for the events at [reloadEventsPath] below the app root.
/// An event with `restart` loads the page again. Any other event patches the
/// page with Jaspr's `ext.jaspr.reload_html` service extension, after
/// loading the new code and rebuilding with `ext.jaspr.reassemble` when the
/// event has `hotReload`. A step that fails loads the page again. The client
/// announces a debug service to `dart:developer`, so that Jaspr's service
/// extensions register at all.
String ddcReloadClientScript() {
  return r'''
(function () {
  // DDC's registerExtension keeps a handler only once a debug service has set
  // these hooks, as DWDS's client does. See developer_patch.dart in the SDK's
  // lib/_internal/js_dev_runtime.
  globalThis.$dwdsVersion ??= 'serverpod';
  globalThis.$emitRegisterEvent ??= function () {};

  const appRoot = (function () {
    const url = document.currentScript.src;
    return url.substring(0, url.lastIndexOf('/') + 1);
  })();

  let pending = Promise.resolve();

  async function hotReload() {
    const response = await fetch(appRoot + '__RELOADED_SOURCES__', { cache: 'no-store' });
    if (!response.ok) {
      throw new Error('Failed to fetch __RELOADED_SOURCES__: ' + response.status);
    }
    const manifest = await response.json();
    const loaded = globalThis.$dartLoadedGeneration ?? 0;
    if (loaded < manifest.since) {
      location.reload();
      return new Promise(() => {});
    }
    const latest = new Map();
    for (const entry of manifest.entries) {
      if (entry.generation > loaded) latest.set(entry.module, entry);
    }
    const files = [];
    const libraries = [];
    for (const entry of latest.values()) {
      files.push(new URL(entry.src, appRoot).toString());
      libraries.push(...entry.libraries);
    }
    if (files.length > 0) await dartDevEmbedder.hotReload(files, libraries);
    globalThis.$dartLoadedGeneration = manifest.generation;
    return libraries.length;
  }

  globalThis.$dartHotReload = function () {
    const result = pending.then(hotReload);
    pending = result.catch(() => {});
    return result;
  };

  const invoke = (method) => dartDevEmbedder.debugger.invokeExtension(method, '{}');
  let updating = Promise.resolve();

  async function update(event) {
    if (event.restart) {
      location.reload();
      return;
    }
    if (event.hotReload) {
      await globalThis.$dartHotReload();
      await invoke('ext.jaspr.reassemble');
    }
    await invoke('ext.jaspr.reload_html');
  }

  new EventSource(appRoot + '__RELOAD_EVENTS__').onmessage = function (message) {
    const event = JSON.parse(message.data);
    updating = updating.then(() => update(event)).catch(() => location.reload());
  };
})();
'''
      .replaceAll('__RELOADED_SOURCES__', DdcBootstrapFiles.reloadedSources)
      .replaceAll('__RELOAD_EVENTS__', reloadEventsPath);
}

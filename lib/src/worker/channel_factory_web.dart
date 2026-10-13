/// The browser channel factory: a Web Worker per channel, all sharing one
/// compiled module per asset base.
///
/// Internal to the package; nothing here is exported.
library;

import 'dart:js_interop';

import 'package:dart_monty_core/src/worker/asset_base.dart';
import 'package:dart_monty_core/src/worker/spawn_handle.dart';
import 'package:dart_monty_core/src/worker/worker_channel.dart';

final _caches = <String, WasmModuleCache>{};
Future<String>? _found;

/// Starts a Web Worker from the assets under [workerLocation], or under the
/// base [resolveAssetBase] finds (once per page) when it is null.
///
/// Cancelling before the Worker greets terminates it.
SpawnHandle openChannel({String? workerLocation}) =>
    PendingSpawn((cancelled) async {
      final base = workerLocation ?? await (_found ??= _findBase());
      final cache = _caches.putIfAbsent(
        base,
        () => WasmModuleCache(workerWasmUrl(base)),
      );

      return WorkerChannel.spawn(
        cache,
        workerUrl: workerScriptUrl(base),
        cancelled: cancelled,
      );
    });

/// `navigator.hardwareConcurrency`, or 4 when the browser hides it.
int defaultMaxProcesses() {
  final count = _hardwareConcurrency;

  return count == null || count < 1 ? 4 : count;
}

Future<String> _findBase() async {
  try {
    return await resolveAssetBase(_isScript);
  } on Object {
    // A failed search is not cached: a later start tries again.
    _found = null;
    rethrow;
  }
}

/// Whether [url] answers with something other than a page: a dev server
/// that falls back to index.html for unknown paths must not count.
Future<bool> _isScript(String url) async {
  try {
    final response = await _fetch(url.toJS).toDart;
    final type = response.headers.get('content-type'.toJS)?.toDart ?? '';

    return response.ok && !type.startsWith('text/html');
  } on Object {
    return false;
  }
}

@JS('navigator.hardwareConcurrency')
external int? get _hardwareConcurrency;

@JS('fetch')
external JSPromise<_Response> _fetch(JSString url);

extension type const _Response._(JSObject _) implements JSObject {
  external bool get ok;
  external _Headers get headers;
}

extension type const _Headers._(JSObject _) implements JSObject {
  external JSString? get(JSString name);
}

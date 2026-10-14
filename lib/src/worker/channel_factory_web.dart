/// The browser channel factory: a Web Worker per channel, all sharing one
/// compiled module per asset base.
///
/// Internal to the package; nothing here is exported.
library;

import 'dart:js_interop';

import 'package:dart_monty_core/src/worker/asset_base.dart';
import 'package:dart_monty_core/src/worker/monty_channel.dart';
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

/// Null: a Web Worker has no process id.
int? channelPid(MontyChannel channel) => null;

/// `navigator.hardwareConcurrency`, or 4 when the browser hides it.
int defaultMaxProcesses() {
  final count = _hardwareConcurrency;

  return count == null || count < 1 ? 4 : count;
}

Future<String> _findBase() async {
  try {
    return await resolveAssetBase(workerScriptServed);
  } on Object {
    // A failed search is not cached: a later start tries again.
    _found = null;
    rethrow;
  }
}

@JS('navigator.hardwareConcurrency')
external int? get _hardwareConcurrency;

/// The browser [MontyChannel]: one Web Worker per channel, every Worker
/// instantiating one `WebAssembly.Module` the page compiled once.
///
/// The Worker is `lib/assets/dart_monty_core_worker.js`, running
/// `lib/assets/dart_monty_core_worker.wasm`. Turn semantics live in
/// [WorkerConnection]; this file only binds them to `dart:js_interop`.
///
/// Internal to the package; nothing here is exported.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/worker_connection.dart';
import 'package:meta/meta.dart';

/// A [MontyChannel] over one Web Worker.
final class WorkerChannel implements MontyChannel {
  const WorkerChannel._(this._worker, this._connection);

  /// The default Worker script URL, resolved against the page.
  static const String defaultWorkerUrl = 'dart_monty_core_worker.js';

  final _Worker _worker;
  final WorkerConnection _connection;

  /// Starts a Worker from [workerUrl], posts it [cache]'s module and waits
  /// for it to instantiate and run the JSPI probe.
  ///
  /// [forceNoJspi] skips the probe, so the Worker dispatches directly; tests
  /// use it to keep the fallback path green on a browser with JSPI.
  ///
  /// When [cancelled] completes before the Worker greets, the Worker is
  /// terminated and the spawn fails with [CrashCause.killed]: a Worker that
  /// loads but never answers would otherwise wait forever.
  ///
  /// Throws [MontyCrashedError] if the Worker cannot start
  /// ([CrashCause.vanished]) or speaks another protocol version
  /// ([CrashCause.fatal]).
  static Future<WorkerChannel> spawn(
    WasmModuleCache cache, {
    String workerUrl = defaultWorkerUrl,
    bool forceNoJspi = false,
    Future<void>? cancelled,
  }) async {
    // A cancel that lands after this is handled at the greeting below.
    final module = await _moduleUnlessCancelled(cache, cancelled);
    final worker = _Worker(workerUrl.toJS);
    final hello = Completer<WorkerMessage>();
    void first(WorkerMessage m) {
      if (!hello.isCompleted) hello.complete(m);
    }

    if (cancelled != null) {
      unawaited(_abandonOnCancel(cancelled, worker, hello));
    }
    worker
      ..onmessage = ((_MessageEvent e) => first(_read(e))).toJS
      ..onerror = ((_ErrorEvent e) => first(
        workerFailure(e.message ?? 'Worker $workerUrl failed to load'),
      )).toJS
      ..postMessage(_Start(module: module, noJspi: forceNoJspi));
    final connection = WorkerConnection.accept(
      _WorkerPort(worker),
      await hello.future,
    );
    worker
      ..onmessage = ((_MessageEvent e) => connection.onMessage(_read(e))).toJS
      ..onerror = ((_ErrorEvent e) {
        e.preventDefault();
        connection.onWorkerError(e.message ?? 'Worker error');
      }).toJS;

    return WorkerChannel._(worker, connection);
  }

  /// Whether `dmw_dispatch` runs under JSPI. The probe's result, exposed for
  /// tests and the browser gate.
  bool get jspi => _connection.jspi;

  /// `dmw_protocol_version()`, already checked against the driver's.
  int get protocol => _connection.protocol;

  @override
  bool get isAlive => _connection.isAlive;

  @override
  Future<pb.ChildEvent> turn(
    pb.ParentRequest request, {
    PrintHandler? onPrint,
  }) => _connection.turn(request, onPrint: onPrint);

  @override
  Future<void> close() async {
    await _connection.close();
    _detach();
  }

  @override
  void kill() {
    _connection.kill();
    _detach();
  }

  void _detach() {
    _worker
      ..onmessage = null
      ..onerror = null;
  }
}

/// [cache]'s module, unless [cancelled] completes first: then
/// [MontyCrashedError] ([CrashCause.killed]).
Future<JSObject> _moduleUnlessCancelled(
  WasmModuleCache cache,
  Future<void>? cancelled,
) async {
  if (cancelled == null) return cache.module;
  final module = await Future.any([cache.module, _nullOnceDone(cancelled)]);

  return module ?? (throw _cancelledError());
}

/// Null once [done] completes: the cancel's side of a race with the module.
Future<JSObject?> _nullOnceDone(Future<void> done) async {
  await done;

  return null;
}

/// Terminates [worker] and fails [hello] if [cancelled] completes before
/// the Worker greets.
Future<void> _abandonOnCancel(
  Future<void> cancelled,
  _Worker worker,
  Completer<WorkerMessage> hello,
) async {
  await cancelled;
  if (hello.isCompleted) return;
  worker
    ..onmessage = null
    ..onerror = null
    ..terminate();
  hello.completeError(_cancelledError(), StackTrace.current);
}

/// Whether [url] serves something other than an HTML page: a dev server
/// that answers unknown paths with index.html must not count as having it.
Future<bool> workerScriptServed(String url) async {
  try {
    final response = await _fetch(url.toJS).toDart;
    final type = response.headers.get('content-type'.toJS)?.toDart ?? '';

    return response.ok && !type.startsWith('text/html');
  } on Object {
    return false;
  }
}

MontyCrashedError _cancelledError() => crashedError(
  CrashCause.killed,
  detail: 'the Worker start was cancelled',
);

/// The page-lifetime compiled module: fetched and compiled once, lazily, then
/// posted to every Worker [WorkerChannel.spawn] starts.
final class WasmModuleCache {
  /// Creates a cache for the module at [wasmUrl], resolved against the page.
  WasmModuleCache(this.wasmUrl)
    : _module = OnceAsync(() => _compileModule(wasmUrl));

  /// Where the module is fetched from.
  final String wasmUrl;

  final OnceAsync<JSObject> _module;

  /// The compiled `WebAssembly.Module`. A failed compile is not cached, so a
  /// later call retries.
  Future<JSObject> get module => _module.value;

  /// How many times the module was compiled: 1 once [module] has completed.
  @visibleForTesting
  int get compileCount => _module.runs;
}

/// Fetches and compiles the module at [wasmUrl].
Future<JSObject> _compileModule(String wasmUrl) async {
  final response = await _fetch(wasmUrl.toJS).toDart;
  if (!response.ok) {
    throw StateError('fetch $wasmUrl: HTTP ${response.status}');
  }
  final type = response.headers.get('content-type'.toJS)?.toDart ?? '';
  // compileStreaming refuses any other MIME type; a server that labels the
  // module wrongly still gets a (non-streaming) compile.
  if (type.startsWith('application/wasm')) {
    return _compileStreaming(response).toDart;
  }
  final buffer = await response.arrayBuffer().toDart;

  return _compileBytes(buffer).toDart;
}

final class _WorkerPort implements WorkerPort {
  const _WorkerPort(this._worker);

  final _Worker _worker;

  @override
  void post(Uint8List frame) {
    // Copied, not transferred: dart2wasm's `toJS` copies anyway, and a
    // request frame is small next to the turn it starts.
    _worker.postMessage(frame.toJS);
  }

  @override
  void terminate() => _worker.terminate();
}

@JS('fetch')
external JSPromise<_Response> _fetch(JSString url);

@JS('WebAssembly.compileStreaming')
external JSPromise<JSObject> _compileStreaming(_Response source);

@JS('WebAssembly.compile')
external JSPromise<JSObject> _compileBytes(JSArrayBuffer bytes);

extension type const _Response._(JSObject _) implements JSObject {
  external bool get ok;
  external int get status;
  external _Headers get headers;
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

extension type const _Headers._(JSObject _) implements JSObject {
  external JSString? get(JSString name);
}

@JS('Worker')
extension type const _Worker._(JSObject _) implements JSObject {
  external factory _Worker(JSString url);
  external void postMessage(JSAny? message);
  external void terminate();
  external JSFunction? get onmessage;
  external set onmessage(JSFunction? handler);
  external JSFunction? get onerror;
  external set onerror(JSFunction? handler);
}

extension type const _MessageEvent._(JSObject _) implements JSObject {
  external _Reply? get data;
}

/// A Worker message as Dart values.
WorkerMessage _read(_MessageEvent e) {
  final r = e.data;

  return (
    ready: r?.ready,
    error: r?.error,
    jspi: r?.jspi,
    protocol: r?.protocol,
    events: r?.events?.toDart,
    outcome: r?.outcome,
    trap: r?.trap,
  );
}

/// An `ErrorEvent`, or the plain `Event` a Worker that failed to load fires,
/// which has no `message`.
extension type const _ErrorEvent._(JSObject _) implements JSObject {
  external String? get message;
  external void preventDefault();
}

extension type const _Start._(JSObject _) implements JSObject {
  external factory _Start({JSObject module, bool noJspi});
}

/// Any message the Worker posts; see the protocol in the Worker script.
extension type const _Reply._(JSObject _) implements JSObject {
  external bool? get ready;
  external bool? get jspi;
  external int? get protocol;
  external String? get error;
  external JSUint8Array? get events;
  external int? get outcome;
  external String? get trap;
}

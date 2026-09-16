import 'dart:typed_data';

import 'package:dart_monty_core/src/ffi/native_isolate_bindings.dart';
import 'package:dart_monty_core/src/ffi/native_isolate_bindings_impl.dart';
import 'package:dart_monty_core/src/platform/monty_future_capable.dart';
import 'package:dart_monty_core/src/platform/monty_limits.dart';
import 'package:dart_monty_core/src/platform/monty_platform.dart';
import 'package:dart_monty_core/src/platform/monty_progress.dart';
import 'package:dart_monty_core/src/platform/monty_result.dart';
import 'package:dart_monty_core/src/platform/monty_snapshot_capable.dart';
import 'package:dart_monty_core/src/platform/monty_state_mixin.dart';

/// Native Isolate implementation of [MontyPlatform].
///
/// Uses a [NativeIsolateBindings] abstraction to call into a background Isolate
/// that runs the native FFI. Manages a state machine: idle -> active ->
/// disposed.
///
/// ## INTENTIONALLY PRESENT AND NOT CURRENTLY SELECTED — do not delete
///
/// No application factory returns this class. `createPlatformMonty()` returns
/// `MontyFfi` (monty_factory_native.dart:8), and the REPL path builds
/// `FfiReplBindings` (repl_factory_native.dart:7). Static analysis will
/// therefore report this file, and the two `native_isolate_bindings*.dart`
/// files it is the sole importer of, as unused — `dcm check-unused-code`
/// does exactly that. THAT REPORT IS NOT A LICENCE TO REMOVE THEM. It was
/// acted on once, in 2026-09, and the deletion was wrong.
///
/// WHAT IT IS FOR. `MontyFfi` returns Futures but performs the synchronous
/// FFI call on the CALLING isolate (ffi_core_bindings.dart:73). This backend
/// runs that same implementation inside a worker — the worker constructs
/// `MontyFfi.withCore` at native_isolate_bindings_impl.dart:156 — so native
/// execution does not block the caller. That matters most for a Flutter UI
/// isolate; docs/reference/execution-model.md:83 states it directly:
/// "Running the sandbox in an isolate is still worthwhile to keep work off
/// the Flutter UI thread."
///
/// WHAT IT IS NOT. The same document is equally direct that this is not a
/// safety mechanism. Isolates share one OS process, so a native abort takes
/// the host down with them (:75), and an isolate blocked in a synchronous FFI
/// call cannot be killed, because `Isolate.kill` only lands at a Dart
/// safepoint (:81). It is a concurrency boundary, not a fault boundary.
///
/// WHAT WIRING IT UP WOULD TAKE, so the next person does not assume a factory
/// branch is enough:
///   * this class inherits the throwing [MontyPlatform] defaults for
///     compileCode, type checking, precompiled execution, typed exceptions,
///     not-found and name-lookup responses, which `MontyFfi` gets from
///     `BaseMontyPlatform`. The request protocol and worker dispatch need
///     extending before the two are interchangeable.
///   * `Monty.run` and `MontyRepl` go through `ReplBindings`, not through a
///     `MontyPlatform` (monty.dart:73, monty_repl.dart:116). Selecting this
///     backend for them needs a REPL worker adapter, not just a new factory.
///
/// ```dart
/// final monty = MontyNative();
/// await monty.initialize();
/// final result = await monty.run('2 + 2');
/// print(result.value); // 4
/// await monty.dispose();
/// ```
class MontyNative extends MontyPlatform
    with MontyStateMixin
    implements MontySnapshotCapable, MontyFutureCapable {
  /// Creates a [MontyNative] with optional [bindings].
  ///
  /// Defaults to [NativeIsolateBindingsImpl] when omitted.
  MontyNative({NativeIsolateBindings? bindings})
    : _bindings =
          bindings ?? NativeIsolateBindingsImpl(); // coverage:ignore-line

  final NativeIsolateBindings _bindings;
  bool _initialized = false;

  @override
  String get backendName => 'MontyNative';

  /// Initializes the background Isolate.
  ///
  /// Must be called before any execution methods. Initialization is
  /// idempotent — subsequent calls return immediately.
  ///
  /// Throws [StateError] if the Isolate fails to start.
  Future<void> initialize() async {
    if (_initialized) return;
    final ok = await _bindings.init();
    if (!ok) {
      throw StateError('Failed to initialize native Isolate');
    }
    _initialized = true;
  }

  @override
  Future<MontyResult> run(
    String code, {
    MontyLimits? limits,
    String? scriptName,
  }) async {
    assertNotDisposed('run');
    assertIdle('run');
    markActive();
    try {
      await _ensureInitialized();

      return await _bindings.run(code, limits: limits, scriptName: scriptName);
    } finally {
      markIdle();
    }
  }

  @override
  Future<MontyProgress> start(
    String code, {
    List<String>? externalFunctions,
    MontyLimits? limits,
    String? scriptName,
  }) async {
    assertNotDisposed('start');
    assertIdle('start');
    markActive();
    try {
      await _ensureInitialized();

      final progress = await _bindings.start(
        code,
        externalFunctions: externalFunctions,
        limits: limits,
        scriptName: scriptName,
      );

      return _handleProgress(progress);
    } catch (e) {
      markIdle();
      rethrow;
    }
  }

  @override
  Future<MontyProgress> resume(Object? returnValue) {
    assertNotDisposed('resume');
    assertActive('resume');

    return _safeBindingsCall(() => _bindings.resume(returnValue));
  }

  @override
  Future<MontyProgress> resumeWithError(String errorMessage) {
    assertNotDisposed('resumeWithError');
    assertActive('resumeWithError');

    return _safeBindingsCall(() => _bindings.resumeWithError(errorMessage));
  }

  @override
  Future<MontyProgress> resumeAsFuture() {
    assertNotDisposed('resumeAsFuture');
    assertActive('resumeAsFuture');

    return _safeBindingsCall(_bindings.resumeAsFuture);
  }

  @override
  Future<MontyProgress> resolveFutures(
    Map<int, Object?> results, {
    Map<int, String>? errors,
  }) {
    assertNotDisposed('resolveFutures');
    assertActive('resolveFutures');

    return _safeBindingsCall(
      () => _bindings.resolveFutures(results, errors: errors),
    );
  }

  @override
  Future<Uint8List> snapshot() {
    assertNotDisposed('snapshot');
    assertActive('snapshot');

    return _bindings.snapshot();
  }

  @override
  Future<MontyPlatform> restore(Uint8List data) async {
    assertNotDisposed('restore');
    assertIdle('restore');

    await _bindings.restore(data);

    return MontyNative(bindings: _bindings)
      .._initialized = _initialized
      ..markActive();
  }

  @override
  Future<void> dispose() async {
    if (isDisposed) return;

    if (_initialized) {
      await _bindings.dispose();
    }
    markDisposed();
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  Future<void> _ensureInitialized() async {
    if (!_initialized) {
      await initialize();
    }
  }

  /// Calls [fn] and handles progress. If [fn] throws, marks idle
  /// (execution is over) and rethrows.
  Future<MontyProgress> _safeBindingsCall(
    Future<MontyProgress> Function() fn,
  ) async {
    try {
      final progress = await fn();

      return _handleProgress(progress);
    } catch (e) {
      markIdle();
      rethrow;
    }
  }

  MontyProgress _handleProgress(MontyProgress progress) {
    switch (progress) {
      case MontyComplete():
        markIdle();

        return progress;

      case MontyPending():
      case MontyOsCall():
      case MontyResolveFutures():
      case MontyNameLookup():
        markActive();

        return progress;
    }
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_monty_core/src/externals.dart';
import 'package:dart_monty_core/src/platform/core_bindings.dart';
import 'package:dart_monty_core/src/platform/inputs_encoder.dart'
    as inputs_encoder;
import 'package:dart_monty_core/src/platform/monty_error.dart';
import 'package:dart_monty_core/src/platform/monty_exception.dart';
import 'package:dart_monty_core/src/platform/monty_progress.dart';
import 'package:dart_monty_core/src/platform/monty_resource_usage.dart';
import 'package:dart_monty_core/src/platform/monty_result.dart';
import 'package:dart_monty_core/src/platform/monty_stack_frame.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/repl/repl_bindings.dart';
import 'package:dart_monty_core/src/repl/repl_factory.dart' as repl_factory;

const _replZeroUsage = MontyResourceUsage(
  memoryBytesUsed: 0,
  timeElapsedMs: 0,
  stackDepthUsed: 0,
);

MontyComplete _buildCompleteProgress(CoreProgressResult p) => MontyComplete(
  result: MontyResult(
    value: MontyValue.fromJson(p.value),
    error: _buildReplError(p.error, p.excType, p.traceback),
    usage: p.usage ?? _replZeroUsage,
    printOutput: p.printOutput,
  ),
);

MontyPending _buildPendingProgress(CoreProgressResult p) => MontyPending(
  functionName: p.functionName ?? '',
  args: _parseReplArgList(p.args),
  kwargs: _parseReplKwargMap(p.kwargs),
  callId: p.callId ?? 0,
  methodCall: p.methodCall ?? false,
);

MontyOsCall _buildOsCallProgress(CoreProgressResult p) => MontyOsCall(
  operationName: p.functionName ?? '',
  args: _parseReplArgList(p.args),
  kwargs: _parseReplKwargMap(p.kwargs),
  callId: p.callId ?? 0,
);

MontyException? _buildReplError(
  String? error,
  String? excType,
  List<Object?>? traceback,
) {
  if (error == null) return null;

  return MontyException(
    message: error,
    excType: excType,
    traceback: MontyStackFrame.listFromJson(traceback ?? const []),
  );
}

Never _throwReplError({
  required String message,
  String? excType,
  List<Object?>? traceback,
}) {
  if (excType == 'MemoryLimitExceeded') throw MontyResourceError(message);
  final exception = MontyException(
    message: message,
    excType: excType,
    traceback: MontyStackFrame.listFromJson(traceback ?? const []),
  );
  throw MontyScriptError(message, excType: excType, exception: exception);
}

List<MontyValue> _parseReplArgList(List<Object?>? args) =>
    args != null ? args.map(MontyValue.fromJson).toList() : const [];

Map<String, MontyValue>? _parseReplKwargMap(Map<String, Object?>? kwargs) =>
    kwargs?.map((k, v) => MapEntry(k, MontyValue.fromJson(v)));

/// A stateful REPL session backed by the Monty Rust interpreter.
///
/// Heap, globals, functions, and classes all persist across [feedRun] calls
/// without serialization — the underlying Rust REPL handle is reused between
/// calls, not recreated.
///
/// ```dart
/// final repl = MontyRepl();
/// await repl.feedRun('x = 42');
/// final result = await repl.feedRun('x + 1');
/// print(result.value); // MontyInt(43)
/// await repl.dispose();
/// ```
class MontyRepl {
  /// Creates a [MontyRepl] with auto-detected backend (FFI or WASM).
  ///
  /// [preamble] is Python code fed into the REPL before any user calls.
  MontyRepl({
    String? scriptName,
    String? preamble,
  }) : _bindings = repl_factory.createReplBindings(),
       _scriptName = scriptName,
       _preamble = preamble;

  /// Creates a [MontyRepl] with explicit [bindings].
  MontyRepl.withBindings({
    required ReplBindings bindings,
    String? scriptName,
    String? preamble,
  }) : _bindings = bindings,
       _scriptName = scriptName,
       _preamble = preamble;

  ReplBindings _bindings;
  final String? _scriptName;
  final String? _preamble;
  bool _created = false;
  bool _disposed = false;
  bool _pending = false;

  /// Script name used as the filename in tracebacks and error messages.
  ///
  /// Returns `null` when the REPL was constructed without one, in which
  /// case the engine falls back to its default (`'main.py'`).
  String? get scriptName => _scriptName;

  // ---------------------------------------------------------------------------
  // Synchronous feed
  // ---------------------------------------------------------------------------

  /// Feeds [code] and runs to completion.
  ///
  /// State (variables, functions, classes, heap objects) persists across
  /// calls. If [externalFunctions] are provided, Python can call them
  /// like regular functions; each call is dispatched and the result
  /// resumed automatically.
  ///
  /// Python-level exceptions land in [MontyResult.error] rather than
  /// throwing — the REPL survives and can keep running. Binding-level
  /// failures (handle invalidated, resource limits) still throw.
  ///
  /// [inputs] injects per-invocation Python variables before [code]
  /// runs. Each key becomes a Python variable; values are converted to
  /// Python literals.
  ///
  /// [externalFunctions] is a `Map<String, MontyCallback>` here —
  /// distinct from the `List<String>` form on [feedStart], where the
  /// iterative path drives dispatch from Dart and only the names cross
  /// the boundary.
  ///
  /// [printCallback], if provided, is invoked once per call with the
  /// captured `print()` output before the result returns. The first
  /// argument is always `'stdout'` (matches Python's
  /// `Literal['stdout']`). This is a batch callback — the entire
  /// captured output is delivered in a single call when execution
  /// completes; per-flush streaming is not currently supported. When
  /// the held code prints nothing, the callback is not invoked.
  Future<MontyResult> feedRun(
    String code, {
    Map<String, MontyCallback> externalFunctions = const {},
    Map<String, MontyCallback> externalAsyncFunctions = const {},
    OsCallHandler? osHandler,
    Map<String, Object?>? inputs,
    void Function(String stream, String text)? printCallback,
  }) async {
    _checkNotDisposed();
    await _ensureCreated();
    final overlap = externalFunctions.keys.toSet().intersection(
      externalAsyncFunctions.keys.toSet(),
    );
    if (overlap.isNotEmpty) {
      throw ArgumentError(
        'externalFunctions and externalAsyncFunctions must be disjoint; '
        'overlapping keys: $overlap',
      );
    }
    final effectiveCode = inputs != null && inputs.isNotEmpty
        ? '${inputs_encoder.inputsToCode(inputs)}\n$code'
        : code;

    // Always sync the Rust handle's ext_fn_names HashSet to this feed's
    // externalFunctions — including clearing it when empty. Without
    // this, names registered in a previous feed leak into the next
    // feed's NameLookup auto-resolve and surface as a confusing
    // "no handler registered" error instead of NameError.
    await _bindings.setExtFns([
      ...externalFunctions.keys,
      ...externalAsyncFunctions.keys,
    ]);

    try {
      if (externalFunctions.isEmpty &&
          externalAsyncFunctions.isEmpty &&
          osHandler == null) {
        // Fast path: no externalFunctions, use simple feedRun.
        final r = await _bindings.feedRun(effectiveCode);
        _pending = false;
        _emitPrintOutput(printCallback, r.printOutput);
        if (r.ok) {
          return MontyResult(
            value: MontyValue.fromJson(r.value),
            error: _buildReplError(r.error, r.excType, r.traceback),
            usage: r.usage ?? _replZeroUsage,
            printOutput: r.printOutput,
          );
        }
        _throwReplError(
          message: r.error ?? 'Unknown error',
          excType: r.excType,
          traceback: r.traceback,
        );
      }

      // Iterative path: drive the start/resume loop, dispatching
      // externalFunctions.
      final initial = _translateProgress(
        await _bindings.feedStart(effectiveCode),
      );

      final result = await _driveLoop(
        initial,
        externalFunctions,
        externalAsyncFunctions,
        osHandler,
      );
      _emitPrintOutput(printCallback, result.printOutput);

      return result;
    } on MontyScriptError catch (e) {
      return MontyResult(
        value: const MontyNone(),
        error: e.exception,
        usage: _replZeroUsage,
      );
    }
  }

  static void _emitPrintOutput(
    void Function(String stream, String text)? cb,
    String? text,
  ) {
    if (cb != null && text != null && text.isNotEmpty) {
      cb('stdout', text);
    }
  }

  // ---------------------------------------------------------------------------
  // Iterative feed (caller drives the loop)
  // ---------------------------------------------------------------------------

  /// Starts iterative execution of [code], pausing at each registered name.
  ///
  /// Register callback names in [externalFunctions]. When Python calls one,
  /// execution pauses and returns [MontyPending]. Use [resume] or
  /// [resumeWithError] to continue.
  ///
  /// [externalFunctions] is `List<String>` (names only) here, distinct from
  /// the `Map<String, MontyCallback>` form on [feedRun]. The list shape is
  /// intentional: the iterative path lets the caller drive dispatch, so
  /// only the name registry crosses the FFI/WASM boundary.
  Future<MontyProgress> feedStart(
    String code, {
    List<String>? externalFunctions,
  }) async {
    _checkNotDisposed();
    await _ensureCreated();
    if (externalFunctions != null && externalFunctions.isNotEmpty) {
      await _bindings.setExtFns(externalFunctions);
    }

    return _translateProgress(await _bindings.feedStart(code));
  }

  /// Resumes a paused execution with [returnValue].
  Future<MontyProgress> resume(Object? returnValue) async {
    _checkNotDisposed();
    final json = returnValue != null ? jsonEncode(returnValue) : 'null';

    return _translateProgress(await _bindings.resume(json));
  }

  /// Resumes a paused execution by raising [errorMessage] in Python.
  Future<MontyProgress> resumeWithError(String errorMessage) async {
    _checkNotDisposed();

    return _translateProgress(await _bindings.resumeWithError(errorMessage));
  }

  /// Resumes a paused OS call by signalling that the host does not handle
  /// [fnName]. Python raises `NameError: name '<fnName>' is not defined`.
  Future<MontyProgress> resumeNotFound(String fnName) async {
    _checkNotDisposed();

    return _translateProgress(await _bindings.resumeNotFound(fnName));
  }

  /// Resumes the paused REPL by promising a future for the pending call.
  ///
  /// Use this in place of [resume] when the host is going to deliver the
  /// pending call's result later via [resolveFutures]. The VM keeps
  /// running until it hits an `await`, then yields [MontyResolveFutures]
  /// listing the call IDs whose values it now needs.
  ///
  /// Throws [UnsupportedError] when the underlying bindings backend does
  /// not implement the futures path (currently the WASM backend).
  Future<MontyProgress> resumeAsFuture() async {
    _checkNotDisposed();

    return _translateProgress(await _bindings.resumeAsFuture());
  }

  /// Resolves the call IDs the VM is waiting on with [results] and
  /// optionally [errors], then continues execution.
  ///
  /// [results] maps each call ID to its resolved value; [errors] maps
  /// call IDs to error message strings (raised as `RuntimeError` in
  /// Python). The union of keys must cover every ID the engine listed
  /// in the preceding [MontyResolveFutures].
  ///
  /// Throws [UnsupportedError] when the bindings backend does not
  /// implement the futures path.
  Future<MontyProgress> resolveFutures(
    Map<int, Object?> results, {
    Map<int, String>? errors,
  }) async {
    _checkNotDisposed();
    final resultsJson = jsonEncode(
      results.map((k, v) => MapEntry(k.toString(), v)),
    );
    final errorsJson = errors != null
        ? jsonEncode(errors.map((k, v) => MapEntry(k.toString(), v)))
        : '{}';

    return _translateProgress(
      await _bindings.resolveFutures(resultsJson, errorsJson),
    );
  }

  // ---------------------------------------------------------------------------
  // Continuation detection
  // ---------------------------------------------------------------------------

  /// Returns whether [source] is syntactically complete for execution.
  ///
  /// Useful for building REPL UIs that show `>>>` vs `...` prompts.
  /// Dart-only — the upstream `pydantic_monty` Python package does not
  /// expose this helper; it wraps the engine's incomplete-input detector.
  Future<ReplContinuationMode> detectContinuation(String source) async {
    _checkNotDisposed();
    await _ensureCreated();
    final mode = await _bindings.detectContinuation(source);

    return switch (mode) {
      1 => ReplContinuationMode.incompleteImplicit,
      2 => ReplContinuationMode.incompleteBlock,
      _ => ReplContinuationMode.complete,
    };
  }

  // ---------------------------------------------------------------------------
  // Snapshot / restore
  // ---------------------------------------------------------------------------

  /// Serialises the REPL heap to postcard bytes.
  ///
  /// The bytes can be passed to [restore] to rehydrate an identical REPL.
  /// The REPL must not be mid-execution (no pending [feedStart]/[resume]
  /// loop in progress). Throws [StateError] if mid-execution.
  Future<Uint8List> snapshot() {
    _checkNotDisposed();
    _checkNotPending('snapshot');

    return _bindings.snapshot();
  }

  /// Restores the REPL from bytes produced by [snapshot].
  ///
  /// The current REPL handle is freed and replaced with a new one restored
  /// from [bytes]. Any in-flight operations must complete before calling
  /// this. Throws [StateError] if mid-execution.
  Future<void> restore(Uint8List bytes) {
    _checkNotDisposed();
    _checkNotPending('restore');

    return _bindings.restore(bytes);
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Wipes all persisted state. The next [feedRun]/[feedStart] call starts
  /// with empty globals.
  ///
  /// Disposes the underlying Rust handle and creates a fresh one. Throws
  /// [StateError] if the REPL is mid-execution (a `feedStart`/`resume`
  /// loop is paused) — await the loop to completion first.
  Future<void> clearState() async {
    _checkNotDisposed();
    _checkNotPending('clearState');
    await _bindings.dispose();
    _bindings = repl_factory.createReplBindings();
    _created = false;
  }

  /// Disposes the REPL session and frees native resources.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _bindings.dispose();
  }

  // ---------------------------------------------------------------------------
  // Private
  // ---------------------------------------------------------------------------

  Future<MontyResult> _driveLoop(
    MontyProgress initial,
    Map<String, MontyCallback> externalFunctions,
    Map<String, MontyCallback> externalAsyncFunctions,
    OsCallHandler? osHandler,
  ) async {
    // Per-call map of pending futures keyed by callId. Populated only for
    // callbacks registered in externalAsyncFunctions; drained by the
    // MontyResolveFutures branch.
    final pendingFutures = <int, Future<Object?>>{};

    var progress = initial;
    try {
      while (true) {
        switch (progress) {
          case MontyComplete(:final result):
            return result;
          case MontyPending(:final functionName, :final callId):
            final asyncCb = externalAsyncFunctions[functionName];
            final syncCb = externalFunctions[functionName];
            final cb = asyncCb ?? syncCb;
            if (cb == null) {
              progress = _translateProgress(
                await _bindings.resumeWithError(
                  'No handler registered for: $functionName',
                ),
              );
            } else if (asyncCb != null) {
              // Futures path: launch the callback unawaited, register the
              // future, and tell the engine to keep running until it hits an
              // `await`. The engine will surface MontyResolveFutures with
              // the call IDs it now needs values for.
              final cbArgs = progress.args.map((v) => v.dartValue).toList();
              final cbKwargs = progress.kwargs?.map(
                (k, v) => MapEntry(k, v.dartValue),
              );
              final fut = Future<Object?>(() => asyncCb(cbArgs, cbKwargs));
              pendingFutures[callId] = fut;
              // Suppress "unhandled async error" — errors are caught and
              // surfaced via the errors map during resolveFutures.
              _suppressFutureErrors(fut);
              progress = _translateProgress(await _bindings.resumeAsFuture());
            } else {
              try {
                final cbArgs = progress.args.map((v) => v.dartValue).toList();
                final cbKwargs = progress.kwargs?.map(
                  (k, v) => MapEntry(k, v.dartValue),
                );
                final res = await cb(cbArgs, cbKwargs);
                progress = _translateProgress(
                  await _bindings.resume(jsonEncode(res)),
                );
              } on Object catch (e) {
                progress = _translateProgress(
                  await _bindings.resumeWithError(e.toString()),
                );
              }
            }
          case MontyOsCall():
            progress = await _handleOsCall(progress, osHandler);
          case MontyResolveFutures(:final pendingCallIds):
            if (pendingFutures.isEmpty) {
              // No async callbacks were registered — nothing to resolve.
              // Resume with null so the engine can advance.
              progress = _translateProgress(await _bindings.resume('null'));
              break;
            }
            final results = <int, Object?>{};
            final errors = <int, String>{};
            for (final id in pendingCallIds) {
              final fut = pendingFutures.remove(id);
              if (fut == null) {
                errors[id] =
                    'No pending future for callId $id (engine/host out of sync)';
                continue;
              }
              try {
                results[id] = await fut;
              } on Object catch (e) {
                errors[id] = e.toString();
              }
            }
            progress = _translateProgress(
              await _bindings.resolveFutures(
                jsonEncode(
                  results.map((k, v) => MapEntry(k.toString(), v)),
                ),
                jsonEncode(
                  errors.map((k, v) => MapEntry(k.toString(), v)),
                ),
              ),
            );
          case MontyNameLookup():
            // The Rust handle auto-resolves NameLookup via ext_fn_names; this
            // branch only fires when the name was not registered. Signal
            // NameError back to Python.
            progress = _translateProgress(
              await _bindings.resumeNameLookupUndefined(),
            );
        }
      }
    } finally {
      // Drain any callbacks still pending if the loop exits through a
      // throw — guarantees no unhandled async errors leak out of the call.
      pendingFutures.values.forEach(_suppressFutureErrors);
      pendingFutures.clear();
    }
  }

  /// Catches and discards any error from [future] so that callbacks launched
  /// unawaited on the futures path do not surface as unhandled async errors.
  /// Errors are re-surfaced via the errors map during `resolveFutures`.
  static void _suppressFutureErrors(Future<Object?> future) {
    unawaited(future.catchError((Object _) => null));
  }

  MontyProgress _translateProgress(CoreProgressResult p) {
    switch (p.state) {
      case 'complete':
        _pending = false;

        return _buildCompleteProgress(p);
      case 'pending':
        _pending = true;

        return _buildPendingProgress(p);
      case 'os_call':
        _pending = true;

        return _buildOsCallProgress(p);
      case 'resolve_futures':
        _pending = true;

        return MontyResolveFutures(
          pendingCallIds: p.pendingCallIds ?? const [],
        );
      case 'error':
        _pending = false;
        _throwReplError(
          message: p.error ?? 'Unknown error',
          excType: p.excType,
          traceback: p.traceback,
        );
      default:
        throw StateError('Unknown progress state: ${p.state}');
    }
  }

  Future<MontyProgress> _handleOsCall(
    MontyOsCall call,
    OsCallHandler? handler,
  ) async {
    if (handler == null) {
      return _translateProgress(
        await _bindings.resumeWithError(
          'OS operations not available — no OsCallHandler configured',
        ),
      );
    }
    try {
      final args = call.args.map((v) => v.dartValue).toList();
      final kwargs = call.kwargs?.map((k, v) => MapEntry(k, v.dartValue));
      final result = await handler(call.operationName, args, kwargs);

      return _translateProgress(
        await _bindings.resume(jsonEncode(result)),
      );
    } on OsCallNotHandledException catch (e) {
      return _translateProgress(
        await _bindings.resumeNotFound(e.fnName ?? call.operationName),
      );
    } on OsCallException catch (e) {
      // The REPL bindings do not yet expose a typed exception path
      // (no monty_repl_resume_with_exception). Best-effort: prefix the
      // requested Python exception type into the message so it is
      // visible in Python tracebacks; the actual class surfaces as
      // RuntimeError until the binding is extended.
      final wireMessage = e.pythonExceptionType != null
          ? '${e.pythonExceptionType}: ${e.message}'
          : e.message;

      return _translateProgress(
        await _bindings.resumeWithError(wireMessage),
      );
    } on Object catch (e) {
      return _translateProgress(await _bindings.resumeWithError(e.toString()));
    }
  }

  Future<void> _ensureCreated() async {
    if (!_created) {
      await _bindings.create(scriptName: _scriptName);
      _created = true;
      final preamble = _preamble;
      if (preamble != null && preamble.isNotEmpty) {
        await _bindings.feedRun(preamble);
      }
    }
  }

  void _checkNotDisposed() {
    if (_disposed) throw StateError('MontyRepl has been disposed.');
  }

  void _checkNotPending(String op) {
    if (_pending) {
      throw StateError(
        'Cannot $op a MontyRepl that is mid-execution; '
        'await all feedStart/resume calls until they return MontyComplete.',
      );
    }
  }
}

/// Whether a source fragment is syntactically complete for REPL execution.
enum ReplContinuationMode {
  /// The snippet is complete and can be executed.
  complete,

  /// The snippet has unclosed brackets, parentheses, or strings.
  incompleteImplicit,

  /// The snippet opened an indented block and needs a trailing blank line.
  incompleteBlock,
}

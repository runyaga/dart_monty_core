import 'dart:convert';

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
  arguments: _parseReplArgList(p.arguments),
  kwargs: _parseReplKwargMap(p.kwargs),
  callId: p.callId ?? 0,
  methodCall: p.methodCall ?? false,
);

MontyOsCall _buildOsCallProgress(CoreProgressResult p) => MontyOsCall(
  operationName: p.functionName ?? '',
  arguments: _parseReplArgList(p.arguments),
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

Map<String, Object?> _replArgsToMap(
  List<MontyValue> positional,
  Map<String, MontyValue>? kwargs,
) {
  final result = <String, Object?>{};
  if (kwargs != null) {
    result.addAll(kwargs.map((k, v) => MapEntry(k, v.dartValue)));
  }
  for (var i = 0; i < positional.length; i++) {
    result['_$i'] = positional[i].dartValue;
  }

  return result;
}

/// A stateful REPL session backed by the Monty Rust interpreter.
///
/// Heap, globals, functions, and classes all persist across [feed] calls
/// without serialization — the underlying Rust REPL handle is reused between
/// calls, not recreated.
///
/// ```dart
/// final repl = MontyRepl();
/// await repl.feed('x = 42');
/// final result = await repl.feed('x + 1');
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

  final ReplBindings _bindings;
  final String? _scriptName;
  final String? _preamble;
  bool _created = false;
  bool _disposed = false;

  // ---------------------------------------------------------------------------
  // Synchronous feed
  // ---------------------------------------------------------------------------

  /// Feeds [code] and runs to completion.
  ///
  /// State (variables, functions, classes, heap objects) persists across
  /// calls. If [externals] are provided, Python can call registered host
  /// functions; each call is dispatched and the result resumed automatically.
  ///
  /// If [code] raises a Python exception, the REPL survives and the error
  /// is returned in [MontyResult.error].
  ///
  /// [inputs] injects per-invocation Python variables before [code] runs.
  /// Each key becomes a Python variable; values are converted to Python
  /// literals.
  Future<MontyResult> feed(
    String code, {
    Map<String, MontyCallback> externals = const {},
    OsCallHandler? osHandler,
    Map<String, Object?>? inputs,
  }) async {
    _checkNotDisposed();
    await _ensureCreated();
    final effectiveCode = inputs != null && inputs.isNotEmpty
        ? '${inputs_encoder.inputsToCode(inputs)}\n$code'
        : code;

    if (externals.isEmpty && osHandler == null) {
      // Fast path: no externals, use simple feedRun.
      final r = await _bindings.feedRun(effectiveCode);
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

    // Iterative path: drive the start/resume loop, dispatching externals.
    _bindings.setExtFns(externals.keys.toList());
    final initial = _translateProgress(
      await _bindings.feedStart(effectiveCode),
    );

    return _driveLoop(initial, externals, osHandler);
  }

  // ---------------------------------------------------------------------------
  // Iterative feed (caller drives the loop)
  // ---------------------------------------------------------------------------

  /// Starts iterative execution of [code], pausing at each registered name.
  ///
  /// Register callback names in [externalFunctions]. When Python calls one,
  /// execution pauses and returns [MontyPending]. Use [resume] or
  /// [resumeWithError] to continue.
  Future<MontyProgress> feedStart(
    String code, {
    List<String>? externalFunctions,
  }) async {
    _checkNotDisposed();
    await _ensureCreated();
    if (externalFunctions != null && externalFunctions.isNotEmpty) {
      _bindings.setExtFns(externalFunctions);
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

  // ---------------------------------------------------------------------------
  // Continuation detection
  // ---------------------------------------------------------------------------

  /// Returns whether [source] is syntactically complete for execution.
  ///
  /// Useful for building REPL UIs that show `>>>` vs `...` prompts.
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
  // Lifecycle
  // ---------------------------------------------------------------------------

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
    Map<String, MontyCallback> externals,
    OsCallHandler? osHandler,
  ) async {
    var progress = initial;
    while (true) {
      switch (progress) {
        case MontyComplete(:final result):
          return result;
        case MontyPending(:final functionName):
          final cb = externals[functionName];
          if (cb == null) {
            progress = _translateProgress(
              await _bindings.resumeWithError(
                'No handler registered for: $functionName',
              ),
            );
          } else {
            try {
              final args = _replArgsToMap(
                progress.arguments,
                progress.kwargs,
              );
              final res = await cb(args);
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
        case MontyResolveFutures():
          progress = _translateProgress(await _bindings.resume('null'));
        case MontyNameLookup():
          // REPL doesn't support NameLookup — signal NameError to Python.
          progress = _translateProgress(
            await _bindings.resumeNameLookupUndefined(),
          );
      }
    }
  }

  MontyProgress _translateProgress(CoreProgressResult p) {
    switch (p.state) {
      case 'complete':
        return _buildCompleteProgress(p);
      case 'pending':
        return _buildPendingProgress(p);
      case 'os_call':
        return _buildOsCallProgress(p);
      case 'error':
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
      final args = call.arguments.map((v) => v.dartValue).toList();
      final kwargs = call.kwargs?.map((k, v) => MapEntry(k, v.dartValue));
      final result = await handler(call.operationName, args, kwargs);

      return _translateProgress(
        await _bindings.resume(jsonEncode(result)),
      );
    } on OsCallException catch (e) {
      return _translateProgress(
        await _bindings.resumeWithError(e.message),
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

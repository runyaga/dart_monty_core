import 'dart:async';
import 'dart:typed_data';

import 'package:dart_monty_core/src/externals.dart';
import 'package:dart_monty_core/src/platform/monty_error.dart';
import 'package:dart_monty_core/src/platform/monty_exception.dart';
import 'package:dart_monty_core/src/platform/monty_limits.dart';
import 'package:dart_monty_core/src/platform/monty_progress.dart';
import 'package:dart_monty_core/src/platform/monty_resource_usage.dart';
import 'package:dart_monty_core/src/platform/monty_result.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/repl/monty_repl.dart';
import 'package:meta/meta.dart';

const _zeroUsage = MontyResourceUsage(
  memoryBytesUsed: 0,
  timeElapsedMs: 0,
  stackDepthUsed: 0,
);

/// A stateful execution session backed by the native Rust REPL heap.
///
/// All Python state — variables, functions, classes, and module objects —
/// persists natively across [run] calls without JSON serialisation.
/// Two-call import patterns work naturally:
///
/// ```dart
/// final session = MontySession();
/// await session.run('import pathlib');
/// final r = await session.run('pathlib.Path("/data/f.txt").read_text()');
/// session.dispose();
/// ```
///
/// Register Dart callbacks with `externalFunctions` to let Python call host
/// functions. OS calls (pathlib, os.getenv, datetime) are handled by
/// `osHandler`; if none is provided, OS calls raise a Python exception.
class MontySession {
  /// Creates a [MontySession].
  MontySession({
    OsCallHandler? osHandler,
    String? scriptName,
  }) : _osHandler = osHandler,
       _scriptName = scriptName,
       _repl = MontyRepl(scriptName: scriptName);

  final OsCallHandler? _osHandler;
  final String? _scriptName;
  MontyRepl _repl;

  bool _isDisposed = false;

  /// Whether this session has been disposed.
  @visibleForTesting
  bool get isDisposed => _isDisposed;

  /// Script name used as the filename in tracebacks and error messages.
  ///
  /// Returns `null` when the session was constructed without one, in which
  /// case the engine falls back to its default (`'main.py'`).
  String? get scriptName => _scriptName;

  /// Executes [code] with full Python state from previous calls available.
  ///
  /// All Python objects (variables, functions, classes, modules) persist via
  /// the Rust REPL heap across calls.
  ///
  /// [externalFunctions] maps Python-callable function names to Dart
  /// handlers.
  ///
  /// [inputs] injects per-invocation Python variables before [code] runs.
  /// Each key becomes a Python variable; values are converted to Python
  /// literals.
  ///
  /// [limits] and [scriptName] are accepted for API compatibility but
  /// ignored — the REPL uses `NoLimitTracker` and the session-level
  /// scriptName.
  Future<MontyResult> run(
    String code, {
    MontyLimits? limits,
    String? scriptName,
    Map<String, MontyCallback> externalFunctions = const {},
    Map<String, Object?>? inputs,
  }) async {
    _checkNotDisposed();
    try {
      return await _repl.feed(
        code,
        externalFunctions: externalFunctions,
        osHandler: _osHandler,
        inputs: inputs,
      );
    } on MontyScriptError catch (e) {
      return MontyResult(
        value: const MontyNone(),
        error: e.exception,
        usage: _zeroUsage,
      );
    } on MontyError catch (e) {
      return MontyResult(
        value: const MontyNone(),
        error: MontyException(message: e.message),
        usage: _zeroUsage,
      );
    }
  }

  /// Starts iterative execution, surfacing [MontyPending] for user callbacks.
  ///
  /// [limits] and [scriptName] are accepted for API compatibility but ignored.
  Future<MontyProgress> start(
    String code, {
    List<String>? externalFunctions,
    MontyLimits? limits,
    String? scriptName,
  }) {
    _checkNotDisposed();

    return _repl.feedStart(code, externalFunctions: externalFunctions);
  }

  /// Resumes a paused execution with [returnValue].
  Future<MontyProgress> resume(Object? returnValue) {
    _checkNotDisposed();

    return _repl.resume(returnValue);
  }

  /// Resumes a paused execution by raising [errorMessage] in Python.
  Future<MontyProgress> resumeWithError(String errorMessage) {
    _checkNotDisposed();

    return _repl.resumeWithError(errorMessage);
  }

  /// Serialises the REPL heap to postcard bytes.
  ///
  /// The bytes can be passed to [restore] to rehydrate an identical session.
  /// Throws [StateError] if the session is disposed or the REPL is
  /// mid-execution.
  Future<Uint8List> snapshot() {
    _checkNotDisposed();

    return _repl.snapshot();
  }

  /// Restores this session's REPL from bytes produced by [snapshot].
  ///
  /// The current REPL handle is freed and replaced with a new one restored
  /// from [bytes]. Any in-flight [run] calls must complete before calling this.
  Future<void> restore(Uint8List bytes) {
    _checkNotDisposed();

    return _repl.restore(bytes);
  }

  /// Clears all persisted state. The next [run] starts with empty globals.
  void clearState() {
    _checkNotDisposed();
    _resetRepl();
  }

  /// Disposes the session.
  void dispose() {
    _isDisposed = true;
    unawaited(_repl.dispose());
  }

  // ---------------------------------------------------------------------------
  // Private
  // ---------------------------------------------------------------------------

  void _resetRepl() {
    unawaited(_repl.dispose());
    _repl = MontyRepl(scriptName: _scriptName);
  }

  void _checkNotDisposed() {
    if (_isDisposed) throw StateError('MontySession has been disposed.');
  }
}

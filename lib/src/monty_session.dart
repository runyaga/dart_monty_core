import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_monty_core/src/externals.dart';
import 'package:dart_monty_core/src/platform/code_capture.dart';
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
/// Register Dart callbacks with `externals` to let Python call host functions.
/// OS calls (pathlib, os.getenv, datetime) are handled by `osHandler`; if
/// none is provided, OS calls raise a Python exception.
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

  // Dart-side tracking of top-level Python variable names.
  // Monty does not expose vars()/globals(), so we infer assigned names from
  // code analysis and restore them individually on snapshot().
  final Set<String> _knownVars = {};

  // State to be injected on the next run() after a restore().
  Map<String, Object?>? _pendingRestore;

  bool _isDisposed = false;

  /// Whether this session has been disposed.
  @visibleForTesting
  bool get isDisposed => _isDisposed;

  /// Executes [code] with full Python state from previous calls available.
  ///
  /// All Python objects (variables, functions, classes, modules) persist via
  /// the Rust REPL heap across calls.
  ///
  /// [externals] maps Python-callable function names to Dart handlers.
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
    Map<String, MontyCallback> externals = const {},
    Map<String, Object?>? inputs,
  }) async {
    _checkNotDisposed();
    final effectiveInputs = _mergeInputs(_pendingRestore, inputs);
    _pendingRestore = null;

    // Track names that will be set in the REPL after this call.
    _knownVars.addAll(extractAssignmentTargets(code));
    if (effectiveInputs != null) {
      _knownVars.addAll(effectiveInputs.keys);
    }

    try {
      return await _repl.feed(
        code,
        externals: externals,
        osHandler: _osHandler,
        inputs: effectiveInputs,
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
    _pendingRestore = null;
    _knownVars.addAll(extractAssignmentTargets(code));

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

  /// Captures JSON-serialisable Python globals as a portable snapshot.
  ///
  /// Reads each Dart-tracked variable directly from the REPL — no Python
  /// introspection needed. Non-serialisable values (functions, class
  /// instances, module objects) are silently skipped.
  ///
  /// Pass the returned bytes to [restore] on a new [MontySession] to recreate
  /// variable state.
  ///
  /// **Note on external functions:** [MontyCallback] closures registered via
  /// `externals:` cannot be serialised. Re-provide them in subsequent [run]
  /// calls after [restore].
  Future<Uint8List> snapshot() async {
    _checkNotDisposed();

    // Flush any pending restore into the REPL before snapshotting.
    final pending = _pendingRestore;
    if (pending != null) {
      _knownVars.addAll(pending.keys);
      try {
        await _repl.feed('pass', inputs: pending);
      } on Object {
        // ignore — snapshot whatever state the REPL currently holds
      }
      _pendingRestore = null;
    }

    final state = <String, Object?>{};
    for (final varName in List.of(_knownVars)) {
      try {
        final result = await _repl.feed(varName);
        final dartVal = result.value.dartValue;
        if (_isJsonSafe(dartVal)) {
          state[varName] = dartVal;
        }
      } on Object {
        // Variable no longer in scope (deleted or never set) — remove tracking.
        _knownVars.remove(varName);
      }
    }

    return _encodeSnapshot(state);
  }

  /// Restores Python variables from a snapshot produced by [snapshot].
  ///
  /// Resets the REPL to a fresh state and injects the snapshot variables on
  /// the next [run] call.
  ///
  /// Accepts both v1 (legacy `dartState` key) and v2 (`replState` key)
  /// envelopes. Throws [ArgumentError] if [bytes] is not a valid snapshot.
  void restore(Uint8List bytes) {
    _checkNotDisposed();
    final Map<String, dynamic> envelope;
    try {
      envelope = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } on FormatException catch (e) {
      throw ArgumentError('Not a valid MontySession snapshot: $e');
    }
    final version = envelope['v'] as int?;
    if (version != 1 && version != 2) {
      throw ArgumentError('Unsupported snapshot version: $version');
    }
    final stateKey = version == 1 ? 'dartState' : 'replState';
    _resetRepl();
    _pendingRestore = Map<String, Object?>.from(
      (envelope[stateKey] as Map<String, dynamic>?) ?? const {},
    );
  }

  /// Clears all persisted state. The next [run] starts with empty globals.
  void clearState() {
    _checkNotDisposed();
    _resetRepl();
    _pendingRestore = null;
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
    _knownVars.clear();
  }

  static Map<String, Object?>? _mergeInputs(
    Map<String, Object?>? restore,
    Map<String, Object?>? inputs,
  ) {
    if (restore == null && inputs == null) return null;
    if (restore == null) return inputs;
    if (inputs == null) return restore;

    return {...restore, ...inputs};
  }

  static Uint8List _encodeSnapshot(Map<String, Object?> state) {
    final envelope = jsonEncode({'v': 2, 'replState': state});

    return Uint8List.fromList(utf8.encode(envelope));
  }

  /// Returns true if [value] can be round-tripped through JSON without loss.
  static bool _isJsonSafe(Object? value) {
    if (value == null || value is bool || value is String) return true;
    if (value is int) return true;
    if (value is double) return !value.isNaN && !value.isInfinite;
    if (value is List) return value.every(_isJsonSafe);
    if (value is Map) {
      return value.keys.every((k) => k is String) &&
          value.values.every(_isJsonSafe);
    }

    return false;
  }

  void _checkNotDisposed() {
    if (_isDisposed) throw StateError('MontySession has been disposed.');
  }
}

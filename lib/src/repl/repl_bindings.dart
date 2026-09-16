import 'dart:typed_data';

import 'package:dart_monty_core/src/platform/monty_core_bindings.dart';
import 'package:dart_monty_core/src/platform/wire_json.dart';

/// Bindings interface for REPL operations.
///
/// Implemented by `FfiReplBindings` and `WasmReplBindings` to provide
/// a unified contract across native FFI and web WASM backends.
///
/// Public: `MontyRepl.withBindings` takes one, so an outside caller may
/// implement this to drive a REPL over its own transport. Every type in every
/// signature below is reachable from `dart_monty_core.dart`.
abstract class ReplBindings {
  /// Creates a persistent REPL session.
  ///
  /// [limitsJson] applies SESSION-scoped resource limits, mirroring
  /// upstream's `checkout(limits=…)`. Null means an unbounded session, which
  /// is what every REPL got before limits existed here.
  Future<void> create({String? scriptName, String? limitsJson});

  /// Feeds a Python snippet and runs to completion.
  ///
  /// Returns a [CoreRunResult] in the same format as one-shot execution.
  Future<CoreRunResult> feedRun(String code);

  /// Detects whether a source fragment is complete or needs more input.
  ///
  /// Returns `0` = complete, `1` = incomplete, `2` = incomplete block.
  Future<int> detectContinuation(String source);

  /// Registers external function names for name resolution.
  Future<void> setExtFns(List<String> names);

  /// Starts iterative execution. Pauses at external function calls.
  Future<CoreProgressResult> feedStart(String code);

  /// Resumes with [value] as the pending call's return value.
  ///
  /// Typed [WireJson] rather than `String` because this is the method the
  /// self-driven drive loop calls, and the loop is where core#136 lived.
  Future<CoreProgressResult> resume(WireJson value);

  /// Resumes by raising an error in Python.
  Future<CoreProgressResult> resumeWithError(String errorMessage);

  /// Resumes by raising a typed Python exception. [excType] is the Python
  /// exception class name (e.g. `FileNotFoundError`); unknown names fall
  /// back to RuntimeError.
  Future<CoreProgressResult> resumeWithException(
    String excType,
    String errorMessage,
  );

  /// Resumes by signalling "function not found" — Python sees NameError.
  ///
  /// Used when the host cannot dispatch an OS call; [fnName] is embedded in
  /// the resulting Python NameError message.
  Future<CoreProgressResult> resumeNotFound(String fnName);

  /// Resumes a name lookup by indicating the name is undefined.
  ///
  /// The engine raises NameError.
  Future<CoreProgressResult> resumeNameLookupUndefined();

  /// Resumes the paused REPL by promising a future for the pending call.
  ///
  /// Instead of providing an immediate return value (as [resume] does), this
  /// tells the VM that the host will deliver the pending call's result later
  /// via [resolveFutures]. The VM keeps executing until it hits an `await`,
  /// then yields a `resolve_futures` progress.
  Future<CoreProgressResult> resumeAsFuture();

  /// Resolves outstanding REPL futures with their results and/or errors.
  ///
  /// [results] frames `callId -> resolved value`; [errors] frames
  /// `callId -> message` (each becomes a RuntimeError in Python). Build them
  /// with [WireJson.callResults] and [WireJson.callErrors] — an absent error
  /// map frames as `{}`.
  Future<CoreProgressResult> resolveFutures(
    WireJson results,
    WireJson errors,
  );

  /// Serialises the REPL heap to postcard bytes.
  ///
  /// Throws [StateError] if the REPL is mid-execution.
  Future<Uint8List> snapshot();

  /// Restores the REPL from postcard bytes produced by [snapshot].
  ///
  /// The old native handle is freed and replaced with a new one
  /// restored from [bytes].
  /// Restores a session from [bytes].
  ///
  /// [limitsJson] is APPLIED to the restored session. A snapshot restores the
  /// limits of the session it was taken from, so a caller who wants their own
  /// must pass them — without this a `MontyRepl(limits: ...)` that restores an
  /// unbounded snapshot runs UNBOUNDED, which is a security control reporting
  /// success (FB-1 / core#124). Null keeps the snapshot's limits.
  ///
  /// [extFns] re-registers external function names. A snapshot cannot carry
  /// them: they live on the native handle, not in monty's session.
  Future<void> restore(
    Uint8List bytes, {
    String? limitsJson,
    List<String>? extFns,
  });

  /// Disposes the REPL session.
  Future<void> dispose();
}

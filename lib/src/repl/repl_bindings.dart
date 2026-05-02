import 'dart:typed_data';

import 'package:dart_monty_core/src/platform/core_bindings.dart';

/// Internal bindings interface for REPL operations.
///
/// Implemented by `FfiReplBindings` and `WasmReplBindings` to provide
/// a unified contract across native FFI and web WASM backends.
abstract class ReplBindings {
  /// Creates a persistent REPL session.
  Future<void> create({String? scriptName});

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

  /// Resumes with a JSON-encoded return value.
  Future<CoreProgressResult> resume(String valueJson);

  /// Resumes by raising an error in Python.
  Future<CoreProgressResult> resumeWithError(String errorMessage);

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
  /// [resultsJson] is a JSON object mapping `callId.toString()` to the
  /// resolved value. [errorsJson] is a JSON object mapping
  /// `callId.toString()` to an error message string (each becomes a
  /// RuntimeError in Python). Pass an empty `'{}'` when no errors occurred.
  Future<CoreProgressResult> resolveFutures(
    String resultsJson,
    String errorsJson,
  );

  /// Serialises the REPL heap to postcard bytes.
  ///
  /// Throws [StateError] if the REPL is mid-execution.
  Future<Uint8List> snapshot();

  /// Restores the REPL from postcard bytes produced by [snapshot].
  ///
  /// The old native handle is freed and replaced with a new one
  /// restored from [bytes].
  Future<void> restore(Uint8List bytes);

  /// Disposes the REPL session.
  Future<void> dispose();
}

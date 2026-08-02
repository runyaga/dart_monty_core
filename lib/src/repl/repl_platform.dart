import 'dart:typed_data';

import 'package:dart_monty_core/src/platform/monty_future_capable.dart';
import 'package:dart_monty_core/src/platform/monty_limits.dart';
import 'package:dart_monty_core/src/platform/monty_platform.dart';
import 'package:dart_monty_core/src/platform/monty_progress.dart';
import 'package:dart_monty_core/src/platform/monty_result.dart';
import 'package:dart_monty_core/src/repl/monty_repl.dart';

/// Adapts [MontyRepl] to the [MontyPlatform] interface.
///
/// Use this when a consumer expects a [MontyPlatform] but you want to
/// drive it with a stateful [MontyRepl] heap rather than a fresh
/// per-call platform.
///
/// ```dart
/// final repl = MontyRepl();
/// final platform = ReplPlatform(repl: repl);
/// await platform.run('x = 42');
/// await repl.dispose();
/// ```
///
/// **`limits` and `scriptName` are SESSION-scoped here and are rejected as
/// per-call arguments.** Both are fixed when the Rust REPL handle is created:
/// the tracker cannot be swapped mid-session, and the script name is baked
/// into the handle at `monty_repl_create`. Pass them to the [MontyRepl]
/// constructor instead:
///
/// ```dart
/// final repl = MontyRepl(
///   scriptName: 'analysis.py',
///   limits: MontyLimits(memoryBytes: 1 << 20),
/// );
/// ```
class ReplPlatform implements MontyFutureCapable {
  /// Creates a [ReplPlatform] wrapping [repl].
  const ReplPlatform({required MontyRepl repl}) : _repl = repl;

  final MontyRepl _repl;

  @override
  Future<MontyResult> run(
    String code, {
    MontyLimits? limits,
    String? scriptName,
  }) {
    _rejectSessionArgs(limits, scriptName);

    return _repl.feedRun(code);
  }

  @override
  Future<MontyProgress> start(
    String code, {
    List<String>? externalFunctions,
    MontyLimits? limits,
    String? scriptName,
  }) {
    _rejectSessionArgs(limits, scriptName);

    return _repl.feedStart(code, externalFunctions: externalFunctions);
  }

  @override
  Future<MontyProgress> resume(Object? returnValue) =>
      _repl.resume(returnValue);

  @override
  Future<MontyProgress> resumeWithError(String errorMessage) =>
      _repl.resumeWithError(errorMessage);

  @override
  Future<MontyProgress> resumeWithException(
    String excType,
    String errorMessage,
  ) => _repl.resumeWithException(excType, errorMessage);

  @override
  Future<MontyProgress> resumeNotFound(String fnName) =>
      _repl.resumeNotFound(fnName);

  @override
  Future<MontyProgress> resumeAsFuture() => _repl.resumeAsFuture();

  @override
  Future<MontyProgress> resolveFutures(
    Map<int, Object?> results, {
    Map<int, String>? errors,
  }) => _repl.resolveFutures(results, errors: errors);

  // `UnimplementedError`, not `UnsupportedError`, and the distinction is
  // load-bearing rather than stylistic. Harnesses that drive a MontyPlatform
  // catch `UnimplementedError` to record "this backend cannot inject a named
  // constant" as a SKIP — see the FB-5 branch in
  // `packages/monty_conformance/lib/src/fixture_dispatch.dart`. An
  // `UnsupportedError` sails through that catch and aborts the whole run, so a
  // known capability gap is reported as a crash.
  //
  // Neither is reachable through the REPL bindings today: the Rust side
  // auto-resolves every `NameLookup` (`native/src/repl_handle.rs`, the
  // `ReplProgress::NameLookup` arm) and never surfaces one, so a host is never
  // asked. That makes the REPL strictly less capable than the one-shot handle
  // for host-injected constants, not merely differently wired.
  @override
  Future<MontyProgress> resumeNameLookup(String name, Object? value) =>
      throw UnimplementedError(
        'NameLookup is not wired on ReplPlatform: the REPL handle '
        'auto-resolves name lookups and never asks the host',
      );

  @override
  Future<MontyProgress> resumeNameLookupUndefined(String name) =>
      throw UnimplementedError(
        'NameLookup is not wired on ReplPlatform: the REPL handle '
        'auto-resolves name lookups and never asks the host',
      );

  @override
  Future<Uint8List> compileCode(String code) =>
      throw UnsupportedError('compileCode() is not supported by ReplPlatform');

  @override
  Future<String?> typeCheck(
    String code, {
    String? prefixCode,
    String scriptName = 'main.py',
  }) => throw UnsupportedError(
    'typeCheck() is not supported by ReplPlatform',
  );

  @override
  Future<MontyResult> runPrecompiled(
    Uint8List compiled, {
    MontyLimits? limits,
    String? scriptName,
  }) => throw UnsupportedError(
    'runPrecompiled() is not supported by ReplPlatform',
  );

  @override
  Future<MontyProgress> startPrecompiled(
    Uint8List compiled, {
    MontyLimits? limits,
    String? scriptName,
  }) => throw UnsupportedError(
    'startPrecompiled() is not supported by ReplPlatform',
  );

  @override
  Future<void> dispose() => _repl.dispose();

  /// Rejects the two [MontyPlatform] arguments a REPL session cannot honour.
  ///
  /// These used to be accepted and DROPPED. That is the FB-1 / core#124 defect
  /// shape: `Monty.run(limits:)` routes through a [MontyRepl], so a caller who
  /// asked for a memory cap silently got an unbounded session and no signal —
  /// a resource control that reports success is worse than one that is absent.
  /// The same argument applies to `scriptName`, whose only symptom is a
  /// traceback naming the wrong file.
  static void _rejectSessionArgs(MontyLimits? limits, String? scriptName) {
    if (limits != null) {
      throw ArgumentError.value(
        limits,
        'limits',
        'ReplPlatform cannot apply per-call limits: the resource tracker is '
            'chosen when the REPL session is created and cannot be swapped. '
            'Pass MontyRepl(limits: …) instead',
      );
    }
    if (scriptName != null) {
      throw ArgumentError.value(
        scriptName,
        'scriptName',
        'ReplPlatform cannot apply a per-call scriptName: it is fixed for the '
            'session. Pass MontyRepl(scriptName: …) instead',
      );
    }
  }
}

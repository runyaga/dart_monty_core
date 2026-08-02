import 'package:dart_monty_core/dart_monty_core.dart';

import 'package:monty_conformance/src/fixture_externals.dart';

/// What running a `# call-external` fixture produced.
class DispatchOutcome {
  /// Creates a [DispatchOutcome].
  const DispatchOutcome({
    this.excType,
    this.value,
    this.skipped = false,
    this.skipReason,
  });

  /// The Python exception type raised, if any.
  final String? excType;

  /// The value the fixture evaluated to, when it completed.
  final MontyValue? value;

  /// True when the harness could not run the fixture at all.
  final bool skipped;

  /// Why it was skipped — shown to a reader rather than swallowed.
  final String? skipReason;
}

/// Runs a `# call-external` fixture, answering the sandbox's calls from
/// [conformanceDispatch].
///
/// **Parameterised by [platform] on purpose.** This loop was written twice —
/// once for FFI in `oracle_ffi_ext_test.dart` and once for the browser in
/// `wasm_runner.dart` — and the two drifted. Both backends implement
/// `MontyPlatform`, so there is no reason for two loops.
///
/// One real asymmetry survives and is handled here rather than hidden: FFI does
/// not implement `resumeNameLookupValue` (FB-5), so fixtures that inject a
/// named constant can only be asserted on the web. Rather than skip them
/// everywhere to match the weaker backend, this tries the injection and reports
/// a skip only when the backend refuses.
Future<DispatchOutcome> runCallExternalFixture(
  MontyPlatform platform,
  String source, {
  String? scriptName,
}) async {
  String? excType;
  MontyValue? value;

  /// Echo values held between `resumeAsFuture` and `resolveFutures`, keyed by
  /// callId. This is the async-external path: the host promises a value now and
  /// delivers it when the engine asks, which is what lets several coroutines in
  /// one `asyncio.gather` be in flight at once.
  final pendingResults = <int, Object?>{};

  MontyProgress? progress;
  try {
    progress = await platform.start(
      source,
      // `async_call` is not in the dispatch table on purpose: it returns
      // nothing directly, it goes down the futures path below.
      externalFunctions: [...conformanceExtFns, 'async_call'],
      scriptName: scriptName,
    );
  } on MontyScriptError catch (e) {
    return DispatchOutcome(excType: e.excType);
  }

  while (progress != null) {
    switch (progress) {
      case MontyComplete(:final result):
        return DispatchOutcome(
          excType: result.error?.excType,
          value: result.value,
        );

      case MontyPending(
        :final functionName,
        :final args,
        :final kwargs,
        :final callId,
      ):
        if (functionName == 'async_call') {
          // Echo: stash the argument and hand the engine a future, so it can
          // keep running other coroutines before asking for the value.
          pendingResults[callId] = args.first.dartValue;
          if (platform is! MontyFutureCapable) {
            return const DispatchOutcome(
              skipped: true,
              skipReason: 'backend does not implement the futures path',
            );
          }
          try {
            progress = await platform.resumeAsFuture();
          } on MontyScriptError catch (e) {
            return DispatchOutcome(excType: e.excType);
          }
          continue;
        }
        if (!conformanceExtFns.contains(functionName)) {
          return DispatchOutcome(
            skipped: true,
            skipReason: 'needs an external we do not model: $functionName',
          );
        }
        try {
          if (functionName == 'raise_error') {
            // Not a value-returning call: the fixture asks the HOST to raise
            // into the sandbox, which is a different resume verb entirely.
            progress = await platform.resumeWithException(
              (args.first as MontyString).value,
              (args[1] as MontyString).value,
            );
          } else {
            progress = await platform.resume(
              conformanceDispatch(functionName, args, kwargs),
            );
          }
        } on MontyScriptError catch (e) {
          return DispatchOutcome(excType: e.excType);
          // conformanceDispatch signals an unmodelled external this way;
          // reporting it as a skip is the point.
          // ignore: avoid_catching_errors
        } on StateError catch (e) {
          return DispatchOutcome(skipped: true, skipReason: e.message);
        }

      case MontyNameLookup(:final variableName):
        if (conformanceNameConstants.containsKey(variableName)) {
          try {
            progress = await platform.resumeNameLookup(
              variableName,
              conformanceNameConstants[variableName],
            );
            // FFI signals "not wired" with an UnimplementedError, and
            // reporting that honestly is the whole point of this branch (FB-5).
            // ignore: avoid_catching_errors
          } on UnimplementedError {
            // FFI: resumeNameLookupValue is not wired (FB-5).
            return const DispatchOutcome(
              skipped: true,
              skipReason: 'backend cannot inject a named constant (FB-5)',
            );
          } on MontyScriptError catch (e) {
            return DispatchOutcome(excType: e.excType);
          }
        } else {
          try {
            progress = await platform.resumeNameLookupUndefined(variableName);
          } on MontyScriptError catch (e) {
            return DispatchOutcome(excType: e.excType);
          }
        }

      case MontyResolveFutures(:final pendingCallIds):
        try {
          progress = await (platform as MontyFutureCapable).resolveFutures({
            for (final id in pendingCallIds) id: pendingResults.remove(id),
          });
        } on MontyScriptError catch (e) {
          return DispatchOutcome(excType: e.excType);
        }

      case MontyOsCall():
        return const DispatchOutcome(
          skipped: true,
          skipReason: 'needs an OS-call handler',
        );
    }
  }

  return DispatchOutcome(excType: excType, value: value);
}

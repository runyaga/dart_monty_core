import 'package:dart_monty_core/dart_monty_core.dart';

import 'package:monty_conformance/src/fixture_externals.dart';
import 'package:monty_conformance/src/fixture_os_handler.dart';

/// What running a `# call-external` fixture produced.
class DispatchOutcome {
  /// Creates a [DispatchOutcome].
  const DispatchOutcome({
    this.excType,
    this.value,
    this.skipped = false,
    this.skipReason,
    this.exception,
  });

  /// The Python exception type raised, if any.
  final String? excType;

  /// The FULL exception, when the backend supplied one.
  ///
  /// [excType] alone is what this class used to carry, and it is not enough to
  /// act on: `MontyException` also has the message, the line number, the source
  /// line and the traceback, and dropping them here is why a failing fixture
  /// could only be reported as "unexpected error" (core#145). It is also why
  /// FB-10 took three wrong write-ups — the failing line number was available
  /// the whole time and thrown away at this boundary.
  final MontyException? exception;

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
  final osHandler = conformanceOsHandler();

  MontyProgress? progress;
  try {
    progress = await platform.start(
      source,
      // `async_call` is not in the dispatch table on purpose: it returns
      // nothing directly, it goes down the futures path below.
      // `async_fail` is deliberately absent. An AWAITED host failure is not
      // the same as `raise_error`'s immediate one -- resuming with an
      // exception straight away does not satisfy async__ext_exc.py, and no
      // existing runner models it either (wasm_runner.dart has no async_fail
      // branch). Reporting "not modelled" is honest; guessing an
      // implementation and shipping a red row is not.
      externalFunctions: [...conformanceExtFns, 'async_call'],
      scriptName: scriptName,
    );
  } on MontyScriptError catch (e) {
    return DispatchOutcome(excType: e.excType, exception: e.exception);
  }

  while (progress != null) {
    switch (progress) {
      case MontyComplete(:final result):
        return DispatchOutcome(
          excType: result.error?.excType,
          exception: result.error,
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
            return DispatchOutcome(excType: e.excType, exception: e.exception);
          }
          continue;
        }
        if (!conformanceExtFns.contains(functionName)) {
          // A method call on a host-supplied dataclass whose name we do not
          // model is not an unmodelled external -- it is the receiver saying
          // it has no such attribute, and fixtures call missing methods ON
          // PURPOSE to assert that. `resumeNotFound` is the wrong verb here:
          // it reports the bare name, so the sandbox raises
          //   NameError: name 'nonexistent_method' is not defined
          // where the fixture requires
          //   AttributeError: 'Point' object has no attribute '...'
          // Anything NOT called on a dataclass is still an honest skip.
          if (args.isNotEmpty && args.first is MontyDataclass) {
            final self = args.first as MontyDataclass;
            try {
              progress = await platform.resumeWithException(
                'AttributeError',
                "'${self.name}' object has no attribute '$functionName'",
              );
              continue;
            } on MontyScriptError catch (e) {
              return DispatchOutcome(
                excType: e.excType,
                exception: e.exception,
              );
            }
          }

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
          return DispatchOutcome(excType: e.excType, exception: e.exception);
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
            return DispatchOutcome(excType: e.excType, exception: e.exception);
          }
        } else {
          try {
            progress = await platform.resumeNameLookupUndefined(variableName);
          } on MontyScriptError catch (e) {
            return DispatchOutcome(excType: e.excType, exception: e.exception);
          }
        }

      case MontyResolveFutures(:final pendingCallIds):
        try {
          progress = await (platform as MontyFutureCapable).resolveFutures({
            for (final id in pendingCallIds) id: pendingResults.remove(id),
          });
        } on MontyScriptError catch (e) {
          return DispatchOutcome(excType: e.excType, exception: e.exception);
        }

      case MontyOsCall(:final operationName, :final args, :final kwargs):
        // Answer it rather than skipping: the corpus's os/pathlib/datetime
        // fixtures are exactly the host-mediated behaviour worth demonstrating.
        try {
          final ret = await osHandler(
            operationName,
            args.map((v) => v.dartValue).toList(),
            kwargs?.map((k, v) => MapEntry(k, v.dartValue)),
          );
          progress = await platform.resume(ret);
        } on OsCallException catch (e) {
          progress = e.pythonExceptionType != null
              ? await platform.resumeWithException(
                  e.pythonExceptionType!,
                  e.message,
                )
              : await platform.resumeWithError(e.message);
        } on MontyScriptError catch (e) {
          return DispatchOutcome(excType: e.excType, exception: e.exception);
        }
    }
  }

  return DispatchOutcome(excType: excType, value: value);
}

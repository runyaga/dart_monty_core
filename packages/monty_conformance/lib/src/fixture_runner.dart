import 'package:dart_monty_core/dart_monty_core.dart';

import 'package:monty_conformance/src/fixture_corpus.dart';
import 'package:monty_conformance/src/fixture_externals.dart';
import 'package:monty_conformance/src/fixture_os_handler.dart';
import 'package:monty_conformance/src/fixture_parser.dart';
import 'package:monty_conformance/src/unsupported_wasm_fixtures.dart';

/// The whole standalone corpus runner, minus the one thing that genuinely
/// differs between the two web backends: how a line reaches the console.
///
/// **This function exists because the runner was written twice.**
/// `test/integration/wasm_runner.dart` (dart2js) and
/// `wasm_runner_wasm.dart` (dart2wasm) were ~1200 near-identical lines each,
/// and the only real difference was `print` versus a `dart:js_interop`
/// `console.log` shim. Everything else that differed between them had drifted
/// by accident: the `MontyOsCall` and `MontyResolveFutures` arms sat in
/// opposite orders, one emitted a `"ms"` field the other did not, and both
/// carried a private ~400-line `_VirtualFs` — a files-map + directories-set
/// store that this repo had already replaced with a real tree.
///
/// That is the FB-10 shape exactly: a defect fixed on one backend and shipped
/// broken on the other because the other kept its own copy. Two files that
/// must agree cannot be kept in agreement by discipline, so there is now one
/// body and two entry points.
///
/// [log] receives each protocol line verbatim:
///
///     FIXTURE_RESULT:{"name":"<file>","ok":<bool>}
///     FIXTURE_RESULT:{"name":"<file>","ok":false,"reason":"<msg>"}
///     FIXTURE_DONE:{"total":<n>,"passed":<n>,"failed":<n>,"skipped":<n>}
///
/// The harness scripts grep those out of Chrome's stderr.
Future<void> runFixtureCorpus({required void Function(String) log}) async {
  var passed = 0;
  var failed = 0;
  var skipped = 0;

  /// Emits one result line and moves the matching counter.
  ///
  /// A [reason] of `null` means the fixture passed — the two are one decision,
  /// and splitting them into an `ok` flag plus a message let a caller report
  /// "ok" with a reason attached, or a failure with none.
  void report(String key, String? reason) {
    if (reason == null) {
      passed++;
      log('FIXTURE_RESULT:{"name":"$key","ok":true}');
    } else {
      failed++;
      final escaped = reason.replaceAll('"', r'\"');
      log('FIXTURE_RESULT:{"name":"$key","ok":false,"reason":"$escaped"}');
    }
  }

  for (final MapEntry(:key, :value) in fixtureCorpus.entries) {
    // Engine-level divergences are always skipped; test-hooks fixtures run
    // only under a `-DMONTY_TEST_HOOKS=true` build against a test-hooks WASM.
    if (alwaysUnsupportedWasmFixtures.contains(key) ||
        (!_testHooks && testHooksWasmFixtures.contains(key))) {
      skipped++;
      continue;
    }

    // -----------------------------------------------------------------------
    // Path D — run-async: start() + async dispatch loop
    // Handles pure-async fixtures and async+call-external (async_call echo).
    // -----------------------------------------------------------------------
    if (fixtureIsRunAsync(value)) {
      final expectation = parseFixture(
        value,
        skipRunAsync: false,
        skipCallExternal: false, // async+ext fixtures are handled here too
      );
      if (expectation == null) {
        skipped++;
        continue;
      }

      final extFns = fixtureIsCallExternal(value) ? ['async_call'] : <String>[];
      final platform = createPlatformMonty();
      try {
        final (thrownExcType, resultValue, shouldSkip) = await _runDispatchLoop(
          platform,
          value,
          key,
          conformanceOsHandler(),
          externalFunctions: extFns,
        );

        if (shouldSkip) {
          skipped++;
        } else {
          report(key, _evaluate(expectation, thrownExcType, resultValue));
        }
      } on Object catch (e) {
        report(key, '$e');
      } finally {
        await platform.dispose();
      }
      continue;
    }

    // -----------------------------------------------------------------------
    // Path C — mount-fs: start() with /mnt VFS + injected `root` variable
    // -----------------------------------------------------------------------
    if (fixtureMountsFs(value)) {
      final expectation = parseFixture(
        value,
        skipMountFs: false,
      );
      if (expectation == null) {
        skipped++;
        continue;
      }

      // Inject `root = Path('/mnt')` before the fixture body.
      // The fixture already imports `from pathlib import Path`; the duplicate
      // import at the top is harmless in Python.
      final source = "from pathlib import Path\nroot = Path('/mnt')\n$value";

      final platform = createPlatformMonty();
      try {
        final (thrownExcType, resultValue, shouldSkip) = await _runDispatchLoop(
          platform,
          source,
          key,
          conformanceMountFsOsHandler(),
        );

        if (shouldSkip) {
          skipped++;
        } else {
          report(key, _evaluate(expectation, thrownExcType, resultValue));
        }
      } on Object catch (e) {
        report(key, '$e');
      } finally {
        await platform.dispose();
      }
      continue;
    }

    // -----------------------------------------------------------------------
    // Path A — call-external: start() + ext-function dispatch loop
    // -----------------------------------------------------------------------
    if (fixtureIsCallExternal(value)) {
      // Parse the fixture expectation with call-external skipping disabled
      // (run-async / mount-fs still cause a skip via parseFixture).
      final expectation = parseFixture(
        value,
        skipCallExternal: false,
      );
      if (expectation == null) {
        skipped++;
        continue;
      }

      final platform = createPlatformMonty();
      try {
        final (thrownExcType, resultValue, shouldSkip) = await _runDispatchLoop(
          platform,
          value,
          key,
          conformanceOsHandler(),
          externalFunctions: conformanceExtFns.toList(),
        );

        if (shouldSkip) {
          skipped++;
        } else {
          report(key, _evaluate(expectation, thrownExcType, resultValue));
        }
      } on Object catch (e) {
        report(key, '$e');
      } finally {
        await platform.dispose();
      }
    } else {
      // ---------------------------------------------------------------------
      // Path B — normal: platform.run() (no external calls needed)
      // ---------------------------------------------------------------------
      final expectation = parseFixture(value);
      if (expectation == null) {
        skipped++;
        continue;
      }

      final platform = createPlatformMonty();
      try {
        MontyResult? result;
        String? thrownExcType;
        try {
          result = await platform.run(value, scriptName: key);
          thrownExcType = result.error?.excType;
        } on MontyScriptError catch (e) {
          thrownExcType = e.excType;
        } on MontyResourceError {
          thrownExcType = 'MemoryLimitExceeded';
        }

        report(key, _evaluate(expectation, thrownExcType, result?.value));
      } on Object catch (e) {
        report(key, '$e');
      } finally {
        await platform.dispose();
      }
    }
  }

  log(
    'FIXTURE_DONE:{'
    '"total":${passed + failed + skipped},'
    '"passed":$passed,'
    '"failed":$failed,'
    '"skipped":$skipped'
    '}',
  );
}

/// Set by `-DMONTY_TEST_HOOKS=true` (tool/test_cm_wasm.sh), paired with a
/// test-hooks WASM binary so `_test_cm`-based fixtures can run.
///
/// `bool.fromEnvironment` is resolved for the whole compilation unit, so this
/// reads the flag whichever entry point is being compiled — which is why it
/// lives here rather than being threaded in from each runner as a parameter
/// the two could then set differently.
const _testHooks = bool.fromEnvironment('MONTY_TEST_HOOKS');

/// Runs [source] through [platform] using `start()` + a dispatch loop,
/// answering OS calls from [osHandler].
///
/// Returns `(thrownExcType, resultValue, shouldSkip)`.
Future<(String?, MontyValue?, bool)> _runDispatchLoop(
  MontyPlatform platform,
  String source,
  String key,
  OsCallHandler osHandler, {
  List<String> externalFunctions = const [],
}) async {
  String? thrownExcType;
  MontyValue? resultValue;
  var shouldSkip = false;

  MontyProgress? progress;
  try {
    progress = await platform.start(
      source,
      externalFunctions: externalFunctions,
      scriptName: key,
    );
  } on MontyScriptError catch (e) {
    thrownExcType = e.excType;
  } on MontyResourceError {
    thrownExcType = 'MemoryLimitExceeded';
  }

  if (progress != null) {
    // Stores async_call echo values keyed by callId.
    // Consumed when MontyResolveFutures arrives.
    final pendingResults = <int, Object?>{};
    dispatchLoop:
    while (true) {
      switch (progress!) {
        case MontyComplete(:final result):
          thrownExcType = result.error?.excType;
          resultValue = result.value;
          break dispatchLoop;

        case MontyPending(
          :final functionName,
          :final args,
          :final callId,
          :final kwargs,
          :final methodCall,
        ):
          if (functionName == 'async_call') {
            // Echo function: store the result and convert to a future so the
            // engine can continue running other coroutines in the same gather.
            pendingResults[callId] = args.first.dartValue;
            try {
              progress = await (platform as MontyFutureCapable)
                  .resumeAsFuture();
            } on MontyScriptError catch (e) {
              thrownExcType = e.excType;
              break dispatchLoop;
            } on MontyResourceError {
              thrownExcType = 'MemoryLimitExceeded';
              break dispatchLoop;
            }
          } else if (!conformanceExtFns.contains(functionName)) {
            if (methodCall) {
              // Unknown public method on external dataclass — raise
              // AttributeError so Python try/except blocks can catch it.
              final typeName =
                  (args.firstOrNull as MontyDataclass?)?.name ?? 'object';
              try {
                progress = await platform.resumeWithException(
                  'AttributeError',
                  "'$typeName' object has no attribute '$functionName'",
                );
              } on MontyScriptError catch (e) {
                thrownExcType = e.excType;
                break dispatchLoop;
              }
            } else {
              shouldSkip = true;
              break dispatchLoop;
            }
          } else {
            final isRaiseError = functionName == 'raise_error';
            try {
              if (isRaiseError) {
                final excType = (args.first as MontyString).value;
                final msg = (args[1] as MontyString).value;
                progress = await platform.resumeWithException(excType, msg);
              } else {
                final ret = conformanceDispatch(functionName, args, kwargs);
                progress = await platform.resume(ret);
              }
            } on MontyScriptError catch (e) {
              thrownExcType = e.excType;
              break dispatchLoop;
            } on MontyResourceError {
              thrownExcType = 'MemoryLimitExceeded';
              break dispatchLoop;
            }
          }

        case MontyOsCall(
          :final operationName,
          :final args,
          :final kwargs,
        ):
          // TWO try blocks, deliberately. The resume calls have to sit OUTSIDE
          // the catch that produced the error: `resumeWithException` throws
          // MontyScriptError when Python does not catch the exception, and a
          // throw from inside a catch clause is NOT covered by that same try.
          // Nested, a fixture whose whole point is an UNCAUGHT OS error —
          // pathlib__os_read_error.py — blows out of the harness with a stack
          // trace instead of being compared against its expected traceback.
          //
          // An OsCallHandler speaks Dart values, not MontyValues, so the args
          // are converted here; `MontyPath.dartValue` is the plain String the
          // handler's `rawPath is! String` guard expects.
          Object? osRet;
          OsCallException? osErr;
          try {
            osRet = await osHandler(
              operationName,
              args.map((v) => v.dartValue).toList(),
              kwargs?.map((k, v) => MapEntry(k, v.dartValue)),
            );
          } on OsCallException catch (e) {
            osErr = e;
          }
          try {
            if (osErr == null) {
              progress = await platform.resume(osRet);
            } else if (osErr.pythonExceptionType case final excType?) {
              progress = await platform.resumeWithException(
                excType,
                osErr.message,
              );
            } else {
              progress = await platform.resumeWithError(osErr.message);
            }
          } on MontyScriptError catch (e) {
            thrownExcType = e.excType;
            break dispatchLoop;
          } on MontyResourceError {
            thrownExcType = 'MemoryLimitExceeded';
            break dispatchLoop;
          } on Object catch (_) {
            shouldSkip = true;
            break dispatchLoop;
          }

        case MontyResolveFutures(:final pendingCallIds):
          // Resolve all pending futures with their stored echo values.
          try {
            final results = <int, Object?>{
              for (final id in pendingCallIds) id: pendingResults.remove(id),
            };
            progress = await (platform as MontyFutureCapable).resolveFutures(
              results,
            );
          } on MontyScriptError catch (e) {
            thrownExcType = e.excType;
            break dispatchLoop;
          } on MontyResourceError {
            thrownExcType = 'MemoryLimitExceeded';
            break dispatchLoop;
          }

        case MontyNameLookup(:final variableName):
          try {
            if (conformanceNameConstants.containsKey(variableName)) {
              progress = await platform.resumeNameLookup(
                variableName,
                conformanceNameConstants[variableName],
              );
            } else {
              progress = await platform.resumeNameLookupUndefined(variableName);
            }
          } on MontyScriptError catch (e) {
            thrownExcType = e.excType;
            break dispatchLoop;
          } on MontyResourceError {
            thrownExcType = 'MemoryLimitExceeded';
            break dispatchLoop;
          }
      }
    }
  }

  return (thrownExcType, resultValue, shouldSkip);
}

/// Evaluates an expectation against the actual result.
///
/// Returns `null` when the fixture met its expectation, otherwise the reason
/// it did not — the same shape [runFixtureCorpus]'s `report` consumes.
String? _evaluate(
  FixtureExpectation expectation,
  String? thrownExcType,
  MontyValue? resultValue,
) {
  switch (expectation) {
    case ExpectNoException():
      if (thrownExcType == null) return null;

      return 'expected no error, got $thrownExcType';

    case ExpectReturn(value: final fixtureValue):
      final expected = MontyValue.fromDart(fixtureValue);
      if (thrownExcType == null && resultValue == expected) return null;
      if (thrownExcType != null) {
        // Say what was expected as well as what happened. "unexpected error:
        // X" told a reader neither which value the fixture wanted nor where it
        // died, and this runner's output IS the CI diagnostic (core#145).
        return 'expected $expected, got error $thrownExcType';
      }

      return 'value mismatch: expected $expected, got $resultValue';

    case ExpectRaise(:final excType):
      if (thrownExcType == excType) return null;

      return 'excType mismatch: expected $excType, got $thrownExcType';
  }
}

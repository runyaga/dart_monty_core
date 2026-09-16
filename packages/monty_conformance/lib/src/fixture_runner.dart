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

  const isWasm = bool.fromEnvironment('dart.library.js_interop');
  const debugOneFixture = String.fromEnvironment('MONTY_DEBUG_ONE_FIXTURE');
  MontyPlatform? sharedPlatform;

  // Belt-and-braces recycle: even without an explicit trap, long runs can
  // accrete state in the JS worker / WASM runtime. Recycle periodically.
  //
  // Important: recycling means *creating a new Worker+WASM instance*.
  // That creation itself can OOM if Chrome's process does not return memory to
  // the OS quickly enough.
  //
  // This runner now uses one shared session for the whole corpus and recycles
  // only on WASM trap/panic (the only mechanism that fires in normal runs).
  // Keeping a periodic recycle counter here would be dead code and suggests a
  // safety net that does not exist.
  var fixturesSinceRecycle = 0;
  const recycleEvery = 10_000; // intentionally unreachable

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
      // Backslash FIRST -- escaping quotes first would then escape the
      // backslashes this very line inserts, doubling them. Latent until the
      // reason started carrying Python exception text, which can contain both.
      final escaped = reason.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
      log('FIXTURE_RESULT:{"name":"$key","ok":false,"reason":"$escaped"}');

      // (no early-abort here; fixture runs must be exhaustive)
    }
  }

  for (final MapEntry(:key, :value) in fixtureCorpus.entries) {
    if (debugOneFixture.isNotEmpty && key != debugOneFixture) {
      continue;
    }
    // Human-only progress marker: this is NOT consumed by CI, but is logged to
    // Chrome's stderr so tool/test_wasm.sh can surface it.
    //
    // Keep the exact prefix stable: tool/test_wasm.sh greps it.
    log('FIXTURE_BEGIN:{"name":"$key"}');
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
      final platform = sharedPlatform ??= createPlatformMonty();
      try {
        final (
          thrownExcType,
          thrownMessage,
          resultValue,
          shouldSkip,
        ) = await _runDispatchLoop(
          platform,
          value,
          key,
          conformanceOsHandler(),
          externalFunctions: extFns,
        );

        if (shouldSkip) {
          skipped++;
        } else {
          report(
            key,
            _evaluate(expectation, thrownExcType, thrownMessage, resultValue),
          );
        }
      } on Object catch (e) {
        report(key, '$e');

        if (isWasm && e is MontyPanicError) {
          await platform.dispose();
          sharedPlatform = null;
          fixturesSinceRecycle = 0;
          continue;
        }
      } finally {
        if (isWasm) {
          if (sharedPlatform == platform) {
            fixturesSinceRecycle++;
            if (fixturesSinceRecycle >= recycleEvery) {
              await platform.dispose();
              sharedPlatform = null;
              fixturesSinceRecycle = 0;
            } else {
              await (platform as dynamic).idle();
            }
          }
        } else {
          await platform.dispose();
          sharedPlatform = null;
        }
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

      final platform = sharedPlatform ??= createPlatformMonty();
      try {
        final (
          thrownExcType,
          thrownMessage,
          resultValue,
          shouldSkip,
        ) = await _runDispatchLoop(
          platform,
          source,
          key,
          conformanceMountFsOsHandler(),
        );

        if (shouldSkip) {
          skipped++;
        } else {
          report(
            key,
            _evaluate(expectation, thrownExcType, thrownMessage, resultValue),
          );
        }
      } on Object catch (e) {
        report(key, '$e');

        if (isWasm && e is MontyPanicError) {
          await platform.dispose();
          sharedPlatform = null;
          fixturesSinceRecycle = 0;
          continue;
        }
      } finally {
        if (isWasm) {
          if (sharedPlatform == platform) {
            fixturesSinceRecycle++;
            if (fixturesSinceRecycle >= recycleEvery) {
              await platform.dispose();
              sharedPlatform = null;
              fixturesSinceRecycle = 0;
            } else {
              await (platform as dynamic).idle();
            }
          }
        } else {
          await platform.dispose();
          sharedPlatform = null;
        }
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

      final platform = sharedPlatform ??= createPlatformMonty();
      try {
        final (
          thrownExcType,
          thrownMessage,
          resultValue,
          shouldSkip,
        ) = await _runDispatchLoop(
          platform,
          value,
          key,
          conformanceOsHandler(),
          externalFunctions: conformanceExtFns.toList(),
        );

        if (shouldSkip) {
          skipped++;
        } else {
          report(
            key,
            _evaluate(expectation, thrownExcType, thrownMessage, resultValue),
          );
        }
      } on Object catch (e) {
        report(key, '$e');

        if (isWasm && e is MontyPanicError) {
          await platform.dispose();
          sharedPlatform = null;
          fixturesSinceRecycle = 0;
          continue;
        }
      } finally {
        if (isWasm) {
          if (sharedPlatform == platform) {
            fixturesSinceRecycle++;
            if (fixturesSinceRecycle >= recycleEvery) {
              await platform.dispose();
              sharedPlatform = null;
              fixturesSinceRecycle = 0;
            } else {
              await (platform as dynamic).idle();
            }
          }
        } else {
          await platform.dispose();
          sharedPlatform = null;
        }
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

      final platform = sharedPlatform ??= createPlatformMonty();
      try {
        MontyResult? result;
        String? thrownExcType;
        String? thrownMessage;
        try {
          // Untrusted fixture corpus: cap memory so a single runaway (or a
          // backend leak) cannot poison the rest of the run by growing the WASM
          // linear memory to the 4GiB ceiling.
          result = await platform.run(
            value,
            scriptName: key,
            limits: const MontyLimits(memoryBytes: 256 * 1024 * 1024),
          );
          thrownExcType = result.error?.excType;
          thrownMessage = result.error?.message;
        } on MontyScriptError catch (e) {
          thrownExcType = e.excType;
          thrownMessage = e.message;
        } on MontyResourceError catch (e) {
          thrownExcType = 'MemoryLimitExceeded';
          thrownMessage = e.message;
        }

        report(
          key,
          _evaluate(expectation, thrownExcType, thrownMessage, result?.value),
        );
      } on Object catch (e) {
        report(key, '$e');

        if (isWasm && e is MontyPanicError) {
          await platform.dispose();
          sharedPlatform = null;
          fixturesSinceRecycle = 0;
          continue;
        }
      } finally {
        if (isWasm) {
          if (sharedPlatform == platform) {
            fixturesSinceRecycle++;
            if (fixturesSinceRecycle >= recycleEvery) {
              await platform.dispose();
              sharedPlatform = null;
              fixturesSinceRecycle = 0;
            } else {
              await (platform as dynamic).idle();
            }
          }
        } else {
          await platform.dispose();
          sharedPlatform = null;
        }
      }
    }
  }

  await sharedPlatform?.dispose();

  log(
    'FIXTURE_DONE:{'
    '"total":${passed + failed + skipped},'
    '"passed":$passed,'
    '"failed":$failed,'
    '"skipped":$skipped'
    '}',
  );

  if (debugOneFixture.isNotEmpty) {
    log('MONTY_DEBUG_ONE_FIXTURE_DONE:{"name":"$debugOneFixture"}');
  }
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
/// Returns `(thrownExcType, thrownMessage, resultValue, shouldSkip)`.
Future<(String?, String?, MontyValue?, bool)> _runDispatchLoop(
  MontyPlatform platform,
  String source,
  String key,
  OsCallHandler osHandler, {
  List<String> externalFunctions = const [],
}) async {
  String? thrownExcType;
  String? thrownMessage;
  MontyValue? resultValue;
  var shouldSkip = false;

  MontyProgress? progress;
  try {
    progress = await platform.start(
      source,
      externalFunctions: externalFunctions,
      scriptName: key,
      limits: const MontyLimits(memoryBytes: 256 * 1024 * 1024),
    );
  } on MontyScriptError catch (e) {
    thrownExcType = e.excType;
    thrownMessage = e.message;
  } on MontyResourceError catch (e) {
    thrownExcType = 'MemoryLimitExceeded';
    thrownMessage = e.message;
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
          thrownMessage = result.error?.message;
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
              thrownMessage = e.message;
              break dispatchLoop;
            } on MontyResourceError catch (e) {
              thrownExcType = 'MemoryLimitExceeded';
              thrownMessage = e.message;
              break dispatchLoop;
            }
          } else if (!conformanceExtFns.contains(functionName)) {
            if (methodCall) {
              // Unknown public method on external dataclass — raise
              // AttributeError so Python try/except blocks can catch it.
              //
              // `?? 'object'` ALWAYS fires, and the message is therefore
              // wrong. monty v0.0.23 sends an EMPTY argument list for a method
              // call (measured, both here and against pydantic-monty 0.0.23
              // directly); the receiver travels as FunctionCall.object_id,
              // which native/src/repl_handle.rs:848 reduces to
              // `object_id.is_some()` before Dart ever sees it. So there is no
              // receiver to name and this cannot do better today.
              //
              // This is the sole reason dataclass__basic.py is declared in
              // tool/wasm-corpus-expected-failures.txt: it asserts
              // "'Point' object has no attribute 'nonexistent_method'" and
              // gets "'object' ...". The fixture is right and monty is right
              // — the binding drops the identity. Forwarding object_id is the
              // fix; see artifacts/DIAG-DATACLASS-BASIC-2026-09-15.md.
              final typeName =
                  (args.firstOrNull as MontyDataclass?)?.name ?? 'object';
              try {
                progress = await platform.resumeWithException(
                  'AttributeError',
                  "'$typeName' object has no attribute '$functionName'",
                );
              } on MontyScriptError catch (e) {
                thrownExcType = e.excType;
                thrownMessage = e.message;
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
              thrownMessage = e.message;
              break dispatchLoop;
            } on MontyResourceError catch (e) {
              thrownExcType = 'MemoryLimitExceeded';
              thrownMessage = e.message;
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
            thrownMessage = e.message;
            break dispatchLoop;
          } on MontyResourceError catch (e) {
            thrownExcType = 'MemoryLimitExceeded';
            thrownMessage = e.message;
            break dispatchLoop;
          }
        // NO `on Object catch` HERE, DELIBERATELY. It used to swallow ANY
        // unexpected error into `shouldSkip = true`, and a skip emits NO
        // FIXTURE_RESULT line at all — so the fixture vanished from the
        // corpus rather than failing. `total` stayed self-consistent
        // (total = passed + failed + skipped) and the expected-failure gate
        // only inspects `"ok":false` lines, so the run reported GREEN.
        //
        // MEASURED, by throwing unconditionally on this path:
        //     clean      Results: 575/578 passed   gate exit 0
        //     injected   Results: 565/568 passed   gate exit 0
        // Ten fixtures disappeared from the corpus and nothing went red.
        //
        // MontyScriptError and MontyResourceError are handled above — those
        // are the EXPECTED failure shapes. Anything else is a genuine
        // surprise, and it now propagates to the outer handler in
        // `runFixtures`, which calls `report(key, '$e')` and makes it a
        // visible FAILURE. A conformance run must never be able to lose a
        // fixture silently; failing loudly on an unknown error is the only
        // honest default.
        //
        // Verified this path does not fire today: instrumenting both
        // `shouldSkip = true` sites and running the full corpus produced no
        // hits, so nothing that passes now turns red.

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
            thrownMessage = e.message;
            break dispatchLoop;
          } on MontyResourceError catch (e) {
            thrownExcType = 'MemoryLimitExceeded';
            thrownMessage = e.message;
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
            thrownMessage = e.message;
            break dispatchLoop;
          } on MontyResourceError catch (e) {
            thrownExcType = 'MemoryLimitExceeded';
            thrownMessage = e.message;
            break dispatchLoop;
          }
      }
    }
  }

  return (thrownExcType, thrownMessage, resultValue, shouldSkip);
}

/// Renders a caught error as `ExcType: message` for a fixture reason line.
///
/// The corpus used to report the bare `excType`, so a failure read "expected
/// no error, got AssertionError" and said nothing about WHICH of a fixture's
/// ~200 assertions blew up. Recovering that cost a hand-instrumented re-run of
/// the dispatch loop when `dataclass__basic.py` was diagnosed
/// (artifacts/DIAG-DATACLASS-BASIC-2026-09-15.md), and every `MontyError`
/// already carried the message this needed -- 17 capture sites read `.excType`
/// off the exception and dropped `.message` on the floor.
///
/// Folded to one line and capped, because this text is emitted inside a
/// single-line `FIXTURE_RESULT:` record that tool/test_wasm.sh greps.
String _describeError(String? excType, String? message) {
  final type = excType ?? 'no error';
  if (message == null) return type;
  final oneLine = message.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (oneLine.isEmpty || oneLine == type) return type;
  final capped = oneLine.length > 200
      ? '${oneLine.substring(0, 200)}…'
      : oneLine;
  return '$type: $capped';
}

/// Evaluates an expectation against the actual result.
///
/// Returns `null` when the fixture met its expectation, otherwise the reason
/// it did not — the same shape [runFixtureCorpus]'s `report` consumes.
String? _evaluate(
  FixtureExpectation expectation,
  String? thrownExcType,
  String? thrownMessage,
  MontyValue? resultValue,
) {
  switch (expectation) {
    case ExpectNoException():
      if (thrownExcType == null) return null;

      return 'expected no error, got '
          '${_describeError(thrownExcType, thrownMessage)}';

    case ExpectReturn(value: final fixtureValue):
      final expected = MontyValue.fromDart(fixtureValue);
      if (thrownExcType == null && resultValue == expected) return null;
      if (thrownExcType != null) {
        // Say what was expected as well as what happened. "unexpected error:
        // X" told a reader neither which value the fixture wanted nor where it
        // died, and this runner's output IS the CI diagnostic (core#145).
        return 'expected $expected, got error '
            '${_describeError(thrownExcType, thrownMessage)}';
      }

      return 'value mismatch: expected $expected, got $resultValue';

    case ExpectRaise(:final excType):
      if (thrownExcType == excType) return null;

      return 'excType mismatch: expected $excType, got '
          '${_describeError(thrownExcType, thrownMessage)}';
  }
}

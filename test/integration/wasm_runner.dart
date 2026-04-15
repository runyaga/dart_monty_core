// Standalone WASM fixture runner for headless-Chrome CI.
//
// Compile with:
//   dart compile js test/integration/wasm_runner.dart \
//     -o test/integration/web/wasm_runner.dart.js
//
// Runs every fixture from the compile-time corpus through MontyWasm,
// prints one JSON line per fixture, then a summary line.
//
// Output protocol:
//   FIXTURE_RESULT:{"name":"<file>","ok":<bool>}
//   FIXTURE_RESULT:{"name":"<file>","ok":false,"reason":"<msg>"}
//   FIXTURE_DONE:{"total":<n>,"passed":<n>,"failed":<n>,"skipped":<n>}
//
// The CI job greps for FIXTURE_RESULT / FIXTURE_DONE from Chrome stderr.

// ignore_for_file: avoid_print

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart';

import '_fixture_corpus.dart';
import '_fixture_parser.dart';

// ---------------------------------------------------------------------------
// External-function dispatch
// ---------------------------------------------------------------------------

/// Functions the test harness can dispatch. Registered with platform.start()
/// so the interpreter pauses on them and we resume with the computed result.
const _supportedExtFns = {
  'add_ints',
  'concat_strings',
  'return_value',
  'get_list',
};

/// Known ext-function names used in the corpus that we do NOT implement yet.
/// Any fixture calling one of these is kept skipped to avoid wrong failures.
const _unsupportedExtFns = {
  'raise_error', // resumeWithError hardcodes RuntimeError in Rust
  'make_point',
  'make_user',
  'make_mutable_point',
  'make_empty',
  'async_call',
};

/// Dispatches a supported [functionName] call to its Dart implementation.
/// Returns the Dart value to resume with (passed to [platform.resume]).
Object? _dispatch(
  String functionName,
  List<MontyValue> args,
  Map<String, MontyValue>? kwargs,
) =>
    switch (functionName) {
      // add_ints(a: int, b: int) → int
      'add_ints' => (args[0].dartValue as int) + (args[1].dartValue as int),
      // concat_strings(a: str, b: str) → str
      'concat_strings' => '${args[0].dartValue}${args[1].dartValue}',
      // return_value(x: any) → x  (identity)
      'return_value' => args[0].dartValue,
      // get_list() → [1, 2, 3]
      'get_list' => [1, 2, 3],
      _ => throw StateError('Unexpected external function: $functionName'),
    };

// ---------------------------------------------------------------------------
// Runner
// ---------------------------------------------------------------------------

Future<void> main() async {
  var passed = 0;
  var failed = 0;
  var skipped = 0;

  for (final MapEntry(:key, :value) in fixtureCorpus.entries) {
    // -------------------------------------------------------------------------
    // Path A — call-external: platform.start() + external-function dispatch loop
    // -------------------------------------------------------------------------
    if (fixtureIsCallExternal(value)) {
      // Skip fixtures that call ext functions we haven't implemented yet.
      if (_unsupportedExtFns.any((fn) => value.contains('$fn('))) {
        skipped++;
        continue;
      }

      // Parse the fixture expectation with call-external skipping disabled
      // (run-async / mount-fs still cause a skip via parseFixture).
      final expectation = parseFixture(
        value,
        skipWasm: true,
        skipCallExternal: false,
      );
      if (expectation == null) {
        skipped++;
        continue;
      }

      final platform = createPlatformMonty();
      try {
        String? thrownExcType;
        MontyValue? resultValue;
        bool shouldSkip = false;

        // -- start() ---------------------------------------------------------
        // Nullable: remains null if start() throws, skipping the dispatch loop.
        MontyProgress? progress;
        try {
          progress = await platform.start(
            value,
            externalFunctions: _supportedExtFns.toList(),
            scriptName: key,
          );
        } on MontyScriptError catch (e) {
          thrownExcType = e.excType;
        } on MontyResourceError {
          thrownExcType = 'MemoryLimitExceeded';
        }

        // -- dispatch loop ---------------------------------------------------
        // Only runs when start() returned a progress state without throwing.
        if (progress != null) {
          dispatchLoop:
          while (true) {
            switch (progress!) {
              case MontyComplete(:final result):
                thrownExcType = result.error?.excType;
                resultValue = result.value;
                break dispatchLoop;

              case MontyPending(
                :final functionName,
                :final arguments,
                :final kwargs,
              ):
                if (!_supportedExtFns.contains(functionName)) {
                  // Unexpected pending call — skip this fixture gracefully.
                  shouldSkip = true;
                  break dispatchLoop;
                }
                try {
                  final ret = _dispatch(functionName, arguments, kwargs);
                  progress = await platform.resume(ret);
                } on MontyScriptError catch (e) {
                  thrownExcType = e.excType;
                  break dispatchLoop;
                } on MontyResourceError {
                  thrownExcType = 'MemoryLimitExceeded';
                  break dispatchLoop;
                }

              case MontyOsCall():
                // OS-call dispatch not yet implemented — skip this fixture.
                shouldSkip = true;
                break dispatchLoop;

              case MontyResolveFutures():
                // Async futures not yet implemented — skip this fixture.
                shouldSkip = true;
                break dispatchLoop;
            }
          }
        }

        // -- evaluate result -------------------------------------------------
        if (shouldSkip) {
          skipped++;
        } else {
          bool ok;
          String reason = '';

          switch (expectation) {
            case ExpectNoException():
              ok = thrownExcType == null;
              if (!ok) reason = 'expected no error, got $thrownExcType';

            case ExpectReturn(:final value):
              final expected = MontyValue.fromDart(value);
              ok = thrownExcType == null && resultValue == expected;
              if (!ok) {
                reason = thrownExcType != null
                    ? 'unexpected error: $thrownExcType'
                    : 'value mismatch: expected $expected, got $resultValue';
              }

            case ExpectRaise(:final excType):
              ok = thrownExcType == excType;
              if (!ok) {
                reason =
                    'excType mismatch: expected $excType, got $thrownExcType';
              }
          }

          if (ok) {
            passed++;
            print('FIXTURE_RESULT:{"name":"$key","ok":true}');
          } else {
            failed++;
            final escaped = reason.replaceAll('"', r'\"');
            print(
              'FIXTURE_RESULT:{"name":"$key","ok":false,"reason":"$escaped"}',
            );
          }
        }
      } catch (e) {
        failed++;
        final escaped = '$e'.replaceAll('"', r'\"');
        print('FIXTURE_RESULT:{"name":"$key","ok":false,"reason":"$escaped"}');
      } finally {
        await platform.dispose();
      }
    } else {
      // -----------------------------------------------------------------------
      // Path B — normal: platform.run() (no external calls needed)
      // -----------------------------------------------------------------------
      final expectation = parseFixture(value, skipWasm: true);
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

        bool ok;
        String reason = '';

        switch (expectation) {
          case ExpectNoException():
            ok = thrownExcType == null;
            if (!ok) reason = 'unexpected error in $key: $thrownExcType';

          case ExpectReturn(:final value):
            final expected = MontyValue.fromDart(value);
            ok = thrownExcType == null && result?.value == expected;
            if (!ok) {
              reason =
                  'value mismatch: expected $expected, got ${result?.value}';
            }

          case ExpectRaise(:final excType):
            ok = thrownExcType == excType;
            if (!ok) {
              reason =
                  'excType mismatch: expected $excType, got $thrownExcType';
            }
        }

        if (ok) {
          passed++;
          print('FIXTURE_RESULT:{"name":"$key","ok":true}');
        } else {
          failed++;
          final escaped = reason.replaceAll('"', r'\"');
          print(
            'FIXTURE_RESULT:{"name":"$key","ok":false,"reason":"$escaped"}',
          );
        }
      } catch (e) {
        failed++;
        final escaped = '$e'.replaceAll('"', r'\"');
        print('FIXTURE_RESULT:{"name":"$key","ok":false,"reason":"$escaped"}');
      } finally {
        await platform.dispose();
      }
    }
  }

  print(
    'FIXTURE_DONE:{'
    '"total":${passed + failed + skipped},'
    '"passed":$passed,'
    '"failed":$failed,'
    '"skipped":$skipped'
    '}',
  );
}

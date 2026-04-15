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

Future<void> main() async {
  var passed = 0;
  var failed = 0;
  var skipped = 0;

  for (final MapEntry(:key, :value) in fixtureCorpus.entries) {
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

      bool ok;
      String reason = '';

      switch (expectation) {
        case ExpectNoException():
          ok = thrownExcType == null;
          if (!ok) reason = 'expected no error, got $thrownExcType';
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
            reason = 'excType mismatch: expected $excType, got $thrownExcType';
          }
      }

      if (ok) {
        passed++;
        print('FIXTURE_RESULT:{"name":"$key","ok":true}');
      } else {
        failed++;
        final escaped = reason.replaceAll('"', r'\"');
        print('FIXTURE_RESULT:{"name":"$key","ok":false,"reason":"$escaped"}');
      }
    } catch (e) {
      failed++;
      final escaped = '$e'.replaceAll('"', r'\"');
      print('FIXTURE_RESULT:{"name":"$key","ok":false,"reason":"$escaped"}');
    } finally {
      await platform.dispose();
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

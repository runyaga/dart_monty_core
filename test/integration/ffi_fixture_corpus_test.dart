// The fixture corpus on FFI, through the SAME runner the browser uses.
//
// `runFixtureCorpus` (package:monty_conformance) is what tool/test_wasm.sh
// drives on dart2js and dart2wasm. It is backend-agnostic — it calls
// `createPlatformMonty()`, which is `MontyFfi` on the VM — but until now no VM
// step ran it. The FFI harnesses each covered a slice through their own loop:
// oracle_ffi_test.dart compares against the oracle binary (circular, and
// type-only), oracle_ffi_ext_test.dart covers only `# call-external`, and
// ffi_repl_corpus_test.dart drives the REPL handle. So the one-shot handle was
// never judged against the directives for most of the corpus, and the three
// backends could not be compared fixture for fixture.
//
// The verdict uses tool/test_wasm.sh's rule: the failing set must EQUAL the
// declared set in tool/ffi-corpus-expected-failures.txt, in both directions.
//
// Run: dart test test/integration/ffi_fixture_corpus_test.dart -p vm \
//        --run-skipped --tags=ffi
@Tags(['integration', 'ffi'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:monty_conformance/monty_conformance.dart';
import 'package:test/test.dart';

const _declaredFile = 'tool/ffi-corpus-expected-failures.txt';

Set<String> _declared() => _declaredIn(_declaredFile);

Set<String> _declaredIn(String path) => {
  for (final line in File(path).readAsLinesSync())
    if (line.trim().isNotEmpty && !line.trimLeft().startsWith('#'))
      line.trim().replaceFirst(RegExp(r'\s.*$'), ''),
};

void main() {
  test('the shell and Dart declarations of S7 defects agree', () {
    // strict_adjudicator_defects.dart (read by wasm_fixture_test.dart) and
    // the tool/*-corpus-expected-failures.txt files (read by this file,
    // tool/test_wasm.sh and tool/test_cm_wasm.sh) declare the same
    // fixtures. Copies that must agree are kept in agreement by a check, not
    // by discipline.
    final wasm = _declaredIn('tool/wasm-corpus-expected-failures.txt');
    expect(
      oneShotCompileErrorDefects.difference(_declared()),
      isEmpty,
      reason: 'missing from $_declaredFile',
    );
    expect(
      {...oneShotCompileErrorDefects, ...webEmptyMessageDefects}.difference(
        wasm,
      ),
      isEmpty,
      reason: 'missing from tool/wasm-corpus-expected-failures.txt',
    );
    expect(
      {...oneShotCompileErrorDefects, ...webEmptyMessageDefects}.difference(
        _declaredIn('tool/cm-corpus-expected-failures.txt'),
      ),
      isEmpty,
      reason: 'missing from tool/cm-corpus-expected-failures.txt',
    );
    expect(
      _declared().intersection(webEmptyMessageDefects),
      isEmpty,
      reason: 'web-only defects must not be declared for FFI',
    );
  });

  test(
    'the corpus on FFI fails exactly the declared set',
    () async {
      final lines = <String>[];
      await runFixtureCorpus(log: lines.add);

      final results = [
        for (final l in lines)
          if (l.startsWith('FIXTURE_RESULT:'))
            jsonDecode(l.substring('FIXTURE_RESULT:'.length))
                as Map<String, Object?>,
      ];
      final doneLines = [
        for (final l in lines)
          if (l.startsWith('FIXTURE_DONE:')) l,
      ];
      expect(doneLines, hasLength(1), reason: 'exactly one FIXTURE_DONE');
      final doneLine = doneLines.join();
      // The per-backend scorecard line, in the same words test_wasm.sh prints.
      // ignore: avoid_print
      print('ffi $doneLine');
      final done =
          jsonDecode(doneLine.substring('FIXTURE_DONE:'.length))
              as Map<String, Object?>;
      final failing = {
        for (final r in results)
          if (r['ok'] == false) r['name']! as String,
      };
      final reasons = {
        for (final r in results)
          if (r['ok'] == false) r['name']! as String: r['reason'],
      };

      // The corpus actually ran, all of it, and no record was lost.
      final recorded =
          (jsonDecode(File('tool/fixture-corpus.json').readAsStringSync())
              as Map<String, Object?>)['fixture_count'];
      expect(done['total'], recorded, reason: 'corpus size');
      expect(failing.length, done['failed'], reason: 'lost result records');

      final declared = _declared();
      final unexpected = failing.difference(declared);
      final stale = declared.difference(failing);
      // One assertion for both directions, so a run that is wrong both ways
      // reports both rather than stopping at the first.
      expect(
        {'unexpected': unexpected, 'stale': stale},
        {'unexpected': isEmpty, 'stale': isEmpty},
        reason:
            'REGRESSION — failing but not declared in $_declaredFile:\n'
            '${unexpected.map((k) => '  $k: ${reasons[k]}').join('\n')}\n'
            'STALE — declared in $_declaredFile but now PASS; delete: $stale',
      );
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}

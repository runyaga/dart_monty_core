// The corpus checks shared by the VM and browser entry points: pure Dart, so
// the same code judges the native worker and the Web Worker.
import 'dart:async';
import 'dart:convert';

import 'package:dart_monty_core/dart_monty_core.dart';
// PoolOptions is internal: the browser entry point starts its pools with its
// own channel factory, which the public Monty.start cannot take.
import 'package:dart_monty_core/src/worker/worker_pool.dart' show PoolOptions;
import 'package:meta/meta.dart';
import 'package:monty_conformance/worker_conformance.dart';
import 'package:test/test.dart';

/// One minute bounds a fixture's turn, so a hung one fails instead of
/// stalling the run.
const Duration corpusRequestTimeout = Duration(seconds: 60);

/// The corpus pool's settings, for a start that supplies its own channel
/// factory: one worker, [corpusRequestTimeout].
const PoolOptions corpusPoolOptions = PoolOptions(
  maxProcesses: 1,
  requestTimeout: corpusRequestTimeout,
);

/// [body] on a pool as [corpusPoolOptions] say, started through the public
/// API.
Future<T> withCorpusPool<T>(Future<T> Function(Monty monty) body) =>
    Monty.withPool(
      body,
      maxProcesses: 1,
      requestTimeout: corpusRequestTimeout,
    );

/// How the entry point judges the corpus.
final class CorpusTarget {
  /// Creates a [CorpusTarget].
  const CorpusTarget({
    required this.label,
    required this.profile,
    required this.startPool,
    this.jspi,
    this.startNoJspiPool,
    this.recursionSet = workerRecursionSetNoJspi,
  });

  /// `native`, `dart2js` or `dart2wasm`, as printed.
  final String label;

  /// The manifest profile.
  final WorkerCorpusProfile profile;

  /// Starts the pool the corpus runs on.
  final Future<Monty> Function() startPool;

  /// The Worker's JSPI probe, for a browser; null on native.
  final bool? jspi;

  /// The recursion set's expected outcomes when [jspi] is false.
  final Map<String, RecursionOutcome> recursionSet;

  /// A pool whose Workers skip JSPI (the forced fallback), for a browser.
  final Future<Monty> Function()? startNoJspiPool;
}

/// The corpus tests for [target], for a backend whose JSPI state is known
/// when the tests are declared (the VM).
void corpusTests(CorpusTarget target) {
  manifestTests();
  test(
    'the upstream 1.1.0 corpus meets its directives, or is a listed '
    'divergence (${target.label})',
    () => runCorpusChecks(target),
    timeout: const Timeout(Duration(minutes: 15)),
  );
  adjudicatorSelfTests();
}

/// The manifest is well formed.
void manifestTests() {
  _mountedTextTests();

  test('the manifest is well formed', () {
    expect(manifestProblems(fixtureCorpusV1.keys), isEmpty);
    expect(fixtureCorpusV1, hasLength(643));
  });

  test(
    "the no-JSPI branch is judged against upstream's recorded outcomes",
    () {
      const crashed = 'the worker crashed: boom';
      final recorded = {
        for (final e in workerRecursionSetNoJspi.entries)
          if (e.value == RecursionOutcome.crashes) e.key: crashed,
      };
      expect(recursionSetProblems(recorded), isEmpty);
      // Safari's measured set: every file passes, so a crash is a problem.
      expect(recursionSetProblems({}, workerRecursionSetNoJspiSafari), isEmpty);
      expect(
        recursionSetProblems(recorded, workerRecursionSetNoJspiSafari),
        hasLength(
          workerRecursionSetNoJspi.values
              .where((o) => o == RecursionOutcome.crashes)
              .length,
        ),
      );
      // A file that should crash and passes, one that should pass and crashes,
      // and one that fails some other way: each is a problem.
      final [first, ...] = workerRecursionSetNoJspi.keys.toList();
      final oneProblem = hasLength(1);
      expect(recursionSetProblems({...recorded}..remove(first)), oneProblem);
      expect(
        recursionSetProblems({...recorded, 'generic_alias.py': crashed}),
        oneProblem,
      );
      expect(
        recursionSetProblems({...recorded, first: 'value mismatch'}),
        oneProblem,
      );
    },
  );

  test('pyValueRepr preserves fixed-point boundaries and declines scientific values', () {
    expect(pyValueRepr(MontyFloat(1e15)), equals('1000000000000000.0')); expect(pyValueRepr(MontyFloat(-1e15)), equals('-1000000000000000.0')); expect(pyValueRepr(MontyFloat(1e-4)), equals('0.0001')); expect(pyValueRepr(MontyFloat(-1e-4)), equals('-0.0001')); expect(pyValueRepr(MontyFloat(1e16)), isNull); expect(pyValueRepr(MontyFloat(-1e16)), isNull); expect(pyValueRepr(MontyFloat(1e-5)), isNull); expect(pyValueRepr(MontyFloat(-1e-5)), isNull); expect(pyValueRepr(MontyFloat(0.0)), equals('0.0')); expect(pyValueRepr(MontyFloat(-0.0)), equals('-0.0')); expect(pyValueRepr(MontyFloat(double.nan)), equals('nan')); expect(pyValueRepr(MontyFloat(double.infinity)), equals('inf')); expect(pyValueRepr(MontyFloat(double.negativeInfinity)), equals('-inf'));
  });
}

/// Runs the whole corpus on [target]'s pool and judges it against the
/// manifest; prints the scorecard line.
Future<void> runCorpusChecks(CorpusTarget target) async {
  final run = await _runAll(target.startPool);
  final failures = run.failures;
  final noJspi = target.jspi == false;
  final problems = <String>[
    ...checkAgainstManifest(
      {
        for (final e in failures.entries)
          if (!(noJspi && target.recursionSet.containsKey(e.key)))
            e.key: e.value,
      },
      target.profile,
      fixtureCorpusV1.keys,
    ),
    if (noJspi) ...recursionSetProblems(failures, target.recursionSet),
  ];
  final listed = {
    for (final e in workerCorpusExpected)
      if (e.profiles.contains(target.profile)) e.file,
  };
  // Every corpus file ran, once: the totals below are what ran, not what the
  // corpus holds.
  expect(
    run.executed,
    fixtureCorpusV1.keys.toList(),
    reason: 'the run must execute every corpus file, once each, in order',
  );
  // The scorecard line the CI job prints, per backend.
  // ignore: avoid_print
  print(
    'CORPUS ${target.label}: total=${run.executed.length} '
    'passed=${run.passed} '
    'divergent=${failures.length} jspi=${target.jspi} '
    'listed=${listed.length}',
  );
  expect(problems, isEmpty, reason: problems.join('\n'));
}

/// Runs the recursion set on [pool] (whose Workers skip JSPI on a browser
/// that has it) and prints what each file did.
///
/// This is an observation, not the no-JSPI gate: a browser without JSPI is
/// judged against upstream's browser build in [runCorpusChecks], and a
/// JSPI-capable browser forced onto the fallback dispatch is a different
/// environment from it. What this asserts is that no file ends any way but a
/// pass or a crashed worker (the two outcomes upstream's browser build has).
Future<void> runRecursionSetFallback(String label, Monty pool) async {
  final WorkerCorpusRun run;
  try {
    run = await runWorkerFixtureCorpus(
      pool: pool,
      log: _discard,
      only: workerRecursionSetNoJspi.keys.toSet(),
    );
  } finally {
    await pool.close();
  }
  final failures = run.failures;
  expect(
    run.executed.toSet(),
    workerRecursionSetNoJspi.keys.toSet(),
    reason: 'the whole recursion set must run',
  );
  final outcomes = {
    for (final f in workerRecursionSetNoJspi.keys)
      f: failures.containsKey(f) ? 'fails' : 'passes',
  };
  // The scorecard line, as the full run's.
  // ignore: avoid_print
  print('RECURSION-SET forced fallback $label: $outcomes');
  expect(
    [
      for (final MapEntry(:key, :value) in failures.entries)
        if (!value.startsWith('the worker crashed')) '$key: $value',
    ],
    isEmpty,
    reason: 'a recursion-set file ended neither as a pass nor a crash',
  );
}

/// The strict adjudicator, with the worker as the engine under it.
void adjudicatorSelfTests() {
  group('the strict adjudicator judges worker outcomes', () {
    Future<Map<String, String>> judge(Map<String, String> corpus) async {
      final run = await withCorpusPool(
        (pool) =>
            runWorkerFixtureCorpus(pool: pool, log: _discard, corpus: corpus),
      );
      // Each control ran: a verdict on nothing is not a pass.
      expect(run.executed, corpus.keys.toList());

      return run.failures;
    }

    test('controls that meet their directives pass', () async {
      expect(
        await judge({
          'return.py': 'x = 1 + 1\nx\n# Return=2',
          'raise.py': "raise ValueError('bad')\n# Raise=ValueError('bad')",
          'tb.py':
              "def f():\n    raise ValueError('boom')\nf()\n"
              '"""\nTRACEBACK:\n'
              'Traceback (most recent call last):\n'
              '  File "tb.py", line 3, in <module>\n'
              '    f()\n'
              '    ~~~\n'
              '  File "tb.py", line 2, in f\n'
              "    raise ValueError('boom')\n"
              'ValueError: boom\n'
              '"""\n',
          'xfail.py': 'x = 1 / 0\n# xfail=monty\n# Return=1',
        }),
        isEmpty,
      );
    });

    test('an expected value altered fails, in each directive', () async {
      final failures = await judge({
        'return.py': 'x = 1 + 1\nx\n# Return=3',
        'raise_type.py': "raise ValueError('bad')\n# Raise=KeyError('bad')",
        'raise_message.py':
            "raise ValueError('bad')\n# Raise=ValueError('worse')",
        'tb_line.py':
            "def f():\n    raise ValueError('boom')\nf()\n"
            '"""\nTRACEBACK:\n'
            'Traceback (most recent call last):\n'
            '  File "tb_line.py", line 4, in <module>\n'
            '    f()\n'
            '    ~~~\n'
            '  File "tb_line.py", line 2, in f\n'
            "    raise ValueError('boom')\n"
            'ValueError: boom\n'
            '"""\n',
        'xfail_passes.py': 'x = 1 + 1\nx\n# xfail=monty\n# Return=2',
        'no_error.py': 'x = 1 / 0\n# Return=1',
        'unknown.py': 'x = 1\n# xfail-ish=monty',
      });
      expect(failures.keys, {
        'return.py',
        'raise_type.py',
        'raise_message.py',
        'tb_line.py',
        'xfail_passes.py',
        'no_error.py',
        'unknown.py',
      });
    });

    test(
      'one expected value altered in a real upstream fixture fails',
      () async {
        const name = 'edge__float_int_mod.py';
        final source = fixtureCorpusV1[name]!;
        expect(source, contains('# Return=1.5'));
        expect(await judge({name: source}), isEmpty);
        final altered = await judge({
          name: source.replaceFirst('# Return=1.5', '# Return=1.25'),
        });
        expect(altered.keys, [name]);
        expect(altered[name], contains('1.25'));
      },
    );
  });
}

Future<WorkerCorpusRun> _runAll(
  Future<Monty> Function() start, {
  Set<String>? only,
}) async {
  final pool = await start();
  try {
    return await runWorkerFixtureCorpus(
      pool: pool,
      log: _discard,
      only: only,
    );
  } finally {
    await pool.close();
  }
}

/// How [failures] differ from the expected outcomes [set] on the recursion
/// set (by default upstream's browser build on Chrome), for a run whose JSPI
/// probe failed.
@visibleForTesting
List<String> recursionSetProblems(
  Map<String, String> failures, [
  Map<String, RecursionOutcome> set = workerRecursionSetNoJspi,
]) {
  final problems = <String>[];
  for (final MapEntry(:key, :value) in set.entries) {
    final reason = failures[key];
    switch (value) {
      case RecursionOutcome.crashes:
        if (reason == null || !reason.startsWith('the worker crashed')) {
          problems.add('$key: expected the worker to crash; got $reason');
        }
      case RecursionOutcome.passes:
        if (reason != null) {
          problems.add('$key: expected a pass; got $reason');
        }
    }
  }

  return problems;
}

/// Swallows the corpus runner's progress lines.
final void Function(String) _discard = <String>[].add;

/// The byte order mark a UTF-8 file may start with, as the character it
/// decodes to: upstream's `json__file_io.py` writes a file that starts with
/// one, and reads the text back with the mark still in it.
const String _bom = '\uFEFF';

/// The bytes upstream's `json__file_io.py` writes: the BOM, then JSON
/// (`crates/monty/test_cases/json__file_io.py:51`).
final List<int> _bomBytes = [0xEF, 0xBB, 0xBF, ...utf8.encode('{"bom": 1}')];

/// The text of a file with ordinary UTF-8 in it.
const String _utf8Text = 'héllo ☃';

/// The program the mounted tree runs: it writes the BOM payload, an empty
/// file, ordinary UTF-8, and bytes that are not UTF-8 at all, then reads
/// each back as text and as bytes. It answers the texts, the bytes, and the
/// error the invalid file raised, in that order. The empty file is the one
/// upstream reads at `crates/monty/test_cases/json__file_io.py:82`.
const String _mountedTextProgram = r'''
from pathlib import Path

bom_path = root / 'bom.json'
bom_path.write_bytes(b'\xef\xbb\xbf{"bom": 1}')
bom_text = bom_path.read_text()
bom_bytes = bom_path.read_bytes()

empty_path = root / 'empty_bytes.txt'
empty_path.write_bytes(b'')
empty_text = empty_path.read_text()
empty_bytes = empty_path.read_bytes()

utf8_path = root / 'utf8.txt'
utf8_path.write_bytes('héllo ☃'.encode('utf-8'))
utf8_text = utf8_path.read_text()
utf8_bytes = utf8_path.read_bytes()

bad_path = root / 'bad_utf8.bin'
bad_path.write_bytes(b'\x80\x81\x82')
try:
    bad_path.read_text()
    bad_text = ''
except UnicodeDecodeError as exc:
    bad_text = str(exc)

(bom_text, bom_bytes, empty_text, empty_bytes, utf8_text, utf8_bytes, bad_text)
''';

/// The answers the mounted program gives: every file read back as text and as
/// bytes, and the error the invalid file raised.
typedef _MountedAnswers = ({
  String bomText,
  List<int> bomBytes,
  String emptyText,
  List<int> emptyBytes,
  String utf8Text,
  List<int> utf8Bytes,
  String badText,
});

/// The mounted tree's text and bytes, as upstream's `json__file_io.py` reads
/// them: a file written with a UTF-8 BOM reads back as text that keeps the
/// BOM, and as the bytes that were written
/// (`crates/monty/test_cases/json__file_io.py:51-57`).
///
/// The tree is [WorkerFixtureOs.mounted], the mounted tree the corpus
/// fixtures see, and the pool is [withCorpusPool]'s, so the VM and the
/// browser read the same files the same way.
void _mountedTextTests() {
  test(
    'mounted fixture text preserves BOM and binary reads preserve bytes',
    () async {
      final fixtureOs = WorkerFixtureOs.mounted();
      await withCorpusPool((pool) async {
        final session = await pool.checkout(scriptName: 'mounted_text.py');
        try {
          final answers = _mountedAnswers(
            await session.feedRun(
              _mountedTextProgram,
              cwd: '/mnt',
              os: fixtureOs.call,
              externalLookup: {'root': MontyPath('/mnt')},
              printCallback: _discardPrint,
            ),
          );

          // The BOM is text: upstream's fixture reads the file's text with
          // the mark in it, which `json.load` then rejects.
          expect(answers.bomText, startsWith(_bom));
          expect(answers.bomBytes, equals(_bomBytes));
          // The controls around it: an empty file, ordinary UTF-8, and bytes
          // that are not UTF-8 at all.
          expect(answers.emptyText, isEmpty);
          expect(answers.emptyBytes, isEmpty);
          expect(answers.utf8Text, _utf8Text);
          expect(answers.utf8Bytes, equals(utf8.encode(_utf8Text)));
          expect(
            answers.badText,
            "'utf-8' codec can't decode byte 0x80 in position 0: "
            'invalid start byte',
          );
        } finally {
          await session.close();
        }
      });
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

/// The answers the mounted program gave, read off the tuple it returned.
_MountedAnswers _mountedAnswers(MontyValue answers) => switch (answers) {
  MontyTuple(
    items: [
      final bomText,
      final bomBytes,
      final emptyText,
      final emptyBytes,
      final utf8Text,
      final utf8Bytes,
      final badText,
    ],
  ) =>
    (
      bomText: _text(bomText),
      bomBytes: _bytes(bomBytes),
      emptyText: _text(emptyText),
      emptyBytes: _bytes(emptyBytes),
      utf8Text: _text(utf8Text),
      utf8Bytes: _bytes(utf8Bytes),
      badText: _text(badText),
    ),
  _ => fail('the mounted program must answer seven values, got $answers'),
};

/// The text [answer] holds, or a failure.
String _text(MontyValue answer) => switch (answer) {
  MontyString(:final value) => value,
  _ => fail('expected a string, got $answer'),
};

/// The bytes [answer] holds, or a failure.
List<int> _bytes(MontyValue answer) => switch (answer) {
  MontyBytes(:final value) => value,
  _ => fail('expected bytes, got $answer'),
};

/// Swallows what the mounted program prints: the corpus judges values, not
/// printed output.
void _discardPrint(String stream, String text) {
  return;
}

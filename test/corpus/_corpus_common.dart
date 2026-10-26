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
  hostModuleTests(target.label, target.startPool);
  adjudicatorSelfTests();
}

/// The upstream fixtures that import a module the sandbox does not have, so
/// the host answers the import with the module itself (`tools`).
///
/// Between them they cover the module's own functions, its submodule
/// (`tools.nested.VERSION`), the futures its async tools return and the
/// failure one raises, and the two ways an import can fail: a module the host
/// does not have, and a name the module does not have.
///
/// Pinned by upstream v1.2.0:
/// `up/crates/monty/test_cases/import__host.py`,
/// `up/crates/monty/test_cases/import__host_async.py`,
/// `up/crates/monty/test_cases/import__host_not_found.py` and
/// `up/crates/monty/test_cases/import__host_cannot_import.py`.
const hostImportFixtures = [
  'import__host.py',
  'import__host_async.py',
  'import__host_not_found.py',
  'import__host_cannot_import.py',
];

/// Registers the host-module corpus test: the four upstream fixtures that
/// import a module the host supplies, run on the pool [startPool] starts.
///
/// [label] names the backend, for the failure messages.
void hostModuleTests(String label, Future<Monty> Function() startPool) {
  test(
    'corpus harness supplies tools modules and preserves async fixture '
    'outcomes',
    () => runHostModuleChecks(label, startPool),
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

/// Runs the four host-import fixtures on the pool [startPool] starts and
/// judges them against upstream's own outcomes.
///
/// The pool is closed in a `finally`, whether the fixtures passed or failed.
Future<void> runHostModuleChecks(
  String label,
  Future<Monty> Function() startPool,
) async {
  final run = await _runAll(startPool, only: hostImportFixtures.toSet());

  // All four ran, once each: the corpus holds them and the runner ran each
  // of them, so a verdict is a verdict on the fixture and not on nothing.
  expect(
    run.executed.toSet(),
    hostImportFixtures.toSet(),
    reason: 'the four host-import fixtures must each run ($label)',
  );
  expect(
    run.executed,
    hasLength(hostImportFixtures.length),
    reason: 'each host-import fixture must run exactly once ($label)',
  );

  // Each met the outcome its own directives state: the module's functions
  // and `tools.nested.VERSION`, the awaited futures and the failure they
  // raise, and the two import errors' tracebacks. A harness fault is a
  // failure too, so it cannot pass as a fixture's outcome.
  expect(
    run.failures,
    isEmpty,
    reason:
        'every host-import fixture must meet the outcome upstream states '
        '($label):\n${run.failures}',
  );

  // No divergence is recorded for them: they are expected to pass, so a
  // manifest entry for one of them would be a new divergence.
  expect(
    workerCorpusExpected
        .where((e) => hostImportFixtures.contains(e.file))
        .map((e) => e.file),
    isEmpty,
    reason: 'the host-import fixtures must not be listed as divergences',
  );
}

/// The manifest is well formed.
void manifestTests() {
  _mountedTextTests();

  test('the manifest is well formed', () {
    expect(manifestProblems(fixtureCorpusV1.keys), isEmpty);
    expect(fixtureCorpusV1, hasLength(643));
  });

  test(
    'selected v1.2.0 corpus sources match independent upstream copies',
    () {
      // Each production source must be the upstream v1.2.0 text, byte for
      // byte: both sides are strict UTF-8 decodings of the same file, so
      // equal strings are equal bytes.
      for (final MapEntry(:key, :value)
          in selectedUpstreamV120Sources.entries) {
        expect(
          fixtureCorpusV1,
          containsPair(key, value),
          reason:
              '$key must equal its independent upstream v1.2.0 copy '
              'byte-for-byte',
        );
      }
      // The four non-open sources are the ones held for the execution tests:
      // open__fs.py runs through the mounted tree instead.
      expect(selectedUpstreamV120ExecutionSources, {
        for (final MapEntry(:key, :value)
            in selectedUpstreamV120Sources.entries)
          if (key != 'open__fs.py') key: value,
      });
    },
  );

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

  test(
    'pyValueRepr preserves fixed-point boundaries and declines scientific '
    'values',
    () {
      expect(pyValueRepr(MontyFloat(1e15)), equals('1000000000000000.0'));
      expect(pyValueRepr(MontyFloat(-1e15)), equals('-1000000000000000.0'));
      expect(pyValueRepr(MontyFloat(1e-4)), equals('0.0001'));
      expect(pyValueRepr(MontyFloat(-1e-4)), equals('-0.0001'));
      expect(pyValueRepr(MontyFloat(1e16)), isNull);
      expect(pyValueRepr(MontyFloat(-1e16)), isNull);
      expect(pyValueRepr(MontyFloat(1e-5)), isNull);
      expect(pyValueRepr(MontyFloat(-1e-5)), isNull);
      expect(pyValueRepr(MontyFloat(0.0)), equals('0.0'));
      expect(pyValueRepr(MontyFloat(-0.0)), equals('-0.0'));
      expect(pyValueRepr(MontyFloat(double.nan)), equals('nan'));
      expect(pyValueRepr(MontyFloat(double.infinity)), equals('inf'));
      expect(pyValueRepr(MontyFloat(double.negativeInfinity)), equals('-inf'));
    },
  );
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

// ---------------------------------------------------------------------------
// The selected corpus sources as independent upstream v1.2.0 copies. None of
// these strings is generated: the comparison in [manifestTests] judges the
// production corpus against a text that cannot drift with it.
// ---------------------------------------------------------------------------

// Each embedded source below is one JSON string literal, as long as the file
// it holds: dart format cannot split a string literal, so the 80-column rule
// is lifted for the whole file rather than annotated five times over.
// ignore_for_file: lines_longer_than_80_chars

/// The complete `open__fs.py` as upstream v1.2.0 ships it: `newline=`
/// taken as a real argument — validated after the open, with the read
/// matrix over every terminator and the write matrix beside it, and
/// files open for reading and for writing iterated
/// (`up/crates/monty/test_cases/open__fs.py:656-820`). The 1.1.0 file
/// this copy replaces rejected an explicit `newline` kwarg outright,
/// which is the obsolete behaviour the production corpus must not
/// still carry.
const String upstreamOpenFsV120 =
    "# /// monty\n# mount-fs = true\n# # CPython on Windows defaults text I/O to cp1252, which can't encode β;\n# # Windows-specific coverage lives in open__fs_windows.py.\n# skip-cpython-windows = true\n# ///\nimport sys\n\nis_monty = sys.platform == 'monty'\nis_windows = sys.platform == 'win32'\n\n# === Text read ===\ntext_file = open(root / 'hello.txt')\nassert str(type(text_file)) == \"<class '_io.TextIOWrapper'>\"\nassert text_file.mode == 'r'\nassert text_file.readable() == True\nassert text_file.writable() == False\nassert text_file.read() == 'hello world\\n'\n# Second sequential read should be empty (CPython EOF semantics)\nassert text_file.read() == ''\nassert text_file.read() == ''\n# Both CPython and Monty report readable files as seekable now that Monty\n# implements seek()/tell() via on-demand buffering.\nassert text_file.seekable() == True\ntext_file.close()\nassert text_file.closed == True\n\n# === Binary read ===\nbinary_file = open(root / 'data.bin', 'rb')\nassert str(type(binary_file)) == \"<class '_io.BufferedReader'>\"\nassert binary_file.mode == 'rb'\nassert binary_file.read() == b'\\x00\\x01\\x02\\x03'\nassert binary_file.read() == b''\nbinary_file.close()\n\n# === Text write ===\nwriter = open(root / 'open_write.txt', 'w')\nassert str(type(writer)) == \"<class '_io.TextIOWrapper'>\"\nassert writer.readable() == False\nassert writer.writable() == True\nassert writer.write('alpha') == 5\nassert writer.write('\\nβ') == 2\nwriter.flush()\nwriter.close()\nassert (root / 'open_write.txt').read_text() == 'alpha\\nβ'\n\n# === Text append ===\nappend_writer = open(root / 'open_write.txt', 'a')\nassert append_writer.write('!') == 1\nappend_writer.close()\nassert (root / 'open_write.txt').read_text() == 'alpha\\nβ!'\n\nnew_append_writer = open(root / 'open_new_append.txt', 'a')\nassert new_append_writer.write('created') == 7\nnew_append_writer.close()\nassert (root / 'open_new_append.txt').read_text() == 'created'\n\n# === Binary write and append ===\nbinary_writer = open(root / 'open_bytes.bin', 'wb')\nassert str(type(binary_writer)) == \"<class '_io.BufferedWriter'>\"\nassert binary_writer.write(b'\\x10\\x11') == 2\nassert binary_writer.write(b'\\x12') == 1\nbinary_writer.close()\nassert (root / 'open_bytes.bin').read_bytes() == b'\\x10\\x11\\x12'\n\nbinary_append = open(root / 'open_bytes.bin', 'ab')\nassert binary_append.write(b'\\x13') == 1\nbinary_append.close()\nassert (root / 'open_bytes.bin').read_bytes() == b'\\x10\\x11\\x12\\x13'\n\n# === Identity comparison: a file is equal to itself but not to a distinct handle ===\nf = open(root / 'hello.txt')\nassert f == f\ng = open(root / 'hello.txt')\nassert f != g\nf.close()\ng.close()\n\n# === '+' modes rejected on Monty (CPython accepts them; Monty's wrapper lacks\n# read-position tracking so they would silently destroy data on first write) ===\nif is_monty:\n    for mode in ('r+', 'rb+', 'r+b', 'w+', 'wb+', 'a+', 'ab+'):\n        try:\n            open(root / 'open_bytes.bin', mode)\n            assert False, f'expected ValueError for + mode {mode!r}'\n        except ValueError as exc:\n            assert str(exc) == \"update modes ('+') are not yet supported\", (\n                f'unexpected + mode rejection for {mode!r}: {exc}'\n            )\n\n# === Keyword arguments ===\nkeyword_file = open(file=root / 'hello.txt', mode='r', encoding='utf-8')\nassert keyword_file.read() == 'hello world\\n'\nkeyword_file.close()\n\n# === bytes path accepted (matches CPython os.fsdecode semantics) ===\nhello_bytes = str(root / 'hello.txt').encode('utf-8')\nbytes_path_file = open(hello_bytes)\nassert bytes_path_file.read() == 'hello world\\n'\nbytes_path_file.close()\n\n# === All eight positional args accepted at CPython defaults ===\n# Monty only honors `file`, `mode` and `newline`; the other five must be at their\n# CPython defaults (encoding='utf-8' is also accepted as a documented no-op since\n# Monty already uses UTF-8).\npositional = open(root / 'hello.txt', 'r', -1, 'utf-8', None, None, True, None)\nassert positional.read() == 'hello world\\n'\npositional.close()\n\n# closefd and opener also accepted as kwargs at their defaults\nkw_closefd = open(root / 'hello.txt', closefd=True, opener=None)\nkw_closefd.close()\n\n# Non-default values for ignored kwargs are rejected on Monty (CPython\n# silently honors them).\nif is_monty:\n    for kwarg_name, kwarg_value in (\n        ('buffering', 0),\n        ('encoding', 'latin-1'),\n        ('errors', 'strict'),\n        ('closefd', False),\n    ):\n        try:\n            open(root / 'hello.txt', **{kwarg_name: kwarg_value})\n            assert False, f'expected non-default {kwarg_name}={kwarg_value!r} to fail'\n        except TypeError as exc:\n            assert str(exc) == f\"'{kwarg_name}' argument is not yet supported\", (\n                f'unexpected message for {kwarg_name}={kwarg_value!r}: {exc}'\n            )\n\n# === Open-time truncation / creation (CPython truncates/creates on open) ===\n# w truncates an existing file immediately, before (and even without) any write\n(root / 'open_trunc.txt').write_text('previous contents')\ntrunc = open(root / 'open_trunc.txt', 'w')\nassert (root / 'open_trunc.txt').read_text() == ''\ntrunc.close()\nassert (root / 'open_trunc.txt').read_text() == ''\n\n# w creates a missing file immediately, even with no write\nopened_w = open(root / 'open_created_w.txt', 'w')\nopened_w.close()\nassert (root / 'open_created_w.txt').read_text() == ''\n\n# a creates a missing file immediately, even with no write\nopened_a = open(root / 'open_created_a.txt', 'a')\nopened_a.close()\nassert (root / 'open_created_a.txt').read_text() == ''\n\n# a must NOT truncate existing content on open\n(root / 'open_keep_a.txt').write_text('keep me')\nkeep = open(root / 'open_keep_a.txt', 'a')\nassert (root / 'open_keep_a.txt').read_text() == 'keep me'\nkeep.write('!')\nkeep.close()\nassert (root / 'open_keep_a.txt').read_text() == 'keep me!'\n\n# binary w truncates on open too\n(root / 'open_trunc.bin').write_bytes(b'\\xff\\xfe')\nbtrunc = open(root / 'open_trunc.bin', 'wb')\nassert (root / 'open_trunc.bin').read_bytes() == b''\nbtrunc.close()\n\n# === Open-time existence checks for read modes ===\n# r on a missing file raises FileNotFoundError at open time (not on first read)\ntry:\n    open(root / 'open_missing.txt', 'r')\n    assert False, 'expected FileNotFoundError opening a missing file for read'\nexcept FileNotFoundError as exc:\n    if is_monty:\n        assert str(exc) == \"[Errno 2] No such file or directory: '/mnt/open_missing.txt'\", (\n            f'unexpected missing-file message: {exc}'\n        )\n    elif not is_windows:\n        assert str(exc).startswith(\"[Errno 2] No such file or directory: '\"), f'exc message: {exc}'\n\n# opening a directory for read raises IsADirectoryError at open time\ntry:\n    open(root, 'r')\n    assert False, 'expected IsADirectoryError opening a directory for read'\nexcept IsADirectoryError as exc:\n    if is_monty:\n        assert str(exc) == \"[Errno 21] Is a directory: '/mnt'\", f'unexpected is-a-directory message: {exc}'\n    elif not is_windows:\n        assert str(exc).startswith('[Errno 21] Is a directory: '), f'exc message: {exc}'\n\n# === Operation errors ===\ntry:\n    text_file.read()\n    assert False, 'expected read after close to fail'\nexcept ValueError as exc:\n    assert str(exc) == 'I/O operation on closed file.', f'unexpected closed-file message: {exc}'\n\n# write() to a closed file must not leak its (heap-allocated) data argument\nclosed_writer = open(root / 'open_closed.txt', 'w')\nclosed_writer.close()\ntry:\n    closed_writer.write('payload' + str(1))\n    assert False, 'expected write after close to fail'\nexcept ValueError as exc:\n    assert str(exc) == 'I/O operation on closed file.', f'unexpected closed-write message: {exc}'\n\n# an invalid ignored-kwarg type must not leak the file/mode arguments\ntry:\n    open(root / 'hello.txt', encoding=123)\n    assert False, 'expected non-str encoding to fail'\nexcept TypeError as exc:\n    assert str(exc) == \"open() argument 'encoding' must be str or None, not int\", (\n        f'unexpected encoding type message: {exc}'\n    )\n\n# === Wrong-type `mode` matches CPython's `_PyArg_BadArgument` wording ===\n# Driven by `bad_arg_named` on `OpenArgs`. The `None`-vs-`NoneType` special\n# case must apply (lone `None` reads as `\"not None\"`).\nfor bad, expected_type in ((42, 'int'), (None, 'None'), (b'r', 'bytes')):\n    try:\n        open(root / 'hello.txt', bad)\n        assert False, f'open(mode={bad!r}) should error'\n    except TypeError as exc:\n        assert str(exc) == f\"open() argument 'mode' must be str, not {expected_type}\", (\n            f'open(mode={bad!r}) wrong type: {exc}'\n        )\n    try:\n        open(root / 'hello.txt', mode=bad)\n        assert False, f'open(mode={bad!r} kwarg) should error'\n    except TypeError as exc:\n        assert str(exc) == f\"open() argument 'mode' must be str, not {expected_type}\", (\n            f'open(mode={bad!r} kwarg) wrong type: {exc}'\n        )\n\ntry:\n    open(root / 'hello.txt', 'r').write('x')\n    assert False, 'expected writing to read-only file to fail'\nexcept OSError as exc:\n    assert str(exc) == 'not writable', f'unexpected not-writable message: {exc}'\n    # Mode-violation errors must surface as io.UnsupportedOperation, not bare\n    # OSError.\n    assert type(exc).__name__ == 'UnsupportedOperation', f'unexpected type name: {type(exc).__name__}'\n\ntry:\n    open(root / 'hello.txt', 'rb').write(b'x')\n    assert False, 'expected writing to rb file to fail'\nexcept OSError as exc:\n    assert str(exc) == 'write', f'unexpected binary not-writable message: {exc}'\n\ntry:\n    open(root / 'hello.txt', 'w').read()\n    assert False, 'expected reading from write-only file to fail'\nexcept OSError as exc:\n    assert str(exc) == 'not readable', f'unexpected not-readable message: {exc}'\n\n# io.UnsupportedOperation also inherits from ValueError in CPython; Monty\n# matches that behaviour so `except ValueError:` also catches mode violations.\ntry:\n    open(root / 'hello.txt', 'w').read()\n    assert False, 'expected reading from write-only file to fail'\nexcept ValueError as exc:\n    assert str(exc) == 'not readable', f'unexpected not-readable message: {exc}'\n\ntry:\n    open(root / 'bad.txt', 'w').write(b'bytes')\n    assert False, 'expected bytes write to text file to fail'\nexcept TypeError as exc:\n    assert str(exc) == 'write() argument must be str, not bytes', f'unexpected text write type message: {exc}'\n\ntry:\n    open(root / 'bad.bin', 'wb').write('text')\n    assert False, 'expected str write to binary file to fail'\nexcept TypeError as exc:\n    assert str(exc) == \"a bytes-like object is required, not 'str'\", f'unexpected binary write type message: {exc}'\n\ntry:\n    open(root / 'bad.txt', 'rw')\n    assert False, 'expected invalid mode to fail'\nexcept ValueError as exc:\n    assert str(exc) == 'must have exactly one of create/read/write/append mode', (\n        f'unexpected invalid mode message: {exc}'\n    )\n\n# === Empty mode and unknown-character mode parse errors ===\ntry:\n    open(root / 'hello.txt', '')\n    assert False, 'expected empty mode to fail'\nexcept ValueError as exc:\n    assert str(exc) == 'Must have exactly one of create/read/write/append mode and at most one plus', (\n        f'unexpected empty mode message: {exc}'\n    )\n\ntry:\n    open(root / 'hello.txt', 'z')\n    assert False, 'expected unknown mode character to fail'\nexcept ValueError as exc:\n    assert str(exc) == \"invalid mode: 'z'\", f'unexpected unknown mode message: {exc}'\n\n# A `b`/`t` flag alone supplies no r/w/a action and must be rejected, not\n# silently treated as a read.\ntry:\n    open(root / 'hello.txt', 'b')\n    assert False, 'expected action-less binary mode to fail'\nexcept ValueError as exc:\n    assert str(exc) == 'Must have exactly one of create/read/write/append mode and at most one plus', (\n        f'unexpected action-less mode message: {exc}'\n    )\n\ntry:\n    open(root / 'hello.txt', 't')\n    assert False, 'expected action-less text mode to fail'\nexcept ValueError as exc:\n    assert str(exc) == 'Must have exactly one of create/read/write/append mode and at most one plus', (\n        f'unexpected action-less mode message: {exc}'\n    )\n\n# === Sized read ===\n# Set up a multi-line text fixture for the rest of these tests.\n(root / 'sized.txt').write_text('hello world')\nsized = open(root / 'sized.txt')\nassert sized.read(5) == 'hello'\nassert sized.read(100) == ' world'\nassert sized.read(1) == ''\nassert sized.read(0) == ''\nsized.close()\n\nread_none = open(root / 'sized.txt')\nassert read_none.read(None) == 'hello world'\nread_none.close()\n\nread_bool = open(root / 'sized.txt')\nassert read_bool.read(True) == 'h'\nassert read_bool.read(False) == ''\nassert read_bool.read(1) == 'e'\nread_bool.close()\n\n# read(-1) and read() (with buffer loaded) return the rest\nmixed = open(root / 'sized.txt')\nassert mixed.read(5) == 'hello'\nassert mixed.read(-1) == ' world'\nmixed.close()\n\nmixed2 = open(root / 'sized.txt')\nassert mixed2.read(5) == 'hello'\nassert mixed2.read() == ' world'\nmixed2.close()\n\n# read(0) without prior reads short-circuits without loading\nzero = open(root / 'sized.txt')\nempty = ''\nassert zero.read(0) is empty, 'zero-length text read should reuse the empty string'\nassert zero.read(5) == 'hello'\nzero.close()\n\n# Binary sized read\n(root / 'sized.bin').write_bytes(b'\\x10\\x11\\x12\\x13\\x14')\nsized_b = open(root / 'sized.bin', 'rb')\nassert sized_b.read(3) == b'\\x10\\x11\\x12'\nassert sized_b.read(10) == b'\\x13\\x14'\nassert sized_b.read(1) == b''\nsized_b.close()\n\n# === readline / readlines / tell / seek ===\n(root / 'lines.txt').write_text('first\\nsecond\\nthird')\nlf = open(root / 'lines.txt')\nassert lf.readline() == 'first\\n'\nassert lf.readline() == 'second\\n'\nassert lf.readline() == 'third'\nassert lf.readline() == ''\nlf.close()\n\n# readline on an empty file\n(root / 'empty_lines.txt').write_text('')\nempty_lf = open(root / 'empty_lines.txt')\nassert empty_lf.readline() == ''\nempty_lf.close()\n\n# readlines\nall_lines = open(root / 'lines.txt')\nassert all_lines.readlines() == ['first\\n', 'second\\n', 'third']\nassert all_lines.readlines() == []\nall_lines.close()\n\n# Binary readline / readlines\n(root / 'lines.bin').write_bytes(b'a\\nb\\nc')\nbin_lf = open(root / 'lines.bin', 'rb')\nassert bin_lf.readline() == b'a\\n'\nassert bin_lf.readlines() == [b'b\\n', b'c']\nbin_lf.close()\n\n# tell()\nt = open(root / 'sized.txt')\nassert t.tell() == 0\nt.read(5)\nassert t.tell() == 5\nt.read(2)\nassert t.tell() == 7\nt.close()\n\n# seek()\ns = open(root / 'sized.txt')\nassert s.read(11) == 'hello world'\nassert s.tell() == 11\nassert s.seek(0) == 0\nassert s.tell() == 0\nassert s.read(5) == 'hello'\nassert s.seek(0, 2) == 11\nassert s.read(1) == ''\nassert s.seek(6) == 6\nassert s.read(5) == 'world'\ns.close()\n\n# seek() with no prior reads triggers the buffer load\nfresh_seek = open(root / 'sized.txt')\nassert fresh_seek.seek(0, 2) == 11\nassert fresh_seek.tell() == 11\nassert fresh_seek.read(1) == ''\nfresh_seek.close()\n\n# seek(offset, 1) — SEEK_CUR — adjusts position relative to current.\n# CPython's TextIOWrapper rejects nonzero cur-relative seeks, so the\n# text-mode case is restricted to seek(0, 1) (which is a no-op tell()).\ncur_t = open(root / 'sized.txt')\nassert cur_t.read(4) == 'hell'\nassert cur_t.seek(0, 1) == 4\nassert cur_t.read(2) == 'o '\ncur_t.close()\n\n# Binary SEEK_CUR supports nonzero offsets in both CPython and Monty.\ncur_b = open(root / 'sized.bin', 'rb')\nassert cur_b.read(2) == b'\\x10\\x11'\nassert cur_b.seek(1, 1) == 3\nassert cur_b.read(2) == b'\\x13\\x14'\nassert cur_b.seek(-3, 1) == 2\nassert cur_b.read(2) == b'\\x12\\x13'\ncur_b.close()\n\n# Negative seek raises OSError in binary mode (matches CPython's BufferedReader).\nns = open(root / 'sized.bin', 'rb')\nns.read(0)  # no-op\ntry:\n    ns.seek(-1)\n    assert False, 'expected OSError for negative seek'\nexcept OSError as exc:\n    assert str(exc) == '[Errno 22] Invalid argument', f'unexpected negative seek message: {exc}'\nns.close()\n\n# Invalid whence\niw = open(root / 'sized.bin', 'rb')\niw.read(0)\ntry:\n    iw.seek(0, 99)\n    assert False, 'expected ValueError for invalid whence'\nexcept ValueError as exc:\n    assert str(exc) == 'whence value 99 unsupported', f'unexpected invalid whence message: {exc}'\ntry:\n    iw.seek(0, -1)\n    assert False, 'expected ValueError for negative whence'\nexcept ValueError as exc:\n    assert str(exc) == 'whence value -1 unsupported', f'unexpected negative whence message: {exc}'\ntry:\n    iw.seek(0, 256)\n    assert False, 'expected ValueError for large whence'\nexcept ValueError as exc:\n    assert str(exc) == 'whence value 256 unsupported', f'unexpected large whence message: {exc}'\niw.close()\n\n# tell / seek on a closed file\nclosed_t = open(root / 'sized.txt')\nclosed_t.close()\ntry:\n    closed_t.tell()\n    assert False, 'expected tell on closed file to fail'\nexcept ValueError as exc:\n    assert str(exc) == 'I/O operation on closed file.'\ntry:\n    closed_t.seek(0)\n    assert False, 'expected seek on closed file to fail'\nexcept ValueError as exc:\n    assert str(exc) == 'I/O operation on closed file.'\n\n# UTF-8 multi-byte handling: 'β' is 2 bytes, 1 char.\n(root / 'utf8.txt').write_text('aβc')\nutf = open(root / 'utf8.txt')\nassert utf.read(2) == 'aβ'\n# Monty's text-mode tell() is a char index (diverges from CPython's opaque\n# byte cookie); see limitations/open.md.\nif is_monty:\n    assert utf.tell() == 2\nassert utf.read(1) == 'c'\nutf.close()\n\n# tell/seek round-trip\nrt = open(root / 'lines.txt')\nrt.read(3)\ncaptured = rt.tell()\nassert captured == 3\nrt.read(5)\nassert rt.seek(captured) == 3\nassert rt.read(2) == 'st'\nrt.close()\n\n# Mixed read() / readline()\nmixed_rl = open(root / 'lines.txt')\nassert mixed_rl.read(2) == 'fi'\nassert mixed_rl.readline() == 'rst\\n'\nassert mixed_rl.read() == 'second\\nthird'\nmixed_rl.close()\n\n# read on a 'w' file\ntry:\n    open(root / 'open_write.txt', 'w').read(5)\n    assert False, 'expected read on w to fail'\nexcept OSError as exc:\n    assert str(exc) == 'not readable'\n\n# read(0) on a write-only file: the open/readable check still happens first\ntry:\n    open(root / 'open_write.txt', 'w').read(0)\n    assert False, 'expected read(0) on w to fail'\nexcept OSError as exc:\n    assert str(exc) == 'not readable'\n\n# read on a closed write-only file should hit ensure_open before mode check\nclosed_w = open(root / 'open_write.txt', 'w')\nclosed_w.close()\ntry:\n    closed_w.read(0)\n    assert False, 'expected read(0) on closed file to fail'\nexcept ValueError as exc:\n    assert str(exc) == 'I/O operation on closed file.'\n\n# write-only files still expose logical tell/seek state.\nwrite_pos = open(root / 'write_position.txt', 'w')\nassert write_pos.seekable() == True\nassert write_pos.tell() == 0\nassert write_pos.write('abc') == 3\nassert write_pos.tell() == 3\nassert write_pos.seek(0) == 0\nassert write_pos.tell() == 0\nassert write_pos.seek(0, 2) == 3\nwrite_pos.close()\n\nwrite_pos_b = open(root / 'write_position.bin', 'wb')\nassert write_pos_b.write(b'\\x00\\x01\\x02\\x03') == 4\nassert write_pos_b.tell() == 4\nwrite_pos_b.close()\n\n# Regression: binary read after seek-past-end must not panic.\n(root / 'past_end.bin').write_bytes(b'12345')\npe = open(root / 'past_end.bin', 'rb')\nassert pe.seek(100) == 100\nassert pe.tell() == 100\nassert pe.read(5) == b''\nassert pe.tell() == 100\nassert pe.readline() == b''\nassert pe.tell() == 100\nassert pe.readlines() == []\nassert pe.tell() == 100\nassert pe.read() == b''\nassert pe.tell() == 100\npe.close()\n\n# Same regression in text mode.\n(root / 'past_end.txt').write_text('hello')\npet = open(root / 'past_end.txt')\nassert pet.seek(100) == 100\nassert pet.read(5) == ''\nassert pet.tell() == 100\nassert pet.readline() == ''\nassert pet.tell() == 100\nassert pet.readlines() == []\nassert pet.tell() == 100\nassert pet.read() == ''\nassert pet.tell() == 100\npet.close()\n\n# read(N) with non-int arg raises TypeError (exact message diverges from CPython).\nnt = open(root / 'sized.txt')\ntry:\n    nt.read('5')\n    assert False, 'expected TypeError for non-int read size'\nexcept TypeError as exc:\n    msg = str(exc)\n    if is_monty:\n        assert msg == \"'str' object cannot be interpreted as an integer\", f'unexpected message: {msg}'\n    else:\n        assert msg == \"argument should be integer or None, not 'str'\", f'unexpected CPython message: {msg}'\nnt.close()\n\n# === Path.open() — same OsCall as builtin open() with `self` as the file ===\n# Mode/kwarg validation, open-time effects, returned wrapper types, and\n# context-manager semantics are all shared with `open()` above. The tests\n# here focus on what's specific to going through Path: that the implicit\n# `self` is used as the file argument, that positional and keyword `mode`\n# both work, and that validation still fires when called via Path.\n#\n# Each test uses its own dedicated file because earlier tests in this file\n# truncate `hello.txt` (`open(..., 'w').read()` truncates before raising).\n(root / 'path_open_text.txt').write_text('hello via Path.open\\n')\n(root / 'path_open_bytes.bin').write_bytes(b'\\x10\\x20\\x30')\n\npath_read = (root / 'path_open_text.txt').open()\nassert path_read.read() == 'hello via Path.open\\n'\npath_read.close()\n\n# Positional mode reaches the same wrapper as `open(..., 'rb')`.\nbinary_via_path = (root / 'path_open_bytes.bin').open('rb')\nassert str(type(binary_via_path)) == \"<class '_io.BufferedReader'>\"\nassert binary_via_path.read() == b'\\x10\\x20\\x30'\nbinary_via_path.close()\n\n# Keyword-only mode works too (no positional arg).\nkw_mode = (root / 'path_open_text.txt').open(mode='r')\nassert kw_mode.read() == 'hello via Path.open\\n'\nkw_mode.close()\n\n# `encoding='utf-8'` accepted as the documented no-op (Monty always uses UTF-8).\nenc = (root / 'path_open_text.txt').open('r', encoding='utf-8')\nassert enc.read() == 'hello via Path.open\\n'\nenc.close()\n\n# Context manager works through Path.open() — closes on exit on both paths.\nwith (root / 'path_open_text.txt').open() as f:\n    assert f.read() == 'hello via Path.open\\n'\nassert f.closed\n\n# Write through Path.open() lands the same content as a direct open().\n(root / 'path_open_write.txt').open('w').write('written via Path.open\\n')\nassert (root / 'path_open_write.txt').read_text() == 'written via Path.open\\n'\n\n# Mode validation is shared — Monty rejects '+' modes; CPython would accept\n# them, so this is monty-only.\nif is_monty:\n    try:\n        (root / 'path_open_text.txt').open('r+')\n        assert False, \"expected ValueError for Path.open('r+')\"\n    except ValueError as exc:\n        assert str(exc) == \"update modes ('+') are not yet supported\", f'unexpected Path.open r+ rejection: {exc}'\n\n    try:\n        (root / 'path_open_text.txt').open(buffering=0)\n        assert False, 'expected TypeError for Path.open(buffering=0)'\n    except TypeError as exc:\n        assert str(exc) == \"'buffering' argument is not yet supported\", (\n            f'unexpected Path.open buffering rejection: {exc}'\n        )\n\n# Open-time existence check still fires when called via Path.open().\ntry:\n    (root / 'path_open_missing.txt').open()\n    assert False, 'expected FileNotFoundError opening a missing file via Path.open'\nexcept FileNotFoundError as exc:\n    assert str(exc).startswith(\"[Errno 2] No such file or directory: '\")\n\n# === newline argument ===\n# The value is validated after the open, as in CPython: a missing file still raises\n# FileNotFoundError, and 'w' still creates the file before the ValueError.\n(root / 'nl.txt').write_bytes(b'a\\nb\\r\\nc\\rd')\ntry:\n    open(root / 'nl.txt', newline='x')\n    assert False, 'expected ValueError'\nexcept ValueError as exc:\n    assert str(exc) == 'illegal newline value: x'\ntry:\n    open(root / 'nl_missing.txt', newline='x')\n    assert False, 'expected FileNotFoundError'\nexcept FileNotFoundError:\n    pass\ntry:\n    open(root / 'nl_created.txt', 'w', newline='x')\n    assert False, 'expected ValueError'\nexcept ValueError as exc:\n    assert str(exc) == 'illegal newline value: x'\nassert (root / 'nl_created.txt').exists()\ntry:\n    open(root / 'nl.txt', 'rb', newline='')\n    assert False, 'expected ValueError'\nexcept ValueError as exc:\n    assert str(exc) == \"binary mode doesn't take a newline argument\"\ntry:\n    open(root / 'nl.txt', newline=1)\n    assert False, 'expected TypeError'\nexcept TypeError as exc:\n    assert str(exc) == \"open() argument 'newline' must be str or None, not int\"\n\n# Reading: None translates to '\\n', '' keeps the terminators, an explicit\n# terminator splits only on itself.\nnewline_reads = {\n    None: (['a\\n', 'b\\n', 'c\\n', 'd'], 'a\\n', 'b\\nc\\nd'),\n    '': (['a\\n', 'b\\r\\n', 'c\\r', 'd'], 'a\\n', 'b\\r\\nc\\rd'),\n    '\\n': (['a\\n', 'b\\r\\n', 'c\\rd'], 'a\\n', 'b\\r\\nc\\rd'),\n    '\\r': (['a\\nb\\r', '\\nc\\r', 'd'], 'a\\nb\\r', '\\nc\\rd'),\n    '\\r\\n': (['a\\nb\\r\\n', 'c\\rd'], 'a\\nb\\r\\n', 'c\\rd'),\n}\nfor nl, (lines, first, rest) in newline_reads.items():\n    with open(root / 'nl.txt', newline=nl) as f:\n        assert f.readlines() == lines\n    with open(root / 'nl.txt', newline=nl) as f:\n        assert f.readline() == first\n        assert f.read() == rest\n    with open(root / 'nl.txt', newline=nl) as f:\n        assert [line for line in f] == lines\nwith open(root / 'nl.txt') as f:\n    assert f.read(3) == 'a\\nb'\n    assert f.read() == '\\nc\\nd'\nwith (root / 'nl.txt').open(newline='') as f:\n    assert f.readline() == 'a\\n'\n\n# Writing: only '\\r' and '\\r\\n' translate, and write() reports the length as passed.\nnewline_writes = (\n    (None, b'x\\ny\\r\\nz'),\n    ('', b'x\\ny\\r\\nz'),\n    ('\\n', b'x\\ny\\r\\nz'),\n    ('\\r', b'x\\ry\\r\\rz'),\n    ('\\r\\n', b'x\\r\\ny\\r\\r\\nz'),\n)\nfor nl, raw in newline_writes:\n    with open(root / 'nl_out.txt', 'w', newline=nl) as f:\n        assert f.write('x\\ny\\r\\nz') == 6\n    assert (root / 'nl_out.txt').read_bytes() == raw\nwith open(root / 'nl_out.txt', 'w', newline='\\r\\n') as f:\n    assert f.write('one\\n') == 4\n    assert f.write('two\\n') == 4\nassert (root / 'nl_out.txt').read_bytes() == b'one\\r\\ntwo\\r\\n'\n\n# === Iteration ===\n(root / 'iter.txt').write_text('first\\nsecond\\nthird')\nf = open(root / 'iter.txt')\nassert iter(f) is f\nassert next(f) == 'first\\n'\nassert f.readline() == 'second\\n'\nassert next(f) == 'third'\ntry:\n    next(f)\n    assert False, 'expected StopIteration'\nexcept StopIteration:\n    pass\nassert next(f, 'done') == 'done'\nf.close()\n\n# next() with a default on an unread file loads it first\nf = open(root / 'iter.txt')\nassert next(f, 'done') == 'first\\n'\nf.close()\n(root / 'iter_empty.txt').write_text('')\nf = open(root / 'iter_empty.txt')\nassert next(f, 'done') == 'done'\nf.close()\nf = open(root / 'iter_empty.txt')\ntry:\n    next(f)\n    assert False, 'expected StopIteration'\nexcept StopIteration:\n    pass\nf.close()\n\n# for loops load an unread file on their first step\ncollected = []\nwith open(root / 'iter.txt') as f:\n    for line in f:\n        collected.append(line)\nassert collected == ['first\\n', 'second\\n', 'third']\nwith open(root / 'iter.txt') as f:\n    for line in f:\n        break\n    assert line == 'first\\n'\n    # the position is shared with every other read\n    assert [line for line in f] == ['second\\n', 'third']\n    assert [line for line in f] == []\n    assert f.read() == ''\n    f.seek(0)\n    # once loaded, any consumer can iterate the file\n    assert list(f) == ['first\\n', 'second\\n', 'third']\nwith open(root / 'iter.txt') as f:\n    assert [line.strip() for line in f if line.startswith('s')] == ['second']\nwith open(root / 'iter.txt') as f:\n    assert f.read(3) == 'fir'\n    assert list(f) == ['st\\n', 'second\\n', 'third']\nwith open(root / 'iter.txt') as f:\n    assert [f.readline(), f.readline()] == ['first\\n', 'second\\n']\n    assert sorted(f) == ['third']\ncollected = []\nwith open(root / 'lines.bin', 'rb') as f:\n    for line in f:\n        collected.append(line)\nassert collected == [b'a\\n', b'b\\n', b'c']\nwith open(root / 'iter_empty.txt') as f:\n    for line in f:\n        assert False, 'empty file yielded a line'\n\n# Consumers that cannot yield to the host see an unread file as not loaded yet.\nif is_monty:\n    f = open(root / 'iter.txt')\n    try:\n        list(f)\n        assert False, 'expected NotImplementedError'\n    except NotImplementedError as exc:\n        assert (\n            str(exc)\n            == \"iterating an unread _io.TextIOWrapper is only supported by 'for' loops and next(); call seek(0) first to load it\"\n        )\n    f.seek(0)\n    assert list(f) == ['first\\n', 'second\\n', 'third']\n    f.close()\n# generator expressions compile to `for` loops, so they can load an unread file\nwith open(root / 'iter.txt') as f:\n    assert list(line.strip() for line in f) == ['first', 'second', 'third']\n\n# closed and write-only files\nf = open(root / 'iter.txt')\nf.close()\ntry:\n    iter(f)\n    assert False, 'expected ValueError'\nexcept ValueError as exc:\n    assert str(exc) == 'I/O operation on closed file.'\ntry:\n    for line in f:\n        pass\n    assert False, 'expected ValueError'\nexcept ValueError as exc:\n    assert str(exc) == 'I/O operation on closed file.'\nw = open(root / 'iter_w.txt', 'w')\nassert iter(w) is w\ntry:\n    next(w)\n    assert False, 'expected UnsupportedOperation'\nexcept OSError as exc:\n    assert str(exc) == 'not readable'\ntry:\n    for line in w:\n        pass\n    assert False, 'expected UnsupportedOperation'\nexcept OSError as exc:\n    assert str(exc) == 'not readable'\nw.close()\n";

/// The complete `fstring__all.py` as upstream v1.2.0 ships it: CPython
/// caps format precision at INT_MAX - 1024 for every value kind, and
/// float repr crosses into scientific notation at 1e16 and 1e-5
/// (`up/crates/monty/test_cases/fstring__all.py:259,625-628`).
const String upstreamFstringAllV120 =
    "# === Basic f-strings ===\nassert f'hello' == 'hello'\nassert f'' == ''\n\n# === Simple interpolation ===\nx = 'world'\nassert f'hello {x}' == 'hello world'\n\n# multiple interpolations\na = 1\nb = 2\nassert f'{a} + {b} = {a + b}' == '1 + 2 = 3'\n\n# expression in f-string\nassert f'{1 + 2 + 3}' == '6'\n\n# === Value types ===\n# list value\nx = [1, 2, 3]\nassert f'list: {x}' == 'list: [1, 2, 3]'\n\n# bool value\nx = True\nassert f'value: {x}' == 'value: True'\n\n# int value\nassert f'{42}' == '42'\n\n# float value\nassert f'{3.14}' == '3.14'\n\n# None value\nassert f'{None}' == 'None'\n\n# === Conversion flags (!s, !r, !a) ===\n# conversion !s (str)\nassert f'{42!s}' == '42'\n\n# conversion !r (repr)\nassert f'{\"hello\"!r}' == \"'hello'\"\n\n# conversion !r on int (should be same as str for int)\nassert f'{42!r}' == '42'\n\n# conversion !r on list\nassert f'{[1, 2]!r}' == '[1, 2]'\n\n# conversion !s on string (no quotes)\nassert f'{\"hello\"!s}' == 'hello'\n\n# conversion !a (ascii) - escapes non-ASCII characters\nassert f'{\"café\"!a}' == \"'caf\\\\xe9'\"\nassert f'{\"hello\"!a}' == \"'hello'\"\nassert f'{\"日本\"!a}' == \"'\\\\u65e5\\\\u672c'\"\n\n# === String padding and alignment ===\n# format spec: width (left-aligned by default for strings)\nassert f'{\"hi\":10}' == 'hi        '\n\n# format spec: left align\nassert f'{\"hi\":<10}' == 'hi        '\n\n# format spec: right align\nassert f'{\"hi\":>10}' == '        hi'\n\n# format spec: center align\nassert f'{\"hi\":^10}' == '    hi    '\n\n# center align with odd padding\nassert f'{\"zip\":^6}' == ' zip  '\n\n# format spec: fill character\nassert f'{\"hi\":*>10}' == '********hi'\nassert f'{\"hi\":_<10}' == 'hi________'\nassert f'{\"hi\":*^10}' == '****hi****'\n\n# string truncation with precision\nassert f'{\"xylophone\":.5}' == 'xylop'\nassert f'{\"xylophone\":10.5}' == 'xylop     '\n\n# === Integer formatting ===\n# basic integer\nassert f'{42}' == '42'\n\n# integer with :d type\nassert f'{42:d}' == '42'\n\n# integer padding\nassert f'{42:4d}' == '  42'\nassert f'{42:04d}' == '0042'\n\n# integer with sign\nassert f'{42:+d}' == '+42'\nassert f'{42: d}' == ' 42'\nassert f'{-42:+d}' == '-42'\nassert f'{-42: d}' == '-42'\n\n# sign-aware padding\nassert f'{-23:=5d}' == '-  23'\n\n# i64::MIN: formatting must not overflow when taking abs of the minimum int\nassert f'{-9223372036854775808:d}' == '-9223372036854775808'\nassert f'{-9223372036854775808:+d}' == '-9223372036854775808'\nassert f'{-9223372036854775808:=22d}' == '-  9223372036854775808'\n\n# integer fill character with alignment\nassert f'{42:*>10d}' == '********42'\nassert f'{42:*<10d}' == '42********'\nassert f'{42:*^10d}' == '****42****'\n\n# === Integer non-decimal bases ===\n# binary\nassert f'{10:b}' == '1010'\nassert f'{-10:b}' == '-1010'\nassert f'{0:b}' == '0'\n\n# octal\nassert f'{8:o}' == '10'\nassert f'{-8:o}' == '-10'\n\n# hexadecimal (lower and upper)\nassert f'{255:x}' == 'ff'\nassert f'{-255:x}' == '-ff'\nassert f'{255:X}' == 'FF'\n\n# Uppercase `X` uppercases only the hex digits and the `0x` prefix (`0X`), NOT an\n# alphabetic fill char — the fill must stay as written.\nassert f'{180:a>8X}' == 'aaaaaaB4'\nassert f'{0xABC:f>8X}' == 'fffffABC'\nassert f'{255:#X}' == '0XFF'\nassert f'{255:b>#8X}' == 'bbbb0XFF'\n# Same rules for big integers (LongInt path).\nassert f'{2**70:a>25X}' == 'aaaaaaa400000000000000000'\nassert f'{2**68 + 0xAB:#X}' == '0X1000000000000000AB'\nassert f'{2**68 + 0xAB:#x}' == '0x1000000000000000ab'\n\n# === Sign-aware (`=`) padding applies to every numeric format, not just :d/:f ===\n# Previously pad_string's SignAware arm fell through, so width was silently\n# dropped for hex/oct/bin/exponential/general/percent.\nassert f'{255:=10x}' == '        ff'\nassert f'{-255:=10x}' == '-       ff'\nassert f'{8:=8b}' == '    1000'\nassert f'{8:=8o}' == '      10'\nassert f'{3.14:=10g}' == '      3.14'\nassert f'{-3.14:=10g}' == '-     3.14'\nassert f'{0.5:=12.2%}' == '      50.00%'\n# format_char has no sign; CPython accepts `=` here and degrades to right-align.\nassert f'{65:=10c}' == '         A'\n\n# === Sign prefix (`+`, ` `) applies to non-decimal integer bases too ===\n# format_int_base previously ignored spec.sign and only emitted '-' for negatives.\nassert f'{255:+x}' == '+ff'\nassert f'{255: x}' == ' ff'\nassert f'{8:+b}' == '+1000'\nassert f'{-255:X}' == '-FF'\n\n# === Integer as Unicode character (:c) ===\nassert f'{65:c}' == 'A'\nassert f'{0x4E2D:c}' == '中'\n\n# === Bool with format spec ===\n# bool is a subclass of int, so :d works\nassert f'{True:d}' == '1'\nassert f'{False:d}' == '0'\nassert f'{True:04d}' == '0001'\n\n# === Float formatting ===\n# basic float\nassert f'{3.14159}' == '3.14159'\n\n# float with :f type\nassert f'{3.141592653589793:f}' == '3.141593'\n\n# float precision\nassert f'{3.141592653589793:.2f}' == '3.14'\nassert f'{3.141592653589793:.4f}' == '3.1416'\n\n# float width and precision\nassert f'{3.141592653589793:06.2f}' == '003.14'\nassert f'{3.141592653589793:10.2f}' == '      3.14'\n\n# float with sign\nassert f'{3.14:+.2f}' == '+3.14'\nassert f'{-3.14:+.2f}' == '-3.14'\nassert f'{3.14:-.2f}' == '3.14'\nassert f'{-3.14:-.2f}' == '-3.14'\n\n# exponential notation\nassert f'{1234.5678:e}' == '1.234568e+03'\nassert f'{1234.5678:E}' == '1.234568E+03'\nassert f'{1234.5678:.2e}' == '1.23e+03'\nassert f'{0.00012345:.2e}' == '1.23e-04'\n\n# general format (g/G) - uses exponential for very large/small numbers\nassert f'{1.5:g}' == '1.5'\nassert f'{1.500:g}' == '1.5'\nassert f'{1234567890:g}' == '1.23457e+09'\n\n# percentage\nassert f'{0.25:%}' == '25.000000%'\nassert f'{0.25:.1%}' == '25.0%'\nassert f'{0.125:.0%}' == '12%'\n\n# zero precision rounds (banker's/half-even style per Python)\nassert f'{3.7:.0f}' == '4'\nassert f'{3.4:.0f}' == '3'\nassert f'{1234.5:.0e}' == '1e+03'\n\n# uppercase exponential\nassert f'{1234.5:E}' == '1.234500E+03'\n\n# float fill character with alignment + precision\nassert f'{3.14:*>10.2f}' == '******3.14'\nassert f'{3.14:*<10.2f}' == '3.14******'\nassert f'{3.14:*^10.2f}' == '***3.14***'\n\n# large and small magnitude exponents\nassert f'{1e100:.3e}' == '1.000e+100'\nassert f'{1e-100:.3e}' == '1.000e-100'\n\n# high precision reveals f64 representation\nassert f'{0.1:.20f}' == '0.10000000000000000555'\n\n# === Large dynamic precision ===\n# Precision > u16::MAX (65535) must not overflow Rust's `format!` precision\n# argument. Each of these exercises a different internal format code path.\nassert f'{1:.{10**6}f}' == '1.' + '0' * 10**6\nassert f'{1:.{10**6}e}' == '1.' + '0' * 10**6 + 'e+00'\nassert f'{1:.{10**6}E}' == '1.' + '0' * 10**6 + 'E+00'\nassert f'{0.5:.{10**6}%}' == '50.' + '0' * 10**6 + '%'\n# :g strips trailing zeros, so the visible result is short, but the\n# underlying format call still uses the full precision internally.\nassert f'{1.5:.{10**6}g}' == '1.5'\nassert f'{1e-10:.{10**6}g}' == '1.0000000000000000364321973154977415791655470655996396089904010295867919921875e-10'\nassert f'{0.0001:.{2**31 - 1025}g}' == ('0.000100000000000000004792173602385929598312941379845142364501953125')\n# CPython's float-to-string conversion caps the precision at INT_MAX - 1024\n# before looking at the value, so inf/nan, ints formatted as floats and complex\n# values all hit it; a str precision is a plain truncation and is unbounded.\n_p = 2**31 - 1024\nfor _value, _spec in (\n    (0.0001, f'.{_p}g'),\n    (1.5, f'.{_p}G'),\n    (1.5, f'.{_p}n'),\n    (1.5, f'.{_p}'),\n    (float('inf'), f'.{_p}f'),\n    (float('nan'), f'.{_p}e'),\n    (float('-inf'), f'.{_p}%'),\n    (float('inf'), f'#.{_p}g'),\n    (float('inf'), f'.{_p}_f'),\n    (1, f'.{_p}g'),\n    (True, f'.{_p}G'),\n    (10**30, f'.{_p}g'),\n    (1 + 2j, f'.{_p}g'),\n):\n    try:\n        format(_value, _spec)\n        assert False, f'expected precision too big for {_value!r} with {_spec!r}'\n    except ValueError as _e:\n        assert str(_e) == 'precision too big', f'{_spec}: {_e}'\ntry:\n    f'{1.5:.{2**31}g}'\n    assert False, 'expected precision too big'\nexcept ValueError as _e:\n    assert str(_e) == 'precision too big'\nassert f'{\"x\":.{2**31 - 1}}' == 'x'\n\n# === Large static width/precision ===\n# Static format specs are parsed at parse time and packed into a compact\n# bytecode constant; values around the previous u16 boundary must still\n# round-trip correctly.\nassert len(f'{1.5:.65535f}') == 65537\nassert len(f'{1.5:.65536f}') == 65538\nassert len(f'{42:65536d}') == 65536\n\n# Specs whose width or precision exceed the compact bytecode encoding\n# (MAX_ENCODED_WIDTH = 2**20 - 1, MAX_ENCODED_PRECISION = 2**21 - 2)\n# must still compile — the parser falls back to a dynamic spec so the\n# VM re-parses at runtime.\nassert len(f'{42:1048576d}') == 1048576\nassert len(f'{1.5:.2097151f}') == 2097153\n\n# Fill characters above Latin-1 (codepoint > 0xFF) don't fit the 8-bit\n# fill slot of the compact encoding either — they must also round-trip\n# through the dynamic-spec fallback rather than corrupting the encoded form.\nassert f'{\"hi\":日^10}' == '日日日日hi日日日日'\nassert f'{42:🐍>5d}' == '🐍🐍🐍42'\n\n# === Integer with float format types ===\n# Python allows formatting integers with float types\nassert f'{42:f}' == '42.000000'\nassert f'{42:.2f}' == '42.00'\nassert f'{42:.2e}' == '4.20e+01'\nassert f'{1234:g}' == '1234'\nassert f'{5:%}' == '500.000000%'\n\n# === Negative zero preserves sign ===\nassert f'{-0.0}' == '-0.0'\nassert f'{-0.0:f}' == '-0.000000'\nassert f'{-0.0:+.2f}' == '-0.00'\n\n# === The `z` flag coerces negative zero to positive zero ===\n# Coercion happens AFTER rounding to the target precision: a negative value that\n# rounds to zero becomes +0, but one that rounds to a nonzero value keeps its sign.\nassert f'{-0.0:z}' == '0.0'\nassert f'{-0.0:z.2f}' == '0.00'\nassert f'{-0.001:z.1f}' == '0.0'\nassert f'{-0.001:z.3f}' == '-0.001'\nassert f'{-0.04:z.1f}' == '0.0'\nassert f'{-0.05:z.1f}' == '-0.1'\nassert f'{-0.49:z.0f}' == '0'\nassert f'{-0.5:z.0f}' == '0'\nassert f'{-0.0:ze}' == '0.000000e+00'\nassert f'{-0.0:zg}' == '0'\nassert f'{-0.0:z%}' == '0.000000%'\nassert f'{0.0:z.2f}' == '0.00'\nassert f'{3.14:z.1f}' == '3.1'\nassert f'{-3.14:z.1f}' == '-3.1'\nassert f'{-0.0:+z.1f}' == '+0.0'\nassert f'{-0.0:z010.1f}' == '00000000.0'\nassert f'{0:zf}' == '0.000000'\nassert f'{True:zf}' == '1.000000'\n# `z` in fill position (followed by an align char) is a fill char, not the flag.\nassert f'{-0.0:z>8.1f}' == 'zzzz-0.0'\n\n\n# `z` is only valid for floating-point presentations.\ndef _z_err(fn):\n    try:\n        fn()\n        assert False, 'expected ValueError'\n    except ValueError as exc:\n        return str(exc)\n\n\nassert _z_err(lambda: f'{-5:z}') == 'Negative zero coercion (z) not allowed in integer format specifier'\nassert _z_err(lambda: f'{-5:zx}') == 'Negative zero coercion (z) not allowed in integer format specifier'\nassert _z_err(lambda: f'{True:z}') == 'Negative zero coercion (z) not allowed in integer format specifier'\nassert _z_err(lambda: f'{\"x\":z}') == 'Negative zero coercion (z) not allowed in string format specifier'\nassert _z_err(lambda: f'{5:z#}') == 'Negative zero coercion (z) not allowed in integer format specifier'\nassert _z_err(lambda: f'{\"x\":z#}') == 'Negative zero coercion (z) not allowed in string format specifier'\n# Precedence: a bad type code or grouping error still wins over the z error.\nassert _z_err(lambda: f'{5:z.2}') == 'Precision not allowed in integer format specifier'\n\n# === Infinity formatting across format codes ===\n# inf bypasses precision/width-pad zero rules and renders as 'inf'\nassert f'{float(\"inf\"):f}' == 'inf'\nassert f'{float(\"inf\"):e}' == 'inf'\nassert f'{float(\"inf\"):.3f}' == 'inf'\nassert f'{float(\"inf\"):+f}' == '+inf'\nassert f'{float(\"-inf\"):f}' == '-inf'\n\n# === Nested format specs ===\nwidth = 10\nassert f'{\"hi\":{width}}' == 'hi        '\n\n# nested alignment and width\nalign = '^'\nassert f'{\"test\":{align}{width}}' == '   test   '\n\nwidth, prec = 10, 3\nassert f'{3.14159:{width}.{prec}f}' == '     3.142'\n\n# nested precision\nprec = 3\nassert f'{\"xylophone\":.{prec}}' == 'xyl'\n\n\n# === f-string in function ===\ndef greet(name):\n    return f'Hello, {name}!'\n\n\nassert greet('World') == 'Hello, World!'\n\n\n# function returning formatted value\ndef format_num(n, w):\n    return f'{n:>{w}}'\n\n\nassert format_num('x', 5) == '    x'\n\n# === Escaping ===\n# double braces to escape\nassert f'{{}}' == '{}'\nassert f'{{x}}' == '{x}'\nassert f'{{{42}}}' == '{42}'\n\n# === Complex expressions ===\n# TODO: method call on literal - parser doesn't support this yet\n# assert f'{\"hello\".upper()}' == 'HELLO', 'method call on literal'\n\n# TODO: method call on variable - str.upper() not implemented yet\n# s = 'hello'\n# assert f'{s.upper()}' == 'HELLO', 'method call on variable'\n\n# subscript in f-string\nlst = [10, 20, 30]\nassert f'{lst[1]}' == '20'\n\n# dict lookup\nd = {'a': 1, 'b': 2}\nassert f'{d[\"a\"]}' == '1'\n\n# TODO: conditional expression - parser doesn't support IfExp yet\n# x = 5\n# assert f'{x if x > 0 else -x}' == '5', 'conditional positive'\n# x = -5\n# assert f'{-x if x < 0 else x}' == '5', 'conditional negative'\n\n# === String concatenation ===\nname = 'world'\n# regular string + f-string (implicit concatenation)\nassert f'hello {name}' == 'hello world'\n\n# === Empty interpolation expression ===\n# (this should be a syntax error, but test current behavior)\n# assert f'{}' would be syntax error\n\n# === Whitespace in format spec ===\n# no extra whitespace handling needed, width handles it\nassert f'{\"x\":5}' == 'x    '\n\n# === Empty format spec with various types ===\n# trailing `:` with no spec behaves like no spec\nassert f'{42:}' == '42'\nassert f'{3.14:}' == '3.14'\nassert f'{\"hi\":}' == 'hi'\n\n# === Unicode character counting in padding ===\nx = 'café'\nassert f'{x:_<10}' == 'café______'\nassert f'{x:_>10}' == '______café'\nassert f'{x:_^10}' == '___café___'\nassert f'{x:_^11}' == '___café____'\nassert f'{x:é<10}' == 'cafééééééé'\nassert f'{x:é>10}' == 'éééééécafé'\nassert f'{x:é^10}' == 'ééécaféééé'\nassert f'{x:é^11}' == 'ééécafééééé'\n\n# === Conversion flag with type spec ===\n# conversion flag produces string, so 's' format should work\nassert f'{42!r:s}' == '42'\n\n# === Conversion flag + spec: the spec is validated as a *string* spec ===\n# `!s`/`!r`/`!a` convert to a string first, so flags that are illegal for text\n# must be rejected exactly as they are for a real string value — and the value\n# and its converted form must raise the *same* error. Valid string flags work:\nassert f'{123!s:05}' == '12300'\nassert f'{123!r:>6}' == '   123'\nwidth = 6\nassert f'{123!r:>{width}}' == '   123'\nassert f'{3.14159!r:.4}' == '3.14'\n\n\n# Illegal-for-text flags raise the same ValueError as on a bare string.\ndef _conv_err(fn):\n    try:\n        fn()\n        assert False, 'expected ValueError'\n    except ValueError as exc:\n        return str(exc)\n\n\nassert _conv_err(lambda: f'{123!s:#}') == 'Alternate form (#) not allowed in string format specifier'\nassert _conv_err(lambda: f'{123!r:,}') == \"Cannot specify ',' with 's'.\"\nassert _conv_err(lambda: f'{123!r:_}') == \"Cannot specify '_' with 's'.\"\nassert _conv_err(lambda: f'{123!s:+}') == 'Sign not allowed in string format specifier'\nassert _conv_err(lambda: f'{123!s: }') == 'Space not allowed in string format specifier'\nassert _conv_err(lambda: f'{123!s:=}') == \"'=' alignment not allowed in string format specifier\"\nassert _conv_err(lambda: f'{123!r:#x}') == \"Unknown format code 'x' for object of type 'str'\"\nassert _conv_err(lambda: f'{123!s:.2f}') == \"Unknown format code 'f' for object of type 'str'\"\n\n# Precedence among multiple violations matches CPython (grouping > type > sign >\n# alternate > `=`), and a value formats identically with or without `!s`/`!r`.\nassert (\n    _conv_err(lambda: f'{\"x\":=#}')\n    == _conv_err(lambda: f'{1!r:=#}')\n    == 'Alternate form (#) not allowed in string format specifier'\n), 'alternate beats = align'\nassert (\n    _conv_err(lambda: f'{\"x\":+#}') == _conv_err(lambda: f'{1!s:+#}') == 'Sign not allowed in string format specifier'\n), 'sign beats alternate'\nassert _conv_err(lambda: f'{\"x\":,x}') == _conv_err(lambda: f'{1!r:,x}') == \"Cannot specify ',' with 'x'.\", (\n    'grouping beats type'\n)\n\n# === Zero-padding with negative numbers ===\n# zero-padding should use sign-aware alignment\nx = -42\nassert f'{x:05d}' == '-0042'\n\n# === Debug/self-documenting expressions (=) ===\na = 42\nassert f'{a=}' == 'a=42'\nassert f'{a = }' == 'a = 42'\nname = 'test'\nassert f'{name=}' == \"name='test'\"\nassert f'{name = }' == \"name = 'test'\"\nassert f'{name=!s}' == 'name=test'\nassert f'{name=!r}' == \"name='test'\"\nassert f'{1+1=}' == '1+1=2'\n# a format spec applies to the *value*, not the (default-repr) string — the\n# implicit repr only kicks in when there is no spec and no conversion\n_v = 6.28318\nassert f'{_v=:.3f}' == '_v=6.283'\nassert f'{_v=:>10.2f}' == '_v=      6.28'\nassert f'{_v=!r:>12}' == '_v=     6.28318'\nassert f'{_v=}' == '_v=6.28318'\n# an *explicit empty* spec (`{x=:}`) formats with str, NOT the repr default —\n# `format(x, \"\")` equals `str(x)`, so the colon disables the debug repr default\nassert f'{name=:}' == 'name=test'\nassert f'{a=:}' == 'a=42'\n_b = True\nassert f'{_b=:}' == '_b=True'\nassert f'{name = :}' == 'name = test'\nassert f'{name=!r:}' == \"name='test'\"\n\n# === Comma thousands separator ===\nassert f'{1234567:,}' == '1,234,567'\nassert f'{1234:,}' == '1,234'\nassert f'{12:,}' == '12'\nassert f'{0:,}' == '0'\nassert f'{-1234567:,}' == '-1,234,567'\nassert f'{1234567:,d}' == '1,234,567'\nassert f'{1234567.891:,f}' == '1,234,567.891000'\nassert f'{1234567.891:,.2f}' == '1,234,567.89'\nassert f'{-1234567.891:,.2f}' == '-1,234,567.89'\nassert f'{1234567.891:,e}' == '1.234568e+06'\nassert f'{1234.5:,g}' == '1,234.5'\nassert f'{12.3456:,%}' == '1,234.560000%'\nassert f'{1234:+,}' == '+1,234'\nassert f'{-1234:+,}' == '-1,234'\nassert f'{1234: ,}' == ' 1,234'\n\n# === Underscore thousands separator ===\nassert f'{1234567:_}' == '1_234_567'\nassert f'{1234567:_d}' == '1_234_567'\nassert f'{1234567.891:_.2f}' == '1_234_567.89'\n# Underscore groups binary/octal/hex in fours\nassert f'{255:_b}' == '1111_1111'\nassert f'{0xABCDEF:_x}' == 'ab_cdef'\nassert f'{0xABCDEF:_X}' == 'AB_CDEF'\nassert f'{0o12345670:_o}' == '1234_5670'\n\n# === Grouping with zero-padding (padding is itself grouped) ===\nassert f'{1234567:012,d}' == '0,001,234,567'\nassert f'{1234:010,}' == '00,001,234'\nassert f'{-1234:010,}' == '-0,001,234'\nassert f'{1234:08,}' == '0,001,234'\nassert f'{1234:07,}' == '001,234'\nassert f'{1234:05,}' == '1,234'\nassert f'{1234567.891:020,.2f}' == '0,000,001,234,567.89'\nassert f'{255:010_b}' == '0_1111_1111'\nassert f'{1234:0=10,}' == '00,001,234'\nassert f'{1:0=+9_g}' == '+0_000_001'\n\n# === Grouping with explicit alignment (fill is not grouped) ===\nassert f'{1234:=10,}' == '     1,234'\nassert f'{1234:=+10,}' == '+    1,234'\nassert f'{1234:>12,}' == '       1,234'\nassert f'{1234:*>12,}' == '*******1,234'\n\n# === Alternate form (#) on integer bases adds the 0b/0o/0x prefix ===\nassert f'{255:#x}' == '0xff'\nassert f'{255:#X}' == '0XFF'\nassert f'{5:#b}' == '0b101'\nassert f'{8:#o}' == '0o10'\nassert f'{-255:#x}' == '-0xff'\nassert f'{0:#x}' == '0x0'\nassert f'{255:#d}' == '255'\n# prefix counts toward width and sits before zero padding\nassert f'{255:#10x}' == '      0xff'\nassert f'{255:#010x}' == '0x000000ff'\nassert f'{-255:#010x}' == '-0x00000ff'\nassert f'{255:+#x}' == '+0xff'\n# prefix with alignment / grouping\nassert f'{255:<#10x}' == '0xff      '\nassert f'{255:^#10x}' == '   0xff   '\nassert f'{255:=#10x}' == '0x      ff'\nassert f'{255:*=#10x}' == '0x******ff'\nassert f'{0xABCDEF:#_x}' == '0xab_cdef'\nassert f'{0xABCDEF:#010_x}' == '0x0ab_cdef'\n\n# === Alternate form (#) on floats forces a decimal point ===\nassert f'{1.0:#.0f}' == '1.'\nassert f'{0.0:#.0f}' == '0.'\nassert f'{1.0:#.0e}' == '1.e+00'\nassert f'{3.14:+#.2f}' == '+3.14'\nassert f'{0.5:#.0%}' == '50.%'\n# explicit g/G keeps trailing zeros under #\nassert f'{1.0:#g}' == '1.00000'\nassert f'{100.0:#g}' == '100.000'\nassert f'{1.5:#.3g}' == '1.50'\nassert f'{1234.0:#.4g}' == '1234.'\n# default float presentation: # is a no-op (shortest repr already has a point)\nassert f'{3.14:#}' == '3.14'\n# `#g`/`#G`/type-less keep every trailing zero, so the digit count scales with\n# precision past Rust's formatter cap (regression: it used to silently truncate\n# to ~65k digits). Verify the count is exact, not clamped.\nassert f'{1.0:#.10g}' == '1.000000000'\nassert f'{1.0:#.10G}' == '1.000000000'\nassert f'{123456.0:#.10}' == '123456.0000'\nassert len(f'{1.0:#.70000g}') == 70001\nassert len(f'{1.0:#.70000}') == 70001\n\n# === inf / nan: case follows the presentation, never `.0` ===\n_inf = float('inf')\n_nan = float('nan')\nassert f'{_inf}' == 'inf'\nassert f'{-_inf}' == '-inf'\nassert f'{_nan}' == 'nan'\nassert str(_inf) == 'inf' and repr(_nan) == 'nan', 'inf/nan str/repr'\nassert f'{_inf:f}' == 'inf' and f'{_inf:F}' == 'INF', 'inf f vs F case'\nassert f'{_nan:e}' == 'nan' and f'{_nan:E}' == 'NAN', 'nan e vs E case'\nassert f'{_inf:g}' == 'inf' and f'{_inf:G}' == 'INF', 'inf g vs G case'\nassert f'{_nan:%}' == 'nan%'\nassert f'{_inf:+.2f}' == '+inf'\n# grouping/zero-pad on a non-finite value must not panic and ignores the comma\nassert f'{_inf:08,}' == '00000inf'\nassert f'{-_inf:+020,}' == '-0000000000000000inf'\nassert f'{_nan:,}' == 'nan'\n\n# === float repr uses scientific notation past CPython's thresholds ===\nassert f'{1e16}' == '1e+16'\nassert f'{1e15}' == '1000000000000000.0'\nassert f'{1e-5}' == '1e-05'\nassert f'{1e-4}' == '0.0001'\nassert f'{1.2345678901234568e16}' == '1.2345678901234568e+16'\nassert f'{1e100}' == '1e+100'\n\n# === type-less float spec uses repr digits, not g (precision-6) ===\nassert f'{1234567.0:}' == '1234567.0'\nassert f'{1234567.0:>12}' == '   1234567.0'\nassert f'{1234.5678:+,}' == '+1,234.5678'\n\n# === bool is an int subclass under a (non-empty) format spec ===\nassert f'{True}' == 'True' and f'{True:}' == 'True', 'bare bool is the word'\nassert f'{True: }' == ' 1'\nassert f'{False:05}' == '00000'\nassert f'{True:#06x}' == '0x0001'\nassert f'{True:.2f}' == '1.00'\n\n# === big integers honour the full mini-language ===\n_big = 2**70\nassert f'{_big:,}' == '1,180,591,620,717,411,303,424'\nassert f'{_big:+}' == '+1180591620717411303424'\nassert f'{_big:#x}' == '0x400000000000000000'\nassert f'{_big:#o}' == '0o200000000000000000000000'\nassert f'{-(2**63):>25}' == '     -9223372036854775808'\nassert f'{2**63:.3e}' == '9.223e+18'\n\n# === precision is rejected on integer presentations ===\nfor _spec in ('.2d', '.2', '.2x', '.2b', '.0c'):\n    try:\n        f'{42:{_spec}}'\n        assert False, f'expected precision on int spec {_spec!r} to fail'\n    except ValueError as _e:\n        assert str(_e) == 'Precision not allowed in integer format specifier', f'{_spec}: {_e}'\n\n# === c rejects a sign; strings reject signs and `=` alignment ===\ntry:\n    f'{65:+c}'\n    assert False, 'expected sign with c to fail'\nexcept ValueError as _e:\n    assert str(_e) == \"Sign not allowed with integer format specifier 'c'\", f'sign+c: {_e}'\ntry:\n    f'{\"x\":+}'\n    assert False, 'expected sign on string to fail'\nexcept ValueError as _e:\n    assert str(_e) == 'Sign not allowed in string format specifier', f'sign+str: {_e}'\ntry:\n    f'{\"x\": }'\n    assert False, 'expected space on string to fail'\nexcept ValueError as _e:\n    assert str(_e) == 'Space not allowed in string format specifier', f'space+str: {_e}'\ntry:\n    f'{\"x\":=5}'\n    assert False, 'expected = alignment on string to fail'\nexcept ValueError as _e:\n    assert str(_e) == \"'=' alignment not allowed in string format specifier\", f'=+str: {_e}'\n\n# === `0` flag with an explicit alignment is just a `0` fill, not sign-aware ===\nassert f'{-42:<05}' == '-4200'\nassert f'{42:^05}' == '04200'\nassert f'{42:>05}' == '00042'\nassert f'{42:*<05}' == '42***'\nassert f'{-42:05}' == '-0042'\nassert f'{\"hi\":05}' == 'hi000'\n\n# === `c` is a numeric presentation: right-aligned by default ===\nassert f'{65:5c}' == '    A'\nassert f'{65:<5c}' == 'A    '\nassert f'{65:05c}' == '0000A'\n\n# === `n` (locale number): like `d` for int, `g` for float (C locale here) ===\nassert f'{1234567:n}' == '1234567'\nassert f'{1234567.0:n}' == '1.23457e+06'\nassert f'{-42:+n}' == '-42'\nassert f'{2**70:n}' == '1180591620717411303424'\nassert f'{True:n}' == '1'\n# n forbids an explicit grouping and (for ints) a precision\ntry:\n    f'{1234:,n}'\n    assert False, 'expected , with n to fail'\nexcept ValueError as _e:\n    assert str(_e) == \"Cannot specify ',' with 'n'.\", f',n: {_e}'\ntry:\n    f'{42:.2n}'\n    assert False, 'expected precision with int n to fail'\nexcept ValueError as _e:\n    assert str(_e) == 'Precision not allowed in integer format specifier', f'.2n: {_e}'\n\n# === Fractional grouping (Python 3.14): [.precision][grouping] ===\nassert f'{1234.5678:.6_f}' == '1234.567_800'\nassert f'{1234567.89:,.4_f}' == '1,234,567.890_0'\nassert f'{12345.678:._f}' == '12345.678_000'\nassert f'{1234567.891:,._f}' == '1,234,567.891_000'\n\n# === Type-less float with an explicit precision (g-like, one exp earlier) ===\nassert f'{100.0:.3}' == '1e+02'\nassert f'{1.0:.0}' == '1e+00'\nassert f'{1234.5678:.6}' == '1234.57'\nassert f'{9.99:.1g}' == '1e+01'\n\n# === Error precedence: an invalid type code beats the #/sign checks ===\ntry:\n    f'{3.14:#c}'\n    assert False, 'expected #c on float to fail'\nexcept ValueError as _e:\n    assert str(_e) == \"Unknown format code 'c' for object of type 'float'\", f'#c float: {_e}'\ntry:\n    f'{42:#s}'\n    assert False, 'expected #s on int to fail'\nexcept ValueError as _e:\n    assert str(_e) == \"Unknown format code 's' for object of type 'int'\", f'#s int: {_e}'\n";

/// The complete `str__format.py` as upstream v1.2.0 ships it:
/// `str.format` raises 'precision too big' one precision above
/// CPython's cap
/// (`up/crates/monty/test_cases/str__format.py:68`).
const String upstreamStrFormatV120 =
    "import re\nfrom collections import deque\nfrom datetime import datetime, time, timedelta\n\n\ndef capture_error(template, *args, **kwargs):\n    try:\n        template.format(*args, **kwargs)\n    except Exception as exc:\n        return type(exc).__name__, str(exc)\n    return None\n\n\nassert '{} {}'.format('one', 'two') == 'one two'\nassert '{1} {0}'.format('one', 'two') == 'two one'\nassert '{first} {last}'.format(first='Jean-Luc', last='Picard') == 'Jean-Luc Picard'\nassert '{a-b}'.format(**{'a-b': 7}) == '7'\nunicode_index = '{٠}'\nassert unicode_index.format('zero') == 'zero'\nmathematical_index = '{𝟘}'\nassert mathematical_index.format('zero') == 'zero'\nliteral_only = 'unchanged'\nassert literal_only.format(1, ignored=2) == 'unchanged'\n\n\nclass Record:\n    def __init__(self, value):\n        self.value = value\n\n\nassert '{0.value:04d}'.format(Record(1)) == '0001'\nassert capture_error('{0.missing}', Record(2001)) == (\n    'AttributeError',\n    \"'Record' object has no attribute 'missing'\",\n)\nperson = {'first': 'Jean-Luc', 'last': 'Picard'}\nassert '{p[first]} {p[last]}'.format(p=person) == 'Jean-Luc Picard'\nassert capture_error('{0[missing]}', person) == ('KeyError', \"'missing'\")\nplant = {'kinds': [{'name': 'oak'}]}\nassert '{p[kinds][0][name]}'.format(p=plant) == 'oak'\nassert capture_error('{0[2]}', [10, 20]) == ('IndexError', 'list index out of range')\nassert '{0[１]}'.format([10, 20]) == '20'\nassert '{0[𝟙]}'.format(['zero', 'one']) == 'one'\nunusual_item_keys = '{0[a:b]} {0[a!b]} {0[a}b]}'\nassert unusual_item_keys.format({'a:b': 1, 'a!b': 2, 'a}b': 3}) == '1 2 3'\n\nnative_datetime = datetime(2001, 2, 3, 4, 5)\nassert '{0.year}-{0.hour}'.format(native_datetime) == '2001-4'\nassert '{0.days}'.format(timedelta(days=2)) == '2'\nassert '{0.maxlen}'.format(deque(maxlen=4)) == '4'\nnative_match = re.match('a', 'abc')\nassert '{0.string}'.format(native_match) == 'abc'\n\nnul = chr(0)\nassert ('{0!' + nul + '}').format('a') == 'a'\nassert ('{0!' + nul + ':04d}').format(1) == '0001'\nassert '{0!s} {0!r} {0!a}'.format('räpr') == \"räpr 'räpr' 'r\\\\xe4pr'\"\nassert '{0!a}'.format('😀') == \"'\\\\U0001f600'\"\nassert '{0:>10}'.format('test') == '      test'\nassert '{0:_<10.5}'.format('xylophone') == 'xylop_____'\nassert '{0:+06.2f}'.format(3.14159) == '+03.14'\nassert '{:５}'.format(1) == '    1'\nassert '{:.２f}'.format(1.25) == '1.25'\nassert '{:._}'.format(True) == '1'\nassert '{:._}'.format('x') == 'x'\nassert capture_error('{:.6_n}', 1.234567) == ('ValueError', \"Cannot specify '_' with 'n'.\")\nassert '{0:.2147482623g}'.format(0.0001) == ('0.000100000000000000004792173602385929598312941379845142364501953125')\nassert capture_error('{0:.2147482624g}', 0.0001) == ('ValueError', 'precision too big')\nassert capture_error('{0:.2147482624f}', float('inf')) == ('ValueError', 'precision too big')\nassert capture_error('{0:.{1}e}', 1, 2**31) == ('ValueError', 'precision too big')\nassert '{:}'.format(True) == 'True'\nassert '{0!r:>6}'.format(123) == '   123'\nassert '{0:{align}{width}}'.format('test', align='^', width=10) == '   test   '\nassert '{0:{width}.{precision}f}'.format(2.7182, width=5, precision=2) == ' 2.72'\nassert '{0:{spec[align]}}'.format('x', spec={'align': '^5'}) == '  x  '\nassert '{} {:{}}'.format(1, 2, 3) == '1   2'\ndt = datetime(2001, 2, 3, 4, 5)\nassert '{0:%Y-%m-%d %H:%M}'.format(dt) == '2001-02-03 04:05'\nescaped_datetime_spec = '{0:{{%Y}}}'\nassert escaped_datetime_spec.format(dt) == '{2001}'\nassert '{0:{1}} {0:>3} {0:}'.format(7, '03d') == '007   7 7'\nassert '{0:{1:}}'.format(7, '03d') == '007'\n\nassert '{{}}'.format() == '{}'\nassert '{{{0}}}'.format('x') == '{x}'\nassert ''.format() == ''\nshared = {'x': 'value'}\nassert '{0} {0!r} {0[x]}'.format(shared) == \"{'x': 'value'} {'x': 'value'} value\"\n\nassert capture_error('{} {0}', 'a', 'b') == (\n    'ValueError',\n    'cannot switch from automatic field numbering to manual field specification',\n)\nassert capture_error('{0} {}', 'a', 'b') == (\n    'ValueError',\n    'cannot switch from manual field specification to automatic field numbering',\n)\nassert capture_error('{2}', 'a') == (\n    'IndexError',\n    'Replacement index 2 out of range for positional args tuple',\n)\nassert capture_error('{missing}') == ('KeyError', \"'missing'\")\nassert capture_error('{') == ('ValueError', \"Single '{' encountered in format string\")\nassert capture_error('}') == ('ValueError', \"Single '}' encountered in format string\")\nassert capture_error('{0!x}', 'a') == ('ValueError', 'Unknown conversion specifier x')\nassert capture_error('{0!}}', 'a') == ('ValueError', 'Unknown conversion specifier }')\nassert capture_error('{0!}{', 'a') == ('ValueError', \"expected ':' after conversion specifier\")\nassert capture_error('{0! }', 'a') == ('ValueError', 'Unknown conversion specifier \\\\x20')\nassert capture_error('{0!é}', 'a') == ('ValueError', 'Unknown conversion specifier \\\\xe9')\nassert capture_error('{0!😀}', 'a') == ('ValueError', 'Unknown conversion specifier \\\\x1f600')\nassert capture_error('{0!rs}', 'a') == ('ValueError', \"expected ':' after conversion specifier\")\nassert capture_error('{0:=5}', 'a') == ('ValueError', \"'=' alignment not allowed in string format specifier\")\nassert capture_error('{0[foo}', {'foo': 'a'}) == ('ValueError', \"expected '}' before end of string\")\nassert capture_error('{0!', 'a') == (\n    'ValueError',\n    'end of string while looking for conversion specifier',\n)\nassert capture_error('{0!s', 'a') == ('ValueError', \"unmatched '{' in format spec\")\nassert capture_error('{0!}', 'a') == ('ValueError', \"unmatched '{' in format spec\")\nassert capture_error('{missing:') == ('ValueError', \"unmatched '{' in format spec\")\nassert capture_error('{missing!rs}') == (\n    'ValueError',\n    \"expected ':' after conversion specifier\",\n)\nassert capture_error('{missing!x}') == ('KeyError', \"'missing'\")\n\n\nclass BrokenRepr:\n    def __repr__(self):\n        raise RuntimeError('repr failed')\n\n\nassert capture_error('{0!r:{missing}}', BrokenRepr()) == ('RuntimeError', 'repr failed')\nassert capture_error('{0!r:q}', BrokenRepr()) == ('RuntimeError', 'repr failed')\nassert capture_error('{0:.2q}', 1) == (\n    'ValueError',\n    \"Unknown format code 'q' for object of type 'int'\",\n)\nassert capture_error('{0:.}', 1) == ('ValueError', 'Format specifier missing precision')\nassert capture_error('{0{}}', 'a') == ('ValueError', \"unexpected '{' in field name\")\nassert capture_error('{0..x}', 'a') == ('ValueError', 'Empty attribute in format string')\nassert capture_error('{0[]}', {'': 1}) == ('ValueError', 'Empty attribute in format string')\nassert capture_error('{0[x]x}', {'x': 1}) == (\n    'ValueError',\n    \"Only '.' or '[' may follow ']' in format field specifier\",\n)\nassert capture_error('{0[x}', {'x': 1}) == ('ValueError', \"expected '}' before end of string\")\nassert capture_error('{0:{1}', 1, 2) == ('ValueError', \"unmatched '{' in format spec\")\nassert capture_error('{0:{spec[a}b]}}', 'x', spec={'a}b': '^5'}) == (\n    'ValueError',\n    \"expected '}' before end of string\",\n)\nassert capture_error('{0:{}}', 1, 2) == (\n    'ValueError',\n    'cannot switch from manual field specification to automatic field numbering',\n)\nassert capture_error('{:{0}}', 1, 2) == (\n    'ValueError',\n    'cannot switch from automatic field numbering to manual field specification',\n)\nassert capture_error('{0:{1:{2}}}', 1, 2, 3) == ('ValueError', 'Max string recursion exceeded')\nassert capture_error('{999999999999999999999999999999999999}', 1) == (\n    'ValueError',\n    'Too many decimal digits in format string',\n)\nassert capture_error('{0[999999999999999999999999999999999999]}', {}) == (\n    'ValueError',\n    'Too many decimal digits in format string',\n)\n\nassert '{:0=10,}'.format(1234) == '00,001,234'\nassert '{:0=15,.2f}'.format(1234.5) == '0,000,001,234.50'\nassert '{:0=+9_g}'.format(1) == '+0_000_001'\nassert '{:>010,}'.format(1234) == '000001,234'\nassert '{:x=10,}'.format(1234) == 'xxxxx1,234'\n\nassert capture_error('{0:{1:{{}}}}', 'x', 'y') == ('ValueError', 'Max string recursion exceeded')\nassert capture_error('{0:{{}}<9}', 5) == (\n    'ValueError',\n    \"Invalid format specifier '{}<9' for object of type 'int'\",\n)\n\nassert '{[0]}'.format(['a']) == 'a'\nassert '{.value}'.format(Record(1)) == '1'\nassert capture_error('{x=}', x=1) == ('KeyError', \"'x='\")\nassert '{:%H:%M}'.format(time(4, 5)) == '04:05'\n\nfor width in range(130):\n    grouped = '{:0{},}'.format(7, width)\n    assert grouped.replace(',', '').lstrip('0') == '7'\n    assert len(grouped) in (width, width + 1), grouped\n    assert all(len(group) == 3 for group in grouped.split(',')[1:]), grouped\n";

/// The complete `dataclass__options.py` as upstream v1.2.0 ships it:
/// a frozen field assignment is refused with "cannot assign to field
/// 'x'" (`up/crates/monty/test_cases/dataclass__options.py:47`).
const String upstreamDataclassOptionsV120 =
    "# The `@dataclass(...)` keyword form, for the options Monty implements:\n# `eq` and `frozen`. All behaviour here matches CPython.\nfrom dataclasses import FrozenInstanceError, dataclass\n\n\n# === The empty call form behaves like the bare decorator ===\n@dataclass()\nclass Called:\n    x: int\n\n\nassert repr(Called(1)) == 'Called(x=1)'\nassert Called(1) == Called(1)\n\n\n# === Explicitly spelling the defaults matches the bare decorator ===\n@dataclass(eq=True, frozen=False)\nclass Defaults:\n    x: int\n\n\nassert Defaults(1) == Defaults(1)\ntry:\n    hash(Defaults(1))\n    assert False, 'a default dataclass is unhashable'\nexcept TypeError as e:\n    assert str(e) == \"unhashable type: 'Defaults'\"\n\n\n# === frozen=True: construction, repr and equality are unchanged ===\n@dataclass(frozen=True)\nclass Point:\n    x: int\n    y: int\n\n\np = Point(1, 2)\nassert repr(p) == 'Point(x=1, y=2)'\nassert Point(1, 2) == Point(1, 2)\nassert Point(1, 2) != Point(1, 3)\n\n# === frozen=True rejects attribute assignment ===\ntry:\n    p.x = 9\n    assert False, 'expected a frozen assignment to raise'\nexcept FrozenInstanceError as e:\n    assert str(e) == \"cannot assign to field 'x'\"\nassert p.x == 1\n\n# Assigning an attribute that is not a declared field is refused too.\ntry:\n    p.extra = 1\n    assert False, 'expected a frozen assignment to raise'\nexcept FrozenInstanceError as e:\n    assert str(e) == \"cannot assign to field 'extra'\"\n\n# === frozen=True with the default eq=True is hashable, by field values ===\nassert hash(Point(1, 2)) == hash(Point(1, 2))\nassert hash(Point(1, 2)) == hash((1, 2))\nassert len({Point(1, 2), Point(1, 2)}) == 1\nassert len({Point(1, 2), Point(3, 4)}) == 2\nassert {Point(1, 2): 'a'}[Point(1, 2)] == 'a'\n\n\n# === eq=False falls back to identity, and stays hashable ===\n@dataclass(eq=False)\nclass NoEq:\n    x: int\n\n\na = NoEq(1)\nassert a == a\nassert not (NoEq(1) == NoEq(1)), 'distinct instances are unequal without eq'\nassert isinstance(hash(a), int), 'eq=False leaves the class hashable'\nassert repr(NoEq(1)) == 'NoEq(x=1)'\n\n\n# === eq=False with frozen=True hashes by identity, not by fields ===\n@dataclass(eq=False, frozen=True)\nclass NoEqFrozen:\n    x: int\n\n\nb = NoEqFrozen(1)\nassert isinstance(hash(b), int)\nassert hash(b) == hash(b)\ntry:\n    b.x = 2\n    assert False, 'expected a frozen assignment to raise'\nexcept FrozenInstanceError as e:\n    assert str(e) == \"cannot assign to field 'x'\"\n\n\n# === A generated hash outranks the class body's own __eq__/__hash__ ===\n# CPython writes the hash after the body has run, and treats a `__hash__ = None`\n# sitting beside an `__eq__` as the opt-out `type` inserted rather than one the\n# author wrote — so `eq=True, frozen=True` hashes by fields through both.\n@dataclass(frozen=True)\nclass BodyEq:\n    x: int\n\n    def __eq__(self, other):\n        return True\n\n\nassert hash(BodyEq(1)) == hash((1,))\n\n\n@dataclass(frozen=True)\nclass BodyEqNoneHash:\n    x: int\n\n    def __eq__(self, other):\n        return True\n\n    __hash__ = None\n\n\nassert hash(BodyEqNoneHash(1)) == hash((1,))\n\n\n# A `__hash__ = None` with no `__eq__` beside it is deliberate, and survives.\n@dataclass(frozen=True)\nclass NoneHash:\n    x: int\n\n    __hash__ = None\n\n\ntry:\n    hash(NoneHash(1))\n    assert False, 'expected an explicit __hash__ = None to stay unhashable'\nexcept TypeError as e:\n    assert str(e) == \"unhashable type: 'NoneHash'\"\n\n\n# So does a real one, which no decoration overwrites.\n@dataclass(frozen=True)\nclass BodyHash:\n    x: int\n\n    def __hash__(self):\n        return 7\n\n\nassert hash(BodyHash(1)) == 7\n\n\n# === eq=False generates no hash, so the body's __eq__ opt-out stands ===\n@dataclass(eq=False, frozen=True)\nclass NoEqBodyEq:\n    x: int\n\n    def __eq__(self, other):\n        return True\n\n\ntry:\n    hash(NoEqBodyEq(1))\n    assert False, 'expected a body __eq__ to leave the class unhashable'\nexcept TypeError as e:\n    assert str(e) == \"unhashable type: 'NoEqBodyEq'\"\n\n\n@dataclass(eq=False)\nclass NoEqBodyEqMutable:\n    x: int\n\n    def __eq__(self, other):\n        return True\n\n\ntry:\n    hash(NoEqBodyEqMutable(1))\n    assert False, 'expected a body __eq__ to leave the class unhashable'\nexcept TypeError as e:\n    assert str(e) == \"unhashable type: 'NoEqBodyEqMutable'\"\n\n\n# === An unknown keyword is rejected ===\ndef unknown_keyword():\n    @dataclass(bogus=True)\n    class Bogus:\n        x: int\n\n\ntry:\n    unknown_keyword()\n    assert False, 'expected an unknown keyword to raise'\nexcept TypeError as e:\n    assert str(e) == \"dataclass() got an unexpected keyword argument 'bogus'\"\n\n\n# === The class may be passed positionally alongside the options ===\nclass Manual:\n    __annotations__ = {'x': 'int'}\n\n\nApplied = dataclass(Manual, frozen=True)\nassert Applied is Manual\nm = Applied(5)\nassert m.x == 5\ntry:\n    m.x = 6\n    assert False, 'expected a frozen assignment to raise'\nexcept FrozenInstanceError as e:\n    assert str(e) == \"cannot assign to field 'x'\"\n\n\n# === The options compose with the cycle guard and uninitialized-field rules ===\n@dataclass(frozen=True)\nclass Leaf:\n    v: int\n\n\n@dataclass\nclass Holder:\n    a: object\n    b: object\n\n\nh = Holder(Leaf(1), None)\nh.b = h\nassert repr(h) == 'Holder(a=Leaf(v=1), b=...)'\n\n\n# `eq=False` never reads the fields, so an uninitialized one is only felt by repr.\n@dataclass(eq=False)\nclass NoEqPartial:\n    a: int\n    b: int\n\n    def __init__(self, a: int) -> None:\n        self.a = a\n\n\nassert not (NoEqPartial(1) == NoEqPartial(1)), 'eq=False compares by identity, never touching fields'\ntry:\n    repr(NoEqPartial(1))\n    assert False, 'expected repr to read the uninitialized field'\nexcept AttributeError as e:\n    assert str(e) == \"'NoEqPartial' object has no attribute 'b'\"\n\n\n# === Nested frozen dataclasses stay equal and hashable ===\n@dataclass(frozen=True)\nclass Outer:\n    i: Leaf\n\n\nassert Outer(Leaf(1)) == Outer(Leaf(1))\nassert hash(Outer(Leaf(1))) == hash(Outer(Leaf(1)))\nassert len({Outer(Leaf(1)), Outer(Leaf(1))}) == 1\n\n\n# === __dataclass_params__ records the options on the class ===\n# The decorator writes it beside `__dataclass_fields__`, as CPython does; the\n# eight options Monty refuses unless left at their default read as constants.\nparams = Point.__dataclass_params__\nassert type(params).__name__ == '_DataclassParams'\nassert params.frozen is True\nassert params.eq is True\nassert params.init is True\nassert params.repr is True\nassert params.match_args is True\nassert params.order is False\nassert params.unsafe_hash is False\nassert params.kw_only is False\nassert params.slots is False\nassert params.weakref_slot is False\nassert repr(params) == (\n    '_DataclassParams(init=True,repr=True,eq=True,order=False,unsafe_hash=False,'\n    'frozen=True,match_args=True,kw_only=False,slots=False,weakref_slot=False)'\n)\n\n# `eq=False` is recorded too, and instances read it through their class.\nassert NoEqPartial.__dataclass_params__.eq is False\nassert NoEqPartial.__dataclass_params__.frozen is False\nassert NoEqPartial(1).__dataclass_params__ is NoEqPartial.__dataclass_params__\n\ntry:\n    params.nope\n    assert False, 'expected AttributeError'\nexcept AttributeError as e:\n    assert str(e) == \"'_DataclassParams' object has no attribute 'nope'\"\n\n\n# === A plain class has no params, just as it has no fields ===\n\n\nclass PlainOptions:\n    pass\n\n\nassert not hasattr(PlainOptions, '__dataclass_params__')\n\n\n# === dataclass(...) is a value, so the decorator can be stored and reused ===\nfrozen = dataclass(frozen=True)\n\n\n@frozen\nclass First:\n    x: int\n\n\n@frozen\nclass Second:\n    y: int\n\n\nassert First(1).x == 1\nassert Second(2).y == 2\n\n\n# The stored decorator is CPython's `def wrap(cls)`, so the class binds by\n# keyword too, and its arity errors name that closure rather than `dataclass`.\nclass ByKeyword:\n    x: int\n\n\nassert frozen(cls=ByKeyword) is ByKeyword\nassert ByKeyword.__dataclass_params__.frozen is True\n\ntry:\n    frozen()\n    assert False, 'expected a missing class to raise'\nexcept TypeError as e:\n    assert str(e) == \"dataclass.<locals>.wrap() missing 1 required positional argument: 'cls'\"\n\ntry:\n    frozen(First, Second)\n    assert False, 'expected a second positional argument to raise'\nexcept TypeError as e:\n    assert str(e) == 'dataclass.<locals>.wrap() takes 1 positional argument but 2 were given'\n\ntry:\n    frozen(cls=First, nope=1)\n    assert False, 'expected an unknown keyword to raise'\nexcept TypeError as e:\n    assert str(e) == \"dataclass.<locals>.wrap() got an unexpected keyword argument 'nope'\"\n\nassert First.__dataclass_params__.frozen is True\nassert Second.__dataclass_params__.frozen is True\ntry:\n    Second(2).y = 3\n    assert False, 'expected a frozen assignment to raise'\nexcept FrozenInstanceError as e:\n    assert str(e) == \"cannot assign to field 'y'\"\n\n\n# === Options are read for truthiness, as CPython's pure-Python decorator does ===\n@dataclass(frozen=1, eq='yes')\nclass Truthy:\n    x: int\n\n\nassert Truthy(1) == Truthy(1)\nassert hash(Truthy(1)) == hash((1,))\ntry:\n    Truthy(1).x = 2\n    assert False, 'expected a frozen assignment to raise'\nexcept FrozenInstanceError as e:\n    assert str(e) == \"cannot assign to field 'x'\"\n\n\n# === A frozen dataclass holding an unhashable field reports that field's type ===\n@dataclass(frozen=True)\nclass Boxed:\n    v: object\n\n\nassert hash(Boxed(1)) == hash((1,))\ntry:\n    hash(Boxed([1, 2]))\n    assert False, 'expected an unhashable field to raise'\nexcept TypeError as e:\n    assert str(e) == \"unhashable type: 'list'\"\n\n\n# === Re-decorating replaces both the fields and the options ===\n@dataclass\nclass Rebound:\n    x: int\n\n\ntry:\n    hash(Rebound(1))\n    assert False, 'a default dataclass is unhashable'\nexcept TypeError as e:\n    assert str(e) == \"unhashable type: 'Rebound'\"\n\nRebound = dataclass(frozen=True)(Rebound)\nassert Rebound.__dataclass_params__.frozen is True\nassert list(Rebound.__dataclass_fields__) == ['x']\n";

/// The complete `repr__mutation.py` as upstream v1.2.0 ships it: a
/// dict entry deleted mid-repr still prints, because the deletion
/// leaves a tombstone the repr walk steps over
/// (`up/crates/monty/test_cases/repr__mutation.py:144`).
const String upstreamReprMutationV120 =
    "import sys\nfrom collections import Counter, deque\n\n\n# === list: repr sees live length, so mid-repr pops truncate the output ===\nclass ListPopper:\n    def __repr__(self):\n        xs.pop()\n        return 'X'\n\n\nxs = [ListPopper(), ListPopper(), ListPopper()]\nassert repr(xs) == '[X, X]'\n\n\n# === list: mid-repr appends are picked up (each element appends once) ===\nclass ListGrower:\n    def __init__(self):\n        self.done = False\n\n    def __repr__(self):\n        if not self.done:\n            self.done = True\n            ys.append('tail')\n        return 'X'\n\n\nys = [ListGrower(), ListGrower()]\nassert repr(ys) == \"[X, X, 'tail', 'tail']\"\n\n\n# === deque: repr formats a snapshot, so mid-repr pops change nothing ===\nclass DequePopper:\n    def __repr__(self):\n        dq.pop()\n        return 'X'\n\n\ndq = deque([DequePopper(), DequePopper(), DequePopper()])\nassert repr(dq) == 'deque([X, X, X])'\n\n\n# === set: repr formats a snapshot, so mid-repr discards change nothing ===\nclass SetPopper:\n    def __init__(self, n):\n        self.n = n\n\n    def __hash__(self):\n        return self.n\n\n    def __repr__(self):\n        st.discard(next(iter(st)))\n        return f'S{self.n}'\n\n\nst = {SetPopper(1), SetPopper(2), SetPopper(3)}\nassert repr(st) == '{S1, S2, S3}'\n\n\n# === set: elements added mid-repr are not shown (snapshot on both) ===\nclass SetAdder:\n    def __init__(self, n):\n        self.n = n\n\n    def __hash__(self):\n        return self.n\n\n    def __repr__(self):\n        st2.add(self.n * 100)\n        return f'A{self.n}'\n\n\nst2 = {SetAdder(1), SetAdder(2)}\nassert repr(st2) == '{A1, A2}'\n\n\n# === dict: keys inserted mid-repr are appended and printed ===\nclass KeyAdder:\n    def __init__(self, n):\n        self.n = n\n\n    def __hash__(self):\n        return self.n\n\n    def __eq__(self, other):\n        return self is other\n\n    def __repr__(self):\n        if self.n == 1:\n            d['new'] = 99\n        return f'K{self.n}'\n\n\nd = {KeyAdder(1): 1, KeyAdder(2): 2}\nassert repr(d) == \"{K1: 1, K2: 2, 'new': 99}\"\n\n\n# === dict: a deletion after the affected entries have printed is harmless ===\n# (early deletions diverge — see the sys.platform sections below)\nclass KeyPopper:\n    def __init__(self, n, mutate=False):\n        self.n = n\n        self.mutate = mutate\n\n    def __hash__(self):\n        return self.n\n\n    def __eq__(self, other):\n        return self is other\n\n    def __repr__(self):\n        if self.mutate:\n            d2.pop(next(iter(d2)), None)\n        return f'K{self.n}'\n\n\nd2 = {KeyPopper(1): 1, KeyPopper(2): 2, KeyPopper(3, mutate=True): 3}\nassert repr(d2) == '{K1: 1, K2: 2, K3: 3}'\n\n\n# === dict: deleting a NOT-yet-printed entry mid-repr ===\n# A deletion leaves a tombstone the repr walk steps over rather than shifting\n# later entries into printed slots, so nothing is skipped. These also prove the\n# live slot lookup cannot panic when the dict shrinks under the repr cursor.\nclass ShiftPopper:\n    def __init__(self, n, mutate=False):\n        self.n = n\n        self.mutate = mutate\n\n    def __hash__(self):\n        return self.n\n\n    def __eq__(self, other):\n        return self is other\n\n    def __repr__(self):\n        if self.mutate:\n            target.pop(next(iter(target)), None)\n        return f'K{self.n}'\n\n\n# the FIRST key deletes itself while printing\ntarget = {ShiftPopper(1, mutate=True): 1, ShiftPopper(2): 2, ShiftPopper(3): 3}\nassert repr(target) == '{K1: 1, K2: 2, K3: 3}'\n\n# a LATER key deletes the already-printed first entry\ntarget = {ShiftPopper(1): 1, ShiftPopper(2, mutate=True): 2, ShiftPopper(3): 3}\nassert repr(target) == '{K1: 1, K2: 2, K3: 3}'\n\n\n# === dict: a VALUE repr mutating the dict ===\n# The mutation runs between the key printing and the value printing: the\n# entry's pair was already copied, so the value still prints even though its\n# entry is gone, and the tombstone left behind keeps the walk on the entries\n# after it.\nclass ValuePopper:\n    def __init__(self, n, mutate=False):\n        self.n = n\n        self.mutate = mutate\n\n    def __repr__(self):\n        if self.mutate:\n            target.pop(next(iter(target)), None)\n        return f'V{self.n}'\n\n\ntarget = {'a': ValuePopper(1, mutate=True), 'b': ValuePopper(2), 'c': ValuePopper(3)}\nassert repr(target) == \"{'a': V1, 'b': V2, 'c': V3}\"\n\n# the LAST value deleting an already-printed entry changes nothing on either\n# engine — everything affected has already printed\ntarget = {'a': ValuePopper(1), 'b': ValuePopper(2), 'c': ValuePopper(3, mutate=True)}\nassert repr(target) == \"{'a': V1, 'b': V2, 'c': V3}\"\n\n\n# === Counter: repr orders and prints a snapshot despite mid-repr pops ===\nclass CountPopper:\n    def __init__(self, n):\n        self.n = n\n\n    def __hash__(self):\n        return self.n\n\n    def __eq__(self, other):\n        return self is other\n\n    def __repr__(self):\n        c.pop(next(iter(c)), None)\n        return f'C{self.n}'\n\n\nc = Counter({CountPopper(1): 5, CountPopper(2): 3})\nassert repr(c) == 'Counter({C1: 5, C2: 3})'\n";

/// Each selected corpus source as the complete file upstream v1.2.0 ships,
/// keyed by corpus file name: [manifestTests] compares every entry against
/// the production corpus byte-for-byte, and the literals are JSON — as
/// `tool/generate_fixture_corpus_v1.dart` encodes the production corpus — so
/// an embedded source and its production twin are written the same way and
/// only their bytes can differ.
const Map<String, String> selectedUpstreamV120Sources = {
  'open__fs.py': upstreamOpenFsV120,
  'fstring__all.py': upstreamFstringAllV120,
  'str__format.py': upstreamStrFormatV120,
  'dataclass__options.py': upstreamDataclassOptionsV120,
  'repr__mutation.py': upstreamReprMutationV120,
};

/// The four [selectedUpstreamV120Sources] entries the `open()` fixture does
/// not cover, keyed by corpus file name, held for the native and browser
/// execution tests that run each file on a worker: `open__fs.py` is the open
/// source, exercised through the mounted tree, and is left out.
const Map<String, String> selectedUpstreamV120ExecutionSources = {
  'fstring__all.py': upstreamFstringAllV120,
  'str__format.py': upstreamStrFormatV120,
  'dataclass__options.py': upstreamDataclassOptionsV120,
  'repr__mutation.py': upstreamReprMutationV120,
};

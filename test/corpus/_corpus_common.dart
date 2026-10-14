// The corpus checks shared by the VM and browser entry points: pure Dart, so
// the same code judges the native worker and the Web Worker.
import 'dart:async';

import 'package:dart_monty_core/src/worker/monty_pool.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:monty_conformance/worker_conformance.dart';
import 'package:test/test.dart';

/// One minute bounds a fixture's turn, so a hung one fails instead of
/// stalling the run.
const PoolOptions corpusPoolOptions = PoolOptions(
  maxProcesses: 1,
  requestTimeout: Duration(seconds: 60),
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
  });

  /// `native`, `dart2js` or `dart2wasm`, as printed.
  final String label;

  /// The manifest profile.
  final WorkerCorpusProfile profile;

  /// Starts the pool the corpus runs on.
  final Future<MontyPool> Function() startPool;

  /// The Worker's JSPI probe, for a browser; null on native.
  final bool? jspi;

  /// A pool whose Workers skip JSPI (the forced fallback), for a browser.
  final Future<MontyPool> Function()? startNoJspiPool;
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
  test('the manifest is well formed', () {
    expect(manifestProblems(fixtureCorpusV1.keys), isEmpty);
    expect(fixtureCorpusV1, hasLength(643));
  });
}

/// Runs the whole corpus on [target]'s pool and judges it against the
/// manifest; prints the scorecard line.
Future<void> runCorpusChecks(CorpusTarget target) async {
  final failures = await _runAll(target.startPool);
  final noJspi = target.jspi == false;
  final problems = <String>[
    ...checkAgainstManifest(
      {
        for (final e in failures.entries)
          if (!(noJspi && workerRecursionSetNoJspi.containsKey(e.key)))
            e.key: e.value,
      },
      target.profile,
      fixtureCorpusV1.keys,
    ),
    if (noJspi) ..._recursionSetProblems(failures),
  ];
  final listed = {
    for (final e in workerCorpusExpected)
      if (e.profiles.contains(target.profile)) e.file,
  };
  // The scorecard line the CI job prints, per backend.
  // ignore: avoid_print
  print(
    'CORPUS ${target.label}: total=${fixtureCorpusV1.length} '
    'passed=${fixtureCorpusV1.length - failures.length} '
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
Future<void> runRecursionSetFallback(String label, MontyPool pool) async {
  final Map<String, String> failures;
  try {
    failures = await runWorkerFixtureCorpus(
      pool: pool,
      log: (_) {},
      only: workerRecursionSetNoJspi.keys.toSet(),
    );
  } finally {
    await pool.close();
  }
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
    Future<Map<String, String>> judge(Map<String, String> corpus) =>
        MontyPool.withPool(
          (pool) =>
              runWorkerFixtureCorpus(pool: pool, log: (_) {}, corpus: corpus),
          options: corpusPoolOptions,
        );

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

Future<Map<String, String>> _runAll(
  Future<MontyPool> Function() start, {
  Set<String>? only,
}) async {
  final pool = await start();
  try {
    return await runWorkerFixtureCorpus(
      pool: pool,
      log: (_) {},
      only: only,
    );
  } finally {
    await pool.close();
  }
}

/// How [failures] differ from upstream's browser build on the recursion set,
/// for a run whose JSPI probe failed.
List<String> _recursionSetProblems(Map<String, String> failures) {
  final problems = <String>[];
  for (final MapEntry(:key, :value) in workerRecursionSetNoJspi.entries) {
    final reason = failures[key];
    switch (value) {
      case RecursionOutcome.crashes:
        if (reason == null || !reason.startsWith('the worker crashed')) {
          problems.add("$key: upstream's browser build crashes; got $reason");
        }
      case RecursionOutcome.passes:
        if (reason != null) {
          problems.add("$key: upstream's browser build passes; got $reason");
        }
      case RecursionOutcome.unrecorded:
        problems.add(
          '$key: no upstream-browser outcome is recorded for a browser '
          'without JSPI; measure it before judging this branch',
        );
    }
  }

  return problems;
}

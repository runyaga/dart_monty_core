// The expected outcomes of the pinned upstream corpus on the worker engine.
//
// Every corpus file the engine fails is listed here, tied to a divergence ID
// and a reason, and a run is judged against the list in BOTH directions: a
// failing file that is not listed is a regression, and a listed file that now
// passes is a stale entry to delete. Nothing is skipped. The list may only
// shrink; adding to it is a decision, made with the divergence it names.
//
// The manifest is Dart, not a data file, because the browser runs read it too
// and a page has no filesystem.

/// Where a divergence applies.
// ignore: prefer-match-file-name, the file holds the manifest, not one type
enum WorkerCorpusProfile {
  /// The native worker executable, on the VM.
  native,

  /// The Web Worker, dart2js or dart2wasm, in any browser.
  browser,
}

/// A recorded divergence between the worker engine and upstream's datatest.
final class CorpusDivergence {
  /// Creates a [CorpusDivergence].
  const CorpusDivergence(this.id, this.summary, this.source);

  /// The stable ID an expected failure names.
  final String id;

  /// What differs, and why that is not a defect of this package.
  final String summary;

  /// Where the divergence is recorded or decided.
  final String source;
}

/// A corpus file expected to fail, and why.
final class ExpectedFailure {
  /// Creates an [ExpectedFailure] of [file] under [divergence], whose failure
  /// reason is exactly [reason].
  const ExpectedFailure(
    this.file,
    this.divergence,
    this.reason, {
    this.profiles = const {
      WorkerCorpusProfile.native,
      WorkerCorpusProfile.browser,
    },
  }) : tail = false;

  /// An [ExpectedFailure] whose failure reason ENDS with [reason]: a
  /// traceback mismatch states the expected traceback first, which is the
  /// fixture's own, and the actual one last, which is what is recorded.
  const ExpectedFailure.tail(
    this.file,
    this.divergence,
    this.reason, {
    this.profiles = const {
      WorkerCorpusProfile.native,
      WorkerCorpusProfile.browser,
    },
  }) : tail = true;

  /// The corpus file name.
  final String file;

  /// The ID of the [CorpusDivergence] this belongs to.
  final String divergence;

  /// The failure reason, as the adjudicator words it: a listed file that
  /// fails for any other reason is not the divergence it was listed for.
  final String reason;

  /// Whether [reason] is the end of the failure reason rather than all of it.
  final bool tail;

  /// The profiles the failure is expected in.
  final Set<WorkerCorpusProfile> profiles;

  /// Whether [actual] is the failure this entry records.
  bool matches(String actual) =>
      tail ? actual.endsWith(reason) : actual == reason;
}

/// The recorded divergences, by ID.
const Map<String, CorpusDivergence> workerCorpusDivergences = {
  'worker-no-test-hooks': CorpusDivergence(
    'worker-no-test-hooks',
    'Upstream runs its datatest with the engine built with `test-hooks`, '
        'which adds `sys.setrecursionlimit` and the `gc` module for these '
        'fixtures. The shipped worker is built without it, as every '
        'consumer receives it, so it has neither.',
    'upstream crates/monty-datatest/Cargo.toml (features = ["test-hooks"]); '
        'the worker crate never enables it in shipped builds',
  ),
  'cycle-marker-is-str': CorpusDivergence(
    'cycle-marker-is-str',
    'A returned cyclic container carries the wire marker `[...]` / `{...}` '
        "as a Python `str`, as upstream's Python host maps the wire's "
        "`cycle` node; the fixtures state `py_repr()` of upstream's "
        'in-process `MontyObject`, which prints the marker bare.',
    "C2 arena reader: `cycle` is mapped as upstream's Python host maps it "
        '(lib/src/worker/arena_reader.dart); pydantic_monty 1.1.0 returns '
        'the same `str`',
  ),
  'worker-undefined-call-span': CorpusDivergence(
    'worker-undefined-call-span',
    'A call to an undefined name suspends in the worker as a host function '
        'call; the NameError its refusal raises spans the whole call '
        '(`aaa_func()`), where the in-process engine raises it at the name '
        '(`aaa_func`). Same traceback otherwise.',
    'pydantic_monty 1.1.0 prints the same wider span for '
        "name_error__undefined_call_chained.py's source (measured); the "
        'frame file `<python-input-N>` is normalised by the runner',
  ),
  'browser-int-limit': CorpusDivergence(
    'browser-int-limit',
    'The browser build is wasm32: a size or count past 2**31 - 1 overflows '
        "where the native worker's 64-bit word does not. Upstream's own "
        'browser build fails these four files identically.',
    'KNOWN-DIVERGENCE of the browser target, decided with the oracle '
        'rule: pydantic_monty 1.1.0 is the reference, and `@pydantic/monty` '
        '1.1.0 `/wasm` (the wasm32 build) fails the same four '
        'files with the same exceptions (measured on Chrome 155)',
  ),
  'worker-fixture-memory-limit': CorpusDivergence(
    'worker-fixture-memory-limit',
    "Upstream's datatest runs every fixture with no memory limit, and the "
        '1.2.0 percent-format precision cases pass for it: the largest one '
        'formats with a precision of 2147482623 '
        '(`bytes__percent_format.py:184`, `str__percent_format.py:370`), '
        'whose buffer allocates about 2.1 GB. This '
        'repository bounds every worker it starts, and the corpus harness '
        'bounds a fixture at `workerFixtureMaxMemory` = 256 MB, so the '
        "allocation is refused with the allocator's `MemoryError`, whose "
        "text ends 'bytes > 268435456 bytes'. A wasm32 browser worker "
        'could not allocate the 2 GB either. The bound is not raised for '
        'these two files.',
    'the fixture bound is worker_fixture_runner.dart:35 '
        "(workerFixtureMaxMemory = 256 MB); the datatest's default_test_limits "
        '(crates/monty-datatest/src/main.rs:76) sets '
        'only the recursion depth; kept by owner decision at the 1.2.0 '
        'corpus re-measure',
  ),
};

/// Every corpus file expected to fail on the shipped worker.
const List<ExpectedFailure> workerCorpusExpected = [
  // worker-no-test-hooks
  ExpectedFailure(
    'functools__gc.py',
    'worker-no-test-hooks',
    "expected no error, got ModuleNotFoundError: No module named 'gc'",
  ),
  ExpectedFailure(
    'itertools__gc.py',
    'worker-no-test-hooks',
    "expected no error, got ModuleNotFoundError: No module named 'gc'",
  ),
  ExpectedFailure(
    'refcount__exec_namespace.py',
    'worker-no-test-hooks',
    "expected no error, got ModuleNotFoundError: No module named 'gc'",
  ),
  ExpectedFailure(
    'json__dumps_recursion.py',
    'worker-no-test-hooks',
    'expected no error, got '
        "AttributeError: module 'sys' has no attribute 'setrecursionlimit'",
  ),
  ExpectedFailure(
    'recursion__deep_copy.py',
    'worker-no-test-hooks',
    'expected no error, got '
        "AttributeError: module 'sys' has no attribute 'setrecursionlimit'",
  ),
  ExpectedFailure(
    'recursion__deep_repr.py',
    'worker-no-test-hooks',
    'expected no error, got '
        "AttributeError: module 'sys' has no attribute 'setrecursionlimit'",
  ),
  ExpectedFailure(
    'recursion__limit_depth.py',
    'worker-no-test-hooks',
    'expected no error, got '
        "AttributeError: module 'sys' has no attribute 'setrecursionlimit'",
  ),

  // cycle-marker-is-str
  ExpectedFailure(
    'pyobject__cycle_dict_self.py',
    'cycle-marker-is-str',
    "repr mismatch: expected {'self': {...}}, got {'self': '{...}'}",
  ),
  ExpectedFailure(
    'pyobject__cycle_list_dict.py',
    'cycle-marker-is-str',
    "repr mismatch: expected [{'list': [...]}], got [{'list': '[...]'}]",
  ),
  ExpectedFailure(
    'pyobject__cycle_list_self.py',
    'cycle-marker-is-str',
    "repr mismatch: expected [[...]], got ['[...]']",
  ),
  ExpectedFailure(
    'pyobject__cycle_multiple_refs.py',
    'cycle-marker-is-str',
    "repr mismatch: expected [[[...]], [[...]]], got [['[...]'], ['[...]']]",
  ),

  // worker-undefined-call-span
  ExpectedFailure.tail(
    'name_error__undefined_call_chained.py',
    'worker-undefined-call-span',
    '--- actual\n'
        'Traceback (most recent call last):\n'
        '  File "name_error__undefined_call_chained.py", line 1, in <module>\n'
        '    x = aaa_func() + bbb_func()\n'
        '        ~~~~~~~~~~\n'
        "NameError: name 'aaa_func' is not defined",
  ),
  ExpectedFailure.tail(
    'name_error__undefined_call_in_expr.py',
    'worker-undefined-call-span',
    '--- actual\n'
        'Traceback (most recent call last):\n'
        '  File "name_error__undefined_call_in_expr.py", line 1, in <module>\n'
        '    x = 1 + missing_func()\n'
        '            ~~~~~~~~~~~~~~\n'
        "NameError: name 'missing_func' is not defined",
  ),
  ExpectedFailure.tail(
    'name_error__undefined_call_in_function.py',
    'worker-undefined-call-span',
    '--- actual\n'
        'Traceback (most recent call last):\n'
        '  File "name_error__undefined_call_in_function.py", '
        'line 5, in <module>\n'
        '    outer()\n'
        '    ~~~~~~~\n'
        '  File "name_error__undefined_call_in_function.py", line 2, in outer\n'
        '    return missing_func()\n'
        '           ~~~~~~~~~~~~~~\n'
        "NameError: name 'missing_func' is not defined",
  ),
  ExpectedFailure.tail(
    'name_error__undefined_call_with_args.py',
    'worker-undefined-call-span',
    '--- actual\n'
        'Traceback (most recent call last):\n'
        '  File "name_error__undefined_call_with_args.py", '
        'line 1, in <module>\n'
        '    missing_func(1, 2, 3)\n'
        '    ~~~~~~~~~~~~~~~~~~~~~\n'
        "NameError: name 'missing_func' is not defined",
  ),
  ExpectedFailure.tail(
    'name_error__undefined_global.py',
    'worker-undefined-call-span',
    '--- actual\n'
        'Traceback (most recent call last):\n'
        '  File "name_error__undefined_global.py", line 2, in <module>\n'
        '    unknown_func()\n'
        '    ~~~~~~~~~~~~~~\n'
        "NameError: name 'unknown_func' is not defined",
  ),
  ExpectedFailure.tail(
    'traceback__undefined_call.py',
    'worker-undefined-call-span',
    '--- actual\n'
        'Traceback (most recent call last):\n'
        '  File "traceback__undefined_call.py", line 5, in <module>\n'
        '    foo()\n'
        '    ~~~~~\n'
        '  File "traceback__undefined_call.py", line 2, in foo\n'
        '    snap(1)\n'
        '    ~~~~~~~\n'
        "NameError: name 'snap' is not defined",
  ),

  // browser-int-limit
  ExpectedFailure(
    'itertools__combinatoric.py',
    'browser-int-limit',
    'expected no error, got '
        'OverflowError: Python int too large to convert to C ssize_t',
    profiles: {WorkerCorpusProfile.browser},
  ),
  ExpectedFailure(
    'itertools__tee.py',
    'browser-int-limit',
    'expected no error, got '
        'OverflowError: Python int too large to convert to C ssize_t',
    profiles: {WorkerCorpusProfile.browser},
  ),
  ExpectedFailure(
    'random__errors.py',
    'browser-int-limit',
    'expected no error, got ValueError: Cannot convert negative int',
    profiles: {WorkerCorpusProfile.browser},
  ),
  ExpectedFailure(
    'range__ops.py',
    'browser-int-limit',
    'expected no error, got '
        'AssertionError: assert 4294967295 == 9223372036854775807',
    profiles: {WorkerCorpusProfile.browser},
  ),

  // worker-fixture-memory-limit
  ExpectedFailure.tail(
    'bytes__percent_format.py',
    'worker-fixture-memory-limit',
    'bytes > 268435456 bytes',
  ),
  ExpectedFailure.tail(
    'str__percent_format.py',
    'worker-fixture-memory-limit',
    'bytes > 268435456 bytes',
  ),
];

/// How a recursion-set file ends on a browser whose JSPI probe failed: what
/// upstream's own browser build (`@pydantic/monty` 1.1.0 `/wasm`) did with the
/// file on Chrome 155 (5 fresh pages each; the same build and 7-file harness).
enum RecursionOutcome {
  /// The worker died: `MontyCrashedError`.
  crashes,

  /// The file ran to its end.
  passes,
}

/// The 7-file recursion set. With the Worker's JSPI probe succeeding each
/// file must meet its own directives, as on native (no entry above lists
/// them). With it failing, each file's outcome must equal upstream's browser
/// build's, recorded here.
const Map<String, RecursionOutcome> workerRecursionSetNoJspi = {
  'collections__deque.py': RecursionOutcome.crashes,
  'dataclass__repr_eq.py': RecursionOutcome.crashes,
  'dict__eq_self_referential.py': RecursionOutcome.crashes,
  'generic_alias.py': RecursionOutcome.passes,
  'list__eq_self_referential.py': RecursionOutcome.passes,
  'recursion__deep_hash.py': RecursionOutcome.passes,
  'recursion__deep_isinstance.py': RecursionOutcome.passes,
};

/// The recursion set's outcomes on Safari 26.6 (JavaScriptCore, no JSPI),
/// measured with this corpus run on dart2js: every file runs to its end,
/// including the three that crash Chrome's and Firefox's worker.
/// Upstream's browser build has no Safari baseline to compare with.
const Map<String, RecursionOutcome> workerRecursionSetNoJspiSafari = {
  'collections__deque.py': RecursionOutcome.passes,
  'dataclass__repr_eq.py': RecursionOutcome.passes,
  'dict__eq_self_referential.py': RecursionOutcome.passes,
  'generic_alias.py': RecursionOutcome.passes,
  'list__eq_self_referential.py': RecursionOutcome.passes,
  'recursion__deep_hash.py': RecursionOutcome.passes,
  'recursion__deep_isinstance.py': RecursionOutcome.passes,
};

/// How a run's failures differ from the manifest for [profile]; empty when
/// they match exactly.
///
/// [failures] maps each failing file to its reason. [corpus] is the file set
/// that ran, so an entry for a file that is not in it is itself a problem.
List<String> checkAgainstManifest(
  Map<String, String> failures,
  WorkerCorpusProfile profile,
  Iterable<String> corpus,
) {
  final problems = <String>[];
  final expected = {
    for (final e in workerCorpusExpected)
      if (e.profiles.contains(profile)) e.file: e,
  };
  final files = corpus.toSet();
  for (final MapEntry(:key, :value) in failures.entries) {
    final entry = expected[key];
    if (entry == null) {
      problems.add('REGRESSION $key: not an expected failure\n  $value');
    } else if (!entry.matches(value)) {
      problems.add(
        'CHANGED $key: expected the failure '
        '${entry.tail ? 'ending ' : ''}"${entry.reason}" '
        '(${entry.divergence}), got\n  $value',
      );
    }
  }
  for (final file in expected.keys) {
    if (!files.contains(file)) {
      problems.add('MISSING $file: expected failure is not in the corpus');
    } else if (!failures.containsKey(file)) {
      problems.add('STALE $file: listed as a failure but it now passes');
    }
  }

  return problems;
}

/// What is wrong with the manifest itself; empty when it is well formed.
List<String> manifestProblems(Iterable<String> corpus) {
  final files = corpus.toSet();
  final seen = <String>{};

  return [
    ..._expectedFailureProblems(files, seen),
    ..._divergenceProblems(),
    ..._recursionSetProblems(files, seen),
  ];
}

/// What is wrong with the expected-failure entries: an entry whose divergence
/// is not recorded, a file the corpus does not hold, a file listed twice and
/// an entry with no reason.
///
/// [seen] collects the files the entries name, so a file listed twice is
/// caught, and the recursion set reads it afterwards.
List<String> _expectedFailureProblems(Set<String> files, Set<String> seen) {
  final problems = <String>[];
  for (final e in workerCorpusExpected) {
    if (!workerCorpusDivergences.containsKey(e.divergence)) {
      problems.add('${e.file}: unknown divergence ${e.divergence}');
    }
    if (!files.contains(e.file)) problems.add('${e.file}: not in the corpus');
    if (!seen.add(e.file)) problems.add('${e.file}: listed twice');
    if (e.reason.isEmpty) problems.add('${e.file}: no reason text');
  }

  return problems;
}

/// What is wrong with the divergence records: one that names no file.
List<String> _divergenceProblems() {
  final problems = <String>[];
  for (final id in workerCorpusDivergences.keys) {
    if (!workerCorpusExpected.any((e) => e.divergence == id)) {
      problems.add('divergence $id names no file');
    }
  }

  return problems;
}

/// What is wrong with the two recursion sets: one that names different files
/// from the other, a file the corpus does not hold and a file that is also an
/// expected failure.
List<String> _recursionSetProblems(Set<String> files, Set<String> seen) {
  final problems = <String>[];
  final safariFiles = workerRecursionSetNoJspiSafari.keys.toSet();
  if (safariFiles.length != workerRecursionSetNoJspi.length ||
      !safariFiles.containsAll(workerRecursionSetNoJspi.keys)) {
    problems.add('the Safari recursion set names different files');
  }
  for (final file in workerRecursionSetNoJspi.keys) {
    if (!files.contains(file)) problems.add('$file: not in the corpus');
    if (seen.contains(file)) {
      problems.add('$file: a recursion-set file is also an expected failure');
    }
  }

  return problems;
}

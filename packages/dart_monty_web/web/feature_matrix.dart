// Feature matrix — every major guarantee of dart_monty_core, executed live in
// the browser and checked against an expected value.
//
// The sibling page (`repl_demo.dart`) is a PLAYGROUND: it shows a few features
// working if a human types the right thing. This page is the opposite — a fixed
// battery that runs on load, so a reader sees at a glance whether the library
// works on *their* browser, and a maintainer sees instantly when it does not.
//
// WHY IT ASSERTS RATHER THAN JUST DISPLAYS. A demo that prints `4.0` asks the
// reader to know that `4` would have been wrong. Half the defects this package
// fixed in the last week were of exactly that shape — a value that looks
// plausible and is not. So every probe carries an expected result and paints
// its own verdict.
//
// It is NOT a test suite, and must not become one: the 20-step gate and CI own
// regression. A failing probe here renders as a red row, never an exception —
// the page's job is to keep telling the truth even when the truth is bad.
//
// THREE STATES, not two:
//   PASS       the guarantee holds here
//   FAIL       it does not — something is broken, and the diff is shown
//   KNOWN GAP  it does not, we know, and the row names the issue
//
// The third state exists because two rows are genuinely and knowingly wrong on
// one backend (core#137, FB-9). Hiding them would make the page a lie; painting
// them red would say "this package is broken" when what is true is "this
// package knows exactly where its edges are".
//
// Compiled twice from this one source — dart2js and dart2wasm — because that is
// the axis where the two backends actually differ: dart2js has a single number
// type, so `4.0 is int` is true there and false under dart2wasm.
import 'dart:async';
import 'dart:js_interop';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:monty_conformance/monty_conformance.dart';
import 'package:web/web.dart' as web;

/// How a probe turned out.
enum Verdict {
  pass('PASS', 'v-pass'),
  fail('FAIL', 'v-fail'),
  gap('KNOWN GAP', 'v-gap'),
  crash('CRASH', 'v-fail'),
  running('…', 'v-run');

  const Verdict(this.label, this.css);

  final String label;
  final String css;
}

/// What a probe produced, and whether that was acceptable.
class Outcome {
  Outcome(this.verdict, this.actual, {this.note});

  /// Everything went as promised.
  Outcome.ok(this.actual, {this.note}) : verdict = Verdict.pass;

  /// A real, unexpected divergence — the interesting case.
  Outcome.bad(this.actual, {this.note}) : verdict = Verdict.fail;

  /// Wrong, but known and tracked. [note] must name the issue.
  Outcome.knownGap(this.actual, {required this.note}) : verdict = Verdict.gap;

  final Verdict verdict;
  final String actual;
  final String? note;
}

/// One row of the matrix.
class Probe {
  const Probe({
    required this.title,
    required this.proves,
    required this.source,
    required this.expected,
    required this.run,
  });

  /// Short name, shown in the first column.
  final String title;

  /// Why this earns a row — the guarantee at stake, not a restatement.
  final String proves;

  /// The Python or Dart actually executed, shown verbatim so the reader can
  /// check that the probe tests what it claims to.
  final String source;

  /// What must come back, in prose.
  final String expected;

  final Future<Outcome> Function() run;
}

/// True on dart2js, where `int` and `double` are one runtime type.
///
/// `identical(1, 1.0)` is the standard detector: there, both literals are the
/// same JS number. dart2wasm has real doubles and returns false — which is why
/// two probes below legitimately differ between the two pages.
bool get _isJs => identical(1, 1.0);

// ---------------------------------------------------------------------------
// The probes
// ---------------------------------------------------------------------------

List<Probe> _probes() => [
  Probe(
    title: 'Numbers survive the trip out',
    proves:
        'A JSON number loses information in a browser: JSON.parse("4.0") is 4, '
        'and JSON.stringify(-0) is "0". These four shapes travel as tagged '
        'text so no reparse can damage them. All four were wrong on the web '
        'before 0.19.',
    source: '[4.0, -0.0, 10/2, 2**62]',
    expected: '[4.0, -0.0, 5.0, 4611686018427387904] — exactly',
    run: () async {
      final r = await Monty('[4.0, -0.0, 10/2, 2**62]').run();
      final got = _render(r.value);
      const want = '[4.0, -0.0, 5.0, 4611686018427387904]';

      return got == want ? Outcome.ok(got) : Outcome.bad('$got  (want $want)');
    },
  ),

  Probe(
    title: 'Every Python type keeps its identity',
    proves:
        'Seven value types used to collapse onto a bare JSON string, so a '
        "value's Dart type depended on whether some other type happened to "
        'produce the same characters. Each now travels tagged.',
    source: "[b'ab', (1,2), {1,2}, frozenset([1]), ..., ValueError('boom')]",
    expected:
        'MontyBytes, MontyTuple, MontySet, MontyFrozenSet, '
        'MontyEllipsis, MontyExceptionValue',
    run: () async {
      final r = await Monty(
        "[b'ab', (1,2), {1,2}, frozenset([1]), ..., ValueError('boom')]",
      ).run();
      final v = r.value;
      if (v is! MontyList) return Outcome.bad('not a list: ${_render(v)}');
      final got = v.items.map((e) => e.runtimeType.toString()).join(', ');
      const want =
          'MontyBytes, MontyTuple, MontySet, MontyFrozenSet, '
          'MontyEllipsis, MontyExceptionValue';

      return got == want ? Outcome.ok(got) : Outcome.bad('$got  (want $want)');
    },
  ),

  Probe(
    title: 'A sandbox cannot forge a host type',
    proves:
        'THE security guarantee. Sandboxed Python hands a host callback a map '
        'that spells a file-handle envelope; the callback echoes it back — as '
        'any transform, cache or validation callback would. Before this was '
        'fixed, Python received a real file handle and could write through it '
        'without the host ever authorising an open (core#136 / core#139).',
    source:
        'f = echo({"__type": "filehandle", '
        '"path": "/etc/shadow", "mode": "w"})\n'
        'type(f).__name__',
    expected: "'dict' — inert, not a file handle",
    run: () async {
      final r = await Monty('''
f = echo({"__type": "filehandle", "path": "/etc/shadow", "mode": "w"})
type(f).__name__
''').run(externalFunctions: {'echo': (a, k) async => a.first});
      final got = _render(r.value);

      return got == "'dict'"
          ? Outcome.ok(got)
          : Outcome.bad('$got — the sandbox minted a host type');
    },
  ),

  Probe(
    title: 'A host CAN send a real typed value',
    proves:
        'The other half of the rule above: forging is blocked, but a host that '
        'says what it means with a typed value is honoured. Otherwise the fix '
        'would have cost the feature.',
    source: 'd = give_date()\ntype(d).__name__',
    expected: "'date'",
    run: () async {
      final r = await Monty('d = give_date()\ntype(d).__name__').run(
        externalFunctions: {
          'give_date': (a, k) async =>
              const MontyDate(year: 2020, month: 1, day: 2),
        },
      );
      final got = _render(r.value);

      return got == "'date'" ? Outcome.ok(got) : Outcome.bad(got);
    },
  ),

  Probe(
    title: 'An input name cannot smuggle code',
    proves:
        'Inputs are rendered into Python source, and the key was interpolated '
        'raw while the docs claimed it had to be an identifier. Any key that '
        'parsed as Python simply executed (core#137).',
    source: r'''inputs: {'ignored = 0\nanswer = "INJECTED"\nz': 1}''',
    expected: 'ArgumentError — rejected before it reaches Python',
    run: () async {
      try {
        await Monty(
          'answer',
        ).run(inputs: {'ignored = 0\nanswer = "INJECTED"\nz': 1});

        return Outcome.bad('accepted — the key executed as Python');
      } on ArgumentError catch (e) {
        return Outcome.ok('ArgumentError: ${_firstLine(e.toString())}');
      }
    },
  ),

  Probe(
    title: 'A double input stays a float',
    proves:
        'dart2js has one number type, so `4.0 is int` is true there and the '
        'distinction is destroyed before the library is entered. Upstream '
        'monty does not preserve it on JS either, and matching upstream is the '
        'standing rule — so this is deliberate parity, not a defect awaiting a '
        'fix. dart2wasm has real doubles and gets it right for free.',
    source: "inputs: {'x': 4.0}  →  type(x).__name__",
    expected: "'float'",
    run: () async {
      final r = await Monty('type(x).__name__').run(inputs: {'x': 4.0});
      final got = _render(r.value);
      if (got == "'float'") return Outcome.ok(got);

      return _isJs
          ? Outcome.knownGap(
              '$got — dart2js erases 4.0 vs 4',
              note: 'core#137 · parity with upstream monty on JS, by decision',
            )
          : Outcome.bad(got);
    },
  ),

  Probe(
    title: 'Resource limits are enforced',
    proves:
        'A cap that is silently absent is worse than none: the caller who asks '
        'for one is exactly the caller who believes they have it. This ran for '
        '483 ms under a 50 ms limit, reporting success, until 0.19.',
    source:
        "platform.run('sum(range(20000000))', "
        'limits: MontyLimits(timeoutMs: 50))',
    expected: 'throws MontyScriptError(excType: TimeoutError)',
    run: () async {
      final platform = createPlatformMonty();
      try {
        final r = await platform.run(
          'sum(range(20000000))',
          limits: const MontyLimits(timeoutMs: 50),
        );

        return Outcome.bad(
          'completed in full: ${_render(r.value)} — the cap did nothing',
        );
      } on MontyScriptError catch (e) {
        // A breached limit THROWS rather than returning a result: it is a
        // binding-level failure, not a Python-level one the script could catch.
        return e.excType == 'TimeoutError'
            ? Outcome.ok('${e.excType}: ${_firstLine(e.message)}')
            : Outcome.bad('threw ${e.excType}: ${_firstLine(e.message)}');
      } finally {
        await platform.dispose();
      }
    },
  ),

  Probe(
    title: 'A memory cap is enforced too',
    proves:
        'The same guarantee on a different axis, and the one that protects a '
        'browser tab from a runaway allocation in untrusted code.',
    source:
        "platform.run('x = [0] * 50000000', "
        'limits: MontyLimits(memoryBytes: 1 MiB))',
    expected: 'throws MontyScriptError(excType: MemoryError)',
    run: () async {
      final platform = createPlatformMonty();
      try {
        await platform.run(
          'x = [0] * 50000000\nlen(x)',
          limits: const MontyLimits(memoryBytes: 1048576),
        );

        return Outcome.bad('the allocation succeeded — the cap did nothing');
      } on MontyScriptError catch (e) {
        return e.excType == 'MemoryError'
            ? Outcome.ok('${e.excType}: ${_firstLine(e.message)}')
            : Outcome.bad('threw ${e.excType}: ${_firstLine(e.message)}');
      } finally {
        await platform.dispose();
      }
    },
  ),

  Probe(
    title: 'The convenience API inherits the session limitation',
    proves:
        'The trap worth knowing: Monty(code).run() builds a MontyRepl '
        'internally, so passing limits: to the one-line entry point hits the '
        'session restriction above even though the underlying engine enforces '
        'limits perfectly well. Use createPlatformMonty() when you need a cap '
        'on the web.',
    source: "Monty('1 + 1').run(limits: MontyLimits(timeoutMs: 50))",
    expected: 'the same UnsupportedError — not a silently dropped cap',
    run: () async {
      try {
        await Monty('1 + 1').run(limits: const MontyLimits(timeoutMs: 50));

        return Outcome.bad(
          'accepted — either the cap was dropped, or this no longer routes '
          'through MontyRepl and the error message needs updating',
        );
      } on UnsupportedError catch (e) {
        return Outcome.ok(_firstLine(e.toString()), note: 'core#140');
      }
    },
  ),

  Probe(
    title: 'Session limits refuse loudly on the web',
    proves:
        'Read this together with the two rows above, which show limits being '
        'enforced on this very page. What is missing on the web is not limits '
        '— it is SESSION-scoped limits: the JS replCreate takes no limits '
        'parameter, so a persistent session cannot carry one. Rather than '
        'accept and ignore it (the exact defect fixed elsewhere in this list) '
        'the constructor refuses.',
    source: 'MontyRepl(limits: MontyLimits(timeoutMs: 50))',
    expected: 'UnsupportedError, not silent acceptance',
    run: () async {
      final repl = MontyRepl(limits: const MontyLimits(timeoutMs: 50));
      try {
        await repl.feedRun('1 + 1');

        return Outcome.bad('accepted — a limit was silently dropped');
      } on UnsupportedError catch (e) {
        return Outcome.ok(_firstLine(e.toString()), note: 'core#140');
      } finally {
        await repl.dispose().catchError((_) {});
      }
    },
  ),

  Probe(
    title: 'A session keeps its heap',
    proves:
        'MontyRepl is a persistent interpreter, not a series of one-shots: '
        'variables, functions and imports survive across feeds.',
    source: "feedRun('acc = []') → feedRun('acc.append(1)') → feedRun('acc')",
    expected: '[1]',
    run: () async {
      final repl = MontyRepl();
      try {
        await repl.feedRun('acc = []');
        await repl.feedRun('acc.append(1)');
        final got = _render((await repl.feedRun('acc')).value);

        return got == '[1]' ? Outcome.ok(got) : Outcome.bad(got);
      } finally {
        await repl.dispose();
      }
    },
  ),

  Probe(
    title: 'A session can be snapshotted and rewound',
    proves:
        'The whole interpreter heap serialises to bytes and restores, so a '
        'host can checkpoint before running untrusted code and roll back after.',
    source: "x = 1 → snapshot() → x = 999 → restore() → x",
    expected: '1 — the mutation is undone',
    run: () async {
      final repl = MontyRepl();
      try {
        await repl.feedRun('x = 1');
        final snap = await repl.snapshot();
        await repl.feedRun('x = 999');
        final mutated = _render((await repl.feedRun('x')).value);
        await repl.restore(snap);
        final got = _render((await repl.feedRun('x')).value);

        return got == '1'
            ? Outcome.ok('$got  (was $mutated before restore)')
            : Outcome.bad('$got after restore, want 1');
      } finally {
        await repl.dispose();
      }
    },
  ),

  Probe(
    title: 'Filesystem access is mediated by the host',
    proves:
        'There is no real filesystem here. `pathlib` calls surface as OS-call '
        'requests the host answers — so the host decides what exists, what is '
        'readable, and what is refused.',
    source: "pathlib.Path('/data/hello.txt').read_text()",
    expected: "'Hello from a virtual filesystem!'",
    run: () async {
      final r =
          await Monty(
            "import pathlib\npathlib.Path('/data/hello.txt').read_text()",
          ).run(
            osHandler: memoryMountedOsHandler(
              mounts: const [MountDir(virtualPath: '/data')],
              vfs: {'/data/hello.txt': 'Hello from a virtual filesystem!'},
            ),
          );
      final got = _render(r.value);

      return got == "'Hello from a virtual filesystem!'"
          ? Outcome.ok(got)
          : Outcome.bad('$got  err=${r.error?.message ?? '-'}');
    },
  ),

  Probe(
    title: 'An unmounted path is refused',
    proves:
        'The complement of the row above, and the one that matters: a path the '
        'host did not mount is not reachable, however the script asks.',
    source: "pathlib.Path('/etc/passwd').read_text()",
    expected: 'an error, no content',
    run: () async {
      final r =
          await Monty(
            "import pathlib\npathlib.Path('/etc/passwd').read_text()",
          ).run(
            osHandler: memoryMountedOsHandler(
              mounts: const [MountDir(virtualPath: '/data')],
              vfs: {'/data/hello.txt': 'Hello from a virtual filesystem!'},
            ),
          );

      final err = r.error;

      return err != null
          ? Outcome.ok('${err.excType ?? 'error'}: ${_firstLine(err.message)}')
          : Outcome.bad('read succeeded: ${_render(r.value)}');
    },
  ),

  Probe(
    title: 'Code can be checked before it runs',
    proves:
        'Type errors are reported without executing anything — so a host can '
        'reject bad input before it costs an interpreter session.',
    source: "Monty.typeCheck('x: int = \"not an int\"')",
    expected: 'at least one diagnostic, nothing executed',
    run: () async {
      final errors = await Monty.typeCheck('x: int = "not an int"');

      return errors.isNotEmpty
          ? Outcome.ok('${errors.length} diagnostic: ${errors.first.message}')
          : Outcome.bad('no diagnostics — the type error was not caught');
    },
  ),

  Probe(
    title: 'A Python exception is data, not a crash',
    proves:
        'A raise inside the sandbox comes back as a structured result — type, '
        'message and traceback — rather than throwing into host code. The host '
        'stays in control of what to do about it.',
    source: "raise ValueError('boom')",
    expected: "excType 'ValueError', error text, no Dart throw",
    run: () async {
      final r = await Monty("raise ValueError('boom')").run();
      final err = r.error;

      return err != null &&
              err.excType == 'ValueError' &&
              err.message.contains('boom')
          ? Outcome.ok(
              '${err.excType}: ${_firstLine(err.message)} '
              '(${err.traceback.length} frame(s))',
            )
          : Outcome.bad('excType=${err?.excType} message=${err?.message}');
    },
  ),
];

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

String _firstLine(String s) {
  final line = s.split('\n').first.trim();

  return line.length > 110 ? '${line.substring(0, 110)}…' : line;
}

/// Renders a [MontyValue] the way Python would print it, so the expected
/// column can be written in Python terms rather than Dart ones.
String _render(Object? v) => switch (v) {
  null => 'null',
  MontyNone() => 'None',
  MontyBool(:final value) => value ? 'True' : 'False',
  MontyInt(:final value) => '$value',
  MontyBigInt(:final value) => '$value',
  MontyFloat(:final value) => _float(value),
  MontyString(:final value) => "'$value'",
  MontyList(:final items) => '[${items.map(_render).join(', ')}]',
  MontyTuple(:final items) => '(${items.map(_render).join(', ')})',
  final MontyValue mv => mv.runtimeType.toString(),
  _ => '$v',
};

/// dart2js renders 4.0 as "4"; this is the same rule the library uses on the
/// wire, applied to display so the page does not reproduce the bug it reports.
String _float(double d) {
  if (d.isNaN) return 'nan';
  if (d.isInfinite) return d > 0 ? 'inf' : '-inf';
  if (d == 0 && d.isNegative) return '-0.0';
  final t = '$d';

  return t.contains('.') || t.contains('e') ? t : '$t.0';
}

final _doc = web.document;

// ---------------------------------------------------------------------------
// The conformance panel
// ---------------------------------------------------------------------------
//
// The 16 probes above cover the HOST surface — externals, limits, the VFS,
// snapshots — because that is dart_monty_core's own contribution and no corpus
// can test it. This panel covers the other surface: what sandboxed Python can
// actually do, and for that the honest source is not rows I invented but
// monty's OWN conformance corpus.
//
// All 531 fixtures ship in `package:monty_conformance` (one copy, shared with
// this repo's oracle and WASM harnesses — Dart cannot import another package's
// test/, which is why it is a package at all). Each carries a `# Return=` or
// `# Raise=` directive that IS the expected answer, written upstream, not by
// us. This panel runs them in your browser and checks them the same way
// `wasm_fixture_test.dart` does.

/// Why a fixture is not asserted here.
enum SkipKind {
  /// Needs the host to answer: `# call-external`, `# mount-fs`, `# run-async`.
  /// Not a gap in the engine — these are the probes above, in fixture form.
  needsHost('needs a host'),

  /// Known to diverge on the web transport (core#128), or needs a `test-hooks`
  /// build that is never shipped.
  divergent('web divergence'),

  /// The fixture asserts nothing to check against.
  noDirective('no directive');

  const SkipKind(this.label);

  final String label;
}

class _Fixture {
  _Fixture(this.name, this.source)
    : group = name.contains('__') ? name.split('__').first : 'misc';

  final String name;
  final String source;
  final String group;
}

/// Per-fixture outcome, filled in by [_runCorpus] and read by the drill-down.
/// Empty until the corpus is run; the skip reasons are known without running.
final Map<String, String> _fixtureStatus = {};

/// Why a host-backed fixture could not be completed, when that happens — shown
/// in the drill-down rather than folded into a bare FAIL.
final Map<String, String> _skipNotes = {};

/// What the drill-down is currently showing: a group, a skip reason, or the
/// failures. Every count on this panel is clickable, because a number the
/// reader cannot open is a number they have to take on trust.
sealed class _Selection {
  const _Selection();
}

class _GroupSel extends _Selection {
  const _GroupSel(this.group);
  final String group;
}

class _SkipSel extends _Selection {
  /// [kind] null means "every fixture that was not asserted, for any reason".
  const _SkipSel(this.kind);
  final SkipKind? kind;
}

class _FailSel extends _Selection {
  const _FailSel();
}

_Selection? _selection;

final List<_Fixture> _corpus =
    (fixtureCorpus.entries.map((e) => _Fixture(e.key, e.value)).toList()
      ..sort((a, b) => a.name.compareTo(b.name)));

/// Upstream source for every fixture name shown in the drill-down. Appending a
/// fixture file name to this yields its file on GitHub.
///
/// The tag in this URL MUST track the `monty` git pin in `native/Cargo.toml`
/// (currently `tag = "v0.0.19"`). It is pinned, not `main`, so the source the
/// reader opens is the source these fixtures were vendored from — an upgrade
/// that bumps Cargo.toml without bumping this would silently show the wrong
/// file, which is worse than no link at all.
const _fixtureSourceBase =
    'https://github.com/pydantic/monty/blob/v0.0.19/crates/monty/test_cases/';

/// Classifies a fixture without running it, so the page can show the shape of
/// the corpus instantly and only pay for execution on demand.
SkipKind? _skipReason(_Fixture f) {
  if (unsupportedWasmFixtures.contains(f.name)) return SkipKind.divergent;

  // `# call-external` is NOT a skip here. Those fixtures are the host↔sandbox
  // round trip, which is the whole point of this package — refusing to run
  // them in its demo would be the strangest possible omission. The panel
  // supplies the externals they ask for (package:monty_conformance) and drives
  // the pending/resume loop.
  // Both flags off: a fixture can be call-external AND run-async
  // (async__ext_call.py is), and leaving skipRunAsync on here made parseFixture
  // return null for it, which this then mislabelled "no directive". It has
  // internal asserts — running it without raising IS the assertion.
  if (fixtureIsCallExternal(f.source) || fixtureIsRunAsync(f.source)) {
    return parseFixture(
              f.source,
              skipCallExternal: false,
              skipRunAsync: false,
              skipWasm: true,
            ) ==
            null
        ? SkipKind.noDirective
        : null;
  }

  // `# mount-fs` fixtures want a pre-populated filesystem bound to `root`.
  // The panel supplies one with the PUBLIC memoryMountedOsHandler — notably
  // without the ~400-line private VFS the WASM corpus runner carries.
  if (fixtureMountsFs(f.source)) {
    return parseFixture(f.source, skipMountFs: false, skipWasm: true) == null
        ? SkipKind.noDirective
        : null;
  }

  if (parseFixture(f.source, skipWasm: true) == null) {
    return SkipKind.noDirective;
  }

  return null;
}

/// The filesystem a `# mount-fs` fixture expects to find at `root`.
///
/// The contents are upstream's, not ours — the fixtures assert exact sizes
/// (`hello.txt` is 12 bytes, `readonly.txt` is 16), so this is a contract, not
/// a convenience.
const _mountFsSeed = <String, String>{
  '/mnt/hello.txt': 'hello world\n',
  '/mnt/empty.txt': '',
  '/mnt/data.bin': '\x00\x01\x02\x03',
  '/mnt/readonly.txt': 'readonly content',
  '/mnt/subdir/nested.txt': 'nested content',
  '/mnt/subdir/deep/file.txt': 'deep file',
};

/// Runs one fixture exactly as `wasm_fixture_test.dart` does, and reports
/// whether upstream's own directive held.
/// `'PASS'`, `'FAIL'`, or a reason the harness could not assert it.
///
/// The distinction matters: "monty got this wrong" and "this demo does not
/// model the external the fixture asks for" are completely different claims,
/// and collapsing them into FAIL would slander the library.
Future<String> _runFixture(_Fixture f, FixtureExpectation expectation) async {
  if (fixtureIsCallExternal(f.source)) {
    final platform = createPlatformMonty();
    try {
      final o = await runCallExternalFixture(
        platform,
        f.source,
        scriptName: f.name,
      );
      if (o.skipped) {
        _skipNotes[f.name] = o.skipReason ?? 'skipped';

        return o.skipReason ?? 'not modelled';
      }

      final ok = switch (expectation) {
        ExpectNoException() => o.excType == null,
        ExpectReturn(value: final want) =>
          o.excType == null && o.value == MontyValue.fromDart(want),
        ExpectRaise(:final excType) => o.excType == excType,
      };

      return ok ? 'PASS' : 'FAIL';
    } on StateError catch (e) {
      // conformanceDispatch throws this for an external it does not model.
      _skipNotes[f.name] = e.message;

      return 'not modelled';
    } finally {
      await platform.dispose();
    }
  }

  final platform = createPlatformMonty();
  MontyResult? result;
  String? thrownExcType;
  try {
    if (fixtureMountsFs(f.source)) {
      // The fixtures document that `root` is injected by the test runner, so
      // injecting it is part of honouring the directive, not a cheat.
      final r =
          await Monty(
            "from pathlib import Path as _P\nroot = _P('/mnt')\n${f.source}",
          ).run(
            osHandler: memoryMountedOsHandler(
              mounts: const [MountDir(virtualPath: '/mnt')],
              vfs: Map.of(_mountFsSeed),
            ),
          );

      // A red row must say why. These two currently fail on FB-11 (a missing
      // file INSIDE a mount reports PermissionError instead of
      // FileNotFoundError), and leaving them red rather than relabelling them
      // is deliberate: the library really does fail them.
      if (r.error != null)
        _skipNotes[f.name] = r.error!.message.split('\n').first;

      return switch (expectation) {
        ExpectNoException() => r.error == null ? 'PASS' : 'FAIL',
        ExpectReturn(value: final want) =>
          r.error == null && r.value == MontyValue.fromDart(want)
              ? 'PASS'
              : 'FAIL',
        ExpectRaise(:final excType) =>
          r.error?.excType == excType ? 'PASS' : 'FAIL',
      };
    }

    result = await platform.run(f.source, scriptName: f.name);
    thrownExcType = result.error?.excType;
  } on MontyScriptError catch (e) {
    thrownExcType = e.excType;
  } on Object catch (e) {
    _skipNotes[f.name] = e.toString();

    return 'FAIL';
  } finally {
    await platform.dispose();
  }

  final ok = switch (expectation) {
    ExpectNoException() => thrownExcType == null,
    ExpectReturn(value: final want) =>
      thrownExcType == null && result?.value == MontyValue.fromDart(want),
    ExpectRaise(:final excType) => thrownExcType == excType,
  };

  return ok ? 'PASS' : 'FAIL';
}

void _renderCorpusOverview() {
  final host = _doc.getElementById('corpus-groups');
  if (host == null) return;
  host.textContent = '';

  final byGroup = <String, List<_Fixture>>{};
  for (final f in _corpus) {
    byGroup.putIfAbsent(f.group, () => []).add(f);
  }
  final groups = byGroup.keys.toList()..sort();

  var runnable = 0;
  for (final f in _corpus) {
    if (_skipReason(f) == null) runnable++;
  }
  _doc.getElementById('corpus-headline')?.textContent =
      '$runnable of ${_corpus.length} upstream fixtures assert in this browser';

  // Why the rest are not asserted — the question the counts alone provoke.
  final reasons = <SkipKind, int>{};
  for (final f in _corpus) {
    final r = _skipReason(f);
    if (r != null) reasons[r] = (reasons[r] ?? 0) + 1;
  }
  final breakdown = _doc.getElementById('corpus-breakdown');
  if (breakdown != null) {
    breakdown.textContent = '';
    for (final k in SkipKind.values) {
      final n = reasons[k] ?? 0;
      if (n == 0) continue;
      breakdown.append(_el('span', cls: 'pill v-run', text: '$n ${k.label}'));
    }
  }

  for (final g in groups) {
    final all = byGroup[g]!;
    final n = all.where((f) => _skipReason(f) == null).length;
    final chip = _el('button', cls: 'chip${n == 0 ? ' chip-none' : ''}')
      ..append(_el('span', cls: 'chip-name', text: g))
      ..append(_el('span', cls: 'chip-n', text: '$n/${all.length}'))
      ..id = 'grp-$g';
    (chip as web.HTMLButtonElement).onclick = (web.MouseEvent _) {
      final cur = _selection;
      _selection = (cur is _GroupSel && cur.group == g) ? null : _GroupSel(g);
      _renderGroupDetail();
    }.toJS;
    host.append(chip);
  }
  _renderGroupDetail();
}

/// Lists every fixture in the open group: its name, what happened to it (or
/// why it was not asserted), and the Python that ran. Without this the panel
/// reports a score and hides the evidence, which is the failure mode the whole
/// page exists to avoid.
void _renderGroupDetail() {
  final host = _doc.getElementById('corpus-detail');
  if (host == null) return;
  host.textContent = '';
  final sel = _selection;
  if (sel == null) {
    host.append(
      _el(
        'p',
        cls: 'muted',
        text:
            'Pick a group above to see its fixtures, their sources, and '
            'exactly why any of them are not asserted.',
      ),
    );

    return;
  }

  final (members, heading) = switch (sel) {
    _GroupSel(:final group) => (
      _corpus.where((f) => f.group == group).toList(),
      group,
    ),
    _SkipSel(kind: final k?) => (
      _corpus.where((f) => _skipReason(f) == k).toList(),
      'not asserted — ${k.label}',
    ),
    _SkipSel(kind: null) => (
      _corpus.where((f) => _skipReason(f) != null).toList(),
      'not asserted — every reason',
    ),
    _FailSel() => (
      _corpus.where((f) => _fixtureStatus[f.name] == 'FAIL').toList(),
      'failing',
    ),
  };

  host.append(
    _el('h3', cls: 'detail-h', text: '$heading — ${members.length} fixture(s)'),
  );

  for (final f in members) {
    final skip = _skipReason(f);
    final status = _fixtureStatus[f.name] ?? (skip?.label ?? 'not run yet');
    final cls = switch (status) {
      'PASS' => 'v-pass',
      'FAIL' => 'v-fail',
      _ => 'v-run',
    };
    final expectation = parseFixture(f.source, skipWasm: false);
    final want = switch (expectation) {
      ExpectReturn(:final value) => 'Return= $value',
      ExpectRaise(:final excType, :final message) =>
        'Raise= $excType: $message',
      ExpectNoException() => 'must not raise',
      null => 'no directive',
    };

    host.append(
      _el('div', cls: 'fx')
        ..append(_el('span', cls: 'pill $cls', text: status))
        ..append(
          _el('a', cls: 'fx-name', text: f.name)
            ..setAttribute('href', '$_fixtureSourceBase${f.name}')
            ..setAttribute('target', '_blank')
            ..setAttribute('rel', 'noopener'),
        )
        ..append(
          _el(
            'span',
            cls: 'fx-want',
            text: _skipNotes[f.name] == null
                ? want
                : '$want  ·  ${_skipNotes[f.name]}',
          ),
        )
        ..append(_el('pre', cls: 'src', text: f.source.trimRight())),
    );
  }
}

Future<void> _runCorpus() async {
  final btn = _doc.getElementById('run-corpus') as web.HTMLButtonElement?;
  btn?.disabled = true;
  final status = _doc.getElementById('corpus-status');
  final started = DateTime.now();

  var passed = 0;
  var failed = 0;
  var skipped = 0;
  final failures = <String>[];

  for (var i = 0; i < _corpus.length; i++) {
    final f = _corpus[i];
    final skip = _skipReason(f);
    if (skip != null) {
      skipped++;
      _fixtureStatus[f.name] = skip.label;
    } else {
      final expectation = parseFixture(
        f.source,
        skipCallExternal: false,
        skipRunAsync: false,
        skipMountFs: false,
        skipWasm: true,
      )!;
      final status = await _runFixture(f, expectation);
      _fixtureStatus[f.name] = status;
      switch (status) {
        case 'PASS':
          passed++;
        case 'FAIL':
          failed++;
          if (failures.length < 12) failures.add(f.name);
        default:
          // The harness could not assert it — not a library failure.
          skipped++;
      }
    }
    // Yield to the event loop so the browser can paint progress; without this
    // the page freezes for the whole run and looks hung.
    if (i % 25 == 0) {
      status?.textContent =
          '$i / ${_corpus.length} — $passed passed, $failed failed';
      await Future<void>.delayed(Duration.zero);
    }
  }

  final took = DateTime.now().difference(started);
  status?.textContent = '';
  final failPill = _el(
    'button',
    cls: 'pill pill-btn ${failed == 0 ? 'v-run' : 'v-fail'}',
    text: '$failed FAIL',
  );
  (failPill as web.HTMLButtonElement).onclick = (web.MouseEvent _) {
    _selection = const _FailSel();
    _renderGroupDetail();
  }.toJS;

  final skipPill = _el(
    'button',
    cls: 'pill v-run pill-btn',
    text: '$skipped not asserted',
  );
  (skipPill as web.HTMLButtonElement).onclick = (web.MouseEvent _) {
    final cur = _selection;
    _selection = (cur is _SkipSel && cur.kind == null)
        ? null
        : const _SkipSel(null);
    _renderGroupDetail();
  }.toJS;

  status
    ?..append(_el('span', cls: 'pill v-pass', text: '$passed PASS'))
    ..append(failPill)
    ..append(skipPill)
    ..append(_el('span', cls: 'took', text: '${took.inMilliseconds} ms'))
    ..append(
      _el(
        'span',
        cls: 'took',
        text: '· ${DateTime.now().toIso8601String().substring(0, 19)}',
      ),
    );

  if (failures.isNotEmpty) {
    status?.append(
      _el('div', cls: 'note', text: 'failing: ${failures.join(', ')}'),
    );
  }
  _renderGroupDetail();
  btn?.disabled = false;
}

web.Element _el(String tag, {String? cls, String? text}) {
  final e = _doc.createElement(tag);
  if (cls != null) e.className = cls;
  if (text != null) e.textContent = text;

  return e;
}

void _renderRow(web.Element tbody, Probe p, int i) {
  final tr = _el('tr')..id = 'probe-$i';
  tr
    ..append(
      _el('td', cls: 'c-verdict')..append(
        _el(
          'span',
          cls: 'pill ${Verdict.running.css}',
          text: Verdict.running.label,
        ),
      ),
    )
    ..append(
      _el('td', cls: 'c-what')
        ..append(_el('div', cls: 'title', text: p.title))
        ..append(_el('div', cls: 'proves', text: p.proves))
        ..append(_el('pre', cls: 'src', text: p.source)),
    )
    ..append(
      _el('td', cls: 'c-result')
        ..append(_el('div', cls: 'want', text: 'expected: ${p.expected}'))
        ..append(_el('div', cls: 'got', text: '…')),
    );
  tbody.append(tr);
}

void _paint(int i, Outcome o) {
  final tr = _doc.getElementById('probe-$i');
  if (tr == null) return;
  final pill = tr.querySelector('.pill')!
    ..className = 'pill ${o.verdict.css}'
    ..textContent = o.verdict.label;
  pill.setAttribute('data-verdict', o.verdict.label);
  final got = tr.querySelector('.got')!
    ..textContent = o.actual
    ..className = 'got ${o.verdict == Verdict.pass ? '' : 'got-bad'}';
  if (o.note != null) {
    got.append(_el('div', cls: 'note', text: o.note!));
  }
}

void _summarise(Map<Verdict, int> counts, Duration took) {
  final el = _doc.getElementById('summary');
  if (el == null) return;
  el.textContent = '';
  for (final v in [Verdict.pass, Verdict.gap, Verdict.fail, Verdict.crash]) {
    final n = counts[v] ?? 0;
    if (n == 0) continue;
    el.append(_el('span', cls: 'pill ${v.css}', text: '$n ${v.label}'));
  }
  el.append(_el('span', cls: 'took', text: '${took.inMilliseconds} ms'));
  // Stamped on purpose. A claim in a README is only as good as the day it was
  // written; every row above was re-derived against this build, just now.
  el.append(
    _el(
      'span',
      cls: 'took',
      text: '· measured ${DateTime.now().toIso8601String().substring(0, 19)}',
    ),
  );
}

Future<void> _runAll() async {
  final probes = _probes();
  final tbody = _doc.getElementById('rows')!..textContent = '';
  for (var i = 0; i < probes.length; i++) {
    _renderRow(tbody, probes[i], i);
  }

  final counts = <Verdict, int>{};
  final started = DateTime.now();

  for (var i = 0; i < probes.length; i++) {
    Outcome outcome;
    try {
      // A hung probe must not take the page down with it. 20s is generous —
      // every probe here is milliseconds — but a cold wasm boot on a slow
      // machine is not.
      outcome = await probes[i].run().timeout(const Duration(seconds: 20));
    } on TimeoutException {
      outcome = Outcome.bad('timed out after 20s');
    } on Object catch (e) {
      outcome = Outcome(Verdict.crash, _firstLine(e.toString()));
    }
    counts[outcome.verdict] = (counts[outcome.verdict] ?? 0) + 1;
    _paint(i, outcome);
  }

  _summarise(counts, DateTime.now().difference(started));
  (_doc.getElementById('rerun') as web.HTMLButtonElement?)?.disabled = false;
}

void main() {
  _doc.getElementById('backend')?.textContent = _isJs ? 'dart2js' : 'dart2wasm';
  final rerun = _doc.getElementById('rerun') as web.HTMLButtonElement?;
  rerun?.onclick = (web.MouseEvent _) {
    rerun.disabled = true;
    unawaited(_runAll());
  }.toJS;
  final runCorpus = _doc.getElementById('run-corpus') as web.HTMLButtonElement?;
  runCorpus?.onclick = (web.MouseEvent _) {
    unawaited(_runCorpus());
  }.toJS;
  _renderCorpusOverview();
  unawaited(_runAll());
}

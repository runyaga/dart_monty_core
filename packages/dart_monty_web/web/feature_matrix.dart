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
        'distinction is destroyed before the library is entered. Not fixable '
        'inside the package — only a typed input could carry it. dart2wasm has '
        'real doubles and gets this right.',
    source: "inputs: {'x': 4.0}  →  type(x).__name__",
    expected: "'float'",
    run: () async {
      final r = await Monty('type(x).__name__').run(inputs: {'x': 4.0});
      final got = _render(r.value);
      if (got == "'float'") return Outcome.ok(got);

      return _isJs
          ? Outcome.knownGap(
              '$got — dart2js erases 4.0 vs 4',
              note: 'core#137 · not reachable from inside the library',
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
  unawaited(_runAll());
}

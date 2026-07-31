// Web demo for dart_monty_core — three panels.
//
//  Panel A — MontyRepl (persistent heap, snapshot/restore, detectContinuation)
//    Exercises: MontyRepl.feedRun, externals, osHandler, detectContinuation,
//               snapshot, restore, all MontyValue types, MontyResult fields,
//               Monty.typeCheck (🔎 pre-flight, no execution).
//
//  Panel B — Externals showcase (Python → Dart callbacks)
//    Exercises: MontyRepl.feedStart/resume, MontyPending (functionName, args,
//               kwargs, callId), resumeWithError, MontyOsCall, MontyProgress.
//    Pre-registered Dart functions: db_query, compute, format_currency, now.
//    Each call is logged with its arguments and return value so the flow
//    is visible.
//
//  Panel VFS — MontyRepl + per-call osHandler (virtual filesystem,
//  snapshot/restore)
//    Exercises: MontyRepl.feedRun(osHandler:), pathlib, OsCallException,
//               snapshot, restore, MontyPath value type.
import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:web/web.dart' as web;

// ---------------------------------------------------------------------------
// Mock data for the externals panel
// ---------------------------------------------------------------------------
final _mockDb = <String, List<Map<String, Object?>>>{
  'users': [
    {'id': 1, 'name': 'Alice', 'role': 'admin', 'active': true},
    {'id': 2, 'name': 'Bob', 'role': 'user', 'active': true},
    {'id': 3, 'name': 'Carol', 'role': 'user', 'active': false},
  ],
  'products': [
    {'id': 101, 'name': 'Widget', 'price': 9.99, 'stock': 42},
    {'id': 102, 'name': 'Gadget', 'price': 24.99, 'stock': 7},
  ],
};

// ---------------------------------------------------------------------------
// In-memory VFS for the VFS panel
// ---------------------------------------------------------------------------
final Map<String, String> _vfs = {
  '/data/hello.txt': 'Hello from the virtual filesystem!',
  '/data/config.txt': 'version=1.0\nenv=demo',
};

Future<Object?> _vfsOsHandler(
  String op,
  List<Object?> args,
  Map<String, Object?>? kwargs,
) async {
  switch (op) {
    case 'Path.read_text':
      return _vfs[args.first! as String] ?? '';
    case 'Path.write_text':
      _vfs[args[0]! as String] = args[1]! as String;
      return null;
    case 'Path.exists':
      return _vfs.containsKey(args.first! as String);
    case 'Path.unlink':
      _vfs.remove(args.first! as String);
      return null;
    // open() — the interpreter emits the prefix-less `open`, takes the returned
    // handle, then drives writes through `append_text`. resolveOpenCall (owned by
    // dart_monty_core) maps mode → effect and raises the typed FileNotFoundError
    // for a missing 'r' target; this map-backed VFS only supplies the filesystem
    // facts.
    //
    // monty v0.0.19 renamed this op from 'Open' to 'open' (#576). This demo is a
    // CONSUMER of dart_monty_core, and it broke exactly the way the CHANGELOG
    // warns consumers it will: the case stopped matching, the call fell through to
    // `default`, and the VFS example failed with "open not supported in this demo"
    // — with no compile error anywhere.
    case 'open':
      return resolveOpenCall(
        args[0]! as String,
        args[1]! as String,
        exists: _vfs.containsKey,
        truncate: (p) => _vfs[p] = '',
        createIfMissing: (p) => _vfs.putIfAbsent(p, () => ''),
      );
    case 'Path.append_text':
      final text = args[1]! as String;
      _vfs[args[0]! as String] = (_vfs[args[0]! as String] ?? '') + text;
      // f.write() resumes with the number of characters written.
      return text.length;
    default:
      throw OsCallException('$op not supported in this demo');
  }
}

// ---------------------------------------------------------------------------
// DOM helpers
// ---------------------------------------------------------------------------
web.HTMLDivElement _div(String id) =>
    web.document.getElementById(id)! as web.HTMLDivElement;
web.HTMLInputElement _input(String id) =>
    web.document.getElementById(id)! as web.HTMLInputElement;
web.HTMLTextAreaElement _textarea(String id) =>
    web.document.getElementById(id)! as web.HTMLTextAreaElement;
web.HTMLButtonElement _button(String id) =>
    web.document.getElementById(id)! as web.HTMLButtonElement;

void _appendLine(web.HTMLDivElement output, String text, {String? className}) {
  final div = web.document.createElement('div') as web.HTMLDivElement
    ..textContent = text;
  if (className != null) div.className = className;
  output
    ..appendChild(div)
    ..scrollTop = output.scrollHeight;
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
void main() {
  _initReplPanel();
  _initExternalsPanel();
  _initVfsPanel();
  _initExamples();
}

// ---------------------------------------------------------------------------
// Panel A — MontyRepl with feed, detectContinuation, snapshot/restore
// ---------------------------------------------------------------------------
void _initReplPanel() {
  final output = _div('output-a');
  final input = _textarea('input-a'); // textarea preserves newlines
  final runBtn = _button('run-a');

  final repl = MontyRepl();
  Uint8List? savedSnap;

  void write(String text, {String? className}) =>
      _appendLine(output, text, className: className);

  output.innerHTML = ''.toJS;
  write(
    'MontyRepl — persistent heap across feed() calls.',
    className: 'system-line',
  );
  write(
    'Try: x = 10 → then: x * x  |  snapshot with 📸  |  mutate  |  ↩ restore',
    className: 'system-line',
  );
  write(
    'Externals: host_upper("hello")  calls a Dart function from Python.',
    className: 'system-line',
  );
  write(
    'Pre-flight: 🔎 runs Monty.typeCheck on the input — diagnostics, no execution.',
    className: 'system-line',
  );

  Future<void> execute() async {
    final code = input.value.trim();
    if (code.isEmpty) {
      input.focus();
      return;
    }

    final mode = await repl.detectContinuation(code);
    if (mode != ReplContinuationMode.complete) return;

    input.value = '';
    write('>>> $code', className: 'input-line');

    try {
      final result = await repl.feedRun(
        code,
        externalFunctions: {
          'host_upper': (args, _) async => (args[0] as String).toUpperCase(),
        },
        osHandler: _vfsOsHandler,
      );

      if (result.printOutput != null && result.printOutput!.isNotEmpty) {
        write(result.printOutput!.trimRight(), className: 'print-line');
      }
      if (result.error != null) {
        write(
          '${result.error!.excType}: ${result.error!.message}',
          className: 'error-line',
        );
      } else if (result.value is! MontyNone) {
        write('=> ${_fmt(result.value)}', className: 'output-line');
      }
    } on MontyScriptError catch (e) {
      write('${e.excType}: ${e.message}', className: 'error-line');
    } on MontyError catch (e) {
      write('${e.runtimeType}: ${e.message}', className: 'error-line');
    }
    input.focus();
  }

  // Inline buttons appended after the Run button. Insertion order matters:
  // each insertAdjacentElement('afterend', …) places the element directly
  // after Run, so the visible order becomes Run, 🔎, 📸, ↩.
  final snapBtn = web.document.createElement('button') as web.HTMLButtonElement
    ..textContent = '📸'
    ..className = 'btn-sm';
  final restoreBtn =
      web.document.createElement('button') as web.HTMLButtonElement
        ..textContent = '↩'
        ..className = 'btn-sm';
  final typeCheckBtn =
      web.document.createElement('button') as web.HTMLButtonElement
        ..textContent = '🔎'
        ..className = 'btn-sm';
  runBtn.insertAdjacentElement('afterend', restoreBtn);
  runBtn.insertAdjacentElement('afterend', snapBtn);
  runBtn.insertAdjacentElement('afterend', typeCheckBtn);

  // Static signatures for Dart-registered externals so Monty.typeCheck
  // recognises calls like host_upper("hi") instead of flagging an
  // undefined name. Kept in sync with the externalFunctions map below.
  // The body must be type-clean (return a str): Monty's checker treats
  // `...` as an empty body that implicitly returns None.
  const externalsPrefix = '''
def host_upper(s: str) -> str:
    return s
''';
  // Newline count of the prefix — diagnostics in this region come from
  // the synthetic prefix, not user code, and are filtered out below.
  // Diagnostics in user code have their line numbers rebased so they
  // line up with the textarea.
  final prefixLines = '\n'.allMatches(externalsPrefix).length;

  typeCheckBtn.onclick = (web.MouseEvent _) {
    unawaited(() async {
      final code = input.value.trim();
      if (code.isEmpty) {
        write('🔎 No code to check.', className: 'system-line');
        return;
      }
      try {
        final raw = await Monty.typeCheck(code, prefixCode: externalsPrefix);
        final errors = raw
            .where((e) => e.line == null || e.line! > prefixLines)
            .toList(growable: false);
        if (errors.isEmpty) {
          write('🔎 No type errors.', className: 'system-line');
          return;
        }
        write(
          '🔎 ${errors.length} type ${errors.length == 1 ? 'error' : 'errors'}:',
          className: 'system-line',
        );
        for (final e in errors) {
          final userLine = e.line == null ? null : e.line! - prefixLines;
          final loc = (userLine != null && e.column != null)
              ? '$userLine:${e.column}'
              : (userLine?.toString() ?? '?');
          write('  $loc  ${e.code}: ${e.message}', className: 'error-line');
        }
      } on Object catch (e) {
        write('🔎 typeCheck failed: $e', className: 'error-line');
      }
    }());
  }.toJS;

  snapBtn.onclick = (web.MouseEvent _) {
    unawaited(() async {
      try {
        final b = await repl.snapshot();
        savedSnap = b;
        write('📸 Snapshot (${b.length} bytes).', className: 'system-line');
      } on Object catch (e) {
        write('Snapshot error: $e', className: 'error-line');
      }
    }());
  }.toJS;

  restoreBtn.onclick = (web.MouseEvent _) {
    final s = savedSnap;
    if (s == null) {
      write('No snapshot yet.', className: 'system-line');
      return;
    }
    unawaited(() async {
      try {
        await repl.restore(s);
        write('↩ Restored.', className: 'system-line');
      } on Object catch (e) {
        write('Restore error: $e', className: 'error-line');
      }
    }());
  }.toJS;

  runBtn.onclick = (web.MouseEvent _) {
    unawaited(execute());
  }.toJS;
  // Enter submits; Shift+Enter inserts a newline (textarea default).
  input.onkeydown = (web.KeyboardEvent e) {
    if (e.key == 'Enter' && !e.shiftKey) {
      e.preventDefault();
      unawaited(execute());
    }
  }.toJS;
  input.disabled = false;
  runBtn.disabled = false;
}

// ---------------------------------------------------------------------------
// Panel B — Externals showcase
//
// Pre-registered Dart callbacks Python can call. Each call is logged
// showing functionName, arguments, kwargs → return value, so the
// MontyPending dispatch flow is visible.
//
// Available externals:
//   db_query(table, filter=None)       → list[dict]
//   compute(op, a, b)                  → number  (ops: add mul pow)
//   format_currency(amount, code="USD")→ str
//   now()                              → ISO timestamp str
// ---------------------------------------------------------------------------
void _initExternalsPanel() {
  final output = _div('output-b');
  final input = _input('input-b');
  final runBtn = _button('run-b');

  final repl = MontyRepl();

  void write(String text, {String? className}) =>
      _appendLine(output, text, className: className);

  output.innerHTML = ''.toJS;
  write(
    'Externals — Python calls registered Dart functions.',
    className: 'system-line',
  );
  write('Available:', className: 'system-line');
  write(
    '  db_query(table, filter=None)        → list of dicts',
    className: 'system-line',
  );
  write(
    '  compute(op, a, b)                   → number  (add/mul/pow)',
    className: 'system-line',
  );
  write(
    '  format_currency(amount, code="USD") → str',
    className: 'system-line',
  );
  write(
    '  now()                              → ISO timestamp',
    className: 'system-line',
  );
  write('─' * 48, className: 'system-line');
  write(
    'Try: rows = db_query("users", filter="active")',
    className: 'system-line',
  );
  write(
    '     total = compute("add", len(rows), 100)',
    className: 'system-line',
  );

  // Dart implementations of each external.
  final externals = <String, MontyCallback>{
    'db_query': (args, kwargs) async {
      final table = args[0] as String;
      final filter = kwargs?['filter'];
      final rows = _mockDb[table] ?? [];
      if (filter == null || filter == 'None' || filter == false) return rows;
      return rows.where((r) => r['active'] == true).toList();
    },
    'compute': (args, _) async {
      final op = args[0] as String;
      final a = args[1] as num;
      final b = args[2] as num;
      return switch (op) {
        'add' => a + b,
        'mul' => a * b,
        'pow' => a.toDouble() * a.toDouble(), // simplified
        _ => throw Exception('unknown op: $op'),
      };
    },
    'format_currency': (args, kwargs) async {
      final amount = args[0] as num;
      final code = (kwargs?['code'] as String?) ?? 'USD';
      return '$code ${amount.toStringAsFixed(2)}';
    },
    'now': (_, _) async => DateTime.now().toIso8601String(),
  };

  Future<void> execute() async {
    final code = input.value.trim();
    if (code.isEmpty) {
      input.focus();
      return;
    }
    input.value = '';
    write('>>> $code', className: 'input-line');

    try {
      // Use start/resume so we can log each MontyPending call as it happens.
      var progress = await repl.feedStart(
        code,
        externalFunctions: externals.keys.toList(),
      );

      while (true) {
        switch (progress) {
          case MontyComplete(:final result):
            if (result.printOutput != null && result.printOutput!.isNotEmpty) {
              write(result.printOutput!.trimRight(), className: 'print-line');
            }
            if (result.error != null) {
              write(
                '${result.error!.excType}: ${result.error!.message}',
                className: 'error-line',
              );
            } else if (result.value is! MontyNone) {
              write('=> ${_fmt(result.value)}', className: 'output-line');
            }
            input.focus();
            return;

          case MontyPending(
            :final functionName,
            :final args,
            :final kwargs,
            :final callId,
          ):
            final argStr = [
              ...args.map((a) => _fmt(a)),
              if (kwargs != null)
                ...kwargs.entries.map((e) => '${e.key}=${_fmt(e.value)}'),
            ].join(', ');

            final cb = externals[functionName];
            if (cb == null) {
              write(
                '  ⚡ #$callId $functionName($argStr) → ERROR: no handler',
                className: 'error-line',
              );
              progress = await repl.resumeWithError(
                'No handler: $functionName',
              );
            } else {
              try {
                final dartArgs = args.map((v) => v.dartValue).toList();
                final dartKwargs = kwargs?.map(
                  (k, v) => MapEntry(k, v.dartValue),
                );
                final result = await cb(dartArgs, dartKwargs);
                final resultStr = result is List
                    ? '[${(result as List).length} rows]'
                    : result.toString();
                write(
                  '  ⚡ #$callId $functionName($argStr) → $resultStr',
                  className: 'system-line',
                );
                progress = await repl.resume(result);
              } on Object catch (e) {
                write(
                  '  ⚡ #$callId $functionName($argStr) → ERROR: $e',
                  className: 'error-line',
                );
                progress = await repl.resumeWithError(e.toString());
              }
            }

          case MontyOsCall(:final operationName):
            progress = await repl.resumeWithError(
              '$operationName not available in externals panel',
            );

          case MontyNameLookup(:final variableName):
            progress = await repl.resumeWithError('$variableName not found');

          case MontyResolveFutures():
            progress = await repl.resume(null);
        }
      }
    } on MontyScriptError catch (e) {
      write('${e.excType}: ${e.message}', className: 'error-line');
    } on MontyError catch (e) {
      write('${e.runtimeType}: ${e.message}', className: 'error-line');
      input.focus();
    }
  }

  runBtn.onclick = (web.MouseEvent _) {
    unawaited(execute());
  }.toJS;
  input.onkeydown = (web.KeyboardEvent e) {
    if (e.key == 'Enter') unawaited(execute());
  }.toJS;
  input.disabled = false;
  runBtn.disabled = false;
}

// ---------------------------------------------------------------------------
// Panel VFS — MontyRepl with per-call osHandler, pathlib, snapshot/restore
// ---------------------------------------------------------------------------
void _initVfsPanel() {
  final output = _div('output-vfs');
  final input = _input('input-vfs');
  final runBtn = _button('run-vfs');
  final snapBtn = _button('snap-vfs');
  final restoreBtn = _button('restore-vfs');

  Uint8List? savedSnap;
  final repl = MontyRepl();

  void write(String text, {String? className}) =>
      _appendLine(output, text, className: className);

  output.innerHTML = ''.toJS;
  write(
    'VFS panel — MontyRepl with per-call osHandler. State persists across feedRun calls.',
    className: 'system-line',
  );
  write('Files: ${_vfs.keys.join(", ")}', className: 'system-line');
  write(
    'Try: import pathlib  →  pathlib.Path("/data/hello.txt").read_text()',
    className: 'system-line',
  );

  Future<void> execute() async {
    final code = input.value.trim();
    if (code.isEmpty) {
      input.focus();
      return;
    }
    input.value = '';
    write('>>> $code', className: 'input-line');

    try {
      final result = await repl.feedRun(code, osHandler: _vfsOsHandler);

      if (result.printOutput != null && result.printOutput!.isNotEmpty) {
        write(result.printOutput!.trimRight(), className: 'print-line');
      }
      if (result.error != null) {
        write(
          '${result.error!.excType}: ${result.error!.message}',
          className: 'error-line',
        );
      } else if (result.value is! MontyNone) {
        write('=> ${_fmt(result.value)}', className: 'output-line');
      }
    } on MontyScriptError catch (e) {
      write('${e.excType}: ${e.message}', className: 'error-line');
    } on MontyError catch (e) {
      write('${e.runtimeType}: ${e.message}', className: 'error-line');
    }
    input.focus();
  }

  snapBtn.onclick = (web.MouseEvent _) {
    unawaited(() async {
      final b = await repl.snapshot();
      savedSnap = b;
      write('📸 Snapshot (${b.length} bytes).', className: 'system-line');
    }());
  }.toJS;

  restoreBtn.onclick = (web.MouseEvent _) {
    final s = savedSnap;
    if (s == null) {
      write('No snapshot yet.', className: 'system-line');
      return;
    }
    unawaited(() async {
      await repl.restore(s);
      write('↩ Restored.', className: 'system-line');
    }());
  }.toJS;

  runBtn.onclick = (web.MouseEvent _) {
    unawaited(execute());
  }.toJS;
  input.onkeydown = (web.KeyboardEvent e) {
    if (e.key == 'Enter') unawaited(execute());
  }.toJS;
  input.disabled = false;
  runBtn.disabled = false;
}

// ---------------------------------------------------------------------------
// Examples palette — 15 samples from simple to sophisticated
// ---------------------------------------------------------------------------
class _Step {
  const _Step({required this.label, required this.code});
  final String label;
  final String code;
}

class _Sample {
  const _Sample({
    required this.num,
    required this.title,
    required this.panel,
    required this.desc,
    required this.steps,
  });
  final int num;
  final String title;
  final String panel; // 'a' | 'b' | 'vfs'
  final String desc;
  final List<_Step> steps;
}

const _kSamples = <_Sample>[
  _Sample(
    num: 1,
    title: 'Typed values across the host boundary',
    panel: 'a',
    desc:
        'Every Python value crosses into Dart as a typed MontyValue subtype — '
        'MontyInt, MontyFloat, MontyList, MontyDict, MontyBool, etc. This page '
        'runs the WASM backend; the same types come back over FFI on native. '
        'Submit this dict to see each field typed individually.',
    steps: [
      _Step(
        label: '→ REPL',
        code: '{"pi": 3.14159, "n": 42, "items": [1, 2, 3], "ok": True}',
      ),
    ],
  ),
  _Sample(
    num: 2,
    title: 'Heap persistence between calls',
    panel: 'a',
    desc:
        'Python state lives in the Rust heap between feed() calls — not '
        're-parsed, not serialised to JSON. Inject step 1, run it, then '
        'inject step 2: x is still there.',
    steps: [
      _Step(label: 'Step 1', code: 'x = [i**2 for i in range(1, 6)]'),
      _Step(label: 'Step 2', code: 'sum(x)  # x persists in the Rust heap'),
    ],
  ),
  _Sample(
    num: 3,
    title: 'Multi-line block detection (typed)',
    panel: 'a',
    desc:
        'detectContinuation() returns incompleteBlock when the statement is '
        'not yet closed. Paste the full annotated function — the REPL holds '
        'input until the de-indent completes the block, and 🔎 type-checks '
        'the n: int / -> int signature before you run it.',
    steps: [
      _Step(
        label: '→ REPL',
        code:
            'def fib(n: int) -> int:\n'
            '    a, b = 0, 1\n'
            '    for _ in range(n): a, b = b, a+b\n'
            '    return a\n'
            '\n'
            '[fib(i) for i in range(10)]',
      ),
    ],
  ),
  _Sample(
    num: 4,
    title: 'Snapshot / restore the heap',
    panel: 'a',
    desc:
        'snapshot() serialises the entire Rust heap to postcard bytes. '
        'Run step 1 to set counter=0, click 📸, mutate with step 2 a few '
        'times, then click ↩ — the heap rewinds exactly.',
    steps: [
      _Step(label: 'Step 1 (then 📸)', code: 'counter = 0; counter'),
      _Step(label: 'Step 2 (then ↩)', code: 'counter += 1; counter'),
    ],
  ),
  _Sample(
    num: 5,
    title: 'Error taxonomy',
    panel: 'a',
    desc:
        'MontyError is sealed: MontySyntaxError is caught before execution '
        'starts; MontyScriptError wraps runtime exceptions with a Python '
        'traceback. Each snippet exercises a different subtype.',
    steps: [
      _Step(label: 'SyntaxError', code: 'def broken(:'),
      _Step(label: 'ZeroDivisionError', code: '1 / 0'),
      _Step(label: 'NameError', code: 'undefined_name'),
    ],
  ),
  _Sample(
    num: 6,
    title: 'Single callback — one suspension',
    panel: 'b',
    desc:
        'Calling compute() suspends Python execution and emits MontyPending. '
        'Dart\'s handler runs, calls repl.resume() with the result. '
        'The ⚡ line logs each round-trip across the boundary.',
    steps: [_Step(label: '→ Externals', code: 'compute("add", 19, 23)')],
  ),
  _Sample(
    num: 7,
    title: 'Nested calls — three suspensions',
    panel: 'b',
    desc:
        'A single Python expression can trigger multiple MontyPending events. '
        'Here the two inner compute() calls suspend first, then the outer mul. '
        'Count the ⚡ lines — three distinct suspend/resume cycles.',
    steps: [
      _Step(
        label: '→ Externals',
        code: 'compute("mul", compute("add", 2, 3), compute("add", 4, 1))',
      ),
    ],
  ),
  _Sample(
    num: 8,
    title: 'Kwargs in the callback map',
    panel: 'b',
    desc:
        'MontyCallback receives (args, kwargs) as two separate values: '
        'positional arguments as a list, keyword arguments as a map keyed by '
        'their Python name. format_currency(19.99, code="EUR") fires the '
        'callback with args = [19.99] and kwargs = {code: "EUR"}.',
    steps: [
      _Step(label: '→ Externals', code: 'format_currency(19.99, code="EUR")'),
    ],
  ),
  _Sample(
    num: 9,
    title: 'OsCall — pathlib interception',
    panel: 'vfs',
    desc:
        'pathlib.Path.read_text() becomes a MontyOsCall — Python execution '
        'suspends, Dart looks up the path in its in-memory map, and resumes '
        'with the string. The import must run first; state persists.',
    steps: [
      _Step(label: 'Step 1', code: 'import pathlib'),
      _Step(
        label: 'Step 2',
        code: 'pathlib.Path("/data/hello.txt").read_text()',
      ),
    ],
  ),
  _Sample(
    num: 10,
    title: 'VFS write → read round-trip',
    panel: 'vfs',
    desc:
        'Writing from Python mutates Dart\'s in-memory map via an OsCall. '
        'Reading it back confirms the full cycle: Python → OsCall → Dart map '
        'mutation → OsCall → Python value.',
    steps: [
      _Step(
        label: 'Write',
        code:
            'pathlib.Path("/data/new.txt").write_text("written from Python!")',
      ),
      _Step(label: 'Read', code: 'pathlib.Path("/data/new.txt").read_text()'),
    ],
  ),
  _Sample(
    num: 11,
    title: 'open() write → close → read-back',
    panel: 'vfs',
    desc:
        'monty 0.0.18 ships the builtin open(). Calling it crosses the OsCall '
        'boundary as `Open`, which dart_monty_core\'s resolveOpenCall maps to a '
        'truncate-and-create effect on Dart\'s map; f.write() then rides an '
        'append_text OsCall and resumes with the char count. The dict shows '
        'the write count, the closed flag, and the round-tripped read — one '
        'physical line, three boundary crossings.',
    steps: [
      _Step(
        label: '→ VFS',
        code:
            'f = open("/data/note.txt", "w"); n = f.write("hello\\nworld\\n"); '
            'f.close(); {"wrote": n, "closed": f.closed, '
            '"read_back": open("/data/note.txt").read()}',
      ),
    ],
  ),
  _Sample(
    num: 12,
    title: 'with open(...) — context manager auto-close',
    panel: 'vfs',
    desc:
        'A single-line `with` statement is valid Python when its body is one '
        'simple statement. The context manager enters on the `Open` OsCall and '
        'guarantees the handle is closed on exit — no explicit f.close(). '
        'Run the write step, then the read step to confirm the bytes landed '
        'in Dart\'s map after the block exited.',
    steps: [
      _Step(
        label: 'Write (with)',
        code:
            'with open("/data/ctx.txt", "w") as f: f.write("via context manager")',
      ),
      _Step(label: 'Read back', code: 'open("/data/ctx.txt").read()'),
    ],
  ),
  _Sample(
    num: 13,
    title: 'open(..., "a") — append preserves content',
    panel: 'vfs',
    desc:
        'Mode "a" maps to createIfMissing (never truncate), so existing bytes '
        'survive. Seed the file, then open it twice in append mode — each '
        'f.write() is an append_text OsCall onto Dart\'s map. The final read '
        'shows all three fragments concatenated in order.',
    steps: [
      _Step(
        label: 'Seed',
        code: 'pathlib.Path("/data/log.txt").write_text("line1\\n")',
      ),
      _Step(
        label: 'Append',
        code:
            'f = open("/data/log.txt", "a"); f.write("line2\\n"); '
            'f.write("line3\\n"); f.close(); open("/data/log.txt").read()',
      ),
    ],
  ),
  _Sample(
    num: 14,
    title: 'open() missing file → typed FileNotFoundError',
    panel: 'vfs',
    desc:
        'open() in read mode against a path Dart\'s map does not contain. '
        'resolveOpenCall raises an OsCallException tagged FileNotFoundError, '
        'which surfaces in Python as the real builtin exception and renders '
        'red below. This is the demo — the error is the point, so it is not '
        'wrapped in try/except (which would not fit on one line anyway).',
    steps: [_Step(label: '→ VFS', code: 'open("/data/missing.txt").read()')],
  ),
  _Sample(
    num: 15,
    title: 'OsCall breadth — exists / write / unlink',
    panel: 'vfs',
    desc:
        'Three distinct Path.* OsCalls chained on one line: probe a path, '
        'create it via write_text, probe again, then unlink it. Every boolean '
        'and the deletion crosses the boundary into Dart\'s map, so the dict '
        'captures the full lifecycle: gone → created → gone again.',
    steps: [
      _Step(
        label: '→ VFS',
        code:
            'p = pathlib.Path("/data/tmp.txt"); before = p.exists(); '
            'p.write_text("temp"); created = p.exists(); p.unlink(); '
            '{"before": before, "created": created, "after": p.exists()}',
      ),
    ],
  ),
];

void _initExamples() {
  final toggleBtn =
      web.document.getElementById('examples-toggle')! as web.HTMLButtonElement;
  final strip =
      web.document.getElementById('examples-strip')! as web.HTMLDivElement;

  for (final sample in _kSamples) {
    strip.appendChild(_buildSampleCard(sample));
  }

  var open = false;
  toggleBtn.onclick = (web.MouseEvent _) {
    open = !open;
    strip.style.display = open ? 'flex' : 'none';
    toggleBtn.textContent = open ? '✕ Hide' : '📖 Examples';
  }.toJS;
}

web.HTMLDivElement _buildSampleCard(_Sample sample) {
  final card = web.document.createElement('div') as web.HTMLDivElement
    ..className = 'sample-card';

  final panelLabel = switch (sample.panel) {
    'a' => 'REPL',
    'b' => 'Externals',
    _ => 'VFS',
  };

  final numEl = web.document.createElement('div') as web.HTMLDivElement
    ..className = 'sample-num'
    ..textContent = '${sample.num} of ${_kSamples.length} · $panelLabel';
  card.appendChild(numEl);

  final titleEl = web.document.createElement('div') as web.HTMLDivElement
    ..className = 'sample-title'
    ..textContent = sample.title;
  card.appendChild(titleEl);

  final descEl = web.document.createElement('div') as web.HTMLDivElement
    ..className = 'sample-desc'
    ..textContent = sample.desc;
  card.appendChild(descEl);

  for (final step in sample.steps) {
    final codeEl = web.document.createElement('pre') as web.HTMLPreElement
      ..className = 'sample-code'
      ..textContent = step.code;
    card.appendChild(codeEl);

    final actionsEl = web.document.createElement('div') as web.HTMLDivElement
      ..className = 'sample-actions';

    final btnClass = switch (sample.panel) {
      'b' => 'inject-btn ext',
      'vfs' => 'inject-btn vfs',
      _ => 'inject-btn',
    };
    final injectBtn =
        web.document.createElement('button') as web.HTMLButtonElement
          ..className = btnClass
          ..textContent = step.label;

    final code = step.code;
    final panel = sample.panel;
    injectBtn.onclick = (web.MouseEvent _) {
      final inputEl =
          web.document.getElementById('input-$panel')! as web.HTMLInputElement;
      inputEl.value = code;
      inputEl.focus();
    }.toJS;

    actionsEl.appendChild(injectBtn);
    card.appendChild(actionsEl);
  }

  return card;
}

// ---------------------------------------------------------------------------
// Value formatter — exhaustive over all 20 MontyValue subtypes
// ---------------------------------------------------------------------------
String _fmt(MontyValue v) => switch (v) {
  MontyNone() => 'None',
  MontyEllipsis() => 'Ellipsis',
  MontyBool(:final value) => value.toString(),
  MontyInt(:final value) => value.toString(),
  MontyFloat(:final value) =>
    value.isNaN
        ? 'nan'
        : value.isInfinite
        ? (value > 0 ? 'inf' : '-inf')
        : value.toString(),
  MontyString(:final value) => '"$value"',
  MontyBytes(:final value) => 'b[${value.length}]',
  // Show up to 20 items — enough for demo punchlines like
  // `[fib(i) for i in range(10)]` (Sample #3) without unbounded
  // rendering for pathological inputs like `range(1_000_000)`.
  MontyList(:final items) =>
    '[${items.take(20).map(_fmt).join(', ')}${items.length > 20 ? ', …(${items.length})' : ''}]',
  MontyTuple(:final items) => '(${items.map(_fmt).join(', ')})',
  MontyDict(:final entries) =>
    '{${entries.entries.take(20).map((e) => '"${e.key}": ${_fmt(e.value)}').join(', ')}${entries.length > 20 ? ', …' : ''}}',
  // A dict with non-string keys (wire v2's `entries` envelope). Rendered like
  // any other dict, with the KEYS formatted rather than stringified — the whole
  // point of the variant is that they are typed values, not labels.
  MontyPairsDict(:final pairs) =>
    '{${pairs.take(20).map((p) => '${_fmt(p.$1)}: ${_fmt(p.$2)}').join(', ')}${pairs.length > 20 ? ', …' : ''}}',
  // ---- Tier 2 variants (wire v3) ----------------------------------------
  // These five all used to arrive as MontyString, so the demo rendered them
  // without knowing what they were.
  MontyBigInt(:final value) => '$value',
  MontyExceptionValue(:final excType, :final message) =>
    message == null ? '$excType()' : '$excType($message)',
  MontyOpaque(:final text) => text,
  MontySet(:final items) => '{${items.map(_fmt).join(', ')}}',
  MontyFrozenSet(:final items) => 'frozenset({${items.map(_fmt).join(', ')}})',
  MontyDate(:final year, :final month, :final day) => '$year-$month-$day',
  MontyDateTime(
    :final year,
    :final month,
    :final day,
    :final hour,
    :final minute,
  ) =>
    '$year-$month-${day}T$hour:$minute',
  MontyTimeDelta(:final days, :final seconds) => '${days}d ${seconds}s',
  MontyTimeZone(:final offsetSeconds, :final name) =>
    name ?? '${offsetSeconds}s',
  MontyPath(:final value) => 'Path("$value")',
  MontyFileHandle(:final path, :final mode) => "<file '$path' mode '$mode'>",
  MontyNamedTuple(:final typeName, :final fieldNames, :final values) =>
    '$typeName(${List.generate(fieldNames.length, (i) => '${fieldNames[i]}=${_fmt(values[i])}').join(', ')})',
  MontyDataclass(:final name, :final attrs) =>
    '$name(${attrs.entries.map((e) => '${e.key}=${_fmt(e.value)}').join(', ')})',
};

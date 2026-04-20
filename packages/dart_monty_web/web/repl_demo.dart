// Web demo for dart_monty_core — three panels.
//
//  Panel A — MontyRepl (persistent heap, snapshot/restore, detectContinuation)
//    Exercises: MontyRepl.feed, externals, osHandler, detectContinuation,
//               snapshot, restore, all MontyValue types, MontyResult fields.
//
//  Panel B — Externals showcase (Python → Dart callbacks)
//    Exercises: MontySession.start/resume, MontyPending (functionName, args,
//               kwargs, callId), resumeWithError, MontyOsCall, MontyProgress.
//    Pre-registered Dart functions: db_query, compute, format_currency, now.
//    Each call is logged with its arguments and return value so the flow
//    is visible.
//
//  Panel VFS — Monty + osHandler (virtual filesystem, snapshot/restore)
//    Exercises: Monty(osHandler:), pathlib, OsCallException, snapshot,
//               restore, MontyPath value type.
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
      final result = await repl.feed(
        code,
        externals: {
          'host_upper': (args) async => (args['_0'] as String).toUpperCase(),
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

  // Snap button — append inline after run button.
  final snapBtn = web.document.createElement('button') as web.HTMLButtonElement
    ..textContent = '📸'
    ..className = 'btn-sm';
  final restoreBtn =
      web.document.createElement('button') as web.HTMLButtonElement
        ..textContent = '↩'
        ..className = 'btn-sm';
  runBtn.insertAdjacentElement('afterend', restoreBtn);
  runBtn.insertAdjacentElement('afterend', snapBtn);

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

  final session = MontySession();

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
    'db_query': (args) async {
      final table = args['_0'] as String;
      final filter = args['filter'];
      final rows = _mockDb[table] ?? [];
      if (filter == null || filter == 'None' || filter == false) return rows;
      return rows.where((r) => r['active'] == true).toList();
    },
    'compute': (args) async {
      final op = args['_0'] as String;
      final a = args['_1'] as num;
      final b = args['_2'] as num;
      return switch (op) {
        'add' => a + b,
        'mul' => a * b,
        'pow' => a.toDouble() * a.toDouble(), // simplified
        _ => throw Exception('unknown op: $op'),
      };
    },
    'format_currency': (args) async {
      final amount = args['_0'] as num;
      final code = (args['code'] as String?) ?? 'USD';
      return '$code ${amount.toStringAsFixed(2)}';
    },
    'now': (_) async => DateTime.now().toIso8601String(),
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
      var progress = await session.start(
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
            :final arguments,
            :final kwargs,
            :final callId,
          ):
            final argStr = [
              ...arguments.map((a) => _fmt(a)),
              if (kwargs != null)
                ...kwargs.entries.map((e) => '${e.key}=${_fmt(e.value)}'),
            ].join(', ');

            final cb = externals[functionName];
            if (cb == null) {
              write(
                '  ⚡ #$callId $functionName($argStr) → ERROR: no handler',
                className: 'error-line',
              );
              progress = await session.resumeWithError(
                'No handler: $functionName',
              );
            } else {
              try {
                final dartArgs = <String, Object?>{};
                if (kwargs != null) {
                  dartArgs.addAll(
                    kwargs.map((k, v) => MapEntry(k, v.dartValue)),
                  );
                }
                for (var i = 0; i < arguments.length; i++) {
                  dartArgs['_$i'] = arguments[i].dartValue;
                }
                final result = await cb(dartArgs);
                final resultStr = result is List
                    ? '[${(result as List).length} rows]'
                    : result.toString();
                write(
                  '  ⚡ #$callId $functionName($argStr) → $resultStr',
                  className: 'system-line',
                );
                progress = await session.resume(result);
              } on Object catch (e) {
                write(
                  '  ⚡ #$callId $functionName($argStr) → ERROR: $e',
                  className: 'error-line',
                );
                progress = await session.resumeWithError(e.toString());
              }
            }

          case MontyOsCall(:final operationName):
            progress = await session.resumeWithError(
              '$operationName not available in externals panel',
            );

          case MontyNameLookup(:final variableName):
            progress = await session.resumeWithError('$variableName not found');

          case MontyResolveFutures():
            progress = await session.resume(null);
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
// Panel VFS — Monty with osHandler, pathlib, snapshot/restore
// ---------------------------------------------------------------------------
void _initVfsPanel() {
  final output = _div('output-vfs');
  final input = _input('input-vfs');
  final runBtn = _button('run-vfs');
  final snapBtn = _button('snap-vfs');
  final restoreBtn = _button('restore-vfs');

  Uint8List? savedSnap;
  final monty = Monty(osHandler: _vfsOsHandler);

  void write(String text, {String? className}) =>
      _appendLine(output, text, className: className);

  output.innerHTML = ''.toJS;
  write(
    'VFS panel — Monty with osHandler. State persists across run() calls.',
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
      final result = await monty.run(code);

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
      final b = await monty.snapshot();
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
      await monty.restore(s);
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
// Examples palette — 10 samples from simple to sophisticated
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
    title: 'Typed values across FFI',
    panel: 'a',
    desc:
        'Every Python value crosses the FFI boundary as a typed MontyValue '
        'subtype — MontyInt, MontyFloat, MontyList, MontyDict, MontyBool, etc. '
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
    title: 'Multi-line block detection',
    panel: 'a',
    desc:
        'detectContinuation() returns incompleteBlock when the statement is '
        'not yet closed. Paste the full function — the REPL holds input until '
        'the de-indent completes the block.',
    steps: [
      _Step(
        label: '→ REPL',
        code:
            'def fib(n):\n'
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
        'Dart\'s handler runs, calls session.resume() with the result. '
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
        'Positional args arrive as _0, _1, … in MontyCallback\'s args map; '
        'kwargs appear by their Python name. format_currency(19.99, code="EUR") '
        'fires the callback with {_0: 19.99, code: "EUR"}.',
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
    ..textContent = '${sample.num} of 10 · $panelLabel';
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
// Value formatter — exhaustive over all 18 MontyValue subtypes
// ---------------------------------------------------------------------------
String _fmt(MontyValue v) => switch (v) {
  MontyNone() => 'None',
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
  MontyList(:final items) =>
    '[${items.take(3).map(_fmt).join(', ')}${items.length > 3 ? ', …(${items.length})' : ''}]',
  MontyTuple(:final items) => '(${items.map(_fmt).join(', ')})',
  MontyDict(:final entries) =>
    '{${entries.entries.take(3).map((e) => '"${e.key}": ${_fmt(e.value)}').join(', ')}${entries.length > 3 ? ', …' : ''}}',
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
  MontyNamedTuple(:final typeName, :final fieldNames, :final values) =>
    '$typeName(${List.generate(fieldNames.length, (i) => '${fieldNames[i]}=${_fmt(values[i])}').join(', ')})',
  MontyDataclass(:final name, :final attrs) =>
    '$name(${attrs.entries.map((e) => '${e.key}=${_fmt(e.value)}').join(', ')})',
};

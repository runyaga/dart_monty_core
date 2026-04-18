// Flutter demo for dart_monty_core — five tabs covering the full API.
//
//  Tab 1 — Monty.exec() one-shot
//    Exercises: Monty.exec, inputs, MontyLimits, MontyResourceUsage,
//               MontyValue exhaustive pattern matching.
//
//  Tab 2 — MontyRepl (persistent heap)
//    Exercises: MontyRepl.feed, externals, osHandler, detectContinuation,
//               snapshot, restore, feedStart/resume loop.
//
//  Tab 3 — Externals (MontySession + Dart callbacks)
//    Exercises: MontySession.run, MontyCallback, callback call-flow logging.
//    Registered: db_query, compute, format_currency, now.
//
//  Tab 4 — VFS / OsCall (Monty with osHandler)
//    Exercises: Monty(osHandler:), pathlib, OsCallException,
//               snapshot, restore, clearState, MontyPath value type.
//
//  Tab 5 — Session start/resume (manual MontyProgress dispatch)
//    Exercises: MontySession.start, MontyPending, MontyOsCall,
//               resumeWithError, MontyNameLookup, MontyResolveFutures.

import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// VFS shared across VFS tab
// ---------------------------------------------------------------------------
final Map<String, String> _vfs = {
  '/data/hello.txt': 'Hello from the virtual filesystem!',
  '/data/config.txt': 'version=1.0\nenv=demo',
};

Future<Object?> _osHandler(
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
    required this.tabIndex,
    required this.tabName,
    required this.desc,
    required this.steps,
  });
  final int num;
  final String title;
  final int tabIndex; // 1=REPL, 2=Externals, 3=VFS
  final String tabName;
  final String desc;
  final List<_Step> steps;
}

const _kSamples = <_Sample>[
  _Sample(
    num: 1,
    title: 'Typed values across FFI',
    tabIndex: 1,
    tabName: 'REPL',
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
    tabIndex: 1,
    tabName: 'REPL',
    desc:
        'Python state lives in the Rust heap between feed() calls — not '
        're-parsed, not serialised. Inject step 1, run it, then inject step 2: '
        'x is still there.',
    steps: [
      _Step(label: 'Step 1', code: 'x = [i**2 for i in range(1, 6)]'),
      _Step(label: 'Step 2', code: 'sum(x)  # x persists in the Rust heap'),
    ],
  ),
  _Sample(
    num: 3,
    title: 'Multi-line block detection',
    tabIndex: 1,
    tabName: 'REPL',
    desc:
        'detectContinuation() returns incompleteBlock when the statement is '
        'not yet closed. Paste the full function — the REPL waits for the '
        'de-indent before executing.',
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
    tabIndex: 1,
    tabName: 'REPL',
    desc:
        'snapshot() serialises the entire Rust heap to postcard bytes. Run '
        'step 1 (then 📸 Snap), mutate with step 2, then ↩ Restore — the heap '
        'rewinds exactly to the snapshot point.',
    steps: [
      _Step(label: 'Step 1 → snap', code: 'counter = 0; counter'),
      _Step(label: 'Step 2 → restore', code: 'counter += 1; counter'),
    ],
  ),
  _Sample(
    num: 5,
    title: 'Error taxonomy',
    tabIndex: 1,
    tabName: 'REPL',
    desc:
        'MontyError is sealed: MontySyntaxError is caught before execution '
        'starts; MontyScriptError wraps runtime exceptions with a Python '
        'traceback. Each step exercises a different subtype.',
    steps: [
      _Step(label: 'SyntaxError', code: 'def broken('),
      _Step(label: 'ZeroDivisionError', code: '1 / 0'),
      _Step(label: 'NameError', code: 'undefined_name'),
    ],
  ),
  _Sample(
    num: 6,
    title: 'Single callback — one suspension',
    tabIndex: 2,
    tabName: 'Externals',
    desc:
        'Calling compute() suspends Python execution and fires a MontyCallback '
        'in Dart. Dart handles the arithmetic and calls resume(). '
        'The ⚡ line logs each round-trip.',
    steps: [_Step(label: '→ Externals', code: 'compute("add", 19, 23)')],
  ),
  _Sample(
    num: 7,
    title: 'Nested calls — three suspensions',
    tabIndex: 2,
    tabName: 'Externals',
    desc:
        'One Python expression can trigger multiple MontyCallback firings. '
        'The two inner compute() calls suspend first, then the outer mul. '
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
    tabIndex: 2,
    tabName: 'Externals',
    desc:
        'Positional args arrive as _0, _1, … in MontyCallback\'s args map; '
        'kwargs appear by their Python name. format_currency(19.99, code="EUR") '
        'fires with {_0: 19.99, code: "EUR"}.',
    steps: [
      _Step(label: '→ Externals', code: 'format_currency(19.99, code="EUR")'),
    ],
  ),
  _Sample(
    num: 9,
    title: 'OsCall — pathlib interception',
    tabIndex: 3,
    tabName: 'VFS',
    desc:
        'pathlib.Path.read_text() becomes a MontyOsCall — Python suspends, '
        'Dart looks up the path in its in-memory map, resumes with the string. '
        'Import must run first; VFS state persists.',
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
    tabIndex: 3,
    tabName: 'VFS',
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

// ---------------------------------------------------------------------------
// Fake data for the Externals tab callbacks
// ---------------------------------------------------------------------------
const _dbTables = <String, List<Map<String, Object>>>{
  'users': [
    {'id': 1, 'name': 'Alice', 'role': 'admin'},
    {'id': 2, 'name': 'Bob', 'role': 'user'},
    {'id': 3, 'name': 'Carol', 'role': 'user'},
  ],
  'orders': [
    {'id': 101, 'item': 'Widget', 'qty': 3, 'price': 9.99},
    {'id': 102, 'item': 'Gadget', 'qty': 1, 'price': 49.99},
  ],
};

void main() => runApp(const MontyDemoApp());

class MontyDemoApp extends StatelessWidget {
  const MontyDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'dart_monty_core Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4EC9B0),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        fontFamily: 'monospace',
      ),
      home: const _DemoShell(),
    );
  }
}

// ---------------------------------------------------------------------------
// Shell with tabs
// ---------------------------------------------------------------------------
class _DemoShell extends StatefulWidget {
  const _DemoShell();

  @override
  State<_DemoShell> createState() => _DemoShellState();
}

class _DemoShellState extends State<_DemoShell>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _replA = MontyRepl();
  final _externalsSession = MontySession();
  late final Monty _vfsMonty;
  late final MontySession _manualSession;

  final _replKey = GlobalKey<_ReplPanelState>();
  final _externalsKey = GlobalKey<_ExternalsPanelState>();
  final _vfsKey = GlobalKey<_VfsPanelState>();

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 5, vsync: this);
    _vfsMonty = Monty(osHandler: _osHandler);
    _manualSession = MontySession(osHandler: _osHandler);
  }

  @override
  void dispose() {
    _tabs.dispose();
    _replA.dispose();
    _externalsSession.dispose();
    _vfsMonty.dispose();
    _manualSession.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('dart_monty_core'),
        actions: [
          IconButton(
            icon: const Icon(Icons.lightbulb_outline),
            tooltip: 'Examples',
            onPressed: () => _showSamples(context),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabs: const [
            Tab(text: 'exec()'),
            Tab(text: 'REPL'),
            Tab(text: 'Externals'),
            Tab(text: 'VFS'),
            Tab(text: 'Session'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _ExecPanel(),
          _ReplPanel(key: _replKey, repl: _replA),
          _ExternalsPanel(key: _externalsKey, session: _externalsSession),
          _VfsPanel(key: _vfsKey, monty: _vfsMonty),
          _SessionPanel(session: _manualSession),
        ],
      ),
    );
  }

  void _injectSample(int tabIndex, String code) {
    switch (tabIndex) {
      case 1:
        _replKey.currentState?.injectCode(code);
      case 2:
        _externalsKey.currentState?.injectCode(code);
      case 3:
        _vfsKey.currentState?.injectCode(code);
    }
    _tabs.animateTo(tabIndex);
  }

  void _showSamples(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFF1e1e1e),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.95,
        builder: (_, scrollCtrl) => ListView.builder(
          controller: scrollCtrl,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          itemCount: _kSamples.length + 1,
          itemBuilder: (_, i) {
            if (i == 0) {
              return const Padding(
                padding: EdgeInsets.fromLTRB(4, 4, 4, 10),
                child: Text(
                  '10 Examples  —  tap any snippet to inject it',
                  style: TextStyle(
                    color: Color(0xFF4ec9b0),
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              );
            }
            final sample = _kSamples[i - 1];
            return _SampleCard(
              sample: sample,
              onInject: (code) {
                Navigator.pop(ctx);
                _injectSample(sample.tabIndex, code);
              },
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared output types
// ---------------------------------------------------------------------------
class _OutputLine {
  _OutputLine(this.text, this.style);
  final String text;
  final _LineStyle style;
}

enum _LineStyle { system, input, output, print, error }

class _ReplOutput extends StatefulWidget {
  const _ReplOutput({required this.lines});
  final List<_OutputLine> lines;

  @override
  State<_ReplOutput> createState() => _ReplOutputState();
}

class _ReplOutputState extends State<_ReplOutput> {
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(_ReplOutput old) {
    super.didUpdateWidget(old);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: _scroll,
      itemCount: widget.lines.length,
      itemBuilder: (_, i) {
        final line = widget.lines[i];
        final color = switch (line.style) {
          _LineStyle.system => Colors.blueGrey,
          _LineStyle.input => Colors.white,
          _LineStyle.output => const Color(0xFF4EC9B0),
          _LineStyle.print => Colors.yellow,
          _LineStyle.error => Colors.red,
        };
        return Text(line.text, style: TextStyle(color: color, fontSize: 13));
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Tab 1 — Monty.exec() one-shot
// ---------------------------------------------------------------------------
class _ExecPanel extends StatefulWidget {
  @override
  State<_ExecPanel> createState() => _ExecPanelState();
}

class _ExecPanelState extends State<_ExecPanel> {
  final _lines = <_OutputLine>[];
  final _ctrl = TextEditingController();
  var _limitChoice = 'none';

  void _write(String text, _LineStyle style) =>
      setState(() => _lines.add(_OutputLine(text, style)));

  Future<void> _execute() async {
    final code = _ctrl.text.trim();
    if (code.isEmpty) return;
    _ctrl.clear();
    _write('>>> $code', _LineStyle.input);

    final limits = switch (_limitChoice) {
      '50ms' => MontyLimits(timeoutMs: 50),
      '200ms' => MontyLimits(timeoutMs: 200),
      'stack10' => MontyLimits(stackDepth: 10),
      _ => null,
    };

    try {
      final result = await Monty.exec(code, limits: limits);

      if (result.printOutput != null && result.printOutput!.isNotEmpty) {
        _write(result.printOutput!.trimRight(), _LineStyle.print);
      }

      if (result.error != null) {
        _write(
          '${result.error!.excType}: ${result.error!.message}',
          _LineStyle.error,
        );
      } else {
        _write('=> ${_fmtValue(result.value)}', _LineStyle.output);
        _write(
          '   ${result.usage.memoryBytesUsed}b  ${result.usage.timeElapsedMs}ms  stack:${result.usage.stackDepthUsed}',
          _LineStyle.system,
        );
      }
    } on MontyResourceError catch (e) {
      _write('ResourceError: ${e.message}', _LineStyle.error);
    } on MontyError catch (e) {
      _write('Error: $e', _LineStyle.error);
    }
  }

  @override
  void initState() {
    super.initState();
    _write('One-shot — no state persists between runs.', _LineStyle.system);
    _write(
      'Try: [i*i for i in range(5)]  {"key": [1,2,3]}  2**32',
      _LineStyle.system,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(child: _ReplOutput(lines: _lines)),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              DropdownButton<String>(
                value: _limitChoice,
                items: const [
                  DropdownMenuItem(value: 'none', child: Text('no limit')),
                  DropdownMenuItem(value: '50ms', child: Text('50ms')),
                  DropdownMenuItem(value: '200ms', child: Text('200ms')),
                  DropdownMenuItem(value: 'stack10', child: Text('stack:10')),
                ],
                onChanged: (v) => setState(() => _limitChoice = v!),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  decoration: const InputDecoration(
                    hintText: 'Python code…',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _execute(),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(onPressed: _execute, child: const Text('Run')),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Tab 2 — MontyRepl (persistent heap)
// ---------------------------------------------------------------------------
class _ReplPanel extends StatefulWidget {
  const _ReplPanel({super.key, required this.repl});
  final MontyRepl repl;

  @override
  State<_ReplPanel> createState() => _ReplPanelState();
}

class _ReplPanelState extends State<_ReplPanel> {
  final _lines = <_OutputLine>[];
  final _ctrl = TextEditingController();
  Uint8List? _snap;

  void injectCode(String code) => setState(() => _ctrl.text = code);

  void _write(String text, _LineStyle style) =>
      setState(() => _lines.add(_OutputLine(text, style)));

  Future<void> _execute() async {
    final code = _ctrl.text.trim();
    if (code.isEmpty) return;

    final mode = await widget.repl.detectContinuation(code);
    if (mode != ReplContinuationMode.complete) return;

    _ctrl.clear();
    _write('>>> $code', _LineStyle.input);

    try {
      final result = await widget.repl.feed(
        code,
        externals: {
          'host_upper': (args) async => (args['_0'] as String).toUpperCase(),
        },
        osHandler: _osHandler,
      );

      if (result.printOutput != null && result.printOutput!.isNotEmpty) {
        _write(result.printOutput!.trimRight(), _LineStyle.print);
      }
      if (result.error != null) {
        _write(
          '${result.error!.excType}: ${result.error!.message}',
          _LineStyle.error,
        );
      } else if (result.value is! MontyNone) {
        _write('=> ${_fmtValue(result.value)}', _LineStyle.output);
      }
    } on MontyError catch (e) {
      _write('Error: $e', _LineStyle.error);
    }
  }

  @override
  void initState() {
    super.initState();
    _write('Persistent heap — state survives between runs.', _LineStyle.system);
    _write(
      'host_upper("hello") calls into Dart from Python.',
      _LineStyle.system,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(child: _ReplOutput(lines: _lines)),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            children: [
              Row(
                children: [
                  ElevatedButton(
                    onPressed: () async {
                      try {
                        final b = await widget.repl.snapshot();
                        setState(() => _snap = b);
                        _write('📸 Snapshot (${b.length}b)', _LineStyle.system);
                      } on Object catch (e) {
                        _write('Snapshot error: $e', _LineStyle.error);
                      }
                    },
                    child: const Text('📸 Snap'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () async {
                      final s = _snap;
                      if (s == null) {
                        _write('No snapshot.', _LineStyle.system);
                        return;
                      }
                      try {
                        await widget.repl.restore(s);
                        _write('↩ Restored.', _LineStyle.system);
                      } on Object catch (e) {
                        _write('Restore error: $e', _LineStyle.error);
                      }
                    },
                    child: const Text('↩ Restore'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      decoration: const InputDecoration(
                        hintText: 'Python code…',
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _execute(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(onPressed: _execute, child: const Text('Run')),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Tab 3 — Externals (MontySession.run + Dart callbacks)
// ---------------------------------------------------------------------------
class _ExternalsPanel extends StatefulWidget {
  const _ExternalsPanel({super.key, required this.session});
  final MontySession session;

  @override
  State<_ExternalsPanel> createState() => _ExternalsPanelState();
}

class _ExternalsPanelState extends State<_ExternalsPanel> {
  final _lines = <_OutputLine>[];
  final _ctrl = TextEditingController();
  int _callNum = 0;

  void injectCode(String code) => setState(() => _ctrl.text = code);

  void _write(String text, _LineStyle style) =>
      setState(() => _lines.add(_OutputLine(text, style)));

  // Format positional args from the callback args map (_0, _1, …).
  String _fmtCallArgs(Map<String, Object?> args) {
    final parts = <String>[];
    for (var i = 0; args.containsKey('_$i'); i++) {
      final v = args['_$i'];
      parts.add(v is String ? '"$v"' : '$v');
    }
    return parts.join(', ');
  }

  Future<Object?> _loggedCall(
    String name,
    Map<String, Object?> args,
    Object? result,
  ) {
    final n = ++_callNum;
    final argStr = _fmtCallArgs(args);
    final resultStr = result is List ? '${result.length} rows' : '$result';
    _write('  ⚡ #$n $name($argStr) → $resultStr', _LineStyle.system);
    return Future.value(result);
  }

  Future<void> _execute() async {
    final code = _ctrl.text.trim();
    if (code.isEmpty) return;
    _ctrl.clear();
    _write('>>> $code', _LineStyle.input);

    try {
      final result = await widget.session.run(
        code,
        externals: {
          'db_query': (args) async {
            final table = (args['_0'] as String?) ?? 'users';
            final rows = _dbTables[table] ?? [];
            return _loggedCall('db_query', args, rows);
          },
          'compute': (args) async {
            final op = args['_0'] as String;
            final a = (args['_1'] as num).toDouble();
            final b = (args['_2'] as num).toDouble();
            final val = switch (op) {
              'add' => a + b,
              'mul' => a * b,
              'sub' => a - b,
              _ => b != 0 ? a / b : double.nan,
            };
            return _loggedCall('compute', args, val);
          },
          'format_currency': (args) async {
            final amount = (args['_0'] as num).toDouble();
            final currency = (args['code'] as String?) ?? 'USD';
            final str = switch (currency) {
              'EUR' => '€${amount.toStringAsFixed(2)}',
              'GBP' => '£${amount.toStringAsFixed(2)}',
              _ => '\$${amount.toStringAsFixed(2)}',
            };
            return _loggedCall('format_currency', args, str);
          },
          'now': (args) async {
            return _loggedCall('now', args, DateTime.now().toIso8601String());
          },
        },
      );

      if (result.printOutput != null && result.printOutput!.isNotEmpty) {
        _write(result.printOutput!.trimRight(), _LineStyle.print);
      }
      if (result.error != null) {
        _write(
          '${result.error!.excType}: ${result.error!.message}',
          _LineStyle.error,
        );
      } else if (result.value is! MontyNone) {
        _write('=> ${_fmtValue(result.value)}', _LineStyle.output);
      }
    } on MontyError catch (e) {
      _write('Error: $e', _LineStyle.error);
    }
  }

  @override
  void initState() {
    super.initState();
    _write(
      'Python calls Dart — each ⚡ line is a round-trip callback.',
      _LineStyle.system,
    );
    _write('db_query("users")       db_query("orders")', _LineStyle.system);
    _write('compute("add", 3, 4)    compute("mul", 6, 7)', _LineStyle.system);
    _write(
      'format_currency(19.99)  format_currency(9.50, code="EUR")',
      _LineStyle.system,
    );
    _write('now()', _LineStyle.system);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(child: _ReplOutput(lines: _lines)),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  decoration: const InputDecoration(
                    hintText: 'result = db_query("users")',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _execute(),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(onPressed: _execute, child: const Text('Run')),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Tab 4 — VFS / OsCall
// ---------------------------------------------------------------------------
class _VfsPanel extends StatefulWidget {
  const _VfsPanel({super.key, required this.monty});
  final Monty monty;

  @override
  State<_VfsPanel> createState() => _VfsPanelState();
}

class _VfsPanelState extends State<_VfsPanel> {
  final _lines = <_OutputLine>[];
  final _ctrl = TextEditingController();
  Uint8List? _snap;

  void injectCode(String code) => setState(() => _ctrl.text = code);

  void _write(String text, _LineStyle style) =>
      setState(() => _lines.add(_OutputLine(text, style)));

  Future<void> _execute() async {
    final code = _ctrl.text.trim();
    if (code.isEmpty) return;
    _ctrl.clear();
    _write('>>> $code', _LineStyle.input);

    try {
      final result = await widget.monty.run(code);
      if (result.printOutput != null && result.printOutput!.isNotEmpty) {
        _write(result.printOutput!.trimRight(), _LineStyle.print);
      }
      if (result.error != null) {
        _write(
          '${result.error!.excType}: ${result.error!.message}',
          _LineStyle.error,
        );
      } else if (result.value is! MontyNone) {
        _write('=> ${_fmtValue(result.value)}', _LineStyle.output);
      }
    } on MontyError catch (e) {
      _write('Error: $e', _LineStyle.error);
    }
  }

  @override
  void initState() {
    super.initState();
    _write('VFS — import pathlib then access /data/ files.', _LineStyle.system);
    _write('Files: ${_vfs.keys.join(", ")}', _LineStyle.system);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(child: _ReplOutput(lines: _lines)),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            children: [
              Row(
                children: [
                  ElevatedButton(
                    onPressed: () async {
                      final b = await widget.monty.snapshot();
                      setState(() => _snap = b);
                      _write('📸 Snapshot (${b.length}b)', _LineStyle.system);
                    },
                    child: const Text('📸 Snap'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () async {
                      final s = _snap;
                      if (s == null) return;
                      await widget.monty.restore(s);
                      _write('↩ Restored.', _LineStyle.system);
                    },
                    child: const Text('↩ Restore'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () {
                      widget.monty.clearState();
                      _write('🗑 Cleared.', _LineStyle.system);
                    },
                    child: const Text('🗑 Clear'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      decoration: const InputDecoration(
                        hintText: 'import pathlib',
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _execute(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(onPressed: _execute, child: const Text('Run')),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Tab 5 — MontySession start/resume (manual MontyProgress dispatch)
// ---------------------------------------------------------------------------
class _SessionPanel extends StatefulWidget {
  const _SessionPanel({required this.session});
  final MontySession session;

  @override
  State<_SessionPanel> createState() => _SessionPanelState();
}

class _SessionPanelState extends State<_SessionPanel> {
  final _lines = <_OutputLine>[];
  final _ctrl = TextEditingController();

  void _write(String text, _LineStyle style) =>
      setState(() => _lines.add(_OutputLine(text, style)));

  Future<void> _execute() async {
    final code = _ctrl.text.trim();
    if (code.isEmpty) return;
    _ctrl.clear();
    _write('>>> $code', _LineStyle.input);

    try {
      var progress = await widget.session.start(
        code,
        externalFunctions: ['compute'],
      );

      while (true) {
        switch (progress) {
          case MontyComplete(:final result):
            if (result.printOutput != null && result.printOutput!.isNotEmpty) {
              _write(result.printOutput!.trimRight(), _LineStyle.print);
            }
            if (result.error != null) {
              _write(
                '${result.error!.excType}: ${result.error!.message}',
                _LineStyle.error,
              );
            } else if (result.value is! MontyNone) {
              _write('=> ${_fmtValue(result.value)}', _LineStyle.output);
            }
            return;

          case MontyPending(
            :final functionName,
            :final arguments,
            :final callId,
          ):
            _write(
              '  ⚡ $functionName(${arguments.map((a) => a.dartValue).join(", ")}) [#$callId]',
              _LineStyle.system,
            );
            if (functionName == 'compute') {
              final n = arguments.first.dartValue as int;
              progress = await widget.session.resume(n * 2);
            } else {
              progress = await widget.session.resumeWithError(
                'Unknown: $functionName',
              );
            }

          case MontyOsCall(:final operationName):
            _write('  🗂 $operationName', _LineStyle.system);
            progress = await widget.session.resume(null);

          case MontyNameLookup(:final variableName):
            _write('  🔍 $variableName → undefined', _LineStyle.system);
            progress = await widget.session.resumeWithError(
              '$variableName not defined',
            );

          case MontyResolveFutures(:final pendingCallIds):
            _write(
              '  ⏳ resolve ${pendingCallIds.length} futures',
              _LineStyle.system,
            );
            progress = await widget.session.resume(null);
        }
      }
    } on MontyError catch (e) {
      _write('Error: $e', _LineStyle.error);
    }
  }

  @override
  void initState() {
    super.initState();
    _write(
      'Manual start/resume loop — raw MontyProgress dispatch.',
      _LineStyle.system,
    );
    _write('  result = compute(5) + compute(10)', _LineStyle.system);
    _write(
      '  (compute doubles the argument via Dart callback)',
      _LineStyle.system,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(child: _ReplOutput(lines: _lines)),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  decoration: const InputDecoration(
                    hintText: 'result = compute(5) + compute(10)',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _execute(),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(onPressed: _execute, child: const Text('Run')),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Sample card widget for the examples bottom sheet
// ---------------------------------------------------------------------------
class _SampleCard extends StatelessWidget {
  const _SampleCard({required this.sample, required this.onInject});
  final _Sample sample;
  final void Function(String code) onInject;

  @override
  Widget build(BuildContext context) {
    final accent = switch (sample.tabIndex) {
      2 => const Color(0xFF7a3f9c),
      3 => const Color(0xFF3a7a3a),
      _ => const Color(0xFF0e639c),
    };

    return Card(
      color: const Color(0xFF1a1a1a),
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: accent.withAlpha(100)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '${sample.num} of 10 · ${sample.tabName}',
                  style: const TextStyle(
                    color: Color(0xFF6a9955),
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              sample.title,
              style: TextStyle(
                color: accent,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              sample.desc,
              style: const TextStyle(
                color: Color(0xFF999999),
                fontSize: 12,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 8),
            ...sample.steps.map(
              (step) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF111111),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        step.code,
                        style: const TextStyle(
                          color: Color(0xFF9cdcfe),
                          fontFamily: 'monospace',
                          fontSize: 11,
                          height: 1.4,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    TextButton(
                      style: TextButton.styleFrom(
                        backgroundColor: accent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      onPressed: () => onInject(step.code),
                      child: Text(
                        step.label,
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Value formatter — exhaustive over all 18 MontyValue subtypes
// ---------------------------------------------------------------------------
String _fmtValue(MontyValue v) => switch (v) {
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
  MontyList(:final items) => '[${items.map(_fmtValue).join(', ')}]',
  MontyTuple(:final items) => '(${items.map(_fmtValue).join(', ')})',
  MontyDict(:final entries) =>
    '{${entries.entries.map((e) => '"${e.key}": ${_fmtValue(e.value)}').join(', ')}}',
  MontySet(:final items) => '{${items.map(_fmtValue).join(', ')}}',
  MontyFrozenSet(:final items) =>
    'frozenset({${items.map(_fmtValue).join(', ')}})',
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
    '$typeName(${List.generate(fieldNames.length, (i) => "${fieldNames[i]}=${_fmtValue(values[i])}").join(", ")})',
  MontyDataclass(:final name, :final attrs) =>
    '$name(${attrs.entries.map((e) => "${e.key}=${_fmtValue(e.value)}").join(", ")})',
};

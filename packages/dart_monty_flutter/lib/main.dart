// Flutter demo for dart_monty_core — five tabs covering the full API.
//
//  Tab 1 — Monty.exec() one-shot
//    Exercises: Monty.exec, inputs, MontyLimits, MontyResourceUsage,
//               MontyValue exhaustive pattern matching.
//
//  Tab 2 — MontyRepl A (persistent heap)
//    Exercises: MontyRepl.feed, externals, osHandler, detectContinuation,
//               snapshot, restore, feedStart/resume loop.
//
//  Tab 3 — MontyRepl B (independent heap — isolation demo)
//    Same as A, but a completely separate Rust handle.
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
  final _replB = MontyRepl();
  late final Monty _vfsMonty;
  late final MontySession _session;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 5, vsync: this);
    _vfsMonty = Monty(osHandler: _osHandler);
    _session = MontySession(osHandler: _osHandler);
  }

  @override
  void dispose() {
    _tabs.dispose();
    _replA.dispose();
    _replB.dispose();
    _vfsMonty.dispose();
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('dart_monty_core'),
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabs: const [
            Tab(text: 'exec()'),
            Tab(text: 'REPL A'),
            Tab(text: 'REPL B'),
            Tab(text: 'VFS'),
            Tab(text: 'Session'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _ExecPanel(),
          _ReplPanel(label: 'A', repl: _replA, otherLabel: 'B'),
          _ReplPanel(label: 'B', repl: _replB, otherLabel: 'A'),
          _VfsPanel(monty: _vfsMonty),
          _SessionPanel(session: _session),
        ],
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
        _write('${result.error!.excType}: ${result.error!.message}', _LineStyle.error);
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
    _write('Try: [i*i for i in range(5)]  {"key": [1,2,3]}  2**32', _LineStyle.system);
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
// Tabs 2 & 3 — MontyRepl (A or B)
// ---------------------------------------------------------------------------
class _ReplPanel extends StatefulWidget {
  const _ReplPanel({
    required this.label,
    required this.repl,
    required this.otherLabel,
  });
  final String label;
  final MontyRepl repl;
  final String otherLabel;

  @override
  State<_ReplPanel> createState() => _ReplPanelState();
}

class _ReplPanelState extends State<_ReplPanel> {
  final _lines = <_OutputLine>[];
  final _ctrl = TextEditingController();
  Uint8List? _snap;

  void _write(String text, _LineStyle style) =>
      setState(() => _lines.add(_OutputLine(text, style)));

  Future<void> _execute() async {
    final code = _ctrl.text.trim();
    if (code.isEmpty) return;

    // detectContinuation: drive REPL prompt logic.
    final mode = await widget.repl.detectContinuation(code);
    if (mode != ReplContinuationMode.complete) return;

    _ctrl.clear();
    _write('>>> $code', _LineStyle.input);

    try {
      // feed() auto-dispatches externals + osHandler.
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
        _write('${result.error!.excType}: ${result.error!.message}', _LineStyle.error);
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
      'Session ${widget.label} — heap is isolated from ${widget.otherLabel}.',
      _LineStyle.system,
    );
    _write('host_upper("hello") calls Dart from Python.', _LineStyle.system);
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
                      if (s == null) { _write('No snapshot.', _LineStyle.system); return; }
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
// Tab 4 — VFS / OsCall
// ---------------------------------------------------------------------------
class _VfsPanel extends StatefulWidget {
  const _VfsPanel({required this.monty});
  final Monty monty;

  @override
  State<_VfsPanel> createState() => _VfsPanelState();
}

class _VfsPanelState extends State<_VfsPanel> {
  final _lines = <_OutputLine>[];
  final _ctrl = TextEditingController();
  Uint8List? _snap;

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
        _write('${result.error!.excType}: ${result.error!.message}', _LineStyle.error);
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
      // Start iterative execution. Registers 'compute' as an external.
      var progress = await widget.session.start(
        code,
        externalFunctions: ['compute'],
      );

      // Exhaustive dispatch over all 5 MontyProgress subtypes.
      while (true) {
        switch (progress) {
          case MontyComplete(:final result):
            if (result.printOutput != null && result.printOutput!.isNotEmpty) {
              _write(result.printOutput!.trimRight(), _LineStyle.print);
            }
            if (result.error != null) {
              _write('${result.error!.excType}: ${result.error!.message}', _LineStyle.error);
            } else if (result.value is! MontyNone) {
              _write('=> ${_fmtValue(result.value)}', _LineStyle.output);
            }
            return;

          case MontyPending(:final functionName, :final arguments, :final callId):
            _write(
              '  ⚡ $functionName(${arguments.map((a) => a.dartValue).join(", ")}) [#$callId]',
              _LineStyle.system,
            );
            if (functionName == 'compute') {
              final n = arguments.first.dartValue as int;
              progress = await widget.session.resume(n * 2);
            } else {
              progress = await widget.session.resumeWithError('Unknown: $functionName');
            }

          case MontyOsCall(:final operationName):
            _write('  🗂 $operationName', _LineStyle.system);
            progress = await widget.session.resume(null);

          case MontyNameLookup(:final variableName):
            _write('  🔍 $variableName → undefined', _LineStyle.system);
            progress = await widget.session.resumeWithError('$variableName not defined');

          case MontyResolveFutures(:final pendingCallIds):
            _write('  ⏳ resolve ${pendingCallIds.length} futures', _LineStyle.system);
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
    _write('Manual start/resume loop. Try:', _LineStyle.system);
    _write('  result = compute(5) + compute(10)', _LineStyle.system);
    _write('  (compute doubles the argument via Dart callback)', _LineStyle.system);
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
// Value formatter — exhaustive over all 18 MontyValue subtypes
// ---------------------------------------------------------------------------
String _fmtValue(MontyValue v) => switch (v) {
  MontyNone() => 'None',
  MontyBool(:final value) => value.toString(),
  MontyInt(:final value) => value.toString(),
  MontyFloat(:final value) =>
    value.isNaN ? 'nan' : value.isInfinite ? (value > 0 ? 'inf' : '-inf') : value.toString(),
  MontyString(:final value) => '"$value"',
  MontyBytes(:final value) => 'b[${value.length}]',
  MontyList(:final items) => '[${items.map(_fmtValue).join(', ')}]',
  MontyTuple(:final items) => '(${items.map(_fmtValue).join(', ')})',
  MontyDict(:final entries) =>
    '{${entries.entries.map((e) => '"${e.key}": ${_fmtValue(e.value)}').join(', ')}}',
  MontySet(:final items) => '{${items.map(_fmtValue).join(', ')}}',
  MontyFrozenSet(:final items) => 'frozenset({${items.map(_fmtValue).join(', ')}})',
  MontyDate(:final year, :final month, :final day) => '$year-$month-$day',
  MontyDateTime(:final year, :final month, :final day, :final hour, :final minute) =>
    '$year-$month-${day}T$hour:$minute',
  MontyTimeDelta(:final days, :final seconds) => '${days}d ${seconds}s',
  MontyTimeZone(:final offsetSeconds, :final name) => name ?? '${offsetSeconds}s',
  MontyPath(:final value) => 'Path("$value")',
  MontyNamedTuple(:final typeName, :final fieldNames, :final values) =>
    '$typeName(${List.generate(fieldNames.length, (i) => "${fieldNames[i]}=${_fmtValue(values[i])}").join(", ")})',
  MontyDataclass(:final name, :final attrs) =>
    '$name(${attrs.entries.map((e) => "${e.key}=${_fmtValue(e.value)}").join(", ")})',
};

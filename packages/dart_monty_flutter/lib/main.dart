// Flutter demo for dart_monty_core.
//
// Three tabs demonstrate the core features:
//
//  Session A / Session B — two independent MontyRepl instances.
//    Each is assigned a unique replId internally so their Rust heap handles
//    are stored separately in the WASM Worker's replHandles Map. Variables
//    in A are invisible in B and vice versa.
//    Tip: set x = 10 in Session A, then evaluate x in Session B — B won't see it.
//
//  VFS / OsCall — a Monty() session (REPL-backed) with an in-memory
//    filesystem wired to the osHandler. `import pathlib` on one call
//    persists to the next — the Rust REPL heap stays alive between run()
//    calls. Also demonstrates snapshot / restore (📸 / ↩).
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// In-memory VFS
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
// App
// ---------------------------------------------------------------------------
void main() => runApp(const MontyDemoApp());

class MontyDemoApp extends StatelessWidget {
  const MontyDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Monty Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4EC9B0),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        fontFamily: 'monospace',
      ),
      home: const MontyDemoPage(),
    );
  }
}

class MontyDemoPage extends StatefulWidget {
  const MontyDemoPage({super.key});

  @override
  State<MontyDemoPage> createState() => _MontyDemoPageState();
}

class _MontyDemoPageState extends State<MontyDemoPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  // Two independent REPL sessions.
  final MontyRepl _replA = MontyRepl();
  final MontyRepl _replB = MontyRepl();

  // VFS session with osHandler.
  late final Monty _vfsMonty;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _vfsMonty = Monty(osHandler: _osHandler);
  }

  @override
  void dispose() {
    _replA.dispose();
    _replB.dispose();
    _vfsMonty.dispose();
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF333333),
        title: const Text(
          'Monty Demo',
          style: TextStyle(color: Color(0xFF4EC9B0), fontWeight: FontWeight.bold),
        ),
        bottom: TabBar(
          controller: _tabs,
          labelColor: const Color(0xFF4EC9B0),
          unselectedLabelColor: Colors.grey,
          indicatorColor: const Color(0xFF4EC9B0),
          tabs: const [
            Tab(text: 'Session A'),
            Tab(text: 'Session B'),
            Tab(text: 'VFS / OsCall'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _ReplPanel(label: 'A', repl: _replA),
          _ReplPanel(label: 'B', repl: _replB),
          _VfsPanel(monty: _vfsMonty),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// REPL panel widget (MontyRepl — concurrent session isolation demo)
// ---------------------------------------------------------------------------
class _ReplPanel extends StatefulWidget {
  const _ReplPanel({required this.label, required this.repl});

  final String label;
  final MontyRepl repl;

  @override
  State<_ReplPanel> createState() => _ReplPanelState();
}

class _ReplPanelState extends State<_ReplPanel> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  final List<_ReplLine> _lines = [];

  @override
  void initState() {
    super.initState();
    _lines.add(_ReplLine(
      'Session ${widget.label} — Monty REPL ready.',
      _LineKind.system,
    ));
    _lines.add(const _ReplLine(
      'Tip: set x = 10 here, then evaluate x in the other session.',
      _LineKind.system,
    ));
  }

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _execute() async {
    final code = _controller.text.trim();
    if (code.isEmpty) return;
    _controller.clear();
    setState(() => _lines.add(_ReplLine('>>> $code', _LineKind.input)));

    try {
      final result = await widget.repl.feed(code);
      setState(() {
        if (result.printOutput?.isNotEmpty ?? false) {
          _lines.add(_ReplLine(result.printOutput!, _LineKind.print));
        }
        if (result.error != null) {
          _lines.add(_ReplLine(result.error!.message, _LineKind.error));
        } else if (result.value is! MontyNone) {
          _lines.add(_ReplLine('=> ${result.value}', _LineKind.output));
        }
      });
    } on Object catch (e) {
      setState(() => _lines.add(_ReplLine('Error: $e', _LineKind.error)));
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
      _focus.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.all(12),
            itemCount: _lines.length,
            itemBuilder: (_, i) => Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                _lines[i].text,
                style: TextStyle(
                  color: _lines[i].kind.color,
                  fontFamily: 'monospace',
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ),
          ),
        ),
        Container(
          color: const Color(0xFF252526),
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  focusNode: _focus,
                  autofocus: true,
                  style: const TextStyle(
                    color: Color(0xFFCCCCCC), fontFamily: 'monospace', fontSize: 13,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Python code…',
                    hintStyle: const TextStyle(color: Color(0xFF666666)),
                    filled: true,
                    fillColor: const Color(0xFF3C3C3C),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4),
                      borderSide: const BorderSide(color: Color(0xFF555555)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4),
                      borderSide: const BorderSide(color: Color(0xFF555555)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4),
                      borderSide: const BorderSide(color: Color(0xFF007ACC)),
                    ),
                  ),
                  onSubmitted: (_) => _execute(),
                ),
              ),
              const SizedBox(width: 6),
              _DemoButton(label: 'Run', onPressed: _execute),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// VFS panel widget (Monty + osHandler + snapshot/restore)
// ---------------------------------------------------------------------------
class _VfsPanel extends StatefulWidget {
  const _VfsPanel({required this.monty});
  final Monty monty;

  @override
  State<_VfsPanel> createState() => _VfsPanelState();
}

class _VfsPanelState extends State<_VfsPanel> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  Uint8List? _savedSnapshot;
  final List<_ReplLine> _lines = [
    const _ReplLine(
      'VFS session — try: import pathlib  then: pathlib.Path("/data/hello.txt").read_text()',
      _LineKind.system,
    ),
    _ReplLine('Files: ${_vfs.keys.join(", ")}', _LineKind.system),
  ];

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _execute() async {
    final code = _controller.text.trim();
    if (code.isEmpty) return;
    _controller.clear();
    setState(() => _lines.add(_ReplLine('>>> $code', _LineKind.input)));

    try {
      final result = await widget.monty.run(code);
      setState(() {
        if (result.printOutput?.isNotEmpty ?? false) {
          _lines.add(_ReplLine(result.printOutput!, _LineKind.print));
        }
        if (result.error != null) {
          _lines.add(_ReplLine(result.error!.message, _LineKind.error));
        } else if (result.value is! MontyNone) {
          _lines.add(_ReplLine('=> ${result.value}', _LineKind.output));
        }
      });
    } on Object catch (e) {
      setState(() => _lines.add(_ReplLine('Error: $e', _LineKind.error)));
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
      _focus.requestFocus();
    });
  }

  Future<void> _snapshot() async {
    try {
      final bytes = await widget.monty.snapshot();
      setState(() {
        _savedSnapshot = bytes;
        _lines.add(_ReplLine(
          '📸 Snapshot saved (${bytes.length} bytes). Modify state then tap ↩.',
          _LineKind.system,
        ));
      });
    } on Object catch (e) {
      setState(() => _lines.add(_ReplLine('Snapshot error: $e', _LineKind.error)));
    }
  }

  void _restore() {
    final saved = _savedSnapshot;
    if (saved == null) {
      setState(() => _lines.add(
        const _ReplLine('No snapshot — tap 📸 first.', _LineKind.system),
      ));
      return;
    }
    try {
      widget.monty.restore(saved);
      setState(() => _lines.add(
        const _ReplLine('✅ State restored from snapshot.', _LineKind.system),
      ));
    } on Object catch (e) {
      setState(() => _lines.add(_ReplLine('Restore error: $e', _LineKind.error)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.all(12),
            itemCount: _lines.length,
            itemBuilder: (_, i) => Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                _lines[i].text,
                style: TextStyle(
                  color: _lines[i].kind.color,
                  fontFamily: 'monospace',
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ),
          ),
        ),
        Container(
          color: const Color(0xFF252526),
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  focusNode: _focus,
                  autofocus: false,
                  style: const TextStyle(
                    color: Color(0xFFCCCCCC), fontFamily: 'monospace', fontSize: 13,
                  ),
                  decoration: InputDecoration(
                    hintText:
                        'import pathlib; pathlib.Path("/data/hello.txt").read_text()',
                    hintStyle: const TextStyle(color: Color(0xFF666666)),
                    filled: true,
                    fillColor: const Color(0xFF3C3C3C),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4),
                      borderSide: const BorderSide(color: Color(0xFF555555)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4),
                      borderSide: const BorderSide(color: Color(0xFF555555)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4),
                      borderSide: const BorderSide(color: Color(0xFF4EC9B0)),
                    ),
                  ),
                  onSubmitted: (_) => _execute(),
                ),
              ),
              const SizedBox(width: 6),
              _DemoButton(label: 'Run', onPressed: _execute),
              const SizedBox(width: 4),
              _DemoButton(label: '📸', onPressed: _snapshot, small: true),
              const SizedBox(width: 4),
              _DemoButton(label: '↩', onPressed: _restore, small: true),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------
class _DemoButton extends StatelessWidget {
  const _DemoButton({
    required this.label,
    required this.onPressed,
    this.small = false,
  });
  final String label;
  final VoidCallback onPressed;
  final bool small;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: small ? const Color(0xFF3C3C3C) : const Color(0xFF0E639C),
        foregroundColor: Colors.white,
        padding: small
            ? const EdgeInsets.symmetric(horizontal: 10, vertical: 8)
            : const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        elevation: 0,
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: small ? 12 : 13,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

enum _LineKind { input, output, print, error, system }

extension on _LineKind {
  Color get color => switch (this) {
    _LineKind.input  => const Color(0xFF9CDCFE),
    _LineKind.output => const Color(0xFFDCDCAA),
    _LineKind.print  => const Color(0xFFB5CEA8),
    _LineKind.error  => const Color(0xFFF44747),
    _LineKind.system => const Color(0xFF6A9955),
  };
}

class _ReplLine {
  const _ReplLine(this.text, this.kind);
  final String text;
  final _LineKind kind;
}

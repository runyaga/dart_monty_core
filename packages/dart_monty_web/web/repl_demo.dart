// Interactive demo for dart_monty_core.
//
// Three panels — all features work under both dart2js and dart2wasm:
//
//  Session A / B  — two independent MontyRepl instances.
//    Each is assigned a unique replId internally (WasmReplBindings static
//    counter) so their Rust heap handles are stored separately in the WASM
//    Worker's replHandles Map. Variables in A are invisible in B.
//    Tip: set x = 10 in A, then evaluate x in B — B won't see it.
//
//  VFS / OsCall   — a Monty() session with an in-memory virtual filesystem
//    wired to the osHandler. Python's pathlib.Path reads and writes go
//    through the Dart handler instead of the real filesystem.
//    Also demonstrates snapshot / restore — click 📸 to capture state
//    and ↩ to restore it.
import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:web/web.dart' as web;

// ---------------------------------------------------------------------------
// In-memory VFS shared for the VFS panel.
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

web.HTMLDivElement _div(String id) {
  final el = web.document.getElementById(id);
  if (el == null) throw StateError('#$id not found');
  return el as web.HTMLDivElement;
}

web.HTMLInputElement _input(String id) {
  final el = web.document.getElementById(id);
  if (el == null) throw StateError('#$id not found');
  return el as web.HTMLInputElement;
}

web.HTMLButtonElement _button(String id) {
  final el = web.document.getElementById(id);
  if (el == null) throw StateError('#$id not found');
  return el as web.HTMLButtonElement;
}

void main() {
  // Two independent MontyRepl instances — demonstrates the multi-REPL fix.
  // WasmReplBindings assigns each a unique replId so their Rust handles are
  // stored independently in the Worker's replHandles Map.
  _initReplPanel('a', 'A', MontyRepl());
  _initReplPanel('b', 'B', MontyRepl());

  // VFS panel: Monty session with osHandler + snapshot capability.
  _initVfsPanel();
}

// ---------------------------------------------------------------------------
// REPL panel (Session A or B)
// ---------------------------------------------------------------------------
void _initReplPanel(String panelId, String label, MontyRepl repl) {
  final output = _div('output-$panelId');
  final input = _input('input-$panelId');
  final runBtn = _button('run-$panelId');

  void write(String text, {String? className}) {
    final div = web.document.createElement('div') as web.HTMLDivElement
      ..textContent = text;
    if (className != null) div.className = className;
    output
      ..appendChild(div)
      ..scrollTop = output.scrollHeight;
  }

  final other = label == 'A' ? 'B' : 'A';
  write('Session $label — Monty REPL ready.', className: 'system-line');
  write(
    'Tip: set x = 10 here, then evaluate x in Session $other.',
    className: 'system-line',
  );

  input.disabled = false;
  runBtn.disabled = false;
  input.placeholder = 'Python code…';

  Future<void> execute() async {
    final code = input.value.trim();
    if (code.isEmpty) {
      input.focus();
      return;
    }
    input.value = '';
    write('>>> $code', className: 'input-line');
    try {
      final result = await repl.feed(code);
      if (result.printOutput != null && result.printOutput!.isNotEmpty) {
        write(result.printOutput!, className: 'print-line');
      }
      if (result.error != null) {
        write(result.error!.message, className: 'error-line');
      } else if (result.value is! MontyNone) {
        write('=> ${result.value}', className: 'output-line');
      }
    } on Object catch (e) {
      write('Error: $e', className: 'error-line');
    }
    input.focus();
  }

  runBtn.onclick = (web.MouseEvent _) {
    unawaited(execute());
  }.toJS;
  input.onkeydown = (web.KeyboardEvent e) {
    if (e.key == 'Enter') unawaited(execute());
  }.toJS;
}

// ---------------------------------------------------------------------------
// VFS panel — Monty() with osHandler + snapshot/restore
// ---------------------------------------------------------------------------
void _initVfsPanel() {
  final output = _div('output-vfs');
  final input = _input('input-vfs');
  final runBtn = _button('run-vfs');
  final snapBtn = _button('snap-vfs');
  final restoreBtn = _button('restore-vfs');

  Uint8List? savedSnapshot;

  void write(String text, {String? className}) {
    final div = web.document.createElement('div') as web.HTMLDivElement
      ..textContent = text;
    if (className != null) div.className = className;
    output
      ..appendChild(div)
      ..scrollTop = output.scrollHeight;
  }

  // Monty session with in-memory VFS wired to the osHandler.
  final monty = Monty(osHandler: _osHandler);

  write(
    'VFS session — try: import pathlib; pathlib.Path("/data/hello.txt").read_text()',
    className: 'system-line',
  );
  write('Files: ${_vfs.keys.join(", ")}', className: 'system-line');

  input.disabled = false;
  runBtn.disabled = false;
  input.placeholder =
      'import pathlib; pathlib.Path("/data/hello.txt").read_text()';

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
        write(result.printOutput!, className: 'print-line');
      }
      if (result.error != null) {
        write(result.error!.message, className: 'error-line');
      } else if (result.value is! MontyNone) {
        write('=> ${result.value}', className: 'output-line');
      }
    } on Object catch (e) {
      write('Error: $e', className: 'error-line');
    }
    input.focus();
  }

  runBtn.onclick = (web.MouseEvent _) {
    unawaited(execute());
  }.toJS;
  input.onkeydown = (web.KeyboardEvent e) {
    if (e.key == 'Enter') unawaited(execute());
  }.toJS;

  // Snapshot: capture current Python variables → Uint8List.
  snapBtn.onclick = (web.MouseEvent _) {
    try {
      final bytes = monty.snapshot();
      savedSnapshot = bytes;
      write(
        '📸 Snapshot saved (${bytes.length} bytes). '
        'Modify state then click ↩ to restore.',
        className: 'system-line',
      );
    } on Object catch (e) {
      write('Snapshot error: $e', className: 'error-line');
    }
  }.toJS;

  // Restore: reload the most recently saved snapshot.
  restoreBtn.onclick = (web.MouseEvent _) {
    final saved = savedSnapshot;
    if (saved == null) {
      write('No snapshot yet — click 📸 first.', className: 'system-line');
      return;
    }
    try {
      monty.restore(saved);
      write(
        '✅ State restored from snapshot.',
        className: 'system-line',
      );
    } on Object catch (e) {
      write('Restore error: $e', className: 'error-line');
    }
  }.toJS;
}

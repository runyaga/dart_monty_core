// Web demo for dart_monty_core — four panels, each demonstrating a layer of the API.
//
//  Panel 1 — Monty.exec()  (one-shot, stateless)
//    Exercises: Monty.exec, inputs, MontyValue pattern matching,
//               MontyResult.printOutput, MontyLimits.
//
//  Panel 2 — MontyRepl     (persistent heap, multi-REPL isolation)
//    Two independent MontyRepl instances (A and B).
//    Exercises: MontyRepl.feed, externals, osHandler, detectContinuation,
//               snapshot, restore, MontyRepl.feedStart/resume.
//
//  Panel 3 — Virtual Filesystem  (Monty + osHandler)
//    Exercises: Monty(osHandler:), pathlib, OsCallException, snapshot, restore.
//
//  Panel 4 — External functions  (MontySession start/resume loop)
//    Exercises: MontySession.start, MontyPending, MontyOsCall,
//               resumeWithError, MontyProgress exhaustive match.

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

// ---------------------------------------------------------------------------
// DOM helpers
// ---------------------------------------------------------------------------
web.HTMLDivElement _div(String id) =>
    web.document.getElementById(id)! as web.HTMLDivElement;
web.HTMLInputElement _input(String id) =>
    web.document.getElementById(id)! as web.HTMLInputElement;
web.HTMLButtonElement _button(String id) =>
    web.document.getElementById(id)! as web.HTMLButtonElement;
web.HTMLSelectElement _select(String id) =>
    web.document.getElementById(id)! as web.HTMLSelectElement;

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
  _initOneShotPanel();
  _initReplPanel('a', MontyRepl());
  _initReplPanel('b', MontyRepl());
  _initVfsPanel();
  _initSessionPanel();
}

// ---------------------------------------------------------------------------
// Panel 1 — Monty.exec() one-shot
// ---------------------------------------------------------------------------
void _initOneShotPanel() {
  final output = _div('output-exec');
  final input = _input('input-exec');
  final runBtn = _button('run-exec');
  final limitSelect = _select('limit-exec');

  void write(String text, {String? className}) =>
      _appendLine(output, text, className: className);

  write('One-shot mode — no state between runs.', className: 'system-line');
  write('Try: [i*i for i in range(5)]  or  {"key": [1,2,3]}', className: 'system-line');

  Future<void> execute() async {
    final code = input.value.trim();
    if (code.isEmpty) return;
    input.value = '';
    write('>>> $code', className: 'input-line');

    // Build limits from the selector.
    MontyLimits? limits;
    switch (limitSelect.value) {
      case '50ms':
        limits = const MontyLimits(timeoutMs: 50);
      case '200ms':
        limits = const MontyLimits(timeoutMs: 200);
      case 'stack10':
        limits = const MontyLimits(stackDepth: 10);
    }

    try {
      final result = await Monty.exec(code, limits: limits);

      if (result.printOutput != null && result.printOutput!.isNotEmpty) {
        write(result.printOutput!.trimRight(), className: 'print-line');
      }

      if (result.error != null) {
        write('${result.error!.excType}: ${result.error!.message}', className: 'error-line');
      } else {
        write('=> ${_formatValue(result.value)}', className: 'output-line');
        write(
          '   (${result.usage.memoryBytesUsed}b  ${result.usage.timeElapsedMs}ms  stack:${result.usage.stackDepthUsed})',
          className: 'system-line',
        );
      }
    } on MontyResourceError catch (e) {
      write('ResourceError: ${e.message}', className: 'error-line');
    } on MontyError catch (e) {
      write('Error: $e', className: 'error-line');
    }
  }

  runBtn.onclick = (web.MouseEvent _) { unawaited(execute()); }.toJS;
  input.onkeydown = (web.KeyboardEvent e) {
    if (e.key == 'Enter') unawaited(execute());
  }.toJS;
  input.disabled = false;
  runBtn.disabled = false;
}

// ---------------------------------------------------------------------------
// Panel 2 — MontyRepl (A or B)
// ---------------------------------------------------------------------------
void _initReplPanel(String panelId, MontyRepl repl) {
  final output = _div('output-$panelId');
  final input = _input('input-$panelId');
  final runBtn = _button('run-$panelId');
  final snapBtn = _button('snap-$panelId');
  final restoreBtn = _button('restore-$panelId');
  final label = panelId.toUpperCase();

  List<int>? savedSnap;
  var promptMode = '>>> ';

  void write(String text, {String? className}) =>
      _appendLine(output, text, className: className);

  write(
    'Session $label — independent Rust REPL heap. '
    'Variables in $label are invisible in ${label == "A" ? "B" : "A"}.',
    className: 'system-line',
  );
  write('Try: x = 10  then evaluate x in Session ${label == "A" ? "B" : "A"}.', className: 'system-line');

  Future<void> execute() async {
    final code = input.value.trim();
    if (code.isEmpty) { input.focus(); return; }

    // Check continuation BEFORE clearing (for multi-line accumulation).
    final mode = await repl.detectContinuation(code);
    if (mode != ReplContinuationMode.complete) {
      // Show '...' prompt but keep collecting lines.
      promptMode = '... ';
      return;
    }
    promptMode = '>>> ';
    input.value = '';
    write('$promptMode$code', className: 'input-line');

    try {
      // externals: demo host function callable from Python.
      final result = await repl.feed(
        code,
        externals: {
          'host_upper': (args) async => (args['_0'] as String).toUpperCase(),
        },
        osHandler: _osHandler,
      );

      if (result.printOutput != null && result.printOutput!.isNotEmpty) {
        write(result.printOutput!.trimRight(), className: 'print-line');
      }
      if (result.error != null) {
        write('${result.error!.excType}: ${result.error!.message}', className: 'error-line');
      } else if (result.value is! MontyNone) {
        write('=> ${_formatValue(result.value)}', className: 'output-line');
      }
    } on MontyError catch (e) {
      write('Error: $e', className: 'error-line');
    }
    input.focus();
  }

  // Snapshot
  snapBtn.onclick = (web.MouseEvent _) {
    unawaited(() async {
      try {
        final bytes = await repl.snapshot();
        savedSnap = bytes.toList();
        write('📸 Snapshot saved (${bytes.length} bytes).', className: 'system-line');
      } on Object catch (e) {
        write('Snapshot error: $e', className: 'error-line');
      }
    }());
  }.toJS;

  // Restore
  restoreBtn.onclick = (web.MouseEvent _) {
    final snap = savedSnap;
    if (snap == null) { write('No snapshot yet.', className: 'system-line'); return; }
    unawaited(() async {
      try {
        await repl.restore(Uint8List.fromList(snap));
        write('↩ State restored from snapshot.', className: 'system-line');
      } on Object catch (e) {
        write('Restore error: $e', className: 'error-line');
      }
    }());
  }.toJS;

  runBtn.onclick = (web.MouseEvent _) { unawaited(execute()); }.toJS;
  input.onkeydown = (web.KeyboardEvent e) {
    if (e.key == 'Enter') unawaited(execute());
  }.toJS;
  input.disabled = false;
  runBtn.disabled = false;
}

// ---------------------------------------------------------------------------
// Panel 3 — VFS / OsCall with Monty
// ---------------------------------------------------------------------------
void _initVfsPanel() {
  final output = _div('output-vfs');
  final input = _input('input-vfs');
  final runBtn = _button('run-vfs');
  final snapBtn = _button('snap-vfs');
  final restoreBtn = _button('restore-vfs');

  List<int>? savedSnap;
  final monty = Monty(osHandler: _osHandler);

  void write(String text, {String? className}) =>
      _appendLine(output, text, className: className);

  write('VFS panel — import pathlib then access /data/ files.', className: 'system-line');
  write('Files: ${_vfs.keys.join(", ")}', className: 'system-line');

  Future<void> execute() async {
    final code = input.value.trim();
    if (code.isEmpty) { input.focus(); return; }
    input.value = '';
    write('>>> $code', className: 'input-line');

    try {
      final result = await monty.run(code);
      if (result.printOutput != null && result.printOutput!.isNotEmpty) {
        write(result.printOutput!.trimRight(), className: 'print-line');
      }
      if (result.error != null) {
        write('${result.error!.excType}: ${result.error!.message}', className: 'error-line');
      } else if (result.value is! MontyNone) {
        write('=> ${_formatValue(result.value)}', className: 'output-line');
      }
    } on MontyError catch (e) {
      write('Error: $e', className: 'error-line');
    }
    input.focus();
  }

  snapBtn.onclick = (web.MouseEvent _) {
    unawaited(() async {
      final bytes = await monty.snapshot();
      savedSnap = bytes.toList();
      write('📸 Snapshot saved (${bytes.length} bytes).', className: 'system-line');
    }());
  }.toJS;

  restoreBtn.onclick = (web.MouseEvent _) {
    final snap = savedSnap;
    if (snap == null) { write('No snapshot yet.', className: 'system-line'); return; }
    unawaited(() async {
      await monty.restore(Uint8List.fromList(snap));
      write('↩ Restored.', className: 'system-line');
    }());
  }.toJS;

  runBtn.onclick = (web.MouseEvent _) { unawaited(execute()); }.toJS;
  input.onkeydown = (web.KeyboardEvent e) {
    if (e.key == 'Enter') unawaited(execute());
  }.toJS;
  input.disabled = false;
  runBtn.disabled = false;
}

// ---------------------------------------------------------------------------
// Panel 4 — MontySession start/resume loop (manual dispatch)
// ---------------------------------------------------------------------------
void _initSessionPanel() {
  final output = _div('output-session');
  final input = _input('input-session');
  final runBtn = _button('run-session');

  final session = MontySession(osHandler: _osHandler);

  void write(String text, {String? className}) =>
      _appendLine(output, text, className: className);

  write('Session panel — manual start/resume loop with externals.', className: 'system-line');
  write('Try: result = compute(5) + compute(10)  (compute doubles the arg)', className: 'system-line');

  Future<void> execute() async {
    final code = input.value.trim();
    if (code.isEmpty) { input.focus(); return; }
    input.value = '';
    write('>>> $code', className: 'input-line');

    try {
      // Start iterative execution with an external function registered.
      var progress = await session.start(
        code,
        externalFunctions: ['compute'],
      );

      // Drive the loop manually — exhaustive pattern match on MontyProgress.
      while (true) {
        switch (progress) {
          case MontyComplete(:final result):
            if (result.printOutput != null && result.printOutput!.isNotEmpty) {
              write(result.printOutput!.trimRight(), className: 'print-line');
            }
            if (result.error != null) {
              write('${result.error!.excType}: ${result.error!.message}', className: 'error-line');
            } else if (result.value is! MontyNone) {
              write('=> ${_formatValue(result.value)}', className: 'output-line');
            }
            input.focus();
            return;

          case MontyPending(:final functionName, :final arguments, :final kwargs):
            write(
              '  ⚡ call: $functionName(${arguments.map((a) => a.dartValue).join(", ")}'
              '${kwargs != null && kwargs.isNotEmpty ? ", ${kwargs.entries.map((e) => "${e.key}=${e.value.dartValue}").join(", ")}" : ""})',
              className: 'system-line',
            );
            if (functionName == 'compute') {
              final n = arguments.first.dartValue as int;
              progress = await session.resume(n * 2);
            } else {
              progress = await session.resumeWithError('Unknown: $functionName');
            }

          case MontyOsCall(:final operationName, :final arguments):
            write('  🗂 os: $operationName(${arguments.map((a) => a.dartValue).join(", ")})', className: 'system-line');
            progress = await session.resume(null);

          case MontyNameLookup(:final variableName):
            write('  🔍 lookup: $variableName', className: 'system-line');
            progress = await session.resumeWithError('$variableName not found');

          case MontyResolveFutures():
            progress = await session.resume(null);
        }
      }
    } on MontyError catch (e) {
      write('Error: $e', className: 'error-line');
      input.focus();
    }
  }

  runBtn.onclick = (web.MouseEvent _) { unawaited(execute()); }.toJS;
  input.onkeydown = (web.KeyboardEvent e) {
    if (e.key == 'Enter') unawaited(execute());
  }.toJS;
  input.disabled = false;
  runBtn.disabled = false;
}

// ---------------------------------------------------------------------------
// Value formatting
// ---------------------------------------------------------------------------
String _formatValue(MontyValue v) => switch (v) {
  MontyNone() => 'None',
  MontyBool(:final value) => value.toString(),
  MontyInt(:final value) => value.toString(),
  MontyFloat(:final value) => value.isNaN ? 'nan' : value.isInfinite ? (value > 0 ? 'inf' : '-inf') : value.toString(),
  MontyString(:final value) => '"$value"',
  MontyBytes(:final value) => 'b[${value.length} bytes]',
  MontyList(:final items) => '[${items.map(_formatValue).join(", ")}]',
  MontyTuple(:final items) => '(${items.map(_formatValue).join(", ")})',
  MontyDict(:final entries) => '{${entries.entries.map((e) => '"${e.key}": ${_formatValue(e.value)}').join(", ")}}',
  MontySet(:final items) => '{${items.map(_formatValue).join(", ")}}',
  MontyFrozenSet(:final items) => 'frozenset({${items.map(_formatValue).join(", ")}})',
  MontyDate(:final year, :final month, :final day) => '$year-$month-$day',
  MontyDateTime(:final year, :final month, :final day, :final hour, :final minute) =>
    '$year-$month-${day}T$hour:$minute',
  MontyTimeDelta(:final days, :final seconds) => '${days}d ${seconds}s',
  MontyPath(:final value) => 'Path("$value")',
  MontyNamedTuple(:final typeName, :final fieldNames, :final values) =>
    '$typeName(${List.generate(fieldNames.length, (i) => "${fieldNames[i]}=${_formatValue(values[i])}").join(", ")})',
  MontyDataclass(:final name, :final attrs) =>
    '$name(${attrs.entries.map((e) => "${e.key}=${_formatValue(e.value)}").join(", ")})',
  _ => v.toString(),
};

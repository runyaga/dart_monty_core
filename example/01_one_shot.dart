// 01 — One-shot execution
//
// Monty.exec() creates a temporary interpreter, runs code, disposes.
// No state survives between calls — each exec() starts fresh.
//
// Covers: Monty.exec, MontyResult, MontyResourceUsage, MontyValue basics.
//
// Run: dart run example/01_one_shot.dart

import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  // ── Arithmetic ──────────────────────────────────────────────────────────────
  final r1 = await Monty.exec('2 ** 10');
  print('2**10 = ${r1.value}'); // MontyInt(1024)

  // ── Print capture ───────────────────────────────────────────────────────────
  // printOutput contains everything written to stdout during execution.
  final r2 = await Monty.exec('print("hello"); print("world")');
  print('captured: ${r2.printOutput}'); // hello\nworld\n

  // ── String result ───────────────────────────────────────────────────────────
  final r3 = await Monty.exec('"py" + "thon"');
  switch (r3.value) {
    case MontyString(:final value):
      print('string: $value');
    default:
      print('unexpected: ${r3.value}');
  }

  // ── Inputs: inject Dart values as Python variables ───────────────────────────
  // Dart Map<String, Object?> → Python assignment statements prepended to code.
  final r4 = await Monty.exec('x * x', inputs: {'x': 7});
  print('7*7 = ${r4.value}'); // MontyInt(49)

  // ── Resource usage ──────────────────────────────────────────────────────────
  final usage = r4.usage;
  print('memory: ${usage.memoryBytesUsed} bytes');
  print('time:   ${usage.timeElapsedMs} ms');
  print('stack:  ${usage.stackDepthUsed}');

  // ── Python error in result ───────────────────────────────────────────────────
  // A Python exception does NOT throw in Dart — it lands in result.error.
  final r5 = await Monty.exec('1 / 0');
  if (r5.error != null) {
    print('error: ${r5.error!.excType} — ${r5.error!.message}');
  }

  // ── Pattern matching on MontyValue ──────────────────────────────────────────
  // result.value when an error occurred is MontyNone.
  for (final code in [
    'None',
    'True',
    '42',
    '3.14',
    '"hello"',
    'b"bytes"',
    '[1,2,3]',
    '(1,2)',
    '{1,2}',
    '{"a":1}',
  ]) {
    final r = await Monty.exec(code);
    _printValue(code, r.value);
  }
}

void _printValue(String code, MontyValue v) {
  final label = switch (v) {
    MontyNone() => 'None',
    MontyBool(:final value) => 'Bool($value)',
    MontyInt(:final value) => 'Int($value)',
    MontyFloat(:final value) => 'Float($value)',
    MontyString(:final value) => 'Str("$value")',
    MontyBytes(:final value) => 'Bytes(${value.length}b)',
    MontyList(:final items) => 'List[${items.length}]',
    MontyTuple(:final items) => 'Tuple(${items.length})',
    MontySet(:final items) => 'Set{${items.length}}',
    MontyFrozenSet(:final items) => 'FrozenSet{${items.length}}',
    MontyDict(:final entries) => 'Dict{${entries.length}}',
    _ => v.toString(),
  };
  print('$code => $label');
}

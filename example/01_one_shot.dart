// Examples print what they show; the number in the name is the reading order.
// ignore_for_file: avoid_print, file_names
//
// 01 — Running code
//
// Monty.withPool starts a pool of worker processes and closes it when the
// body ends; withSession checks a worker out for one session and gives it
// back. feedRun runs a snippet and returns the value of its last
// expression as a MontyValue, or MontyNone.
//
// A Python exception that escapes the snippet throws MontyRuntimeError in
// Dart; the session survives it.
//
// Covers: Monty.withPool, Monty.withSession, MontySession.feedRun, inputs,
//         MontyRuntimeError, pattern matching on MontyValue.
//
// Run: dart run example/01_one_shot.dart

import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  await Monty.withPool(
    (monty) => monty.withSession((session) async {
      // ── Arithmetic ────────────────────────────────────────────────────────
      final r1 = await session.feedRun('2 ** 10');
      print('2**10 = $r1');
      _check(r1 == const MontyInt(1024), '2 ** 10');

      // ── Statements return None ────────────────────────────────────────────
      final none = await session.feedRun('x = 1');
      print('assignment => $none');
      _check(none is MontyNone, 'assignment');

      // ── String result ─────────────────────────────────────────────────────
      final r3 = await session.feedRun('"py" + "thon"');
      switch (r3) {
        case MontyString(:final value):
          print('string: $value');
          _check(value == 'python', 'concat');
        default:
          throw StateError('unexpected: $r3');
      }

      // ── Inputs: bind Dart values as Python globals ────────────────────────
      final r4 = await session.feedRun(
        'x * x',
        inputs: {'x': const MontyInt(7)},
      );
      print('7*7 = $r4');
      _check(r4 == const MontyInt(49), 'x * x');

      // MontyValue.fromDart converts plain Dart data.
      final r5 = await session.feedRun(
        'sorted(d["xs"])[-1]',
        inputs: {
          'd': MontyValue.fromDart({
            'xs': [3, 9, 4],
          }),
        },
      );
      print('max = ${r5.dartValue}');
      _check(r5 == const MontyInt(9), 'inputs from Dart');

      // ── A Python error throws ─────────────────────────────────────────────
      try {
        await session.feedRun('1 / 0');
        throw StateError('1 / 0 did not raise');
      } on MontyRuntimeError catch (e) {
        print('error: ${e.exception.excType}: ${e.exception.message}');
        _check(e.exception.excType == 'ZeroDivisionError', 'excType');
      }
      // The session is still usable afterwards.
      _check(
        await session.feedRun('x') == const MontyInt(7),
        'session survives an error',
      );

      // ── Pattern matching on MontyValue ────────────────────────────────────
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
        _printValue(code, await session.feedRun(code));
      }
    }),
  );
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
    MontyDict(:final pairs) => 'Dict{${pairs.length}}',
    _ => v.toString(),
  };
  print('$code => $label');
}

void _check(bool ok, String what) {
  if (!ok) throw StateError('unexpected result: $what');
}

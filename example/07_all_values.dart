// Examples print what they show; the number in the name is the reading order.
// ignore_for_file: avoid_print, file_names
//
// 07 — MontyValue: every kind of value
//
// MontyValue is a sealed class: a feed's result is one of its subtypes,
// so a switch over it can be exhaustive.
//
//  Scalars:     MontyNone, MontyBool, MontyInt, MontyBigInt, MontyFloat,
//               MontyString, MontyBytes, MontyEllipsis, MontyNotImplemented
//  Collections: MontyList, MontyTuple, MontyDict, MontySet, MontyFrozenSet
//  Datetime:    MontyDate, MontyDateTime, MontyTime, MontyTimeDelta,
//               MontyTimeZone
//  Structured:  MontyPath, MontyNamedTuple, MontyExceptionValue,
//               MontyFileHandle, MontyClassProxy (example 10),
//               MontyStdTypeProxy
//
// Covers: the subtypes, dartValue, MontyValue.fromDart, values as inputs.
//
// Run: dart run example/07_all_values.dart

import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  await Monty.withPool(
    (monty) => monty.withSession((session) async {
      await _scalars(session);
      await _collections(session);
      await _datetimes(session);
      await _structured(session);
      await _fromDart(session);
    }),
  );
}

Future<void> _scalars(MontySession s) async {
  print('\n── scalars ──');

  final none = await s.feedRun('None');
  print('None: dartValue=${none.dartValue}');
  _check(none is MontyNone, 'None');

  final yes = await s.feedRun('True') as MontyBool;
  print('True: ${yes.value}');

  final n = await s.feedRun('2 ** 32') as MontyInt;
  print('2**32: ${n.value}');
  _check(n.value == 4294967296, '2**32');

  // Integers beyond 64 bits arrive as MontyBigInt.
  final big = await s.feedRun('2 ** 100') as MontyBigInt;
  print('2**100: ${big.value}');
  _check(big.value == BigInt.two.pow(100), '2**100');

  // NaN and the infinities survive the trip.
  for (final expr in ['3.14', 'float("nan")', 'float("inf")', '-1e400']) {
    final v = await s.feedRun(expr) as MontyFloat;
    print('$expr -> ${v.value}');
  }

  final str = await s.feedRun('"héllo 世界"') as MontyString;
  print('str: ${str.value}');
  _check(str.value == 'héllo 世界', 'unicode');

  final bytes = await s.feedRun('b"hello"') as MontyBytes;
  print('bytes: ${bytes.value} (len=${bytes.value.length})');

  _check(await s.feedRun('...') is MontyEllipsis, 'Ellipsis');
  _check(await s.feedRun('NotImplemented') is MontyNotImplemented, 'NI');
}

Future<void> _collections(MontySession s) async {
  print('\n── collections ──');

  final list = await s.feedRun('[1, "two", 3.0, None]') as MontyList;
  print('list: ${list.items.map((v) => v.dartValue).toList()}');

  final tup = await s.feedRun('(1, 2, 3)') as MontyTuple;
  print('tuple: ${tup.items.map((v) => v.dartValue).toList()}');

  // A dict is insertion-ordered (key, value) pairs; keys may be any
  // hashable value, not only strings.
  final d = await s.feedRun('{"a": 1, 2: [2, 3]}') as MontyDict;
  for (final (key, value) in d.pairs) {
    print('dict: $key -> ${value.dartValue}');
  }
  _check(d.pairs.length == 2, 'dict pairs');

  final set = await s.feedRun('{1, 2, 3, 2, 1}') as MontySet;
  print('set: ${set.items.length} unique');
  _check(set.items.length == 3, 'set');

  final fs = await s.feedRun('frozenset({4, 5, 6})') as MontyFrozenSet;
  print('frozenset: ${fs.items.map((v) => v.dartValue).toSet()}');

  // dartValue converts nested collections to plain Dart.
  final nested = await s.feedRun('{"x": [1, {"y": True}]}');
  print('nested dartValue: ${nested.dartValue}');
}

Future<void> _datetimes(MontySession s) async {
  print('\n── datetimes ──');
  await s.feedRun('import datetime');

  final date = await s.feedRun('datetime.date(2024, 6, 15)') as MontyDate;
  print('date: ${date.year}-${date.month}-${date.day}');
  _check(date == const MontyDate(year: 2024, month: 6, day: 15), 'date');

  final dt =
      await s.feedRun('datetime.datetime(2024, 6, 15, 12, 30)')
          as MontyDateTime;
  print('datetime: $dt (naive: offsetSeconds=${dt.offsetSeconds})');

  final utc =
      await s.feedRun(
            'datetime.datetime(2024, 6, 15, tzinfo=datetime.timezone.utc)',
          )
          as MontyDateTime;
  print('aware datetime: offsetSeconds=${utc.offsetSeconds}');
  _check(utc.offsetSeconds == 0, 'utc offset');

  final time = await s.feedRun('datetime.time(13, 45, 7)') as MontyTime;
  print('time: ${time.hour}:${time.minute}:${time.second}');

  final td =
      await s.feedRun('datetime.timedelta(days=2, hours=3)') as MontyTimeDelta;
  print('timedelta: days=${td.days} seconds=${td.seconds}');
  _check(td.days == 2 && td.seconds == 3 * 3600, 'timedelta');

  final tz = await s.feedRun('datetime.timezone.utc') as MontyTimeZone;
  print('timezone: offsetSeconds=${tz.offsetSeconds}');
}

Future<void> _structured(MontySession s) async {
  print('\n── structured ──');

  final p = await s.feedRun('import pathlib\npathlib.Path("/usr/bin")');
  print('path: $p');
  _check(p == const MontyPath('/usr/bin'), 'path');

  final nt =
      await s.feedRun('''
from collections import namedtuple
Point = namedtuple("Point", ["x", "y"])
Point(3, 4)
''')
          as MontyNamedTuple;
  print('namedtuple ${nt.typeName}: ${nt.fieldNames} = ${nt.values}');
  _check(nt.fieldNames.length == 2, 'namedtuple');

  // An exception object as a value (not raised).
  final exc = await s.feedRun('ValueError("bad input")') as MontyExceptionValue;
  print('exception value: ${exc.excType}: ${exc.message}');
  _check(exc.excType == 'ValueError', 'exception value');

  // Builtin functions and types arrive as proxies.
  final fn = await s.feedRun('len') as MontyStdTypeProxy;
  final ty = await s.feedRun('int') as MontyStdTypeProxy;
  print('len: ${fn.kind} ${fn.name}; int: ${ty.kind} ${ty.name}');
  _check(fn.kind == 'function' && ty.kind == 'type', 'proxies');
}

Future<void> _fromDart(MontySession s) async {
  print('\n── fromDart and inputs ──');

  // MontyValue.fromDart converts plain Dart data.
  final values = <String, Object?>{
    'none': null,
    'flag': true,
    'count': 42,
    'ratio': 3.14,
    'name': 'hello',
    'when': DateTime.utc(2024, 6, 15, 12),
    'items': [1, 2, 3],
    'config': {'a': 1},
  };
  for (final MapEntry(:key, :value) in values.entries) {
    final v = MontyValue.fromDart(value);
    // Each converted value goes in as an input and comes back unchanged.
    final back = await s.feedRun(key, inputs: {key: v});
    print('$key: ${v.runtimeType}, round trip equal: ${back == v}');
    _check(back == v, 'round trip of $key');
  }
}

void _check(bool ok, String what) {
  if (!ok) throw StateError('unexpected result: $what');
}

// 07 — Complete MontyValue type coverage
//
// MontyValue is a sealed class with 18 concrete subtypes covering every Python
// value type that Monty can return. Use exhaustive switch/pattern-match.
//
// Subtypes by category:
//  Scalars:    MontyNone, MontyBool, MontyInt, MontyFloat, MontyString, MontyBytes
//  Collections: MontyList, MontyTuple, MontyDict, MontySet, MontyFrozenSet
//  Datetime:   MontyDate, MontyDateTime, MontyTimeDelta, MontyTimeZone
//  Structured: MontyPath, MontyNamedTuple, MontyDataclass
//
// Covers: all 18 subtypes, dartValue, MontyValue.fromDart, JSON round-trip,
//         special float handling (NaN, ±Inf).
//
// Run: dart run example/07_all_values.dart

import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  await _scalars();
  await _collections();
  await _datetimes();
  await _structured();
  await _fromDartAndJson();
}

Future<void> _scalars() async {
  print('\n── scalars ──');
  final session = MontySession();

  // MontyNone — Python None
  final none = await session.run('None');
  switch (none.value) {
    case MontyNone():
      print('None: dartValue=${none.value.dartValue}'); // null
    default:
  }

  // MontyBool
  final yes = (await session.run('True')).value as MontyBool;
  print('True: ${yes.value}, dartValue=${yes.dartValue}');

  // MontyInt — arbitrary precision (Monty restricts to i64 range)
  final n = (await session.run('2 ** 32')).value as MontyInt;
  print('2**32: ${n.value}');

  // MontyFloat — NaN and Infinity survive the round-trip
  for (final expr in [
    '3.14',
    'float("nan")',
    'float("inf")',
    'float("-inf")',
  ]) {
    final v = (await session.run(expr)).value as MontyFloat;
    print(
      '$expr → ${v.value.isNaN
          ? "NaN"
          : v.value.isInfinite
          ? "${v.value > 0 ? '+' : '-'}Inf"
          : v.value}',
    );
  }

  // MontyString — UTF-8
  final s = (await session.run('"héllo 世界"')).value as MontyString;
  print('str: ${s.value}');

  // MontyBytes
  final b = (await session.run('b"hello"')).value as MontyBytes;
  print('bytes: ${b.value} (len=${b.value.length})');

  session.dispose();
}

Future<void> _collections() async {
  print('\n── collections ──');
  final session = MontySession();

  // MontyList — ordered, mutable
  final list = (await session.run('[1, "two", 3.0, None]')).value as MontyList;
  print('list items: ${list.items.map((v) => v.dartValue)}');

  // MontyTuple — ordered, immutable
  final tup = (await session.run('(1, 2, 3)')).value as MontyTuple;
  print('tuple: ${tup.items.map((v) => v.dartValue)}');

  // MontyDict — str keys only (Monty restriction)
  final d = (await session.run('{"a": 1, "b": [2, 3]}')).value as MontyDict;
  print('dict keys: ${d.entries.keys.toList()}');
  print(
    'dict["b"]: ${(d.entries["b"] as MontyList).items.map((v) => v.dartValue)}',
  );

  // MontySet
  final set_ = (await session.run('{1, 2, 3, 2, 1}')).value as MontySet;
  print('set items: ${set_.items.length} unique'); // 3

  // MontyFrozenSet
  final fs =
      (await session.run('frozenset({4, 5, 6})')).value as MontyFrozenSet;
  print('frozenset: ${fs.items.map((v) => v.dartValue)}');

  // dartValue recursively converts nested collections.
  final nested = (await session.run('{"x": [1, {"y": True}]}')).value;
  print('nested dartValue: ${nested.dartValue}');

  session.dispose();
}

Future<void> _datetimes() async {
  print('\n── datetimes ──');
  final session = MontySession();

  await session.run('import datetime');

  // MontyDate
  final date =
      (await session.run('datetime.date(2024, 6, 15)')).value as MontyDate;
  print(
    'date: ${date.year}-${date.month}-${date.day}  dartValue=${date.dartValue}',
  );

  // MontyDateTime (naive — no timezone)
  final dt =
      (await session.run('datetime.datetime(2024, 6, 15, 12, 30, 0)')).value
          as MontyDateTime;
  print(
    'datetime: ${dt.year}-${dt.month}-${dt.day} ${dt.hour}:${dt.minute}:${dt.second}',
  );
  print('  naive (offsetSeconds=${dt.offsetSeconds})');

  // MontyTimeDelta
  final td =
      (await session.run('datetime.timedelta(days=2, hours=3)')).value
          as MontyTimeDelta;
  print(
    'timedelta: days=${td.days} seconds=${td.seconds}  dartValue=${td.dartValue}',
  );

  session.dispose();
}

Future<void> _structured() async {
  print('\n── structured ──');
  final session = MontySession();

  // MontyPath — returned when Python evaluates a pathlib.Path object
  await session.run('import pathlib');
  final p = (await session.run('pathlib.Path("/usr/bin")')).value as MontyPath;
  print('path: ${p.value}  dartValue=${p.dartValue}');

  // MontyNamedTuple — Python collections.namedtuple
  await session.run('''
from collections import namedtuple
Point = namedtuple("Point", ["x", "y"])
pt = Point(3, 4)
''');
  final nt = (await session.run('pt')).value as MontyNamedTuple;
  print('namedtuple type: ${nt.typeName}  fields: ${nt.fieldNames}');
  print('  x=${nt.values[0].dartValue}  y=${nt.values[1].dartValue}');
  print('  dartValue: ${nt.dartValue}');

  // MontyDataclass — Python @dataclass
  await session.run('''
from dataclasses import dataclass
@dataclass
class User:
    name: str
    age: int
    active: bool = True

u = User("Alice", 30)
''');
  final dc = (await session.run('u')).value as MontyDataclass;
  print('dataclass: ${dc.name}  frozen=${dc.frozen}  typeId=${dc.typeId}');
  print('  fields: ${dc.fieldNames}');
  print(
    '  name=${dc.attrs["name"]!.dartValue}  age=${dc.attrs["age"]!.dartValue}',
  );
  print('  dartValue: ${dc.dartValue}');

  session.dispose();
}

// ── MontyValue.fromDart / JSON round-trip ─────────────────────────────────────
Future<void> _fromDartAndJson() async {
  print('\n── fromDart + JSON round-trip ──');

  // Convert Dart values to MontyValue.
  final values = [
    MontyValue.fromDart(null), // MontyNone
    MontyValue.fromDart(true), // MontyBool
    MontyValue.fromDart(42), // MontyInt
    MontyValue.fromDart(3.14), // MontyFloat
    MontyValue.fromDart('hello'), // MontyString
    MontyValue.fromDart([1, 2, 3]), // MontyList
    MontyValue.fromDart({'a': 1}), // MontyDict
  ];

  for (final v in values) {
    final json = v.toJson();
    final roundTrip = MontyValue.fromJson(json);
    print(
      '${v.runtimeType}: dartValue=${v.dartValue}  roundTrip=${roundTrip.dartValue}',
    );
  }
}

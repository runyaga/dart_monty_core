// INDEPENDENTLY AUTHORED wire fixtures.
//
// Every other serialization test in this package round-trips through the
// package's OWN encoder: `fromJson(v.toJson())`. That structurally cannot catch
// the failure that matters most here -- an encoder and a decoder which agree on
// the SAME WRONG FORMAT pass every round trip and still break against Rust.
// A round trip tests self-consistency; it says nothing about the contract.
//
// So these literals are not written by Dart. Each was harvested from the REAL
// RUST ENCODER by running Python through the oracle binary:
//
//     podman exec -i dmc-build bash -lc \
//       'cd /work/dart_monty_core && printf %s "<the python>" > /tmp/o.py &&
//        ./native/target/release/oracle < /tmp/o.py'
//
// and taking the `value` field verbatim. The Python that produced each one is
// recorded beside it, so any fixture can be re-derived rather than trusted.
//
// Asserted in BOTH directions, because they fail differently:
//   DECODE  Rust's bytes -> the MontyValue we claim they mean.
//   ENCODE  our MontyValue -> byte-comparable to what Rust emits.
// Decode-only would let the encoder drift; encode-only would let the decoder.
//
// Harvested 2026-09-15 against monty v0.0.23 (tool/fixture-corpus.json).
//
// 24 of the 26 MontyValue subtypes. NOT covered here, stated so the count is
// not mistaken for the hierarchy:
//   - MontyClassInstance / MontyDataclass -- Rust emits a fresh `id` and
//     `instance_id` UUID per run, so a verbatim literal is not reproducible.
//     (A dataclass also arrives as `class_instance` with `is_dataclass: true`,
//     not as its own tag.) Needs a fixture that normalises the two ids.
//   - MontyOpaque -- no single Python expression produces one; it is what the
//     encoder falls back to.
//   - MontyFileHandle -- `open(...)` returned a null value through the oracle,
//     so nothing was harvested rather than guessed.
@TestOn('vm || browser')
library;

import 'dart:convert';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

/// A fixture: the Python that produced it, the literal Rust emitted, and the
/// value it must mean.
class _Wire {
  const _Wire(this.python, this.json, this.value);

  /// The Python evaluated through the oracle to produce [json].
  final String python;

  /// VERBATIM from the Rust encoder. Never regenerate this from Dart.
  final String json;

  /// What this package claims those bytes mean.
  final MontyValue value;
}

/// Canonical JSON: key order is not part of the contract, so compare sorted.
String _canon(Object? o) {
  if (o is Map) {
    final keys = o.keys.map((k) => k as String).toList()..sort();
    final body = keys.map((k) => '${json.encode(k)}:${_canon(o[k])}').join(',');

    return '{$body}';
  }
  if (o is List) return '[${o.map(_canon).join(',')}]';

  return json.encode(o);
}

final fixtures = {
  'none': const _Wire('None', 'null', MontyNone()),
  'bool': const _Wire('True', 'true', MontyBool(true)),
  'int': const _Wire('42', '42', MontyInt(42)),
  'str': const _Wire('"s"', '"s"', MontyString('s')),
  'float': const _Wire('1.5', '1.5', MontyFloat(1.5)),
  'list': const _Wire('[1]', '[1]', MontyList([MontyInt(1)])),
  'bigint': _Wire(
    '123456789012345678901234567890',
    '{"__type": "bigint", "value": "123456789012345678901234567890"}',
    MontyBigInt(BigInt.parse('123456789012345678901234567890')),
  ),
  // -0.0 travels as TEXT under a float envelope, while 1.5 travels bare. That
  // asymmetry is the contract: `-0.0` cannot survive a bare JSON number.
  'float_negative_zero': const _Wire(
    '-0.0',
    '{"__type": "float", "value": "-0.0"}',
    // `-0` is the int zero and loses the sign. This fixture exists BECAUSE
    // signed zero is fragile; taking the lint would silently turn it into a
    // test of 0.0 -- the exact loss it was written to catch.
    // ignore: prefer_int_literals
    MontyFloat(-0.0),
  ),
  'bytes': const _Wire(
    'b"abc"',
    '{"__type": "bytes", "value": [97, 98, 99]}',
    MontyBytes([97, 98, 99]),
  ),
  'tuple': const _Wire(
    '(1,)',
    '{"__type": "tuple", "value": [1]}',
    MontyTuple([MontyInt(1)]),
  ),
  // Both dict shapes, from Rust. An all-string-keyed dict travels under
  // `value`; any other key forces `entries`. Nothing else in the suite pins
  // which shape Rust picks -- only that ours round-trips.
  'dict_string_keys': const _Wire(
    '{"a": 1}',
    '{"__type": "dict", "value": {"a": 1}}',
    MontyDict([(MontyString('a'), MontyInt(1))]),
  ),
  'dict_int_keys': const _Wire(
    '{1: "a"}',
    '{"__type": "dict", "entries": [[1, "a"]]}',
    MontyDict([(MontyInt(1), MontyString('a'))]),
  ),
  'set': const _Wire(
    '{1, 2}',
    '{"__type": "set", "value": [1, 2]}',
    MontySet([MontyInt(1), MontyInt(2)]),
  ),
  'frozenset': const _Wire(
    'frozenset([1])',
    '{"__type": "frozenset", "value": [1]}',
    MontyFrozenSet([MontyInt(1)]),
  ),
  'ellipsis': const _Wire('...', '{"__type": "ellipsis"}', MontyEllipsis()),
  'not_implemented': const _Wire(
    'NotImplemented',
    '{"__type": "not_implemented"}',
    MontyNotImplemented(),
  ),
  'path': const _Wire(
    'pathlib.Path("x")',
    '{"__type": "path", "value": "x"}',
    MontyPath('x'),
  ),
  'date': const _Wire(
    'datetime.date(2020, 1, 2)',
    '{"__type": "date", "year": 2020, "month": 1, "day": 2}',
    MontyDate(year: 2020, month: 1, day: 2),
  ),
  'datetime': const _Wire(
    'datetime.datetime(2020, 1, 2, 3, 4, 5, 6)',
    '{"__type": "datetime", "year": 2020, "month": 1, "day": 2, "hour": 3, '
        '"minute": 4, "second": 5, "microsecond": 6, "offset_seconds": null, '
        '"timezone_name": null}',
    MontyDateTime(
      year: 2020,
      month: 1,
      day: 2,
      hour: 3,
      minute: 4,
      second: 5,
      microsecond: 6,
    ),
  ),
  'time': const _Wire(
    'datetime.time(1, 2, 3, 4)',
    '{"__type": "time", "hour": 1, "minute": 2, "second": 3, '
        '"microsecond": 4, "offset_seconds": null, "timezone_name": null, '
        '"fold": 0}',
    MontyTime(hour: 1, minute: 2, second: 3, microsecond: 4),
  ),
  'timedelta': const _Wire(
    'datetime.timedelta(days=1, seconds=2)',
    '{"__type": "timedelta", "days": 1, "seconds": 2, "microseconds": 0}',
    MontyTimeDelta(days: 1, seconds: 2),
  ),
  'timezone': const _Wire(
    'datetime.timezone.utc',
    '{"__type": "timezone", "offset_seconds": 0, "name": null}',
    MontyTimeZone(offsetSeconds: 0),
  ),
  'namedtuple': const _Wire(
    'namedtuple("P", ["x"])(1)',
    '{"__type": "namedtuple", "type_name": "P", "field_names": ["x"], '
        '"values": [1]}',
    MontyNamedTuple(typeName: 'P', fieldNames: ['x'], values: [MontyInt(1)]),
  ),
  'exception': const _Wire(
    'ValueError("m")',
    '{"__type": "exception", "exc_type": "ValueError", "message": "m"}',
    MontyExceptionValue(excType: 'ValueError', message: 'm'),
  ),
};

void main() {
  group('wire fixtures authored by Rust, not by us', () {
    fixtures.forEach((name, f) {
      test('$name: Rust bytes DECODE to the value we claim', () {
        expect(
          MontyValue.fromJson(json.decode(f.json)),
          f.value,
          reason: 'produced by: ${f.python}',
        );
      });

      test('$name: our value ENCODES to what Rust emits', () {
        expect(
          _canon(f.value.toJson()),
          _canon(json.decode(f.json)),
          reason:
              'our encoder disagrees with the Rust encoder.\n'
              'produced by: ${f.python}',
        );
      });
    });

    test('the fixtures are not silently empty', () {
      // A table-driven suite whose table is empty reports success. This repo
      // has paid for that shape before.
      expect(fixtures.length, greaterThanOrEqualTo(24));
    });
  });
}

// THE SINGLE SOURCE OF TRUTH for the MontyValue and MontyError hierarchies.
//
// WHY THIS FILE EXISTS. Coverage of these two hierarchies was spread across
// several suites, each with its own per-subtype table. Two tables are two
// sources of truth, and they drift: a review of the suite found
// `MontySet is never equal to MontyFrozenSet` asserted in two files, 26
// round-trip tests that were a literal strict subset of another 26, and a test
// whose TITLE still described set equality as ordered after the implementation
// had been changed to unordered. Nothing failed. Nothing could.
//
// So the tables live here, once, and every suite imports them. What a type IS
// is stated in one place; what is DONE with it is the suite's business.
//
// THE GATE THAT KEEPS IT SINGLE-SOURCED is tool/check_hierarchy_registry.sh,
// which reads lib/ rather than trusting this file. It fails on three distinct
// rots -- a hierarchy member with no entry, an entry naming no real class, and
// any second sample table anywhere under test/. A Dart test CANNOT do this:
// there is no runtime reflection on the web or under AOT, so a test cannot
// enumerate a sealed class's subtypes. The guard that used to sit in the
// matrix, `expect(samples.length, 26)`, compared a hand-written table to a
// hand-written number and would pass unchanged if a 27th subtype shipped with
// no sample -- which is precisely the rot it claimed to prevent.
//
// THE ERROR HIERARCHY is enumerated in comments of the form `// ERROR <Name>`,
// which is what the gate greps. They are comments rather than a Dart table
// because these are thrown types, not values: constructing one proves nothing,
// and each needs the suite that provokes it from a real backend.
//
//   MontyError (sealed root, lib/src/platform/monty_error.dart:20)
//     // ERROR MontyScriptError    -- Python raised; carries the traceback
//     // ERROR MontySyntaxError    -- extends MontyScriptError; compile-time
//     // ERROR MontyPanicError     -- the interpreter aborted
//     // ERROR MontyCrashError     -- the host process died
//     // ERROR MontyDisposedError  -- use after close
//     // ERROR MontyResourceError  -- a declared limit was hit
//
// NOT under MontyError, and deliberately excluded from that list because they
// are not part of the sealed hierarchy: MontyException, MontyTypingError,
// MontyInternalError (extends Error), OsCallException,
// OsCallNotHandledException, WireFormatMismatch. They are each covered by
// their own suite; listing them here would imply a `switch` exhaustiveness
// this file cannot promise.
@TestOn('vm || browser')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

/// One wire fixture: what Rust emitted, and what we claim it means.
///
/// The literal is NEVER regenerated from Dart. Each was harvested by running
/// [python] through `native/target/release/oracle` and taking the `value`
/// field verbatim, so any row can be re-derived rather than trusted.
class WireFixture {
  const WireFixture(this.python, this.json, this.value);

  /// The Python evaluated through the oracle to produce [json].
  final String python;

  /// VERBATIM from the Rust encoder.
  final String json;

  /// What this package claims those bytes mean.
  final MontyValue value;
}

/// One constructible sample per MontyValue subtype. Exhaustive by gate, not by
/// assertion -- see tool/check_hierarchy_registry.sh.
final hierarchySamples = <String, MontyValue>{
  'MontyNone': const MontyNone(),
  'MontyBool': const MontyBool(true),
  'MontyInt': const MontyInt(42),
  'MontyBigInt': MontyBigInt(BigInt.parse('123456789012345678901234567890')),
  'MontyFloat': const MontyFloat(1.5),
  'MontyString': const MontyString('s'),
  'MontyBytes': const MontyBytes([1, 2, 3]),
  'MontyList': const MontyList([MontyInt(1)]),
  'MontyTuple': const MontyTuple([MontyInt(1)]),
  'MontyDict': const MontyDict([(MontyString('k'), MontyInt(1))]),
  'MontySet': const MontySet([MontyInt(1)]),
  'MontyFrozenSet': const MontyFrozenSet([MontyInt(1)]),
  'MontyEllipsis': const MontyEllipsis(),
  'MontyNotImplemented': const MontyNotImplemented(),
  'MontyPath': const MontyPath('/x'),
  'MontyDate': const MontyDate(year: 2026, month: 1, day: 2),
  'MontyDateTime': const MontyDateTime(
    year: 2026,
    month: 1,
    day: 2,
    hour: 3,
    minute: 4,
    second: 5,
    microsecond: 6,
  ),
  'MontyTime': const MontyTime(hour: 1, minute: 2, second: 3, microsecond: 4),
  'MontyTimeDelta': const MontyTimeDelta(days: 1, seconds: 2),
  'MontyTimeZone': const MontyTimeZone(offsetSeconds: 0),
  'MontyExceptionValue': const MontyExceptionValue(
    excType: 'ValueError',
    message: 'm',
  ),
  'MontyOpaque': const MontyOpaque(MontyOpaqueKind.repr, 'x'),
  'MontyNamedTuple': const MontyNamedTuple(
    typeName: 'P',
    fieldNames: ['x'],
    values: [MontyInt(1)],
  ),
  'MontyFileHandle': const MontyFileHandle(path: '/f', mode: 'r'),
  'MontyClassInstance': const MontyClassInstance(
    classType: MontyClassType(
      name: 'C',
      id: '1',
      hostDefined: false,
      isDataclass: false,
      attrs: {},
    ),
    instanceId: 'i',
    attrs: {},
  ),
  'MontyDataclass': const MontyDataclass(
    name: 'D',
    typeId: 1,
    fieldNames: ['f'],
    attrs: {'f': MontyInt(1)},
  ),
};

/// Wire fixtures, keyed by SCENARIO -- several per subtype where the wire
/// shape depends on the data (a dict travels differently by key type).
final wireFixtures = {
  'none': const WireFixture('None', 'null', MontyNone()),
  'bool': const WireFixture('True', 'true', MontyBool(true)),
  'int': const WireFixture('42', '42', MontyInt(42)),
  'str': const WireFixture('"s"', '"s"', MontyString('s')),
  'float': const WireFixture('1.5', '1.5', MontyFloat(1.5)),
  'list': const WireFixture('[1]', '[1]', MontyList([MontyInt(1)])),
  'bigint': WireFixture(
    '123456789012345678901234567890',
    '{"__type": "bigint", "value": "123456789012345678901234567890"}',
    MontyBigInt(BigInt.parse('123456789012345678901234567890')),
  ),
  // -0.0 travels as TEXT under a float envelope, while 1.5 travels bare. That
  // asymmetry is the contract: `-0.0` cannot survive a bare JSON number.
  'float_negative_zero': const WireFixture(
    '-0.0',
    '{"__type": "float", "value": "-0.0"}',
    // `-0` is the int zero and loses the sign. This fixture exists BECAUSE
    // signed zero is fragile; taking the lint would silently turn it into a
    // test of 0.0 -- the exact loss it was written to catch.
    // ignore: prefer_int_literals
    MontyFloat(-0.0),
  ),
  'bytes': const WireFixture(
    'b"abc"',
    '{"__type": "bytes", "value": [97, 98, 99]}',
    MontyBytes([97, 98, 99]),
  ),
  'tuple': const WireFixture(
    '(1,)',
    '{"__type": "tuple", "value": [1]}',
    MontyTuple([MontyInt(1)]),
  ),
  // Both dict shapes, from Rust. An all-string-keyed dict travels under
  // `value`; any other key forces `entries`. Nothing else in the suite pins
  // which shape Rust picks -- only that ours round-trips.
  'dict_string_keys': const WireFixture(
    '{"a": 1}',
    '{"__type": "dict", "value": {"a": 1}}',
    MontyDict([(MontyString('a'), MontyInt(1))]),
  ),
  'dict_int_keys': const WireFixture(
    '{1: "a"}',
    '{"__type": "dict", "entries": [[1, "a"]]}',
    MontyDict([(MontyInt(1), MontyString('a'))]),
  ),
  // MULTI-KEY AND UNSORTED, on purpose. Every other dict fixture has ONE key,
  // which makes insertion order unobservable: MEASURED, a decoder patched to
  // reverse its entries left all 49 fixtures AND the 131-test matrix green.
  // `MontyDict.==` is order-insensitive by design (it matches the sandbox), so
  // only a representation-sensitive check can see order at all.
  //
  // It must be the `entries` shape, not `value`. `_canon` SORTS object keys --
  // so under the `value` shape it would canonicalise `{"z":1,"a":2}` and
  // `{"a":2,"z":1}` to the same text and see nothing. `entries` is a JSON
  // LIST, and _canon preserves list order.
  //
  // Note the Rust output is NOT sorted: keys arrive 2, 1, 3, matching Python's
  // insertion order. That is the property under test.
  'dict_multi_key_unsorted': const WireFixture(
    '{2: "b", 1: "a", 3: "c"}',
    '{"__type": "dict", "entries": [[2, "b"], [1, "a"], [3, "c"]]}',
    MontyDict([
      (MontyInt(2), MontyString('b')),
      (MontyInt(1), MontyString('a')),
      (MontyInt(3), MontyString('c')),
    ]),
  ),
  'set': const WireFixture(
    '{1, 2}',
    '{"__type": "set", "value": [1, 2]}',
    MontySet([MontyInt(1), MontyInt(2)]),
  ),
  'frozenset': const WireFixture(
    'frozenset([1])',
    '{"__type": "frozenset", "value": [1]}',
    MontyFrozenSet([MontyInt(1)]),
  ),
  'ellipsis': const WireFixture(
    '...',
    '{"__type": "ellipsis"}',
    MontyEllipsis(),
  ),
  'not_implemented': const WireFixture(
    'NotImplemented',
    '{"__type": "not_implemented"}',
    MontyNotImplemented(),
  ),
  'path': const WireFixture(
    'pathlib.Path("x")',
    '{"__type": "path", "value": "x"}',
    MontyPath('x'),
  ),
  'date': const WireFixture(
    'datetime.date(2020, 1, 2)',
    '{"__type": "date", "year": 2020, "month": 1, "day": 2}',
    MontyDate(year: 2020, month: 1, day: 2),
  ),
  'datetime': const WireFixture(
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
  'time': const WireFixture(
    'datetime.time(1, 2, 3, 4)',
    '{"__type": "time", "hour": 1, "minute": 2, "second": 3, '
        '"microsecond": 4, "offset_seconds": null, "timezone_name": null, '
        '"fold": 0}',
    MontyTime(hour: 1, minute: 2, second: 3, microsecond: 4),
  ),
  'timedelta': const WireFixture(
    'datetime.timedelta(days=1, seconds=2)',
    '{"__type": "timedelta", "days": 1, "seconds": 2, "microseconds": 0}',
    MontyTimeDelta(days: 1, seconds: 2),
  ),
  'timezone': const WireFixture(
    'datetime.timezone.utc',
    '{"__type": "timezone", "offset_seconds": 0, "name": null}',
    MontyTimeZone(offsetSeconds: 0),
  ),
  'namedtuple': const WireFixture(
    'namedtuple("P", ["x"])(1)',
    '{"__type": "namedtuple", "type_name": "P", "field_names": ["x"], '
        '"values": [1]}',
    MontyNamedTuple(typeName: 'P', fieldNames: ['x'], values: [MontyInt(1)]),
  ),
  'exception': const WireFixture(
    'ValueError("m")',
    '{"__type": "exception", "exc_type": "ValueError", "message": "m"}',
    MontyExceptionValue(excType: 'ValueError', message: 'm'),
  ),
};

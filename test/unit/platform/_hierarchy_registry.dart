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
    offsetSeconds: -18000,
    timezoneName: 'EST',
  ),
  // EVERY OPTIONAL FIELD CARRIES A NON-DEFAULT VALUE. A sample built from
  // defaults cannot detect a DROPPED field: the decoder fills the same default
  // back in, so the round trip compares equal. MEASURED -- deleting
  // `'position': position` from MontyFileHandle.toJson left all 692 unit tests
  // green. That is the rule for every sample below, not a note about this one.
  'MontyTime': const MontyTime(
    hour: 1,
    minute: 2,
    second: 3,
    microsecond: 4,
    offsetSeconds: 3600,
    timezoneName: 'TZ',
    fold: 1,
  ),
  'MontyTimeDelta': const MontyTimeDelta(days: 1, seconds: 2),
  'MontyTimeZone': const MontyTimeZone(offsetSeconds: 3600, name: 'TZ'),
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
  'MontyFileHandle': const MontyFileHandle(
    path: '/f',
    mode: 'r',
    position: 7,
  ),
  'MontyClassInstance': const MontyClassInstance(
    classType: MontyClassType(
      name: 'C',
      id: '1',
      hostDefined: false,
      isDataclass: false,
      attrs: {'classAttr': MontyString('c')},
    ),
    instanceId: 'i',
    // NON-EMPTY, and nested: with `attrs: {}` the child-conversion traversal
    // never runs, so a wrapper that forgot to convert its children stayed
    // green.
    attrs: {
      'x': MontyInt(1),
      'nested': MontyList([MontyFloat(1.5)]),
    },
  ),
  'MontyDataclass': const MontyDataclass(
    name: 'D',
    typeId: 1,
    fieldNames: ['f'],
    attrs: {
      'f': MontyInt(1),
      'nested': MontyTuple([MontyString('t')]),
    },
    frozen: true,
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
  // ---------------------------------------------------------------------
  // FLOAT ENVELOPE. Each of these IS already asserted Dart-side, and these
  // rows are deliberately NOT a second copy of that claim:
  //     monty_value_test.dart:116-136  asserts OUR encoder emits the envelope
  //     these rows                     assert RUST emits the same bytes
  // Nothing anywhere proved the two encoders agree, which is the only failure
  // a Dart round trip structurally cannot see. Where a row adds nothing beyond
  // the Dart-side test, it is not here.
  // ---------------------------------------------------------------------
  // `4.0` travels as the TEXT "4.0", never a bare `4`. That envelope is the
  // whole defence against core#128a: a bare JSON `4` decodes as an int, and on
  // dart2js -- one number type, `4.0 is int` is TRUE -- the float would be
  // unrecoverable.
  'float_integral': const WireFixture(
    '4.0',
    '{"__type": "float", "value": "4.0"}',
    // Writing `4` here is what the fixture EXISTS to catch: it makes this a
    // test of MontyFloat(4), i.e. the very collapse core#128a was about.
    // ignore: prefer_int_literals
    MontyFloat(4.0),
  ),
  // NaN and the infinities have no JSON spelling at all.
  'float_nan': const WireFixture(
    'float("nan")',
    '{"__type": "float", "value": "NaN"}',
    MontyFloat(double.nan),
  ),
  'float_infinity': const WireFixture(
    'float("inf")',
    '{"__type": "float", "value": "Infinity"}',
    MontyFloat(double.infinity),
  ),
  'float_negative_infinity': const WireFixture(
    'float("-inf")',
    '{"__type": "float", "value": "-Infinity"}',
    MontyFloat(double.negativeInfinity),
  ),
  // ---------------------------------------------------------------------
  // THE INTEGER ESCALATION BOUNDARY IS 2^53, NOT 2^63 -- harvested, and not
  // where the i64 in the Rust signature suggests:
  //     9007199254740992   (2^53)     -> bare int
  //     9007199254740993   (2^53+1)   -> bigint envelope
  //     9223372036854775807 (i64 MAX) -> bigint envelope
  // It is the JavaScript safe-integer limit, chosen so dart2js -- where every
  // number is a double and precision dies past 2^53 -- can still receive an
  // exact value.
  //
  // RELATIONSHIP TO monty_value_int64_vm_test.dart, so neither looks
  // redundant: that file asserts DART's encoder escalates past 2^53, is VM
  // ONLY (the literals are a dart2js COMPILE error that takes down the whole
  // library), and round-trips through our own encoder. These rows assert RUST
  // escalates at the same boundary, and run on all three targets because the
  // large values are `BigInt.parse` STRINGS, not literals.
  //
  // The below-boundary side is pinned here for the first time: 2^53 itself
  // must stay a BARE INT.
  //
  // WRITTEN AS A LITERAL, and NOT as `1 << 53`. That idiom is what
  // monty_value_int64_vm_test.dart uses, and it is safe there only because
  // that file is VM ONLY. MEASURED here on dart2js: `1 << 53` evaluates to
  // **0** -- shifts are 32-bit on that backend, so the shift overflows to
  // nothing and the fixture silently became a test of MontyInt(0), which duly
  // failed against Rust's `9007199254740992`. The plain literal is correct
  // because 2^53 IS exactly representable as a double; it is 2^53 + 1 that is
  // not, which is why the rows past the boundary use `BigInt.parse` strings.
  'int_at_2_53_stays_bare': const WireFixture(
    '9007199254740992',
    '9007199254740992',
    MontyInt(9007199254740992),
  ),
  'bigint_just_past_2_53': WireFixture(
    '9007199254740993',
    '{"__type": "bigint", "value": "9007199254740993"}',
    MontyBigInt(BigInt.parse('9007199254740993')),
  ),
  'bigint_at_i64_max': WireFixture(
    '9223372036854775807',
    '{"__type": "bigint", "value": "9223372036854775807"}',
    MontyBigInt(BigInt.parse('9223372036854775807')),
  ),
  // STRUCTURED, with NON-EMPTY nested attrs -- `attrs: {}` would leave the
  // attribute traversal unexercised, the same hazard fixed in the samples.
  // Note `class_type.attrs` is a dict envelope nested INSIDE another dict
  // envelope; nothing else in this table exercises two levels of that.
  'class_instance': const WireFixture(
    'class C: self.x = 1; self.nested = [1.5]',
    '{"__type": "class_instance", "class_type": {"name": "C", '
        '"id": "7c0cead4-4931-4a3d-9a33-01bbbd5f27d8", "host_defined": false, '
        '"is_dataclass": false, "attrs": {"__type": "dict", "value": {}}}, '
        '"instance_id": "f73ec986-3063-4c7c-b639-a1de780edfdf", '
        '"attrs": {"__type": "dict", "value": {"x": 1, "nested": [1.5]}}}',
    MontyClassInstance(
      classType: MontyClassType(
        name: 'C',
        id: '7c0cead4-4931-4a3d-9a33-01bbbd5f27d8',
        hostDefined: false,
        isDataclass: false,
        attrs: {},
      ),
      instanceId: 'f73ec986-3063-4c7c-b639-a1de780edfdf',
      attrs: {
        'x': MontyInt(1),
        'nested': MontyList([MontyFloat(1.5)]),
      },
    ),
  ),
  // A FROZEN dataclass, and this row exists to pin that it is NOT a
  // MontyDataclass on the wire: it is a `class_instance` with
  // `is_dataclass: true`, and the envelope carries no `frozen` field at all.
  'dataclass_arrives_as_class_instance': const WireFixture(
    '@dataclass(frozen=True) class D: f: int -> D(1)',
    '{"__type": "class_instance", "class_type": {"name": "D", '
        '"id": "d561690f-c54b-42c3-b32b-2e3fe42a0fce", "host_defined": false, '
        '"is_dataclass": true, "attrs": {"__type": "dict", "value": {}}}, '
        '"instance_id": "2553f4c5-db0c-4b18-a74e-b7ad9ce0e7d5", '
        '"attrs": {"__type": "dict", "value": {"f": 1}}}',
    MontyClassInstance(
      classType: MontyClassType(
        name: 'D',
        id: 'd561690f-c54b-42c3-b32b-2e3fe42a0fce',
        hostDefined: false,
        isDataclass: true,
        attrs: {},
      ),
      instanceId: '2553f4c5-db0c-4b18-a74e-b7ad9ce0e7d5',
      attrs: {'f': MontyInt(1)},
    ),
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

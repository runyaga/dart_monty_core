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
//   MontyError (sealed root, lib/src/worker/monty_error.dart)
//     // ERROR MontySyntaxError    -- fed code did not parse
//     // ERROR MontyRuntimeError   -- Python raised and did not catch
//     // ERROR MontyTypingError    -- the session's type check refused
//     // ERROR MontyCrashedError   -- the worker is gone
//
// NOT under MontyError, and deliberately excluded from that list because they
// are not part of the sealed hierarchy: OsCallNotHandledException,
// ExternalException. They are each covered by their own suite; listing them
// here would imply a `switch` exhaustiveness
// this file cannot promise.
@TestOn('vm || browser')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart'
    show montyClassProxy, montyClassTypeProxy, montyStdTypeProxy;
import 'package:test/test.dart';

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
  'MontyPath': MontyPath('/x'),
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
  'MontyExceptionValue': MontyExceptionValue(
    'ValueError',
    'm',
  ),
  'MontyStdTypeProxy': montyStdTypeProxy('function', 'abs'),
  'MontyNamedTuple': const MontyNamedTuple(
    typeName: 'P',
    fieldNames: ['x'],
    values: [MontyInt(1)],
  ),
  'MontyFileHandle': MontyFileHandle('/f', 'r', position: BigInt.from(7)),
  'MontyClassProxy': montyClassProxy(
    classType: montyClassTypeProxy(
      name: 'C',
      id: '1',
      hostDefined: false,
      isDataclass: false,
      attrs: const {'classAttr': MontyString('c')},
    ),
    instanceId: 'i',
    // NON-EMPTY, and nested: with `attrs: {}` the child-conversion traversal
    // never runs, so a wrapper that forgot to convert its children stayed
    // green.
    attrs: const {
      'x': MontyInt(1),
      'nested': MontyList([MontyFloat(1.5)]),
    },
  ),
};

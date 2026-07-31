// The contract vocabulary for a decoded value.
//
// `WIRE-CONTRACT.md` names the 27 upstream `MontyObject` variants by their wire
// tag — `dict`, `bigint`, `exception` — and that is the vocabulary the type
// identity invariant (I1) is written in. This maps a decoded `MontyValue` back
// onto it.
//
// Deliberately NOT `runtimeType.toString()`. Two reasons, both about the test
// being trustworthy rather than convenient:
//
//   1. dart2js may minify class names, so `runtimeType` is not a stable
//      identifier across the three backends the invariant has to hold on.
//   2. An exhaustive switch over the sealed hierarchy stops compiling when a
//      variant is added. Tiers 2 and 3 add four, and every one of them must be
//      given a contract name deliberately rather than inheriting a plausible
//      default — which is how `Ellipsis` ended up collapsed onto `"..."`.
//
// Shares no code with `lib/`'s encoder or decoder: this file is the reference,
// so reusing them would make it agree with whatever they do.
import 'package:dart_monty_core/dart_monty_core.dart';

/// The `WIRE-CONTRACT.md` tag for [v]'s decoded type.
String montyTypeName(MontyValue v) => switch (v) {
  MontyNone() => 'none',
  MontyBool() => 'bool',
  MontyInt() => 'int',
  MontyFloat() => 'float',
  MontyString() => 'str',
  MontyBytes() => 'bytes',
  MontyList() => 'list',
  MontyTuple() => 'tuple',
  MontyNamedTuple() => 'namedtuple',
  MontyDict() => 'dict',
  MontySet() => 'set',
  MontyFrozenSet() => 'frozenset',
  MontyDate() => 'date',
  MontyDateTime() => 'datetime',
  MontyTimeDelta() => 'timedelta',
  MontyTimeZone() => 'timezone',
  MontyPath() => 'path',
  MontyFileHandle() => 'filehandle',
  MontyDataclass() => 'dataclass',
  MontyEllipsis() => 'ellipsis',
};

// The contract vocabulary for a decoded value.
//
// `WIRE-CONTRACT.md` names the 29 upstream `MontyObject` variants by their wire
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
  MontyBigInt() => 'bigint',
  MontyFloat() => 'float',
  MontyString() => 'str',
  MontyBytes() => 'bytes',
  MontyList() => 'list',
  MontyTuple() => 'tuple',
  MontyNamedTuple() => 'namedtuple',
  // Both dict shapes carry the SAME wire tag; only the payload key differs
  // (`value` vs `entries`). They now decode to one type, so this is one arm —
  // and row 11 was always one row, which is what made the two classes suspect.
  MontyDict() => 'dict',
  MontySet() => 'set',
  MontyFrozenSet() => 'frozenset',
  MontyDate() => 'date',
  MontyDateTime() => 'datetime',
  MontyTimeDelta() => 'timedelta',
  MontyTimeZone() => 'timezone',
  MontyPath() => 'path',
  MontyFileHandle() => 'filehandle',
  // BOTH ADDED 2026-09-14. An alignment audit found the Rust encoder emits
  // these two (convert.rs:172, :174) while Dart had no factory for either, so
  // `datetime.time(12, 0)` and the bare name `NotImplemented` each threw
  // `unknown __type`. This file's own header claimed to cover "the 27 upstream
  // MontyObject variants"; upstream has 29, and these were the missing two.
  MontyTime() => 'time',
  MontyNotImplemented() => 'not_implemented',
  MontyClassInstance() => 'class_instance',
  // Still here, and still 'dataclass'. monty v0.0.23 stopped EMITTING this
  // tag (upstream cf8246d7 replaced the wire Dataclass variant), so nothing
  // decodes into a MontyDataclass any more — but the type is still how a HOST
  // sends one IN, and this file names the tag a value carries, not the tag
  // the engine happens to produce today.
  MontyDataclass() => 'dataclass',
  MontyEllipsis() => 'ellipsis',
  MontyExceptionValue() => 'exception',
  // The five opaque kinds each keep their own contract tag, which is why the
  // variant carries a typed kind rather than collapsing them.
  MontyOpaque(:final kind) => kind.wireTag,
};

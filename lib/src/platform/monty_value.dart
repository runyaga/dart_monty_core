import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

part 'monty_value_scalars.dart';
part 'monty_value_collections.dart';
part 'monty_value_datetime.dart';
part 'monty_value_structured.dart';

const _deepEq = DeepCollectionEquality();

/// A typed representation of a Python value crossing the Rust-Dart boundary.
///
/// Each subclass corresponds to a Python type. Use pattern matching:
/// ```dart
/// switch (result.value) {
///   case MontyInt(:final value): print('int: $value');
///   case MontyString(:final value): print('str: $value');
///   case MontyDate(:final year, :final month, :final day): ...
///   case MontyList(:final items): ...
///   case null: print('no value');
/// }
/// ```
sealed class MontyValue {
  const MontyValue();

  /// Deserializes a JSON value into the appropriate [MontyValue] subclass.
  ///
  /// Handles:
  /// - Scalars: null, bool, int, double, String
  /// - Collections: List (→ [MontyList])
  /// - Typed wrappers: every object carries `__type`, which selects the class.
  ///   A dict is `{"__type": "dict", "value": {…}}` (→ [MontyDict]) or
  ///   `{"__type": "dict", "entries": […]}` (→ [MontyPairsDict]).
  ///
  /// Throws [FormatException] on an object with no `__type` or an unrecognised
  /// one. Both used to decode as a dict, which is what let sandboxed Python
  /// mint host types (core#136).
  factory MontyValue.fromJson(Object? json) => switch (json) {
    null => const MontyNone(),
    final bool b => MontyBool(b),
    final int n => MontyInt(n),
    final double d => MontyFloat(d),
    final String s => _parseSpecialFloat(s) ?? MontyString(s),
    final List<dynamic> l => MontyList(l.map(MontyValue.fromJson).toList()),
    final Map<String, dynamic> m => _parseMap(m),
    _ => throw ArgumentError(
      'Cannot deserialize ${json.runtimeType} to MontyValue',
    ),
  };

  /// Converts a native Dart value into the appropriate [MontyValue] subclass.
  ///
  /// Handles:
  /// - `MontyValue` instances (passed through)
  /// - `null`, `bool`, `int`, `double`, `String`
  /// - `DateTime` (→ [MontyDateTime] in UTC)
  /// - `List` (elements recursively converted)
  /// - `Map` (values recursively converted, keys coerced to String)
  factory MontyValue.fromDart(Object? value) => switch (value) {
    final MontyValue mv => mv,
    null => const MontyNone(),
    final bool b => MontyBool(b),
    final int n => MontyInt(n),
    final double d => MontyFloat(d),
    final String s => MontyString(s),
    final DateTime dt => MontyDateTime(
      year: dt.toUtc().year,
      month: dt.toUtc().month,
      day: dt.toUtc().day,
      hour: dt.toUtc().hour,
      minute: dt.toUtc().minute,
      second: dt.toUtc().second,
      microsecond: dt.toUtc().microsecond,
    ),
    final List<dynamic> l => MontyList(l.map(MontyValue.fromDart).toList()),
    final Map<dynamic, dynamic> m => MontyDict(
      m.map((k, v) => MapEntry(k.toString(), MontyValue.fromDart(v))),
    ),
    _ => throw ArgumentError(
      'Cannot convert ${value.runtimeType} to MontyValue',
    ),
  };

  static final Map<String, MontyValue Function(Map<String, dynamic>)>
  _typeFactories = {
    'bytes': MontyBytes._fromMap,
    'tuple': MontyTuple._fromMap,
    'set': MontySet._fromMap,
    'frozenset': MontyFrozenSet._fromMap,
    'date': MontyDate._fromMap,
    'datetime': MontyDateTime._fromMap,
    'timedelta': MontyTimeDelta._fromMap,
    'timezone': MontyTimeZone._fromMap,
    'path': MontyPath._fromMap,
    'filehandle': MontyFileHandle._fromMap,
    'namedtuple': MontyNamedTuple._fromMap,
    'dataclass': MontyDataclass._fromMap,
    'ellipsis': MontyEllipsis._fromMap,
    // Both dict shapes share one tag: `value` for all-string keys,
    // `entries` for anything else. The tag names the TYPE; the payload key
    // names how the keys are encoded.
    'dict': _dictFromMap,
  };

  /// Encodes a host-supplied value as wire JSON.
  ///
  /// **The single serialization point for values leaving Dart.** Five call
  /// sites used to build wire JSON with a raw `json.encode(value)` — `resume`,
  /// `resumeNameLookup`, both `resolveFutures` implementations, and
  /// `MontyRepl.resume` — so the encoder was not in fact the only thing
  /// deciding what a value looked like on the wire. A plain Dart `Map` went
  /// out as a bare JSON object, which the interpreter accepted as a dict.
  ///
  /// Since wire format v2 it would be REJECTED, because a bare object is a
  /// protocol violation. Routing through [MontyValue.fromDart] gives it the
  /// dict envelope, so host values and interpreter values are encoded by the
  /// same code — the property that makes rule R1 checkable at all.
  static String encodeForWire(Object? value) =>
      json.encode(MontyValue.fromDart(value).toJson());

  /// Serializes this value back to JSON compatible with the Rust side.
  Object? toJson();

  /// Returns the underlying Dart value for easy migration.
  ///
  /// Scalars return their primitive (`int`, `double`, `String`, etc.).
  /// Collections recursively unwrap to `List<Object?>` / `Map<String, Object?>`.
  /// Typed wrappers return their `toJson()` map.
  Object? get dartValue;

  /// Dispatches the two dict payload shapes.
  ///
  /// `entries` (any key type) wins if present; otherwise `value` (string keys).
  static MontyValue _dictFromMap(Map<String, dynamic> map) {
    final entries = map['entries'];
    if (entries is List<dynamic>) return MontyPairsDict._fromEntries(entries);

    return MontyDict._fromMap(map);
  }

  static MontyValue? _parseSpecialFloat(String s) => switch (s) {
    'NaN' => const MontyFloat(double.nan),
    'Infinity' => const MontyFloat(double.infinity),
    '-Infinity' => const MontyFloat(double.negativeInfinity),
    _ => null,
  };

  // Returns different sealed subclasses based on __type, so it
  // cannot be a constructor.
  static MontyValue _parseMap(Map<String, dynamic> map) {
    final type = map['__type'] as String?;

    // THIS is where core#136 lived. Both fall-throughs below used to produce a
    // dict: an object with no `__type`, and an object with an unrecognised one.
    // The first meant a Python dict and a type envelope were the same shape,
    // so returning `{"__type": "path", "value": "x"}` from sandboxed Python
    // arrived here as a genuine MontyPath — untrusted code choosing its own
    // host class.
    //
    // Since wire format v2 every object the encoder emits is tagged, so
    // anything untagged is a protocol violation rather than a value.
    // `fromJson` is a deserializer; refusing malformed input is the same
    // contract `json.decode` has (rule R4 of WIRE-CONTRACT.md).
    if (type == null) {
      throw FormatException(
        'untagged JSON object at a value position. Since wire format v2 every '
        'object carries a __type, and a dict is '
        '{"__type":"dict","value":{...}}. An untagged object here means the '
        'value did not come from this version of the encoder — check for a '
        'stale lib/assets/*.wasm, or a hand-built JSON payload.',
        json.encode(map),
      );
    }

    final factory = _typeFactories[type];
    if (factory == null) {
      throw FormatException(
        'unknown __type "$type". The decoder rejects what it does not '
        'understand rather than guessing a dict, because guessing is how a '
        'forged type became a real one (core#136).',
        json.encode(map),
      );
    }

    return factory(map);
  }
}

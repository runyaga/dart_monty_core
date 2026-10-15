part of 'monty_value.dart';

// ---------------------------------------------------------------------------
// Scalars
// ---------------------------------------------------------------------------

/// Represents a Python `None` value.
@immutable
final class MontyNone extends MontyValue {
  /// Creates a [MontyNone].
  const MontyNone();

  @override
  int get _graphKind => _kFixed;

  @override
  Null get dartValue => null;

  @override
  bool operator ==(Object other) => other is MontyNone;

  @override
  int get hashCode => null.hashCode;

  @override
  String toString() => 'MontyNone()';

  @override
  Null _toJson() => null;
}

/// Represents a Python `bool` value.
@immutable
final class MontyBool extends MontyValue {
  /// Creates a [MontyBool] with the given [value].
  // Value-type wrapper — single positional field is the intended API.
  // ignore: avoid_positional_boolean_parameters
  const MontyBool(this.value);

  /// The underlying boolean value.
  final bool value;

  @override
  int get _graphKind => _kFixed;

  @override
  bool get dartValue => value;

  /// Python's `bool` is an `int`: `True == 1 == 1.0 == 1+0j`.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyBool ? other.value == value : _numEquals(this, other));

  /// The hash of the integer 0 or 1, as every equal number has.
  @override
  int get hashCode => (value ? 1 : 0).hashCode;

  @override
  String toString() => 'MontyBool($value)';

  @override
  bool _toJson() => value;
}

/// Represents a Python `int` value.
@immutable
final class MontyInt extends MontyValue {
  /// Creates a [MontyInt] with the given [value].
  const MontyInt(this.value);

  /// The underlying integer value.
  final int value;

  /// The largest magnitude every backend holds exactly in a Dart `int`.
  ///
  /// On dart2js `int` IS a double, so beyond this an integer cannot be a
  /// [MontyInt] at all there. Values past it decode as [MontyBigInt] on every
  /// backend, and encode as the bigint envelope so the digits survive.
  static final BigInt _exactIntLimit = BigInt.from(1) << 53;

  @override
  int get _graphKind => _kFixed;

  @override
  int get dartValue => value;

  /// Python's numeric `==`: equal to the [MontyBigInt], [MontyBool],
  /// [MontyFloat] or [MontyComplex] of the same number, compared exactly
  /// (`2**64 + 1 != float(2**64)`).
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyInt ? other.value == value : _numEquals(this, other));

  @override
  int get hashCode => _intHash(value);

  @override
  String toString() => 'MontyInt($value)';

  @override
  Object _toJson() {
    final big = BigInt.from(value);
    if (big.abs() > _exactIntLimit) {
      return {'__type': 'bigint', 'value': big.toString()};
    }

    return value;
  }
}

/// Represents a Python `float` value (including NaN and infinities).
@immutable
final class MontyFloat extends MontyValue {
  /// Creates a [MontyFloat] with the given [value].
  const MontyFloat(this.value);

  /// The underlying double value.
  final double value;

  @override
  int get _graphKind => _kFixed;

  @override
  double get dartValue => value;

  /// Python's numeric `==` (an integral float equals the int of its value,
  /// exactly), except that NaN equals NaN: a recorded divergence, so a value
  /// holding NaN can be a map key.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyFloat
          ? _floatEquals(value, other.value)
          : _numEquals(this, other));

  /// An integral float hashes as its integer, as every equal number does.
  @override
  int get hashCode => _doubleHash(value);

  @override
  String toString() => 'MontyFloat($value)';

  static Map<String, Object?> _tagged(String text) => {
    '__type': 'float',
    'value': text,
  };

  /// Renders so the type and the sign survive: `4.0`, not `4`; `-0.0`, not `0`.
  // Delegates to the shared rule. Without it the web would emit
  // {"__type":"float","value":"4"} for 4.0: still decoded as a float because
  // the TAG carries the type, but the text would disagree with what the Rust
  // encoder writes for the identical value, and the two sides must agree byte
  // for byte or the differential is comparing different things.
  static String _exactText(double v) => exactDoubleText(v);

  @override
  Object _toJson() {
    // The non-finite forms have no JSON number representation, so they travel
    // as TAGGED text. They used to be bare strings, which made them
    // indistinguishable from the Python strings "NaN"/"Infinity"/"-Infinity" —
    // and the decoder resolved that ambiguity by guessing float, so a genuine
    // string was silently converted (wire v3 / rule R2).
    if (value.isNaN) return _tagged('NaN');
    if (value == double.infinity) return _tagged('Infinity');
    if (value == double.negativeInfinity) return _tagged('-Infinity');

    // Tier 3 / core#128: an integral float and a negative zero are the two
    // shapes a JSON number cannot carry across the web transport — `4.0`
    // reparses as `4`, and `-0.0` re-serialises as `0`. Carried as text they
    // survive, and only these two shapes pay for it.
    if (value == value.roundToDouble() || (value == 0 && value.isNegative)) {
      return _tagged(_exactText(value));
    }

    // A finite float stays a plain JSON number. Tier 3 will envelope these too,
    // for the int/float and signed-zero distinctions the web transport
    // destroys (core#128).
    return value;
  }
}

/// Represents a Python `complex` value.
///
/// It is a number: `MontyComplex(1, 0) == MontyInt(1)` and they hash
/// alike, as `1 + 0j == 1` in Python. A complex equals a real number only
/// when its imaginary part is zero (`-0.0` included). Each part compares as
/// a [MontyFloat] does, so NaN equals NaN (the recorded divergence).
@immutable
final class MontyComplex extends MontyValue {
  /// The complex number [real] + [imag]j. Any doubles, NaN and the
  /// infinities included, as Python's `complex(real, imag)` accepts.
  const MontyComplex(this.real, this.imag);

  /// The real part.
  final double real;

  /// The imaginary part.
  final double imag;

  @override
  int get _graphKind => _kFixed;

  @override
  Map<String, Object?> get dartValue => _toJson();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyComplex
          ? _floatEquals(real, other.real) && _floatEquals(imag, other.imag)
          : _numEquals(this, other));

  /// With a zero imaginary part, the hash of the real part, as every equal
  /// number has.
  @override
  int get hashCode => imag == 0
      ? _doubleHash(real)
      : Object.hash(_doubleHash(real), _doubleHash(imag));

  @override
  String toString() => 'MontyComplex($real, $imag)';

  /// Each part in [MontyFloat]'s form, so NaN, the infinities and `-0.0`
  /// survive.
  @override
  Map<String, Object?> _toJson() => {
    '__type': 'complex',
    'real': MontyFloat(real)._toJson(),
    'imag': MontyFloat(imag)._toJson(),
  };
}

/// Represents a Python `str` value.
@immutable
final class MontyString extends MontyValue {
  /// Creates a [MontyString] with the given [value].
  const MontyString(this.value);

  /// The underlying string value.
  final String value;

  @override
  String get dartValue => value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is MontyString && other.value == value);

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'MontyString($value)';

  @override
  String _toJson() => value;
}

/// Represents a Python `int` too large for a Dart `int` (i.e. beyond i64).
///
/// Python integers are unbounded; JSON numbers and Dart `int`s are not. Such a
/// value travels as `{"__type": "bigint", "value": "<digits>"}` — the digits as
/// text, because no JSON number can hold them — and arrives here as an exact
/// [BigInt].
///
/// Before wire format v2 it arrived as a [MontyString], so a value's Dart TYPE
/// depended on its MAGNITUDE: `2**62` was a [MontyInt] and `2**63` was a string
/// (core#134). Nothing in the type system hinted that the boundary existed.
///
/// Note this variant only appears BEYOND the i64 range. Values that fit stay
/// [MontyInt], because widening every integer to [BigInt] would cost every
/// consumer an unwrap for a case that almost never occurs.
@immutable
final class MontyBigInt extends MontyValue {
  /// Creates a [MontyBigInt] with the given [value].
  const MontyBigInt(this.value);

  /// The exact integer value.
  final BigInt value;

  @override
  BigInt get dartValue => value;

  /// Python's numeric `==`; see [MontyInt.==]. Python has one int type, so
  /// a [MontyBigInt] equals the [MontyInt] of the same integer.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyBigInt ? other.value == value : _numEquals(this, other));

  @override
  int get hashCode => _bigHash(value);

  @override
  String toString() => 'MontyBigInt($value)';

  @override
  Map<String, Object?> _toJson() => {
    '__type': 'bigint',
    'value': value.toString(),
  };
}

/// Represents a Python exception object travelling as a VALUE.
///
/// Not to be confused with `MontyError`, which this package THROWS when fed
/// code fails. This is what you get when Python hands an exception back as
/// data — `return ValueError("boom")`, or an
/// exception caught and returned.
///
/// [attributes] carries upstream's structured data for a Unicode or JSON
/// decode error (`encoding`, `object`, `start`, `end`, `reason`; `msg`,
/// `doc`, `pos`, `lineno`, `colno`); it is empty for every other exception.
@immutable
final class MontyExceptionValue extends MontyValue {
  /// An exception of type [excType] with [message] and [attributes].
  ///
  /// Each attribute value is a leaf, a `str`, `bytes` or `int`, as upstream's
  /// attributes are; a container throws [ArgumentError]. [attributes] is
  /// copied, and the copy cannot be modified.
  MontyExceptionValue(
    this.excType, [
    this.message,
    Map<String, MontyValue> attributes = const {},
  ]) : attributes = _leafAttributes(attributes);

  /// The Python exception class name, e.g. `'ValueError'`.
  final String excType;

  /// The exception's argument, when it has one.
  final String? message;

  /// The exception's structured attributes by name, unmodifiable.
  final Map<String, MontyValue> attributes;

  @override
  Map<String, Object?> get dartValue => _toJson();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyExceptionValue &&
          other.excType == excType &&
          other.message == message &&
          _sameAttributes(attributes, other.attributes));

  @override
  int get hashCode => attributes.isEmpty
      ? Object.hash(excType, message)
      : Object.hash(excType, message, _attributesHash(attributes));

  @override
  String toString() =>
      'MontyExceptionValue($excType${message == null ? '' : ': $message'})';

  @override
  Map<String, Object?> _toJson() => {
    '__type': 'exception',
    'exc_type': excType,
    'message': message,
  };
}

/// [attributes] as an unmodifiable copy; throws [ArgumentError] for a value
/// that is not a leaf.
Map<String, MontyValue> _leafAttributes(Map<String, MontyValue> attributes) {
  if (attributes.isEmpty) return const {};
  for (final MapEntry(:key, :value) in attributes.entries) {
    final leaf =
        value is MontyString ||
        value is MontyBytes ||
        value is MontyInt ||
        value is MontyBigInt;
    if (!leaf) {
      throw ArgumentError.value(
        value,
        key,
        'an exception attribute is a str, bytes or int',
      );
    }
  }

  return Map.unmodifiable(attributes);
}

/// Whether two exceptions' attributes hold the same keys with equal values.
/// The values are leaves (_leafAttributes), compared by their own
/// rules, so `MontyInt(1)` equals `MontyBigInt(1)` here too.
bool _sameAttributes(Map<String, MontyValue> a, Map<String, MontyValue> b) {
  if (a.length != b.length) return false;
  for (final MapEntry(:key, :value) in a.entries) {
    final other = b[key];
    if (other == null || other != value) return false;
  }

  return true;
}

/// A hash of [attributes] that does not depend on their order, as
/// [_sameAttributes] does not.
int _attributesHash(Map<String, MontyValue> attributes) {
  var h = 0;
  for (final MapEntry(:key, :value) in attributes.entries) {
    h = (h + Object.hash(key, value)) & _hashMask;
  }

  return h;
}

// ---------------------------------------------------------------------------
// The numeric tower
// ---------------------------------------------------------------------------

/// Two doubles as [MontyFloat] compares them: by value, NaN equal to NaN.
bool _floatEquals(double a, double b) => a == b || (a.isNaN && b.isNaN);

/// [v] as a Python number: its real part (a [BigInt] for an integer type, a
/// double for a float or complex) and its imaginary part; null for a value
/// that is not a number.
(Object, double)? _number(Object v) => switch (v) {
  MontyBool(:final value) => (value ? BigInt.one : BigInt.zero, 0.0),
  MontyInt(:final value) => (BigInt.from(value), 0.0),
  MontyBigInt(:final value) => (value, 0.0),
  MontyFloat(:final value) => (value, 0.0),
  MontyComplex(:final real, :final imag) => (real, imag),
  _ => null,
};

/// Python's `==` between two numbers of different classes: the imaginary
/// parts as floats, then the real parts exactly, an integer against a float
/// never by converting the integer to a double.
bool _numEquals(Object a, Object b) {
  final x = _number(a);
  final y = _number(b);
  if (x == null || y == null || !_floatEquals(x.$2, y.$2)) return false;

  return switch ((x.$1, y.$1)) {
    (final BigInt i, final BigInt j) => i == j,
    (final double d, final double e) => _floatEquals(d, e),
    (final BigInt i, final double d) ||
    (final double d, final BigInt i) => _intEqualsDouble(i, d),
    _ => false,
  };
}

/// Whether [d] is exactly the integer [i].
bool _intEqualsDouble(BigInt i, double d) =>
    d.isFinite && d == d.truncateToDouble() && BigInt.from(d) == i;

/// The largest magnitude whose hash is an `int`'s on every compiler.
const int _maxSafeInt = 9007199254740992; // 2^53

/// The hash of the integer [v]: an `int`'s within ±2^53, a [BigInt]'s
/// beyond, on every compiler (on dart2js an `int` beyond 2^53 is a double).
int _intHash(int v) =>
    v > _maxSafeInt || v < -_maxSafeInt ? BigInt.from(v).hashCode : v.hashCode;

/// The hash of the integer [v], as [_intHash] gives it.
int _bigHash(BigInt v) =>
    v.bitLength <= 53 || v.abs() == BigInt.from(_maxSafeInt)
    ? v.toInt().hashCode
    : v.hashCode;

/// The hash of [d]: an integral value's as its integer's, NaN one constant.
int _doubleHash(double d) {
  if (d.isNaN) return 0x7FF80000;
  if (d.isInfinite || d != d.truncateToDouble()) return d.hashCode;
  if (d.abs() <= _maxSafeInt) return _intHash(d.toInt());

  return BigInt.from(d).hashCode;
}

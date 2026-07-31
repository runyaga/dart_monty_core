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
  Null toJson() => null;

  @override
  Null get dartValue => null;

  @override
  bool operator ==(Object other) => other is MontyNone;

  @override
  int get hashCode => null.hashCode;

  @override
  String toString() => 'MontyNone()';
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
  bool toJson() => value;

  @override
  bool get dartValue => value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is MontyBool && other.value == value);

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'MontyBool($value)';
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
  Object toJson() {
    final big = BigInt.from(value);
    if (big.abs() > _exactIntLimit) {
      return {'__type': 'bigint', 'value': big.toString()};
    }

    return value;
  }

  @override
  int get dartValue => value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is MontyInt && other.value == value);

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'MontyInt($value)';
}

/// Represents a Python `float` value (including NaN and infinities).
@immutable
final class MontyFloat extends MontyValue {
  /// Creates a [MontyFloat] with the given [value].
  const MontyFloat(this.value);

  /// The underlying double value.
  final double value;

  @override
  Object toJson() {
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

  @override
  double get dartValue => value;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! MontyFloat) return false;
    if (value.isNaN && other.value.isNaN) return true;

    return value == other.value;
  }

  @override
  int get hashCode => value.isNaN ? 0x7FF80000 : value.hashCode;

  @override
  String toString() => 'MontyFloat($value)';

  static Map<String, Object?> _tagged(String text) => {
    '__type': 'float',
    'value': text,
  };

  /// Renders so the type and the sign survive: `4.0`, not `4`; `-0.0`, not `0`.
  static String _exactText(double v) {
    if (v == 0 && v.isNegative) return '-0.0';

    final text = '$v';
    // On dart2js `int` and `double` are one type, so `'${4.0}'` is `"4"` — the
    // same int/float collapse this envelope exists to prevent, appearing in
    // Dart's own rendering. Without this the web would emit
    // {"__type":"float","value":"4"}: still decoded as a float because the TAG
    // carries the type, but the text would disagree with what the Rust encoder
    // writes for the identical value, and the two sides must agree byte for
    // byte or the differential is comparing different things.
    if (!text.contains('.') && !text.contains('e')) return '$text.0';

    return text;
  }
}

/// Represents a Python `str` value.
@immutable
final class MontyString extends MontyValue {
  /// Creates a [MontyString] with the given [value].
  const MontyString(this.value);

  /// The underlying string value.
  final String value;

  @override
  String toJson() => value;

  @override
  String get dartValue => value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is MontyString && other.value == value);

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'MontyString($value)';
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

  factory MontyBigInt._fromMap(Map<String, dynamic> map) {
    final raw = map['value'];
    final parsed = raw is String ? BigInt.tryParse(raw) : null;
    if (parsed == null) {
      throw FormatException(
        'a bigint envelope needs base-10 digits as a string under "value"; '
        'got ${raw.runtimeType}',
        json.encode(map),
      );
    }

    return MontyBigInt(parsed);
  }

  /// The exact integer value.
  final BigInt value;

  @override
  Map<String, Object?> toJson() => {
    '__type': 'bigint',
    'value': value.toString(),
  };

  @override
  BigInt get dartValue => value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is MontyBigInt && other.value == value);

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'MontyBigInt($value)';
}

/// Represents a Python exception object travelling as a VALUE.
///
/// Not to be confused with `MontyException`, which is the Dart exception this
/// package THROWS when the interpreter fails. This is what you get when Python
/// hands an exception back as data — `return ValueError("boom")`, or an
/// exception caught and returned.
///
/// It travels as `{"__type": "exception", "exc_type": "ValueError",
/// "message": "boom"}`. Before wire format v2 it was the bare string
/// `"ValueError: boom"` — **byte-identical to the Python string of the same
/// text**, so nothing downstream could tell an exception from prose describing
/// one. Joining the two halves with `": "` was also unrecoverable whenever the
/// message itself contained `": "`.
@immutable
final class MontyExceptionValue extends MontyValue {
  /// Creates a [MontyExceptionValue].
  const MontyExceptionValue({required this.excType, this.message});

  factory MontyExceptionValue._fromMap(Map<String, dynamic> map) =>
      MontyExceptionValue(
        excType: map['exc_type'] as String? ?? '',
        message: map['message'] as String?,
      );

  /// The Python exception class name, e.g. `'ValueError'`.
  final String excType;

  /// The exception's argument, when it has one.
  final String? message;

  @override
  Map<String, Object?> toJson() => {
    '__type': 'exception',
    'exc_type': excType,
    'message': message,
  };

  @override
  Map<String, Object?> get dartValue => toJson();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyExceptionValue &&
          other.excType == excType &&
          other.message == message);

  @override
  int get hashCode => Object.hash(excType, message);

  @override
  String toString() =>
      'MontyExceptionValue($excType${message == null ? '' : ': $message'})';
}

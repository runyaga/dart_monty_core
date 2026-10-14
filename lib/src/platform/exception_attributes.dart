/// The attributes of a [MontyExceptionValue]: upstream's structured data
/// for a Unicode or JSON decode error (`encoding`, `object`, `start`, `end`,
/// `reason`; `msg`, `doc`, `pos`, `lineno`, `colno`).
///
/// The cutover makes them a public `attributes` field; until then they are
/// attached here, so the public class keeps its members. They take part in
/// the value's `==`, `hashCode` and in the value walk's budget.
///
/// Internal to the package; nothing here is exported.
library;

import 'package:dart_monty_core/src/platform/monty_value.dart';

final Expando<Map<String, MontyValue>> _attributes = Expando('attributes');

const Map<String, MontyValue> _none = {};

/// An exception value of type [excType] with [message] and [attributes].
///
/// Each attribute value is a leaf: a string, bytes or an integer, as
/// upstream's attributes are. Throws [ArgumentError] for a container.
MontyExceptionValue exceptionWithAttributes({
  required String excType,
  String? message,
  Map<String, MontyValue> attributes = _none,
}) {
  // A new instance, never a canonical const one: the attributes are
  // attached to it.
  final exception = MontyExceptionValue(excType: excType, message: message);
  if (attributes.isEmpty) return exception;
  for (final MapEntry(:key, :value) in attributes.entries) {
    if (!_isLeaf(value)) {
      throw ArgumentError.value(
        value,
        key,
        'an exception attribute is a str, bytes or int',
      );
    }
  }
  _attributes[exception] = Map.unmodifiable(attributes);

  return exception;
}

/// [exception]'s attributes; empty for one built without them.
Map<String, MontyValue> exceptionAttributes(MontyExceptionValue exception) =>
    _attributes[exception] ?? _none;

bool _isLeaf(MontyValue value) =>
    value is MontyString ||
    value is MontyBytes ||
    value is MontyInt ||
    value is MontyBigInt;

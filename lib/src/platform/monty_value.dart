import 'dart:async';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:dart_monty_core/src/platform/double_text.dart';
import 'package:dart_monty_core/src/platform/value_graph_budget.dart';
import 'package:dart_monty_core/src/worker/monty_snapshot.dart'
    show ExternalException;
import 'package:dart_monty_core/src/worker/python_rules.dart'
    show hasUnpairedSurrogate, parseFileMode, purePosixPath, pythonRepr;
import 'package:meta/meta.dart';

part 'monty_value_scalars.dart';
part 'monty_value_collections.dart';
part 'monty_value_datetime.dart';
part 'monty_value_structured.dart';
part 'monty_value_graph.dart';
part 'monty_value_host.dart';

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
///
/// Equality is Python's: the numeric classes ([MontyBool], [MontyInt],
/// [MontyBigInt], [MontyFloat], [MontyComplex]) compare and hash as Python's
/// numbers do, so `MontyBool(true) == MontyInt(1)`.
sealed class MontyValue {
  const MontyValue();

  /// Converts a native Dart value into the appropriate [MontyValue] subclass.
  ///
  /// Handles:
  /// - `MontyValue` instances (passed through)
  /// - `null`, `bool`, `int`, `double`, `String`
  /// - `DateTime` (→ an aware [MontyDateTime] at its instant, to the
  ///   microsecond, with its UTC offset: zero for a UTC `DateTime`)
  /// - `List` (elements recursively converted)
  /// - `Map` (keys and values recursively converted)
  ///
  /// `-0.0` and the infinities become [MontyFloat] on every backend. Other
  /// integral doubles are ambiguous on dart2js, where they pass `is int`;
  /// pass a [MontyFloat] when the type matters there.
  ///
  /// The conversion does not recurse, so nesting depth is not limited by the
  /// stack. A `List` or `Map` reached twice becomes one value, shared in the
  /// result; one that contains itself is an [ArgumentError].
  factory MontyValue.fromDart(Object? value) =>
      _MontyValueGraph.fromDart(value);

  /// This value as tagged JSON-shaped Dart data; internal, read through
  /// [MontyValueInternal.toJson].
  Object? _toJson();

  /// Returns the underlying Dart value for easy migration.
  ///
  /// Scalars return their primitive (`int`, `double`, `String`, etc.).
  /// Collections recursively unwrap to `List<Object?>` / `Map<String, Object?>`.
  /// Typed wrappers return a tagged map.
  Object? get dartValue;

  /// What the identity-aware walk treats this value as. Containers and
  /// fixed-size leaves override it; MontyDict, at its method-count limit, is
  /// recognised here instead.
  int get _graphKind => this is MontyDict ? _kDict : _kPayload;
}

/// [MontyValue]'s internal members (pass-3 G2): the tagged JSON-shaped
/// projection the package's own tests and tools read. The public libraries'
/// `show` lists leave this extension out.
extension MontyValueInternal on MontyValue {
  /// This value as tagged JSON-shaped Dart data.
  Object? toJson() => _toJson();
}

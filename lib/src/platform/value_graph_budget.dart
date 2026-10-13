/// The budget of the recursive fast path behind `MontyValue`'s `==`,
/// `hashCode`, `toJson` and `dartValue`.
///
/// Internal: not exported. Tests run code under a different budget so that
/// the fast path and the memoised fallback each run on the same values.
library;

import 'dart:async';

import 'package:meta/meta.dart';

/// Limits for the recursive walk, and a count of how often it gave up.
///
/// The walk recurses while it stays within [maxDepth] levels and [maxVisits]
/// visits. Past either limit it restarts as a memoised walk on an explicit
/// stack, which is linear in distinct nodes and cannot overflow the stack.
///
/// The defaults apply everywhere except inside [run], which installs this
/// budget for the code it runs.
@internal
final class ValueGraphBudget {
  /// A budget with the given limits.
  ValueGraphBudget({
    this.maxDepth = defaultMaxDepth,
    this.maxVisits = defaultMaxVisits,
  });

  /// The default depth limit. dart2js overflowed the old recursion at 2,000.
  static const int defaultMaxDepth = 400;

  /// The default visit limit, 2^22.
  static const int defaultMaxVisits = 1 << 22;

  /// The depth limit.
  final int maxDepth;

  /// The visit limit.
  final int maxVisits;

  static const Symbol _zoneKey = #dart_monty_core.valueGraphBudget;

  int _fallbacks = 0;

  /// How many walks under this budget fell back to the memoised walk.
  int get fallbacks => _fallbacks;

  /// The budget installed by an enclosing [run], or null for the defaults.
  static ValueGraphBudget? get current =>
      Zone.current[_zoneKey] as ValueGraphBudget?;

  /// Runs [body] with this budget in force.
  R run<R>(R Function() body) => runZoned(body, zoneValues: {_zoneKey: this});

  /// Counts one fallback.
  void recordFallback() => _fallbacks++;
}

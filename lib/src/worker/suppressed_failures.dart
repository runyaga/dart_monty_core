/// Package-internal bounded sink of suppressed cleanup and startup failures.
///
/// Retains `(error, stack, stage)` records when cancellation, close, kill, or
/// losing sibling startup failures are suppressed so the primary failure can
/// propagate unmasked.
///
/// Internal to the package; nothing here is exported.
library;

import 'dart:collection';

import 'package:meta/meta.dart';

/// One suppressed cleanup or startup failure record.
typedef SuppressedFailure = (Object error, StackTrace stack, String stage);

/// Bounded isolate-local sink of [SuppressedFailure] records.
abstract final class SuppressedFailures {
  /// Maximum number of retained [SuppressedFailure] records before oldest
  /// entries are evicted.
  static const int capacity = 256;

  /// Snapshot of currently retained failures in recording order.
  static List<SuppressedFailure> get entries =>
      List<SuppressedFailure>.unmodifiable(_sink.entries);

  /// Monotonic count of records evicted after reaching [capacity].
  static int get droppedCount => _sink.droppedCount;

  /// Records a suppressed [error] and [stack] at [stage].
  static void record(Object error, StackTrace stack, String stage) =>
      _sink.record(error, stack, stage);

  /// Clears retained entries and resets [droppedCount] for isolated tests.
  @visibleForTesting
  static void clear() => _sink.clear();
}

/// Named accessors on [SuppressedFailure] positional records.
extension SuppressedFailureFields on SuppressedFailure {
  /// The suppressed error object.
  Object get error => $1;

  /// The stack trace captured with [error].
  StackTrace get stack => $2;

  /// The cleanup or startup stage where [error] was suppressed.
  String get stage => $3;
}

final _sink = _SuppressedFailureSink();

final class _SuppressedFailureSink {
  final Queue<SuppressedFailure> entries = Queue<SuppressedFailure>();
  int droppedCount = 0;

  void record(Object error, StackTrace stack, String stage) {
    if (entries.length >= SuppressedFailures.capacity) {
      entries.removeFirst();
      droppedCount++;
    }
    entries.addLast((error, stack, stage));
  }

  void clear() {
    entries.clear();
    droppedCount = 0;
  }
}

import 'package:meta/meta.dart';

/// Resource usage statistics from a Monty Python execution.
///
/// Tracks [memoryBytesUsed], [timeElapsedMs], and [stackDepthUsed] to help
/// callers monitor and budget sandbox resources.
@immutable
final class MontyResourceUsage {
  /// Creates a [MontyResourceUsage] with the given resource metrics.
  const MontyResourceUsage({
    required this.memoryBytesUsed,
    required this.timeElapsedMs,
    required this.stackDepthUsed,
  });

  /// Creates a [MontyResourceUsage] from a JSON map.
  ///
  /// Expected keys: `memory_bytes_used`, `time_elapsed_ms`,
  /// `stack_depth_used`.
  factory MontyResourceUsage.fromJson(Map<String, dynamic> json) {
    return MontyResourceUsage(
      memoryBytesUsed: json['memory_bytes_used'] as int,
      timeElapsedMs: json['time_elapsed_ms'] as int,
      stackDepthUsed: json['stack_depth_used'] as int,
    );
  }

  /// Always `0` — memory use is not observable in monty v0.0.23.
  ///
  /// This is an upstream limit, not a shortcut here. `ResourceTracker` exposes
  /// `elapsed()` and nothing else of this kind: there is no accessor for memory
  /// used or recursion depth used, only the configured MAXIMA (`max_memory`,
  /// `max_duration`). Every site that builds this struct writes a literal `0`
  /// (`native/src/handle.rs`, `native/src/repl_handle.rs`), and zeroing a field
  /// the host genuinely cannot observe is the honest option.
  ///
  /// Do not use this to impose your own memory ceiling — it will read `0` even
  /// on a run that breached `MontyLimits.memoryBytes`. Tracked in core#155.
  final int memoryBytesUsed;

  /// The wall-clock time elapsed in milliseconds.
  final int timeElapsedMs;

  /// The maximum stack depth reached during execution.
  final int stackDepthUsed;

  /// Serializes this resource usage to a JSON-compatible map.
  Map<String, dynamic> toJson() {
    return {
      'memory_bytes_used': memoryBytesUsed,
      'time_elapsed_ms': timeElapsedMs,
      'stack_depth_used': stackDepthUsed,
    };
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is MontyResourceUsage &&
            other.memoryBytesUsed == memoryBytesUsed &&
            other.timeElapsedMs == timeElapsedMs &&
            other.stackDepthUsed == stackDepthUsed);
  }

  @override
  int get hashCode =>
      Object.hash(memoryBytesUsed, timeElapsedMs, stackDepthUsed);

  @override
  String toString() {
    return 'MontyResourceUsage('
        'memoryBytesUsed: $memoryBytesUsed, '
        'timeElapsedMs: $timeElapsedMs, '
        'stackDepthUsed: $stackDepthUsed)';
  }
}

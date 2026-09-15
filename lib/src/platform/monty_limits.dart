import 'package:meta/meta.dart';

/// Resource limits to impose on a Monty Python execution.
///
/// All fields are optional — omitted limits are unconstrained.
@immutable
final class MontyLimits {
  /// Creates a [MontyLimits] with optional resource constraints.
  const MontyLimits({this.memoryBytes, this.timeoutMs, this.stackDepth});

  /// Creates a [MontyLimits] from a JSON map.
  ///
  /// Expected keys: `memory_bytes`, `timeout_ms`, `stack_depth`.
  factory MontyLimits.fromJson(Map<String, dynamic> json) {
    return MontyLimits(
      memoryBytes: json['memory_bytes'] as int?,
      timeoutMs: json['timeout_ms'] as int?,
      stackDepth: json['stack_depth'] as int?,
    );
  }

  /// Creates limits using the same field names as the JS `@pydantic/monty`
  /// SDK.
  ///
  /// ```dart
  /// // JS: { maxMemory: 1_000_000, maxDurationSecs: 5, maxRecursionDepth: 200 }
  /// MontyLimits.jsAligned(
  ///   maxMemory: 1000000,
  ///   maxDurationSecs: 5,
  ///   maxRecursionDepth: 200,
  /// )
  /// ```
  ///
  /// Note: `maxAllocations` and `gcInterval` from the JS SDK are not
  /// supported in the current Rust engine and have no Dart equivalent.
  factory MontyLimits.jsAligned({
    int? maxMemory,
    double? maxDurationSecs,
    int? maxRecursionDepth,
  }) => MontyLimits(
    memoryBytes: maxMemory,
    timeoutMs: maxDurationSecs != null
        ? (maxDurationSecs * 1000).round()
        : null,
    stackDepth: maxRecursionDepth,
  );

  /// Maximum size of a SINGLE object allocation in bytes, or `null` for
  /// unlimited.
  ///
  /// **This is not a heap ceiling, and the distinction is security-relevant.**
  /// It bounds how large one object may become. It does NOT bound the total
  /// memory a program accumulates across many small objects.
  ///
  /// Measured on the FFI backend, every case under the SAME
  /// `MontyLimits(memoryBytes: 100 * 1024)` — a 100 KB cap:
  ///
  /// CAUGHT (one object, ~20 MB each):
  /// - `b"a" * 20971520`
  /// - `"y" * 20971520`
  /// - `s = ""` then `s += "y" * 100000` ×200
  ///
  /// NOT caught (many small objects):
  /// - `a = []` then `a.append("y"*100 + str(i))` ×200,000 — ~20 MB
  /// - the same ×3,000,000 — **~314 MB**, no error
  ///
  /// The third row is the control that makes the rule precise: it allocates
  /// incrementally but concatenates into one growing object, and it IS caught.
  /// So the discriminator is the size of an individual object, not whether
  /// allocation happens incrementally.
  ///
  /// If you are sandboxing untrusted code and need a ceiling on TOTAL memory,
  /// this field does not give you one, and neither does
  /// `MontyResourceUsage.memoryBytesUsed`, which is always zero. Bound the
  /// process instead. Tracked in core#160.
  final int? memoryBytes;

  /// Maximum execution time in milliseconds, or `null` for unlimited.
  final int? timeoutMs;

  /// Maximum call stack depth, or `null` for unlimited.
  final int? stackDepth;

  /// Serializes this limits configuration to a JSON-compatible map.
  Map<String, dynamic> toJson() {
    return {
      if (memoryBytes != null) 'memory_bytes': memoryBytes,
      if (timeoutMs != null) 'timeout_ms': timeoutMs,
      if (stackDepth != null) 'stack_depth': stackDepth,
    };
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is MontyLimits &&
            other.memoryBytes == memoryBytes &&
            other.timeoutMs == timeoutMs &&
            other.stackDepth == stackDepth);
  }

  @override
  int get hashCode => Object.hash(memoryBytes, timeoutMs, stackDepth);

  @override
  String toString() {
    return 'MontyLimits('
        'memoryBytes: $memoryBytes, '
        'timeoutMs: $timeoutMs, '
        'stackDepth: $stackDepth)';
  }
}

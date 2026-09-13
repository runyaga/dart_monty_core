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

  /// Maximum memory in bytes, or `null` for unlimited.
  final int? memoryBytes;

  /// Maximum execution time in milliseconds, or `null` for unlimited.
  final int? timeoutMs;

  /// Maximum call stack depth, or `null` for unlimited.
  final int? stackDepth;

  /// The deepest recursion this binding can survive, MEASURED.
  ///
  /// This is not a policy number, it is a physical one. Monty's recursion
  /// guard is a COUNTER: it raises `RecursionError` when the interpreter has
  /// nested [stackDepth] frames. Reaching that counter costs real native
  /// stack, and an FFI call runs on a Dart isolate's thread — not a process
  /// main thread — so it has far less stack than monty gets in upstream's own
  /// embedding, which runs the engine in subprocess workers.
  ///
  /// If the limit is set higher than the stack can sustain, the stack
  /// overflows BEFORE the counter trips and the HOST PROCESS SEGFAULTS. There
  /// is no exception to catch: the process is gone. That is the failure mode
  /// this constant exists to prevent, and it is why the value is not simply
  /// CPython's 1000.
  ///
  /// Measured on linux/arm64, monty v0.0.23, by bisecting the crash point of
  /// each recursion shape (`<= safe` / `>= SIGSEGV`):
  ///
  ///     cyclic dict == dict     534 / 539     <-- worst case, sets this bound
  ///     cyclic deque == deque   765 / 781
  ///     cyclic list, deep repr, deep hash     >= 765
  ///     deep Python frames (many locals)      >= 765
  ///
  /// Cost per frame is NOT uniform — a cyclic dict comparison burns far more
  /// native stack per level than a Python call frame does, so the safe default
  /// is the minimum across shapes, not the typical one.
  ///
  /// 512 sits below the worst measured ceiling of 534. That is a thin margin,
  /// and the measurements above are arm64; CI runs amd64, where frame sizes
  /// differ. `test/integration/ffi_recursion_ceiling_test.dart` re-measures
  /// the worst shapes on whatever platform it runs on and FAILS if this value
  /// is no longer safe there, rather than leaving it to be discovered as a
  /// segfault.
  static const int defaultStackDepth = 512;

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

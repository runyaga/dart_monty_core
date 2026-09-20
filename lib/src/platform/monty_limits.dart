import 'package:meta/meta.dart';

/// Resource limits to impose on a Monty Python execution.
///
/// Engine-enforced fields are optional and omitted ones are unconstrained.
/// [maxSuspensions] is the exception, and deliberately so — see its doc.
@immutable
final class MontyLimits {
  /// Creates a [MontyLimits] with optional resource constraints.
  const MontyLimits({
    this.memoryBytes,
    this.timeoutMs,
    this.stackDepth,
    this.maxSuspensions,
  });

  /// Creates a [MontyLimits] from a JSON map.
  ///
  /// Expected keys: `memory_bytes`, `timeout_ms`, `stack_depth`,
  /// `max_suspensions`.
  factory MontyLimits.fromJson(Map<String, dynamic> json) {
    return MontyLimits(
      memoryBytes: json['memory_bytes'] as int?,
      timeoutMs: json['timeout_ms'] as int?,
      stackDepth: json['stack_depth'] as int?,
      maxSuspensions: json['max_suspensions'] as int?,
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

  /// Suspension budget applied when [maxSuspensions] is omitted. Matches
  /// upstream's pool default.
  static const int defaultMaxSuspensions = 1000;

  /// Pass as [maxSuspensions] to opt out of the budget. Distinct from
  /// omitting it, which applies [defaultMaxSuspensions].
  static const int unlimitedSuspensions = -1;

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

  /// Maximum suspensions the sandbox may raise for the host to answer, across
  /// the whole session. `null` applies [defaultMaxSuspensions];
  /// [unlimitedSuspensions] removes the bound; `0` refuses the first
  /// suspension while still permitting work that never suspends.
  ///
  /// Enforced by the HOST, not the engine — [timeoutMs] bounds interpreter
  /// time, and a suspension spends its time in Dart. Needs no backend support,
  /// so it applies on web too (core#156).
  final int? maxSuspensions;

  /// Whether anything here is for the ENGINE to enforce. [maxSuspensions] is
  /// host-side, so a caller setting only it asks nothing of the backend — and
  /// a backend that refuses session limits (core#140) must not refuse it.
  bool get hasEngineLimits =>
      memoryBytes != null || timeoutMs != null || stackDepth != null;

  /// Serializes this limits configuration to a JSON-compatible map.
  Map<String, dynamic> toJson() {
    return {
      if (memoryBytes != null) 'memory_bytes': memoryBytes,
      if (timeoutMs != null) 'timeout_ms': timeoutMs,
      if (stackDepth != null) 'stack_depth': stackDepth,
      if (maxSuspensions != null) 'max_suspensions': maxSuspensions,
    };
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is MontyLimits &&
            other.memoryBytes == memoryBytes &&
            other.timeoutMs == timeoutMs &&
            other.stackDepth == stackDepth &&
            other.maxSuspensions == maxSuspensions);
  }

  @override
  int get hashCode =>
      Object.hash(memoryBytes, timeoutMs, stackDepth, maxSuspensions);

  @override
  String toString() {
    return 'MontyLimits('
        'memoryBytes: $memoryBytes, '
        'timeoutMs: $timeoutMs, '
        'stackDepth: $stackDepth, '
        'maxSuspensions: $maxSuspensions)';
  }
}

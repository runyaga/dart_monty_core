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

  /// The suspension budget applied when [maxSuspensions] is omitted.
  ///
  /// Matches the default upstream's pool applies (`monty-pool`), measured
  /// against `pydantic-monty` 0.0.23: a run with NO limits configured at all
  /// stops after 1000 host callbacks with
  /// `RuntimeError: suspension limit 1000 exceeded`.
  static const int defaultMaxSuspensions = 1000;

  /// Pass as [maxSuspensions] to opt OUT of the budget entirely.
  ///
  /// Distinct from omitting the field, which applies
  /// [defaultMaxSuspensions]. Unbounded host-driven execution is what
  /// core#156 is about, so it has to be asked for by name.
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

  /// Maximum number of suspensions the sandbox may raise for the host to
  /// answer, across the whole session. `null` applies
  /// [defaultMaxSuspensions]; [unlimitedSuspensions] removes the bound; `0`
  /// permits computation that completes without ever suspending, and refuses
  /// the first suspension.
  ///
  /// ENFORCED BY THE HOST, NOT THE ENGINE, and that is why it is the one
  /// field whose omission is not "unconstrained". The engine bounds
  /// INTERPRETER time; every suspension hands control to Dart, and host time
  /// is not interpreter time, so a script calling an external function in a
  /// loop never accumulates enough interpreter time to trip [timeoutMs].
  /// Measured (core#156): 1,975,000 callbacks in 2,492ms against a 500ms
  /// `timeoutMs` — and it ended because the probe gave up.
  ///
  /// Upstream reaches the same guarantee from `monty-pool`, which this
  /// package does not depend on: `native/Cargo.toml` pins `monty` and
  /// `monty-type-checking` only. The budget is the PARENT's job, and this is
  /// the parent.
  ///
  /// Being host-side, it needs no backend support — it applies identically on
  /// FFI and on the web, including where session limits are refused (#140).
  ///
  /// COUNTED PER SESSION, not per feed: the count accumulates across
  /// `feedRun`/`feedStart` on one `MontyRepl`, matching upstream, where two
  /// feeds of four callbacks under a budget of six trip during the second.
  final int? maxSuspensions;

  /// Whether anything here is for the ENGINE to enforce.
  ///
  /// [maxSuspensions] is host-side and deliberately excluded. A caller who
  /// sets only the suspension budget is asking nothing of the backend, so
  /// nothing should be sent to it — and a backend that refuses session limits
  /// (the web REPL, core#140) must not refuse a limit it was never asked to
  /// apply. Measured before this existed: five of six suspension-budget tests
  /// failed on dart2js with
  /// `UnsupportedError: Session-scoped resource limits are not supported`,
  /// for a bound the engine has no part in.
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

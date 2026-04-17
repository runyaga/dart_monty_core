// 09 — Resource limits, code capture utilities
//
// MontyLimits constrains memory, CPU time, and stack depth.
// code_capture utilities help build REPL tooling on top of MontyRepl.
//
// Covers: MontyLimits, MontyLimits.jsAligned, MontyResourceUsage,
//         isExpression, captureLastExpression, extractAssignmentTargets.
//
// Run: dart run example/09_limits_and_code_capture.dart

import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  await _limits();
  _codeCaptureUtilities();
}

// ── MontyLimits ───────────────────────────────────────────────────────────────
// Apply per-call resource constraints. null means unlimited.
Future<void> _limits() async {
  print('\n── MontyLimits ──');

  // ── timeoutMs ───────────────────────────────────────────────────────────────
  try {
    await Monty.exec(
      'i = 0\nwhile True: i += 1',
      limits: MontyLimits(timeoutMs: 50),
    );
  } on MontyResourceError catch (e) {
    print('timeout: ${e.message}');
  }

  // ── stackDepth ──────────────────────────────────────────────────────────────
  try {
    await Monty.exec(
      'def f(n): return f(n+1)\nf(0)',
      limits: MontyLimits(stackDepth: 10),
    );
  } on MontyResourceError catch (e) {
    print('stack: ${e.message}');
  }

  // ── memoryBytes ─────────────────────────────────────────────────────────────
  try {
    // Allocate a very large list — should trigger OOM with tight memory limit.
    await Monty.exec(
      'x = [0] * 10_000_000',
      limits: MontyLimits(memoryBytes: 1024 * 1024), // 1 MB
    );
  } on MontyResourceError catch (e) {
    print('memory: ${e.message}');
  }

  // ── MontyLimits.jsAligned ────────────────────────────────────────────────────
  // Accepts the JavaScript SDK field names — useful when reading limits from
  // a JS config or if migrating from a JS-adjacent API.
  final limits = MontyLimits.jsAligned(
    maxMemory: 64 * 1024 * 1024,  // 64 MB
    maxDurationSecs: 5.0,
    maxRecursionDepth: 500,
  );
  print('jsAligned: memory=${limits.memoryBytes}  timeout=${limits.timeoutMs}ms  stack=${limits.stackDepth}');

  // ── MontyResourceUsage ───────────────────────────────────────────────────────
  final r = await Monty.exec('[i**2 for i in range(1000)]');
  print('usage:');
  print('  memory: ${r.usage.memoryBytesUsed} bytes');
  print('  time:   ${r.usage.timeElapsedMs} ms');
  print('  stack:  ${r.usage.stackDepthUsed}');

  // JSON round-trip (useful for logging / telemetry).
  final usageJson = r.usage.toJson();
  final usage2 = MontyResourceUsage.fromJson(usageJson);
  print('  json round-trip ok: ${usage2.memoryBytesUsed == r.usage.memoryBytesUsed}');
}

// ── code_capture utilities ────────────────────────────────────────────────────
// Helper functions exported from dart_monty_core for building REPL tooling.
void _codeCaptureUtilities() {
  print('\n── code_capture utilities ──');

  // isExpression() — true for expressions, false for statements.
  // MontyRepl.detectContinuation() is the right tool for REPL prompts;
  // isExpression() is useful for deciding whether to capture a return value.
  for (final line in [
    '1 + 1',           // expression
    'x = 5',           // statement (assignment)
    'def f(): pass',   // statement (function def)
    '"hello"',         // expression
    'import os',       // statement
    'print("hi")',     // expression (call)
  ]) {
    print('isExpression("$line"): ${isExpression(line)}');
  }

  print('');

  // captureLastExpression() — wraps trailing expression as __r = (expr).
  // Useful for REPL-style display: user types `x + 1` and you capture the value.
  final cases = [
    'x = 5\nx + 1',          // last line is expression — captured
    'def f():\n  return 42', // last line is statement — not captured
    '"result"',               // expression only
  ];

  for (final code in cases) {
    final (modified, captured) = captureLastExpression(code);
    print('captureLastExpression(${code.split("\n").last.trim()}): captured=$captured');
    if (captured) print('  modified tail: ${modified.split("\n").last}');
  }

  print('');

  // extractAssignmentTargets() — finds all top-level assignment targets.
  // Useful for tracking which variables a block of code defines.
  final code = '''
x = 10
y = x + 1
z, w = 1, 2
_internal = 99
result = x + y
''';
  final targets = extractAssignmentTargets(code);
  print('assignment targets (excluding _ prefix): $targets');
  // Expected: {x, y, z, w, result}  (_internal excluded by convention)
}

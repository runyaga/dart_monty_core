// Session-scoped resource limits over FFI (core#138).
//
// The defect: `Monty.run(limits: …)` accepted a `MontyLimits` and silently
// discarded it. Measured before the fix — `timeoutMs: 50` on a 20-million
// iteration sum completed in 483 ms with `error == null`. In a sandboxing
// library that is the wrong failure direction: the caller who asks for a cap is
// exactly the caller who believes they have one.
//
// Limits are SESSION-scoped, mirroring upstream's Python API where
// `checkout(limits=…)` configures a REPL session rather than an individual feed
// (`monty-python/src/pool.rs`). A tracker is chosen when the session is created
// and cannot be swapped afterwards, which is why this is a constructor
// argument and not a per-feed one.
//
// FFI only for now: the web backend throws rather than ignoring limits
// (core#140), which is a deliberate placeholder, not a design.
@Tags(['integration', 'ffi'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  group('session resource limits', () {
    test('a timeout stops a long-running program', () async {
      final result = await Monty('sum(range(20000000))').run(
        limits: const MontyLimits(timeoutMs: 50),
      );

      expect(
        result.error,
        isNotNull,
        reason: 'the whole of core#138: this used to complete with no error',
      );
      expect('${result.error}', contains('TimeoutError'));
    });

    test('no limits still runs to completion', () async {
      // LimitedTracker with every field null must behave as NoLimitTracker did.
      // Every existing caller depends on it.
      final result = await Monty('sum(range(1000))').run();

      expect(result.error, isNull);
      expect(result.value, const MontyInt(499500));
    });

    test('a limit generous enough to finish does not interfere', () async {
      final result = await Monty('sum(range(1000))').run(
        limits: const MontyLimits(timeoutMs: 30000),
      );

      expect(result.error, isNull);
      expect(result.value, const MontyInt(499500));
    });

    test('a recursion limit stops runaway recursion', () async {
      final repl = MontyRepl(limits: const MontyLimits(stackDepth: 32));
      addTearDown(repl.dispose);

      final result = await repl.feedRun('def f(n):\n    return f(n + 1)\nf(0)');

      expect(
        result.error,
        isNotNull,
        reason: 'unbounded, this recurses until the process dies',
      );
    });

    test('limits are session-scoped, so they persist across feeds', () async {
      final repl = MontyRepl(limits: const MontyLimits(timeoutMs: 50));
      addTearDown(repl.dispose);

      // First feed is trivial and must succeed.
      expect((await repl.feedRun('1 + 1')).error, isNull);
      // A later feed on the SAME session is still bounded — which is what
      // "session-scoped" means, and what a per-feed argument could not express.
      expect((await repl.feedRun('sum(range(20000000))')).error, isNotNull);
    });
  });
}

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

    // ---- memoryBytes: BOTH halves, because only one of them works --------
    // core#160. This file covered timeoutMs and stackDepth and never
    // memoryBytes, so neither the working case nor the non-working one was
    // guarded and a change in either direction would ship silently.

    test('a single over-large allocation IS caught', () async {
      final r = await Monty(
        'x = b"a" * ${20 * 1024 * 1024}\nlen(x)',
      ).run(limits: const MontyLimits(memoryBytes: 100 * 1024));

      expect(r.error, isNotNull);
      expect(r.error!.excType, 'MemoryError');
      expect(r.error!.message, contains('memory limit exceeded'));
    });

    test('incremental growth into ONE object is caught too', () async {
      // The control that makes the rule precise. This allocates incrementally,
      // like the aggregate case below, but concatenates into a single growing
      // object — and it IS caught. So the discriminator is object SIZE, not
      // incremental allocation.
      final r = await Monty(
        's = ""\nfor i in range(200):\n    s += "y" * 100000\nlen(s)',
      ).run(limits: const MontyLimits(memoryBytes: 100 * 1024));

      expect(r.error, isNotNull);
      expect(r.error!.excType, 'MemoryError');
    });

    test('CHARACTERISATION: aggregate heap is NOT bounded', () async {
      // This pins OBSERVED behaviour, not desired behaviour. ~20 MB spread
      // across 200,000 small objects completes cleanly under a 100 KB cap;
      // measured up to ~314 MB with the same result. If monty ever starts
      // bounding aggregate heap this test FAILS, which is the point — the
      // change becomes visible instead of silently altering what the limit
      // means. Flip it to expect an error when that happens. core#160.
      final r = await Monty(
        'a = []\n'
        'for i in range(200000):\n'
        '    a.append("y"*100 + str(i))\n'
        'len(a)',
      ).run(limits: const MontyLimits(memoryBytes: 100 * 1024));

      expect(
        r.error,
        isNull,
        reason:
            'memoryBytes bounds single-object size, not total heap. '
            'If this now errors, the limit gained aggregate bounding: '
            'update the MontyLimits.memoryBytes doc and flip this.',
      );
      expect((r.value as MontyInt).value, 200000);
    });

    test(
      'memoryBytesUsed is zero even on a run that breached the limit',
      () async {
        // Upstream exposes no accessor for memory used
        // (core#155), so this field is a literal 0 everywhere.
        // is a literal 0 everywhere. Pinned so nobody builds a ceiling on it.
        final r = await Monty(
          'x = b"a" * ${20 * 1024 * 1024}\nlen(x)',
        ).run(limits: const MontyLimits(memoryBytes: 100 * 1024));

        expect(r.error, isNotNull, reason: 'the limit did fire');
        expect(r.usage.memoryBytesUsed, 0);
      },
    );
  });
}

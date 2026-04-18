/// Regression tests for sequential external-call chains with large payloads.
///
/// Background: in the old dart_monty bridge, calling an external function
/// 4+ times within a single execute() where each handler returned a large
/// response (~1000+ chars) caused:
///
///   Bad state: Cannot call resumeWithError() when not in active state
///
/// The failure was traced to the SSE HTTP lifecycle interacting with the
/// MontyStateMixin state machine in BaseMontyPlatform — the state was set
/// to idle by a catch block before the outer loop called resumeWithError().
///
/// dart_monty_core's MontyRepl bypasses MontyStateMixin entirely and drives
/// the resume loop directly through ReplBindings, so it should be immune.
/// These tests pin that behaviour and serve as a regression guard.
@Tags(['integration', 'ffi'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

final String _largePayload = 'x' * 2000;

void main() {
  group('ffi_multi_pending — sequential external calls', () {
    // Mirrors the failing scenario: Python calls a host function N times
    // in a loop; each call returns a large payload. In the old bridge this
    // crashed at call 4 with a state-machine error.
    test(
      '5 sequential external calls with 2000-char returns complete',
      () async {
        final repl = MontyRepl();
        addTearDown(repl.dispose);

        var callCount = 0;
        final result = await repl.feed(
          '''
results = []
for i in range(5):
    results.append(fetch(i))
len(results)
''',
          externals: {
            'fetch': (args) async {
              callCount++;
              // Simulate async work (e.g. SSE round-trip) before returning
              // a large payload — the exact shape of the failing scenario.
              await Future<void>.delayed(const Duration(milliseconds: 1));
              return _largePayload;
            },
          },
        );

        expect(callCount, 5, reason: 'all 5 external calls should fire');
        expect(result.error, isNull);
        expect(result.value, const MontyInt(5));
      },
    );

    // Pushes further than the old bridge's threshold (4 calls).
    test('10 sequential external calls with large returns complete', () async {
      final repl = MontyRepl();
      addTearDown(repl.dispose);

      var callCount = 0;
      final result = await repl.feed(
        '''
total = 0
for i in range(10):
    r = big_fn(i)
    total = total + len(r)
total
''',
        externals: {
          'big_fn': (args) async {
            callCount++;
            await Future<void>.delayed(const Duration(milliseconds: 1));
            return _largePayload;
          },
        },
      );

      expect(callCount, 10);
      expect(result.error, isNull);
      expect(result.value, MontyInt(_largePayload.length * 10));
    });

    // Verify that a handler throwing on call 4 surfaces as a Python
    // exception (not a Dart StateError), so the REPL survives.
    test(
      'external call that throws on 4th invocation raises Python error',
      () async {
        final repl = MontyRepl();
        addTearDown(repl.dispose);

        var callCount = 0;
        final result = await repl.feed(
          '''
try:
    for i in range(6):
        do_work(i)
    outcome = "ok"
except Exception as e:
    outcome = "caught:" + str(e)
outcome
''',
          externals: {
            'do_work': (args) async {
              callCount++;
              await Future<void>.delayed(const Duration(milliseconds: 1));
              if (callCount == 4) throw Exception('simulated SSE failure');
              return 'done';
            },
          },
        );

        expect(callCount, 4, reason: 'should stop at the throwing call');
        expect(
          result.error,
          isNull,
          reason: 'REPL survived — error caught by Python',
        );
        expect(
          (result.value as MontyString).value,
          startsWith('caught:'),
          reason: 'Python caught the propagated error string',
        );
      },
    );

    // Verifies the REPL is still usable after a multi-call sequence.
    test(
      'REPL state is intact after 5 sequential external calls',
      () async {
        final repl = MontyRepl();
        addTearDown(repl.dispose);

        await repl.feed(
          'collected = [fetch(i) for i in range(5)]',
          externals: {
            'fetch': (_) async {
              await Future<void>.delayed(const Duration(milliseconds: 1));
              return _largePayload;
            },
          },
        );

        final r = await repl.feed('len(collected[4])');
        expect(r.error, isNull);
        expect(r.value, MontyInt(_largePayload.length));
      },
    );
  });
}

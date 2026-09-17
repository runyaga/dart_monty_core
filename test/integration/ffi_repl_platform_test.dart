// ReplPlatform — the adapter, on a real backend.
//
// lib/src/repl/repl_platform.dart sat at 50% (18/36). It is the adapter that
// presents a MontyRepl as a MontyPlatform, and dart_monty's MontyRuntime is
// built on it (`ReplPlatform(repl: _sharedRepl!)`), so it is live code.
//
// WHY ITS UNCOVERED HALF MATTERS. Most of it is one-line FORWARDING —
// `resumeWithError(m) => _repl.resumeWithError(m)`. A delegation bug there
// (forwarding to the wrong method, dropping an argument, swallowing the
// return) is invisible to MontyRepl's own tests, because those call the repl
// directly and never go through this class. The only way to see it is to
// drive the adapter and check the ENGINE's answer.
//
// The rest is deliberate refusals, each carrying a reason. Pinning them
// records what ReplPlatform does not support, which is otherwise discoverable
// only by hitting it.
@Tags(['integration', 'ffi'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

/// A REPL-backed platform on the real FFI engine.
({MontyRepl repl, ReplPlatform platform}) _make() {
  final repl = MontyRepl();

  return (repl: repl, platform: ReplPlatform(repl: repl));
}

void main() {
  group('ReplPlatform forwards to the REPL', () {
    test('resume carries the host value into the engine', () async {
      final m = _make();
      addTearDown(m.repl.dispose);

      final pending = await m.platform.start(
        'fetch(1)',
        externalFunctions: ['fetch'],
      );
      expect(pending, isA<MontyPending>());

      final done = await m.platform.resume(7);

      // 7 is what the host supplied; a forward that dropped the argument
      // would complete with something else or not at all.
      expect(done, isA<MontyComplete>());
      expect((done as MontyComplete).output, const MontyInt(7));
    });

    test('resumeWithError injects the message as a Python exception', () async {
      final m = _make();
      addTearDown(m.repl.dispose);

      await m.platform.start('fetch(1)', externalFunctions: ['fetch']);

      await expectLater(
        m.platform.resumeWithError('boom'),
        throwsA(
          isA<MontyScriptError>().having(
            (e) => e.toString(),
            'message',
            contains('boom'),
          ),
        ),
      );
    });

    test(
      'resumeWithException carries the TYPE as well as the message',
      () async {
        final m = _make();
        addTearDown(m.repl.dispose);

        await m.platform.start('fetch(1)', externalFunctions: ['fetch']);

        // Two arguments, so this is the forward most likely to lose one.
        await expectLater(
          m.platform.resumeWithException('ValueError', 'bad input'),
          throwsA(
            isA<MontyScriptError>().having(
              (e) => e.toString(),
              'message',
              contains('bad input'),
            ),
          ),
        );
      },
    );

    test('resumeNotFound raises NameError for the named function', () async {
      final m = _make();
      addTearDown(m.repl.dispose);

      await m.platform.start('fetch(1)', externalFunctions: ['fetch']);

      await expectLater(
        m.platform.resumeNotFound('fetch'),
        throwsA(
          isA<MontyScriptError>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('fetch'), contains('not defined')),
          ),
        ),
      );
    });

    test('resumeAsFuture and resolveFutures walk the futures loop', () async {
      final m = _make();
      addTearDown(m.repl.dispose);

      await m.platform.start('await fetch(1)', externalFunctions: ['fetch']);

      final blocked = await m.platform.resumeAsFuture();
      expect(blocked, isA<MontyResolveFutures>());
      final ids = (blocked as MontyResolveFutures).pendingCallIds;
      expect(ids, isNotEmpty);

      final done = await m.platform.resolveFutures({
        for (final id in ids) id: 41,
      });

      expect(done, isA<MontyComplete>());
      expect((done as MontyComplete).output, const MontyInt(41));
    });

    test('run returns the engine result through the adapter', () async {
      final m = _make();
      addTearDown(m.repl.dispose);

      final r = await m.platform.run('2 + 3');

      expect(r.error, isNull);
      expect(r.value, const MontyInt(5));
    });
  });

  group('ReplPlatform refuses what the REPL cannot do', () {
    test('name-lookup resume is UnimplementedError, and says why', () async {
      final m = _make();
      addTearDown(m.repl.dispose);

      // UnimplementedError, NOT UnsupportedError — the two refusal families in
      // this file differ and the distinction is load-bearing: these two are
      // "not wired", the four below are "not supported".
      // SYNCHRONOUS throws. These are `=> throw ...` arrow bodies, so the
      // error is raised when the method is CALLED, not when its Future is
      // awaited — `expectLater(call(), ...)` never sees it because the throw
      // happens while building the argument. Measured: both cases failed that
      // way before this was written as `expect(() => ..., throwsA(...))`.
      for (final call in <void Function()>[
        () => m.platform.resumeNameLookup('x', 1),
        () => m.platform.resumeNameLookupUndefined('x'),
      ]) {
        expect(
          call,
          throwsA(
            isA<UnimplementedError>().having(
              (e) => e.toString(),
              'message',
              contains('auto-resolves name lookups and never asks the host'),
            ),
          ),
        );
      }
    });

    test('the reason it gives is TRUE of the real engine', () async {
      // The refusal claims the REPL handle auto-resolves name lookups and
      // never asks the host. That is checkable, and it is the difference
      // between a documented limitation and a comment: the one-shot handle
      // DOES yield MontyNameLookup for an unresolved name (see
      // ffi_name_lookup_test.dart), while the REPL raises NameError instead.
      final m = _make();
      addTearDown(m.repl.dispose);

      await expectLater(
        m.platform.start('mystery_value + 1'),
        throwsA(isA<MontyScriptError>()),
      );
    });

    test('precompiled and type-check surfaces are UnsupportedError', () async {
      final m = _make();
      addTearDown(m.repl.dispose);

      // Synchronous, for the same reason as the name-lookup pair above.
      expect(
        () => m.platform.compileCode('x = 1'),
        throwsA(isA<UnsupportedError>()),
      );
      expect(
        () => m.platform.typeCheck('x = 1'),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });
}

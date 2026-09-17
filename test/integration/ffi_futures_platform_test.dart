// MontyFfi's futures path, and the constructor nothing had called.
//
// lib/src/ffi/monty_ffi.dart sat at 18.2% line coverage (6/33) — the lowest of
// any VM-reachable file in the package. What was uncovered is not incidental:
// `resumeAsFuture`, `resolveFutures`, `snapshot`, `restore` and the
// `MontyFfi.withCore` constructor. Every FFI test in the suite goes through
// this class and none of them took those paths.
//
// test/integration/_repl_futures_test_body.dart walks the same progress loop,
// but through MontyRepl — a DIFFERENT platform with its own overrides. Its own
// header says it exercises "the path that runtime/Monty.run does NOT take";
// this file covers the third one, MontyFfi, which neither touches.
@Tags(['integration', 'ffi'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/ffi/ffi_core_bindings.dart';
import 'package:dart_monty_core/src/ffi/monty_ffi.dart';
import 'package:dart_monty_core/src/ffi/native_bindings_ffi.dart';
import 'package:test/test.dart';

void main() {
  group('MontyFfi.resumeAsFuture / resolveFutures', () {
    test('an awaited external resolves through the futures loop', () async {
      final m = MontyFfi();
      addTearDown(m.dispose);

      final pending = await m.start(
        'await fetch(1)',
        externalFunctions: ['fetch'],
      );
      expect(pending, isA<MontyPending>());
      expect((pending as MontyPending).functionName, 'fetch');

      // resumeAsFuture says "I will answer later", so the engine continues to
      // the await and hands back the ids it is blocked on.
      final blocked = await m.resumeAsFuture();
      expect(blocked, isA<MontyResolveFutures>());
      final ids = (blocked as MontyResolveFutures).pendingCallIds;
      expect(ids, isNotEmpty);

      final done = await m.resolveFutures({for (final id in ids) id: 41});

      // 41 is what the HOST supplied and the engine returned through `await`.
      expect(done, isA<MontyComplete>());
      expect((done as MontyComplete).output, const MontyInt(41));
    });

    test(
      'resolveFutures can answer with an ERROR, which Python raises',
      () async {
        final m = MontyFfi();
        addTearDown(m.dispose);

        await m.start('await fetch(1)', externalFunctions: ['fetch']);
        final blocked = await m.resumeAsFuture() as MontyResolveFutures;

        // The error path is a separate parameter and a separate engine branch
        // from the value path above; a test that only resolved values would
        // leave it unexercised.
        await expectLater(
          m.resolveFutures(
            const {},
            errors: {for (final id in blocked.pendingCallIds) id: 'boom'},
          ),
          throwsA(
            isA<MontyScriptError>().having(
              (e) => e.toString(),
              'message',
              contains('boom'),
            ),
          ),
        );
      },
    );

    test('the state guards fire on a disposed platform', () async {
      final m = MontyFfi();
      await m.dispose();

      // assertNotDisposed guards every override here. Without this the
      // disposed branch of resumeAsFuture/resolveFutures is never taken.
      await expectLater(
        m.resumeAsFuture(),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        m.resolveFutures(const {}),
        throwsA(isA<StateError>()),
      );
    });

    test('resumeAsFuture refuses when no execution is active', () async {
      final m = MontyFfi();
      addTearDown(m.dispose);

      // assertActive, the other guard. Idle is not disposed, and the two
      // failures are different sentences.
      await expectLater(
        m.resumeAsFuture(),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('MontyFfi.snapshot / restore', () {
    // Both delegate to FfiCoreBindings, which refuses on the one-shot handle
    // (core#152, pinned at the bindings layer in 28afa5b). These two cases
    // pin the refusal AT THE PLATFORM, which is the layer a consumer actually
    // holds — MontyFfi.snapshot() is what they would call, not
    // FfiCoreBindings.snapshot().
    test('snapshot refuses on an active one-shot platform', () async {
      final m = MontyFfi();
      addTearDown(m.dispose);
      await m.start('mystery + 1');

      await expectLater(
        m.snapshot(),
        throwsA(
          isA<Object>().having(
            (e) => e.toString(),
            'message',
            contains('snapshot is not supported on the one-shot handle'),
          ),
        ),
      );
    });

    test('restore refuses VALID bytes from a real REPL snapshot', () async {
      final repl = MontyRepl();
      addTearDown(repl.dispose);
      await repl.feedRun('seed = 7');
      final bytes = await repl.snapshot();
      expect(bytes, isNotEmpty);

      final m = MontyFfi();
      addTearDown(m.dispose);

      await expectLater(
        m.restore(bytes),
        throwsA(
          isA<Object>().having(
            (e) => e.toString(),
            'message',
            contains('restore is not supported on the one-shot handle'),
          ),
        ),
      );
    });
  });

  group('MontyFfi.withCore', () {
    test('builds a working platform from supplied bindings', () async {
      // The named constructor had zero coverage. It exists so a caller can
      // inject bindings — the seam the tests in this package rely on — so a
      // constructor that compiled but produced a non-functional platform
      // would not have been noticed.
      const native = NativeBindingsFfi();
      final m = MontyFfi.withCore(
        coreBindings: FfiCoreBindings(bindings: native),
        nativeBindings: native,
      );
      addTearDown(m.dispose);

      final r = await m.run('1 + 1');

      expect(r.error, isNull);
      expect(r.value, const MontyInt(2));
    });

    test('reports its backend name', () async {
      const native = NativeBindingsFfi();
      final m = MontyFfi.withCore(
        coreBindings: FfiCoreBindings(bindings: native),
        nativeBindings: native,
      );
      addTearDown(m.dispose);

      expect(m.backendName, 'MontyFfi');
    });
  });
}

// The two ways a HOST reports failure back into a suspended engine, on FFI.
//
// `resumeWithError` (the external function ran and threw) and `resumeNotFound`
// (the engine asked for a function the host does not have) are the whole error
// half of the external-call protocol, and on the native backend neither had
// ever reached its binding. Measured on the gate's own coverage/honest.info:
// ffi_core_bindings.dart:138-142 and :161-165 -- both method bodies entire --
// were uncovered.
//
// They LOOKED covered. ffi_state_guards_test.dart calls `resumeNotFound` and
// asserts it refuses, but it calls it on a platform that never started, so
// `assertActive` rejects BEFORE the binding is reached. A guard test on a
// method is not a test of the method. That is why these drive a genuinely
// suspended engine instead.
@Tags(['integration', 'ffi'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/ffi/monty_ffi.dart';
import 'package:test/test.dart';

void main() {
  group('FFI host-side failure resumes', () {
    test('resumeWithError raises the host error AT the call site', () async {
      final m = MontyFfi();
      addTearDown(m.dispose);

      final pending = await m.start(
        'fetch(1)',
        externalFunctions: ['fetch'],
      );
      expect(pending, isA<MontyPending>());
      expect((pending as MontyPending).functionName, 'fetch');

      // The host's function failed. Python must see an exception raised where
      // it called fetch(), not a None return and not a silent completion --
      // the latter is what a binding that dropped the message would produce.
      // It THROWS rather than returning an error progress: the engine raised
      // inside Python, nothing caught it, so the run ended in an exception and
      // translateProgress converts that to MontyScriptError. Measured, after
      // first writing this test the other way round and being corrected by it.
      await expectLater(
        m.resumeWithError('upstream refused the request'),
        throwsA(
          isA<MontyScriptError>().having(
            (e) => e.toString(),
            'message',
            contains('upstream refused the request'),
          ),
        ),
        reason: "the host's own text must survive into the Python exception",
      );
    });

    test(
      'resumeNotFound reports the missing name, not a generic failure',
      () async {
        final m = MontyFfi();
        addTearDown(m.dispose);

        await m.start('fetch(1)', externalFunctions: ['fetch']);

        // "I was asked for a function I do not have." The name has to travel:
        // a caller debugging this needs to know WHICH external was missing, and
        // the engine only knows what this call tells it.
        await expectLater(
          m.resumeNotFound('fetch'),
          throwsA(
            isA<MontyScriptError>().having(
              (e) => e.toString(),
              'message',
              allOf(contains('fetch'), contains('not defined')),
            ),
          ),
          reason:
              'a caller debugging this needs the NAME, not a generic failure',
        );
      },
    );

    test('a failed resume leaves the platform usable, not wedged', () async {
      // The handle must survive an error resume. If the binding freed or
      // corrupted it on the error path, the next call would fail for an
      // unrelated-looking reason -- the worst kind of leak to diagnose.
      final m = MontyFfi();
      addTearDown(m.dispose);

      await m.start('fetch(1)', externalFunctions: ['fetch']);
      await expectLater(
        m.resumeWithError('boom'),
        throwsA(isA<MontyScriptError>()),
      );

      final again = await m.run('1 + 1');
      expect(again.ok, isTrue);
      expect(again.value, const MontyInt(2));
    });
  });
}

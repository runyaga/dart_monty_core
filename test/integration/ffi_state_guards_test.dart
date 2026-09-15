// The MontyStateMixin guards must actually fire on a REAL platform.
//
// `assertNotDisposed`, `assertIdle` and `assertActive`
// (monty_state_mixin.dart:40-65) are called by twelve `BaseMontyPlatform`
// methods. Found by a mutation family that disables a validation guard --
// rewriting `if (<cond>) {` to `if (false) {` where the block opens with a
// `throw`. All three survived: with any one disabled, the whole unit suite AND
// the whole FFI integration suite stayed green, and nothing under test/
// referenced the three methods by name.
//
// WHY THIS IS AN INTEGRATION TEST AND NOT A UNIT TEST, recorded because the
// obvious approach does not work. `MockMontyPlatform` mixes in
// `MontyStateMixin` but `extends MontyPlatform`, NOT `BaseMontyPlatform` --
// so it inherits the mixin's assert METHODS and none of the twelve CALL SITES.
// Measured: `typeCheck()` on the mock raises
// `UnimplementedError: typeCheck() has not been implemented` from
// MontyPlatform, never reaching a guard. A unit test against the mock would
// assert nothing about them.
//
// The only classes that extend BaseMontyPlatform are MontyFfi and MontyWasm,
// so a real backend is required.
//
// Falsifier: rewrite any one of the three guard conditions to `false`; the
// matching case below fails.
@Tags(['integration', 'ffi'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/ffi/monty_ffi.dart';
import 'package:test/test.dart';

void main() {
  group('MontyStateMixin guards fire on a real platform', () {
    test('assertNotDisposed: a disposed platform refuses to run', () async {
      final m = MontyFfi();
      await m.run('x = 1');
      await m.dispose();

      await expectLater(
        m.run('x = 1'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('disposed'),
          ),
        ),
      );
    });

    test(
      'assertActive: resuming a platform that never started refuses',
      () async {
        final m = MontyFfi();
        addTearDown(m.dispose);

        await expectLater(
          m.resumeNotFound('missing'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('not in active state'),
            ),
          ),
        );
      },
    );

    test(
      'assertIdle: starting twice refuses while the first is active',
      () async {
        // A NameLookup leaves the platform ACTIVE, waiting to be resumed.
        final m = MontyFfi();
        addTearDown(m.dispose);

        final progress = await m.start('undefined_name');
        expect(
          progress,
          isA<MontyNameLookup>(),
          reason: 'fixture must leave the platform ACTIVE',
        );

        await expectLater(
          m.start('x = 2'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('while execution is active'),
            ),
          ),
        );
      },
    );
  });
}

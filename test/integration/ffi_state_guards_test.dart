// The MontyStateMixin guards must actually fire.
//
// `assertNotDisposed`, `assertIdle` and `assertActive`
// (monty_state_mixin.dart:40-65) are called by twelve `BaseMontyPlatform`
// methods, and nothing under test/ referenced them. Found by a mutation family
// that rewrites a guard's condition to `false`: with any one disabled, the
// whole unit suite and the whole FFI integration suite stayed green.
//
// THE ONE NON-OBVIOUS FACT, and the reason this is an integration test:
// `MockMontyPlatform` mixes in `MontyStateMixin` but `extends MontyPlatform`,
// NOT `BaseMontyPlatform`. It inherits the assert METHODS and none of the
// twelve CALL SITES -- measured, `typeCheck()` on the mock raises
// `UnimplementedError` from MontyPlatform without reaching a guard. A unit test
// against the mock reads correctly and asserts nothing. Only MontyFfi and
// MontyWasm extend BaseMontyPlatform.
//
// Falsifier: rewrite any one guard condition to `false`; the matching case
// below fails.
@Tags(['integration', 'ffi'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/ffi/monty_ffi.dart';
import 'package:test/test.dart';

void main() {
  group('MontyStateMixin guards fire on a real platform', () {
    test('assertNotDisposed: a disposed platform refuses to run', () async {
      final m = MontyFfi();
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
        final m = MontyFfi();
        addTearDown(m.dispose);

        // A NameLookup leaves the platform ACTIVE, waiting to be resumed.
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

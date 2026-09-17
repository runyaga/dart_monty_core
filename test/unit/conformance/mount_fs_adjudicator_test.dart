// The mount-fs adjudicator — `runMountFsFixture`.
//
// This is the entry point M0 needs (PLAN-CORE-DEDUP.md §5): it runs a corpus
// fixture against a CALLER-SUPPLIED handler, so two implementations of the
// filesystem contract can finally be judged by the same oracle instead of by
// reading them against each other.
//
// These tests pin the two things that make it an adjudicator rather than a
// smoke test: the known-good handler passes, and WRONG handlers FAIL. A
// harness that cannot fail proves nothing about the handlers it judges.
@Tags(['unit', 'vm-only'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:monty_conformance/monty_conformance.dart';
import 'package:test/test.dart';

void main() {
  group('runMountFsFixture', () {
    // NAME the fixture instead of indexing into the list. `.first` trips
    // `avoid-unsafe-collection-methods` (it throws when empty) and `[0]` trips
    // `prefer-first` -- the two rules contradict each other on the same line,
    // so neither spelling of "take an element" is clean. These tests do not
    // want an arbitrary element anyway: they want a fixture known to exercise
    // the handler, and naming it says so.
    const fixture = 'mount_fs__ops.py';

    test('the control handler passes every mount-fs fixture', () async {
      for (final name in mountFsFixtures) {
        expect(
          await runMountFsFixture(name, conformanceMountFsOsHandler()),
          isNull,
          reason: '$name must pass against memoryMountedOsHandler',
        );
      }
    });

    test('a handler that DECLINES is reported, not crashed on', () async {
      // dart_monty's handlers decline an op they do not implement
      // (sandboxed_fs_handler.dart throws OsCallNotHandledException). Before
      // this was handled, that exception escaped and took down the whole run
      // instead of filling in one cell of the comparison table.
      final reason = await runMountFsFixture(
        fixture,
        (op, args, kwargs) => throw OsCallNotHandledException(op),
      );

      expect(reason, isNotNull);
      expect(reason, contains('handler threw'));
      expect(reason, contains('OsCallNotHandledException'));
    });

    test('a handler that LIES fails the fixture', () async {
      // Every query answers "yes", every write answers 0. If the adjudicator
      // still reported a pass, it would be measuring nothing.
      final reason = await runMountFsFixture(
        fixture,
        (op, args, kwargs) =>
            op.startsWith('Path.is') || op == 'Path.exists' ? true : 0,
      );

      expect(reason, isNotNull);
    });

    test('a non-mount-fs fixture is refused, not silently skipped', () {
      // A silent skip would let a caller build a green three-column table out
      // of fixtures that never ran.
      expect(
        () => runMountFsFixture('args__len_no_args.py', conformanceOsHandler()),
        throwsA(isA<StateError>()),
      );
    });

    test('an unknown fixture name is refused', () {
      expect(
        () => runMountFsFixture('no__such_fixture.py', conformanceOsHandler()),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}

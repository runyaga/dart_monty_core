// The conformance harness must not corrupt its own expectation (#142).
//
// A fixture says `# Return=2.0`. The parser turns that text into a Dart value,
// and every harness then compares against `MontyValue.fromDart(thatValue)`.
// On dart2js `2.0 is int` is true, so the expectation collapses to
// `MontyInt(2)` — and a fixture whose ACTUAL result is correct is reported as
// failing.
//
// The engine is not at fault and this test does not touch it. Measured in
// Chrome against the shipped wasm: `run('7 % 2.5')` returns
// `{"__type":"float","value":"2.0"}` and `run('repr(7 % 2.5)')` returns
// `"2.0"`. The value crosses correctly; the yardstick is what bends.
//
// This is why it is a UNIT test rather than a fixture run: the defect is in
// how an expectation is built, so it can be shown with no interpreter at all.
// It runs on the VM, dart2js and dart2wasm via the gate's `unit_web` step, and
// is expected to be RED on dart2js until #142 is fixed.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:monty_conformance/monty_conformance.dart';
import 'package:test/test.dart';

/// True on dart2js, where `int` and `double` are one runtime type.
bool get _isJs => identical(1, 1.0);

void main() {
  group('a fixture expectation survives the backend (#142)', () {
    test('`# Return=2.0` must expect a float, not an int', () {
      // edge__int_float_mod.py, in full: `7 % 2.5` with `# Return=2.0`.
      const source = '7 % 2.5\n# Return=2.0\n';
      final expectation = parseFixture(source);

      expect(expectation, isA<ExpectReturn>());
      final want = MontyValue.fromDart((expectation! as ExpectReturn).value);

      expect(
        want,
        isA<MontyFloat>(),
        reason:
            'the directive says 2.0, so the expectation must be a float. '
            'On dart2js it becomes MontyInt(2), and the fixture then fails '
            'against a correct MontyFloat(2.0) coming back from the engine.',
      );
      // The lint asks for `MontyFloat(2)` here, which is the exact erasure
      // under test — writing 2.0 is the point.
      // ignore: prefer_int_literals
      expect(want, const MontyFloat(2.0));
    });

    test('a negative zero expectation keeps its sign', () {
      final expectation = parseFixture('x\n# Return=-0.0\n');
      final want = MontyValue.fromDart((expectation! as ExpectReturn).value);

      expect(want, isA<MontyFloat>());
      expect(
        (want as MontyFloat).value.isNegative,
        isTrue,
        reason:
            '-0.0 collapsing to 0 loses the sign the wire format was '
            'changed to preserve (core#128c)',
      );
    });

    test('an integer expectation is still an int', () {
      // The fix must not overcorrect: `# Return=2` is an int on every backend.
      final expectation = parseFixture('x\n# Return=2\n');
      final want = MontyValue.fromDart((expectation! as ExpectReturn).value);

      expect(want, isA<MontyInt>());
      expect(want, const MontyInt(2));
    });

    test('the erasure is real on this backend, and absent on the others', () {
      // Not an assertion about the fix — a statement of the platform fact the
      // fix exists for, so a reader can see which backend they are on.
      const Object twoPointOh = 2.0;
      expect(
        twoPointOh is int,
        _isJs,
        reason: 'dart2js must erase 2.0 to int; the VM and dart2wasm must not',
      );
    });
  });
}

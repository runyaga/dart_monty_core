// Shared body for ffi_ellipsis_test.dart and wasm_ellipsis_test.dart.
//
// core#129: `...` used to serialize as the bare string "...", so Python's
// Ellipsis and the string "..." both arrived as MontyString and could not be
// told apart. A convert.rs test ASSERTED that collapse as correct, which is
// what made it permanent.
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void runEllipsisTests() {
  group('Ellipsis fidelity (core#129)', () {
    test('... arrives as MontyEllipsis, not a string', () async {
      final r = await Monty('...').run();
      expect(r.error, isNull);
      expect(r.value, isA<MontyEllipsis>());
    });

    test('the string "..." still arrives as MontyString', () async {
      final r = await Monty('"..."').run();
      expect(r.error, isNull);
      expect(r.value, isA<MontyString>());
      expect((r.value as MontyString).value, '...');
    });

    test('they are not equal to each other', () async {
      final a = (await Monty('...').run()).value;
      final b = (await Monty('"..."').run()).value;
      expect(a, isNot(equals(b)));
    });
  });
}

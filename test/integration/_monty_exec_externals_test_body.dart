// Shared test body for ffi_monty_exec_externals_test.dart and
// wasm_monty_exec_externals_test.dart.
//
// `Monty.run` has always supported externals; `Monty.exec` did not. This
// body pins the fix on both backends — Python code passed through the
// static one-shot wrapper can call registered Dart callbacks.

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';
import '../_accessors.dart';

void runMontyExecExternalsTests() {
  group('Monty.exec externals', () {
    test('positional args dispatch through externalFunctions', () async {
      final result = await Monty.exec(
        'add(3, 4)',
        externalFunctions: {
          'add': (args, _) =>
              callbackArg<int>(args, 0) + callbackArg<int>(args, 1),
        },
      );

      expect(result.error, isNull);
      expect(result.value.dartValue, 7);
    });

    test('keyword args dispatch through externalFunctions', () async {
      final result = await Monty.exec(
        'greet(name="World")',
        externalFunctions: {
          'greet': (_, kwargs) => 'Hello, ${kwargs?['name']}!',
        },
      );

      expect(result.error, isNull);
      expect(result.value.dartValue, 'Hello, World!');
    });

    test('multiple external calls within a single exec', () async {
      var calls = 0;
      final result = await Monty.exec(
        'double(double(double(1)))',
        externalFunctions: {
          'double': (args, _) {
            calls++;

            return callbackArg<int>(args, 0) * 2;
          },
        },
      );

      expect(result.error, isNull);
      expect(result.value.dartValue, 8);
      expect(calls, 3);
    });

    test('external returning a list round-trips to Python', () async {
      final result = await Monty.exec(
        'sum(get_numbers())',
        externalFunctions: {
          'get_numbers': (_, _) => [1, 2, 3, 4],
        },
      );

      expect(result.error, isNull);
      expect(result.value.dartValue, 10);
    });
  });
}

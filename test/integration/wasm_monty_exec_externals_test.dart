// Run with dart2js:  dart test test/integration/wasm_monty_exec_externals_test.dart -p chrome --run-skipped
// Run with dart2wasm: dart test test/integration/wasm_monty_exec_externals_test.dart -p chrome --compiler dart2wasm --run-skipped
//
// WASM twin of ffi_monty_exec_externals_test.dart. `Monty.run` has always
// supported `externals:`; `Monty.exec` did not. This file pins the fix on
// the WASM backend so the parameter does not regress in the browser.
@Tags(['integration', 'wasm'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  group('Monty.exec externals', () {
    test('positional args dispatch through externals', () async {
      final result = await Monty.exec(
        'add(3, 4)',
        externals: {
          'add': (args) async => (args['_0']! as int) + (args['_1']! as int),
        },
      );

      expect(result.error, isNull);
      expect(result.value.dartValue, 7);
    });

    test('keyword args dispatch through externals', () async {
      final result = await Monty.exec(
        'greet(name="World")',
        externals: {'greet': (args) async => 'Hello, ${args['name']}!'},
      );

      expect(result.error, isNull);
      expect(result.value.dartValue, 'Hello, World!');
    });

    test('multiple external calls within a single exec', () async {
      var calls = 0;
      final result = await Monty.exec(
        'double(double(double(1)))',
        externals: {
          'double': (args) async {
            calls++;
            return (args['_0']! as int) * 2;
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
        externals: {
          'get_numbers': (_) async => [1, 2, 3, 4],
        },
      );

      expect(result.error, isNull);
      expect(result.value.dartValue, 10);
    });
  });
}

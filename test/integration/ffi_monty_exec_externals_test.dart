// Integration test: `Monty.exec` accepts and dispatches externals.
//
// `Monty.run` has always supported `externals:`; `Monty.exec` did not — Python
// code passed to one-shot evaluation could not call back into Dart, even
// though the convenience method otherwise mirrors `run`. This test pins the
// fix so the parameter does not regress.
//
// Run: dart test test/integration/ffi_monty_exec_externals_test.dart \
//        -p vm --run-skipped --tags=ffi
@Tags(['integration', 'ffi'])
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

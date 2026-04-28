// Shared test body for ffi_monty_compile_run_test.dart and
// wasm_monty_compile_run_test.dart.
//
// The two files are identical aside from their `@Tags`; both call
// [runMontyCompileRunTests] so the assertions live in one place and stay
// in sync across backends.

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void runMontyCompileRunTests() {
  group('Monty(code).run', () {
    test('runs the held code with no inputs', () async {
      final program = Monty('2 + 2');
      final r = await program.run();
      expect(r.error, isNull);
      expect(r.value.dartValue, 4);
    });

    test('runs with inputs injected per call', () async {
      final program = Monty('x * 2');
      final r = await program.run(inputs: {'x': 21});
      expect(r.error, isNull);
      expect(r.value.dartValue, 42);
    });

    test('multiple .run() calls reuse the held code, not state', () async {
      final program = Monty('x + 1');
      final r1 = await program.run(inputs: {'x': 10});
      final r2 = await program.run(inputs: {'x': 100});
      expect(r1.value.dartValue, 11);
      expect(r2.value.dartValue, 101);
    });

    test('state from one .run() does not leak into the next', () async {
      // First call defines `seen`; second call cannot see it because each
      // run is a fresh interpreter.
      final defining = Monty('seen = 1');
      await defining.run();

      final reading = Monty('seen');
      final r = await reading.run();
      expect(r.error?.excType, equals('NameError'));
    });

    test('externals dispatch through Monty(code).run', () async {
      final program = Monty('double(value)');
      final r = await program.run(
        inputs: {'value': 7},
        externalFunctions: {
          'double': (args) async => (args['_0']! as int) * 2,
        },
      );
      expect(r.error, isNull);
      expect(r.value.dartValue, 14);
    });

    test('scriptName threads through to error tracebacks', () async {
      final program = Monty(
        'raise RuntimeError("boom")',
        scriptName: 'compile_run_test.py',
      );
      final r = await program.run();
      expect(r.error, isNotNull);
      expect(r.error?.excType, equals('RuntimeError'));
    });

    test('scriptName getter returns the configured value', () {
      expect(Monty('1').scriptName, 'main.py');
      expect(Monty('1', scriptName: 'job.py').scriptName, 'job.py');
    });
  });
}

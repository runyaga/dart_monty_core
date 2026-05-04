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
          'double': (args, _) async => (args[0]! as int) * 2,
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

  group('inputs are kwargs-only', () {
    // The Dart API exposes `inputs` as a named parameter — there is no
    // positional form. This group verifies that the named-only contract is
    // enforced end-to-end at the Python runtime level.

    test('named inputs dict injects variables', () async {
      final program = Monty('f"{say}, {target}!"');
      final r = await program.run(inputs: {'say': 'hi', 'target': 'alan'});
      expect(r.error, isNull);
      expect(r.value.dartValue, 'hi, alan!');
    });

    test('omitting inputs is valid — no injections', () async {
      final program = Monty('2 + 2');
      final r = await program.run();
      expect(r.error, isNull);
      expect(r.value.dartValue, 4);
    });

    test('passing null inputs is a no-op', () async {
      // Explicitly passing null is equivalent to omitting the param.
      // ignore: avoid_redundant_argument_values
      final r = await Monty('3 + 3').run(inputs: null);
      expect(r.error, isNull);
      expect(r.value.dartValue, 6);
    });
  });

  group('return-value semantics', () {
    // pydantic-monty captures the *last expression* of a script as its
    // result value. Assignment statements, bare `pass`, and other
    // statement-only scripts yield MontyNone (dartValue == null).
    // A module-level `return` is a Python SyntaxError.

    test('last expression is captured as result value', () async {
      final r = await Monty('x + 1').run(inputs: {'x': 41});
      expect(r.error, isNull);
      expect(r.value.dartValue, 42);
    });

    test(
      'assignment statement yields MontyNone — not the assigned value',
      () async {
        final r = await Monty('x = 42').run();
        expect(r.error, isNull);
        // Assignment is a statement; no last-expression value.
        expect(r.value.dartValue, isNull);
      },
    );

    test('module-level return yields the return value', () async {
      // pydantic-monty treats module-level `return` as a valid return
      // statement — it returns the value rather than raising SyntaxError.
      final r = await Monty('return 42').run();
      expect(r.error, isNull);
      expect(r.value.dartValue, 42);
    });

    test('expression after assignment is the result', () async {
      final r = await Monty('x = 7\nx * 6').run();
      expect(r.error, isNull);
      expect(r.value.dartValue, 42);
    });
  });
}

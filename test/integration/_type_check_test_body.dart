// Shared test body for ffi_type_check_test.dart and
// wasm_type_check_test.dart.
//
// Validates Monty.typeCheck end-to-end: clean code returns an empty
// list; annotated code with a return-type/assignment mismatch surfaces
// a structured MontyTypingError with code, path, line, and column;
// prefix_code lets the analyser see declarations that aren't in the
// main source.

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void runTypeCheckTests() {
  group('Monty.typeCheck', () {
    test('clean code returns an empty list', () async {
      final errors = await Monty.typeCheck('x: int = 1\ny: int = x + 1');
      expect(errors, isEmpty);
    });

    test('inference catches literal-vs-literal type errors even without '
        'annotations', () async {
      // The analyser infers literal types eagerly, so `"a" + 1` flags
      // even though neither name is annotated.
      final errors = await Monty.typeCheck('x = "anything"\ny = x + 1');
      expect(errors, isNotEmpty);
      expect(errors.first.code, 'unsupported-operator');
    });

    test('catches incompatible assignment in annotated code', () async {
      final errors = await Monty.typeCheck(
        'x: int = "not an int"',
        scriptName: 'incompat.py',
      );
      expect(errors, isNotEmpty);
      final e = errors.first;
      expect(e.code, 'invalid-assignment');
      expect(e.message, contains('not assignable'));
      expect(e.path, '/incompat.py');
      expect(e.line, 1);
      expect(e.column, isNotNull);
    });

    test('catches None vs list[T] (the rbtree.py bug pattern)', () async {
      const code = '''
def insert_fixup(root: list, z: dict) -> None:
    pass

root: list = [None]
z: dict = {}
root = insert_fixup(root, z)
''';
      final errors = await Monty.typeCheck(code, scriptName: 'rb.py');
      expect(errors, isNotEmpty);
      final hit = errors.firstWhere(
        (e) => e.code == 'invalid-assignment',
        orElse: () => fail(
          'expected invalid-assignment, got ${errors.map((e) => e.code)}',
        ),
      );
      expect(hit.message, contains('None'));
      expect(hit.message, contains('list'));
      expect(hit.path, '/rb.py');
    });

    test(
      'prefix_code provides declarations the main source can rely on',
      () async {
        // Without prefix_code, `x` is an unresolved reference. With it,
        // the analyser sees `x: int` and the assignment passes.
        final withoutPrefix = await Monty.typeCheck('y: int = x + 1');
        expect(withoutPrefix, isNotEmpty);

        final withPrefix = await Monty.typeCheck(
          'y: int = x + 1',
          prefixCode: 'x: int = 0',
        );
        expect(withPrefix, isEmpty);
      },
    );

    test('multiple diagnostics in the same source surface in order', () async {
      const code = '''
a: int = "first"
b: int = "second"
''';
      final errors = await Monty.typeCheck(code);
      expect(errors.length, greaterThanOrEqualTo(2));
      // Diagnostics are sorted by line in the upstream renderer.
      final lines = errors.map((e) => e.line).toList();
      expect(
        lines,
        equals(
          List<int?>.from(lines)..sort((a, b) => (a ?? 0).compareTo(b ?? 0)),
        ),
      );
    });

    test('typeCheck does not affect a parallel Monty.exec', () async {
      // Heap isolation precondition: an in-flight execution shouldn't be
      // disturbed by a typeCheck call. Run both concurrently.
      final type = Monty.typeCheck('x: int = "wrong"');
      final exec = Monty.exec('1 + 2');
      final results = await Future.wait([type, exec]);
      final errors = results[0] as List<MontyTypingError>;
      final result = results[1] as MontyResult;
      expect(errors, isNotEmpty);
      expect(result.error, isNull);
      expect(result.value.dartValue, 3);
    });
  });
}

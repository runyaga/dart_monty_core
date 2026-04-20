// Run with dart2js:  dart test test/integration/wasm_setextfns_test.dart -p chrome --run-skipped
// Run with dart2wasm: dart test test/integration/wasm_setextfns_test.dart -p chrome --compiler dart2wasm --run-skipped
//
// Regression: WasmReplBindings.setExtFns was fire-and-forget, producing
// unhandled Future errors in compiled JS (core_patch.dart:293 Uncaught Error).
// Now that it returns Future<void> and callers await it, these tests verify
// the iterative feedStart path with external functions works correctly.
@Tags(['integration', 'wasm'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  group('WASM setExtFns (regression)', () {
    late MontyRepl repl;

    setUp(() {
      repl = MontyRepl();
    });

    tearDown(() => repl.dispose());

    test(
      'feedStart with external functions does not produce unhandled errors',
      () async {
        // feedStart internally calls setExtFns then feedStart on the bindings.
        // Previously setExtFns was fire-and-forget, which surfaced as
        // "Uncaught Error" at core_patch.dart:293 in compiled JS.
        final progress = await repl.feedStart(
          'my_tool()',
          externalFunctions: ['my_tool'],
        );

        // The code calls an external function, so we get MontyPending.
        expect(progress, isA<MontyPending>());
        final pending = progress as MontyPending;
        expect(pending.functionName, 'my_tool');

        // Resume with a value to complete execution.
        final result = await repl.resume(42);
        expect(result, isA<MontyComplete>());
        expect((result as MontyComplete).output, const MontyInt(42));
      },
    );

    test(
      'feedStart with multiple external functions registers all names',
      () async {
        final progress = await repl.feedStart(
          'a = tool_a()\nb = tool_b()\na + b',
          externalFunctions: ['tool_a', 'tool_b'],
        );

        expect(progress, isA<MontyPending>());
        expect((progress as MontyPending).functionName, 'tool_a');

        // Resume tool_a
        final p2 = await repl.resume(10);
        expect(p2, isA<MontyPending>());
        expect((p2 as MontyPending).functionName, 'tool_b');

        // Resume tool_b
        final result = await repl.resume(32);
        expect(result, isA<MontyComplete>());
        expect((result as MontyComplete).output, const MontyInt(42));
      },
    );

    test('concurrent REPLs with external functions stay isolated', () async {
      final repl2 = MontyRepl();
      addTearDown(repl2.dispose);

      // Both REPLs register external functions and use feedStart.
      final p1 = await repl.feedStart('fn_a()', externalFunctions: ['fn_a']);
      final p2 = await repl2.feedStart('fn_b()', externalFunctions: ['fn_b']);

      expect((p1 as MontyPending).functionName, 'fn_a');
      expect((p2 as MontyPending).functionName, 'fn_b');

      final r1 = await repl.resume('hello');
      final r2 = await repl2.resume('world');

      expect((r1 as MontyComplete).output, const MontyString('hello'));
      expect((r2 as MontyComplete).output, const MontyString('world'));
    });
  });
}

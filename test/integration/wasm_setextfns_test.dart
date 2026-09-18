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

    // THE THREE CASES BELOW USE THE CALL FORM ONLY, AND THE CALL FORM IS
    // REGISTRATION-INDEPENDENT. Measured on FFI 2026-09-17: the engine
    // suspends on ANY unknown call, registered or not, so
    // `feedStart('my_tool()', externalFunctions: ['my_tool'])` yielding
    // MontyPending proves nothing about setExtFns — this suite would pass
    // against a WasmReplBindings.setExtFns that did nothing, which is
    // uncomfortably close to the fire-and-forget bug it was written for.
    //
    // Registration is observable in the NAME form, so these two cases carry
    // the actual claim on WASM. Both expected values were verified on FFI
    // first, through the same public MontyRepl API.
    test('a registered name RESOLVES on WASM', () async {
      final progress = await repl.feedStart(
        'my_tool',
        externalFunctions: ['my_tool'],
      );

      expect(progress, isA<MontyComplete>());
      expect(
        (progress as MontyComplete).output.toString(),
        contains('my_tool'),
        reason: 'the engine must build a callable for the registered name',
      );
    });

    test('an UNregistered name raises NameError on WASM', () async {
      // The control. Same source, no externalFunctions, opposite outcome —
      // which is what makes the case above evidence rather than decoration.
      await expectLater(
        repl.feedStart('my_tool'),
        throwsA(
          isA<MontyScriptError>().having(
            (e) => e.toString(),
            'message',
            contains('my_tool'),
          ),
        ),
      );
    });

    test('the CALL form suspends WITHOUT registration on WASM too', () async {
      // Pins the trap on this backend rather than inferring it from FFI. If
      // this ever stops being true, the three call-form cases below become
      // meaningful on their own and this comment should go.
      final progress = await repl.feedStart('my_tool()');

      expect(progress, isA<MontyPending>());
      expect((progress as MontyPending).functionName, 'my_tool');
    });

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
        final isPending = isA<MontyPending>();
        final progress = await repl.feedStart(
          'a = tool_a()\nb = tool_b()\na + b',
          externalFunctions: ['tool_a', 'tool_b'],
        );

        expect(progress, isPending);
        expect((progress as MontyPending).functionName, 'tool_a');

        // Resume tool_a
        final p2 = await repl.resume(10);
        expect(p2, isPending);
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

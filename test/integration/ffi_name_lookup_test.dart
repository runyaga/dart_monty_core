// Name lookup, driven on a REAL backend at both layers.
//
// `resumeNameLookupValue` was one of six public entry points that
// tool/check_api_exercised.sh reported as never exercised against FFI or WASM
// once its source list stopped being two hard-coded filenames. It has three
// callers inside lib/, so it was reached transitively — but the only
// real-backend text naming it was test/integration/web/wasm_runner.mjs, a
// COMPILED ARTIFACT, not Dart source. A mock cannot vouch for this path: the
// engine decides when to pause for a name, and the value goes out over the
// wire and comes back as a Python value.
//
// Two layers on purpose:
//   - through MontyFfi, which is how a consumer meets this feature
//   - through FfiCoreBindings, which is the MontyCoreBindings contract the
//     entry point actually belongs to, and the layer a backend must satisfy
//
// NOTE `run()` DOES NOT PAUSE. `run('mystery_value + 1')` raises
// MontyScriptError("name 'mystery_value' is not defined") from
// base_monty_platform.dart:434 — measured. Only the stateful `start()` path
// yields MontyNameLookup, which is why every case below starts there.
@Tags(['integration', 'ffi'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/ffi/ffi_core_bindings.dart';
import 'package:dart_monty_core/src/ffi/monty_ffi.dart';
import 'package:dart_monty_core/src/ffi/native_bindings_ffi.dart';
import 'package:test/test.dart';

void main() {
  group('name lookup through the public platform (FFI)', () {
    test('start() pauses on an unresolved name and reports it', () async {
      final m = MontyFfi();
      addTearDown(m.dispose);

      final progress = await m.start('mystery_value + 1');

      expect(progress, isA<MontyNameLookup>());
      expect(
        (progress as MontyNameLookup).variableName,
        'mystery_value',
      );
    });

    test(
      'resumeNameLookup supplies the value and execution continues',
      () async {
        final m = MontyFfi();
        addTearDown(m.dispose);

        final paused = await m.start('mystery_value + 1');
        expect(paused, isA<MontyNameLookup>());

        final done = await m.resumeNameLookup('mystery_value', 42);

        // The value crossed the wire and was used as a Python int, not echoed:
        // 42 + 1 is arithmetic the ENGINE performed.
        expect(done, isA<MontyComplete>());
        expect((done as MontyComplete).output, const MontyInt(43));
      },
    );

    test('resumeNameLookupUndefined raises NameError instead', () async {
      final m = MontyFfi();
      addTearDown(m.dispose);

      final paused = await m.start('mystery_value + 1');
      expect(paused, isA<MontyNameLookup>());

      await expectLater(
        m.resumeNameLookupUndefined('mystery_value'),
        throwsA(
          isA<MontyScriptError>().having(
            (e) => e.toString(),
            'message',
            contains('mystery_value'),
          ),
        ),
      );
    });
  });

  group('MontyCoreBindings.resumeNameLookupValue contract (FFI)', () {
    // The entry point by its own name, at the layer it is declared on. This is
    // the call tool/check_api_exercised.sh looks for, and it is a real
    // contract test rather than a token mention: a backend that accepted the
    // value and dropped it would pass the public-API cases above only if the
    // wrapper happened to compensate.
    test('a paused lookup resumes with a value and completes', () async {
      final core = FfiCoreBindings(bindings: const NativeBindingsFfi());
      await core.init();

      final paused = await core.start('mystery_value + 1');
      expect(paused.state, 'name_lookup');
      expect(paused.variableName, 'mystery_value');

      final done = await core.resumeNameLookupValue(WireJson.value(42));

      expect(done.state, 'complete');
      expect(done.value, 43);
    });

    test('a string value round-trips as a Python str', () async {
      final core = FfiCoreBindings(bindings: const NativeBindingsFfi());
      await core.init();

      final paused = await core.start('greeting + "!"');
      expect(paused.state, 'name_lookup');

      final done = await core.resumeNameLookupValue(WireJson.value('hi'));

      expect(done.state, 'complete');
      expect(done.value, 'hi!');
    });
  });
}

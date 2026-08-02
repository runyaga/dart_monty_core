// Shared test body for ffi_float_roundtrip_test.dart and
// wasm_float_roundtrip_test.dart.
//
// Covers floats travelling INBOUND — a host callback returning a double to the
// sandbox. Every other instrument in this repo reads values *out* of Python;
// this direction is the one that broke.
//
// THE DEFECT. Tier 3 (core#128) taught `MontyFloat.toJson` to send an integral
// float and a negative zero as TAGGED TEXT, because a JSON number cannot carry
// them across the web transport — `4.0` reparses as `4`, `-0.0` re-serialises
// as `0`. The Rust decoder's tagged-float arm was not widened to match: it
// accepted only `NaN`/`Infinity`/`-Infinity` and rejected the very shapes the
// encoder had started sending. Returning a plain `2.0` therefore threw
//
//   RuntimeError: a tagged float carries only NaN/Infinity/-Infinity, got "2.0"
//
// The recorded lesson was "both encode directions move together or neither
// does". They did not — in the opposite direction from the time that produced
// the lesson.
//
// WHAT THIS FILE DELIBERATELY DOES NOT ASSERT. On dart2js `int` and `double`
// are one runtime type, so a *bare* Dart `2.0` is already an int before it
// reaches this package and binds a Python int. That is core#137, decided as
// PARITY with upstream (their own binding cannot preserve it either), not a
// defect — so the type-preservation assertions use an explicit [MontyFloat],
// where the type rides in the wrapper rather than in the numeric value.

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

/// True on dart2js, where `int` and `double` are one runtime type.
bool get _isJs => identical(1, 1.0);

Future<MontyResult> _ret(Object? value) =>
    Monty('f()').run(externalFunctions: {'f': (a, k) => Future.value(value)});

void runFloatRoundtripTests() {
  group('a host callback returning a float', () {
    // The regression test for the decode fix. An explicit MontyFloat carries
    // its type in the wrapper, so this is meaningful on every backend.
    test('an explicitly typed float survives, whatever its shape', () async {
      for (final v in <double>[2, 0, -3, 2.5, 1e300]) {
        final r = await _ret(MontyFloat(v));
        expect(r.error, isNull, reason: 'returning MontyFloat($v) threw');
        expect(r.value.dartValue, v, reason: 'MontyFloat($v) changed value');
      }
    });

    test('an explicitly typed float stays a float in Python', () async {
      final r = await Monty('type(f()).__name__').run(
        externalFunctions: {'f': (a, k) => Future.value(const MontyFloat(2))},
      );

      expect(r.error, isNull);
      expect(r.value.dartValue, 'float');
    });

    test('negative zero keeps its sign', () async {
      // NOT `-0`: an int literal converts to positive 0.0 and silently
      // destroys the sign bit this test exists to check. The lint is wrong
      // here precisely because the double-ness is the subject.
      // ignore: prefer_int_literals
      final r = await _ret(const MontyFloat(-0.0));
      expect(r.error, isNull);
      // 0.0 == -0.0, so comparing values would pass on the very case this is
      // meant to catch. Check the sign bit.
      expect((r.value.dartValue! as double).isNegative, isTrue);
    });

    test('non-finite floats still work', () async {
      for (final v in [double.infinity, double.negativeInfinity]) {
        final r = await _ret(MontyFloat(v));
        expect(r.error, isNull, reason: 'returning $v threw');
        expect(r.value.dartValue, v);
      }
    });

    // A bare Dart double, which is what most callers will actually return.
    // Skipped on dart2js: `2.0 is int` there, so the value arrives as an int
    // before this package sees it (core#137 — parity, not a defect).
    test(
      'a bare integral double survives where the backend has doubles',
      () async {
        for (final v in <double>[2, 0, -3]) {
          final r = await _ret(v);
          expect(r.error, isNull, reason: 'returning $v threw');
          expect(r.value.dartValue, v, reason: 'returning $v changed value');
        }
      },
      skip: _isJs ? 'dart2js erases int/double (core#137 parity)' : null,
    );

    test('a bare non-integral double survives everywhere', () async {
      final r = await _ret(2.5);
      expect(r.error, isNull);
      expect(r.value.dartValue, 2.5);
    });
  });
}

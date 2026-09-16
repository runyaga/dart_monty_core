// Shared body for ffi_output_depth_test.dart and wasm_output_depth_test.dart.
//
// Monty core truncates output at depth 1000 and substitutes the marker
// `<deeply nested>`. Nothing pinned that until now, and TWO separate things
// rest on it.
//
// 1. `native/src/convert.rs` has NO depth guard of its own — `grep -n depth
//    native/src/convert.rs` is 0 hits — so `monty_object_to_json` recurses once
//    per level. It is safe only because the input can never get deep enough.
//    That makes upstream's cap load-bearing for OUR memory safety while living
//    in someone else's repo. PT-S2.1 was filed as unbounded recursion and
//    disproved by measurement, not by reading: the bound is real, it is just
//    not ours. If monty ever raises or removes it, this test is what notices.
//
// 2. The marker is a STRING, so it collides with a real one. That is core#129's
//    exact shape: `...` once serialized as the bare string "...", and a
//    convert.rs test asserted the collapse as correct, which is what made it
//    permanent. Here the marker arrives as `MontyOpaque(repr, …)` and a literal
//    `'<deeply nested>'` arrives as `MontyString`. Untested, that distinction
//    is one refactor away from collapsing the same way.
//
// Measured 2026-09-15 through the FFI binding, and these are the assertions
// below: 999 -> depth 999 leaf MontyInt; 1000, 1001, 2000 and 50000 -> depth
// 1000, leaf MontyOpaque(repr, "<deeply nested>"); no crash, exit 0.
//
// Worth recording for contrast, because it says the cap is NOT in monty core:
// `pydantic_monty` 0.0.23 rejects the same program at depth 49 with
// `RuntimeError: Max output depth exceeded`, where our FFI accepts 49, 60 and
// 200 happily. The two clients disagree by a factor of ~20 about what depth is
// acceptable, so "monty truncates at 1000" is a fact about the path WE take.
import 'package:collection/collection.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

/// The depth monty core truncates output at.
const _cap = 1000;

/// The rendering monty substitutes at [_cap].
const _marker = '<deeply nested>';

/// `x = [[[…1…]]]`, nested [n] deep.
String _nest(int n) => 'x = 1\nfor _ in range($n): x = [x]\nx';

/// How many [MontyList] levels [v] carries before its first non-list leaf.
int _depthOf(MontyValue v) {
  var depth = 0;
  var cursor = v;
  while (cursor is MontyList) {
    // `firstOrNull`, not `isNotEmpty` + `first`: the guarded form is safe but
    // avoid-unsafe-collection-methods cannot see the guard, and the honest fix
    // is the total accessor rather than an exclusion. Same call this repo
    // settled on in test/_accessors.dart.
    final next = cursor.items.firstOrNull;
    if (next == null) break;
    depth++;
    cursor = next;
  }

  return depth;
}

/// The first non-list value at the bottom of [v].
MontyValue _leafOf(MontyValue v) {
  var cursor = v;
  while (cursor is MontyList) {
    final next = cursor.items.firstOrNull;
    if (next == null) break;
    cursor = next;
  }

  return cursor;
}

Future<MontyValue> _runNested(int n) async {
  final result = await Monty(_nest(n)).run();
  expect(result.error, isNull, reason: 'nesting $n deep should not error');

  return result.value;
}

/// The WASM backend cannot reach monty's depth cap.
///
/// Measured 2026-09-15 through `tool/test_wasm_unit.sh`, nesting N deep:
/// 50, 100, 200 and 400 all succeed; **600, 800 and 999 all throw
/// `Bad state: memory access out of bounds`** from
/// `wasm_bindings_js.dart`'s `replCreate`. So the browser backend exhausts
/// its linear memory somewhere in (400, 600] — well before monty core's
/// 1000-deep truncation can fire.
///
/// **And the failure is STICKY.** Once one call blows the instance, every
/// later `replCreate` on the same page fails the same way: the first run of
/// this suite failed all 8 tests, including a literal-string case that nests
/// nothing at all. That is the same poisoning `wasm_mem_spike_repro.dart`
/// documents for `refcount__gather_detached_sibling.py`.
///
/// So the at-and-over-cap rows are FFI-only, and they are skipped rather than
/// deleted so the asymmetry stays visible. What WASM still asserts is
/// everything below the ceiling: nothing is truncated early, and the marker
/// does not collide with a real string.
const wasmDepthCeiling = 400;

/// [depthCeiling] is the deepest nesting this backend survives, or `null` for
/// a backend with no ceiling below monty's own cap.
void runOutputDepthTests({int? depthCeiling}) {
  group('output depth truncation (PT-S2.1)', () {
    test('just under the cap survives intact, with a real leaf', () async {
      if (depthCeiling != null && _cap - 1 > depthCeiling) {
        markTestSkipped(
          "nesting ${_cap - 1} deep exceeds this backend's measured ceiling "
          'of $depthCeiling; see wasmDepthCeiling',
        );

        return;
      }
      final value = await _runNested(_cap - 1);
      expect(_depthOf(value), _cap - 1);
      expect(
        _leafOf(value),
        isA<MontyInt>(),
        reason: 'below the cap nothing is substituted, so the 1 survives',
      );
    });

    // The four that matter: at the cap, one past it, and far past it. If
    // upstream ever removes the cap, the depth assertion fails here rather
    // than convert.rs recursing until the stack runs out.
    for (final n in [_cap, _cap + 1, 2000, 50000]) {
      test('nesting $n deep truncates at $_cap instead of recursing', () async {
        if (depthCeiling != null && n > depthCeiling) {
          markTestSkipped(
            "nesting $n deep exceeds this backend's measured ceiling of "
            '$depthCeiling; see wasmDepthCeiling',
          );

          return;
        }
        final value = await _runNested(n);
        expect(
          _depthOf(value),
          _cap,
          reason:
              'monty core caps output depth at $_cap; if this reads $n '
              'the cap is gone and convert.rs now recurses unbounded',
        );
      });
    }

    test('the truncation marker is MontyOpaque, not a bare string', () async {
      if (depthCeiling != null) {
        markTestSkipped(
          "reaching the marker needs nesting past $_cap, over this backend's "
          'measured ceiling of $depthCeiling; see wasmDepthCeiling',
        );

        return;
      }
      final leaf = _leafOf(await _runNested(_cap + 1));
      expect(leaf, isA<MontyOpaque>());
      expect((leaf as MontyOpaque).kind, MontyOpaqueKind.repr);
      expect(leaf.text, _marker);
    });

    // The one depth assertion every backend can make: below the ceiling
    // nothing is substituted, so a truncation that started firing early --
    // the regression that would silently shorten real data -- fails here on
    // WASM too, not only on FFI.
    test(
      'nesting $wasmDepthCeiling deep is not truncated on any backend',
      () async {
        final value = await _runNested(wasmDepthCeiling);
        expect(_depthOf(value), wasmDepthCeiling);
        expect(_leafOf(value), isA<MontyInt>());
      },
    );

    // core#129's lesson, applied before it can happen again.
    test('a literal $_marker string is still MontyString', () async {
      final result = await Monty("'$_marker'").run();
      expect(result.error, isNull);
      expect(result.value, isA<MontyString>());
      expect((result.value as MontyString).value, _marker);
    });

    test('the marker and the literal string are not equal', () async {
      if (depthCeiling != null) {
        markTestSkipped(
          "reaching the marker needs nesting past $_cap, over this backend's "
          'measured ceiling of $depthCeiling; see wasmDepthCeiling',
        );

        return;
      }
      final marker = _leafOf(await _runNested(_cap + 1));
      final literal = (await Monty("'$_marker'").run()).value;
      expect(
        marker,
        isNot(equals(literal)),
        reason:
            'if these ever compare equal the marker has collapsed into an '
            'ordinary string, which is core#129 all over again',
      );
    });
  });
}

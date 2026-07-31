// The repr differential — an INDEPENDENT oracle for value fidelity.
//
// For each expression, this runs it twice:
//
//   1. `expr`         -> our encode/decode chain -> montyRepr(...)
//   2. `repr(expr)`   -> monty's own repr, computed in Rust, upstream
//
// and requires the two strings to match. (2) never passes through
// `convert.rs`'s value encoding, so it is a genuinely independent reference —
// unlike the oracle conformance suite, which compares our encoder against a
// binary that shares the same encoder (core#130).
//
// This is the check that would have caught core#129 on day one: with dict keys
// sorted, monty said `{'b': 1, 'a': 2}` and our side rendered
// `{'a': 2, 'b': 1}`.
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '_monty_repr.dart';

/// Expressions chosen to cover every value class the encoder handles, with the
/// awkward cases round-tripping misses: unsorted dict keys, 1-tuples,
/// the empty set, signed zero, quote-switching, and integers at the i64 edge.
const _expressions = [
  // scalars
  'None',
  'True',
  'False',
  '42',
  '-7',
  '4.0',
  '-0.0',
  '0.1 + 0.2',
  '1e100',
  '"s"',
  '"it\'s"',
  '...',
  // integers at the i64 boundary (beyond it is a KNOWN divergence, below)
  '2**63 - 1',
  '-2**63',
  // containers
  '[]',
  '[1, 2]',
  '()',
  '(1,)',
  '(1, 2)',
  'set()',
  '{1, 2}',
  'frozenset([1])',
  '{}',
  // the one that mattered: keys NOT in sorted order
  '{"b": 1, "a": 2, "c": 3}',
  '{"z": 1, "y": 2}',
  // nesting
  '{"a": [1, (2, 3)]}',
  '[[1], [2, [3]]]',
  // bytes
  'b""',
  'b"hi"',
];

/// Expressions where our pipeline is KNOWN to disagree with monty's repr.
///
/// These are reported as skips with the reason, never asserted as correct.
/// Asserting current-but-wrong behaviour is what made core#129 permanent, so a
/// known defect gets a visible skip and an issue link — not a green test that
/// pins it.
const _knownDivergences = {
  // Integers outside i64 are encoded as a JSON string, so they arrive as
  // MontyString and render with quotes where monty renders a bare integer.
  '2**63': 'ints beyond i64 arrive as MontyString — core#134',
  '-2**63 - 1': 'ints beyond i64 arrive as MontyString — core#134',
};

/// True when compiled for the web (dart2js or dart2wasm).
const _isWeb = bool.fromEnvironment('dart.library.js_interop');

/// Divergences that exist ONLY on the web backend.
///
/// The JS bridge does `JSON.parse(...)` then `postMessage(...)`, so the exact
/// text of the number is destroyed at the JS boundary: integral floats collapse
/// (`4.0` -> `4`) and integers above 2^53 lose precision. FFI is correct, which
/// is why these are backend-specific rather than global — a blanket skip would
/// hide the fact that one backend gets this right (core#128).
const _webOnlyDivergences = {
  '4.0': 'integral floats collapse to int at the JS boundary — core#128',
  '-0.0': 'signed zero is lost at the JS boundary — core#128',
  '0.1 + 0.2': 'float text is reparsed at the JS boundary — core#128',
  '1e100': 'float text is reparsed at the JS boundary — core#128',
  '2**63 - 1': 'ints above 2^53 lose precision at the JS boundary — core#128',
  '-2**63': 'ints above 2^53 lose precision at the JS boundary — core#128',
};

void runReprOracleTests() {
  group('repr differential — independent value-fidelity oracle', () {
    for (final MapEntry(key: expr, value: why) in _knownDivergences.entries) {
      test('KNOWN DIVERGENCE: $expr', () async {
        markTestSkipped(why);
      });
    }

    for (final expr in _expressions) {
      test(expr, () async {
        if (_isWeb && _webOnlyDivergences.containsKey(expr)) {
          markTestSkipped(_webOnlyDivergences[expr]!);

          return;
        }

        final direct = await Monty(expr).run();
        expect(direct.error, isNull, reason: 'evaluating $expr failed');

        final viaRepr = await Monty('repr($expr)').run();
        expect(viaRepr.error, isNull, reason: 'repr($expr) failed');

        final expected = (viaRepr.value as MontyString).value;
        final actual = montyRepr(direct.value);

        if (actual.startsWith('<unsupported:')) {
          markTestSkipped(
            'renderer does not model ${direct.value.runtimeType}',
          );

          return;
        }

        expect(
          actual,
          expected,
          reason: 'monty (upstream): $expected  ours: $actual',
        );
      });
    }
  });
}

// The old engine's limits encoder: `encodeLimitsJson` is NOT what
// `MontyLimits.toJson` produces. (The `toJson`/`fromJson` and value-semantics
// tests are in monty_limits_json_test.dart.)
//
// THE REASON THIS IS NOT JUST COVERAGE. `MontyLimits.toJson()` is NOT what the
// engine receives. Limits reach a backend through
// `encodeLimitsJson` (base_monty_platform.dart:44), which SUBSTITUTES
// DEFAULTS for a null memory or stack limit. The two disagree exactly where it
// matters most — on the empty value:
//
//     MontyLimits().toJson()            {}
//     encodeLimitsJson(MontyLimits())   {"memory_bytes":268435456,
//                                        "stack_depth":512}
//
// So `toJson()` reads as "no limits" for a configuration the engine runs at
// 256 MB and depth 512. A consumer who serialises limits to show a user, or to
// persist and compare, gets the opposite of the effective policy. Neither
// `toJson` nor `fromJson` has a single caller in lib/, test/, example/ or
// packages/ — they are public API used only from outside, which is precisely
// where that inversion would land.
//
// These tests pin both shapes so the difference is recorded rather than
// rediscovered, and so a change to either one has to confront the other.
@Tags(['unit'])
library;

import 'dart:convert';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/platform/base_monty_platform.dart';
import 'package:test/test.dart';

void main() {
  group('toJson is NOT what the engine receives', () {
    test('encodeLimitsJson substitutes defaults where toJson omits', () {
      const empty = MontyLimits();

      // The claim, measured rather than asserted.
      expect(empty.toJson(), isEmpty);

      final sent = json.decode(encodeLimitsJson(empty)) as Map<String, dynamic>;
      expect(sent['memory_bytes'], BaseMontyPlatform.defaultMemoryBytes);
      expect(sent['stack_depth'], BaseMontyPlatform.defaultStackDepth);

      // Reading toJson() as "the limits in force" inverts the truth: it says
      // unlimited for a run the engine bounds at 256 MB and depth 512.
      expect(
        empty.toJson().keys,
        isNot(unorderedEquals(sent.keys)),
        reason: 'the two serializers disagree on the empty value',
      );
    });

    test('null limits and empty limits reach the engine identically', () {
      expect(encodeLimitsJson(null), encodeLimitsJson(const MontyLimits()));
    });

    test('timeout is the one field encodeLimitsJson also omits when null', () {
      final sent =
          json.decode(encodeLimitsJson(const MontyLimits()))
              as Map<String, dynamic>;
      expect(sent.containsKey('timeout_ms'), isFalse);

      final withTimeout =
          json.decode(encodeLimitsJson(const MontyLimits(timeoutMs: 9)))
              as Map<String, dynamic>;
      expect(withTimeout['timeout_ms'], 9);
    });

    test(
      'an explicit limit is passed through, not replaced by the default',
      () {
        final sent =
            json.decode(encodeLimitsJson(const MontyLimits(memoryBytes: 4096)))
                as Map<String, dynamic>;

        expect(sent['memory_bytes'], 4096);
        expect(
          sent['memory_bytes'],
          isNot(BaseMontyPlatform.defaultMemoryBytes),
        );
      },
    );
  });
}

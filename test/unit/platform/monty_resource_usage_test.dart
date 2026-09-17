// MontyResourceUsage.toString — the shape a failure report carries.
//
// lib/src/platform/monty_resource_usage.dart sat at 78.3% (18/23). The
// uncovered lines were toString alone. It is not decoration: usage is what a
// caller prints when a run hits a limit, so a toString that dropped a field
// would hide which limit was approached.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  group('MontyResourceUsage', () {
    test('toString names every field with its value', () {
      const u = MontyResourceUsage(
        memoryBytesUsed: 11,
        timeElapsedMs: 22,
        stackDepthUsed: 33,
      );
      final text = u.toString();

      expect(text, startsWith('MontyResourceUsage('));
      for (final field in [
        'memoryBytesUsed',
        'timeElapsedMs',
        'stackDepthUsed',
      ]) {
        expect(text, contains(field), reason: '$field must be named');
      }
      for (final value in ['11', '22', '33']) {
        expect(text, contains(value), reason: 'the value $value must appear');
      }
    });

    test('a zero field is still reported, not omitted', () {
      // Zero memory used and zero memory measured are different claims; the
      // second is what an omitted field would imply.
      const u = MontyResourceUsage(
        memoryBytesUsed: 0,
        timeElapsedMs: 0,
        stackDepthUsed: 0,
      );

      expect(u.toString(), contains('memoryBytesUsed: 0'));
      expect(u.toString(), contains('timeElapsedMs: 0'));
      expect(u.toString(), contains('stackDepthUsed: 0'));
    });

    test('equality and hashCode follow all three fields', () {
      const a = MontyResourceUsage(
        memoryBytesUsed: 1,
        timeElapsedMs: 2,
        stackDepthUsed: 3,
      );
      const b = MontyResourceUsage(
        memoryBytesUsed: 1,
        timeElapsedMs: 2,
        stackDepthUsed: 3,
      );

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(
        a,
        isNot(
          const MontyResourceUsage(
            memoryBytesUsed: 9,
            timeElapsedMs: 2,
            stackDepthUsed: 3,
          ),
        ),
      );
    });
  });
}

// The renderers that describe what came back.
//
// Off the gate's own coverage/honest.info: eight toString() overrides across
// the structured and datetime value types had never been called. The
// renderers are what a failed `expect` prints. A value type whose toString
// falls back to "Instance of 'MontyTimeDelta'" turns every assertion failure
// about it into a guess.
@TestOn('vm')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  group('every structured/datetime value renders its own state', () {
    // TABLE-DRIVEN over the eight renderers that had never run. Each case
    // asserts the TYPE NAME and at least one distinguishing field, because a
    // toString that printed only the class name would still "work" and would
    // still be useless in a failure message.
    final cases = <String, (MontyValue, List<String>)>{
      'MontyFileHandle': (
        // Upstream's repr, which leaves out the position.
        MontyFileHandle('/tmp/f', 'r', position: BigInt.from(7)),
        ['MontyFileHandle', "path='/tmp/f'", "mode='r'"],
      ),
      'MontyTimeDelta': (
        const MontyTimeDelta(days: 2, seconds: 30, microseconds: 5),
        ['MontyTimeDelta', '2', '30'],
      ),
      'MontyTimeZone': (
        const MontyTimeZone(offsetSeconds: 3600, name: 'CET'),
        ['MontyTimeZone', '3600', 'CET'],
      ),
      'MontyTime': (
        const MontyTime(hour: 13, minute: 5, second: 9, microsecond: 1),
        ['MontyTime', '13', '5', '9'],
      ),
    };

    for (final entry in cases.entries) {
      final name = entry.key;
      final (value, fragments) = entry.value;
      test('$name.toString names itself and its fields', () {
        final rendered = value.toString();
        expect(
          rendered,
          allOf([startsWith(name), ...fragments.map(contains)]),
          reason: '$name.toString must carry its fields: $rendered',
        );
      });
    }

    test('MontyDateTime renders a readable ISO-ish instant', () {
      // Zero-padded deliberately: '2026-09-07T05:04:03' sorts and reads; the
      // un-padded form does neither.
      expect(
        const MontyDateTime(
          year: 2026,
          month: 9,
          day: 7,
          hour: 5,
          minute: 4,
          second: 3,
        ).toString(),
        'MontyDateTime(2026-09-07T05:04:03)',
      );
    });
  });
}

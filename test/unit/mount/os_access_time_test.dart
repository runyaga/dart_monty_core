@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  // Upstream datetime_now delegates to datetime.datetime.now(tz). The oracle
  // checks zone metadata; these bounds also check the returned wall clock.
  for (final offset in [19800, -12600]) {
    test('datetime.now applies the $offset second offset to UTC', () async {
      final fs = OSAccess();
      final before = DateTime.now().toUtc();
      final value =
          await fs('datetime.now', [
                MontyTimeZone(offsetSeconds: offset, name: 'custom'),
              ], {})
              as MontyDateTime;
      final after = DateTime.now().toUtc();
      final instant = DateTime.utc(
        value.year,
        value.month,
        value.day,
        value.hour,
        value.minute,
        value.second,
        0,
        value.microsecond,
      ).subtract(Duration(seconds: offset));
      expect(
        instant.microsecondsSinceEpoch,
        inInclusiveRange(
          before.microsecondsSinceEpoch,
          after.microsecondsSinceEpoch,
        ),
      );
      expect(value.offsetSeconds, offset);
      expect(value.timezoneName, 'custom');
    });
  }
}

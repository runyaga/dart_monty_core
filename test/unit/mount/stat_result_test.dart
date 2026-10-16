@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  test('P12 file stat exact tuple', () {
    final stat = StatResult.fileStat(10, 384, 1.5);
    expect(stat.typeName, 'StatResult');
    expect(stat.fieldNames, [
      'st_mode',
      'st_ino',
      'st_dev',
      'st_nlink',
      'st_uid',
      'st_gid',
      'st_size',
      'st_atime',
      'st_mtime',
      'st_ctime',
    ]);
    expect(stat.values, [
      const MontyInt(33152),
      const MontyInt(0),
      const MontyInt(0),
      const MontyInt(1),
      const MontyInt(0),
      const MontyInt(0),
      const MontyInt(10),
      const MontyFloat(1.5),
      const MontyFloat(1.5),
      const MontyFloat(1.5),
    ]);
  });
  test('P12 directory stat and full mode', () {
    final stat = StatResult.dirStat(493, 2);
    expect(stat.values.firstOrNull, const MontyInt(16877));
    expect(stat.values.elementAtOrNull(3), const MontyInt(2));
    expect(stat.values.elementAtOrNull(6), const MontyInt(4096));
    expect(stat.values.elementAtOrNull(9), const MontyFloat(2));
    expect(
      StatResult.fileStat(1, 0xA123, 0).values.firstOrNull,
      const MontyInt(0xA123),
    );
    expect(
      StatResult.dirStat(0xA123, 0).values.firstOrNull,
      const MontyInt(0xA123),
    );
    expect(StatResult.fileStat(0).values.firstOrNull, const MontyInt(33188));
    expect(StatResult.dirStat().values.firstOrNull, const MontyInt(16877));
  });
  test('default timestamps use the host clock', () {
    // Read the clock on both sides of the operation to bound its timestamp.
    // ignore: prefer-moving-to-variable
    final before = DateTime.now().millisecondsSinceEpoch / 1000;
    final stat = StatResult.fileStat(0);
    // The upper bound needs a fresh clock reading after stat construction.
    // ignore: prefer-moving-to-variable
    final after = DateTime.now().millisecondsSinceEpoch / 1000 + 0.001;
    expect(
      (stat.values.elementAtOrNull(8) as MontyFloat?)?.value,
      inInclusiveRange(before, after),
    );
  });
}

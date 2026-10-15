// The host zoneinfo lookup a native worker's jiff makes, over a temporary
// directory: which names it resolves (jiff 0.2 tz/db/zoneinfo/enabled.rs).
@Tags(['unit', 'vm-only'])
@TestOn('vm')
library;

import 'dart:io';

import 'package:dart_monty_core/src/worker/zone_database_io.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('zoneinfo');
    addTearDown(() => root.deleteSync(recursive: true));
    void write(String name, String head) => (File(
      '${root.path}/$name',
    )..createSync(recursive: true)).writeAsStringSync('$head...');
    write('Europe/London', 'TZif');
    write('posixrules', 'TZif');
    write('zone.tab', '# tab');
    write('posix/Europe/Paris', 'TZif');
    write('right/UTC', 'TZif');
    Link(
      '${root.path}/Europe/Belfast',
    ).createSync('${root.path}/Europe/London');
  });

  test('names under the directory, by ASCII case, that are TZif', () {
    final zones = zoneFilesUnder(root.path);
    for (final name in [
      'Europe/London',
      'europe/LONDON',
      'posixrules',
      'POSIXRULES',
      'Europe/Belfast',
    ]) {
      expect(zoneKnownIn(zones, name), isTrue, reason: name);
    }
    for (final name in ['zone.tab', 'posix/Europe/Paris', 'right/UTC', 'X']) {
      expect(zoneKnownIn(zones, name), isFalse, reason: name);
    }
  });

  test('no directory: null, so the bundled list decides', () {
    expect(zoneFilesUnder('${root.path}/missing'), isEmpty);
    expect(zoneKnownIn(null, 'Europe/London'), isNull);
  });
}

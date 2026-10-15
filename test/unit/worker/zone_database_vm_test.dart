// The host zoneinfo lookup a native worker's jiff makes, over a temporary
// directory: which names it resolves (jiff 0.2 tz/db/zoneinfo/enabled.rs).
@Tags(['unit', 'vm-only'])
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_monty_core/src/worker/zone_database_io.dart';
import 'package:test/test.dart';

/// A TZif header of [version] with the six counts [counts].
List<int> _header(int version, List<int> counts) => [
  ...'TZif'.codeUnits,
  version,
  ...List.filled(15, 0),
  for (final n in counts) ...[
    n >> 24 & 255,
    n >> 16 & 255,
    n >> 8 & 255,
    n & 255,
  ],
];

/// One local time type (UTC), one designation byte, no transitions.
final List<int> _v1 = [
  ..._header(0, [0, 0, 0, 0, 1, 4]),
  ...[0, 0, 0, 0, 0, 0],
  ...'UTC\u0000'.codeUnits,
];

/// [_v1] as version 2: the 64-bit block again, then the footer.
final List<int> _v2 = [
  ..._header(0x32, [0, 0, 0, 0, 1, 4]),
  ...[0, 0, 0, 0, 0, 0],
  ...'UTC\u0000'.codeUnits,
  ..._header(0x32, [0, 0, 0, 0, 1, 4]),
  ...[0, 0, 0, 0, 0, 0],
  ...'UTC\u0000'.codeUnits,
  ...'\nUTC0\n'.codeUnits,
];

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('zoneinfo');
    addTearDown(() => root.deleteSync(recursive: true));
    void write(String name, List<int> bytes) => (File(
      '${root.path}/$name',
    )..createSync(recursive: true)).writeAsBytesSync(bytes);
    write('Europe/London', _v2);
    write('posixrules', _v1);
    write('Broken/Truncated', _v2.sublist(0, _v2.length - 3));
    write('zone.tab', '# tab'.codeUnits);
    write('posix/Europe/Paris', _v2);
    write('right/UTC', _v2);
    Link(
      '${root.path}/Europe/Belfast',
    ).createSync('${root.path}/Europe/London');
  });

  test('names under the directory, by ASCII case, whose TZif is whole', () {
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
    for (final name in [
      'Broken/Truncated',
      'zone.tab',
      'posix/Europe/Paris',
      'right/UTC',
      'X',
    ]) {
      expect(zoneKnownIn(zones, name), isFalse, reason: name);
    }
  });

  test('a TZif whose counts do not fit the file is refused', () {
    expect(isWholeTzif(Uint8List.fromList(_v1)), isTrue);
    expect(isWholeTzif(Uint8List.fromList(_v2)), isTrue);
    for (final cut in [1, 4, 40]) {
      expect(
        isWholeTzif(Uint8List.fromList(_v1.sublist(0, _v1.length - cut))),
        isFalse,
      );
    }
    // No local time types, which RFC 8536 forbids.
    expect(
      isWholeTzif(Uint8List.fromList(_header(0, [0, 0, 0, 0, 0, 0]))),
      isFalse,
    );
    // A version 2 file without its footer.
    expect(
      isWholeTzif(Uint8List.fromList(_v2.sublist(0, _v2.length - 6))),
      isFalse,
    );
  });

  test("every zone file of the host's database is whole", () {
    final host = zoneFilesUnder('/usr/share/zoneinfo');
    var zones = 0;
    for (final MapEntry(:key, value: path) in host.entries) {
      final bytes = File(path).readAsBytesSync();
      if (bytes.length < 4 || String.fromCharCodes(bytes, 0, 4) != 'TZif') {
        continue;
      }
      zones++;
      expect(isWholeTzif(bytes), isTrue, reason: key);
    }
    if (host.isNotEmpty) expect(zones, greaterThan(300));
  });

  test('no directory: null, so the bundled list decides', () {
    expect(zoneFilesUnder('${root.path}/missing'), isEmpty);
    expect(zoneKnownIn(null, 'Europe/London'), isNull);
  });
}

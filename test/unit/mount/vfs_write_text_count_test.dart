@Tags(['unit'])
library;

import 'package:collection/collection.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  // Three different lengths live in this handler and they must not be
  // confused:
  //
  //   write_text returns   CODEPOINTS   (CPython's len(str))
  //   stat().st_size is    BYTES        (UTF-8)
  //   Dart's String.length is UTF-16 CODE UNITS, which is neither
  //
  // They agree for ASCII, which is why the bug hides. mount_fs__ops.py picks
  // exactly the cases where they diverge.
  group('write_text returns codepoints', () {
    OsCallHandler handler() => memoryMountedOsHandler(
      mounts: const [MountDir(virtualPath: '/mnt')],
      files: const [],
    );

    // (source, codepoints, utf8Bytes, why)
    const cases = [
      ('hello', 5, 5, 'ASCII — all three agree'),
      ('\u{1f600}', 1, 4, 'emoji — 1 codepoint, 2 UTF-16 units, 4 bytes'),
      ('é', 1, 2, 'e-acute — 1 codepoint, 1 UTF-16 unit, 2 bytes'),
      ('世界', 2, 6, 'CJK — 2 codepoints, 2 units, 6 bytes'),
    ];

    for (final (text, codepoints, utf8Bytes, why) in cases) {
      test(why, () async {
        final handler0 = handler();

        expect(
          await handler0('Path.write_text', ['/mnt/u.txt', text], null),
          codepoints,
          reason: 'write_text must return codepoints',
        );

        final statResult = await handler0('Path.stat', ['/mnt/u.txt'], null);
        final stat = statResult! as MontyNamedTuple;
        final size = stat.values.elementAtOrNull(
          stat.fieldNames.indexOf('st_size'),
        );
        expect(
          (size! as MontyInt).value,
          utf8Bytes,
          reason: 'st_size must be UTF-8 bytes',
        );
      });
    }

    test('append_text also returns codepoints', () async {
      final handler0 = handler();

      await handler0('Path.write_text', ['/mnt/a.txt', 'x'], null);

      expect(
        await handler0('Path.append_text', ['/mnt/a.txt', '\u{1f600}'], null),
        1,
      );
    });
  });
}

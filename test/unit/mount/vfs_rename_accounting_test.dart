// Renaming a file must MOVE its memory charge, not orphan it.
//
// `VfsAccountant.recordMove` re-keys `_charge` entries from the old path to
// the new one:
//
//     if (entry.key == from || entry.key.startsWith('$from/'))
//
// Found by a MECHANICAL mutation pass: flipping that `||` to `&&`
// (vfs_accountant.dart:109) makes the condition UNSATISFIABLE -- a key equal
// to `from` cannot also start with `from/` -- so no charge ever moves, and the
// whole suite stayed green.
//
// What goes wrong: the charge stays keyed to a path that no longer exists and
// the new path is unaccounted, so the next write to the renamed file sees
// `prior = 0` in `_applyCharge` and the mount is billed a SECOND time for one
// file. A legitimate overwrite then fails against a budget it fits inside.
//
// THE FILE MUST BE WRITTEN THROUGH THE HANDLER, not seeded via
// MontyMemoryFile. Measured: seeded files are never charged, so `_charge` is
// empty, `recordMove` has nothing to move, and the mutant is INERT. Three
// earlier versions of this test used a seeded file and could not tell the two
// apart -- the test looked fine and proved nothing.
//
// THE BUDGET IS MEASURED, not guessed, and has to be tight. Written, renamed,
// then overwritten with the same 4000 bytes:
//     limit   mutant     correct
//     5000    refused    FITS      <- discriminates
//     6000    refused    FITS      <- discriminates
//     9000    FITS       FITS      <- absorbs the double charge
//    12000    FITS       FITS
// 12000 was the first budget tried; it is exactly where the test stops
// working.
//
// Falsifier: flip that `||` to `&&`; only this file fails.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  group('rename moves the memory charge with the file', () {
    test('overwriting a RENAMED file is not billed twice', () async {
      final payload = 'x' * 4000;
      final h = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/m', memoryUsageLimit: 5000)],
        files: const [],
      );

      await h('Path.write_text', ['/m/a.txt', payload], null);
      await h('Path.rename', ['/m/a.txt', '/m/b.txt'], null);

      // Same bytes, same size, different name: the delta is zero, so this
      // fits. If the charge did not follow the rename, the mount is billed for
      // a second copy and this throws MemoryError.
      await expectLater(
        h('Path.write_text', ['/m/b.txt', payload], null),
        completes,
        reason:
            'the charge did not move with the rename, so an overwrite of '
            'identical size was billed as a second copy',
      );
    });
  });
}

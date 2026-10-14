// Renaming a DIRECTORY must move its descendants' memory charges too.
//
// `VfsAccountant.recordMove` re-keys every charged path at or under the moved
// root. The descendant branch builds the new key from `to` plus the old
// suffix. If descendants kept their old keys, the renamed file would be
// unaccounted under its new path and a same-size overwrite would be billed as
// a second copy.
//
// The file is written THROUGH the handler (seeded files are never charged, so
// the mutant would be inert; see vfs_rename_accounting_test.dart).
//
// Falsifier: replace the descendant key with `oldPath`, or take its suffix from
// `to.length` (the two names differ in length for this reason); this test then
// fails with a MemoryError on the overwrite.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  group('directory rename moves descendant charges', () {
    test(
      'overwriting a file under a RENAMED directory is not billed twice',
      () async {
        final payload = 'x' * 4000;
        final h = memoryMountedOsHandler(
          mounts: const [MountDir(virtualPath: '/m', memoryUsageLimit: 5500)],
          files: const [],
        );

        await h('Path.mkdir', ['/m/d'], null);
        await h('Path.write_text', ['/m/d/f.txt', payload], null);
        await h('Path.rename', ['/m/d', '/m/renamed'], null);

        await expectLater(
          h('Path.write_text', ['/m/renamed/f.txt', payload], null),
          completes,
          reason: 'the child charge did not follow its directory',
        );
        expect(await h('Path.read_text', ['/m/renamed/f.txt'], null), payload);
      },
    );
  });
}

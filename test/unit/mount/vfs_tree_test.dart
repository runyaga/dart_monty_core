@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  group('the flat store cannot represent a directory', () {
    test('an empty directory exists after mkdir', () async {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/m')],
        files: const [],
      );

      await handler('Path.mkdir', ['/m/empty'], null);

      expect(await handler('Path.exists', ['/m/empty'], null), true);
      expect(await handler('Path.is_dir', ['/m/empty'], null), true);
      expect(await handler('Path.is_file', ['/m/empty'], null), false);
    });

    test('a seeded nested file creates its parent directories', () async {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/m')],
        files: [MontyMemoryFile('/m/a/b/c.txt', 'deep')],
      );

      expect(await handler('Path.is_dir', ['/m/a'], null), true);
      expect(await handler('Path.is_dir', ['/m/a/b'], null), true);
    });

    test('a component that is a file is not a directory', () async {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/m')],
        files: [MontyMemoryFile('/m/f.txt', 'x')],
      );

      // /m/f.txt/inner cannot exist: an intermediate component is a file.
      expect(await handler('Path.exists', ['/m/f.txt/inner'], null), false);
    });
  });

  group('seeding builds the interior', () {
    // os_access.py:837-838 raises ValueError at CONSTRUCTION for this. It is
    // not representable — /a.txt cannot be both a file and a directory — and
    // there is no useful runtime behaviour to degrade to, so it must fail
    // where the caller can see which file they got wrong.
    test('a file under a file is rejected when the handler is built', () {
      expect(
        () => memoryMountedOsHandler(
          mounts: const [MountDir(virtualPath: '/m')],
          files: [
            MontyMemoryFile('/m/a.txt', 'x'),
            MontyMemoryFile('/m/a.txt/b.txt', 'y'),
          ],
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('/m/a.txt, which is a file'),
          ),
        ),
      );
    });

    test('a mount with no files is still a directory', () async {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/empty')],
        files: const [],
      );

      expect(await handler('Path.exists', ['/empty'], null), true);
      expect(await handler('Path.is_dir', ['/empty'], null), true);
    });

    test('mkdir then iterdir lists the new directory', () async {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/m')],
        files: const [],
      );

      await handler('Path.mkdir', ['/m/sub'], null);
      final listing = await handler('Path.iterdir', ['/m'], null);

      expect((listing! as List).map((p) => '$p'), contains(contains('/m/sub')));
    });

    test('rmdir removes an empty directory that mkdir created', () async {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/m')],
        files: const [],
      );

      await handler('Path.mkdir', ['/m/gone'], null);
      await handler('Path.rmdir', ['/m/gone'], null);

      expect(await handler('Path.exists', ['/m/gone'], null), false);
    });

    // Renaming a directory moves the subtree AND rewrites the path of every
    // file under it — upstream's _update_paths_recursive (os_access.py:1128).
    // A caller holding the file sees the new path.
    test("renaming a directory rewrites its files' paths", () async {
      final nested = MontyMemoryFile('/m/old/deep/f.txt', 'v');
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/m')],
        files: [nested],
      );

      await handler('Path.rename', ['/m/old', '/m/new'], null);

      expect(nested.path, '/m/new/deep/f.txt');
      expect(
        await handler('Path.read_text', ['/m/new/deep/f.txt'], null),
        'v',
      );
    });
  });
}

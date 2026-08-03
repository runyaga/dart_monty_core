@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  group('resolve and absolute', () {
    OsCallHandler handler() => memoryMountedOsHandler(
      mounts: const [MountDir(virtualPath: '/mnt')],
      files: [MontyMemoryFile('/mnt/subdir/nested.txt', 'n')],
    );

    // They returned a bare String, so Python got a str and `.name` raised
    // AttributeError — mount_fs__ops.py calls `.name` on the result.
    test('resolve returns a Path, not a str', () async {
      final r = await handler()('Path.resolve', ['/mnt/subdir'], null);

      expect(r, isA<MontyPath>());
      expect('$r', contains('/mnt/subdir'));
    });

    test('absolute returns a Path, not a str', () async {
      expect(
        await handler()('Path.absolute', ['/mnt/subdir'], null),
        isA<MontyPath>(),
      );
    });

    // Upstream's Python host does NOT normalise `..`, and its comment claims
    // it does. CPython's resolve() does, so we follow CPython.
    test('resolve normalises .. and .', () async {
      final r = await handler()(
        'Path.resolve',
        ['/mnt/subdir/../subdir/./nested.txt'],
        null,
      );

      expect('$r', contains('/mnt/subdir/nested.txt'));
    });

    test('resolve of a path that does not exist still normalises', () async {
      final r = await handler()('Path.resolve', ['/mnt/a/../b.txt'], null);

      expect('$r', contains('/mnt/b.txt'));
    });
  });
}

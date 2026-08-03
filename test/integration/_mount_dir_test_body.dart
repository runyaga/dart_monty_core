// Shared test body for ffi_mount_dir_test.dart and
// wasm_mount_dir_test.dart.
//
// Exercises memoryMountedOsHandler from end-to-end Python: a script
// uses pathlib.Path against a mount, the handler resolves the request
// through the in-memory vfs, and the result round-trips back to Dart.

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void runMountDirTests() {
  group('MountDir + memoryMountedOsHandler', () {
    test('Python reads a file mounted at /data', () async {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/data')],
        files: [MontyMemoryFile('/data/hello.txt', 'Hello from VFS!')],
      );

      final r = await Monty(
        'import pathlib\npathlib.Path("/data/hello.txt").read_text()',
      ).run(osHandler: handler);

      expect(r.error, isNull);
      expect(r.value.dartValue, 'Hello from VFS!');
    });

    test('Python writes through a writable mount', () async {
      final out = MontyMemoryFile('/tmp/out.txt', '');
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/tmp')],
        files: [out],
      );

      final r = await Monty(
        'import pathlib\n'
        'pathlib.Path("/tmp/out.txt").write_text("written from Python")',
      ).run(osHandler: handler);

      expect(r.error, isNull);
      expect(out.content, VfsText('written from Python'));
    });

    test('readOnly mount surfaces a write rejection to Python', () async {
      final handler = memoryMountedOsHandler(
        mounts: const [
          MountDir(virtualPath: '/data', mode: MountMode.readOnly),
        ],
        files: [MontyMemoryFile('/data/x.txt', 'old')],
      );

      // The handler raises OsCallException(pythonExceptionType:
      // 'PermissionError'), delivered to Python as a typed PermissionError.
      final r = await Monty(
        'import pathlib\n'
        'pathlib.Path("/data/x.txt").write_text("new")',
      ).run(osHandler: handler);

      expect(r.error, isNotNull);
      expect(r.error?.excType, 'PermissionError');
      expect(r.error?.message, contains('/data/x.txt'));
    });

    test(
      'Python sees a path outside every mount as a PermissionError',
      () async {
        final handler = memoryMountedOsHandler(
          mounts: const [MountDir(virtualPath: '/data')],
          files: const [],
        );

        final r = await Monty(
          'import pathlib\npathlib.Path("/etc/passwd").read_text()',
        ).run(osHandler: handler);

        expect(r.error, isNotNull);
        expect(r.error?.excType, 'PermissionError');
        expect(r.error?.message, contains('/etc/passwd'));
      },
    );

    test('Python can catch the typed OS exception with except', () async {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/data')],
        files: const [],
      );

      final r = await Monty(
        'import pathlib\n'
        'try:\n'
        '    pathlib.Path("/data/missing.txt").read_text()\n'
        "    out = 'no-error'\n"
        'except FileNotFoundError as e:\n'
        "    out = ('caught', str(e))\n"
        'out',
      ).run(osHandler: handler);

      expect(r.error, isNull);
      final tuple = r.value.dartValue! as List<Object?>;
      expect(tuple.first, 'caught');
      expect(tuple[1], contains('/data/missing.txt'));
    });

    test('exists / is_file / is_dir reflect mount state', () async {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/data')],
        files: [MontyMemoryFile('/data/sub/x.txt', 'hi')],
      );

      final r = await Monty('''
import pathlib
data = pathlib.Path("/data/sub/x.txt")
sub = pathlib.Path("/data/sub")
[data.exists(), data.is_file(), sub.is_dir(), sub.is_file()]
''').run(osHandler: handler);

      expect(r.error, isNull);
      expect(r.value.dartValue, [true, true, true, false]);
    });
  });
}

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
        vfs: {'/data/hello.txt': 'Hello from VFS!'},
      );

      final r = await Monty(
        'import pathlib\npathlib.Path("/data/hello.txt").read_text()',
      ).run(osHandler: handler);

      expect(r.error, isNull);
      expect(r.value.dartValue, 'Hello from VFS!');
    });

    test('Python writes through a writable mount', () async {
      final vfs = <String, String>{};
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/tmp')],
        vfs: vfs,
      );

      final r = await Monty(
        'import pathlib\n'
        'pathlib.Path("/tmp/out.txt").write_text("written from Python")',
      ).run(osHandler: handler);

      expect(r.error, isNull);
      expect(vfs['/tmp/out.txt'], 'written from Python');
    });

    test('readOnly mount surfaces a write rejection to Python', () async {
      final handler = memoryMountedOsHandler(
        mounts: const [
          MountDir(virtualPath: '/data', mode: MountMode.readOnly),
        ],
        vfs: {'/data/x.txt': 'old'},
      );

      // The handler raises OsCallException(pythonExceptionType:
      // 'PermissionError'). REPL bindings don't yet plumb typed Python
      // exceptions, so it surfaces as RuntimeError with the type name
      // prefixed into the message.
      final r = await Monty(
        'import pathlib\n'
        'pathlib.Path("/data/x.txt").write_text("new")',
      ).run(osHandler: handler);

      expect(r.error, isNotNull);
      expect(r.error?.message, contains('PermissionError'));
      expect(r.error?.message, contains('/data/x.txt'));
    });

    test('Python sees a path outside every mount as a runtime error', () async {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/data')],
        vfs: const {},
      );

      final r = await Monty(
        'import pathlib\npathlib.Path("/etc/passwd").read_text()',
      ).run(osHandler: handler);

      expect(r.error, isNotNull);
      expect(r.error?.message, contains('PermissionError'));
      expect(r.error?.message, contains('/etc/passwd'));
    });

    test('exists / is_file / is_dir reflect mount state', () async {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/data')],
        vfs: {'/data/sub/x.txt': 'hi'},
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

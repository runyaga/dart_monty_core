// Unit tests for memoryMountedOsHandler — path normalisation, mount
// resolution, mode enforcement, and fallthrough behavior. The handler
// is pure Dart, so the unit-level coverage exercises every code path
// without needing an interpreter.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  group('memoryMountedOsHandler', () {
    test('reads a file via Path.read_text', () async {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/data')],
        vfs: {'/data/hello.txt': 'Hello!'},
      );

      final result = await handler('Path.read_text', ['/data/hello.txt'], null);
      expect(result, 'Hello!');
    });

    test('raises FileNotFoundError when path is unknown inside mount', () {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/data')],
        vfs: const {},
      );

      expect(
        () => handler('Path.read_text', ['/data/missing.txt'], null),
        throwsA(
          isA<OsCallException>().having(
            (e) => e.pythonExceptionType,
            'pythonExceptionType',
            'FileNotFoundError',
          ),
        ),
      );
    });

    test('write_text round-trips through the vfs map', () async {
      final vfs = <String, String>{};
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/tmp')],
        vfs: vfs,
      );

      await handler('Path.write_text', ['/tmp/out.txt', 'written'], null);
      expect(vfs['/tmp/out.txt'], 'written');

      final read = await handler('Path.read_text', ['/tmp/out.txt'], null);
      expect(read, 'written');
    });

    test('readOnly mount rejects writes with PermissionError', () {
      final handler = memoryMountedOsHandler(
        mounts: const [
          MountDir(virtualPath: '/data', mode: MountMode.readOnly),
        ],
        vfs: {'/data/x.txt': 'old'},
      );

      expect(
        () => handler('Path.write_text', ['/data/x.txt', 'new'], null),
        throwsA(
          isA<OsCallException>().having(
            (e) => e.pythonExceptionType,
            'pythonExceptionType',
            'PermissionError',
          ),
        ),
      );
    });

    test('writeBytesLimit rejects oversize writes with OSError', () {
      final handler = memoryMountedOsHandler(
        mounts: const [
          MountDir(virtualPath: '/data', writeBytesLimit: 10),
        ],
        vfs: const {},
      );

      expect(
        () => handler(
          'Path.write_text',
          ['/data/big.txt', 'x' * 100],
          null,
        ),
        throwsA(
          isA<OsCallException>().having(
            (e) => e.pythonExceptionType,
            'pythonExceptionType',
            'OSError',
          ),
        ),
      );
    });

    test('rejects "../" traversal that escapes the mount', () {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/sandbox')],
        vfs: {'/etc/passwd': 'root:x:0:0'},
      );

      expect(
        () => handler(
          'Path.read_text',
          ['/sandbox/../etc/passwd'],
          null,
        ),
        throwsA(
          isA<OsCallException>().having(
            (e) => e.pythonExceptionType,
            'pythonExceptionType',
            'PermissionError',
          ),
        ),
      );
    });

    test('exists / is_file / is_dir reflect the vfs structure', () async {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/data')],
        vfs: {'/data/sub/x.txt': 'hi'},
      );

      expect(await handler('Path.exists', ['/data/sub/x.txt'], null), true);
      expect(await handler('Path.is_file', ['/data/sub/x.txt'], null), true);
      expect(await handler('Path.is_dir', ['/data/sub/x.txt'], null), false);

      // /data/sub is a directory because it has children.
      expect(await handler('Path.exists', ['/data/sub'], null), true);
      expect(await handler('Path.is_dir', ['/data/sub'], null), true);
      expect(await handler('Path.is_file', ['/data/sub'], null), false);

      // Non-existent path.
      expect(await handler('Path.exists', ['/data/missing'], null), false);
    });

    test('iterdir lists immediate children', () async {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/data')],
        vfs: {
          '/data/a.txt': '1',
          '/data/b.txt': '2',
          '/data/sub/c.txt': '3',
        },
      );

      final children =
          (await handler('Path.iterdir', ['/data'], null))! as List<MontyPath>;
      final paths = children.map((p) => p.value).toSet();
      expect(paths, {'/data/a.txt', '/data/b.txt', '/data/sub'});
    });

    test('unlink requires writable mount and existing file', () async {
      final vfs = {'/data/x.txt': 'gone'};
      final readOnly = memoryMountedOsHandler(
        mounts: const [
          MountDir(virtualPath: '/data', mode: MountMode.readOnly),
        ],
        vfs: vfs,
      );
      expect(
        () => readOnly('Path.unlink', ['/data/x.txt'], null),
        throwsA(isA<OsCallException>()),
      );
      expect(vfs.containsKey('/data/x.txt'), true);

      final writable = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/data')],
        vfs: vfs,
      );
      await writable('Path.unlink', ['/data/x.txt'], null);
      expect(vfs.containsKey('/data/x.txt'), false);
    });

    test('paths outside every mount fall through to fallthrough', () async {
      var fallthroughCalled = 0;
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/data')],
        vfs: const {},
        fallthrough: (op, args, kwargs) async {
          fallthroughCalled++;
          return null;
        },
      );

      await handler('Path.read_text', ['/etc/passwd'], null);
      expect(fallthroughCalled, 1);
    });

    test('paths outside mounts raise PermissionError without fallthrough', () {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/data')],
        vfs: const {},
      );

      expect(
        () => handler('Path.read_text', ['/etc/passwd'], null),
        throwsA(
          isA<OsCallException>().having(
            (e) => e.pythonExceptionType,
            'pythonExceptionType',
            'PermissionError',
          ),
        ),
      );
    });

    test('non-Path operations fall through cleanly', () async {
      var fallthroughOp = '';
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/data')],
        vfs: const {},
        fallthrough: (op, args, kwargs) async {
          fallthroughOp = op;
          return 'env-value';
        },
      );

      final result = await handler('os.getenv', ['HOME'], null);
      expect(result, 'env-value');
      expect(fallthroughOp, 'os.getenv');
    });

    test('longest matching mount wins', () async {
      final handler = memoryMountedOsHandler(
        mounts: const [
          MountDir(virtualPath: '/data', mode: MountMode.readOnly),
          MountDir(virtualPath: '/data/scratch'),
        ],
        vfs: {'/data/scratch/x.txt': 'old'},
      );

      // /data/scratch/x.txt should resolve under the readWrite mount,
      // so this write should NOT raise PermissionError.
      await handler(
        'Path.write_text',
        ['/data/scratch/x.txt', 'new'],
        null,
      );
    });
  });
}

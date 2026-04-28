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
      expect(vfs, contains('/data/x.txt'));

      final writable = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/data')],
        vfs: vfs,
      );
      await writable('Path.unlink', ['/data/x.txt'], null);
      expect(vfs, isNot(contains('/data/x.txt')));
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

    // -------------------------------------------------------------------
    // Path.mkdir
    // -------------------------------------------------------------------

    test('mkdir succeeds as a no-op when parent (mount root) exists', () async {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/sandbox')],
        vfs: const {},
      );
      // Parent is the mount root /sandbox — implicitly exists.
      final r = await handler('Path.mkdir', ['/sandbox/data'], null);
      expect(r, isNull);
    });

    test('mkdir parents=False raises FileNotFoundError on missing parent', () {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/sandbox')],
        vfs: const {},
      );
      expect(
        () => handler('Path.mkdir', ['/sandbox/a/b/c'], null),
        throwsA(
          isA<OsCallException>().having(
            (e) => e.pythonExceptionType,
            'pythonExceptionType',
            'FileNotFoundError',
          ),
        ),
      );
    });

    test(
      'mkdir parents=True succeeds when intermediates are missing',
      () async {
        final handler = memoryMountedOsHandler(
          mounts: const [MountDir(virtualPath: '/sandbox')],
          vfs: const {},
        );
        final r = await handler(
          'Path.mkdir',
          ['/sandbox/a/b/c'],
          {'parents': true},
        );
        expect(r, isNull);
      },
    );

    test('mkdir raises FileExistsError when a file occupies the path', () {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/sandbox')],
        vfs: {'/sandbox/data': 'I am a file pretending to be a dir'},
      );
      expect(
        () => handler('Path.mkdir', ['/sandbox/data'], null),
        throwsA(
          isA<OsCallException>().having(
            (e) => e.pythonExceptionType,
            'pythonExceptionType',
            'FileExistsError',
          ),
        ),
      );
    });

    test(
      'mkdir raises FileExistsError on existing implicit dir w/o exist_ok',
      () {
        final handler = memoryMountedOsHandler(
          mounts: const [MountDir(virtualPath: '/sandbox')],
          vfs: {'/sandbox/data/file.txt': 'x'},
        );
        expect(
          () => handler('Path.mkdir', ['/sandbox/data'], null),
          throwsA(
            isA<OsCallException>().having(
              (e) => e.pythonExceptionType,
              'pythonExceptionType',
              'FileExistsError',
            ),
          ),
        );
      },
    );

    test(
      'mkdir exist_ok=True silently succeeds on existing implicit dir',
      () async {
        final handler = memoryMountedOsHandler(
          mounts: const [MountDir(virtualPath: '/sandbox')],
          vfs: {'/sandbox/data/file.txt': 'x'},
        );
        final r = await handler(
          'Path.mkdir',
          ['/sandbox/data'],
          {'exist_ok': true},
        );
        expect(r, isNull);
      },
    );

    test('mkdir on readOnly mount raises PermissionError', () {
      final handler = memoryMountedOsHandler(
        mounts: const [
          MountDir(virtualPath: '/sandbox', mode: MountMode.readOnly),
        ],
        vfs: const {},
      );
      expect(
        () => handler('Path.mkdir', ['/sandbox/data'], null),
        throwsA(
          isA<OsCallException>().having(
            (e) => e.pythonExceptionType,
            'pythonExceptionType',
            'PermissionError',
          ),
        ),
      );
    });

    // -------------------------------------------------------------------
    // Path.rmdir
    // -------------------------------------------------------------------

    test('rmdir on a file raises NotADirectoryError', () {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/sandbox')],
        vfs: {'/sandbox/file.txt': 'x'},
      );
      expect(
        () => handler('Path.rmdir', ['/sandbox/file.txt'], null),
        throwsA(
          isA<OsCallException>().having(
            (e) => e.pythonExceptionType,
            'pythonExceptionType',
            'NotADirectoryError',
          ),
        ),
      );
    });

    test('rmdir on non-empty directory raises OSError', () {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/sandbox')],
        vfs: {'/sandbox/data/file.txt': 'x'},
      );
      expect(
        () => handler('Path.rmdir', ['/sandbox/data'], null),
        throwsA(
          isA<OsCallException>().having(
            (e) => e.pythonExceptionType,
            'pythonExceptionType',
            'OSError',
          ),
        ),
      );
    });

    test('rmdir on empty/non-existent path is a no-op success', () async {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/sandbox')],
        vfs: const {},
      );
      final r = await handler('Path.rmdir', ['/sandbox/empty'], null);
      expect(r, isNull);
    });

    test('rmdir on readOnly mount raises PermissionError', () {
      final handler = memoryMountedOsHandler(
        mounts: const [
          MountDir(virtualPath: '/sandbox', mode: MountMode.readOnly),
        ],
        vfs: const {},
      );
      expect(
        () => handler('Path.rmdir', ['/sandbox/data'], null),
        throwsA(
          isA<OsCallException>().having(
            (e) => e.pythonExceptionType,
            'pythonExceptionType',
            'PermissionError',
          ),
        ),
      );
    });

    // -------------------------------------------------------------------
    // Path.rename
    // -------------------------------------------------------------------

    test('rename moves a file by re-keying the map', () async {
      final vfs = {'/sandbox/a.txt': 'alpha'};
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/sandbox')],
        vfs: vfs,
      );
      await handler('Path.rename', ['/sandbox/a.txt', '/sandbox/b.txt'], null);
      expect(vfs.containsKey('/sandbox/a.txt'), false);
      expect(vfs['/sandbox/b.txt'], 'alpha');
    });

    test('rename across two writable mounts succeeds', () async {
      final vfs = {'/data/x.txt': 'x'};
      final handler = memoryMountedOsHandler(
        mounts: const [
          MountDir(virtualPath: '/data'),
          MountDir(virtualPath: '/scratch'),
        ],
        vfs: vfs,
      );
      await handler('Path.rename', ['/data/x.txt', '/scratch/x.txt'], null);
      expect(vfs['/scratch/x.txt'], 'x');
      expect(vfs.containsKey('/data/x.txt'), false);
    });

    test('rename with readOnly source mount raises PermissionError', () {
      final handler = memoryMountedOsHandler(
        mounts: const [
          MountDir(virtualPath: '/data', mode: MountMode.readOnly),
        ],
        vfs: {'/data/x.txt': 'x'},
      );
      expect(
        () => handler('Path.rename', ['/data/x.txt', '/data/y.txt'], null),
        throwsA(
          isA<OsCallException>().having(
            (e) => e.pythonExceptionType,
            'pythonExceptionType',
            'PermissionError',
          ),
        ),
      );
    });

    test('rename with readOnly destination mount raises PermissionError', () {
      final handler = memoryMountedOsHandler(
        mounts: const [
          MountDir(virtualPath: '/src'),
          MountDir(virtualPath: '/dst', mode: MountMode.readOnly),
        ],
        vfs: {'/src/x.txt': 'x'},
      );
      expect(
        () => handler('Path.rename', ['/src/x.txt', '/dst/x.txt'], null),
        throwsA(
          isA<OsCallException>().having(
            (e) => e.pythonExceptionType,
            'pythonExceptionType',
            'PermissionError',
          ),
        ),
      );
    });

    test('rename of a missing path raises FileNotFoundError', () {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/sandbox')],
        vfs: const {},
      );
      expect(
        () => handler('Path.rename', ['/sandbox/a', '/sandbox/b'], null),
        throwsA(
          isA<OsCallException>().having(
            (e) => e.pythonExceptionType,
            'pythonExceptionType',
            'FileNotFoundError',
          ),
        ),
      );
    });

    test('rename of an implicit directory re-prefixes every child', () async {
      final vfs = {
        '/sandbox/old/a.txt': 'a',
        '/sandbox/old/sub/b.txt': 'b',
        '/sandbox/keep.txt': 'keep',
      };
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/sandbox')],
        vfs: vfs,
      );
      await handler('Path.rename', ['/sandbox/old', '/sandbox/new'], null);
      expect(vfs.containsKey('/sandbox/old/a.txt'), false);
      expect(vfs.containsKey('/sandbox/old/sub/b.txt'), false);
      expect(vfs['/sandbox/new/a.txt'], 'a');
      expect(vfs['/sandbox/new/sub/b.txt'], 'b');
      expect(vfs['/sandbox/keep.txt'], 'keep');
    });

    test(
      'rename onto an existing non-empty directory raises OSError',
      () {
        final handler = memoryMountedOsHandler(
          mounts: const [MountDir(virtualPath: '/sandbox')],
          vfs: {
            '/sandbox/old/a.txt': 'a',
            '/sandbox/new/b.txt': 'b',
          },
        );
        expect(
          () => handler('Path.rename', ['/sandbox/old', '/sandbox/new'], null),
          throwsA(
            isA<OsCallException>().having(
              (e) => e.pythonExceptionType,
              'pythonExceptionType',
              'OSError',
            ),
          ),
        );
      },
    );
  });
}

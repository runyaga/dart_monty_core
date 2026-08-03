@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

Matcher raises(String excType, String message) => throwsA(
  isA<OsCallException>()
      .having((e) => e.pythonExceptionType, 'excType', excType)
      .having((e) => e.message, 'message', message),
);

void main() {
  // Every message below is asserted verbatim by mount_fs__errors.py; the
  // fixture names the path, and the errno prefix is part of the string.
  group('directory-aware policy', () {
    OsCallHandler handler() => memoryMountedOsHandler(
      mounts: const [MountDir(virtualPath: '/mnt')],
      files: [
        MontyMemoryFile('/mnt/hello.txt', 'hi'),
        MontyMemoryFile('/mnt/subdir/nested.txt', 'n'),
      ],
    );

    // iterdir returned an EMPTY LIST for a path that is not there, which is
    // the worst of the three answers: it looks like a successful listing of
    // an empty directory, so a caller cannot tell the difference.
    test('iterdir of a nonexistent path raises FileNotFoundError', () {
      expect(
        () => handler()('Path.iterdir', ['/mnt/nonexistent'], null),
        raises(
          'FileNotFoundError',
          "[Errno 2] No such file or directory: '/mnt/nonexistent'",
        ),
      );
    });

    test('iterdir of a file raises NotADirectoryError', () {
      expect(
        () => handler()('Path.iterdir', ['/mnt/hello.txt'], null),
        raises(
          'NotADirectoryError',
          "[Errno 20] Not a directory: '/mnt/hello.txt'",
        ),
      );
    });

    test('iterdir of a real directory still lists it', () async {
      final listing = await handler()('Path.iterdir', ['/mnt/subdir'], null);

      expect(
        (listing! as List).map((p) => '$p'),
        [contains('/mnt/subdir/nested.txt')],
      );
    });

    // CPython raises IsADirectoryError on Linux and PermissionError on macOS;
    // the fixture accepts either. IsADirectoryError is the one that carries
    // the useful message.
    test('unlink of a directory raises IsADirectoryError', () {
      expect(
        () => handler()('Path.unlink', ['/mnt/subdir'], null),
        raises('IsADirectoryError', "[Errno 21] Is a directory: '/mnt/subdir'"),
      );
    });

    test('unlink of a directory leaves it intact', () async {
      final h = handler();

      await expectLater(
        () => h('Path.unlink', ['/mnt/subdir'], null),
        throwsA(isA<OsCallException>()),
      );
      expect(await h('Path.read_text', ['/mnt/subdir/nested.txt'], null), 'n');
    });

    // These three already held before Phase 2; they are here so the whole
    // rmdir matrix reads in one place.
    test('rmdir of a nonexistent path raises FileNotFoundError', () {
      expect(
        () => handler()('Path.rmdir', ['/mnt/nope'], null),
        raises(
          'FileNotFoundError',
          "[Errno 2] No such file or directory: '/mnt/nope'",
        ),
      );
    });

    test('rmdir of a file raises NotADirectoryError', () {
      expect(
        () => handler()('Path.rmdir', ['/mnt/hello.txt'], null),
        raises(
          'NotADirectoryError',
          "[Errno 20] Not a directory: '/mnt/hello.txt'",
        ),
      );
    });

    // CPython uses ONE message for both "a file is there" and "a directory
    // is there", and mount_fs__errors.py asserts it for plain mkdir() as well
    // as mkdir(parents=True, exist_ok=False). We had invented
    // `Directory exists: <path>` for the directory case.
    test('mkdir of an existing directory reports File exists', () {
      expect(
        () => handler()('Path.mkdir', ['/mnt/subdir'], null),
        raises('FileExistsError', "[Errno 17] File exists: '/mnt/subdir'"),
      );
    });

    test('mkdir(parents: true, exist_ok: false) reports the same', () {
      expect(
        () => handler()(
          'Path.mkdir',
          ['/mnt/subdir'],
          {
            'parents': true,
            'exist_ok': false,
          },
        ),
        raises('FileExistsError', "[Errno 17] File exists: '/mnt/subdir'"),
      );
    });

    test('mkdir(exist_ok: true) on an existing directory succeeds', () async {
      expect(
        await handler()('Path.mkdir', ['/mnt/subdir'], {'exist_ok': true}),
        isNull,
      );
    });

    test('rmdir of a non-empty directory raises OSError 39', () {
      expect(
        () => handler()('Path.rmdir', ['/mnt/subdir'], null),
        raises('OSError', "[Errno 39] Directory not empty: '/mnt/subdir'"),
      );
    });
  });
}

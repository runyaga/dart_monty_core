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
  // CPython's rename is four different errors and one silent overwrite,
  // depending on what is at each end. mount_fs__errors.py asserts the
  // messages verbatim.
  group('rename', () {
    OsCallHandler handler() => memoryMountedOsHandler(
      mounts: const [MountDir(virtualPath: '/mnt')],
      files: [
        MontyMemoryFile('/mnt/hello.txt', 'hi'),
        MontyMemoryFile('/mnt/other.txt', 'other'),
        MontyMemoryFile('/mnt/full/a.txt', 'a'),
        MontyMemoryFile('/mnt/src/moved.txt', 'moved'),
      ],
    );

    Future<OsCallHandler> withEmptyDir() async {
      final h = handler();
      await h('Path.mkdir', ['/mnt/empty'], null);

      return h;
    }

    test('file onto a MISSING name moves it', () async {
      final h = handler();

      await h('Path.rename', ['/mnt/hello.txt', '/mnt/renamed.txt'], null);

      expect(await h('Path.exists', ['/mnt/hello.txt'], null), false);
      expect(await h('Path.read_text', ['/mnt/renamed.txt'], null), 'hi');
    });

    // The easy one to get wrong: POSIX rename REPLACES an existing file
    // silently. Refusing here would be a plausible-looking bug.
    test('file onto an EXISTING FILE overwrites it silently', () async {
      final h = handler();

      await h('Path.rename', ['/mnt/hello.txt', '/mnt/other.txt'], null);

      expect(await h('Path.exists', ['/mnt/hello.txt'], null), false);
      expect(await h('Path.read_text', ['/mnt/other.txt'], null), 'hi');
    });

    test('file onto an EXISTING DIRECTORY raises IsADirectoryError', () {
      expect(
        () => handler()('Path.rename', ['/mnt/hello.txt', '/mnt/full'], null),
        raises('IsADirectoryError', "[Errno 21] Is a directory: '/mnt/full'"),
      );
    });

    test('directory onto an EXISTING FILE raises NotADirectoryError', () {
      expect(
        () => handler()('Path.rename', ['/mnt/src', '/mnt/hello.txt'], null),
        raises(
          'NotADirectoryError',
          "[Errno 20] Not a directory: '/mnt/hello.txt'",
        ),
      );
    });

    test('directory onto a NON-EMPTY directory raises errno 39', () {
      expect(
        () => handler()('Path.rename', ['/mnt/src', '/mnt/full'], null),
        raises('OSError', "[Errno 39] Directory not empty: '/mnt/full'"),
      );
    });

    // POSIX allows this, and the fixture exercises it explicitly.
    test('directory onto an EMPTY directory succeeds and moves it', () async {
      final h = await withEmptyDir();

      await h('Path.rename', ['/mnt/src', '/mnt/empty'], null);

      expect(
        await h('Path.read_text', ['/mnt/empty/moved.txt'], null),
        'moved',
      );
      expect(await h('Path.exists', ['/mnt/src'], null), false);
    });

    test('renaming a MISSING path raises FileNotFoundError', () {
      expect(
        () => handler()('Path.rename', [
          '/mnt/nonexistent.txt',
          '/mnt/new.txt',
        ], null),
        raises(
          'FileNotFoundError',
          "[Errno 2] No such file or directory: '/mnt/nonexistent.txt'",
        ),
      );
    });

    test('renaming into a MISSING parent raises FileNotFoundError', () {
      expect(
        () => handler()('Path.rename', [
          '/mnt/hello.txt',
          '/mnt/nope/x.txt',
        ], null),
        raises(
          'FileNotFoundError',
          "[Errno 2] No such file or directory: '/mnt/nope/x.txt'",
        ),
      );
    });

    test('a failed rename leaves both ends untouched', () async {
      final h = handler();

      await expectLater(
        () => h('Path.rename', ['/mnt/src', '/mnt/full'], null),
        throwsA(isA<OsCallException>()),
      );
      expect(await h('Path.read_text', ['/mnt/src/moved.txt'], null), 'moved');
      expect(await h('Path.read_text', ['/mnt/full/a.txt'], null), 'a');
    });

    // A TARGET outside every mount used to decline, which with no fallthrough
    // surfaced as `PermissionError: Permission denied: '<target>'` — telling
    // sandboxed code exactly which paths lie outside the sandbox, the secret
    // the SOURCE path was changed to stop telling (FB-11 P5). Upstream does
    // not pin this: monty-fs/tests/fs_security.rs:1078 accepts either outcome.
    group('a target outside every mount is absent, not denied', () {
      test('it raises FileNotFoundError, never PermissionError', () async {
        final h = handler();

        await expectLater(
          () => h('Path.rename', ['/mnt/hello.txt', '/etc/passwd'], null),
          raises(
            'FileNotFoundError',
            "[Errno 2] No such file or directory: '/etc/passwd'",
          ),
        );
      });

      test('a `..` escape normalises and gets the same answer', () async {
        final h = handler();

        await expectLater(
          () => h('Path.rename', [
            '/mnt/hello.txt',
            '/mnt/../../../etc/passwd',
          ], null),
          raises(
            'FileNotFoundError',
            "[Errno 2] No such file or directory: '/etc/passwd'",
          ),
        );
      });

      // The point of the change: outside-a-mount and merely-missing must be
      // INDISTINGUISHABLE, or the exception itself maps the sandbox.
      test('it is indistinguishable from a missing parent inside', () async {
        final h = handler();

        Future<Object?> err(String target) async {
          try {
            await h('Path.rename', ['/mnt/hello.txt', target], null);

            return 'no throw';
          } on OsCallException catch (e) {
            return '${e.pythonExceptionType}|${e.message}';
          }
        }

        // Identical modulo the path itself, which is the whole property: one
        // target is outside all mounts, the other is inside a mount but under
        // a directory that does not exist, and nothing in the answer says
        // which.
        String sameExcept(String p) =>
            "FileNotFoundError|[Errno 2] No such file or directory: '$p'";

        expect(await err('/outside/x.txt'), sameExcept('/outside/x.txt'));
        expect(await err('/mnt/nope/x.txt'), sameExcept('/mnt/nope/x.txt'));
      });

      test('the source is left untouched', () async {
        final h = handler();

        await expectLater(
          () => h('Path.rename', ['/mnt/hello.txt', '/etc/passwd'], null),
          throwsA(isA<OsCallException>()),
        );
        expect(await h('Path.read_text', ['/mnt/hello.txt'], null), 'hi');
      });

      // Declining used to rewrite the call to `[target]`, so a fallthrough
      // handler received Path.rename with its SOURCE dropped.
      test('declining to a fallthrough keeps BOTH arguments', () async {
        final seen = <List<Object?>>[];
        final h = memoryMountedOsHandler(
          mounts: const [MountDir(virtualPath: '/mnt')],
          files: [MontyMemoryFile('/mnt/hello.txt', 'hi')],
          fallthrough: (op, args, kwargs) async {
            seen.add(args);

            return null;
          },
        );

        await h('Path.rename', ['/mnt/hello.txt', '/etc/passwd'], null);

        expect(seen, [
          ['/mnt/hello.txt', '/etc/passwd'],
        ]);
      });
    });
  });
}

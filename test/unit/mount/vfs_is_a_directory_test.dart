@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

/// `[Errno 21] Is a directory: '<path>'` — CPython's wording, which upstream
/// reproduces verbatim (`os_access.py:950-951`, `:960`).
Matcher isADirectory(String path) => throwsA(
  isA<OsCallException>()
      .having((e) => e.pythonExceptionType, 'excType', 'IsADirectoryError')
      .having(
        (e) => e.message,
        'message',
        "[Errno 21] Is a directory: '$path'",
      ),
);

void main() {
  group('a directory is not a file', () {
    // Handler with /m/d as a real directory holding one file.
    OsCallHandler handlerWithDir() => memoryMountedOsHandler(
      mounts: const [MountDir(virtualPath: '/m')],
      files: [MontyMemoryFile('/m/d/keep.txt', 'precious')],
    );

    // THE P0. Writing to a directory used to SUCCEED: `putContent` saw the
    // existing node was not a VfsFile and replaced it with one, taking the
    // directory and everything under it with it. Silent data loss, not a
    // wrong message.
    test('write_text to a directory raises and keeps its contents', () async {
      final handler = handlerWithDir();

      await expectLater(
        () => handler('Path.write_text', ['/m/d', 'clobber'], null),
        isADirectory('/m/d'),
      );
      expect(
        await handler('Path.read_text', ['/m/d/keep.txt'], null),
        'precious',
      );
      expect(await handler('Path.is_dir', ['/m/d'], null), true);
    });

    test('write_bytes to a directory raises and keeps its contents', () async {
      final handler = handlerWithDir();

      await expectLater(
        () => handler('Path.write_bytes', [
          '/m/d',
          [1, 2, 3],
        ], null),
        isADirectory('/m/d'),
      );
      expect(
        await handler('Path.read_text', ['/m/d/keep.txt'], null),
        'precious',
      );
    });

    test('append_text to a directory raises', () async {
      await expectLater(
        () => handlerWithDir()('Path.append_text', ['/m/d', 'x'], null),
        isADirectory('/m/d'),
      );
    });

    test('append_bytes to a directory raises', () async {
      await expectLater(
        () => handlerWithDir()('Path.append_bytes', [
          '/m/d',
          [1],
        ], null),
        isADirectory('/m/d'),
      );
    });

    // Reads reported FileNotFoundError, which is wrong twice: the path is
    // right there, and an LLM told a file is missing will try to create it.
    test('read_text of a directory raises IsADirectoryError', () async {
      await expectLater(
        () => handlerWithDir()('Path.read_text', ['/m/d'], null),
        isADirectory('/m/d'),
      );
    });

    test('read_bytes of a directory raises IsADirectoryError', () async {
      await expectLater(
        () => handlerWithDir()('Path.read_bytes', ['/m/d'], null),
        isADirectory('/m/d'),
      );
    });

    // A mount root is a directory like any other now, so it gets the same
    // answer rather than the flat model's special case.
    test('the mount root itself is a directory', () async {
      await expectLater(
        () => handlerWithDir()('Path.write_text', ['/m', 'x'], null),
        isADirectory('/m'),
      );
    });

    // open() already raises this for read modes (fixed in 1b); write modes go
    // through the same store and must agree.
    test('open(dir, "w") raises rather than clobbering', () async {
      final handler = handlerWithDir();

      await expectLater(
        () => handler('open', ['/m/d', 'w'], null),
        isADirectory('/m/d'),
      );
      expect(
        await handler('Path.read_text', ['/m/d/keep.txt'], null),
        'precious',
      );
    });
  });
}

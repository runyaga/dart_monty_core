// Unit tests for memoryMountedOsHandler — path normalisation, mount
// resolution, mode enforcement, and fallthrough behavior. The handler
// is pure Dart, so the unit-level coverage exercises every code path
// without needing an interpreter.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

/// Reads a `StatResult` field by NAME. Indexing by position would also trip
/// DCM's unsafe-collection rule, and a positional read says nothing about
/// which field it meant.
MontyValue? _stat(MontyNamedTuple t, String field) {
  final i = t.fieldNames.indexOf(field);

  return i < 0 ? null : t.values.elementAtOrNull(i);
}

void main() {
  group('memoryMountedOsHandler', () {
    test('reads a file via Path.read_text', () async {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/data')],
        files: [MontyMemoryFile('/data/hello.txt', 'Hello!')],
      );

      final result = await handler('Path.read_text', ['/data/hello.txt'], null);
      expect(result, 'Hello!');
    });

    test('raises FileNotFoundError when path is unknown inside mount', () {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/data')],
        files: const [],
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

    test('write_text round-trips, and the caller sees it', () async {
      final out = MontyMemoryFile('/tmp/out.txt', '');
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/tmp')],
        files: [out],
      );

      await handler('Path.write_text', ['/tmp/out.txt', 'written'], null);
      // The caller's own reference is updated in place, which is upstream's
      // documented contract for MemoryFile (os_access.py:606-607).
      expect(out.content, VfsText('written'));

      final read = await handler('Path.read_text', ['/tmp/out.txt'], null);
      expect(read, 'written');
    });

    // The consequence of the test above, across handlers — pinned because it
    // SURPRISES, not because it is wrong.
    //
    // Mount state lives in the handler closure, so a fresh handler starts with
    // a fresh tree and anything the sandbox CREATED is gone. But a seeded file
    // is the caller's own object, mutated in place, so its content SURVIVES.
    // Reusing seed objects across handlers therefore gives a half-discard:
    // created files vanish, seeded content does not.
    //
    // That is deliberate. In-place mutation is upstream's contract
    // (`os_access.py:608`, "When Monty code writes to this file, the content
    // attribute is updated") and it is what makes the output-capture pattern
    // work — seed `MontyMemoryFile('/out.txt', '')`, run, read `.content`. A
    // copy-on-write "fix" would silently break every caller doing that, which
    // is why this is a test and not a bug report. Anyone tempted to make writes
    // replace the node instead of mutating it has to delete this test first,
    // and read this comment to do so.
    test(
      'a fresh handler over REUSED seeds half-discards, on purpose',
      () async {
        final seed = MontyMemoryFile('/tmp/seeded.txt', 'ORIGINAL');

        final first = memoryMountedOsHandler(
          mounts: const [MountDir(virtualPath: '/tmp')],
          files: [seed],
        );
        await first('Path.write_text', [
          '/tmp/scratch.txt',
          'FROM-RUN-1',
        ], null);
        await first('Path.write_text', ['/tmp/seeded.txt', 'MUTATED'], null);

        // A NEW handler over the SAME seed object — the natural thing to do,
        // since `files:` takes objects the caller constructed and still holds.
        final second = memoryMountedOsHandler(
          mounts: const [MountDir(virtualPath: '/tmp')],
          files: [seed],
        );

        // Created-by-sandbox: gone, because the tree is new.
        expect(await second('Path.exists', ['/tmp/scratch.txt'], null), false);
        // Seeded: NOT gone, because the object itself was rewritten.
        expect(
          await second('Path.read_text', ['/tmp/seeded.txt'], null),
          'MUTATED',
        );
        expect(seed.content, VfsText('MUTATED'));
      },
    );

    test('readOnly mount rejects writes with PermissionError', () {
      final handler = memoryMountedOsHandler(
        mounts: const [
          MountDir(virtualPath: '/data', mode: MountMode.readOnly),
        ],
        files: [MontyMemoryFile('/data/x.txt', 'old')],
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

    // This asserted only the exception TYPE, which both a per-write and a
    // cumulative cap satisfy — so it could not tell the two apart, and did not
    // notice when `writeBytesLimit` was per-write and therefore bounded
    // nothing. It now pins the message too. The semantics themselves live in
    // vfs_limits_test.dart.
    test('writeBytesLimit rejects oversize writes with OSError', () {
      final handler = memoryMountedOsHandler(
        mounts: const [
          MountDir(virtualPath: '/data', writeBytesLimit: 10),
        ],
        files: const [],
      );

      expect(
        () => handler(
          'Path.write_text',
          ['/data/big.txt', 'x' * 100],
          null,
        ),
        throwsA(
          isA<OsCallException>()
              .having(
                (e) => e.pythonExceptionType,
                'pythonExceptionType',
                'OSError',
              )
              .having(
                (e) => e.message,
                'message',
                'disk write limit of 10 bytes exceeded',
              ),
        ),
      );
    });

    // The security property is that the content does not come back, and that
    // is what this asserts — not which exception carries the refusal.
    //
    // It reports FileNotFoundError, not PermissionError, even though the file
    // is right there in the store. That is deliberate and it is the safer of
    // the two: `PermissionError` would CONFIRM that `/etc/passwd` exists and
    // is worth denying, which is precisely what a traversal probe is fishing
    // for. It also keeps one story — `exists()` on the same path answers
    // False, and a refusal that contradicts it would be its own leak.
    test('"../" traversal that escapes the mount leaks nothing', () async {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/sandbox')],
        files: [MontyMemoryFile('/etc/passwd', 'root:x:0:0')],
      );

      await expectLater(
        () => handler('Path.read_text', ['/sandbox/../etc/passwd'], null),
        throwsA(
          isA<OsCallException>()
              .having(
                (e) => e.pythonExceptionType,
                'pythonExceptionType',
                'FileNotFoundError',
              )
              // The refusal must not quote the content, nor admit the file is
              // there by any other wording.
              .having((e) => e.message, 'message', isNot(contains('root:x'))),
        ),
      );

      // And the sandbox tells the same story to every question about it.
      expect(await handler('Path.exists', ['/etc/passwd'], null), false);
      expect(await handler('Path.is_file', ['/etc/passwd'], null), false);
    });

    test('exists / is_file / is_dir reflect the vfs structure', () async {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/data')],
        files: [MontyMemoryFile('/data/sub/x.txt', 'hi')],
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
        files: [
          MontyMemoryFile('/data/a.txt', '1'),
          MontyMemoryFile('/data/b.txt', '2'),
          MontyMemoryFile('/data/sub/c.txt', '3'),
        ],
      );

      final children =
          (await handler('Path.iterdir', ['/data'], null))! as List<MontyPath>;
      final paths = children.map((p) => p.value).toSet();
      expect(paths, {'/data/a.txt', '/data/b.txt', '/data/sub'});
    });

    test('unlink requires writable mount and existing file', () async {
      final files = [MontyMemoryFile('/data/x.txt', 'gone')];
      final readOnly = memoryMountedOsHandler(
        mounts: const [
          MountDir(virtualPath: '/data', mode: MountMode.readOnly),
        ],
        files: files,
      );
      await expectLater(
        () => readOnly('Path.unlink', ['/data/x.txt'], null),
        throwsA(isA<OsCallException>()),
      );
      expect(await readOnly('Path.exists', ['/data/x.txt'], null), true);

      final writable = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/data')],
        files: files,
      );
      await writable('Path.unlink', ['/data/x.txt'], null);
      expect(await writable('Path.exists', ['/data/x.txt'], null), false);
    });

    test('paths outside every mount fall through to fallthrough', () async {
      var fallthroughCalled = 0;
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/data')],
        files: const [],
        fallthrough: (op, args, kwargs) async {
          fallthroughCalled++;

          return null;
        },
      );

      await handler('Path.read_text', ['/etc/passwd'], null);
      expect(fallthroughCalled, 1);
    });

    // Was PermissionError. A path the sandbox does not mount is, as far as the
    // sandbox is concerned, not there — and pathlib__os_read_error.py asserts
    // CPython's FileNotFoundError for exactly this.
    test('paths outside mounts report not-there without fallthrough', () {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/data')],
        files: const [],
      );

      expect(
        () => handler('Path.read_text', ['/etc/passwd'], null),
        throwsA(
          isA<OsCallException>()
              .having(
                (e) => e.pythonExceptionType,
                'pythonExceptionType',
                'FileNotFoundError',
              )
              .having(
                (e) => e.message,
                'message',
                "[Errno 2] No such file or directory: '/etc/passwd'",
              ),
        ),
      );
    });

    // The handler used to answer all of these with one invented message,
    // `PermissionError: Path is outside any mount: <arg>`. It was wrong in a
    // different way each time: it called an env-var name a path, it printed
    // `null` for calls that carry no path at all, and it claimed a file that
    // exists inside the mount was outside it.
    //
    // It now raises the call's own no-handler default, computed by
    // [osCallNoHandlerDefault] to match upstream's `on_no_handler`
    // (monty-types/src/os.rs:260-268) — a permission failure naming the path
    // for a filesystem op, `Permission denied: '<path>'` with no errno prefix.
    test('unserved filesystem op reports Permission denied with the path', () {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/data')],
        files: [MontyMemoryFile('/data/hello.txt', 'hi')],
      );

      // This handler now implements all 19 upstream filesystem ops, so the
      // example has to be a hypothetical one. The property under test is
      // structural and survives any future op: the throw sits AFTER the
      // mount check, so the path is inside a mount by construction and
      // "outside any mount" could never be true here.
      expect(
        () => handler('Path.chmod', ['/data/hello.txt'], null),
        throwsA(
          isA<OsCallException>()
              .having(
                (e) => e.pythonExceptionType,
                'excType',
                'PermissionError',
              )
              .having(
                (e) => e.message,
                'message',
                "Permission denied: '/data/hello.txt'",
              ),
        ),
      );
    });

    // A non-filesystem op is not a path question at all. The old message
    // called os.getenv's variable name a path and rendered "... : null" for
    // calls carrying no argument.
    test('unserved non-filesystem op reports RuntimeError, not a path', () {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/data')],
        files: const [],
      );

      Matcher unsupported(String name) => throwsA(
        isA<OsCallException>()
            .having((e) => e.pythonExceptionType, 'excType', 'RuntimeError')
            .having(
              (e) => e.message,
              'message',
              "'$name' is not supported in this environment",
            ),
      );

      expect(
        () => handler('os.getenv', ['HOME'], null),
        unsupported('os.getenv'),
      );
      expect(
        () => handler('os.environ', const [], null),
        unsupported('os.environ'),
      );
      expect(
        () => handler('datetime.now', const [], null),
        unsupported('datetime.now'),
      );
    });

    // Path.stat was unimplemented, so it fell through and reported
    // "Path is outside any mount" for a file that was demonstrably inside one.
    // Shape mirrors upstream's StatResult exactly (monty-types/src/os.rs:487):
    // ten fields, first seven int, last three float; synthetic 0o644 / 0o755
    // modes with type bits OR'd in; directories report size 4096 and nlink 2.
    test('stat of a file returns a 10-field StatResult', () async {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/data')],
        files: [MontyMemoryFile('/data/hello.txt', 'readonly content')],
      );

      final st =
          (await handler('Path.stat', ['/data/hello.txt'], null))!
              as MontyNamedTuple;

      expect(st.typeName, 'StatResult');
      expect(st.fieldNames, const [
        'st_mode',
        'st_ino',
        'st_dev',
        'st_nlink',
        'st_uid',
        'st_gid',
        'st_size',
        'st_atime',
        'st_mtime',
        'st_ctime',
      ]);
      // 16 bytes -- the same value mount_fs__ops.py:52 asserts.
      expect(_stat(st, 'st_size'), const MontyInt(16));
      // 0o644 with the regular-file type bits (0o100000) OR'd in.
      expect(_stat(st, 'st_mode'), const MontyInt(0x81A4));
      expect(_stat(st, 'st_nlink'), const MontyInt(1));
      // Times are floats, not ints -- the wire distinguishes them.
      expect(_stat(st, 'st_atime'), isA<MontyFloat>());
    });

    test('stat of a directory reports 4096 and nlink 2', () async {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/data')],
        files: [MontyMemoryFile('/data/sub/x.txt', 'hi')],
      );

      final st =
          (await handler('Path.stat', ['/data/sub'], null))! as MontyNamedTuple;

      expect(_stat(st, 'st_size'), const MontyInt(4096));
      expect(_stat(st, 'st_nlink'), const MontyInt(2));
      // 0o755 with the directory type bits (0o40000) OR'd in.
      expect(_stat(st, 'st_mode'), const MontyInt(0x41ED));
    });

    test('stat of a missing path inside a mount is FileNotFoundError', () {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/data')],
        files: const [],
      );

      expect(
        () => handler('Path.stat', ['/data/nope.txt'], null),
        throwsA(
          isA<OsCallException>()
              .having(
                (e) => e.pythonExceptionType,
                'excType',
                'FileNotFoundError',
              )
              .having(
                (e) => e.message,
                'message',
                "[Errno 2] No such file or directory: '/data/nope.txt'",
              ),
        ),
      );
    });

    test('non-Path operations fall through cleanly', () async {
      var fallthroughOp = '';
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/data')],
        files: const [],
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
        files: [MontyMemoryFile('/data/scratch/x.txt', 'old')],
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
        files: const [],
      );
      // Parent is the mount root /sandbox — implicitly exists.
      final r = await handler('Path.mkdir', ['/sandbox/data'], null);
      expect(r, isNull);
    });

    test('mkdir parents=False raises FileNotFoundError on missing parent', () {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/sandbox')],
        files: const [],
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
          files: const [],
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
        files: [
          MontyMemoryFile(
            '/sandbox/data',
            'I am a file pretending to be a dir',
          ),
        ],
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
          files: [MontyMemoryFile('/sandbox/data/file.txt', 'x')],
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
          files: [MontyMemoryFile('/sandbox/data/file.txt', 'x')],
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
        files: const [],
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
        files: [MontyMemoryFile('/sandbox/file.txt', 'x')],
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
        files: [MontyMemoryFile('/sandbox/data/file.txt', 'x')],
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

    // Was "a no-op success". CPython raises, and mount_fs__errors.py:110-115
    // asserts the exact message. Under the flat-map model an empty directory
    // is now a real node, so "absent" and "empty" are distinguishable and
    // this raises for the first reason rather than by coincidence.
    // mount_fs__errors.py:141-155. A write into a directory that does not
    // exist must fail; the flat map would happily create the key and invent
    // the parent, which is how a typo'd path silently "worked".
    // Was skipped while `mkdir` was a no-op: the check is correct in
    // principle, but the parent it demanded could never come into existence,
    // so it broke mkdir-then-write. Directories are real nodes now, so the
    // check is back and this is green.
    test(
      'write_text/write_bytes with a missing parent raise',
      () {
        final handler = memoryMountedOsHandler(
          mounts: const [MountDir(virtualPath: '/mnt')],
          files: const [],
        );

        Matcher missing(String p) => throwsA(
          isA<OsCallException>()
              .having(
                (e) => e.pythonExceptionType,
                'excType',
                'FileNotFoundError',
              )
              .having(
                (e) => e.message,
                'message',
                "[Errno 2] No such file or directory: '$p'",
              ),
        );

        expect(
          () => handler('Path.write_text', ['/mnt/nope/child.txt', 'x'], null),
          missing('/mnt/nope/child.txt'),
        );
        expect(
          () => handler('Path.write_bytes', [
            '/mnt/nope/child.bin',
            [1, 2, 3],
          ], null),
          missing('/mnt/nope/child.bin'),
        );
      },
    );

    test('writing directly into a mount root still works', () async {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/mnt')],
        files: const [],
      );

      await handler('Path.write_text', ['/mnt/top.txt', 'ok'], null);
      expect(await handler('Path.read_text', ['/mnt/top.txt'], null), 'ok');
    });

    // mount_fs__errors.py:129-137 asserts CPython's exact wording, and names
    // the TARGET, not the missing parent. We said `No such directory: <parent>`
    // — wrong format and wrong path.
    test('mkdir with a missing parent names the target, CPython-style', () {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/mnt')],
        files: const [],
      );

      expect(
        () => handler('Path.mkdir', ['/mnt/missing_parent/child'], null),
        throwsA(
          isA<OsCallException>()
              .having(
                (e) => e.pythonExceptionType,
                'excType',
                'FileNotFoundError',
              )
              .having(
                (e) => e.message,
                'message',
                "[Errno 2] No such file or directory: '/mnt/missing_parent/child'",
              ),
        ),
      );
    });

    // mkdir, then write into what you just created. The most ordinary
    // filesystem sequence there is, and mount_fs__errors.py:209-212 depends on
    // it to set up its rename case.
    //
    // b289207 broke this: it added a parent-directory check to write_text and
    // write_bytes. The check is right in PRINCIPLE — without it a typo'd path
    // silently creates a file in a directory that was never named — but it is
    // unsafe while `mkdir` is a no-op, because the parent it demands can never
    // come into existence. The gate was green because nothing covered the
    // sequence; this test is that cover.
    //
    // The check comes back in Phase 1, once directories are first-class and
    // `mkdir` actually creates one.
    test('mkdir then write into it — the sequence must work', () async {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/m')],
        files: const [],
      );

      await handler('Path.mkdir', ['/m/d'], null);
      await handler('Path.write_text', ['/m/d/f.txt', 'moved'], null);

      expect(await handler('Path.read_text', ['/m/d/f.txt'], null), 'moved');
    });

    test('rmdir of a nonexistent path raises FileNotFoundError', () {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/sandbox')],
        files: const [],
      );

      expect(
        () => handler('Path.rmdir', ['/sandbox/empty'], null),
        throwsA(
          isA<OsCallException>()
              .having(
                (e) => e.pythonExceptionType,
                'excType',
                'FileNotFoundError',
              )
              .having(
                (e) => e.message,
                'message',
                "[Errno 2] No such file or directory: '/sandbox/empty'",
              ),
        ),
      );
    });

    test('rmdir of a mount root does not claim it is missing', () async {
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/sandbox')],
        files: const [],
      );

      // The mount root exists by definition, so this must not be
      // FileNotFoundError even though the flat map holds no key for it.
      final r = await handler('Path.rmdir', ['/sandbox'], null);
      expect(r, isNull);
    });

    test('rmdir on readOnly mount raises PermissionError', () {
      final handler = memoryMountedOsHandler(
        mounts: const [
          MountDir(virtualPath: '/sandbox', mode: MountMode.readOnly),
        ],
        files: const [],
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
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/sandbox')],
        files: [MontyMemoryFile('/sandbox/a.txt', 'alpha')],
      );
      await handler('Path.rename', ['/sandbox/a.txt', '/sandbox/b.txt'], null);
      expect(await handler('Path.exists', ['/sandbox/a.txt'], null), false);
      expect(
        await handler('Path.read_text', ['/sandbox/b.txt'], null),
        'alpha',
      );
    });

    test('rename across two writable mounts succeeds', () async {
      final handler = memoryMountedOsHandler(
        mounts: const [
          MountDir(virtualPath: '/data'),
          MountDir(virtualPath: '/scratch'),
        ],
        files: [MontyMemoryFile('/data/x.txt', 'x')],
      );
      await handler('Path.rename', ['/data/x.txt', '/scratch/x.txt'], null);
      expect(await handler('Path.read_text', ['/scratch/x.txt'], null), 'x');
      expect(await handler('Path.exists', ['/data/x.txt'], null), false);
    });

    test('rename with readOnly source mount raises PermissionError', () {
      final handler = memoryMountedOsHandler(
        mounts: const [
          MountDir(virtualPath: '/data', mode: MountMode.readOnly),
        ],
        files: [MontyMemoryFile('/data/x.txt', 'x')],
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
        files: [MontyMemoryFile('/src/x.txt', 'x')],
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
        files: const [],
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
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/sandbox')],
        files: [
          MontyMemoryFile('/sandbox/old/a.txt', 'a'),
          MontyMemoryFile('/sandbox/old/sub/b.txt', 'b'),
          MontyMemoryFile('/sandbox/keep.txt', 'keep'),
        ],
      );
      await handler('Path.rename', ['/sandbox/old', '/sandbox/new'], null);
      expect(await handler('Path.exists', ['/sandbox/old/a.txt'], null), false);
      expect(
        await handler('Path.exists', ['/sandbox/old/sub/b.txt'], null),
        false,
      );
      expect(
        await handler('Path.read_text', ['/sandbox/new/a.txt'], null),
        'a',
      );
      expect(
        await handler('Path.read_text', ['/sandbox/new/sub/b.txt'], null),
        'b',
      );
      expect(
        await handler('Path.read_text', ['/sandbox/keep.txt'], null),
        'keep',
      );
    });

    test(
      'rename onto an existing non-empty directory raises OSError',
      () {
        final handler = memoryMountedOsHandler(
          mounts: const [MountDir(virtualPath: '/sandbox')],
          files: [
            MontyMemoryFile('/sandbox/old/a.txt', 'a'),
            MontyMemoryFile('/sandbox/new/b.txt', 'b'),
          ],
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

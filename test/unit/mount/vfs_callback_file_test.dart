@Tags(['unit'])
library;

import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/unsafe_callback_file.dart';
import 'package:test/test.dart';

/// Every write this test does not care about lands here, so the tests that DO
/// care can assert on their own list and the rest still have a real callback
/// rather than an empty block.
final _discarded = <(String, VfsContent)>[];

void _discard(String path, VfsContent content) =>
    _discarded.add((path, content));

/// Named-field read, mirroring the helper in
/// `memory_mounted_os_handler_test.dart`: a positional read says nothing about
/// which field it meant.
MontyValue? _stat(MontyNamedTuple t, String field) {
  final i = t.fieldNames.indexOf(field);

  return i < 0 ? null : t.values.elementAtOrNull(i);
}

Matcher raises(String excType, String message) => throwsA(
  isA<OsCallException>()
      .having((e) => e.pythonExceptionType, 'excType', excType)
      .having((e) => e.message, 'message', message),
);

void main() {
  group('VfsCallbackFile', () {
    test('read_text invokes the read callback', () async {
      final seen = <String>[];
      final h = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/mnt')],
        files: [
          VfsCallbackFile(
            '/mnt/live.txt',
            read: (p) {
              seen.add(p);

              return VfsText('content from $p');
            },
            write: _discard,
          ),
        ],
      );

      expect(
        await h('Path.read_text', ['/mnt/live.txt'], null),
        'content from /mnt/live.txt',
      );
      expect(seen, ['/mnt/live.txt']);
    });

    test('write_text invokes the write callback with VfsText', () async {
      final written = <(String, VfsContent)>[];
      final h = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/mnt')],
        files: [
          VfsCallbackFile(
            '/mnt/live.txt',
            read: (_) => VfsText(''),
            write: (p, c) => written.add((p, c)),
          ),
        ],
      );

      await h('Path.write_text', ['/mnt/live.txt', 'hello'], null);

      expect(written, [('/mnt/live.txt', VfsText('hello'))]);
    });

    test('write_bytes hands the callback VfsBytes, not VfsText', () async {
      final written = <VfsContent>[];
      final h = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/mnt')],
        files: [
          VfsCallbackFile(
            '/mnt/live.bin',
            read: (_) => VfsBytes(Uint8List(0)),
            write: (_, c) => written.add(c),
          ),
        ],
      );

      await h('Path.write_bytes', [
        '/mnt/live.bin',
        <int>[0xFF, 0x00],
      ], null);

      expect(written, [
        VfsBytes(Uint8List.fromList([0xFF, 0x00])),
      ]);
    });

    test('stat sizes the file by INVOKING the read callback', () async {
      var reads = 0;
      final h = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/mnt')],
        files: [
          VfsCallbackFile(
            '/mnt/live.txt',
            read: (_) {
              reads++;

              return VfsText('héllo');
            },
            write: _discard,
          ),
        ],
      );

      // 'héllo' is 5 codepoints and 6 UTF-8 bytes; st_size is bytes.
      final st = await h('Path.stat', ['/mnt/live.txt'], null);
      expect(_stat(st! as MontyNamedTuple, 'st_size'), const MontyInt(6));
      // Upstream does the same (os_access.py:1024): sizing means reading.
      expect(reads, 1);
    });

    test('the path is clamped at construction', () {
      final f = VfsCallbackFile(
        '/mnt/../../../etc/passwd',
        read: (_) => VfsText(''),
        write: _discard,
      );

      expect(f.seededPath, '/etc/passwd');
      expect(f.path, '/etc/passwd');
    });

    // THE SECURITY CASE. Sandboxed Python can rename a file, and a rename
    // rewrites the live `path` of every file in the moved subtree. If the
    // callback were handed that live path, untrusted code would choose the
    // argument the host callback receives.
    test('rename does NOT change the path handed to the callback', () async {
      final seen = <String>[];
      final f = VfsCallbackFile(
        '/mnt/config.txt',
        read: (p) {
          seen.add(p);

          return VfsText('x');
        },
        write: _discard,
      );
      final h = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/mnt')],
        files: [f],
      );

      await h('Path.rename', ['/mnt/config.txt', '/mnt/secrets.txt'], null);
      await h('Path.read_text', ['/mnt/secrets.txt'], null);

      // The tree moved the file, so `path` tracks it...
      expect(f.path, '/mnt/secrets.txt');
      // ...but the HOST still sees only where it was seeded.
      expect(seen, ['/mnt/config.txt']);
    });

    test('a DIRECTORY rename also cannot redirect the callback', () async {
      final seen = <String>[];
      final f = VfsCallbackFile(
        '/mnt/sub/config.txt',
        read: (p) {
          seen.add(p);

          return VfsText('x');
        },
        write: _discard,
      );
      final h = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/mnt')],
        files: [f],
      );

      await h('Path.rename', ['/mnt/sub', '/mnt/other'], null);
      await h('Path.read_text', ['/mnt/other/config.txt'], null);

      expect(f.path, '/mnt/other/config.txt');
      expect(seen, ['/mnt/sub/config.txt']);
    });

    test('a read-only mount still refuses the write callback', () async {
      var writes = 0;
      final h = memoryMountedOsHandler(
        mounts: const [
          MountDir(virtualPath: '/mnt', mode: MountMode.readOnly),
        ],
        files: [
          VfsCallbackFile(
            '/mnt/live.txt',
            read: (_) => VfsText(''),
            write: (_, _) => writes++,
          ),
        ],
      );

      await expectLater(
        () => h('Path.write_text', ['/mnt/live.txt', 'x'], null),
        raises('PermissionError', 'Mount is read-only: /mnt/live.txt'),
      );
      expect(writes, 0);
    });

    test('sandboxed code cannot MINT a callback file', () async {
      final h = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/mnt')],
        files: [
          VfsCallbackFile(
            '/mnt/live.txt',
            read: (_) => VfsText(''),
            write: _discard,
          ),
        ],
      );

      // A file Monty creates is always a plain in-memory file, so no callback
      // can come into existence from inside the sandbox.
      await h('Path.write_text', ['/mnt/fresh.txt', 'hi'], null);
      expect(await h('Path.read_text', ['/mnt/fresh.txt'], null), 'hi');
    });
  });
}

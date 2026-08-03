@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

/// Behaviours pinned by upstream's Python `OSAccess` suite that **no corpus
/// fixture reaches** (`docs/contributor/vfs-phases.md`, §6c).
///
/// The 531-fixture oracle corpus is not the only spec: upstream's
/// `crates/monty-python/tests/test_os_access.py` covers directory and mode
/// semantics the fixtures underspecify. These are ported from it, and one of
/// them found a live defect — see the `open()` group.
Matcher raises(String excType, String message) => throwsA(
  isA<OsCallException>()
      .having((e) => e.pythonExceptionType, 'excType', excType)
      .having((e) => e.message, 'message', message),
);

void main() {
  group('iterdir — the three-way answer', () {
    // An EMPTY directory and a MISSING path must not look alike. The old flat
    // store returned an empty list for both, which is the worst of the three
    // answers: indistinguishable from a successful listing.
    test('an empty directory lists as empty, and does NOT raise', () async {
      final h = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/mnt')],
        files: [MontyMemoryFile('/mnt/sub/file.txt', 'hello')],
      );

      await h('Path.mkdir', ['/mnt/empty'], null);

      expect(await h('Path.iterdir', ['/mnt/empty'], null), isEmpty);
      // Upstream: test_iterdir_empty_directory_direct.
    });

    test('a MISSING path raises rather than listing as empty', () async {
      final h = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/mnt')],
        files: [MontyMemoryFile('/mnt/sub/file.txt', 'hello')],
      );

      await expectLater(
        () => h('Path.iterdir', ['/mnt/nope'], null),
        raises(
          'FileNotFoundError',
          "[Errno 2] No such file or directory: '/mnt/nope'",
        ),
      );
    });
  });

  group('append return units — chars vs bytes', () {
    // Upstream: test_append_text_non_ascii_returns_char_count and
    // test_append_bytes_returns_byte_count. 'αβγ' is 3 characters and 6 UTF-8
    // bytes, so the two calls MUST disagree.
    test('append_text returns CHARACTERS, not encoded bytes', () async {
      final h = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/mnt')],
        files: [MontyMemoryFile('/mnt/file.txt', 'start ')],
      );

      expect(await h('Path.append_text', ['/mnt/file.txt', 'αβγ'], null), 3);
      expect(
        await h('Path.read_text', ['/mnt/file.txt'], null),
        'start αβγ',
      );
    });

    test('append_bytes returns BYTES for the same content', () async {
      final h = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/mnt')],
        files: [MontyMemoryFile('/mnt/file.bin', 'start ')],
      );

      // The UTF-8 encoding of 'αβγ' — 6 bytes.
      const utf8Abg = [0xCE, 0xB1, 0xCE, 0xB2, 0xCE, 0xB3];
      expect(
        await h('Path.append_bytes', ['/mnt/file.bin', utf8Abg], null),
        6,
      );
      expect(
        await h('Path.read_text', ['/mnt/file.bin'], null),
        'start αβγ',
      );
    });
  });

  group('the root directory', () {
    // Upstream: test_root_directory. Root has no name, which is what makes it
    // unnameable and therefore always present — but only inside a mount that
    // covers it, which is our model's one deliberate difference from upstream's
    // mountless OSAccess.
    test('root is a directory and lists its children', () async {
      final h = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/')],
        files: [MontyMemoryFile('/file.txt', 'root file')],
      );

      expect(await h('Path.is_dir', ['/'], null), true);
      expect(await h('Path.exists', ['/'], null), true);
      // iterdir yields MontyPath, not bare strings — Python must receive
      // `pathlib.Path` objects, which is what Phase 3 fixed.
      expect(await h('Path.iterdir', ['/'], null), [
        const MontyPath('/file.txt'),
      ]);
    });

    test('root is not a file', () async {
      final h = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/')],
        files: [MontyMemoryFile('/file.txt', 'root file')],
      );

      expect(await h('Path.is_file', ['/'], null), false);
    });
  });

  group('open() rejects a malformed mode BEFORE any side effect', () {
    // Upstream: test_path_open_invalid_mode_does_not_truncate, which exists as
    // a REGRESSION guard — "a malformed mode that starts with w/a must reject
    // the open BEFORE the truncate/create side effect, otherwise direct
    // callers can destroy data by passing e.g. 'wxyz'".
    //
    // We had the mirror-image bug: any unrecognised mode fell through to
    // `createIfMissing`, so a garbage mode silently CREATED a file instead of
    // raising. `resolveOpenCall` is exported, so a direct caller reaches it.
    // NOT in this list: 'r+', 'w+', 'rt', 'ab+'. `b`/`t`/`+` are orthogonal to
    // the open-time action, so those are VALID — see the group below. 'x' IS
    // rejected: upstream asserts the action is one of r/w/a
    // (os_access.py:896), so treating it as append would invent a semantic.
    for (final mode in ['wxyz', 'axyz', 'w!', 'a?', 'x', 'rw', 'bt', '']) {
      test('mode ${mode.isEmpty ? "(empty)" : mode} raises ValueError', () {
        expect(
          () => resolveOpenCall(
            '/data/file.txt',
            mode,
            exists: (_) => true,
            truncate: (_) => fail('truncate ran for mode $mode'),
            createIfMissing: (_) => fail('createIfMissing ran for mode $mode'),
          ),
          throwsA(
            isA<OsCallException>().having(
              (e) => e.pythonExceptionType,
              'excType',
              'ValueError',
            ),
          ),
        );
      });
    }

    // `b`/`t`/`+` do not change the open-time effect, only the leading action
    // does. Upstream splits it the same way (os_access.py:878-882), which is
    // why 'r+' checks existence rather than truncating.
    test('b, t and + are orthogonal to the action', () {
      for (final mode in ['r+', 'rt', 'rb+']) {
        resolveOpenCall(
          '/data/file.txt',
          mode,
          exists: (_) => true,
          truncate: (_) => fail('$mode is a READ action; it must not truncate'),
          createIfMissing: (_) => fail('$mode must not create'),
        );
      }

      var truncated = 0;
      for (final mode in ['w+', 'wt', 'wb+']) {
        resolveOpenCall(
          '/data/file.txt',
          mode,
          exists: (_) => true,
          truncate: (_) => truncated++,
          createIfMissing: (_) => fail('$mode must truncate, not create'),
        );
      }
      expect(truncated, 3);
    });

    test('a read action with a missing file still raises', () {
      expect(
        () => resolveOpenCall(
          '/data/gone.txt',
          'r+',
          exists: (_) => false,
          truncate: (_) => fail('no side effect on a failed read open'),
          createIfMissing: (_) => fail('r+ must not create a missing file'),
        ),
        raises(
          'FileNotFoundError',
          "[Errno 2] No such file or directory: '/data/gone.txt'",
        ),
      );
    });

    test('the six modes monty emits still work', () {
      final effects = <String>[];
      for (final mode in ['r', 'rb']) {
        final h = resolveOpenCall(
          '/data/file.txt',
          mode,
          exists: (_) => true,
          truncate: (_) => effects.add('truncate'),
          createIfMissing: (_) => effects.add('create'),
        );
        expect(h.mode, mode);
      }
      expect(effects, isEmpty, reason: 'read modes have no open-time effect');

      for (final mode in ['w', 'wb']) {
        resolveOpenCall(
          '/data/file.txt',
          mode,
          exists: (_) => true,
          truncate: (_) => effects.add('truncate:$mode'),
          createIfMissing: (_) => fail('w must truncate, not create'),
        );
      }
      for (final mode in ['a', 'ab']) {
        resolveOpenCall(
          '/data/file.txt',
          mode,
          exists: (_) => true,
          truncate: (_) => fail('a must create-if-missing, not truncate'),
          createIfMissing: (_) => effects.add('create:$mode'),
        );
      }

      expect(effects, [
        'truncate:w',
        'truncate:wb',
        'create:a',
        'create:ab',
      ]);
    });
  });
}

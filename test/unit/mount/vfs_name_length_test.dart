@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  // Limits are in BYTES, not characters — which is why the content ADT keeps
  // byte length separate from character length. mount_fs__errors.py asserts
  // the message verbatim, and it names the FULL path, not the component.
  group('name length limits', () {
    OsCallHandler handler() => memoryMountedOsHandler(
      mounts: const [MountDir(virtualPath: '/mnt')],
      files: [MontyMemoryFile('/mnt/hello.txt', 'hi')],
    );

    final longName = 'a' * 256;
    final longPath = '/mnt/$longName';
    // 21 components of 200 bytes: each is under 255, only the total is over.
    final deepPath = '/mnt/${List.filled(21, 'x' * 200).join('/')}';

    Matcher tooLong(String path) => throwsA(
      isA<OsCallException>()
          .having((e) => e.pythonExceptionType, 'excType', 'OSError')
          .having(
            (e) => e.message,
            'message',
            "[Errno 36] File name too long: '$path'",
          ),
    );

    for (final op in const [
      ('Path.write_text', <Object?>['x']),
      (
        'Path.write_bytes',
        <Object?>[
          [1],
        ],
      ),
      ('Path.append_text', <Object?>['x']),
      ('Path.read_text', <Object?>[]),
      ('Path.read_bytes', <Object?>[]),
      ('Path.stat', <Object?>[]),
      ('Path.mkdir', <Object?>[]),
    ]) {
      test('${op.$1} rejects a component over 255 bytes', () {
        expect(
          () => handler()(op.$1, [longPath, ...op.$2], null),
          tooLong(longPath),
        );
      });
    }

    test('write_text rejects a total path over 4096 bytes', () {
      expect(
        () => handler()('Path.write_text', [deepPath, 'x'], null),
        tooLong(deepPath),
      );
    });

    test('open rejects a component over 255 bytes', () {
      expect(() => handler()('open', [longPath, 'r'], null), tooLong(longPath));
    });

    // A component of EXACTLY 255 bytes is legal; the fixture checks this so a
    // fencepost error cannot hide behind the rejection tests above.
    test('a component of exactly 255 bytes is accepted', () async {
      final ok = '/mnt/${'b' * 255}';

      expect(await handler()('Path.exists', [ok], null), false);
      expect(await handler()('Path.write_text', [ok, 'fine'], null), 4);
    });

    // BYTES, not characters: 'é' is one character and two bytes, so 128 of
    // them are 256 bytes and must be rejected.
    test('the limit counts bytes, not characters', () {
      final accented = '/mnt/${'é' * 128}';

      expect(
        () => handler()('Path.write_text', [accented, 'x'], null),
        tooLong(accented),
      );
    });

    // CPython's exists/is_file/is_dir SWALLOW OSError and answer False. An
    // over-long name is not there, and that is all the caller asked.
    for (final op in const [
      'Path.exists',
      'Path.is_file',
      'Path.is_dir',
      'Path.is_symlink',
    ]) {
      test('$op swallows the limit and returns false', () async {
        expect(await handler()(op, [longPath], null), false);
        expect(await handler()(op, [deepPath], null), false);
      });
    }
  });
}

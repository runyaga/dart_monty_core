@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  // FB-11 P5. A QUERY about a path is not an ACCESS of it. CPython answers
  // False for a path that is not there; raising PermissionError instead is
  // both wrong and unhelpful, and it is why pathlib__os.py sat in
  // knownBrokenExtFixtures.
  group('paths outside every mount', () {
    OsCallHandler handler() => memoryMountedOsHandler(
      mounts: const [MountDir(virtualPath: '/virtual')],
      files: [MontyMemoryFile('/virtual/file.txt', 'hi')],
    );

    for (final op in const [
      'Path.exists',
      'Path.is_file',
      'Path.is_dir',
      'Path.is_symlink',
    ]) {
      test('$op outside a mount answers false', () async {
        expect(await handler()(op, ['/nonexistent'], null), false);
        expect(await handler()(op, ['/nonexistent/file.txt'], null), false);
      });
    }

    // Reading it still fails, and it fails with the SAME story exists() told:
    // it is not there. `PermissionError` would contradict `exists() == False`
    // about the same path, and it leaks more — it confirms the path is
    // meaningful enough to be worth denying.
    Matcher notThere(String p) => throwsA(
      isA<OsCallException>()
          .having((e) => e.pythonExceptionType, 'excType', 'FileNotFoundError')
          .having(
            (e) => e.message,
            'message',
            "[Errno 2] No such file or directory: '$p'",
          ),
    );

    test('read_text outside a mount reports not-there', () {
      expect(
        () => handler()('Path.read_text', ['/etc/passwd'], null),
        notThere('/etc/passwd'),
      );
    });

    test('write_text outside a mount reports not-there', () {
      expect(
        () => handler()('Path.write_text', ['/etc/passwd', 'x'], null),
        notThere('/etc/passwd'),
      );
    });

    test('open outside a mount reports not-there', () {
      expect(
        () => handler()('open', ['/etc/passwd', 'r'], null),
        notThere('/etc/passwd'),
      );
    });

    // A configured fallthrough still gets first refusal — answering false
    // ourselves would shadow a host that DOES serve those paths.
    test('a fallthrough still sees the query', () async {
      var seen = 0;
      final handler0 = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/virtual')],
        files: const [],
        fallthrough: (op, args, kwargs) async {
          seen++;

          return true;
        },
      );

      expect(await handler0('Path.exists', ['/elsewhere'], null), true);
      expect(seen, 1);
    });
  });
}

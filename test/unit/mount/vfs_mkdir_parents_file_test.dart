// `mkdir(parents=True)` walking THROUGH a file raises NotADirectoryError.
//
// `_mkdirParents` checks each ancestor as it walks. An ancestor that is a file
// is a Python-visible error, `[Errno 20] Not a directory`, not an internal
// StateError from the tree. The mount-fs corpus adjudicator used to be the only
// thing that reached that branch; this pins it directly.
//
// Falsifier: make the `VfsFile()` case `continue` instead of throw; the
// test fails with the tree's internal StateError.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  group('mkdir parents=True through a file', () {
    test(
      'raises NotADirectoryError naming the file, creates nothing',
      () async {
        final h = memoryMountedOsHandler(
          mounts: const [MountDir(virtualPath: '/m')],
          files: [MontyMemoryFile('/m/a', 'x')],
        );

        await expectLater(
          h('Path.mkdir', ['/m/a/b/c'], {'parents': true}),
          throwsA(
            isA<OsCallException>()
                .having(
                  (e) => e.pythonExceptionType,
                  'pythonExceptionType',
                  'NotADirectoryError',
                )
                .having(
                  (e) => e.message,
                  'message',
                  equals("[Errno 20] Not a directory: '/m/a'"),
                ),
          ),
        );

        // The file is untouched and nothing was created beneath it.
        expect(await h('Path.read_text', ['/m/a'], null), 'x');
        expect(await h('Path.exists', ['/m/a/b'], null), false);
      },
    );
  });
}

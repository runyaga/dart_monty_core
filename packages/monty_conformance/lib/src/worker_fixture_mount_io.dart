// Upstream 591527397445bf734873252d1ee20c1b6308fe7f,
// crates/monty-datatest/src/main.rs:402-414 and 1660-1685.
import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';

/// Runs a mount fixture over upstream's host tree, with a fresh overlay.
/// Both the opened capability and its temporary directory are released on
/// completion or failure, including a constructor/library-lookup failure.
Future<MontyValue> runMountFixture(MontySession session, String source) async {
  final directory = Directory.systemTemp.createTempSync('monty-corpus-mount-');
  try {
    _seed(directory);
    final mount = MountDir(hostPath: directory.path, virtualPath: '/mnt');
    try {
      return await session.feedRun(
        source,
        mount: [mount],
        cwd: '/mnt',
        externalLookup: {'root': MontyPath('/mnt')},
        printCallback: _discard,
      );
    } finally {
      mount.close();
    }
  } finally {
    directory.deleteSync(recursive: true);
  }
}

void _seed(Directory directory) {
  Directory('${directory.path}/subdir/deep').createSync(recursive: true);
  for (final entry in {
    'hello.txt': 'hello world\n',
    'empty.txt': '',
    'readonly.txt': 'readonly content',
    'subdir/nested.txt': 'nested content',
    'subdir/deep/file.txt': 'deep file',
  }.entries) {
    File('${directory.path}/${entry.key}').writeAsStringSync(entry.value);
  }
  File('${directory.path}/data.bin').writeAsBytesSync([0, 1, 2, 3]);
}

// Corpus directives adjudicate outcomes, not printed output.
void _discard(String stream, String text) {
  return;
}

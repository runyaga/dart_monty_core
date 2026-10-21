// Examples print what they show; the number in the name is the reading order.
// ignore_for_file: avoid_print, file_names
//
// 12 — MountDir: a real host directory in the sandbox
//
// MountDir opens a host directory and maps it to a virtual path through
// upstream monty-fs. Native only: the constructor throws UnsupportedError on
// the web and wherever the mount library is missing — the build hook's
// `build_worker: true` code asset, or the library beside the package's worker
// executable in lib/src/bin/<os>-<arch>/.
//
// Covers: MountDir with mode and writeBytesLimit, absolute virtual paths,
//         mounts answering before os:, overlay discard, close().
//
// Run: dart run example/12_mount_dir.dart

import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  // A real directory on the host, with one file in it.
  final hostDir = await Directory.systemTemp.createTemp('mount_dir_example');
  final note = File('${hostDir.path}/note.txt');
  await note.writeAsString('from the host disk');

  final MountDir mount;
  try {
    mount = MountDir(
      hostPath: hostDir.path,
      virtualPath: '/data',
      mode: 'overlay', // writes live inside one feed only
      writeBytesLimit: 1000000,
    );
  } on UnsupportedError catch (e) {
    print('skipping: $e');
    await hostDir.delete(recursive: true);
    return;
  }

  try {
    await Monty.withPool(
      (monty) => monty.withSession((session) async {
        // The mount answers filesystem calls; OSAccess answers the rest, here
        // os.getenv. Use absolute virtual paths: a relative one resolves
        // against the session's working directory, which the first mount
        // supplies only before that directory is established.
        final os = OSAccess(environ: {'APP_ENV': 'test'});
        final result =
            await session.feedRun(
                  "import os\n(open('/data/note.txt').read(), os.getenv('APP_ENV'))",
                  mount: [mount],
                  os: os,
                )
                as MontyTuple;
        final [text, env] = result.items;
        print('mount read: $text');
        print('os answer:  $env');
        _check(text == const MontyString('from the host disk'), 'mount read');
        _check(env == const MontyString('test'), 'os.getenv via os:');

        // Overlay writes vanish when their feed ends...
        await session.feedRun(
          "open('/data/note.txt', 'w').write('scratch copy')",
          mount: [mount],
        );
        final after = await session.feedRun(
          "open('/data/note.txt').read()",
          mount: [mount],
        );
        print('next feed:  $after');
        _check(after == text, 'overlay writes end with their feed');

        // ...so the host file keeps its original content.
        final hostText = await note.readAsString();
        print('host file:  ${hostText.trim()}');
        _check(hostText == 'from the host disk', 'host file untouched');
      }),
    );
  } finally {
    mount.close(); // idempotent; new feeds can no longer use the mount
    await hostDir.delete(recursive: true);
  }
}

void _check(bool ok, String what) {
  if (!ok) throw StateError('unexpected result: $what');
}

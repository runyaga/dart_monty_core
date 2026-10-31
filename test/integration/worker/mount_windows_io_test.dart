@TestOn('windows')
@Tags(['worker'])
library;

import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// The Windows-only escape surface of a host MountDir, in every mode: NTFS
// junctions and symlinks, backslash and drive-letter paths, reserved device
// names and trailing-dot/space aliases. Each case must be refused without
// the sandbox reading the secret beside the mount root, and nothing may be
// written outside the root. Runs in CI job `test-worker-windows`, which
// builds the worker and mount library this suite needs.
//
// Host layout, one temp directory per run:
//   <tmp>/secret.txt          never readable from Python
//   <tmp>/root/inside.txt     mounted at /data
//   <tmp>/root/jlink          junction to <tmp>
//   <tmp>/root/flink          file symlink to <tmp>/secret.txt (when the
//                             account may create symlinks)

const _secret = 'TOP-SECRET-HOST-DATA';
const _modes = ['read-only', 'overlay', 'read-write'];

/// A raised error the sandbox reports as one of [types].
Matcher _refusedAs(Set<String> types) => throwsA(
  isA<MontyRuntimeError>()
      .having((e) => e.exception.excType, 'type', isIn(types))
      .having((e) => '$e', 'text', isNot(contains(_secret))),
);

final Matcher _refused = _refusedAs({
  'PermissionError',
  'FileNotFoundError',
  'OSError',
});

void main() {
  late Directory tmp;
  late Directory root;
  late bool fileSymlink;
  late Monty monty;

  String hostPy(String path) => 'r"$path"';

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('mount_windows');
    root = Directory('${tmp.path}\\root')..createSync();
    File('${tmp.path}\\secret.txt').writeAsStringSync(_secret);
    File('${root.path}\\inside.txt').writeAsStringSync('inside');
    final junction = await Process.run('cmd', [
      '/c',
      'mklink',
      '/J',
      '${root.path}\\jlink',
      tmp.path,
    ]);
    if (junction.exitCode != 0) {
      fail('mklink /J failed: ${junction.stdout}${junction.stderr}');
    }
    try {
      Link('${root.path}\\flink').createSync('${tmp.path}\\secret.txt');
      fileSymlink = true;
    } on FileSystemException {
      // Creating file symlinks needs Developer Mode or elevation.
      fileSymlink = false;
    }
    monty = await Monty.start();
  });

  tearDownAll(() async {
    await monty.close();
    // Remove the junction first, so the recursive delete cannot reach
    // through it into <tmp> twice.
    await Process.run('cmd', ['/c', 'rmdir', '${root.path}\\jlink']);
    await tmp.delete(recursive: true);
  });

  for (final mode in _modes) {
    group('$mode mount', () {
      late MountDir mount;

      setUp(() {
        mount = MountDir(hostPath: root.path, virtualPath: '/data', mode: mode);
      });

      tearDown(() => mount.close());

      Future<MontyValue> run(String code) =>
          monty.withSession((s) => s.feedRun(code, mount: [mount]));

      test('reads a file inside the root', () async {
        expect(
          await run('open("/data/inside.txt").read()'),
          const MontyString('inside'),
        );
      });

      test('refuses .. past the root', () async {
        await expectLater(run('open("/data/../secret.txt").read()'), _refused);
      });

      test(r'refuses a backslash \..\ past the root', () async {
        await expectLater(
          run(r'open("/data\\..\\secret.txt").read()'),
          _refused,
        );
      });

      test('refuses pathlib .. past the root', () async {
        await expectLater(
          run(
            'from pathlib import Path\n'
            'Path("/data/x/../../secret.txt").read_text()',
          ),
          _refused,
        );
      });

      test('refuses reading through a junction', () async {
        await expectLater(
          run('open("/data/jlink/secret.txt").read()'),
          _refused,
        );
      });

      test('refuses listing through a junction', () async {
        await expectLater(
          run('import os\nos.listdir("/data/jlink")'),
          _refused,
        );
      });

      test('refuses writing through a junction', () async {
        await expectLater(
          run('open("/data/jlink/pwned.txt", "w").write("x")'),
          _refused,
        );
        expect(File('${tmp.path}\\pwned.txt').existsSync(), isFalse);
      });

      test('refuses reading through a file symlink', () async {
        if (!fileSymlink) {
          markTestSkipped('this account may not create file symlinks');

          return;
        }
        await expectLater(run('open("/data/flink").read()'), _refused);
      });

      test('keeps a drive-letter path inside the mount', () async {
        final secret = '${tmp.path}\\secret.txt';
        await expectLater(
          run('open(${hostPy(secret.replaceAll(r'\', '/'))}).read()'),
          _refused,
        );
        await expectLater(run('open(${hostPy(secret)}).read()'), _refused);
      });

      test('refuses renaming out of the mount', () async {
        await expectLater(
          run('import os\nos.rename("/data/inside.txt", "/outside.txt")'),
          _refused,
        );
        expect(File('${root.path}\\inside.txt').existsSync(), isTrue);
      });

      test('refuses writing .. past the root', () async {
        await expectLater(
          run('open("/data/../pwned2.txt", "w").write("x")'),
          _refused,
        );
        expect(File('${tmp.path}\\pwned2.txt').existsSync(), isFalse);
      });

      test('does not alias a trailing dot or space to the file', () async {
        await expectLater(run('open("/data/inside.txt.").read()'), _refused);
        await expectLater(run('open("/data/inside.txt ").read()'), _refused);
      });

      test('does not open reserved device names', () async {
        for (final name in ['CON', 'COM1', 'AUX', 'NUL']) {
          await expectLater(
            run('open("/data/$name").read()'),
            _refused,
            reason: name,
          );
        }
      });

      if (mode == 'read-write') {
        test('refuses writing reserved device names to the host', () async {
          for (final name in ['NUL', 'aux.txt', 'CON', 'COM1']) {
            await expectLater(
              run('open("/data/$name", "w").write("x")'),
              _refused,
              reason: name,
            );
          }
        });
      }
    });
  }

  test('nothing was written outside the mount root', () {
    final outside = tmp.listSync().map((e) => p.basename(e.path)).toList()
      ..sort();
    expect(outside, ['root', 'secret.txt']);
    expect(File('${tmp.path}\\secret.txt').readAsStringSync(), _secret);
  });
}

// Run the shipping script against a fake platform and a toolchain that
// records any attempted build. No native sources exist in the fixture.
@Tags(['integration'])
@TestOn('vm && !windows')
library;

import 'dart:io';

import 'package:test/test.dart';

Directory _fixture(String os, String arch) {
  final root = Directory.systemTemp.createTempSync('channel_build_print_');
  addTearDown(() => root.deleteSync(recursive: true));
  Directory('${root.path}/tool').createSync();
  Directory('${root.path}/bin').createSync();
  File('tool/build_worker.sh').copySync('${root.path}/tool/build_worker.sh');
  _executable(
    root,
    'uname',
    '#!/bin/sh\n'
        'case "\$1" in -s) echo "$os";; -m) echo "$arch";; esac\n',
  );
  for (final tool in ['cargo', 'rustc', 'rustup']) {
    _executable(
      root,
      tool,
      '#!/bin/sh\n'
      'echo "$tool" >> "\$BUILD_PROBE"\nexit 91\n',
    );
  }

  return root;
}

void _executable(Directory root, String name, String text) {
  final file = File('${root.path}/bin/$name')..writeAsStringSync(text);
  final result = Process.runSync('/bin/chmod', ['+x', file.path]);
  expect(result.exitCode, 0, reason: '${result.stderr}');
}

void main() {
  for (final (host, arch, directory, executable, library) in [
    (
      'Darwin',
      'arm64',
      'macos-arm64',
      'dart_monty_worker',
      'libdart_monty_worker.dylib',
    ),
    (
      'Linux',
      'x86_64',
      'linux-x64',
      'dart_monty_worker',
      'libdart_monty_worker.so',
    ),
    (
      'MINGW64_NT',
      'amd64',
      'windows-x64',
      'dart_monty_worker.exe',
      'dart_monty_worker.dll',
    ),
  ]) {
    test(
      '--print reports $directory '
      'without building',
      () async {
        final root = _fixture(host, arch);
        final probe = File('${root.path}/builds');
        final result = await Process.run(
          '/bin/bash',
          ['${root.path}/tool/build_worker.sh', '--print'],
          environment: {
            'PATH': '${root.path}/bin:/usr/bin:/bin',
            'BUILD_PROBE': probe.path,
          },
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(
          result.stdout,
          'lib/src/bin/$directory/$executable\n'
          'lib/src/bin/$directory/$library\n',
        );
        expect(result.stderr, isEmpty);
        expect(probe.existsSync(), isFalse);
        expect(Directory('${root.path}/lib').existsSync(), isFalse);
      },
    );
  }
}

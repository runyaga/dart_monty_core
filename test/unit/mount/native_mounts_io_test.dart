@Tags(['vm-only'])
@TestOn('vm')
library;

import 'dart:io';

import 'package:dart_monty_core/src/mount/native_mount_service.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/worker/arena_reader.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:test/test.dart';

// Expectations: design/F/evidence/probes/oracle_probes.out, P01-P08.
// Protobuf is transport only; no expected result is computed by monty-fs.
void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('dmfs-');
    File('${dir.path}/a.txt').writeAsStringSync('host');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  NativeMountRoot root({
    String path = '/d',
    String? host,
    String mode = 'overlay',
    int? writes,
    int memory = 100000000,
  }) {
    final value = NativeMountRoot(
      hostPath: host ?? dir.path,
      virtualPath: path,
      mode: mode,
      writeBytesLimit: writes,
      memoryUsageLimit: memory,
    );
    addTearDown(value.close);
    return value;
  }

  NativeMountTable table(List<NativeMountRoot> roots) {
    final value = NativeMountTable(roots);
    addTearDown(value.close);
    return value;
  }

  test('P01 normalises virtual paths and reports canonical host', () {
    final alias = Link('${dir.path}/alias')..createSync(dir.path);
    final mount = root(path: '/a/../d/', host: alias.path);
    expect(mount.virtualPath, '/d');
    expect(mount.hostPath, dir.resolveSymbolicLinksSync());
    expect(root(path: '/').virtualPath, '/');
  });
  test('upstream retains embedded NUL virtual labels and mode error text', () {
    // MountRoot::open only requires an absolute virtual path; do not add a
    // C-string truncation or validation rule that upstream does not have.
    expect(root(path: '/d\u0000tail').virtualPath, '/d\u0000tail');
    expect(
      () => root(mode: 'overlay\u0000tail'),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          "Invalid mode 'overlay\u0000tail', expected 'read-only', "
              "'read-write', or 'overlay'",
        ),
      ),
    );
  });
  test('P01 rejects relative and empty virtual paths', () {
    for (final path in ['data', '']) {
      expect(
        () => root(path: path),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            "virtual path must be absolute, got: '$path'",
          ),
        ),
      );
    }
  });
  test('P01 rejects missing and file host paths', () {
    for (final (path, suffix) in [
      ('${dir.path}/missing', 'No such file or directory (os error 2)'),
      ('${dir.path}/a.txt', 'Not a directory (os error 20)'),
    ]) {
      expect(
        () => root(host: path),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            "cannot open host path '$path': $suffix",
          ),
        ),
      );
    }
  });
  test('P01 rejects invalid mode and negative budgets', () {
    expect(
      () => root(mode: 'rw'),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          "Invalid mode 'rw', expected 'read-only', 'read-write', or 'overlay'",
        ),
      ),
    );
    expect(() => root(writes: -1), throwsRangeError);
    expect(() => root(memory: -1), throwsRangeError);
  });
  test('P02 overlap fails at begin-feed with runtime ValueError', () {
    final first = root(path: '/m1');
    final second = root(path: '/m2');
    expect(
      () => table([first, second]),
      throwsA(
        isA<MontyRuntimeError>()
            .having((e) => e.exception.excType, 'type', 'ValueError')
            .having(
              (e) => e.toString(),
              'text',
              "ValueError: cannot mount '${second.hostPath}' at '/m2': it overlaps "
                  "the mount of '${first.hostPath}' at '/m1'; mounts must have distinct "
                  'virtual paths and disjoint host directories',
            )
            .having((e) => e.traceback, 'traceback', isEmpty),
      ),
    );
  });
  test('P02 duplicate virtual and nested host directories overlap', () {
    final other = Directory.systemTemp.createTempSync('dmfs-other-');
    addTearDown(() => other.deleteSync(recursive: true));
    final nested = Directory('${dir.path}/sub')..createSync();
    for (final second in [
      root(host: other.path),
      root(host: nested.path, path: '/x'),
    ]) {
      expect(
        () => table([root(), second]),
        throwsA(
          isA<MontyRuntimeError>()
              .having((e) => e.exception.excType, 'type', 'ValueError')
              .having(
                (e) => e.exception.message,
                'text',
                contains('it overlaps the mount'),
              ),
        ),
      );
    }
  });
  test('nested virtual paths with disjoint hosts use longest prefix', () {
    // P02 also nested its hosts; upstream mount_table.rs explicitly permits
    // nested virtual paths when the hosts are disjoint (contract rule 7a).
    final other = Directory.systemTemp.createTempSync('dmfs-other-');
    addTearDown(() => other.deleteSync(recursive: true));
    File('${other.path}/a.txt').writeAsStringSync('nested');
    final feed = table([root(), root(host: other.path, path: '/d/sub')]);
    expect(
      value(feed, pb.OsCall(readText: '/d/sub/a.txt')),
      const MontyString('nested'),
    );
  });
  test(
    'P03 closed root refuses new tables but existing table retains capability',
    () {
      final mount = root();
      final feed = table([mount]);
      mount
        ..close()
        ..close();
      expect(mount.virtualPath, '/d');
      expect(
        () => table([mount]),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            "mount '/d' is closed",
          ),
        ),
      );
      expect(
        value(feed, pb.OsCall(readText: '/d/a.txt')),
        const MontyString('host'),
      );
    },
  );
  test(
    'P07 route 2 handles reads and leaves outside and non-fs calls unhandled',
    () {
      final feed = table([root()]);
      expect(nativeMountLookupRoute, 'package');
      expect(
        value(feed, pb.OsCall(readText: '/d/a.txt')),
        const MontyString('host'),
      );
      expect(
        feed.call(pb.OsCall(readText: '/else/a.txt').writeToBuffer()),
        isNull,
      );
      expect(
        feed.call(
          pb.OsCall(getEnviron: pb.Unit()).writeToBuffer(),
        ),
        isNull,
      );
      expect(
        error(feed, pb.OsCall(readText: '/d/nope.txt')),
        "FileNotFoundError: [Errno 2] No such file or directory: '/d/nope.txt'",
      );
    },
  );
  test('P04 read-only refuses writes', () {
    expect(
      error(table([root(mode: 'read-only')]), write('ov')),
      "PermissionError: [Errno 30] Read-only file system: '/d/a.txt'",
    );
  });
  test('P04 overlay is discarded at end-feed', () {
    final mount = root();
    final first = table([mount]);
    expect(value(first, write('ov')), const MontyInt(2));
    expect(
      value(first, pb.OsCall(readText: '/d/a.txt')),
      const MontyString('ov'),
    );
    first.close();
    expect(File('${dir.path}/a.txt').readAsStringSync(), 'host');
    expect(
      value(table([mount]), pb.OsCall(readText: '/d/a.txt')),
      const MontyString('host'),
    );
    expect(
      () => first.call(pb.OsCall(exists: '/d').writeToBuffer()),
      throwsStateError,
    );
  });
  test('P04 read-write persists on host', () {
    expect(
      value(table([root(mode: 'read-write')]), write('rw')),
      const MontyInt(2),
    );
    expect(File('${dir.path}/a.txt').readAsStringSync(), 'rw');
  });
  test('P05 write budget resets per table', () {
    final mount = root(writes: 10);
    final first = table([mount]);
    expect(value(first, write('12345678')), const MontyInt(8));
    expect(
      error(first, write('12345678')),
      'OSError: disk write limit of 10 bytes exceeded',
    );
    first.close();
    expect(value(table([mount]), write('12345678')), const MontyInt(8));
  });
  test('P05 transient reads obey memory budget in every mode', () {
    File('${dir.path}/a.txt').writeAsStringSync('a' * 5000);
    for (final mode in ['overlay', 'read-write', 'read-only']) {
      expect(
        error(
          table([root(mode: mode, memory: 1000)]),
          pb.OsCall(readText: '/d/a.txt'),
        ),
        'MemoryError: mount memory usage limit of 1 KB exceeded',
      );
    }
  });
  test('P05 exists needs no read buffer at zero memory', () {
    expect(
      value(table([root(memory: 0)]), pb.OsCall(exists: '/d/a.txt')),
      const MontyBool(true),
    );
  });
  test('tables have independent live overlays', () {
    final mount = root();
    final first = table([mount]);
    final second = table([mount]);
    expect(value(first, write('ov')), const MontyInt(2));
    expect(
      value(second, pb.OsCall(readText: '/d/a.txt')),
      const MontyString('host'),
    );
  });
  test('P05 overlay writes obey memory budget', () {
    expect(
      error(table([root(memory: 1000)]), write('a' * 2000)),
      'MemoryError: mount memory usage limit of 1 KB exceeded',
    );
  });
  test('P08 relative symlink works and absolute symlink is refused', () {
    Link('${dir.path}/rel_link').createSync('a.txt');
    expect(Link('${dir.path}/rel_link').targetSync(), 'a.txt');
    expect(File('${dir.path}/rel_link').readAsStringSync(), 'host');
    Link('${dir.path}/abs_link').createSync('${dir.path}/a.txt');
    // P08 explicitly uses read-write; overlay refuses all symlinks upstream.
    final feed = table([root(mode: 'read-write')]);
    expect(
      value(feed, pb.OsCall(readText: '/d/rel_link')),
      const MontyString('host'),
    );
    expect(
      error(feed, pb.OsCall(readText: '/d/abs_link')),
      "PermissionError: [Errno 13] Permission denied: '/d/abs_link'",
    );
  });
  test('P08 cross-mount and outside rename are refused', () {
    final other = Directory.systemTemp.createTempSync('dmfs-other-');
    addTearDown(() => other.deleteSync(recursive: true));
    final feed = table([root(), root(host: other.path, path: '/m2')]);
    for (final dest in ['/m2/a.txt', '/else/a.txt']) {
      expect(
        error(
          feed,
          pb.OsCall(
            rename: pb.OsCall_Rename(src: '/d/a.txt', dst: dest),
          ),
        ),
        "OSError: [Errno 18] Invalid cross-device link: '/d/a.txt' -> '$dest'",
      );
    }
  });
  test('opened root survives host directory rename', () {
    final mount = root();
    final original = dir.path;
    dir = dir.renameSync('$original-renamed');
    Directory(original).createSync();
    addTearDown(() => Directory(original).deleteSync());
    expect(
      value(table([mount]), pb.OsCall(readText: '/d/a.txt')),
      const MontyString('host'),
    );
  });
  test('NativeFinalizer releases unclosed directory capabilities', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      '--enable-vm-service=0',
      'run',
      'test/unit/mount/native_mount_finalizer_probe.dart',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('finalized 32 mount roots'));
  }, skip: Platform.isWindows ? 'descriptor probe uses POSIX fcntl' : false);
  test('malformed protobuf is refused without poisoning the table', () {
    final feed = table([root()]);
    expect(() => feed.call([255]), throwsFormatException);
    expect(
      value(feed, pb.OsCall(readText: '/d/a.txt')),
      const MontyString('host'),
    );
  });
}

pb.OsCall write(String content) => pb.OsCall(
  writeText: pb.OsCall_TextWrite(path: '/d/a.txt', data: content),
);

pb.ResumeCall reply(NativeMountTable table, pb.OsCall call) {
  call.callId = 73;
  final result = pb.ResumeCall.fromBuffer(table.call(call.writeToBuffer())!);
  expect(result.callId, 73);
  return result;
}

MontyValue value(NativeMountTable table, pb.OsCall call) {
  final result = reply(table, call);
  expect(
    result.result.whichKind(),
    pb.ExtFunctionResult_Kind.returnValue,
    reason: '${result.result.error.excType}: ${result.result.error.message}',
  );
  return ArenaReader(result.values)[result.result.returnValue];
}

String error(NativeMountTable table, pb.OsCall call) {
  final result = reply(table, call);
  expect(result.result.whichKind(), pb.ExtFunctionResult_Kind.error);
  return '${result.result.error.excType}: ${result.result.error.message}';
}

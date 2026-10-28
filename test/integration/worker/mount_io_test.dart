@TestOn('vm')
@Tags(['worker'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/dart_monty_core_testing.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:test/test.dart';

import '../../unit/worker/_mount_cwd_cases.dart';
import '../../unit/worker/_mount_sleep_cases.dart';
import '../../unit/worker/_open_cases.dart';
import '_worker_harness.dart';

// Expected values and error text: owner-approved P01-P08, P11/P11b, P14,
// plus the two-path rename and cwd controls in parity.md.
TypeMatcher<MontyRuntimeError> _raised(String type, Object message) =>
    isA<MontyRuntimeError>()
        .having((e) => e.exception.excType, 'type', type)
        .having((e) => e.exception.message, 'message', message);

/// Runs [body] against the mounted session, with the mount the shared open()
/// cases need.
///
/// The session and the host directory are borrowed from the test's setup; the
/// runner owns its own read-write mount, which is closed when the case ends.
Future<void> _withOpenRunner(
  MontySession session,
  Directory dir,
  Future<void> Function(OpenCaseRunner runner) body,
) async {
  final openMount = MountDir(
    hostPath: dir.path,
    virtualPath: '/d',
    mode: 'read-write',
  );
  try {
    await body(_MountRunner(session, dir, openMount));
  } finally {
    openMount.close();
  }
}

/// The shared open() cases, run against the mounted session.
///
/// Every feed gets the `Path` import the cases need, and the host bytes are
/// read from the mount's host directory.
final class _MountRunner implements OpenCaseRunner {
  const _MountRunner(this._session, this._hostDir, this._mount);

  final MontySession _session;
  final Directory _hostDir;
  final MountDir _mount;

  @override
  Future<MontyValue> run(String code) =>
      _session.feedRun('from pathlib import Path\n$code', mount: [_mount]);

  @override
  List<int> hostBytes(String path) {
    const prefix = '/d/';
    if (!path.startsWith(prefix)) {
      throw ArgumentError.value(path, 'path', "must start with '$prefix'");
    }

    return File(
      '${_hostDir.path}/${path.substring(prefix.length)}',
    ).readAsBytesSync();
  }
}

/// The three answers the BOM program gives, read through a native mount.
///
/// The feed runs on the worker this tree builds from the pinned upstream
/// tag, because the answers are upstream 1.2.0's and the published asset
/// the shared pool starts predates upstream 1.2.0. Without that build the
/// shared session answers instead, so the test still measures the read and
/// fails on the answer rather than raising.
Future<MontyValue> _bomAnswers(
  MontySession shared,
  String program,
  MountDir Function() mount,
) async {
  final worker = await _upstreamWorkerPath();
  if (worker == null) {
    return shared.feedRun(program, mount: [mount()]);
  }
  final pool = await Monty.start(maxProcesses: 1, workerLocation: worker);
  try {
    final session = await pool.checkout();
    try {
      return await session.feedRun(program, mount: [mount()]);
    } finally {
      await session.close();
    }
  } finally {
    await pool.close();
  }
}

/// The path of the worker this tree builds from the pinned upstream tag
/// (tool/build_worker.sh), or null when it is not built.
Future<String?> _upstreamWorkerPath() async {
  try {
    final launch = await realWorker();

    return switch (launch) {
      final WorkerExecutable executable => executable.path,
      _ => null,
    };
  } on Object {
    return null;
  }
}

Future<MontyValue> _finish(MontySnapshot snapshot) async {
  var current = snapshot;
  while (current is! MontyComplete) {
    current = switch (current) {
      FunctionSnapshot() => await current.resumeAuto(),
      NameLookupSnapshot() => await current.resumeAuto(),
      _ => throw StateError('unexpected snapshot $current'),
    };
  }

  return current.output;
}

void main() {
  expectNoWorkersLeftAfterEachTest();
  late Directory dir;
  late Monty pool;
  late MontySession session;
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('f2-mount-');
    File('${dir.path}/a.txt').writeAsStringSync('A');
    Directory('${dir.path}/sub').createSync();
    pool = await Monty.start(maxProcesses: 3);
    session = await pool.checkout();
  });
  tearDown(() async {
    await session.close();
    await pool.close();
    dir.deleteSync(recursive: true);
  });

  MountDir mount({
    String path = '/d',
    String? host,
    String mode = 'overlay',
    int? writes,
    int memory = 100000000,
  }) {
    final result = MountDir(
      hostPath: host ?? dir.path,
      virtualPath: path,
      mode: mode,
      writeBytesLimit: writes,
      memoryUsageLimit: memory,
    );
    addTearDown(result.close);

    return result;
  }

  Future<MontyValue> run(String code, List<MountDir> mounts, {OsHandler? os}) =>
      session.feedRun('from pathlib import Path\n$code', mount: mounts, os: os);

  mountCwdTests(mountsFor: (path) => [mount(path: path)]);
  mountCwdTests();

  // The open() contract, shared with the browser runner. Each case owns a
  // read-write mount at /d, so the bytes it writes reach the host.
  test('the newline argument is validated after the open', () async {
    await _withOpenRunner(session, dir, expectOpenNewline);
  });

  test('reading with each newline mode reads what CPython reads', () async {
    await _withOpenRunner(session, dir, expectOpenReadMatrix);
  });

  test('writing with each newline mode writes what CPython writes', () async {
    await _withOpenRunner(session, dir, expectOpenWriteMatrix);
  });

  test('iterating a text file keeps one shared position', () async {
    await _withOpenRunner(session, dir, expectOpenIteration);
  });

  test('P01 construction canonical fields normalization repr and close', () {
    final alias = Link('${dir.path}/alias')..createSync(dir.path);
    final value = mount(host: alias.path, path: '/a/../d/');
    expect(value.hostPath, dir.resolveSymbolicLinksSync());
    expect(value.virtualPath, '/d');
    expect(value.mode, 'overlay');
    expect(value.writeBytesLimit, isNull);
    expect(value.memoryUsageLimit, 100000000);
    final repr =
        "MountDir(host_path='${value.hostPath}', virtual_path='/d', mode='overlay')";
    final representation = isA<MountDir>().having(
      (m) => m.toString(),
      'repr',
      repr,
    );
    expect(value, representation);
    value
      ..close()
      ..close();
    expect(value, representation);
    expect(mount(path: '/').virtualPath, '/');
  });
  test('P01 construction rejects paths mode and negative limits', () {
    for (final path in ['', 'relative']) {
      expect(
        () => mount(path: path),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            "virtual path must be absolute, got: '$path'",
          ),
        ),
      );
    }
    for (final path in ['${dir.path}/missing', '${dir.path}/a.txt']) {
      expect(
        () => mount(host: path),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            startsWith("cannot open host path '$path':"),
          ),
        ),
      );
    }
    expect(
      () => mount(mode: 'rw'),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          "Invalid mode 'rw', expected 'read-only', 'read-write', or 'overlay'",
        ),
      ),
    );
    expect(() => mount(writes: -1), throwsRangeError);
    expect(() => mount(memory: -1), throwsRangeError);
  });

  for (final conflict in ['duplicate virtual', 'same host', 'nested host']) {
    test('P02 $conflict rejected before Feed and session survives', () async {
      final other = Directory('${dir.path}-other')..createSync();
      addTearDown(() => other.deleteSync(recursive: true));
      final mounts = [
        mount(),
        mount(
          path: conflict == 'duplicate virtual' ? '/d' : '/other',
          host: switch (conflict) {
            'duplicate virtual' => other.path,
            'nested host' => '${dir.path}/sub',
            _ => dir.path,
          },
        ),
      ];
      await expectLater(
        session.feedRun('sent = 1', mount: mounts),
        throwsA(
          _raised(
            'ValueError',
            contains(
              'mounts must have distinct virtual paths '
              'and disjoint host directories',
            ),
          ).having((e) => e.traceback, 'traceback', isEmpty),
        ),
      );
      await expectLater(
        session.feedRun('sent'),
        throwsA(_raised('NameError', "name 'sent' is not defined")),
      );
      expect(await session.feedRun('2'), const MontyInt(2));
    });
  }
  test(
    'P02 disjoint hosts allow nested virtual mounts longest prefix wins',
    () async {
      final other = Directory('${dir.path}-other')..createSync();
      addTearDown(() => other.deleteSync(recursive: true));
      File('${other.path}/a.txt').writeAsStringSync('nested');
      expect(
        await run("Path('/d/sub/a.txt').read_text()", [
          mount(),
          mount(host: other.path, path: '/d/sub'),
        ]),
        const MontyString('nested'),
      );
    },
  );

  for (final start in [false, true]) {
    test('P03 closed mount rejected before Feed start=$start', () async {
      final value = mount()..close();
      await expectLater(
        start
            ? session.feedStart('sent = 1', mount: [value])
            : session.feedRun('sent = 1', mount: [value]),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            "mount '/d' is closed",
          ),
        ),
      );
      await expectLater(
        session.feedRun('sent'),
        throwsA(_raised('NameError', "name 'sent' is not defined")),
      );
      expect(await session.feedRun('3'), const MontyInt(3));
    });
  }
  test('P04 overlay per feed discards writes and deletes', () async {
    final value = mount();
    expect(
      await run(
        "Path('/d/a.txt').write_text('ov')\nPath('/d/a.txt').read_text()",
        [value],
      ),
      const MontyString('ov'),
    );
    expect(
      await run("Path('/d/a.txt').read_text()", [value]),
      const MontyString('A'),
    );
    expect(
      await run("Path('/d/a.txt').unlink()\nPath('/d/a.txt').exists()", [
        value,
      ]),
      const MontyBool(false),
    );
    expect(
      await run("Path('/d/a.txt').exists()", [value]),
      const MontyBool(true),
    );
    expect(File('${dir.path}/a.txt').readAsStringSync(), 'A');
    await expectLater(
      run("Path('/d/a.txt').read_text()", []),
      throwsA(_raised('PermissionError', "Permission denied: '/d/a.txt'")),
    );
  });
  test('P04 read-write persists on host', () async {
    expect(
      await run("Path('/d/a.txt').write_text('rw')", [
        mount(mode: 'read-write'),
      ]),
      const MontyInt(2),
    );
    expect(File('${dir.path}/a.txt').readAsStringSync(), 'rw');
  });
  test('P04 read-only rejects mutation with errno 30', () async {
    final value = mount(mode: 'read-only');
    for (final (code, path) in [
      ("Path('/d/a.txt').write_text('ro')", '/d/a.txt'),
      ("Path('/d/n').mkdir()", '/d/n'),
    ]) {
      await expectLater(
        run(code, [value]),
        throwsA(
          _raised(
            'PermissionError',
            "[Errno 30] Read-only file system: '$path'",
          ),
        ),
      );
    }
    expect(File('${dir.path}/a.txt').readAsStringSync(), 'A');
  });
  test('P05 write budget resets after failed feed', () async {
    final value = mount(writes: 10);
    const write = "Path('/d/w.txt').write_text('12345678')";
    expect(await run(write, [value]), const MontyInt(8));
    await expectLater(
      run('$write\n$write', [value]),
      throwsA(_raised('OSError', 'disk write limit of 10 bytes exceeded')),
    );
    expect(await run(write, [value]), const MontyInt(8));
  });
  for (final mode in ['overlay', 'read-write', 'read-only']) {
    test('P05 $mode transient read memory budget', () async {
      File('${dir.path}/big.txt').writeAsStringSync('x' * 5000);
      await expectLater(
        run("Path('/d/big.txt').read_text()", [
          mount(mode: mode, memory: 1000),
        ]),
        throwsA(
          _raised('MemoryError', 'mount memory usage limit of 1 KB exceeded'),
        ),
      );
    });
  }
  test('P05 overlay retained write memory budget', () async {
    await expectLater(
      run("Path('/d/n.txt').write_text('y' * 2000)", [mount(memory: 1000)]),
      throwsA(
        _raised('MemoryError', 'mount memory usage limit of 1 KB exceeded'),
      ),
    );
  });
  test(
    'P06 explicit cwd resolves relative paths without first-mount default',
    () async {
      expect(
        await session.feedRun(
          "from pathlib import Path\nPath('a.txt').read_text()",
          cwd: '/d',
          mount: [mount()],
        ),
        const MontyString('A'),
      );
    },
  );
  test('P07 mount precedes handler and missing never falls back', () async {
    final value = mount();
    final seen = <String>[];
    MontyValue handler(
      String name,
      List<MontyValue> _,
      Map<String, MontyValue> _,
    ) {
      seen.add(name);

      return const MontyString('from-os');
    }

    expect(
      await run("Path('/d/a.txt').read_text()", [value], os: handler),
      const MontyString('A'),
    );
    await expectLater(
      run("Path('/d/missing').read_text()", [value], os: handler),
      throwsA(
        _raised(
          'FileNotFoundError',
          "[Errno 2] No such file or directory: '/d/missing'",
        ),
      ),
    );
    expect(seen, isEmpty);
    expect(
      await run("Path('/else/a.txt').read_text()", [value], os: handler),
      const MontyString('from-os'),
    );
    expect(
      await run("import os\nos.getenv('K')", [value], os: handler),
      const MontyString('from-os'),
    );
    expect(seen, ['Path.read_text', 'os.getenv']);
  });
  test('P07 declined outside and pathless default errors', () async {
    final value = mount();
    final denied = throwsA(
      _raised('PermissionError', "Permission denied: '/else/a.txt'"),
    );
    await expectLater(
      run("Path('/else/a.txt').exists()", [
        value,
      ], os: (n, a, k) => throw const OsCallNotHandledException()),
      denied,
    );
    await expectLater(
      run("Path('/else/a.txt').read_text()", [value]),
      denied,
    );
    await expectLater(
      run("import os\nos.getenv('K')", [value]),
      throwsA(
        _raised(
          'RuntimeError',
          "'os.getenv' is not supported in this environment",
        ),
      ),
    );
  });
  for (final (src, dst) in [
    ('/else/a', '/d/a'),
    ('/d/a', '/else/a'),
    ('/d/a', '/other/a'),
  ]) {
    test('P08 rename $src to $dst never falls back', () async {
      final other = Directory('${dir.path}-other')..createSync();
      addTearDown(() => other.deleteSync(recursive: true));
      var calls = 0;
      await expectLater(
        run(
          "Path('$src').rename('$dst')",
          [mount(), mount(host: other.path, path: '/other')],
          os: (n, a, k) {
            calls++;

            return const MontyNone();
          },
        ),
        throwsA(
          _raised(
            'OSError',
            "[Errno 18] Invalid cross-device link: '$src' -> '$dst'",
          ),
        ),
      );
      expect(calls, 0);
    });
  }
  test('P08 rename same mount executes and neither mount falls back', () async {
    var calls = 0;
    final value = mount();
    expect(
      await run(
        "Path('/d/a.txt').rename('/d/b.txt')\nPath('/d/b.txt').read_text()",
        [value],
        os: (n, a, k) {
          calls++;

          return const MontyNone();
        },
      ),
      const MontyString('A'),
    );
    expect(calls, 0);
    await run(
      "Path('/else/a').rename('/else/b')",
      [value],
      os: (n, a, k) {
        calls++;

        return const MontyNone();
      },
    );
    expect(calls, 1);
  });
  for (final (label, dst, message) in [
    (
      'length',
      '/${'x' * 4096}',
      "[Errno 36] File name too long: '/${'x' * 19}…${'x' * 20}'",
    ),
    ('NUL', '/bad\u0000dst', 'rename: embedded null character in dst'),
    (
      'length before NUL',
      '/${'x' * 4096}\u0000',
      "[Errno 36] File name too long: '/${'x' * 19}…${'x' * 19}\\x00'",
    ),
  ]) {
    test('P08 rename invalid destination $label no fallback', () async {
      var calls = 0;
      final value = mount();
      // The interpreter rejects NUL before emitting an OS call. Exercise
      // the host boundary with raw scripted paths to test table validation
      // (mount_table.rs:188-206), including the no-table fallback control.
      final fake = FakeMontySession();
      addTearDown(fake.close);
      Future<MontyValue> rename(List<MountDir> mounts) {
        fake
          ..willCallOs(
            'Path.rename',
            args: [
              MontyPath('/else/a'),
              MontyPath(dst),
            ],
          )
          ..willReturn(const MontyNone());

        return fake.feedRun(
          'rename',
          mount: mounts,
          os: (n, a, k) {
            calls++;

            return const MontyNone();
          },
        );
      }

      await expectLater(
        rename([value]),
        throwsA(_raised(label == 'NUL' ? 'ValueError' : 'OSError', message)),
      );
      expect(calls, 0);
      await rename([]);
      expect(calls, 1);
    });
  }
  test('P08 symlinks and dotdot stay within directory capabilities', () async {
    Link('${dir.path}/abs').createSync('${dir.path}/a.txt');
    Link('${dir.path}/rel').createSync('a.txt');
    Link('${dir.path}/escape').createSync('../outside');
    final value = mount(mode: 'read-write');
    expect(
      await run("Path('/d/rel').read_text()", [value]),
      const MontyString('A'),
    );
    for (final name in ['abs', 'escape']) {
      await expectLater(
        run("Path('/d/$name').read_text()", [value]),
        throwsA(
          _raised(
            'PermissionError',
            "[Errno 13] Permission denied: '/d/$name'",
          ),
        ),
      );
    }
    await expectLater(
      run("Path('/d/../outside').read_text()", [value]),
      throwsA(_raised('PermissionError', "Permission denied: '/outside'")),
    );
  }, skip: Platform.isWindows ? 'POSIX symlinks' : false);
  test('P01 root capability survives host rename', () async {
    final value = mount();
    dir = dir.renameSync('${dir.path}-moved');
    expect(
      await run("Path('/d/a.txt').read_text()", [value]),
      const MontyString('A'),
    );
  }, skip: Platform.isWindows ? 'POSIX directory rename' : false);

  // A file written with a UTF-8 BOM reads back as text that KEEPS the mark:
  // the binary read gives the bytes, the text read gives the BOM and the
  // JSON. `json.load` of the bytes accepts them (it decodes them as
  // utf-8-sig), while `json.load` of the text rejects them, as CPython
  // does. Upstream's own fixture writes these bytes and asserts these
  // answers (`crates/monty/test_cases/json__file_io.py:51`).
  //
  // The answers are upstream 1.2.0's, so the feed runs on the worker this
  // tree builds from the pinned upstream tag (tool/build_worker.sh), not on
  // the published asset the shared pool starts: that one predates upstream
  // 1.2.0, and its `json` module has neither `load` nor the BOM rules.
  test('a text read through a native mount keeps a leading BOM', () async {
    // Every answer is taken through `attempt`, so a worker that cannot
    // answer one of them reports the error as the answer instead of
    // raising it: the test then fails on the answer, not on the raise.
    const program = r'''
import json
from pathlib import Path

def attempt(body):
    try:
        return body()
    except Exception as exc:
        return 'raised %s: %s' % (type(exc).__name__, exc)

def write_bom():
    Path('/mnt/b.json').write_bytes(b'\xef\xbb\xbf{"bom": 1}')

def binary_load():
    with open('/mnt/b.json', 'rb') as f:
        return json.load(f)

def text_message():
    with open('/mnt/b.json', encoding='utf-8') as f:
        try:
            json.load(f)
            return 'no JSONDecodeError'
        except json.JSONDecodeError as exc:
            return str(exc)

def head():
    with open('/mnt/b.json', encoding='utf-8') as f:
        return repr(f.read(2))

# The write goes through `attempt` too: a worker that cannot write the file
# then reports it in the answers below, which read the file back.
attempt(write_bom)
(attempt(binary_load), attempt(text_message), attempt(head))
''';
    const expected = <MontyValue>[
      MontyDict([(MontyString('bom'), MontyInt(1))]),
      MontyString(
        'Unexpected UTF-8 BOM (decode using utf-8-sig): '
        'line 1 column 1 (char 0)',
      ),
      // Python's repr of the two characters: the BOM escapes as \ufeff.
      MontyString(r"'\ufeff{'"),
    ];

    for (final mode in ['overlay', 'read-write']) {
      final answers = await _bomAnswers(
        session,
        program,
        () => mount(path: '/mnt', mode: mode),
      );
      // A worker that answered something other than the tuple answers with
      // the one value it has, so the comparison names what came back.
      final items = answers is MontyTuple ? answers.items : [answers];
      expect(items, expected, reason: 'mount mode $mode');
    }
  });

  test(
    'P14 overlay across suspension and closing root retains active feed',
    () async {
      final value = mount();
      var snapshot = await session.feedStart(
        "from pathlib import Path\nPath('/d/n.txt').write_text('ov')\nPath('/d/n.txt').read_text()",
        mount: [value],
      );
      final suspendedCall = isA<FunctionSnapshot>();
      expect(snapshot, suspendedCall);
      value.close();
      snapshot = await (snapshot as FunctionSnapshot).resumeAuto();
      expect(snapshot, suspendedCall);
      expect(await _finish(snapshot), const MontyString('ov'));
      expect(File('${dir.path}/n.txt').existsSync(), isFalse);
    },
  );
  test('resume direct bypasses mount and handler', () async {
    var calls = 0;
    final snapshot = await session.feedStart(
      "from pathlib import Path\nPath('/d/a.txt').read_text()",
      mount: [mount()],
      os: (n, a, k) {
        calls++;

        return const MontyString('handler');
      },
    );
    expect(snapshot, isA<FunctionSnapshot>());
    final done = await (snapshot as FunctionSnapshot).resume(
      const ExternalReturnValue(MontyString('manual')),
    );
    expect(
      done,
      isA<MontyComplete>().having(
        (s) => s.output,
        'output',
        const MontyString('manual'),
      ),
    );
    expect(calls, 0);
  });
  test('resumeNotHandled bypasses mount and handler', () async {
    var calls = 0;
    final snapshot = await session.feedStart(
      "from pathlib import Path\nPath('/d/a.txt').read_text()",
      mount: [mount()],
      os: (n, a, k) {
        calls++;

        return const MontyString('handler');
      },
    );
    await expectLater(
      (snapshot as FunctionSnapshot).resumeNotHandled(),
      throwsA(_raised('PermissionError', "Permission denied: '/d/a.txt'")),
    );
    expect(calls, 0);
  });

  Future<Uint8List> dumpOverlay(MountDir value) async {
    var snapshot = await session.feedStart(
      "from pathlib import Path\nPath('/d/n.txt').write_text('ov')\n"
      "ext()\n(Path('/d/n.txt').exists(), Path('/d/a.txt').read_text())",
      mount: [value],
      externalLookup: {
        'ext': MontyHostFunction('ext', (a, k) => const MontyInt(1)),
      },
    );
    while (snapshot is! FunctionSnapshot || snapshot.isOsFunction) {
      snapshot = switch (snapshot) {
        FunctionSnapshot() => await snapshot.resumeAuto(),
        NameLookupSnapshot() => await snapshot.resumeAuto(),
        _ => throw StateError('expected suspension'),
      };
    }

    return snapshot.dump();
  }

  for (final mounted in [true, false]) {
    test('P11 restore with mount=$mounted starts fresh table', () async {
      final value = mount();
      final state = await dumpOverlay(value);
      final restored = await pool.checkout();
      addTearDown(restored.close);
      final snapshot = await restored.loadSnapshot(
        state,
        mount: mounted ? [value] : null,
        externalLookup: {
          'ext': MontyHostFunction('ext', (a, k) => const MontyInt(1)),
        },
      );
      if (mounted) {
        expect(
          await _finish(snapshot),
          const MontyTuple([MontyBool(false), MontyString('A')]),
        );
      } else {
        await expectLater(
          _finish(snapshot),
          throwsA(_raised('PermissionError', "Permission denied: '/d/n.txt'")),
        );
      }
      expect(File('${dir.path}/n.txt').existsSync(), isFalse);
    });
  }
  test(
    'P03 closed mount rejects loadSnapshot before Load and permits retry',
    () async {
      final open = mount();
      final state = await dumpOverlay(open);
      final closed = mount()..close();
      final restored = await pool.checkout();
      addTearDown(restored.close);
      await expectLater(
        restored.loadSnapshot(state, mount: [closed]),
        throwsStateError,
      );
      final snapshot = await restored.loadSnapshot(
        state,
        mount: [open],
        externalLookup: {
          'ext': MontyHostFunction('ext', (a, k) => const MontyInt(1)),
        },
      );
      expect(
        await _finish(snapshot),
        const MontyTuple([MontyBool(false), MontyString('A')]),
      );
    },
  );
  test('Fake scripted OS call is answered by mount before handler', () async {
    final fake = FakeMontySession()
      ..willCallOs('Path.read_text', args: [MontyPath('/d/a.txt')])
      ..willReturn(const MontyNone());
    addTearDown(fake.close);
    var calls = 0;
    await fake.feedRun(
      'script',
      mount: [mount()],
      os: (n, a, k) {
        calls++;

        return const MontyString('wrong');
      },
    );
    expect(
      fake.answers.singleOrNull?.answer,
      isA<ExternalReturnValue>().having(
        (a) => a.value,
        'value',
        const MontyString('A'),
      ),
    );
    expect(calls, 0);
  });
  group('sleep with mounts', () {
    mountSleepTests(mounts: () => [mount()]);
  });
}

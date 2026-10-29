@Tags(['unit'])
library;

import 'dart:async';
import 'dart:typed_data';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';
import '_custom_file.dart';

// Expectations: pinned os_access.py and approved P09/P12/P15 probes.
Future<MontyValue> call(
  OSAccess fs,
  String op,
  String path, [
  MontyValue? value,
]) => Future.sync(() => fs(op, [MontyPath(path), ?value], {}));
Matcher raises(String type, String message) => throwsA(
  isA<ExternalException>()
      .having((e) => e.excType, 'type', type)
      .having((e) => e.message, 'message', message),
);
void main() {
  _construction();
  _customFiles();
  _seedReplacement();
  _reads();
  _unpairedSurrogates();
  _upstreamArguments();
  _writes();
  _open();
  _directories();
  _renames();
  _scan();
  _defaults();
}

void _construction() {
  _constructionCase0();
  _constructionCase1();
  _constructionCase2();
  _constructionCase3();
  _constructionCase4();
  _constructionCase5();
}

void _constructionCase0() {
  test('relative seeds rootDir and PurePosixPath', () async {
    final file = MemoryFile('a//./../f', 'value');
    final fs = OSAccess(files: [file], rootDir: '/d');
    expect(file.path, '/d/a/../f');
    expect(
      await call(fs, 'Path.read_text', file.path),
      const MontyString('value'),
    );
    expect(await call(fs, 'Path.is_dir', '/'), const MontyBool(true));
  });
}

void _constructionCase1() {
  test('double slash seed is a distinct root', () async {
    final fs = OSAccess(files: [MemoryFile('//data/f', 'double')]);
    expect(
      await call(fs, 'Path.read_text', '//data/f'),
      const MontyString('double'),
    );
    expect(await call(fs, 'Path.exists', '/data/f'), const MontyBool(false));
  });
}

void _constructionCase2() {
  test(
    'filename-less seed replaces root and seed order replaces directories',
    () async {
      final fs = OSAccess(
        files: [
          MemoryFile('/a/b', 'b'),
          MemoryFile('/a', 'a'),
          MemoryFile('/', 'root'),
        ],
      );
      expect(await call(fs, 'Path.read_text', '/'), const MontyString('root'));
      expect(await call(fs, 'Path.exists', '/a/b'), const MontyBool(false));
    },
  );
}

void _constructionCase3() {
  test('P09 construction diagnostics', () {
    final argumentError = isA<ArgumentError>();
    expect(
      () => OSAccess(rootDir: 'rel'),
      throwsA(
        argumentError.having(
          (e) => e.message,
          'message',
          'Root directory must be absolute, got rel',
        ),
      ),
    );
    expect(
      () => OSAccess(files: [MemoryFile('/a', ''), MemoryFile('/a/b', '')]),
      throwsA(
        argumentError.having(
          (e) => e.message,
          'message',
          "Cannot put file MemoryFile(path=/a/b, content='...', permissions=420) within sub-directory of file MemoryFile(path=/a, content='...', permissions=420)",
        ),
      ),
    );
    expect(() => OSAccess(maxUrandomBytes: -1), throwsArgumentError);
    expect(
      () => OSAccess(maxSleep: const Duration(microseconds: -1)),
      throwsArgumentError,
    );
  });
}

void _constructionCase4() {
  test('file list copied, new files visible, environment alias rule', () async {
    final files = <AbstractFile>[];
    final empty = <String, String>{};
    final fs = OSAccess(files: files, environ: empty);
    files.add(MemoryFile('/unseeded', ''));
    empty['K'] = 'invisible';
    expect(fs.files, isEmpty);
    expect(fs.environ, isEmpty);
    await call(fs, 'Path.write_text', '/created', const MontyString('new'));
    expect(fs.files.singleOrNull?.path, '/created');
    final env = {'K': 'old'};
    final aliased = OSAccess(environ: env);
    env['K'] = 'new';
    expect(aliased.environ, same(env));
    expect(
      await aliased('os.getenv', [const MontyString('K')], {}),
      const MontyString('new'),
    );
  });
}

void _constructionCase5() {
  test('exposed file list remains mutable', () {
    final original = MemoryFile('/original', 'original');
    final replacement = MemoryFile('/replacement', 'replacement');
    final fs = OSAccess(files: [original]);
    fs.files[0] = replacement;
    expect(fs.files, [same(replacement)]);
  });

  test('exposed environment map remains mutable', () async {
    final fs = OSAccess(environ: {'KEY': 'before'});
    fs.environ['KEY'] = 'after';
    expect(
      await fs('os.getenv', [const MontyString('KEY')], {}),
      const MontyString('after'),
    );
  });
}

void _reads() {
  _readsCase0();
  _readsCase1();
  _readsCase2();
  _readsCase3();
}

void _readsCase0() {
  for (final op in [
    'Path.exists',
    'Path.is_file',
    'Path.is_dir',
    'Path.is_symlink',
  ]) {
    test('$op whole namespace missing predicate', () async {
      expect(await call(OSAccess(), op, '/outside'), const MontyBool(false));
    });
  }
}

void _readsCase1() {
  test('reads text bytes and stat observes mutable permissions', () async {
    final file = MemoryFile('/f', 'é');
    final fs = OSAccess(files: [file]);
    file.permissions = 384;
    expect(
      await call(fs, 'Path.read_bytes', '/f'),
      const MontyBytes([195, 169]),
    );
    expect(await call(fs, 'Path.read_text', '/f'), const MontyString('é'));
    final stat = await call(fs, 'Path.stat', '/f') as MontyNamedTuple;
    expect(stat.values.firstOrNull, const MontyInt(33152));
    expect(stat.values.elementAtOrNull(6), const MontyInt(2));
    final modified = stat.values.elementAtOrNull(8);
    if (modified is! MontyFloat) {
      fail('stat mtime must be a MontyFloat');
    }
    final reference = DateTime.now();
    final lower = reference.subtract(const Duration(hours: 1));
    final upper = reference.add(const Duration(hours: 1));
    expect(
      modified.value,
      inInclusiveRange(
        lower.microsecondsSinceEpoch / Duration.microsecondsPerSecond,
        upper.microsecondsSinceEpoch / Duration.microsecondsPerSecond,
      ),
    );
  });
}

void _readsCase2() {
  test('P09 invalid UTF8 is ValueError', () async {
    final fs = OSAccess(
      files: [
        MemoryFile('/f', Uint8List.fromList([255])),
      ],
    );
    const message =
        "'utf-8' codec can't decode byte 0xff in position 0: "
        'invalid start byte';
    final invalidUtf8 = raises('ValueError', message);
    await expectLater(
      call(fs, 'Path.read_text', '/f'),
      invalidUtf8,
    );
    await expectLater(
      call(fs, 'Path.append_text', '/f', const MontyString('x')),
      invalidUtf8,
    );
  });
}

void _readsCase3() {
  for (final op in ['Path.absolute', 'Path.resolve']) {
    test('P09 $op returns str and preserves dotdot', () async {
      expect(
        await call(OSAccess(), op, 'a/../b'),
        const MontyString('/a/../b'),
      );
    });
  }
}

void _writes() {
  for (final binary in [false, true]) {
    for (final append in [false, true]) {
      for (final originalBytes in [false, true]) {
        test(
          'write binary=$binary append=$append '
          'priorBytes=$originalBytes',
          () async {
            final file = MemoryFile(
              '/f',
              originalBytes ? Uint8List.fromList([65]) : 'A',
            );
            final fs = OSAccess(files: [file]);
            final data = binary
                ? const MontyBytes([255, 0])
                : const MontyString('😀é');
            final op =
                'Path.${append ? 'append' : 'write'}_'
                '${binary ? 'bytes' : 'text'}';
            expect(await call(fs, op, '/f', data), const MontyInt(2));
            final prefix = append ? 'A' : '';
            final expected = binary ? [if (append) 65, 255, 0] : '$prefix😀é';
            expect(file.content, expected);
            expect(file.content, binary ? isA<Uint8List>() : isA<String>());
          },
        );
      }
    }
  }
  test(
    'new append and write require parent, preserve caller file reference',
    () async {
      final fs = OSAccess();
      await expectLater(
        call(fs, 'Path.write_text', '/d/f', const MontyString('x')),
        raises(
          'FileNotFoundError',
          "[Errno 2] No such file or directory: '/d/f'",
        ),
      );
      await call(fs, 'Path.append_text', '/f', const MontyString('x'));
      final file = fs.files.singleOrNull;
      await call(fs, 'Path.write_bytes', '/f', const MontyBytes([0]));
      expect(file?.readContent(), [0]);
      expect(fs.files.singleOrNull, same(file));
    },
  );
}

void _open() {
  _openCase0();
  _openCase1();
  _openCase2();
}

void _openCase0() {
  for (final mode in [
    'r',
    'rt',
    'rb',
    'br',
    'w',
    'wt',
    'wb',
    'bw',
    'a',
    'at',
    'ab',
    'ba',
  ]) {
    test('open $mode canonical mode and content kind', () async {
      final file = MemoryFile('/f', 'old');
      final fs = OSAccess(files: [file]);
      final modeValue = MontyString(mode);
      final binary = mode.contains('b');
      final handle = await call(fs, 'open', '/f', modeValue) as MontyFileHandle;
      final action = mode.replaceAll('b', '').replaceAll('t', '');
      expect(handle.mode, '$action${binary ? 'b' : ''}');
      final emptyContent = binary ? isEmpty : '';
      expect(file.content, action == 'w' ? emptyContent : 'old');
      if (action != 'r') {
        await call(fs, 'open', '/new', modeValue);
        expect(
          fs.files.lastOrNull?.readContent(),
          binary ? isA<Uint8List>() : isA<String>(),
        );
      }
    });
  }
}

void _openCase1() {
  for (final entry in {
    'r+': "update modes ('+') are not yet supported",
    'x': 'exclusive creation mode is not supported',
    'rw': 'must have exactly one of create/read/write/append mode',
  }.entries) {
    test('P09 invalid open ${entry.key} has no side effects', () async {
      final file = MemoryFile('/f', 'old');
      final fs = OSAccess(files: [file]);
      final mode = MontyString(entry.key);
      final invalidMode = raises('ValueError', entry.value);
      await expectLater(
        call(fs, 'open', '/f', mode),
        invalidMode,
      );
      expect(file.content, 'old');
      await expectLater(
        call(fs, 'open', '/new', mode),
        invalidMode,
      );
      expect(fs.files.length, 1);
    });
  }
}

void _openCase2() {
  test('open default and file handle reads', () async {
    final fs = OSAccess(files: [MemoryFile('/f', 'hello')]);
    final handle = await call(fs, 'open', '/f');
    expect((handle as MontyFileHandle).mode, 'r');
    expect(
      await fs('Path.read_text', [handle], {}),
      const MontyString('hello'),
    );
  });
}

void _directories() {
  _directoriesCase0();
  _directoriesCase1();
  _directoriesCase2();
}

void _directoriesCase0() {
  for (final op in [
    'Path.read_text',
    'Path.read_bytes',
    'Path.write_text',
    'Path.append_text',
    'Path.write_bytes',
    'Path.append_bytes',
    'Path.unlink',
    'open',
  ]) {
    test('$op rejects directory', () async {
      final payload = op.endsWith('bytes')
          ? const MontyBytes([1])
          : const MontyString('x');
      await expectLater(
        call(
          OSAccess(),
          op,
          '/',
          op == 'open' ? const MontyString('a') : payload,
        ),
        raises('IsADirectoryError', "[Errno 21] Is a directory: '/'"),
      );
    });
  }
}

void _directoriesCase1() {
  test('mkdir parents and iterdir use path values; deletion flags', () async {
    final fs = OSAccess();
    await fs(
      'Path.mkdir',
      [MontyPath('/a/b')],
      {'parents': const MontyBool(true)},
    );
    expect(
      await call(fs, 'Path.iterdir', '/a'),
      MontyList([MontyPath('/a/b')]),
    );
    expect(await call(fs, 'Path.iterdir', '/a/b'), const MontyList([]));
    await call(fs, 'Path.write_text', '/a/b/f', const MontyString('x'));
    final file = fs.files.singleOrNull;
    await call(fs, 'Path.unlink', '/a/b/f');
    expect(file?.deleted, true);
    await call(fs, 'Path.rmdir', '/a/b');
    expect(await call(fs, 'Path.exists', '/a/b'), const MontyBool(false));
  });
}

void _directoriesCase2() {
  test('directory errors use upstream text', () async {
    final fs = OSAccess(files: [MemoryFile('/a/f', '')]);
    await expectLater(
      call(fs, 'Path.mkdir', '/q/r'),
      raises(
        'FileNotFoundError',
        "[Errno 2] No such file or directory: '/q/r'",
      ),
    );
    await expectLater(
      call(fs, 'Path.mkdir', '/a'),
      raises('FileExistsError', "[Errno 17] File exists: '/a'"),
    );
    await expectLater(
      call(fs, 'Path.rmdir', '/a'),
      raises('OSError', "[Errno 39] Directory not empty: '/a'"),
    );
    await expectLater(
      call(fs, 'Path.iterdir', '/a/f'),
      raises('NotADirectoryError', "[Errno 20] Not a directory: '/a/f'"),
    );
    await expectLater(
      () => fs(
        'Path.mkdir',
        [MontyPath('/a/f/b/c')],
        {'parents': const MontyBool(true)},
      ),
      raises('NotADirectoryError', "[Errno 20] Not a directory: '/a/f/b/c'"),
    );
    expect(
      await fs(
        'Path.mkdir',
        [MontyPath('/a')],
        {'exist_ok': const MontyBool(true)},
      ),
      const MontyNone(),
    );
  });
}

void _renames() {
  test('P09 missing rename names both paths', () async {
    await expectLater(
      call(OSAccess(), 'Path.rename', '/missing', MontyPath('/dest')),
      raises(
        'FileNotFoundError',
        "[Errno 2] No such file or directory: '/missing' -> '/dest'",
      ),
    );
  });
  test('P09 file rename keeps stale path and unlink raises KeyError', () async {
    final file = MemoryFile('/a', 'A');
    final overwritten = MemoryFile('/b', 'B');
    final fs = OSAccess(files: [file, overwritten]);
    await call(fs, 'Path.rename', '/a', MontyPath('/b'));
    expect(overwritten.deleted, true);
    expect(file.path, '/a');
    expect(await call(fs, 'Path.read_text', '/b'), const MontyString('A'));
    await expectLater(call(fs, 'Path.unlink', '/b'), raises('KeyError', "'a'"));
    expect(file.deleted, true);
  });
  test('P10 directory rename replaces prefix of stale path', () async {
    final file = MemoryFile('/d/f', 'x');
    final fs = OSAccess(files: [file]);
    await call(fs, 'Path.rename', '/d/f', MontyPath('/d/g'));
    await call(fs, 'Path.rename', '/d', MontyPath('/e'));
    expect(file.path, '/e/f');
    expect(await call(fs, 'Path.read_text', '/e/g'), const MontyString('x'));
  });
}

void _defaults() {
  _defaultsCase0();
  _defaultsCase1();
  _defaultsCase2();
  _defaultsCase3();
}

void _defaultsCase0() {
  test('environment and unknown dispatch', () async {
    final fs = OSAccess(environ: {'K': 'v'});
    expect(
      await fs('os.getenv', [
        const MontyString('missing'),
        const MontyString('default'),
      ], {}),
      const MontyString('default'),
    );
    expect(
      await fs('os.getenv', [const MontyString('missing')], {}),
      const MontyNone(),
    );
    expect(
      await fs('os.environ', [], {}),
      const MontyDict([(MontyString('K'), MontyString('v'))]),
    );
    expect(
      () => fs('unknown', [], {}),
      throwsA(isA<OsCallNotHandledException>()),
    );
    expect(fs.toString(), "OSAccess(files=[], environ={'K': 'v'})");
  });
}

void _defaultsCase1() {
  test('clock entropy and asynchronous capped sleeps', () async {
    final fs = OSAccess(maxUrandomBytes: 2, maxSleep: Duration.zero);
    expect(await fs('date.today', [], {}), isA<MontyDate>());
    expect(await fs('datetime.now', [], {}), isA<MontyDateTime>());
    expect(await fs('time.time', [], {}), isA<MontyFloat>());
    expect(
      (await fs('os.urandom', [const MontyInt(2)], {}) as MontyBytes)
          .value
          .length,
      2,
    );
    await expectLater(
      Future.sync(() => fs('os.urandom', [const MontyInt(3)], {})),
      raises('MemoryError', 'os.urandom() size exceeds max_urandom_bytes (2)'),
    );
    for (final name in [
      'time.sleep',
      'asyncio.sleep',
      'system.sleep',
      'system.async_sleep',
    ]) {
      final result = fs(name, [const MontyInt(100)], {});
      expect(result, isA<Future<MontyValue>>());
      expect(await result, const MontyNone());
    }
  });
}

void _defaultsCase2() {
  test('clock defaults use the host calendar and epoch', () async {
    final fs = OSAccess();
    final today = await fs('date.today', [], {}) as MontyDate;
    final now = await fs('datetime.now', [], {}) as MontyDateTime;
    final epoch = await fs('time.time', [], {});
    final reference = DateTime.now();
    final lower = reference.subtract(const Duration(hours: 1));
    final upper = reference.add(const Duration(hours: 1));
    final calendarBoundary = anyOf(
      (lower.year, lower.month, lower.day),
      (upper.year, upper.month, upper.day),
    );
    final returnedDate = (today.year, today.month, today.day);
    expect(returnedDate, calendarBoundary);
    expect((now.year, now.month, now.day), calendarBoundary);
    expect(now.offsetSeconds, isNull);
    expect(now.timezoneName, isNull);
    expect(epoch, isA<MontyFloat>());
    expect(
      (epoch as MontyFloat).value,
      inInclusiveRange(
        lower.microsecondsSinceEpoch / Duration.microsecondsPerSecond,
        upper.microsecondsSinceEpoch / Duration.microsecondsPerSecond,
      ),
    );
  });
}

void _defaultsCase3() {
  test('sleep caps a configured wait', () async {
    final capped = OSAccess(maxSleep: const Duration(milliseconds: 50));
    final waits = <Duration>[];
    await _withRecordedSleeps(
      waits,
      () => capped('time.sleep', [const MontyInt(1)], {}),
    );
    expect(waits, [const Duration(milliseconds: 50)]);
  });

  test('sleep preserves an uncapped wait', () async {
    final uncapped = OSAccess(maxSleep: null);
    final waits = <Duration>[];
    await _withRecordedSleeps(
      waits,
      () => uncapped('time.sleep', [const MontyInt(11)], {}),
    );
    expect(waits, [const Duration(seconds: 11)]);
  });
}

Future<MontyValue> _withRecordedSleeps(
  List<Duration> waits,
  FutureOr<MontyValue> Function() body,
) => runZoned(
  () async => body(),
  zoneSpecification: ZoneSpecification(
    createTimer: (self, parent, zone, duration, callback) {
      waits.add(duration);

      return parent.createTimer(zone, Duration.zero, callback);
    },
  ),
);

void _customFiles() {
  test(
    'external implementation uses only AbstractFile',
    () async {
      final file = CustomFile();
      final fs = OSAccess(files: [file]);
      expect(file.path, '/f');
      expect(
        await call(fs, 'Path.read_text', '/f'),
        const MontyString('custom'),
      );
      expect(
        (await call(fs, 'Path.stat', '/f') as MontyNamedTuple)
            .values
            .firstOrNull,
        const MontyInt(33152),
      );
      await call(fs, 'Path.write_text', '/f', const MontyString('written'));
      expect(file.readContent(), 'written');
      await call(fs, 'Path.unlink', '/f');
      expect(file.deleted, true);
    },
  );
}

void _seedReplacement() {
  test('later seed replaces a parent directory in list order', () async {
    final fs = OSAccess(
      files: [
        MemoryFile('/a/b', 'child'),
        MemoryFile('/a', 'replacement'),
      ],
    );
    expect(
      await call(fs, 'Path.read_text', '/a'),
      const MontyString('replacement'),
    );
    expect(await call(fs, 'Path.exists', '/a/b'), const MontyBool(false));
  });
}

void _unpairedSurrogates() {
  const lone = '\ud800x';
  final encodeError = raises(
    'UnicodeEncodeError',
    r"'utf-8' codec can't encode character '\ud800' in position 0: "
        'surrogates not allowed',
  );
  OSAccess seeded() => OSAccess(files: [MemoryFile('/f', lone)]);

  for (final (op, value) in <(String, MontyValue?)>[
    ('Path.read_bytes', null),
    ('Path.append_bytes', const MontyBytes([122])),
    ('Path.stat', null),
  ]) {
    test('$op of text with an unpaired surrogate is a UnicodeEncodeError', () {
      expect(call(seeded(), op, '/f', value), encodeError);
    });
  }

  test('text with an unpaired surrogate reads as text', () async {
    expect(
      await call(seeded(), 'Path.read_text', '/f'),
      const MontyString(lone),
    );
  });

  test('text with an unpaired surrogate appends as text', () async {
    final fs = seeded();
    expect(
      await call(fs, 'Path.append_text', '/f', const MontyString('q')),
      const MontyInt(1),
    );
    expect(
      await call(fs, 'Path.read_text', '/f'),
      const MontyString('${lone}q'),
    );
  });

  test('a run of surrogates is reported as a range', () {
    // A valid pair is one code point, so the run starts after it.
    final run = String.fromCharCodes([0x61, 0x10000, 0xd800, 0xd800]);
    final fs = OSAccess(files: [MemoryFile('/f', run)]);
    expect(
      call(fs, 'Path.read_bytes', '/f'),
      raises(
        'UnicodeEncodeError',
        "'utf-8' codec can't encode characters in position 2-3: "
            'surrogates not allowed',
      ),
    );
  });
}

// Pinned to os_access.py's dispatch: probes in 1.1.0.
void _upstreamArguments() {
  const noPath =
      'argument should be a str or an os.PathLike object where __fspath__ '
      "returns a str, not 'MontyFileHandle'";
  OSAccess seeded() => OSAccess(
    files: [
      MemoryFile('/t', 'héllo'),
      MemoryFile('/b', Uint8List.fromList([97, 98])),
    ],
  );
  final handle = MontyFileHandle('/t', 'r');
  final notPath = raises('TypeError', noPath);

  group('a file handle', () {
    for (final (op, value) in <(String, MontyValue?)>[
      ('Path.read_text', null),
      ('Path.read_bytes', null),
      ('Path.write_text', const MontyString('x')),
      ('Path.write_bytes', const MontyBytes([120])),
      ('Path.append_text', const MontyString('x')),
      ('Path.append_bytes', const MontyBytes([120])),
    ]) {
      test('is the path of $op', () async {
        final result = await seeded()(op, [handle, ?value], {});
        expect(result, isNot(isA<MontyNone>()));
      });
    }

    for (final op in [
      'Path.exists',
      'Path.is_file',
      'Path.is_dir',
      'Path.stat',
      'Path.unlink',
      'Path.rmdir',
      'Path.iterdir',
      'Path.resolve',
      'Path.absolute',
      'Path.mkdir',
    ]) {
      test('is not a path for $op', () {
        expect(
          Future.sync(() => seeded()(op, [handle], {})),
          notPath,
        );
      });
    }

    test('is not a path for open or rename', () {
      final fs = seeded();
      expect(
        Future.sync(() => fs('open', [handle, const MontyString('r')], {})),
        notPath,
      );
      expect(
        Future.sync(
          () => fs('Path.rename', [handle, MontyPath('/z')], {}),
        ),
        notPath,
      );
    });

    test('is not looked at by Path.is_symlink', () async {
      expect(
        await seeded()('Path.is_symlink', [handle], {}),
        const MontyBool(false),
      );
    });
  });

  group('Path.mkdir keywords', () {
    test('more than two are an AssertionError', () {
      expect(
        Future.sync(
          () => OSAccess()(
            'Path.mkdir',
            [MontyPath('/d')],
            {
              'parents': const MontyBool(true),
              'exist_ok': const MontyBool(true),
              'x': const MontyInt(1),
            },
          ),
        ),
        raises(
          'AssertionError',
          "Unexpected keyword arguments: {'parents': True, 'exist_ok': True, "
              "'x': 1}",
        ),
      );
    });

    final cycleItems = <MontyValue>[];
    final cycle = MontyList(cycleItems);
    cycleItems.add(cycle);
    final tupleItems = <MontyValue>[];
    final listOfTuple = MontyList(tupleItems);
    final tupleCycle = MontyTuple([listOfTuple]);
    tupleItems.add(tupleCycle);
    final reprs = <(MontyValue, String)>[
      // Kinds without a Python repr here show their Dart type.
      (const MontyDate(year: 2026, month: 1, day: 2), '<MontyDate>'),
      (const MontyDict([(MontyString('a'), MontyInt(1))]), "{'a': 1}"),
      (const MontySet([MontyInt(1)]), '{1}'),
      (const MontySet([]), 'set()'),
      (const MontyFrozenSet([MontyInt(1)]), 'frozenset({1})'),
      (const MontyFrozenSet([]), 'frozenset()'),
      (const MontyBytes([0, 255, 92]), r"b'\x00\xff\\'"),
      (tupleCycle, '([(...)],)'),
      (const MontyComplex(1, 2), '(1+2j)'),
      (const MontyComplex(0, 2), '2j'),
      (const MontyComplex(1, -0.5), '(1-0.5j)'),
      (MontyPath('/x'), "PurePosixPath('/x')"),
      (const MontyBytes([104, 105, 10, 39]), 'b"hi\\n\'"'),
      (const MontyDict([]), '{}'),
      (const MontyFloat(1e-7), '1e-07'),
      (const MontyFloat(10000000000000000), '1e+16'),
      (const MontyFloat(-1.5e-10), '-1.5e-10'),
      (const MontyFloat(2.5), '2.5'),
      (const MontyTuple([MontyString('a')]), "('a',)"),
      (const MontyString("it's"), '"it\'s"'),
      (const MontyNone(), 'None'),
      (
        const MontyList([
          MontyInt(1),
          MontyTuple([MontyInt(2), MontyInt(3)]),
          MontyDict([(MontyString('k'), MontyFloat(1))]),
        ]),
        "[1, (2, 3), {'k': 1.0}]",
      ),
      (cycle, '[[...]]'),
    ];
    for (final (value, text) in reprs) {
      test('names an extra keyword ${value.runtimeType} as Python does', () {
        expect(
          Future.sync(
            () => OSAccess()(
              'Path.mkdir',
              [MontyPath('/d')],
              {
                'parents': const MontyBool(true),
                'exist_ok': const MontyBool(false),
                'x': value,
              },
            ),
          ),
          raises(
            'AssertionError',
            "Unexpected keyword arguments: {'parents': True, "
                "'exist_ok': False, 'x': $text}",
          ),
        );
      });
    }

    test('are checked before the path', () {
      expect(
        Future.sync(
          () => OSAccess()(
            'Path.mkdir',
            [handle],
            {
              'a': const MontyInt(1),
              'b': const MontyInt(2),
              'c': const MontyInt(3),
            },
          ),
        ),
        raises(
          'AssertionError',
          "Unexpected keyword arguments: {'a': 1, 'b': 2, 'c': 3}",
        ),
      );
    });

    test('two unknown keywords are ignored', () async {
      final result = await OSAccess()(
        'Path.mkdir',
        [MontyPath('/d')],
        {'x': const MontyInt(1), 'y': const MontyInt(2)},
      );
      expect(result, const MontyNone());
    });

    final truthy = <MontyValue>[
      const MontyInt(1),
      const MontyString('x'),
      const MontyList([MontyInt(1)]),
      const MontyFloat(2.5),
    ];
    final falsy = <MontyValue>[
      const MontyInt(0),
      const MontyString(''),
      const MontyList([]),
      const MontyNone(),
    ];

    // Python truthiness of the other kinds a keyword can hold.
    final truthyKinds = <MontyValue>[
      MontyBigInt(BigInt.two),
      const MontyBool(true),
      const MontyComplex(0, 1),
      const MontyBytes([0]),
      const MontyTuple([MontyNone()]),
      const MontyDict([(MontyInt(1), MontyInt(2))]),
      const MontySet([MontyInt(1)]),
      const MontyFrozenSet([MontyInt(1)]),
      const MontyNamedTuple(
        typeName: 'T',
        fieldNames: ['a'],
        values: [MontyInt(0)],
      ),
      const MontyTimeDelta(days: 0, seconds: 0, microseconds: 1),
      MontyPath('/x'),
    ];
    final falsyKinds = <MontyValue>[
      MontyBigInt(BigInt.zero),
      const MontyBool(false),
      const MontyFloat(0),
      const MontyComplex(0, 0),
      const MontyBytes([]),
      const MontyTuple([]),
      const MontyDict([]),
      const MontySet([]),
      const MontyFrozenSet([]),
      const MontyNamedTuple(typeName: 'T', fieldNames: [], values: []),
      const MontyTimeDelta(days: 0, seconds: 0),
    ];
    for (final value in truthyKinds) {
      test('exist_ok=$value is true', () async {
        final fs = OSAccess();
        await fs('Path.mkdir', [MontyPath('/d')], {});
        final again = await fs(
          'Path.mkdir',
          [MontyPath('/d')],
          {
            'exist_ok': value,
          },
        );
        expect(again, const MontyNone());
      });
    }

    for (final value in falsyKinds) {
      test('exist_ok=$value is false', () async {
        final fs = OSAccess();
        await fs('Path.mkdir', [MontyPath('/d')], {});
        await expectLater(
          Future.sync(
            () => fs('Path.mkdir', [MontyPath('/d')], {'exist_ok': value}),
          ),
          raises('FileExistsError', "[Errno 17] File exists: '/d'"),
        );
      });
    }

    for (final value in truthy) {
      test('exist_ok=$value is true and parents=$value is true', () async {
        final fs = OSAccess();
        await fs('Path.mkdir', [MontyPath('/d')], {});
        final again = await fs(
          'Path.mkdir',
          [MontyPath('/d')],
          {
            'exist_ok': value,
          },
        );
        expect(again, const MontyNone());
        final nested = await fs(
          'Path.mkdir',
          [MontyPath('/p/q')],
          {
            'parents': value,
          },
        );
        expect(nested, const MontyNone());
      });
    }

    for (final value in falsy) {
      test('exist_ok=$value is false and parents=$value is false', () async {
        final fs = OSAccess();
        await fs('Path.mkdir', [MontyPath('/d')], {});
        await expectLater(
          Future.sync(
            () => fs('Path.mkdir', [MontyPath('/d')], {'exist_ok': value}),
          ),
          raises('FileExistsError', "[Errno 17] File exists: '/d'"),
        );
        await expectLater(
          Future.sync(
            () => fs('Path.mkdir', [MontyPath('/p/q')], {'parents': value}),
          ),
          raises(
            'FileNotFoundError',
            "[Errno 2] No such file or directory: '/p/q'",
          ),
        );
      });
    }
  });

  group('write and append payloads follow their type, not the operation', () {
    for (final (op, text) in [
      ('Path.write_text', 'a str'),
      ('Path.write_bytes', 'bytes'),
      ('Path.append_text', 'a str'),
      ('Path.append_bytes', 'bytes'),
    ]) {
      test('$op refuses a payload that is neither text nor bytes', () {
        expect(
          Future.sync(
            () => OSAccess()(op, [MontyPath('/n'), const MontyInt(1)], {}),
          ),
          raises('TypeError', 'expected $text'),
        );
      });
    }

    test('Path.write_text stores bytes and counts them', () async {
      final fs = OSAccess();
      expect(
        await fs('Path.write_text', [
          MontyPath('/n'),
          const MontyBytes([97, 98, 99]),
        ], {}),
        const MontyInt(3),
      );
      expect(
        await fs('Path.read_text', [MontyPath('/n')], {}),
        const MontyString('abc'),
      );
    });

    test('Path.write_bytes stores text and counts its characters', () async {
      final fs = OSAccess();
      expect(
        await fs('Path.write_bytes', [
          MontyPath('/n'),
          const MontyString('é€'),
        ], {}),
        const MontyInt(2),
      );
      expect(
        await fs('Path.read_bytes', [MontyPath('/n')], {}),
        const MontyBytes([195, 169, 226, 130, 172]),
      );
    });

    test('Path.append_bytes of text appends as text', () async {
      final fs = seeded();
      expect(
        await fs('Path.append_bytes', [
          MontyPath('/b'),
          const MontyString('zz'),
        ], {}),
        const MontyInt(2),
      );
      expect(
        await fs('Path.read_text', [MontyPath('/b')], {}),
        const MontyString('abzz'),
      );
    });

    test('Path.append_text of bytes appends as bytes', () async {
      final fs = seeded();
      expect(
        await fs('Path.append_text', [
          MontyPath('/t'),
          const MontyBytes([122, 122]),
        ], {}),
        const MontyInt(2),
      );
      expect(
        await fs('Path.read_bytes', [MontyPath('/t')], {}),
        const MontyBytes([104, 195, 169, 108, 108, 111, 122, 122]),
      );
    });
  });
}

// Upstream's `Path.scan` — the one OS call behind `os.scandir`, `os.walk`,
// `Path.walk` and `Path.glob` — as this namespace must answer it.
//
// WHERE THE EXPECTED VALUES COME FROM: upstream's scan contract at monty
// v1.2.0 (`crates/monty-python/python/pydantic_monty/os_access.py:552-609`
// and `crates/monty-types/src/scan.rs`), the host's own tests
// (`crates/monty-python/tests/test_os_access.py:1183-1207`) and the arguments
// the worker sends (`crates/monty-python/tests/test_os_access_raw.py:726`).
// The reply is a sequence of (path, is_dir, is_file, is_symlink) entries
// whose paths are relative to the root, '' being the root itself. A root that
// is not there is a FileNotFoundError naming it, spelled as the root was
// spelled; the empty root is the ValueError an empty path raises. Only
// `max_depth` and `follow_symlinks` shape the reply: a pattern is a hint,
// so the reply is the tree and the sandbox runs the selector over it.
//
// The namespace has no scan handler yet, so the call is declined. The stub
// below answers a declined call with a wrong value rather than letting the
// decline escape, so this test fails on its first assertion instead of on an
// exception; once the handler lands, the same call reaches it.
void _scan() {
  test(
    'OSAccess scans current trees with depth and resource bounds',
    () async {
      /// The five keywords upstream's `ScanArgs` takes, all of them on every
      /// call: a handler that reads them all must find them all.
      Map<String, MontyValue> keywords({
        MontyValue maxDepth = const MontyNone(),
        bool followSymlinks = false,
        MontyValue pattern = const MontyNone(),
        MontyValue caseSensitive = const MontyNone(),
        bool recurseSymlinks = false,
      }) => {
        'max_depth': maxDepth,
        'follow_symlinks': MontyBool(followSymlinks),
        'pattern': pattern,
        'case_sensitive': caseSensitive,
        'recurse_symlinks': MontyBool(recurseSymlinks),
      };

      /// The scan call the worker makes: the root, and the five keywords
      /// upstream's `ScanArgs` takes as kwargs.
      ///
      /// The stub: a call this namespace has no handler for is declined, and
      /// a declined call would fail this test with an exception rather than
      /// with an assertion. So the decline is answered with a wrong value —
      /// an empty reply, where the tree is not empty.
      Future<MontyValue> scan(
        OSAccess namespace,
        MontyValue root, {
        Map<String, MontyValue> kwargs = const {},
      }) async {
        try {
          return await namespace(
            'Path.scan',
            [root],
            {
              ...keywords(),
              ...kwargs,
            },
          );
        } on OsCallNotHandledException {
          return const MontyList([]);
        }
      }

      /// One of an entry's flags: a boolean, strictly.
      bool boolFlag(MontyValue flagValue, String name) => switch (flagValue) {
        MontyBool(:final value) => value,
        final other => fail(
          'the $name of a scan entry is a boolean, got $other',
        ),
      };

      /// One scan entry, read as upstream encodes it: the path relative to
      /// the root, and what the entry is.
      (String, bool, bool, bool) entry(List<MontyValue> parts) =>
          switch (parts) {
            [final path, final isDir, final isFile, final isSymlink] => (
              switch (path) {
                MontyString(:final value) => value,
                final other => fail(
                  'the path of a scan entry is a string, got $other',
                ),
              },
              boolFlag(isDir, 'is_dir'),
              boolFlag(isFile, 'is_file'),
              boolFlag(isSymlink, 'is_symlink'),
            ),
            final other => fail(
              'a scan entry is (path, is_dir, is_file, is_symlink), got $other',
            ),
          };

      /// The entries of a tree reply, sorted by path: the order they come in
      /// is not part of the contract, the entries are.
      List<(String, bool, bool, bool)> entries(MontyValue reply) {
        final items = switch (reply) {
          MontyList(:final items) || MontySet(:final items) => items,
          final other => fail(
            'a scan reply is a sequence of entries, got $other',
          ),
        };

        return [
          for (final item in items)
            switch (item) {
              MontyTuple(:final items) ||
              MontyList(:final items) => entry(items),
              MontyNamedTuple(:final values) => entry(values),
              final other => fail('a scan entry is a tuple, got $other'),
            },
        ]..sort((left, right) => left.$1.compareTo(right.$1));
      }

      /// The entries a scan of [root] reports.
      Future<List<(String, bool, bool, bool)>> scanned(
        OSAccess namespace,
        String root, {
        Map<String, MontyValue> kwargs = const {},
      }) async => entries(
        await scan(namespace, MontyPath(root), kwargs: kwargs),
      );

      /// The entries of the tree at [root], asserted to be [expected].
      Future<void> expectTree(
        OSAccess namespace,
        String root,
        List<(String, bool, bool, bool)> expected,
        String reason,
      ) async => expect(
        await scanned(namespace, root),
        equals(expected),
        reason: reason,
      );

      /// The deepest entry of a reply, counted in levels below the root.
      int deepest(List<(String, bool, bool, bool)> found) => found.fold(
        0,
        (deepestSoFar, entry) {
          final levels = entry.$1.isEmpty ? 0 : entry.$1.split('/').length;

          return levels > deepestSoFar ? levels : deepestSoFar;
        },
      );

      // The keywords of a scan one level deep.
      final oneLevel = keywords(maxDepth: const MontyInt(1));

      // The tree the scans below read: two files, an empty directory, and a
      // package with a file and a subdirectory of its own.
      final fs = OSAccess(
        files: [
          MemoryFile('/test/a.txt', 'a'),
          MemoryFile('/test/b.py', 'b'),
          MemoryFile('/test/pkg/c.py', 'c'),
          MemoryFile('/test/pkg/sub/d.py', 'd'),
        ],
      );
      await fs('Path.mkdir', [MontyPath('/test/empty')], {});

      // The root of a directory is the root itself, and every entry below it
      // is named by its path relative to it.
      const rootEntry = ('', true, false, false);
      final children = [
        ('a.txt', false, true, false),
        ('b.py', false, true, false),
        ('empty', true, false, false),
        ('pkg', true, false, false),
      ];
      final grandchildren = [
        ('pkg/c.py', false, true, false),
        ('pkg/sub', true, false, false),
      ];
      final greatGrandchildren = [
        ('pkg/sub/d.py', false, true, false),
      ];
      final wholeTree = [
        rootEntry,
        ...children,
        ...grandchildren,
        ...greatGrandchildren,
      ];

      // The whole tree, when no depth is asked for.
      expect(
        await scanned(fs, '/test'),
        equals(wholeTree),
        reason: 'the entries of the whole tree',
      );

      // A depth is the depth of the deepest entry: 0 is the root alone, 1
      // its children, 2 their children.
      expect(
        await scanned(
          fs,
          '/test',
          kwargs: keywords(maxDepth: const MontyInt(0)),
        ),
        equals([rootEntry]),
        reason: 'the entries at depth 0',
      );
      expect(
        await scanned(
          fs,
          '/test',
          kwargs: oneLevel,
        ),
        equals([rootEntry, ...children]),
        reason: 'the entries at depth 1',
      );
      expect(
        await scanned(
          fs,
          '/test',
          kwargs: keywords(maxDepth: const MontyInt(2)),
        ),
        equals([rootEntry, ...children, ...grandchildren]),
        reason: 'the entries at depth 2',
      );

      // Both values of `follow_symlinks`: the tree holds no link, so both
      // report the same tree.
      for (final follow in [false, true]) {
        expect(
          await scanned(
            fs,
            '/test',
            kwargs: keywords(followSymlinks: follow),
          ),
          equals(wholeTree),
          reason: 'the tree with follow_symlinks=$follow',
        );
      }

      // A pattern is a hint, not a filter: the reply is the tree, and the
      // sandbox runs the selector over it. The flags that go with a pattern
      // change nothing here either.
      expect(
        await scanned(
          fs,
          '/test',
          kwargs: keywords(
            followSymlinks: true,
            pattern: const MontyList([MontyString('*.txt')]),
            caseSensitive: const MontyBool(false),
            recurseSymlinks: true,
          ),
        ),
        equals(wholeTree),
        reason: 'the tree with a glob hint',
      );

      // The root arrives as a path or as a string; both name the same tree.
      expect(
        entries(await scan(fs, const MontyString('/test'))),
        equals(wholeTree),
        reason: 'the tree named by a string',
      );

      // An empty directory is a root of its own, and its tree is the root
      // alone.
      expect(
        await scanned(fs, '/test/empty'),
        equals([rootEntry]),
        reason: 'the entries of an empty directory',
      );

      // A file is described, not listed: the root of the scan is the file
      // itself.
      expect(
        await scanned(fs, '/test/a.txt'),
        equals([('', false, true, false)]),
        reason: 'the entries of a file',
      );

      // A scan reads the tree as it is now: a file written after a scan is
      // in the next one.
      final written = OSAccess(files: [MemoryFile('/test/a.txt', 'a')]);
      await expectTree(
        written,
        '/test',
        [rootEntry, ('a.txt', false, true, false)],
        'the tree before the write',
      );
      await call(
        written,
        'Path.write_text',
        '/test/new.txt',
        const MontyString('n'),
      );
      await expectTree(
        written,
        '/test',
        [
          rootEntry,
          ('a.txt', false, true, false),
          ('new.txt', false, true, false),
        ],
        'the tree after the write',
      );

      // A directory renamed under the same root is the next scan's business
      // too: the root is scanned before and after the rename.
      final renamed = OSAccess(files: [MemoryFile('/test/pkg/f', 'f')]);
      await expectTree(
        renamed,
        '/test',
        [
          rootEntry,
          ('pkg', true, false, false),
          ('pkg/f', false, true, false),
        ],
        'the tree before the rename',
      );
      await call(renamed, 'Path.rename', '/test/pkg', MontyPath('/test/pkg2'));
      await expectTree(
        renamed,
        '/test',
        [
          rootEntry,
          ('pkg2', true, false, false),
          ('pkg2/f', false, true, false),
        ],
        'the tree after the rename',
      );

      // A `..` in a path is a name, not a way up: the namespace keeps it
      // literal, so the directory seeded under it is the one a scan finds.
      final dotted = OSAccess(files: [MemoryFile('/test/../f', 'x')]);
      expect(
        await scanned(dotted, '/test/..'),
        equals([rootEntry, ('f', false, true, false)]),
        reason: 'the entries of a literal dotdot directory',
      );
      expect(
        await scanned(
          dotted,
          '/test',
          kwargs: oneLevel,
        ),
        equals([rootEntry, ('..', true, false, false)]),
        reason: 'the entries of the directory holding the dotdot',
      );

      // A double slash is a root of its own: the tree seeded under it is not
      // the tree under the single slash.
      final doubled = OSAccess(files: [MemoryFile('//double/f', 'x')]);
      expect(
        await scanned(doubled, '//double'),
        equals([rootEntry, ('f', false, true, false)]),
        reason: 'the entries of a double root',
      );
      await expectLater(
        scan(doubled, MontyPath('/double')),
        raises(
          'FileNotFoundError',
          "[Errno 2] No such file or directory: '/double'",
        ),
      );

      // A root that is not there names it as it was spelled: the request
      // keeps its `//`, its `.` and its trailing slash.
      await expectLater(
        scan(fs, const MontyString('/test//./nope/')),
        raises(
          'FileNotFoundError',
          "[Errno 2] No such file or directory: '/test//./nope/'",
        ),
      );

      // The empty root is the ValueError an empty path raises.
      await expectLater(
        scan(fs, const MontyString('')),
        raises(
          'ValueError',
          'not enough values to unpack (expected at least 1, got 0)',
        ),
      );

      // Following links with no depth stops 64 levels down, as upstream's
      // does, so that a link cycle ends. This tree holds no link, so only
      // the depth tells the two values of `follow_symlinks` apart.
      final deep = OSAccess(
        files: [
          MemoryFile(
            '/deep/${List.generate(70, (index) => 'd$index').join('/')}/f',
            'x',
          ),
        ],
      );
      final followed = await scanned(
        deep,
        '/deep',
        kwargs: keywords(followSymlinks: true),
      );
      expect(followed.length, 65, reason: 'the entries of a followed scan');
      expect(
        deepest(followed),
        64,
        reason: 'the deepest entry of a followed scan',
      );
      final notFollowed = await scanned(
        deep,
        '/deep',
        // The default does not follow links.
      );
      expect(
        notFollowed.length,
        72,
        reason: 'the entries of a scan that does not follow',
      );
      expect(
        deepest(notFollowed),
        71,
        reason: 'the deepest entry of a scan that does not follow',
      );

      // A scan that would return more than a hundred thousand entries stops
      // with a RuntimeError, as upstream's does.
      final many = OSAccess(
        files: [
          for (var index = 0; index < 100001; index++)
            MemoryFile('/test/f$index', ''),
        ],
      );
      await expectLater(
        scan(many, MontyPath('/test')),
        raises('RuntimeError', 'directory scan exceeded 100000 entries'),
      );

      // A scan that would estimate more than a hundred million bytes of path
      // data stops with a RuntimeError. The tree is deep and its names are
      // long, so the estimate passes the limit well before the last level.
      final wide = OSAccess(
        files: [
          MemoryFile(
            '/deep/${List.generate(500, (index) => 'n' * 1000).join('/')}/f',
            'x',
          ),
        ],
      );
      await expectLater(
        scan(wide, MontyPath('/deep')),
        raises(
          'RuntimeError',
          'directory scan exceeded 100000000 bytes of path data',
        ),
      );
    },
  );

  _scanRootPathBytes();
}

/// The root of a scan is estimated before anything below it is walked.
///
/// So a root path that is long enough on its own stops the scan, even
/// though the tree below it holds a single empty file. The file has to be
/// there: the lookup of the root comes before the estimate.
void _scanRootPathBytes() {
  test(
    'a scan whose root path alone exceeds the path data limit stops',
    () async {
      final file = MemoryFile('/${'a' * 25000000}', '');
      final fs = OSAccess(files: [file]);
      await expectLater(
        call(fs, 'Path.scan', file.path),
        raises(
          'RuntimeError',
          'directory scan exceeded 100000000 bytes of path data',
        ),
      );
    },
  );
}

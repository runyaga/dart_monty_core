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
  _writes();
  _open();
  _directories();
  _renames();
  _defaults();
}

void _construction() {
  _constructionCase0();
  _constructionCase1();
  _constructionCase2();
  _constructionCase3();
  _constructionCase4();
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
    expect(
      (stat.values.elementAtOrNull(8) as MontyFloat?)?.value,
      greaterThan(0),
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

void _customFiles() {
  test(
    'REQ-VfsFile-5,7,8 external implementation uses only AbstractFile',
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

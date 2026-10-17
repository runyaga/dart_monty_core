// The contract explicitly permits implicit call tear-offs at os:.
// ignore_for_file: implicit_call_tearoffs
// Shared VM/web tests exercise the public callable object through feedRun.
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:dart_monty_core/unsafe_callback_file.dart';
import 'package:test/test.dart';

typedef _Start = Future<Monty> Function(PoolOptions);

void memoryFsSessionTests(
  String label,
  Future<Monty> Function(PoolOptions) start,
) {
  _memoryFiles(label, start);
  _callbackFailure(label, start);
  _customStat(label, start);
}

Future<MontySession> _session(_Start start) async {
  final pool = await start(const PoolOptions(maxProcesses: 1));
  addTearDown(pool.close);
  final session = await pool.checkout();
  addTearDown(session.close);

  return session;
}

void _memoryFiles(String label, _Start start) {
  test('OSAccess feedRun preserves host files ($label)', () async {
    final session = await _session(start);
    final file = MemoryFile('f', 'hello');
    final fs = OSAccess(files: [file]);
    file.permissions = 384;
    expect(
      await session.feedRun('''
from pathlib import Path
p = Path('/f')
(p.read_text(), p.stat().st_mode, p.write_text('😀'), p.read_bytes())
''', os: fs),
      const MontyTuple([
        MontyString('hello'),
        MontyInt(33152),
        MontyInt(1),
        MontyBytes([240, 159, 152, 128]),
      ]),
    );
    expect(file.readContent(), '😀');
    file.writeContent('host write');
    expect(
      await session.feedRun('p.read_text()', os: fs),
      const MontyString('host write'),
    );
    file.delete();
    expect(file.deleted, true);
    // Upstream delete only marks the object; unlink removes its tree entry.
    expect(await session.feedRun('p.exists()', os: fs), const MontyBool(true));
    expect(
      await session.feedRun("open('/b', 'wb').close()", os: fs),
      const MontyNone(),
    );
    expect(fs.files.length, 2);
  });
}

void _callbackFailure(String label, _Start start) {
  test(
    'callback failures retain their host exception mapping ($label)',
    () async {
      final session = await _session(start);
      final fs = OSAccess(
        files: [
          CallbackFile(
            '/chosen',
            (_) => throw const ExternalException('KeyError', 'chosen'),
            (_, _) => fail('unexpected write'),
          ),
          CallbackFile(
            '/ordinary',
            (_) => throw StateError('ordinary'),
            (_, _) => fail('unexpected write'),
          ),
        ],
      );
      final runtime = isA<MontyRuntimeError>();
      await expectLater(
        session.feedRun("open('/chosen').read()", os: fs),
        throwsA(
          runtime
              .having((error) => error.exception.excType, 'type', 'KeyError')
              .having((error) => error.exception.message, 'message', 'chosen'),
        ),
      );
      await expectLater(
        session.feedRun("open('/ordinary').read()", os: fs),
        throwsA(
          runtime
              .having((error) => error.exception.excType, 'type', 'Exception')
              .having(
                (error) => error.exception.message,
                'message',
                'Bad state: ordinary',
              ),
        ),
      );
    },
  );

  test('CallbackFile host failure reaches Python ($label)', () async {
    final session = await _session(start);
    final fs = OSAccess(
      files: [
        CallbackFile('/bad', (_) => 42, (_, _) => fail('unexpected write')),
      ],
    );
    await expectLater(
      session.feedRun("open('/bad').read()", os: fs),
      throwsA(
        isA<MontyRuntimeError>().having(
          (e) => e.exception.excType,
          'type',
          'Exception',
        ),
      ),
    );
  });
}

void _customStat(String label, _Start start) {
  test('StatResult custom handler preserves named fields ($label)', () async {
    final session = await _session(start);
    final result = await session.feedRun(
      '''
from pathlib import Path
f = Path('/file').stat()
d = Path('/directory').stat()
(f.st_size, f.st_mode, f.st_mtime, d.st_size, d.st_nlink)
''',
      os: (name, args, kwargs) {
        if (name != 'Path.stat') throw const OsCallNotHandledException();

        return args.firstOrNull == MontyPath('/file')
            ? StatResult.fileStat(3, 420, 7)
            : StatResult.dirStat(493, 2);
      },
    );
    expect(
      result,
      const MontyTuple([
        MontyInt(3),
        MontyInt(33188),
        MontyFloat(7),
        MontyInt(4096),
        MontyInt(2),
      ]),
      reason: '${result.dartValue}',
    );
  });
}

@TestOn('vm')
@Tags(['worker'])
library;

import 'dart:ffi';
import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/dart_monty_core_testing.dart';
import 'package:test/test.dart';

// An open root and its tables share a directory capability. Closing the root
// after a feed must leave no descriptor retained by that feed's table.
void main() {
  test('abandoned suspended feeds release tables on isolate exit', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'test/unit/mount/mount_table_finalizer_probe.dart',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('finalized 8 abandoned feed tables'));
  }, skip: Platform.isWindows ? 'POSIX descriptor accounting' : false);
  for (final ending in [
    'complete',
    'error',
    'input rejection',
    'crash',
    'snapshot complete',
    'snapshot close',
    'lookup failure',
    'unresolved futures',
  ]) {
    test(
      'feed table releases capability on $ending',
      () => _isolated(ending, () async {
        final dir = Directory.systemTemp.createTempSync('mount-lifetime-');
        addTearDown(dir.deleteSync);
        MountDir(hostPath: dir.path, virtualPath: '/warm').close();
        final before = _descriptors();
        final mount = MountDir(hostPath: dir.path, virtualPath: '/d');
        addTearDown(mount.close);
        final opened = _descriptors();
        final owned = opened.difference(before);
        expect(owned, isNotEmpty, reason: 'construction opened a capability');
        final fake = FakeMontySession();
        addTearDown(fake.close);
        switch (ending) {
          case 'lookup failure' || 'unresolved futures':
            await _terminalResume(ending, mount);
          case 'error':
            fake.willRaise('ValueError', message: 'failure');
            await expectLater(
              fake.feedRun('raise', mount: [mount]),
              throwsA(isA<MontyRuntimeError>()),
            );
          case 'crash':
            fake.willCrash();
            await expectLater(
              fake.feedRun('crash', mount: [mount]),
              throwsA(isA<MontyCrashedError>()),
            );
          case 'input rejection':
            fake.willReturn(const MontyNone());
            await expectLater(
              fake.feedRun(
                'invalid',
                inputs: const {'bad': MontyString('\ud800')},
                mount: [mount],
              ),
              throwsA(isA<MontyRuntimeError>()),
            );
            expect(fake.feeds, isEmpty);
          case 'snapshot close':
            fake
              ..willCallOs('Path.exists', args: [MontyPath('/d/a')])
              ..willReturn(const MontyNone());
            final snapshot = await fake.feedStart('suspend', mount: [mount]);
            expect(snapshot, isA<FunctionSnapshot>());
            // A rejected feed must not replace the active drive's table owner.
            await expectLater(fake.feedStart('rejected'), throwsStateError);
            await fake.close();
          case 'snapshot complete':
            fake.willReturn(const MontyInt(2));
            expect(
              await fake.feedStart('done', mount: [mount]),
              isA<MontyComplete>().having(
                (s) => s.output,
                'output',
                const MontyInt(2),
              ),
            );
          default:
            fake.willReturn(const MontyInt(1));
            expect(
              await fake.feedRun('done', mount: [mount]),
              const MontyInt(1),
            );
        }
        mount.close();
        final after = _descriptors();
        expect(
          after.intersection(owned),
          isEmpty,
          reason: 'feed must drop its cloned root on $ending',
        );
      }),
      skip: Platform.isWindows ? 'POSIX descriptor accounting' : false,
    );
  }
}

Future<void> _terminalResume(String ending, MountDir mount) async {
  final pool = await Monty.start(maxProcesses: 1);
  addTearDown(pool.close);
  final session = await pool.checkout();
  // Keep the dead session reachable until after descriptor accounting: GC or
  // explicit session.close must not substitute for feed-end cleanup.
  addTearDown(session.close);
  if (ending == 'lookup failure') {
    final snapshot =
        await session.feedStart(
              'bad',
              mount: [mount],
              externalLookup: const {'bad': MontyString('\ud800')},
            )
            as NameLookupSnapshot;
    mount.close();
    await expectLater(
      snapshot.resumeAuto(),
      throwsA(
        isA<MontyRuntimeError>().having(
          (error) => error.toString(),
          'encoding refusal',
          startsWith('UnicodeEncodeError:'),
        ),
      ),
    );
  } else {
    final call =
        await session.feedStart('await f()', mount: [mount])
            as FunctionSnapshot;
    final snapshot =
        await call.resume(const ExternalFuture()) as FutureSnapshot;
    mount.close();
    await expectLater(snapshot.resumeAuto(), throwsStateError);
  }
  await expectLater(session.feedRun('1'), throwsStateError);
}

final int Function(int, int) _fcntl = DynamicLibrary.process()
    .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
      'fcntl',
    );

Set<int> _descriptors() => {
  for (var fd = 0; fd < 4096; fd++)
    if (_fcntl(fd, 1) != -1) fd,
};

// File descriptors belong to the process, not the isolate. Other suites may
// close and reuse a measured descriptor, so run each measurement alone.
Future<void> _isolated(String ending, Future<void> Function() body) async {
  if (Platform.environment['F2_MOUNT_LIFECYCLE_CHILD'] == '1') {
    return body();
  }
  final result = await Process.run(
    Platform.resolvedExecutable,
    [
      'test',
      'test/integration/worker/mount_lifecycle_io_test.dart',
      '-p',
      'vm',
      '-r',
      'expanded',
      '-N',
      'feed table releases capability on $ending',
    ],
    environment: {'F2_MOUNT_LIFECYCLE_CHILD': '1'},
  );
  expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  expect(result.stdout, contains('+1: All tests passed!'));
}

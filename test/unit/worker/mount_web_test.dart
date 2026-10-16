@TestOn('browser')
@Tags(['worker'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '_mount_sleep_cases.dart';

void main() {
  test('MountDir refuses host directories on web', () {
    expect(
      () => MountDir(hostPath: '/host', virtualPath: '/d'),
      throwsA(
        isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          'MountDir needs a host directory; the browser has none',
        ),
      ),
    );
  });
  test('empty mounts behave as no mounts', () async {
    await Monty.withPool((pool) async {
      await pool.withSession((session) async {
        expect(
          await session.feedRun('42', mount: const []),
          const MontyInt(42),
        );
      });
    }, maxProcesses: 1);
  });
  mountSleepTests();
}

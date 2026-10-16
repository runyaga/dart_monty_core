@TestOn('vm')
@Tags(['worker', 'vm-only'])
library;

import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/mount/native_mount_lookup.dart';
import 'package:monty_conformance/monty_conformance.dart';
import 'package:monty_conformance/worker_conformance.dart';
import 'package:test/test.dart';

import '../../integration/worker/_worker_harness.dart';

const _fixtures = ['mount_fs__ops.py', 'mount_fs__errors.py'];

void main() {
  expectNoWorkersLeftAfterEachTest();
  late Directory directory;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('mount-adjudicator-');
    // Upstream 591527397445bf734873252d1ee20c1b6308fe7f,
    // crates/monty-datatest/src/main.rs:402-414, create_mount_fs_tempdir.
    Directory('${directory.path}/subdir/deep').createSync(recursive: true);
    for (final entry in {
      'hello.txt': 'hello world\n',
      'empty.txt': '',
      'readonly.txt': 'readonly content',
      'subdir/nested.txt': 'nested content',
      'subdir/deep/file.txt': 'deep file',
    }.entries) {
      File('${directory.path}/${entry.key}').writeAsStringSync(entry.value);
    }
    File('${directory.path}/data.bin').writeAsBytesSync([0, 1, 2, 3]);
  });
  tearDown(() {
    nativeMountLookup.overridePackageDirectory(null);
    directory.deleteSync(recursive: true);
  });

  for (final name in _fixtures) {
    group(name, () {
      test('default overlay meets the pinned upstream directives', () async {
        final mount = MountDir(hostPath: directory.path, virtualPath: '/mnt');
        addTearDown(mount.close);
        expect(await _judge(name, mount: [mount]), isNull);
        expect(
          File('${directory.path}/hello.txt').readAsStringSync(),
          'hello world\n',
        );
        expect(directory.listSync(recursive: true), hasLength(8));
      });
      test('read-only control is reported as a fixture failure', () async {
        final mount = MountDir(
          hostPath: directory.path,
          virtualPath: '/mnt',
          mode: 'read-only',
        );
        addTearDown(mount.close);
        expect(await _judge(name, mount: [mount]), contains('PermissionError'));
      });
      test('closed control is reported as a harness failure', () async {
        final mount = MountDir(hostPath: directory.path, virtualPath: '/mnt');
        mount.close();
        expect(
          await _judge(name, mount: [mount]),
          startsWith('harness error:'),
        );
      });
      test('lying OS control without a mount fails the fixture', () async {
        expect(
          await _judge(
            name,
            os: (functionName, args, kwargs) => const MontyBool(false),
          ),
          contains('expected no error'),
        );
      });
    });
  }

  test(
    'corpus mount fixtures require the native library, with no simulation',
    () async {
      nativeMountLookup.overridePackageDirectory(directory.uri);
      final run = await Monty.withPool(
        (pool) => runWorkerFixtureCorpus(
          pool: pool,
          log: <String>[].add,
          only: _fixtures.toSet(),
        ),
      );
      expect(run.executed, containsAll(_fixtures));
      expect(run.passed, 0);
      expect(run.failures.keys, containsAll(_fixtures));
      for (final reason in run.failures.values) {
        expect(
          reason,
          allOf(contains('harness error:'), contains('build_worker: true')),
        );
      }
    },
  );
}

Future<String?> _judge(String name, {List<MountDir>? mount, OsHandler? os}) =>
    Monty.withPool((pool) async {
      final session = await pool.checkout(scriptName: name);
      final source = fixtureCorpusV1[name]!;
      final expectation =
          parseFixture(source, skipMountFs: false) ??
          (throw StateError('mount fixture must be adjudicated'));
      try {
        FixtureOutcome outcome;
        try {
          final value = await session.feedRun(
            source,
            mount: mount,
            cwd: '/mnt',
            os: os,
            externalLookup: {'root': MontyPath('/mnt')},
          );
          outcome = FixtureOutcome(value: value, valueRepr: pyValueRepr(value));
        } on MontyError catch (error) {
          outcome = FixtureOutcome(
            excType: error.exception.excType,
            message: error.exception.message,
          );
        } on StateError catch (error) {
          return 'harness error: $error';
        }

        return adjudicateFixture(expectation, outcome);
      } finally {
        await session.close();
      }
    });

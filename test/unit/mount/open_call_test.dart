// Unit tests for resolveOpenCall — the store-agnostic open() primitive.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  group('resolveOpenCall', () {
    // A tiny in-test store so we can assert which callbacks fire.
    late Set<String> files;
    late Set<String> dirs;
    late List<String> truncated;
    late List<String> created;

    setUp(() {
      files = {'/a.txt'};
      dirs = {'/d'};
      truncated = [];
      created = [];
    });

    MontyFileHandle open(
      String path,
      String mode, {
      bool readOnlyMount = false,
    }) => resolveOpenCall(
      path,
      mode,
      exists: files.contains,
      isDirectory: dirs.contains,
      ensureWritable: (p) {
        if (readOnlyMount) {
          throw const OsCallException(
            'read-only',
            pythonExceptionType: 'PermissionError',
          );
        }
      },
      truncate: truncated.add,
      createIfMissing: (p) {
        if (!files.contains(p)) created.add(p);
      },
    );

    test('read mode returns a handle for an existing file', () {
      final h = open('/a.txt', 'r');
      expect(h.path, '/a.txt');
      expect(h.mode, 'r');
      expect(h.position, 0);
      expect(truncated, isEmpty);
      expect(created, isEmpty);
    });

    test('read mode on a missing file throws FileNotFoundError', () {
      expect(
        () => open('/missing.txt', 'r'),
        throwsA(
          isA<OsCallException>().having(
            (e) => e.pythonExceptionType,
            'pythonExceptionType',
            'FileNotFoundError',
          ),
        ),
      );
    });

    test('read mode on a directory throws IsADirectoryError', () {
      expect(
        () => open('/d', 'rb'),
        throwsA(
          isA<OsCallException>().having(
            (e) => e.pythonExceptionType,
            'pythonExceptionType',
            'IsADirectoryError',
          ),
        ),
      );
    });

    test('write mode truncates (creating if missing)', () {
      final h = open('/new.txt', 'w');
      expect(h.mode, 'w');
      expect(truncated, ['/new.txt']);
      expect(created, isEmpty);
    });

    test('append mode creates if missing, never truncates', () {
      open('/log.txt', 'a');
      expect(truncated, isEmpty);
      expect(created, ['/log.txt']);
    });

    test('binary write mode (wb) truncates', () {
      final h = open('/x.bin', 'wb');
      expect(h.mode, 'wb');
      expect(truncated, ['/x.bin']);
    });

    test('ensureWritable rejection surfaces as PermissionError', () {
      expect(
        () => open('/a.txt', 'w', readOnlyMount: true),
        throwsA(
          isA<OsCallException>().having(
            (e) => e.pythonExceptionType,
            'pythonExceptionType',
            'PermissionError',
          ),
        ),
      );
    });

    test('ensureWritable is not consulted for read mode', () {
      // Read of an existing file succeeds even on a read-only mount.
      expect(open('/a.txt', 'r', readOnlyMount: true).mode, 'r');
    });
  });
}

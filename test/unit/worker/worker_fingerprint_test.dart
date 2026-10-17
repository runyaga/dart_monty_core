@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dart_monty_core/src/worker/worker_fingerprint.dart';
import 'package:dart_monty_core/src/worker/worker_manifest.dart';
import 'package:test/test.dart';

void main() {
  _fingerprintTests();
}

void _fingerprintTests() {
  group('worker fingerprint', () {
    _roundTripTest();
    _malformedRecordTest();
    _missingWorkerTest();
    _entryKeyTest();
    _atomicWriteTest();
    _fileOnlyPathTest();
  });
}

void _roundTripTest() {
  test('round trips a record', () async {
    final directory = await Directory.systemTemp.createTemp('fingerprint_');
    addTearDown(() => directory.delete(recursive: true));
    final worker = File('${directory.path}/worker')..writeAsStringSync('good');
    const entry = 'entry';

    writeWorkerFingerprint(worker, _fingerprint(worker, entry));

    expect(readWorkerFingerprint(worker), statWorkerFingerprint(worker, entry));
  });
}

void _malformedRecordTest() {
  test('treats missing and malformed records as absent', () async {
    final directory = await Directory.systemTemp.createTemp('fingerprint_');
    addTearDown(() => directory.delete(recursive: true));
    final worker = File('${directory.path}/worker')..writeAsStringSync('good');
    final record = File(workerFingerprintPath(worker.path));
    WorkerFingerprint? read() => readWorkerFingerprint(worker);
    for (final source in [
      null,
      '',
      'not json',
      '{}',
      '{"size":"4","modifiedMicros":1,"changedMicros":1,"entry":"x"}',
    ]) {
      if (source != null) record.writeAsStringSync(source);
      expect(read(), isNull);
    }
  });
}

void _missingWorkerTest() {
  test('returns null when a worker is missing', () {
    expect(statWorkerFingerprint(File('/missing/worker'), 'entry'), isNull);
  });
}

void _entryKeyTest() {
  test('keys every manifest artifact field', () {
    final artifact = WorkerArtifact(
      file: 'worker',
      bytes: 4,
      sha256: sha256.convert(utf8.encode('good')).toString(),
    );
    final key = workerEntryKey(artifact, version: 'v1');
    expect(key, isNot(workerEntryKey(artifact, version: 'v2')));
    expect(key, isNot(_entryKey('other', 4, artifact.sha256)));
    expect(key, isNot(_entryKey('worker', 5, artifact.sha256)));
    expect(key, isNot(_entryKey('worker', 4, 'a' * 64)));
  });
}

String _entryKey(String file, int bytes, String digest) => workerEntryKey(
  WorkerArtifact(file: file, bytes: bytes, sha256: digest),
  version: 'v1',
);

void _atomicWriteTest() {
  test('writes no temporary record', () async {
    final directory = await Directory.systemTemp.createTemp('fingerprint_');
    addTearDown(() => directory.delete(recursive: true));
    final worker = File('${directory.path}/worker')..writeAsStringSync('good');

    writeWorkerFingerprint(worker, _fingerprint(worker, 'entry'));

    expect(
      directory.listSync().where(
        (entry) => entry.path.contains('.fingerprint.tmp-'),
      ),
      isEmpty,
    );
  });
}

void _fileOnlyPathTest() {
  test(
    'uses the supplied file path parent without inspecting the path',
    () async {
      final directory = await Directory.systemTemp.createTemp('fingerprint_');
      addTearDown(() => directory.delete(recursive: true));
      final suppliedPath = Directory('${directory.path}/worker')..createSync();

      expect(
        workerFingerprintPath(suppliedPath.path),
        '${directory.path}/.fingerprint',
      );
    },
  );
}

WorkerFingerprint _fingerprint(File worker, String entry) =>
    statWorkerFingerprint(worker, entry) ??
    (throw StateError('test worker cannot be fingerprinted'));

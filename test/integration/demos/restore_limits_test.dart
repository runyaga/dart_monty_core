@Tags(['integration', 'example'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

const _memoryPolicy =
    'POLICY memory main=2097152 omitted=2097152 '
    'looser=2097152 tighter=524288';

const _gcPolicy =
    'POLICY gcInterval main=1000 omitted=1000 '
    'looser=1000 tighter=100 documentation-only';

const List<String> _expectedLines = [
  'POLICY recursion main=32 omitted=32 looser=32 tighter=8',
  'POLICY suspensions main=5 omitted=5 looser=5 tighter=3',
  _memoryPolicy,
  'POLICY feed main=1s omitted=1s looser=1s tighter=250ms',
  'POLICY turn isolated=1s omitted=1s looser=1s tighter=250ms',
  'POLICY sleep isolated=250ms omitted=250ms looser=250ms tighter=125ms',
  _gcPolicy,
  'PASS source-dumps',
  'PASS idle-omitted',
  'PASS idle-looser',
  'PASS idle-tighter',
  'PASS snapshot-omitted',
  'PASS snapshot-looser',
  'PASS snapshot-tighter',
  'PASS idle-turn',
  'PASS snapshot-turn',
  'PASS idle-sleep',
  'PASS snapshot-sleep',
  'PASS idle-optional',
  'PASS snapshot-optional',
  'DEMO OK restore_limits',
];

final List<RegExp> _observationPatterns = [
  RegExp(
    '^OBS dump profile=(main|turn|sleep|optional) '
    r'mode=(idle|snapshot) bytes=[0-9]+$',
  ),
  RegExp(r'^OBS restore case=[a-z0-9-]+ micros=[0-9]+$'),
  RegExp(
    '^OBS carry case=[a-z0-9-]+ source_seen=3 '
    r'returned_after_load=[0-9]+$',
  ),
];

bool _isObservation(String line) {
  return _observationPatterns.any((pattern) => pattern.hasMatch(line));
}

void main() {
  test(
    'restored jobs retain the stricter resource limits',
    () async {
      final result = await Process.run(
        'dart',
        ['run', 'example/17_restore_limits.dart'],
        workingDirectory: Directory.current.path,
      );

      final diagnostics =
          'exit=${result.exitCode}\n'
          '--- stdout ---\n${result.stdout}\n'
          '--- stderr ---\n${result.stderr}';

      expect(result.exitCode, equals(0), reason: diagnostics);

      final lines = const LineSplitter().convert(result.stdout as String);
      final compared = lines.where((line) => !_isObservation(line)).toList();

      expect(compared, equals(_expectedLines), reason: diagnostics);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

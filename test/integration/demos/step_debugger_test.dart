@Tags(['integration', 'example'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

const List<String> _expectedLines = [
  'PASS step-1-kind',
  'PASS step-1-name',
  'PASS step-1-bytes',
  'PASS step-1-slice',
  'PASS step-1-utf16-off-by-one',
  'PASS step-2-kind',
  'PASS step-2-fn',
  'PASS step-2-arg',
  'PASS step-2-slice',
  'PASS step-3-kind',
  'PASS step-3-fn',
  'PASS step-3-arg',
  'PASS step-3-slice',
  'PASS step-4-kind',
  'PASS step-4-pending',
  'PASS step-4-slice',
  'PASS complete-kind',
  'PASS complete-output',
  'DEMO OK step_debugger',
];

void main() {
  test(
    'example/16_step_debugger.dart',
    () async {
      final result = await Process.run(
        'dart',
        ['run', 'example/16_step_debugger.dart'],
      );
      expect(
        result.exitCode,
        equals(0),
        reason:
            'exit=${result.exitCode}\n'
            '--- stdout ---\n${result.stdout}\n'
            '--- stderr ---\n${result.stderr}',
      );
      final lines = const LineSplitter()
          .convert(result.stdout as String)
          .where((line) => line.isNotEmpty)
          .toList();
      expect(lines, equals(_expectedLines));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

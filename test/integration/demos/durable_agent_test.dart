@Tags(['integration', 'example'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test(
    'durable agent survives a host restart',
    () async {
      final result = await Process.run(
        'dart',
        ['run', 'example/18_durable_agent.dart'],
        workingDirectory: Directory.current.path,
      );

      final diagnostics =
          'exit=${result.exitCode}\n'
          'stdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}';

      expect(result.exitCode, equals(0), reason: diagnostics);

      expect(
        const LineSplitter().convert(result.stdout as String),
        equals(const [
          'PASS module-stubs',
          'PASS search-fanout',
          'PASS parked-at-approval',
          'PASS worker-released',
          'PASS host-restarted',
          'PASS worker-restarted',
          'PASS restored-approval',
          'PASS journal-replay',
          'PASS effects-once',
          'PASS restored-tool-error',
          'PASS report-matches',
          'PASS dump-limit-retained',
          'PASS loose-limit-control',
          'DEMO OK durable_agent',
        ]),
        reason: diagnostics,
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

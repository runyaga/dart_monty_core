// The red test for story tutorial-1: example/15_host_module.dart builds an
// ExternalModule, walks every edge of its exposure boundary and prints one
// PASS line per check plus DEMO OK host_module. Until the example exists
// this fails, because `dart run` of a missing file exits non-zero.
//
// Run: dart test -p vm --run-skipped --tags=example test/integration/demos/host_module_test.dart

@Tags(['integration', 'example'])
library;

import 'dart:io';

import 'package:test/test.dart';

/// The whole stdout the example must print, in order. stderr carries
/// "Running build hooks..." and is not compared.
const List<String> _expected = [
  'PASS import-and-dotted-calls',
  'PASS module-id-round-trip',
  'PASS public-attrs-exclude-private',
  'PASS module-assignment-refused',
  'PASS module-not-callable',
  'PASS missing-attribute',
  'PASS private-attribute-refused',
  'PASS unknown-module',
  'PASS unknown-submodule',
  'PASS forged-name-reaches-nothing',
  'PASS host-exception-by-name',
  'PASS hidden-never-called',
  'DEMO OK host_module',
];

void main() {
  test('example/15_host_module.dart checks the module boundary', () async {
    final result = await Process.run('dart', [
      'run',
      'example/15_host_module.dart',
    ]);

    expect(
      result.exitCode,
      equals(0),
      reason:
          'exit=${result.exitCode}\n'
          '--- stdout ---\n${result.stdout}\n'
          '--- stderr ---\n${result.stderr}',
    );
    expect(result.stdout, equals('${_expected.join('\n')}\n'));
  }, timeout: const Timeout(Duration(minutes: 2)));
}

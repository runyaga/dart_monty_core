// Integration tests: verify WASM output matches fixture directives.
//
// Unlike the FFI test, the WASM test cannot use subprocess oracle binaries.
// Instead it relies on the `# Return=` and `# Raise=` directives in each
// fixture file as the source of truth.
//
// Run: dart test test/integration/wasm_fixture_test.dart -p chrome --run-skipped
//
// The platform is selected at compile time:
// MontyWasm on Chrome, MontyFfi on VM.
@Tags(['integration', 'wasm'])
library;

import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '_fixture_parser.dart';

void main() {
  final fixtureDir = Directory('test/fixtures/test_cases');

  if (!fixtureDir.existsSync()) {
    group('wasm_fixture', () {
      test('fixture directory missing', () {
        fail(
          'test/fixtures/test_cases not found. '
          'Create the symlink: ln -s /path/to/monty/crates/monty/test_cases '
          'test/fixtures/test_cases',
        );
      });
    });

    return;
  }

  final fixtures = fixtureDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.py'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  group('wasm_fixture', () {
    for (final file in fixtures) {
      final name = file.path.split('/').last;
      test(name, () async {
        final code = file.readAsStringSync();
        final expectation = parseFixture(code);
        if (expectation == null) return; // skipped fixture

        final platform = createPlatformMonty();
        MontyResult? result;
        String? thrownExcType;
        try {
          result = await platform.run(code, scriptName: name);
          thrownExcType = result.error?.excType;
        } on MontyScriptError catch (e) {
          thrownExcType = e.excType;
        } on MontyResourceError {
          thrownExcType = 'MemoryLimitExceeded';
        } finally {
          await platform.dispose();
        }

        switch (expectation) {
          case ExpectNoException():
            expect(
              thrownExcType,
              isNull,
              reason: 'unexpected error in $name',
            );
          case ExpectReturn(:final value):
            expect(
              thrownExcType,
              isNull,
              reason: 'unexpected error in $name',
            );
            expect(
              result?.value,
              equals(MontyValue.fromDart(value)),
              reason: 'value mismatch for $name',
            );
          case ExpectRaise(:final excType):
            expect(
              thrownExcType,
              equals(excType),
              reason: 'excType mismatch for $name',
            );
        }
      });
    }
  });
}

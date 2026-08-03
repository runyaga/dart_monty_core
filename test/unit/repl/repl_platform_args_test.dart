// Unit tests: ReplPlatform must REJECT the arguments it cannot honour.
//
// `MontyPlatform.run`/`start` take `limits` and `scriptName` per call. A REPL
// cannot honour either: the tracker is chosen when the Rust session is created
// and cannot be swapped afterwards, and the script name is baked into the
// handle at `monty_repl_create`. Both belong on the `MontyRepl` constructor.
//
// Until this test existed, `ReplPlatform.run`/`start` accepted both and threw
// them away. That is the exact shape of FB-1 / core#124: `Monty.run(limits:)`
// routes through `MontyRepl` and silently ran unbounded, so a caller who asked
// for a 1 MB cap got none and had no way to find out. A dropped limit is a
// security control that reports success.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  group('ReplPlatform rejects per-call session arguments', () {
    late MontyRepl repl;
    late ReplPlatform platform;

    setUp(() {
      repl = MontyRepl();
      platform = ReplPlatform(repl: repl);
    });

    tearDown(() => repl.dispose());

    test('run() throws when given limits', () {
      expect(
        () => platform.run('x = 1', limits: const MontyLimits(stackDepth: 10)),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('run() throws when given a scriptName', () {
      expect(
        () => platform.run('x = 1', scriptName: 'other.py'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('start() throws when given limits', () {
      expect(
        () => platform.start(
          'x = 1',
          limits: const MontyLimits(memoryBytes: 1024),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('start() throws when given a scriptName', () {
      expect(
        () => platform.start('x = 1', scriptName: 'other.py'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('the error names the constructor that DOES honour the argument', () {
      // A rejection that does not say where to put the argument instead just
      // moves the dead end. Both replacements are on MontyRepl's constructor.
      expect(
        () => platform.run('x = 1', limits: const MontyLimits(stackDepth: 10)),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('MontyRepl('),
          ),
        ),
      );
    });
  });

  group('ReplPlatform name lookup', () {
    late MontyRepl repl;
    late ReplPlatform platform;

    setUp(() {
      repl = MontyRepl();
      platform = ReplPlatform(repl: repl);
    });

    tearDown(() => repl.dispose());

    // `UnsupportedError` is not an idle choice of class. Conformance harnesses
    // catch `UnimplementedError` to turn "this backend cannot inject a named
    // constant" into a recorded skip (fixture_dispatch.dart, the FB-5 branch).
    // An `UnsupportedError` sails straight through that catch and takes the
    // whole run down, so a missing capability reported as a crash.
    test(
      'resumeNameLookup throws UnimplementedError, not UnsupportedError',
      () {
        expect(
          () => platform.resumeNameLookup('CONST_INT', 42),
          throwsA(isA<UnimplementedError>()),
        );
      },
    );

    test('resumeNameLookupUndefined throws UnimplementedError', () {
      expect(
        () => platform.resumeNameLookupUndefined('nope'),
        throwsA(isA<UnimplementedError>()),
      );
    });
  });
}

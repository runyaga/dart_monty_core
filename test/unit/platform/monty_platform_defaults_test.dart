// MontyPlatform's defaults — the diagnostic a new backend author sees.
//
// lib/src/platform/monty_platform.dart sat at 0/26. It is the abstract class
// every backend implements against, and all thirteen of its methods have the
// same shape: a body that throws UnimplementedError naming itself.
//
// WHAT THIS PINS, AND WHY IT IS NOT BOOKKEEPING. The message is the whole
// value of the default. A backend that forgets to override `resumeNotFound`
// fails at runtime, and the difference between a useful afternoon and a
// confusing one is whether the error says `resumeNotFound()` or something
// generic. Three things can silently break that and nothing was checking any
// of them:
//
//   - a copy-pasted body naming the WRONG method (the most likely mistake in
//     thirteen near-identical throws, and the one a human reading the file
//     will not catch)
//   - a default that stops throwing and returns null or a Future that never
//     completes, turning "not implemented" into a hang
//   - a new method added without a default at all
//
// The subclass below overrides NOTHING, which is exactly the situation being
// described: a backend author who has declared the class and not yet written
// the methods.
@Tags(['unit'])
library;

import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/platform/monty_platform.dart';
import 'package:test/test.dart';

/// A platform that implements nothing — every call must hit a default.
class _BarePlatform extends MontyPlatform {}

/// Asserts [call] throws UnimplementedError whose message names [method].
void _refuses(String method, Object? Function() call) {
  expect(
    call,
    throwsA(
      isA<UnimplementedError>().having(
        (e) => e.toString(),
        'message for $method',
        allOf(contains('$method()'), contains('has not been implemented')),
      ),
    ),
    reason:
        'the default for $method must name ITSELF, or a backend author '
        'is told only that something is missing',
  );
}

void main() {
  group('MontyPlatform defaults name the method they stand for', () {
    final p = _BarePlatform();

    test('the execution entry points', () {
      _refuses('run', () => p.run('x = 1'));
      _refuses('start', () => p.start('x = 1'));
      _refuses('dispose', p.dispose);
    });

    test('every resume variant', () {
      _refuses('resume', () => p.resume(1));
      _refuses('resumeWithError', () => p.resumeWithError('boom'));
      _refuses(
        'resumeWithException',
        () => p.resumeWithException('ValueError', 'boom'),
      );
      _refuses('resumeNotFound', () => p.resumeNotFound('fn'));
      _refuses('resumeNameLookup', () => p.resumeNameLookup('x', 1));
      _refuses(
        'resumeNameLookupUndefined',
        () => p.resumeNameLookupUndefined('x'),
      );
    });

    test('the compile and type-check surfaces', () {
      _refuses('compileCode', () => p.compileCode('x = 1'));
      _refuses('typeCheck', () => p.typeCheck('x = 1'));
      _refuses(
        'runPrecompiled',
        () => p.runPrecompiled(Uint8List.fromList([0])),
      );
      _refuses(
        'startPrecompiled',
        () => p.startPrecompiled(Uint8List.fromList([0])),
      );
    });

    test('no default names a DIFFERENT method than its own', () {
      // The copy-paste check, stated as its own case because it is the failure
      // the per-method assertions above would still catch but nobody would
      // read them as testing for. Thirteen near-identical throws is where a
      // wrong name hides.
      final seen = <String>{};
      for (final entry in <String, Object? Function()>{
        'run': () => p.run('x'),
        'start': () => p.start('x'),
        'resume': () => p.resume(1),
        'resumeWithError': () => p.resumeWithError('e'),
        'resumeWithException': () => p.resumeWithException('T', 'e'),
        'resumeNotFound': () => p.resumeNotFound('f'),
        'resumeNameLookup': () => p.resumeNameLookup('n', 1),
        'resumeNameLookupUndefined': () => p.resumeNameLookupUndefined('n'),
        'compileCode': () => p.compileCode('x'),
        'typeCheck': () => p.typeCheck('x'),
        'runPrecompiled': () => p.runPrecompiled(Uint8List.fromList([0])),
        'startPrecompiled': () => p.startPrecompiled(Uint8List.fromList([0])),
        'dispose': p.dispose,
      }.entries) {
        // RECORDED THROUGH THE MATCHER, not a catch. `UnimplementedError`
        // is an Error, and the analyzer's avoid_catching_errors forbids
        // catching one — rightly, since catching Errors is how a bug becomes
        // a shrug. `having` runs its extractor on the thrown object, so the
        // message can be collected there without the test ever handling it.
        expect(
          entry.value,
          throwsA(
            isA<UnimplementedError>().having(
              (e) {
                seen.add(e.toString());

                return e.toString();
              },
              'message',
              contains('${entry.key}()'),
            ),
          ),
          reason:
              '${entry.key} must throw, and must name itself — a default '
              'that returns instead turns "not implemented" into silence',
        );
      }

      // Thirteen DISTINCT messages. If two defaults carried the same text,
      // at least one names the wrong method — the copy-paste failure this
      // case exists for, which the per-method assertions above would catch
      // only if the wrong name happened to belong to a method not also tested.
      expect(
        seen,
        hasLength(13),
        reason: 'two defaults share a message, so one names the wrong method',
      );
    });
  });
}

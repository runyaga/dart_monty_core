// MontyCrashedError is pure Dart and shared by the native and web channels,
// so it is tested on every compiler.
import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:test/test.dart';

void main() {
  group('MontyCrashedError.toString', () {
    test('names only the cause when that is all it has', () {
      expect(
        MontyCrashedError(CrashCause.killed).toString(),
        'MontyCrashedError(killed)',
      );
    });

    test('names every field it has, in order', () {
      expect(
        MontyCrashedError(
          CrashCause.fatal,
          exitCode: 4,
          message: 'm',
          stderrTail: 's',
        ).toString(),
        'MontyCrashedError(fatal, exit code 4, m, stderr: s)',
      );
    });

    test('a negative exit code is a signal', () {
      expect(
        MontyCrashedError(CrashCause.vanished, exitCode: -9).toString(),
        'MontyCrashedError(vanished, exit code -9)',
      );
    });
  });

  test('is an Error, not an Exception: a dead worker is not recoverable', () {
    expect(MontyCrashedError(CrashCause.outOfMemory), isA<Error>());
  });
}

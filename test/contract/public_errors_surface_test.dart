import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

String _classifyError(MontyError error) => switch (error) {
  MontyRuntimeError(:final traceback) => 'runtime:${traceback.length}',
  MontySyntaxError(:final traceback) => 'syntax:${traceback.length}',
  MontyTypingError() => 'typing:${error.display()}',
  MontyCrashedError(:final cause) => 'crashed:${cause.name}',
};

void main() {
  group('public errors surface', () {
    test('names FrameTooLargeException, CrashCause, ChainWireStatus, Frame, '
        'MontyExceptionValue and each MontyError subtype', () {
      const frameError = FrameTooLargeException(300, 256);
      expect(frameError.length, 300);
      expect(frameError.max, 256);
      expect(
        frameError.toString(),
        'FrameTooLargeException: frame of 300 bytes exceeds maximum of '
        '256 bytes',
      );

      expect(
        CrashCause.values,
        containsAll([
          CrashCause.outOfMemory,
          CrashCause.fatal,
          CrashCause.vanished,
          CrashCause.killed,
          CrashCause.protocol,
          CrashCause.spawn,
        ]),
      );

      expect(
        ChainWireStatus.values,
        [ChainWireStatus.unavailableOnPinnedWire],
      );

      final excValue = MontyExceptionValue(
        'ValueError',
        'bad',
        const {'code': MontyInt(1)},
      );
      expect(excValue.excType, 'ValueError');
      expect(excValue.message, 'bad');
      expect(excValue.attributes, {'code': const MontyInt(1)});

      const emptyFrames = <Frame>[];
      expect(emptyFrames, isA<List<Frame>>());
      expect(_classifyError, isA<String Function(MontyError)>());
      expect(MontyRuntimeError, isNotNull);
      expect(MontySyntaxError, isNotNull);
      expect(MontyTypingError, isNotNull);
      expect(MontyCrashedError, isNotNull);
    });

    test('spawn failure yields MontyCrashedError with CrashCause.spawn and '
        'ChainWireStatus.unavailableOnPinnedWire', () async {
      await expectLater(
        Monty.start(workerLocation: '/nonexistent/dart_monty_worker_missing'),
        throwsA(
          isA<MontyCrashedError>()
              .having((e) => e.cause, 'cause', CrashCause.spawn)
              .having(
                (e) => e.chainWireStatus,
                'chainWireStatus',
                ChainWireStatus.unavailableOnPinnedWire,
              )
              .having(
                _classifyError,
                'classified',
                'crashed:spawn',
              ),
        ),
      );
    });
  });
}

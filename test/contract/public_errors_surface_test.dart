import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

String _classifyError(MontyError error) => switch (error) {
  MontyRuntimeError(:final traceback) => 'runtime:${traceback.length}',
  MontySyntaxError(:final traceback) => 'syntax:${traceback.length}',
  MontyTypingError() => 'typing:${error.display()}',
  MontyCrashedError(:final timedOut) => 'crashed:timedOut=$timedOut',
};

void main() {
  group('public errors surface', () {
    test('names FrameTooLargeException, Frame, MontyExceptionValue and each '
        'MontyError subtype through the root import', () {
      const frameError = FrameTooLargeException(300, 256);
      expect(frameError.length, 300);
      expect(frameError.max, 256);
      expect(
        frameError.toString(),
        'FrameTooLargeException: frame of 300 bytes exceeds maximum of '
        '256 bytes',
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
    });

    test(
      'a spawn failure is a MontyCrashedError that did not time out',
      () async {
        await expectLater(
          Monty.start(workerLocation: '/nonexistent/dart_monty_worker_missing'),
          throwsA(
            isA<MontyCrashedError>().having(
              _classifyError,
              'classified',
              'crashed:timedOut=false',
            ),
          ),
        );
      },
    );
  });
}

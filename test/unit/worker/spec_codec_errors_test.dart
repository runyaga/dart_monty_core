// Spec tests for the error family's frames and rendering: Frame fields and
// identity, traceback order and stability, display() text for a multiline
// syntax error and an invalid format, and that a rejected raised exception is
// a MontyCrashedError caught by `on MontyError`. Each test name starts with
// the requirement id it asserts, so a mutation run can select it with
// `-N 'REQ-<id>:'`. Pure Dart: vm, dart2js and dart2wasm.
import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:test/test.dart';

pb.StackFrame _frame({
  String file = 'main.py',
  int line = 3,
  int column = 5,
  int? endLine,
  int endColumn = 9,
  String? name = '<module>',
  String? preview,
}) => pb.StackFrame(
  filename: file,
  start: pb.CodeLoc(line: line, column: column),
  end: pb.CodeLoc(line: endLine ?? line, column: endColumn),
  frameName: name,
  previewLine: preview,
);

MontyError _error(String type, List<pb.StackFrame> frames, [String? message]) =>
    raisedError(
      pb.RaisedException(excType: type, message: message, traceback: frames),
    );

List<Frame> _traceback(MontyError error) => switch (error) {
  final MontyRuntimeError e => e.traceback,
  final MontySyntaxError e => e.traceback,
  _ => fail('not a raised error: $error'),
};

void main() {
  group('Frame', () {
    test('REQ-Frame-7: positions are non-nullable one-based ints', () {
      final frame = _traceback(
        _error('ValueError', [
          _frame(endLine: 4),
        ]),
      ).single;
      // A list of `int` does not compile if a field is nullable.
      final positions = <int>[
        frame.line,
        frame.column,
        frame.endLine,
        frame.endColumn,
      ];
      expect(positions, [3, 5, 4, 9]);
      final first = _traceback(
        _error('ValueError', [_frame(line: 1, column: 1, endColumn: 2)]),
      ).single;
      expect(
        [first.line, first.column, first.endLine, first.endColumn],
        [1, 1, 1, 2],
      );
    });

    test('REQ-Frame-10: sourceLine is the optional preview', () {
      final absent = _traceback(_error('ValueError', [_frame()])).single;
      expect(absent.sourceLine, isNull);
      final present = _traceback(
        _error('ValueError', [_frame(preview: 'x = 1 / 0')]),
      ).single;
      expect(present.sourceLine, 'x = 1 / 0');
      final empty = _traceback(
        _error('ValueError', [_frame(column: 1, endColumn: 1, preview: '')]),
      ).single;
      expect(empty.sourceLine, '');
    });

    test('REQ-Frame-12: hashCode is the identity hash, not the fields', () {
      final frames = [
        ..._traceback(_error('ValueError', [_frame(), _frame()])),
        ..._traceback(_error('ValueError', [_frame()])),
      ];
      for (final frame in frames) {
        expect(frame.hashCode, identityHashCode(frame));
        expect(frame.hashCode, frame.hashCode);
      }
      // Equal fields, different objects: not equal.
      expect(frames[0] == frames[1], isFalse);
      expect(frames[0] == frames[2], isFalse);
      expect(frames[0] == frames[0], isTrue);
      expect({...frames}, hasLength(3));
    });

    test('REQ-Frame-13: repeated reads give the same frame objects', () {
      for (final error in [
        _error('ValueError', [_frame(), _frame(line: 4)]),
        _error('SyntaxError', [_frame(), _frame(line: 4)]),
      ]) {
        final first = _traceback(error);
        final second = _traceback(error);
        expect(first, hasLength(2));
        for (var i = 0; i < first.length; i++) {
          expect(identical(first[i], second[i]), isTrue, reason: '$error $i');
        }
      }
    });

    test(
      'REQ-Frame-22: a rejected frame is a MontyCrashedError, a MontyError',
      () {
        final rejected = <String, List<pb.StackFrame>>{
          'no start': [
            pb.StackFrame(
              filename: 'm.py',
              end: pb.CodeLoc(line: 1, column: 1),
            ),
          ],
          'no end': [
            pb.StackFrame(
              filename: 'm.py',
              start: pb.CodeLoc(line: 1, column: 1),
            ),
          ],
          'end before start': [
            _frame(endColumn: 2, preview: 'abcdef'),
          ],
          'end beyond preview': [
            _frame(column: 1, preview: 'ab'),
          ],
        };
        for (final MapEntry(:key, :value) in rejected.entries) {
          final error = _error('ValueError', value, 'm');
          expect(error, isA<MontyCrashedError>(), reason: key);
          expect((error as MontyCrashedError).cause, CrashCause.protocol);
          expect(
            error.toString(),
            startsWith(
              'monty worker protocol error: invalid exception payload: ',
            ),
          );
          MontyError? caught;
          try {
            throw error;
          } on MontyError catch (e) {
            caught = e;
          }
          expect(identical(caught, error), isTrue, reason: key);
        }
        // A well-formed frame is a runtime error, not a rejection.
        expect(_error('ValueError', [_frame()]), isA<MontyRuntimeError>());
      },
    );
  });

  group('a rejected raised exception', () {
    test(
      'REQ-MontyRuntimeError-43: is a MontyCrashedError, so on MontyError',
      () {
        final rejected = [
          _error('NotARealException', const [], 'm'),
          _error('ValueError', [
            pb.StackFrame(
              filename: 'm.py',
              end: pb.CodeLoc(line: 1, column: 1),
            ),
          ], 'm'),
        ];
        for (final error in rejected) {
          expect(error, isA<MontyCrashedError>());
          expect(error, isNot(isA<MontyRuntimeError>()));
          expect(error, isNot(isA<MontySyntaxError>()));
          var handled = false;
          try {
            throw error;
          } on MontyRuntimeError {
            fail('a rejection is not a MontyRuntimeError');
          } on MontyError {
            handled = true;
          }
          expect(handled, isTrue);
        }
        expect(
          rejected.first.toString(),
          'monty worker protocol error: invalid exception payload: '
          'unknown exception type "NotARealException"',
        );
      },
    );
  });

  group('tracebacks', () {
    List<pb.StackFrame> three() => [
      _frame(line: 10, name: 'outer'),
      _frame(line: 20, name: 'middle'),
      _frame(line: 30, name: null),
    ];

    test('REQ-MontyRuntimeError-7: repeated reads return the same list', () {
      final error = _error('ValueError', three()) as MontyRuntimeError;
      final first = error.traceback;
      final second = error.traceback;
      expect(identical(first, second), isTrue);
      expect(first, hasLength(3));
      for (var i = 0; i < 3; i++) {
        expect(identical(first[i], second[i]), isTrue);
      }
      expect(() => first.add(first.first), throwsUnsupportedError);
    });

    test('REQ-MontySyntaxError-8: outermost frame first, in order', () {
      final error = _error('SyntaxError', three(), 'bad') as MontySyntaxError;
      expect(error.traceback.map((f) => f.line), [10, 20, 30]);
      expect(error.traceback.map((f) => f.functionName), [
        'outer',
        'middle',
        null,
      ]);
      final runtime = _error('ValueError', three()) as MontyRuntimeError;
      expect(runtime.traceback.map((f) => f.line), [10, 20, 30]);
    });

    test('REQ-MontySyntaxError-9: repeated reads give the same frames', () {
      final error = _error('SyntaxError', three(), 'bad') as MontySyntaxError;
      final first = error.traceback;
      final second = error.traceback;
      expect(first, hasLength(3));
      for (var i = 0; i < 3; i++) {
        expect(identical(first[i], second[i]), isTrue, reason: '$i');
      }
      expect(identical(first, second), isTrue);
    });
  });

  group('display()', () {
    test(
      'REQ-MontySyntaxError-16: a multiline span prints its preview block',
      () {
        final error =
            _error(
                  'SyntaxError',
                  [
                    _frame(
                      line: 1,
                      column: 1,
                      endLine: 3,
                      endColumn: 2,
                      preview: 'if x:\n  y = (\n    1',
                    ),
                  ],
                  'unexpected EOF',
                )
                as MontySyntaxError;
        expect(
          error.display(),
          'Traceback (most recent call last):\n'
          '  File "main.py", line 1, in <module>\n'
          '    if x:\n'
          '      y = (\n'
          '        1\n'
          'SyntaxError: unexpected EOF',
        );
        // Windows line endings are not part of the block's lines, and the
        // block carries no caret line.
        final crlf =
            _error(
                  'SyntaxError',
                  [
                    _frame(
                      line: 2,
                      column: 1,
                      endLine: 3,
                      endColumn: 4,
                      preview: 'ab\r\ncd',
                    ),
                  ],
                  'm',
                )
                as MontySyntaxError;
        expect(crlf.display().split('\n'), [
          'Traceback (most recent call last):',
          '  File "main.py", line 2, in <module>',
          '    ab',
          '    cd',
          'SyntaxError: m',
        ]);
        expect(crlf.display(), isNot(contains('~')));
      },
    );

    test('REQ-MontySyntaxError-19: an unsupported format is refused', () {
      final error =
          _error('SyntaxError', [_frame()], 'bad') as MontySyntaxError;
      expect(
        () => error.display('x'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            "Invalid display format: 'x'. "
                "Expected 'traceback', 'type-msg', or 'msg'",
          ),
        ),
      );
      for (final format in ['', 'Traceback', 'type_msg', 'MSG']) {
        expect(
          () => error.display(format),
          throwsArgumentError,
          reason: format,
        );
      }
      // The three formats it names are accepted.
      expect(error.display('type-msg'), 'SyntaxError: bad');
      expect(error.display('msg'), 'bad');
      expect(error.display(), endsWith('SyntaxError: bad'));
    });
  });
}

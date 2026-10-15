// Spec tests for the error family's frames and rendering: Frame fields and
// identity, traceback order and stability, display() text for a multiline
// syntax error and an invalid format, and that a rejected raised exception is
// a MontyCrashedError caught by `on MontyError`. Each test name starts with
// the requirement id it asserts, so a mutation run can select it with
// `-N 'REQ-<id>:'`. Pure Dart: vm, dart2js and dart2wasm.
import 'package:collection/collection.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:test/test.dart';

import '../../_accessors.dart';

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

/// [values], which must be non-null for this to compile.
List<int> _ints(List<int> values) => values;

/// The one frame of [error]'s traceback.
Frame _onlyFrame(MontyError error) => onlyItem(_traceback(error));

/// Whether [a] and [b] hold the very same objects in the same order.
bool _same(List<Object> a, List<Object> b) =>
    a.length == b.length &&
    !a.indexed.any((e) => !identical(e.$2, b.elementAtOrNull(e.$1)));

/// A traceback frame without a start.
pb.StackFrame _noStart() =>
    pb.StackFrame(filename: 'm.py', end: pb.CodeLoc(line: 1, column: 1));

void main() {
  final crashed = isA<MontyCrashedError>();
  final runtime = isA<MontyRuntimeError>();

  group('Frame', () {
    test('REQ-Frame-7: positions are non-nullable one-based ints', () {
      final frame = _onlyFrame(_error('ValueError', [_frame(endLine: 4)]));
      // A list of `int` does not compile if a field is nullable.
      final positions = _ints([
        frame.line,
        frame.column,
        frame.endLine,
        frame.endColumn,
      ]);
      expect(positions, [3, 5, 4, 9]);
      final first = _onlyFrame(
        _error('ValueError', [_frame(line: 1, column: 1, endColumn: 2)]),
      );
      expect(
        [first.line, first.column, first.endLine, first.endColumn],
        [1, 1, 1, 2],
      );
    });

    test('REQ-Frame-10: sourceLine is the optional preview', () {
      final absent = _onlyFrame(_error('ValueError', [_frame()]));
      expect(absent.sourceLine, isNull);
      final present = _onlyFrame(
        _error('ValueError', [_frame(preview: 'x = 1 / 0')]),
      );
      expect(present.sourceLine, 'x = 1 / 0');
      final empty = _onlyFrame(
        _error('ValueError', [_frame(column: 1, endColumn: 1, preview: '')]),
      );
      expect(empty.sourceLine, '');
    });

    test('REQ-Frame-12: hashCode is the identity hash, not the fields', () {
      final wire = _frame();
      final frames = [
        ..._traceback(_error('ValueError', [wire, wire])),
        ..._traceback(_error('ValueError', [wire])),
      ];
      for (final frame in frames) {
        expect(frame.hashCode, identityHashCode(frame));
        expect(frame.hashCode, frame.hashCode);
      }
      // Equal fields, different objects: not equal.
      final [a, b, c] = frames;
      expect(a == b, isFalse);
      expect(a == c, isFalse);
      expect(a == a, isTrue);
      expect({...frames}, hasLength(3));
    });

    test('REQ-Frame-13: repeated reads give the same frame objects', () {
      final wire = [_frame(), _frame(line: 4)];
      for (final error in [
        _error('ValueError', wire),
        _error('SyntaxError', wire),
      ]) {
        final first = _traceback(error);
        expect(first, hasLength(2));
        expect(_same(first, _traceback(error)), isTrue, reason: '$error');
      }
    });

    test(
      'REQ-Frame-22: a rejected frame is a MontyCrashedError, a MontyError',
      () {
        final rejected = {
          'no start': [_noStart()],
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
          expect(error, crashed, reason: key);
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
        expect(_error('ValueError', [_frame()]), runtime);
      },
    );
  });

  group('a rejected raised exception', () {
    test(
      'REQ-MontyRuntimeError-43: is a MontyCrashedError, so on MontyError',
      () {
        final rejected = [
          _error('NotARealException', const [], 'm'),
          _error('ValueError', [_noStart()], 'm'),
        ];
        for (final error in rejected) {
          expect(error, crashed);
          expect(error, isNot(runtime));
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
          firstItem(rejected).toString(),
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
      expect(identical(first, error.traceback), isTrue);
      expect(first, hasLength(3));
      expect(_same(first, error.traceback), isTrue);
      expect(() => first.add(firstItem(first)), throwsUnsupportedError);
    });

    test('REQ-MontySyntaxError-8: outermost frame first, in order', () {
      final wire = three();
      final error = _error('SyntaxError', wire, 'bad') as MontySyntaxError;
      expect(error.traceback.map((f) => f.line), [10, 20, 30]);
      expect(error.traceback.map((f) => f.functionName), [
        'outer',
        'middle',
        null,
      ]);
      final other = _error('ValueError', wire) as MontyRuntimeError;
      expect(other.traceback.map((f) => f.line), [10, 20, 30]);
    });

    test('REQ-MontySyntaxError-9: repeated reads give the same frames', () {
      final error = _error('SyntaxError', three(), 'bad') as MontySyntaxError;
      final first = error.traceback;
      expect(first, hasLength(3));
      expect(_same(first, error.traceback), isTrue);
      expect(identical(first, error.traceback), isTrue);
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

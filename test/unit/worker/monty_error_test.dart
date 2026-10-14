// The error family (lib/src/worker/monty_error.dart): which class each
// failure is, message and toString() as upstream's str(), exception() as
// upstream's, the crash fields, and upstream's checks on a raised exception
// before it is rendered (raised_record.dart's RaisedRecord.checked). Upstream's
// own str() and exception() for real errors are checked in
// _display_cases.dart. Pure Dart: vm, dart2js and dart2wasm.
import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/raised_record.dart';
import 'package:test/test.dart';

import '../../_accessors.dart';

/// A frame on [line], from [start] to [end], with [preview] if given.
pb.StackFrame _frame({
  int line = 1,
  int start = 1,
  int end = 2,
  int? endLine,
  String? preview,
  bool hasStart = true,
  bool hasEnd = true,
}) => pb.StackFrame(
  filename: 'main.py',
  start: hasStart ? pb.CodeLoc(line: line, column: start) : null,
  end: hasEnd ? pb.CodeLoc(line: endLine ?? line, column: end) : null,
  frameName: '<module>',
  previewLine: preview,
);

MontyError _raised(
  String type, [
  String? message,
  List<pb.StackFrame> traceback = const [],
]) => raisedError(
  pb.RaisedException(excType: type, message: message, traceback: traceback),
);

/// A protocol violation with upstream's text for an invalid exception.
Matcher _invalid(String detail) => isA<MontyCrashedError>()
    .having((e) => e.cause, 'cause', CrashCause.protocol)
    .having(
      (e) => e.message,
      'message',
      'monty worker protocol error: invalid exception payload: $detail',
    )
    .having((e) => e.timedOut, 'timedOut', isFalse)
    .having((e) => e.exitStatus, 'exitStatus', isNull);

void main() {
  group('which class', () {
    test('a SyntaxError is MontySyntaxError, any other MontyRuntimeError', () {
      expect(_raised('SyntaxError', 'bad'), isA<MontySyntaxError>());
      for (final type in ['ValueError', 'MemoryError', 'TimeoutError']) {
        expect(_raised(type, 'x'), isA<MontyRuntimeError>(), reason: type);
      }
      expect(typingError('d'), isA<MontyTypingError>());
      expect(crashedError(CrashCause.vanished), isA<MontyCrashedError>());
    });

    test('every one is a MontyError and an Exception, not an Error', () {
      for (final error in [
        _raised('SyntaxError'),
        _raised('ValueError'),
        typingError(''),
        crashedError(CrashCause.killed),
        protocolError('x'),
      ]) {
        expect(error, isA<Exception>());
        expect(error, isNot(isA<Error>()));
      }
    });
  });

  group("message and toString() are upstream's str()", () {
    test('MontyRuntimeError: Type: message, or Type alone', () {
      for (final (message, str) in [
        ('division by zero', 'ZeroDivisionError: division by zero'),
        (null, 'ZeroDivisionError'),
        ('', 'ZeroDivisionError'),
      ]) {
        final error = _raised('ZeroDivisionError', message);
        expect(error.message, str);
        expect('$error', str);
      }
    });

    test('MontySyntaxError: the message alone', () {
      final error = _raised('SyntaxError', 'invalid syntax');
      expect(error.message, 'invalid syntax');
      expect('$error', 'invalid syntax');
      expect('${_raised('SyntaxError')}', '');
    });

    test('MontyTypingError: the rendered diagnostics', () {
      final error = typingError('main.py:1:1: error[x] y');
      expect('$error', 'main.py:1:1: error[x] y');
      expect(error.display(), 'main.py:1:1: error[x] y');
    });

    test('MontyCrashedError: what happened, framed as upstream frames it', () {
      expect(
        '${crashedError(CrashCause.fatal, detail: 'boom', exitCode: 3)}',
        'monty worker crashed: boom (exit status: 3)',
      );
      expect(
        '${crashedError(CrashCause.vanished, detail: 'EOF', exitCode: -9)}',
        'monty worker crashed while waiting for a reply (signal: 9 (SIGKILL))',
      );
      expect(
        '${crashedError(CrashCause.vanished, detail: 'trap')}',
        'monty worker crashed while waiting for a reply',
      );
      expect(
        '${crashedError(CrashCause.vanished, context: sendingRequest)}',
        'monty worker crashed while sending a request',
      );
      // A signal Rust names, and one it would not on every platform.
      expect(
        '${crashedError(CrashCause.fatal, detail: 'x', exitCode: -6)}',
        'monty worker crashed: x (signal: 6 (SIGABRT))',
      );
      expect(
        '${crashedError(CrashCause.vanished, exitCode: -10)}',
        'monty worker crashed while waiting for a reply (signal: 10)',
      );
      expect(
        '${crashedError(CrashCause.killed, detail: 'closed during a turn')}',
        'closed during a turn',
      );
      expect(
        '${protocolError('unexpected event')}',
        'monty worker protocol error: unexpected event',
      );
    });
  });

  group("exception is upstream's exception()", () {
    test('a raised exception: its type and message, absent read as empty', () {
      expect(
        _raised('KeyError', 'k').exception,
        const MontyExceptionValue(excType: 'KeyError', message: 'k'),
      );
      expect(
        _raised('ValueError').exception,
        const MontyExceptionValue(excType: 'ValueError', message: ''),
      );
      expect(
        _raised('SyntaxError').exception,
        const MontyExceptionValue(excType: 'SyntaxError', message: ''),
      );
    });

    test("a typing error's is TypeError('')", () {
      expect(
        typingError('d').exception,
        const MontyExceptionValue(excType: 'TypeError', message: ''),
      );
    });

    test("a crash's is RuntimeError with the crash's message", () {
      final crash = crashedError(CrashCause.fatal, detail: 'boom');
      expect(
        crash.exception,
        const MontyExceptionValue(
          excType: 'RuntimeError',
          message: 'monty worker crashed: boom',
        ),
      );
    });
  });

  group('MontyCrashedError fields', () {
    test('exitStatus: the exit code the OS reported, else null', () {
      expect(
        crashedError(CrashCause.vanished, exitCode: 134).exitStatus,
        134,
      );
      expect(crashedError(CrashCause.vanished, exitCode: -6).exitStatus, null);
      expect(crashedError(CrashCause.vanished).exitStatus, null);
    });

    test('a deadline kill is timedOut, with no exit status', () {
      final crash = crashedError(
        CrashCause.killed,
        detail: 'monty worker killed after exceeding request timeout of 1s',
        exitCode: 0,
        timedOut: true,
      );
      expect(crash.timedOut, isTrue);
      expect(crash.exitStatus, isNull);
      expect(crashedError(CrashCause.killed).timedOut, isFalse);
    });
  });

  group('Frame', () {
    test("upstream's fields, from the wire's frame", () {
      final error =
          _raised('ValueError', 'v', [
                _frame(line: 3, start: 5, end: 9, preview: '    raise v'),
              ])
              as MontyRuntimeError;
      final frame = onlyItem(error.traceback);
      expect(
        (
          frame.filename,
          frame.line,
          frame.column,
          frame.endLine,
          frame.endColumn,
          frame.functionName,
          frame.sourceLine,
        ),
        ('main.py', 3, 5, 3, 9, '<module>', '    raise v'),
      );
    });

    test('equality is identity, as upstream defines none', () {
      final event = pb.RaisedException(
        excType: 'ValueError',
        traceback: [_frame()],
      );
      Frame frameOf() =>
          onlyItem((raisedError(event) as MontyRuntimeError).traceback);
      final a = frameOf();
      final b = frameOf();
      expect(a == b, isFalse);
      expect(a == a, isTrue);
    });

    test('the traceback cannot be changed', () {
      final error = _raised('ValueError', 'v', [_frame()]) as MontyRuntimeError;
      expect(error.traceback.clear, throwsUnsupportedError);
    });
  });

  group("upstream's checks before a raised exception is rendered", () {
    test('an unknown exception type is a protocol violation', () {
      expect(
        _raised('NotAnExc', 'x'),
        _invalid('unknown exception type "NotAnExc"'),
      );
      // Upstream knows the dotted spellings.
      expect(_raised('json.JSONDecodeError', 'x'), isA<MontyRuntimeError>());
    });

    test('a frame with no start or no end', () {
      expect(
        _raised('ValueError', 'x', [_frame(hasStart: false)]),
        _invalid('missing required field StackFrame.start'),
      );
      expect(
        _raised('ValueError', 'x', [_frame(hasEnd: false)]),
        _invalid('missing required field StackFrame.end'),
      );
    });

    test('an end column before the start on one previewed line', () {
      expect(
        _raised('ValueError', 'x', [
          _frame(start: 5, end: 3, preview: 'abcdef'),
        ]),
        _invalid(
          'invalid value for StackFrame.end.column: 3 is before start column 5',
        ),
      );
    });

    test('an end column far past the preview line, with no allocation', () {
      expect(
        _raised('ValueError', 'x', [
          _frame(end: 1 << 30, preview: 'x'),
        ]),
        _invalid(
          'invalid value for StackFrame.end.column: 1073741824 is beyond the '
          '1-character preview line',
        ),
      );
    });

    test('2 columns past the preview are allowed, 3 are not', () {
      expect(
        _raised('ValueError', 'x', [_frame(end: 5, preview: 'abc')]),
        isA<MontyRuntimeError>(),
      );
      expect(
        _raised('ValueError', 'x', [_frame(end: 6, preview: 'abc')]),
        _invalid(
          'invalid value for StackFrame.end.column: 6 is beyond the '
          '3-character preview line',
        ),
      );
    });

    test('the preview counts characters, not UTF-16 units or bytes', () {
      // Two characters: U+00E9, and U+1F600 (two UTF-16 units).
      const preview = 'é😀';
      expect(
        _raised('ValueError', 'x', [_frame(end: 4, preview: preview)]),
        isA<MontyRuntimeError>(),
      );
      expect(
        _raised('ValueError', 'x', [_frame(end: 5, preview: preview)]),
        _invalid(
          'invalid value for StackFrame.end.column: 5 is beyond the '
          '2-character preview line',
        ),
      );
    });

    test('a span over several lines is not column-checked', () {
      final error =
          _raised('ValueError', 'x', [
                _frame(start: 9, end: 1, endLine: 3, preview: 'f(\n  1,\n)'),
              ])
              as MontyRuntimeError;
      expect(error.display(), contains('ValueError: x'));
    });

    test('a frame with no preview line is not column-checked', () {
      expect(
        _raised('ValueError', 'x', [_frame(start: 9, end: 1)]),
        isA<MontyRuntimeError>(),
      );
    });

    test("the failure names upstream's reason", () {
      expect(
        () => RaisedRecord.checked(pb.RaisedException(excType: 'Nope')),
        throwsA(
          isA<InvalidRaisedException>().having(
            (e) => '$e',
            'toString',
            'InvalidRaisedException: unknown exception type "Nope"',
          ),
        ),
      );
    });

    test('the type is checked before the frames, as upstream', () {
      expect(
        _raised('NotAnExc', 'x', [_frame(hasEnd: false)]),
        _invalid('unknown exception type "NotAnExc"'),
      );
    });
  });
}

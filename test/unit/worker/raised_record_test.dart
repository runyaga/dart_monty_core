// The traceback renderer, rule by rule, over hand-built frames: upstream's
// `Display` for `MontyException` and `StackFrame`
// (monty-types/src/exceptions.rs at the pinned tag) and pydantic-monty's
// `display()` formats. Pure Dart, so the unit and unit_web steps run it on
// the VM, dart2js and dart2wasm. The same renderer is checked against
// upstream's own output for real tracebacks in _display_cases.dart, through
// a real worker on each of them.
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/raised_record.dart';
import 'package:test/test.dart';

import '_display_fixtures.g.dart';

const _header = 'Traceback (most recent call last):\n';

/// A frame on one line of `main.py`.
TracebackFrame _frame({
  String filename = 'main.py',
  int line = 1,
  int column = 1,
  int? endColumn,
  String? name,
  String? preview,
  bool hideCaret = false,
  bool hideFrameName = false,
}) => TracebackFrame(
  filename: filename,
  startLine: line,
  startColumn: column,
  endLine: line,
  endColumn: endColumn ?? column + 1,
  frameName: name,
  previewLine: preview,
  hideCaret: hideCaret,
  hideFrameName: hideFrameName,
);

String _render(List<TracebackFrame> frames, [String? message = 'm']) =>
    RaisedRecord('ValueError', message, frames).display();

void main() {
  group('display formats', () {
    const record = RaisedRecord('KeyError', 'k', []);

    test("the default format is 'traceback'", () {
      // The explicit argument is the point of this test.
      // ignore: avoid_redundant_argument_values
      expect(record.display(), record.display('traceback'));
    });

    test("'type-msg' is `Type: message`, 'msg' the message alone", () {
      expect(record.display('type-msg'), 'KeyError: k');
      expect(record.display('msg'), 'k');
    });

    test('an unknown format is an ArgumentError with upstream text', () {
      for (final format in ['nope', '', 'Traceback', 'type_msg']) {
        expect(
          () => record.display(format),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              "Invalid display format: '$format'. Expected 'traceback', "
                  "'type-msg', or 'msg'",
            ),
          ),
        );
      }
    });

    test("the refusal's text is the oracle's", () {
      for (final f in displayFixtures) {
        expect(
          () => record.display(f.badFormat),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              f.badFormatMessage,
            ),
          ),
          reason: f.id,
        );
      }
    });
  });

  group('absent versus empty message', () {
    const absent = RaisedRecord('ValueError', null, []);
    const empty = RaisedRecord('ValueError', '', []);

    test('`Type` for an absent message, `Type: ` for an empty one', () {
      expect(absent.display('type-msg'), 'ValueError');
      expect(empty.display('type-msg'), 'ValueError: ');
      expect(absent.display(), 'ValueError');
      expect(empty.display(), 'ValueError: ');
    });

    test("'msg' is '' for both", () {
      expect(absent.display('msg'), '');
      expect(empty.display('msg'), '');
    });

    test('fromWire keeps the difference', () {
      final noMessage = RaisedRecord.fromWire(
        pb.RaisedException(excType: 'ValueError'),
      );
      final emptyMessage = RaisedRecord.fromWire(
        pb.RaisedException(excType: 'ValueError', message: ''),
      );
      expect(noMessage.message, isNull);
      expect(emptyMessage.message, '');
      expect(noMessage.display('type-msg'), 'ValueError');
      expect(emptyMessage.display('type-msg'), 'ValueError: ');
    });
  });

  group('frame lines', () {
    test('no frames: no header, only the summary', () {
      expect(_render([]), 'ValueError: m');
    });

    test('`, in <name>`, `<module>` without a name', () {
      expect(
        _render([
          _frame(name: 'f', line: 3),
          _frame(line: 9),
        ]),
        '$_header'
        '  File "main.py", line 3, in f\n'
        '  File "main.py", line 9, in <module>\n'
        'ValueError: m',
      );
    });

    test('a SyntaxError-style frame omits `, in <name>`', () {
      expect(
        _render([_frame(name: 'f', line: 2, hideFrameName: true)]),
        '$_header  File "main.py", line 2\nValueError: m',
      );
    });

    test('the filename is printed as is', () {
      expect(
        _render([_frame(filename: '<python-input-3>')]),
        '$_header  File "<python-input-3>", line 1, in <module>\n'
        'ValueError: m',
      );
    });
  });

  group('preview line and carets', () {
    test('leading whitespace stripped, carets under the span', () {
      expect(
        _render([
          _frame(preview: '    return x / 0', column: 12, endColumn: 17),
        ]),
        '$_header'
        '  File "main.py", line 1, in <module>\n'
        '    return x / 0\n'
        '           ~~~~~\n'
        'ValueError: m',
      );
    });

    // Upstream rejects a reversed span before rendering (its u32
    // subtraction would wrap); the port renders one caret, never a huge run.
    test('a zero-length or reversed span still gets one caret', () {
      for (final end in [5, 4]) {
        expect(
          _render([_frame(preview: 'x = (', column: 5, endColumn: end)]),
          contains('    x = (\n        ~\n'),
          reason: 'end column $end',
        );
      }
    });

    test('a hidden caret prints the line alone', () {
      expect(
        _render([
          _frame(
            preview: '  raise E',
            column: 3,
            endColumn: 10,
            hideCaret: true,
          ),
        ]),
        '$_header'
        '  File "main.py", line 1, in <module>\n'
        '    raise E\n'
        'ValueError: m',
      );
    });

    test('carets count characters, not bytes, after the indent', () {
      // 'é' and 'ж' are two UTF-8 bytes each; the span `1 + 'x'` starts
      // at character 11, so 4 + 11 - 1 = 14 columns of padding.
      expect(
        _render([
          _frame(preview: "s = 'éж'; 1 + 'x'", column: 11, endColumn: 18),
        ]),
        contains("    s = 'éж'; 1 + 'x'\n              ~~~~~~~\n"),
      );
    });

    group('the stripped indent is counted in UTF-8 bytes', () {
      // Upstream pads by `line.len() - line.trim_start().len()`, a byte
      // count, while the column counts characters: the padding is
      // 4 + column - indentBytes - 1, or 4 when the column is not past
      // indentBytes.
      final cases = {
        'two U+00A0 (4 bytes)': ('\u00a0\u00a0', 4),
        'one U+3000 (3 bytes)': ('\u3000', 3),
        'one U+0085 (2 bytes)': ('\u0085', 2),
        'one U+1680 (3 bytes)': ('\u1680', 3),
        'U+2000..U+200A (3 bytes each)': (
          '\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200a',
          33,
        ),
        'U+2028 U+2029 U+202F U+205F (3 bytes each)': (
          '\u2028\u2029\u202f\u205f',
          12,
        ),
        'tab, VT, FF, CR, space (1 byte each)': ('\t\x0b\x0c\r ', 5),
      };
      for (final MapEntry(key: name, value: (indent, bytes)) in cases.entries) {
        test(name, () {
          final chars = indent.runes.length;
          // The span `1 / 0` starts 5 characters into the stripped text.
          final column = chars + 5;
          final out = _render([
            _frame(
              preview: '${indent}y = 1 / 0',
              column: column,
              endColumn: column + 5,
            ),
          ]);
          final pad = column > bytes ? column - bytes + 3 : 4;
          expect(
            out,
            contains('\n    y = 1 / 0\n${' ' * pad}~~~~~\n'),
            reason: 'pad $pad',
          );
        });
      }

      test('a column inside the indent puts the carets at the margin', () {
        // Column 6 is not past the 6 bytes of indent either.
        for (final column in [1, 6]) {
          final frame = _frame(
            preview: '\u00a0\u00a0\u00a01 / 0]',
            column: column,
            endColumn: column + 1,
          );
          expect(
            _render([frame]),
            contains('\n    1 / 0]\n    ~\n'),
            reason: 'column $column',
          );
        }
      });

      test('U+FEFF is not whitespace to upstream, unlike Dart trim', () {
        expect(
          _render([_frame(preview: '\ufeffx = 1', column: 2, endColumn: 3)]),
          contains('\n    \ufeffx = 1\n     ~\n'),
        );
      });

      test('U+200B and U+180E are not whitespace either', () {
        expect(
          _render([_frame(preview: '\u200b\u180ex', column: 3, endColumn: 4)]),
          contains('\n    \u200b\u180ex\n      ~\n'),
        );
      });
    });

    test('an all-whitespace line prints empty, carets from the margin', () {
      expect(
        _render([_frame(preview: '   ', endColumn: 1)]),
        '$_header'
        '  File "main.py", line 1, in <module>\n'
        '    \n'
        '    ~\n'
        'ValueError: m',
      );
    });
  });

  group('a span over several lines', () {
    TracebackFrame multi(String preview) => TracebackFrame(
      filename: 'main.py',
      startLine: 2,
      startColumn: 5,
      endLine: 4,
      endColumn: 2,
      previewLine: preview,
    );

    test('each block line at the 4-space indent, no carets', () {
      expect(
        _render([multi("v = d[\n    'k'\n]")]),
        '$_header'
        '  File "main.py", line 2, in <module>\n'
        '    v = d[\n'
        "        'k'\n"
        '    ]\n'
        'ValueError: m',
      );
    });

    test("lines split as Rust's str::lines()", () {
      // A final line ending adds no line; `\r\n` ends a line; a lone `\r`
      // does not; an empty block has no lines.
      final cases = {
        'a\n': ['a'],
        'a\r\nb': ['a', 'b'],
        'a\rb': ['a\rb'],
        'a\r': ['a\r'],
        'a\n\n': ['a', ''],
        '\n': [''],
        '': <String>[],
        'a\n\r\n': ['a', ''],
      };
      for (final MapEntry(key: block, value: lines) in cases.entries) {
        expect(
          _render([multi(block)]),
          '$_header'
          '  File "main.py", line 2, in <module>\n'
          '${lines.map((l) => '    $l\n').join()}'
          'ValueError: m',
          reason: block,
        );
      }
    });

    test('the leading whitespace of a block line is kept', () {
      expect(
        _render([multi('  x\n\u00a0y')]),
        contains('\n      x\n    \u00a0y\n'),
      );
    });
  });

  test('no preview line: the frame line alone', () {
    expect(
      _render([_frame(name: 'f')]),
      '$_header  File "main.py", line 1, in f\nValueError: m',
    );
  });

  group('repeated frames', () {
    TracebackFrame rec({
      int line = 4,
      String? name = 'f',
      String filename = 'main.py',
      int column = 12,
    }) => _frame(
      filename: filename,
      line: line,
      name: name,
      column: column,
      endColumn: column + 3,
      preview: '    return f()',
    );

    String block(TracebackFrame f) => RaisedRecord('E', null, [
      f,
    ]).display().substring(_header.length).replaceFirst(RegExp(r'E$'), '');

    test('exactly 3 identical frames: all shown, no collapse line', () {
      final f = rec();
      expect(
        _render([f, f, f]),
        '$_header${block(f) * 3}ValueError: m',
      );
    });

    test('4 or more: 3 shown, then the rest counted', () {
      final f = rec();
      for (final n in [4, 5, 1000]) {
        expect(
          _render(List.filled(n, f)),
          '$_header${block(f) * 3}'
          '  [Previous line repeated ${n - 3} more times]\n'
          'ValueError: m',
          reason: '$n frames',
        );
      }
    });

    test('identical means filename, start line and name; not column', () {
      final a = rec();
      final b = rec(column: 3);
      final blockA = block(a);
      expect(
        _render([a, b, a, b]),
        '$_header$blockA${block(b)}$blockA'
        '  [Previous line repeated 1 more times]\n'
        'ValueError: m',
      );
      for (final other in [
        rec(line: 5),
        rec(name: 'g'),
        rec(name: null),
        rec(filename: 'other.py'),
      ]) {
        expect(
          _render([a, a, a, other]),
          isNot(contains('[Previous line')),
          reason: '${other.filename}:${other.startLine} ${other.frameName}',
        );
      }
    });

    test('runs collapse separately, around other frames', () {
      final a = rec();
      final m = rec(line: 9, name: null);
      final z = rec(line: 2, name: 'g');
      expect(
        _render([m, a, a, a, a, a, z, z, z, z]),
        '$_header${block(m)}${block(a) * 3}'
        '  [Previous line repeated 2 more times]\n'
        '${block(z) * 3}'
        '  [Previous line repeated 1 more times]\n'
        'ValueError: m',
      );
    });
  });

  group('fromWire', () {
    test('reads every frame field', () {
      final record = RaisedRecord.fromWire(
        pb.RaisedException(
          excType: 'TypeError',
          message: 'bad',
          traceback: [
            pb.StackFrame(
              filename: '<python-input-0>',
              start: pb.CodeLoc(line: 2, column: 5),
              end: pb.CodeLoc(line: 3, column: 7),
              frameName: 'f',
              previewLine: 'p',
              hideCaret: true,
              hideFrameName: true,
            ),
            pb.StackFrame(
              filename: 'x',
              start: pb.CodeLoc(line: 1, column: 1),
              end: pb.CodeLoc(line: 1, column: 2),
            ),
          ],
        ),
      );
      expect(record.excType, 'TypeError');
      expect(record.message, 'bad');
      final [a, b] = record.traceback;
      expect(
        [
          a.filename,
          a.startLine,
          a.startColumn,
          a.endLine,
          a.endColumn,
          a.frameName,
          a.previewLine,
          a.hideCaret,
          a.hideFrameName,
        ],
        ['<python-input-0>', 2, 5, 3, 7, 'f', 'p', true, true],
      );
      expect(
        [b.frameName, b.previewLine, b.hideCaret, b.hideFrameName],
        [null, null, false, false],
      );
    });

    test('an empty frame name or preview line is kept, not dropped', () {
      final [frame] = RaisedRecord.fromWire(
        pb.RaisedException(
          excType: 'E',
          traceback: [
            pb.StackFrame(
              filename: 'x',
              start: pb.CodeLoc(line: 1, column: 1),
              end: pb.CodeLoc(line: 1, column: 1),
              frameName: '',
              previewLine: '',
            ),
          ],
        ),
      ).traceback;
      expect(frame.frameName, '');
      expect(frame.previewLine, '');
    });
  });
}

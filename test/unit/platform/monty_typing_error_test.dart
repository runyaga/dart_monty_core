// Unit tests for MontyTypingError JSON parsing — pure value-level.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

const _singleDiagnosticJson = '''
[
  {
    "cell": null,
    "code": "invalid-assignment",
    "end_location": {"column": 33, "row": 114},
    "filename": "/main.py",
    "fix": null,
    "location": {"column": 12, "row": 114},
    "message": "Object of type `None` is not assignable to `list[Unknown]`",
    "noqa_row": null,
    "url": "https://ty.dev/rules#invalid-assignment"
  }
]
''';

void main() {
  group('MontyTypingError.fromJson', () {
    test('parses every documented field', () {
      final list = MontyTypingError.listFromJson(_singleDiagnosticJson);
      expect(list, hasLength(1));

      final e = list.single;
      expect(e.code, 'invalid-assignment');
      expect(
        e.message,
        'Object of type `None` is not assignable to `list[Unknown]`',
      );
      expect(e.path, '/main.py');
      expect(e.line, 114);
      expect(e.column, 12);
      expect(e.endLine, 114);
      expect(e.endColumn, 33);
      expect(e.url, 'https://ty.dev/rules#invalid-assignment');
    });

    test('toString summarises with location and code', () {
      final e = MontyTypingError.listFromJson(_singleDiagnosticJson).single;
      expect(
        e.toString(),
        'MontyTypingError(invalid-assignment at /main.py:114:12: '
        'Object of type `None` is not assignable to `list[Unknown]`)',
      );
    });

    test('handles missing optional fields gracefully', () {
      const json = '''
      [{"code": "x", "message": "y"}]
      ''';
      final e = MontyTypingError.listFromJson(json).single;
      expect(e.code, 'x');
      expect(e.message, 'y');
      expect(e.path, isNull);
      expect(e.line, isNull);
      expect(e.column, isNull);
      expect(e.url, isNull);
    });
  });

  group('MontyTypingError.listFromJson', () {
    test('returns empty list for null input', () {
      expect(MontyTypingError.listFromJson(null), isEmpty);
    });

    test('returns empty list for empty string', () {
      expect(MontyTypingError.listFromJson(''), isEmpty);
    });

    test('returns empty list for empty JSON array', () {
      expect(MontyTypingError.listFromJson('[]'), isEmpty);
    });

    test('skips non-object entries silently', () {
      const json = '[1, "string", null, {"code": "ok", "message": "kept"}]';
      final list = MontyTypingError.listFromJson(json);
      expect(list, hasLength(1));
      expect(list.single.code, 'ok');
    });

    test('preserves order of multiple diagnostics', () {
      const json = '''
      [
        {"code": "a", "message": "first"},
        {"code": "b", "message": "second"}
      ]
      ''';
      final list = MontyTypingError.listFromJson(json);
      expect(list.map((e) => e.code), ['a', 'b']);
    });
  });
}

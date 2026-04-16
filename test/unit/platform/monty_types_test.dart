// Unit tests for supporting value types: MontyResult, MontyException,
// MontyLimits, MontyResourceUsage, and MontyError subclasses.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

// Shared zero-usage sub-map used across MontyResult tests.
const _zeroUsage = {
  'memory_bytes_used': 0,
  'time_elapsed_ms': 0,
  'stack_depth_used': 0,
};

void main() {
  // -------------------------------------------------------------------------
  group('MontyResult', () {
    test('isError false when error is null', () {
      final r = MontyResult.fromJson(const {
        'value': 42,
        'error': null,
        'usage': _zeroUsage,
      });
      expect(r.isError, isFalse);
      expect(r.error, isNull);
    });

    test('isError true when error present', () {
      final r = MontyResult.fromJson(const {
        'value': null,
        'error': {'message': 'bad', 'exc_type': 'TypeError'},
        'usage': _zeroUsage,
      });
      expect(r.isError, isTrue);
      expect(r.error, isNotNull);
    });

    test('value is deserialized', () {
      final r = MontyResult.fromJson(const {
        'value': 'hello',
        'error': null,
        'usage': _zeroUsage,
      });
      expect(r.value, equals(const MontyString('hello')));
    });

    test('printOutput captured when present', () {
      final r = MontyResult.fromJson(const {
        'value': null,
        'error': null,
        'usage': _zeroUsage,
        'print_output': 'line1\nline2',
      });
      expect(r.printOutput, 'line1\nline2');
    });

    test('printOutput null when absent', () {
      final r = MontyResult.fromJson(const {
        'value': null,
        'error': null,
        'usage': _zeroUsage,
      });
      expect(r.printOutput, isNull);
    });

    test('usage fields populated', () {
      final r = MontyResult.fromJson(const {
        'value': null,
        'error': null,
        'usage': {
          'memory_bytes_used': 2048,
          'time_elapsed_ms': 15,
          'stack_depth_used': 8,
        },
      });
      expect(r.usage.memoryBytesUsed, 2048);
      expect(r.usage.timeElapsedMs, 15);
      expect(r.usage.stackDepthUsed, 8);
    });
  });

  // -------------------------------------------------------------------------
  group('MontyException', () {
    test('message only — toString format', () {
      const e = MontyException(message: 'something went wrong');
      expect(e.toString(), 'MontyException: something went wrong');
    });

    test('with excType — toString prefixes type', () {
      const e = MontyException(
        message: 'bad value',
        excType: 'ValueError',
      );
      expect(e.toString(), contains('ValueError'));
      expect(e.toString(), contains('bad value'));
    });

    test('with filename and line — toString includes location', () {
      const e = MontyException(
        message: 'oops',
        filename: 'script.py',
        lineNumber: 10,
        columnNumber: 5,
      );
      final s = e.toString();
      expect(s, contains('script.py'));
      expect(s, contains('10'));
    });

    test('all location fields present', () {
      const e = MontyException(
        message: 'err',
        excType: 'RuntimeError',
        filename: 'f.py',
        lineNumber: 3,
        columnNumber: 1,
        sourceCode: 'bad()',
      );
      final s = e.toString();
      expect(s, contains('RuntimeError'));
      expect(s, contains('f.py'));
    });

    test('fromJson minimal', () {
      final e = MontyException.fromJson(const {'message': 'hello'});
      expect(e.message, 'hello');
      expect(e.excType, isNull);
      expect(e.filename, isNull);
      expect(e.traceback, isEmpty);
    });

    test('fromJson with excType', () {
      final e = MontyException.fromJson(const {
        'message': 'err',
        'exc_type': 'KeyError',
      });
      expect(e.excType, 'KeyError');
    });
  });

  // -------------------------------------------------------------------------
  group('MontyLimits', () {
    test('fully null serializes to empty map', () {
      const limits = MontyLimits();
      final json = limits.toJson();
      expect(json, isEmpty);
    });

    test('only set fields appear in JSON', () {
      const limits = MontyLimits(timeoutMs: 5000);
      final json = limits.toJson();
      expect(json.containsKey('timeout_ms'), isTrue);
      expect(json['timeout_ms'], 5000);
      expect(json.containsKey('memory_bytes'), isFalse);
      expect(json.containsKey('stack_depth'), isFalse);
    });

    test('all fields present when all set', () {
      const limits = MontyLimits(
        memoryBytes: 1024,
        timeoutMs: 1000,
        stackDepth: 50,
      );
      final json = limits.toJson();
      expect(json['memory_bytes'], 1024);
      expect(json['timeout_ms'], 1000);
      expect(json['stack_depth'], 50);
    });
  });

  // -------------------------------------------------------------------------
  group('MontyResourceUsage', () {
    test('fields stored correctly', () {
      const u = MontyResourceUsage(
        memoryBytesUsed: 100,
        timeElapsedMs: 50,
        stackDepthUsed: 10,
      );
      expect(u.memoryBytesUsed, 100);
      expect(u.timeElapsedMs, 50);
      expect(u.stackDepthUsed, 10);
    });
  });

  // -------------------------------------------------------------------------
  group('MontyError', () {
    test('MontyScriptError is a MontyError', () {
      const e = MontyScriptError(
        'script failed',
        exception: MontyException(message: 'fail'),
      );
      expect(e, isA<MontyError>());
    });

    test('MontyScriptError toString', () {
      const e = MontyScriptError('script failed');
      expect(e.toString(), contains('script failed'));
    });

    test('MontyPanicError is a MontyError', () {
      const e = MontyPanicError('panic!');
      expect(e, isA<MontyError>());
      expect(e.toString(), contains('panic!'));
    });

    test('MontyCrashError is a MontyError', () {
      const e = MontyCrashError('crash');
      expect(e, isA<MontyError>());
    });

    test('MontyDisposedError is a MontyError', () {
      const e = MontyDisposedError('disposed');
      expect(e, isA<MontyError>());
    });

    test('MontyResourceError is a MontyError', () {
      const e = MontyResourceError('OOM');
      expect(e, isA<MontyError>());
    });

    test('all subclasses caught by MontyError catch block', () {
      const errors = <MontyError>[
        MontyScriptError('a'),
        MontyPanicError('b'),
        MontyCrashError('c'),
        MontyDisposedError('d'),
        MontyResourceError('e'),
      ];
      for (final e in errors) {
        var caught = false;
        try {
          throw e;
        } on MontyError {
          caught = true;
        }
        expect(caught, isTrue, reason: '${e.runtimeType} not caught');
      }
    });
  });
}

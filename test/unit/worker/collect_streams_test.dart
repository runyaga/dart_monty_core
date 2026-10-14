// The print collectors called directly: upstream's CollectStreams and
// CollectString (monty-python/src/print_target.rs and
// monty-types/src/io.rs at v1.1.0). The same collectors as a session's
// print sink are checked against upstream's recorded outcomes in
// _print_cases.dart. Pure Dart: vm, dart2js and dart2wasm.
import 'dart:math' as math;

import 'package:dart_monty_core/src/worker/collect_streams.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:test/test.dart';

/// Upstream's `DEFAULT_MAX_PRINT_COLLECT_BYTES`.
const int _defaultCap = 10 * 1024 * 1024;

/// The [MontyRuntimeError] a collector's overflow is: upstream's
/// `MemoryError` with `memory limit exceeded: <used> bytes > <limit> bytes`.
Matcher _overflow(int used, int limit) => isA<MontyRuntimeError>()
    .having((e) => e.exception.excType, 'excType', 'MemoryError')
    .having(
      (e) => e.exception.message,
      'exception message',
      'memory limit exceeded: $used bytes > $limit bytes',
    )
    .having(
      (e) => e.display('type-msg'),
      "display('type-msg')",
      'MemoryError: memory limit exceeded: $used bytes > $limit bytes',
    )
    .having((e) => e.traceback, 'traceback', isEmpty);

Matcher _argumentError(String name, String message) => isA<ArgumentError>()
    .having((e) => e.name, 'name', name)
    .having((e) => e.message, 'message', message);

void main() {
  group('CollectStreams', () {
    test('starts empty', () {
      final c = CollectStreams();
      expect(c.output, isEmpty);
      expect('$c', 'CollectStreams(output=[])');
    });

    test('keeps each fragment as its own (stream, text) entry, in order, '
        'unchanged', () {
      final c = CollectStreams()
        ..call('stdout', 'a')
        ..call('stdout', 'b\n')
        ..call('stderr', '')
        ..call('stdout', ' c ');
      expect(c.output, [
        ('stdout', 'a'),
        ('stdout', 'b\n'),
        ('stderr', ''),
        ('stdout', ' c '),
      ]);
    });

    test('output is a fresh list each read: changing one does not reach the '
        'collector, and a later call does not reach one already read', () {
      final c = CollectStreams()..call('stdout', 'a');
      final first = c.output..add(('stderr', 'mine'));
      expect(c.output, [('stdout', 'a')]);
      c.call('stderr', 'b');
      expect(first, [('stdout', 'a'), ('stderr', 'mine')]);
      expect(c.output, [('stdout', 'a'), ('stderr', 'b')]);
      first.clear();
      expect(c.output, hasLength(2));
    });

    test('charges UTF-8 bytes plus 64 per entry; equal to the cap is '
        'accepted', () {
      // 1 + 64, 2 + 64 (é), 4 + 64 (an astral character).
      final c = CollectStreams(maxBytes: 65 + 66 + 68)
        ..call('stdout', 'x')
        ..call('stdout', 'é')
        ..call('stderr', '\u{1F600}');
      expect(c.output, hasLength(3));
      expect(
        () => c.call('stdout', ''),
        throwsA(_overflow(65 + 66 + 68 + 64, 65 + 66 + 68)),
      );
    });

    test('an overflow refuses the whole fragment and charges nothing', () {
      final c = CollectStreams(maxBytes: 200)..call('stdout', 'a');
      expect(
        () => c.call('stdout', 'x' * 100),
        throwsA(_overflow(65 + 100 + 64, 200)),
      );
      expect(c.output, [('stdout', 'a')]);
      // The refused fragment was not charged: 65 + 71 + 64 = 200 fits.
      c.call('stderr', 'y' * 71);
      expect(c.output, hasLength(2));
    });

    test('maxBytes 0 refuses even an empty fragment (its 64 bytes)', () {
      final c = CollectStreams(maxBytes: 0);
      expect(() => c.call('stdout', ''), throwsA(_overflow(64, 0)));
      expect(c.output, isEmpty);
    });

    test('the default cap is 10 MiB', () {
      final c = CollectStreams()..call('stdout', 'x' * (_defaultCap - 64));
      expect(
        () => c.call('stdout', ''),
        throwsA(_overflow(_defaultCap + 64, _defaultCap)),
      );
      expect(c.output, hasLength(1));
    });

    test('maxBytes null has no cap', () {
      final c = CollectStreams(maxBytes: null)
        ..call('stdout', 'x' * _defaultCap)
        ..call('stdout', 'y');
      expect(c.output, hasLength(2));
    });

    test('a stream other than stdout or stderr is an ArgumentError, and '
        'nothing is kept or charged', () {
      final c = CollectStreams(maxBytes: 64);
      for (final stream in ['stdin', 'STDOUT', '', 'stdout ']) {
        expect(
          () => c.call(stream, 'x'),
          throwsA(_argumentError('stream', "must be 'stdout' or 'stderr'")),
        );
      }
      expect(c.output, isEmpty);
      c.call('stderr', '');
      expect(c.output, [('stderr', '')]);
    });

    test('toString is upstream repr: CollectStreams(output=<list repr>)', () {
      final c = CollectStreams()
        ..call('stdout', "it's")
        ..call('stderr', 'q\'"\\\x00\té\u{1F600} \n');
      expect(
        '$c',
        'CollectStreams(output=[(\'stdout\', "it\'s"), '
            '(\'stderr\', \'q\\\'"\\\\\\x00\\té\u{1F600}\\u2028\\n\')])',
      );
    });

    test('a negative maxBytes is an ArgumentError', () {
      expect(
        () => CollectStreams(maxBytes: -1),
        throwsA(
          _argumentError('maxBytes', "can't convert negative int to unsigned"),
        ),
      );
    });

    test(
      'a maxBytes of 2^64 or more, which only dart2js holds, is an '
      'ArgumentError',
      () {
        expect(
          () => CollectStreams(maxBytes: math.pow(2, 64).toInt()),
          throwsA(_argumentError('maxBytes', 'int too big to convert')),
        );
      },
      skip: identical(1, 1.0) ? false : 'an int below 2^64 off dart2js',
    );
  });

  group('CollectString', () {
    test('starts empty', () {
      final c = CollectString();
      expect(c.output, '');
      expect('$c', "CollectString(output='')");
    });

    test('concatenates both streams in order, adding nothing', () {
      final c = CollectString()
        ..call('stdout', 'a')
        ..call('stderr', 'b\n')
        ..call('stdout', '')
        ..call('stdout', 'c');
      expect(c.output, 'ab\nc');
      // Reading does not drain.
      expect(c.output, 'ab\nc');
    });

    test('charges the UTF-8 bytes of the whole text; equal to the cap is '
        'accepted', () {
      final c = CollectString(maxBytes: 7)
        ..call('stdout', 'x')
        ..call('stdout', 'é')
        ..call('stderr', '\u{1F600}');
      expect(c.output, 'xé\u{1F600}');
      // An empty fragment adds nothing, so it fits a full collector.
      c.call('stdout', '');
      expect(() => c.call('stdout', 'y'), throwsA(_overflow(8, 7)));
      expect(c.output, 'xé\u{1F600}');
    });

    test('an overflow refuses the whole fragment', () {
      final c = CollectString(maxBytes: 5)..call('stdout', 'abc');
      expect(() => c.call('stdout', 'def'), throwsA(_overflow(6, 5)));
      expect(c.output, 'abc');
      c.call('stdout', 'de');
      expect(c.output, 'abcde');
    });

    test('the default cap is 10 MiB', () {
      final c = CollectString()..call('stdout', 'x' * _defaultCap);
      expect(
        () => c.call('stdout', 'y'),
        throwsA(_overflow(_defaultCap + 1, _defaultCap)),
      );
      expect(c.output, hasLength(_defaultCap));
    });

    test('maxBytes null has no cap', () {
      final c = CollectString(maxBytes: null)
        ..call('stdout', 'x' * _defaultCap)
        ..call('stdout', 'y');
      expect(c.output, hasLength(_defaultCap + 1));
    });

    test('a stream other than stdout or stderr is an ArgumentError, and '
        'nothing is kept', () {
      final c = CollectString();
      expect(
        () => c.call('stdin', 'x'),
        throwsA(_argumentError('stream', "must be 'stdout' or 'stderr'")),
      );
      expect(c.output, '');
    });

    test('toString is upstream repr: CollectString(output=<str repr>)', () {
      final c = CollectString()..call('stdout', 'q\'"\\\x00\té\n');
      expect(
        '$c',
        'CollectString(output=\'q\\\'"\\\\\\x00\\té\\n\')',
      );
      expect(
        '${CollectString()..call('stdout', "it's")}',
        'CollectString(output="it\'s")',
      );
    });

    test('a negative maxBytes is an ArgumentError', () {
      expect(
        () => CollectString(maxBytes: -1),
        throwsA(
          _argumentError('maxBytes', "can't convert negative int to unsigned"),
        ),
      );
    });
  });
}

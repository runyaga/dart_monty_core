// The wire-decode refusals, and the renderers that describe what came back.
//
// Off the gate's own coverage/honest.info. Four FormatException arms in
// monty_value_structured.dart -- 209-212, 224-227, 550-553, 710 -- had never
// run, and eight toString() overrides across the structured and datetime value
// types had never been called.
//
// The refusals are what stop a malformed engine envelope from becoming a
// confusing failure further in. Untested, the message or the exception type
// can be wrong and nothing says so; the first person to find out is whoever is
// staring at a bad decode.
//
// The renderers are the other half of that: they are what a failed `expect`
// prints. A value type whose toString falls back to "Instance of
// 'MontyTimeDelta'" turns every assertion failure about it into a guess.
@TestOn('vm')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  group('malformed envelopes are REFUSED, with the field named', () {
    test('class_instance attrs that are not a dict envelope', () {
      expect(
        () => MontyValue.fromJson({
          '__type': 'class_instance',
          'class_type': {'name': 'C', 'id': 'C#1'},
          'instance_id': 'i1',
          // A bare scalar: MontyInt encodes as plain `3`, so this decodes to
          // a MontyInt and falls through to the refusal arm.
          'attrs': 3,
        }),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('attrs'), contains('dict envelope')),
          ),
        ),
      );
    });

    test('attribute names that are not strings', () {
      // Python guarantees string attribute names; an envelope that carries an
      // int key is the engine contradicting itself, and the decoder has to say
      // so rather than silently stringify.
      expect(
        () => MontyValue.fromJson({
          '__type': 'class_instance',
          'class_type': {'name': 'C', 'id': 'C#1'},
          'instance_id': 'i1',
          // The `entries` form carries arbitrary keys, which is exactly how a
          // non-string attribute name can reach the decoder at all.
          'attrs': {
            '__type': 'dict',
            'entries': [
              [1, 2],
            ],
          },
        }),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('attribute names'), contains('strings')),
          ),
        ),
      );
    });

    test('a dataclass type_id that is not a number', () {
      // NOT defaulted. The Rust decoder derives class identity from type_id,
      // so a Dart-side default produces a value Dart accepts and Rust rejects
      // -- the asymmetry the source comment records.
      expect(
        () => MontyValue.fromJson({
          '__type': 'dataclass',
          'name': 'D',
          'type_id': 'not-a-number',
          'attrs': null,
        }),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('type_id'), contains('number')),
          ),
        ),
      );
    });
  });

  group('every structured/datetime value renders its own state', () {
    // TABLE-DRIVEN over the eight renderers that had never run. Each case
    // asserts the TYPE NAME and at least one distinguishing field, because a
    // toString that printed only the class name would still "work" and would
    // still be useless in a failure message.
    final cases = <String, (MontyValue, List<String>)>{
      'MontyFileHandle': (
        const MontyFileHandle(path: '/tmp/f', mode: 'r', position: 7),
        ['MontyFileHandle', '/tmp/f', 'r', '7'],
      ),
      'MontyTimeDelta': (
        const MontyTimeDelta(days: 2, seconds: 30, microseconds: 5),
        ['MontyTimeDelta', '2', '30'],
      ),
      'MontyTimeZone': (
        const MontyTimeZone(offsetSeconds: 3600, name: 'CET'),
        ['MontyTimeZone', '3600', 'CET'],
      ),
      'MontyTime': (
        const MontyTime(hour: 13, minute: 5, second: 9, microsecond: 1),
        ['MontyTime', '13', '5', '9'],
      ),
    };

    for (final entry in cases.entries) {
      final name = entry.key;
      final (value, fragments) = entry.value;
      test('$name.toString names itself and its fields', () {
        final rendered = value.toString();
        expect(
          rendered,
          allOf([startsWith(name), ...fragments.map(contains)]),
          reason: '$name.toString must carry its fields: $rendered',
        );
      });
    }

    test('MontyDateTime renders a readable ISO-ish instant', () {
      // Zero-padded deliberately: '2026-09-07T05:04:03' sorts and reads; the
      // un-padded form does neither.
      expect(
        const MontyDateTime(
          year: 2026,
          month: 9,
          day: 7,
          hour: 5,
          minute: 4,
          second: 3,
        ).toString(),
        'MontyDateTime(2026-09-07T05:04:03)',
      );
    });
  });
}

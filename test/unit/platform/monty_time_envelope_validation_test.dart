// A `time` envelope with a PRESENT but WRONG-TYPED optional field must be
// rejected, not silently accepted.
//
// `MontyTime._fromMap` guards both nullable fields
// (monty_value_datetime.dart:316-328), and the comment above them records why:
//
//     "REQUIRED fields are required. This was `?? 0` on every one of them, and
//      review caught it: a malformed `time` envelope silently parsed as
//      MIDNIGHT. That is the exact silent-default hazard removed from the Rust
//      decoder and then from MontyClassInstance earlier the same day."
//
// The guards were added; no test was ever written for them. Found by a NEW
// mutation family -- disabling a validation guard by rewriting its condition to
// `false`. The ten operator-replacement rules used earlier in this survey
// cannot express that shape. Measured: with either guard disabled, the full
// unit suite AND the full FFI integration suite both stayed green.
//
// `absent`, `null` and `present-but-wrong-typed` are three different things.
// Absent and null are legitimate -- a naive time carries neither offset nor
// zone -- which is exactly why a wrong TYPE must not be folded in with them.
//
// Falsifier: rewrite either guard's condition to `false`; only this file fails.
@Tags(['unit'])
library;

import 'dart:convert';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  group('time envelope rejects present-but-wrong-typed optionals', () {
    Map<String, Object?> timeWith(Map<String, Object?> extra) => {
      '__type': 'time',
      'hour': 1,
      'minute': 2,
      'second': 3,
      'microsecond': 4,
      'fold': 0,
      ...extra,
    };

    test('offset_seconds as a STRING is a FormatException', () {
      expect(
        () => MontyValue.fromJson(timeWith({'offset_seconds': '3600'})),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('offset_seconds must be a number or null'),
          ),
        ),
      );
    });

    test('timezone_name as a NUMBER is a FormatException', () {
      expect(
        () => MontyValue.fromJson(timeWith({'timezone_name': 7})),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('timezone_name must be a string or null'),
          ),
        ),
      );
    });

    // The other two of the three states must still be accepted, or the guards
    // would be over-strict in a way no mutant would reveal.
    test('ABSENT and NULL are both still accepted', () {
      final absent = MontyValue.fromJson(timeWith({})) as MontyTime;
      expect(absent.offsetSeconds, isNull);
      expect(absent.timezoneName, isNull);

      final explicitNull = MontyValue.fromJson(
        timeWith({'offset_seconds': null, 'timezone_name': null}),
      );
      expect(explicitNull, absent, reason: 'null and absent must agree');
    });

    test('the rejection names the offending type, not just "invalid"', () {
      try {
        MontyValue.fromJson(timeWith({'offset_seconds': <int>[]}));
        fail('expected a FormatException');
      } on FormatException catch (e) {
        // MEASURED -- the runtime type text differs by backend, and asserting
        // the VM spelling made this red on the web:
        //     vm   -> "got List<int>"
        //     web  -> "got JSArray<int>"
        // The portable claim is that the message names the ELEMENT TYPE it
        // actually received, not the container's backend-specific name.
        expect(
          e.message,
          contains('<int>'),
          reason:
              'check_no_vague_errors.sh exists because a diagnostic that '
              'does not name what was wrong is not a diagnostic',
        );
        expect(json.decode(e.source! as String), isA<Map<String, Object?>>());
      }
    });
  });
}

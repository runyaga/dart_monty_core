// Spec tests for structured exception data on the wire: what the host sends
// for an answered json.JSONDecodeError, what it reads from a worker's
// Unicode and JSON payloads, the 64 KiB limits (measured in UTF-8 bytes), and
// that a dropped payload keeps the raised type and message. Each test name
// starts with the requirement id it asserts, so a mutation run can select it
// with `-N 'REQ-<id>:'`. Pure Dart: vm, dart2js and dart2wasm.
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/arena_reader.dart';
import 'package:dart_monty_core/src/worker/arena_writer.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/raised_record.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

import '../../_accessors.dart';
import '_spec_codec_support.dart';

const int _limit = 64 * 1024;

/// A well-formed set of json.JSONDecodeError attributes.
Map<String, MontyValue> _attrs({
  Map<String, MontyValue?> override = const {},
}) {
  final base = <String, MontyValue>{
    'msg': const MontyString('Expecting value'),
    'doc': const MontyString('{"a": x}'),
    'pos': const MontyInt(6),
    'lineno': const MontyInt(1),
    'colno': const MontyInt(7),
  };
  for (final MapEntry(:key, :value) in override.entries) {
    if (value == null) {
      base.remove(key);
    } else {
      base[key] = value;
    }
  }

  return base;
}

pb.RaisedException _host(Map<String, MontyValue> attributes) =>
    raisedException('json.JSONDecodeError', 'boom', attributes);

/// An inbound Unicode error carrying [data].
MontyError _inbound(String type, pb.ExcData? data) => raisedError(
  pb.RaisedException(excType: type, message: 'boom', data: data),
);

pb.ExcData _unicodeStr({
  String object = 'abc',
  String encoding = 'utf-8',
  String reason = 'because',
  int start = 0,
  int end = 1,
}) => pb.ExcData(
  unicode: pb.UnicodeErrorData(
    encoding: encoding,
    objectStr: object,
    start: Int64(start),
    end: Int64(end),
    reason: reason,
  ),
);

pb.ExcData _unicodeBytes(List<int> object, {int start = 0, int end = 1}) =>
    pb.ExcData(
      unicode: pb.UnicodeErrorData(
        encoding: 'utf-8',
        objectBytes: object,
        start: Int64(start),
        end: Int64(end),
        reason: 'invalid start byte',
      ),
    );

/// Whether [error] kept a structured payload.
bool _kept(MontyError error) => error.exception.attributes.isNotEmpty;

/// The type and message [error] renders with, as the worker raised them.
String _rendered(MontyError error) => switch (error) {
  final MontyRuntimeError e => e.display('type-msg'),
  final MontySyntaxError e => e.display('type-msg'),
  _ => fail('not a raised error'),
};

void main() {
  group('the host sends JSON error data only when every field is usable', () {
    test(
      'REQ-ExternalException-14: missing, mistyped or surrogate: dropped',
      () {
        expect(_host(_attrs()).hasData(), isTrue);
        final bad = <String, MontyValue?>{
          'msg': null,
          'doc': null,
          'pos': null,
          'lineno': null,
          'colno': null,
        };
        for (final key in bad.keys) {
          expect(
            () => _host(_attrs(override: {key: null})),
            returnsNormally,
            reason: key,
          );
          expect(
            _host(_attrs(override: {key: null})).hasData(),
            isFalse,
            reason: 'missing $key',
          );
        }
        for (final (key, value) in <(String, MontyValue)>[
          ('msg', const MontyInt(1)),
          ('doc', const MontyBytes([1])),
          ('pos', const MontyString('6')),
          ('lineno', const MontyFloat(1)),
          ('colno', const MontyNone()),
          ('msg', const MontyString('bad\uD800')),
          ('doc', const MontyString('\uDC00 lone')),
        ]) {
          final raised = _host(_attrs(override: {key: value}));
          expect(raised.hasData(), isFalse, reason: '$key: $value');
          expect(raised.excType, 'json.JSONDecodeError');
        }
      },
    );

    test(
      'REQ-snapshots-and-futures-16: a surrogate in msg or doc: no payload',
      () {
        for (final key in ['msg', 'doc']) {
          for (final text in ['\uD800', 'a\uD83Dz', '\uDE00']) {
            final raised = _host(_attrs(override: {key: MontyString(text)}));
            expect(raised.hasData(), isFalse, reason: '$key $text');
          }
          // A paired surrogate (an astral character) is fine.
          expect(
            _host(
              _attrs(override: {key: const MontyString('x\u{1F600}')}),
            ).hasData(),
            isTrue,
            reason: key,
          );
        }
      },
    );

    test('REQ-snapshots-and-futures-15: the usable value types', () {
      String pos(MontyValue v) {
        final raised = _host(_attrs(override: {'pos': v}));

        return raised.hasData()
            ? raised.data.json.pos.toStringUnsigned()
            : 'dropped';
      }

      expect(pos(const MontyBool(true)), '1');
      expect(pos(const MontyBool(false)), '0');
      expect(pos(const MontyInt(0)), '0');
      expect(pos(const MontyInt(41)), '41');
      expect(pos(MontyBigInt(BigInt.one << 63)), '9223372036854775808');
      expect(
        pos(MontyBigInt((BigInt.one << 64) - BigInt.one)),
        '18446744073709551615',
      );
      expect(pos(MontyBigInt(BigInt.one << 64)), 'dropped');
      expect(pos(MontyBigInt(-BigInt.one)), 'dropped');
      expect(pos(const MontyInt(-1)), 'dropped');
      expect(pos(const MontyFloat(1)), 'dropped');
      expect(pos(const MontyString('1')), 'dropped');
      // The same rule for lineno and colno.
      for (final key in ['lineno', 'colno']) {
        final ok = _host(_attrs(override: {key: const MontyBool(true)}));
        expect(ok.hasData(), isTrue, reason: key);
        final no = _host(_attrs(override: {key: const MontyInt(-2)}));
        expect(no.hasData(), isFalse, reason: key);
      }
      // Only json.JSONDecodeError carries structured data.
      expect(
        raisedException('ValueError', 'm', _attrs()).hasData(),
        isFalse,
      );
    });

    test('REQ-wire-limits-22: each required attribute decides alone', () {
      for (final key in ['msg', 'doc', 'pos', 'lineno', 'colno']) {
        expect(
          _host(_attrs(override: {key: null})).hasData(),
          isFalse,
          reason: 'missing $key',
        );
      }
      // lineno and colno in particular: missing, then mistyped.
      for (final key in ['lineno', 'colno']) {
        expect(
          _host(_attrs(override: {key: const MontyString('1')})).hasData(),
          isFalse,
          reason: 'mistyped $key',
        );
        expect(
          _host(_attrs(override: {key: const MontyNone()})).hasData(),
          isFalse,
          reason: 'none $key',
        );
      }
      final all = _host(_attrs());
      final json = all.data.json;
      expect(json.lineno, Int64.ONE);
      expect(json.colno, Int64(7));
    });

    test(
      'REQ-errors-and-tracebacks-47: a dropped payload keeps type, message',
      () {
        final raised = _host(
          _attrs(override: {'colno': const MontyString('x')}),
        );
        expect(raised.hasData(), isFalse);
        expect(raised.excType, 'json.JSONDecodeError');
        expect(raised.message, 'boom');

        // Inbound: a payload of the wrong kind is dropped; the raised type and
        // message still render.
        final error = _inbound('UnicodeDecodeError', _unicodeStr());
        expect(error.exception.excType, 'ValueError');
        expect(error.exception.message, 'boom');
        expect(_rendered(error), 'UnicodeDecodeError: boom');
        final oversized = _inbound(
          'UnicodeEncodeError',
          _unicodeStr(object: 'x' * (_limit + 1)),
        );
        expect(_rendered(oversized), 'UnicodeEncodeError: boom');
        expect(oversized.exception.message, 'boom');
      },
    );

    test(
      'REQ-errors-and-tracebacks-34: an exception input carries no attributes',
      () {
        final value = MontyExceptionValue('UnicodeEncodeError', 'boom', const {
          'encoding': MontyString('utf-8'),
          'object': MontyString('abc'),
          'start': MontyInt(0),
          'end': MontyInt(1),
          'reason': MontyString('because'),
        });
        final writer = ArenaWriter();
        final root = writer.add(value);
        final node = itemAt(writer.arena.nodes, root).exception;
        expect(node.excType, 'UnicodeEncodeError');
        expect(node.arg, 'boom');
        // Nothing beyond the type and the message goes on the wire.
        expect(
          node.writeToBuffer(),
          pb.Exception(
            excType: 'UnicodeEncodeError',
            arg: 'boom',
          ).writeToBuffer(),
        );
        final back =
            ArenaReader(
                  pb.Arena.fromBuffer(writer.arena.writeToBuffer()),
                )[root]
                as MontyExceptionValue;
        expect(back.attributes, isEmpty);
      },
    );
  });

  group('the worker payload limits', () {
    const euro = '€'; // 3 bytes in UTF-8, 1 UTF-16 unit.

    test('REQ-wire-limits-18: an object over 64 KiB drops the payload', () {
      // A byte object is measured in bytes: exactly 64 KiB is kept.
      expect(
        _kept(
          _inbound(
            'UnicodeDecodeError',
            _unicodeBytes(Uint8List(_limit)),
          ),
        ),
        isTrue,
      );
      expect(
        _kept(
          _inbound(
            'UnicodeDecodeError',
            _unicodeBytes(Uint8List(_limit + 1)),
          ),
        ),
        isFalse,
      );
      // A str object is measured in UTF-8 bytes, not characters.
      final fits = euro * (_limit ~/ 3); // 65535 bytes
      final over = euro * (_limit ~/ 3 + 1); // 65538 bytes, 21846 characters
      // Both are under the limit in characters, one over it in bytes.
      for (final text in [fits, over]) {
        expect(text.length, lessThan(_limit));
      }
      expect(
        _kept(_inbound('UnicodeEncodeError', _unicodeStr(object: fits))),
        isTrue,
      );
      expect(
        _kept(_inbound('UnicodeEncodeError', _unicodeStr(object: over))),
        isFalse,
      );
      expect(
        _kept(
          _inbound('UnicodeEncodeError', _unicodeStr(object: 'a' * _limit)),
        ),
        isTrue,
      );
      expect(
        _kept(
          _inbound(
            'UnicodeEncodeError',
            _unicodeStr(object: 'a' * (_limit + 1)),
          ),
        ),
        isFalse,
      );
    });

    test('REQ-wire-limits-20: encoding or reason over 64 KiB drops it', () {
      final fits = euro * (_limit ~/ 3);
      final over = euro * (_limit ~/ 3 + 1);
      for (final field in ['encoding', 'reason']) {
        pb.ExcData with_(String text) => field == 'encoding'
            ? _unicodeStr(encoding: text)
            : _unicodeStr(reason: text);
        expect(
          _kept(_inbound('UnicodeEncodeError', with_(fits))),
          isTrue,
          reason: field,
        );
        final oversized = _inbound('UnicodeEncodeError', with_(over));
        expect(_kept(oversized), isFalse, reason: field);
        expect(
          _kept(_inbound('UnicodeEncodeError', with_('a' * (_limit + 1)))),
          isFalse,
          reason: field,
        );
        // Dropped whole: the other fields are gone too, the message stays.
        expect(oversized.exception.attributes, isEmpty);
        expect(_rendered(oversized), 'UnicodeEncodeError: boom');
      }
      // An oversized object in a decode error: the same rule.
      expect(
        _kept(
          _inbound('UnicodeDecodeError', _unicodeBytes(Uint8List(_limit + 1))),
        ),
        isFalse,
      );
    });

    test(
      'REQ-wire-limits-46: dropping oversized data keeps type and message',
      () {
        for (final (type, data) in [
          ('UnicodeEncodeError', _unicodeStr(object: 'a' * (_limit + 1))),
          ('UnicodeEncodeError', _unicodeStr(reason: euro * (_limit ~/ 3 + 1))),
          ('UnicodeDecodeError', _unicodeBytes(Uint8List(_limit + 1))),
        ]) {
          final raised = pb.RaisedException(
            excType: type,
            message: 'boom',
            data: data,
          );
          final record = RaisedRecord.fromWire(raised);
          expect(record.payload, isNull);
          expect(record.excType, type);
          expect(record.message, 'boom');
          // The error is still a raised one, not a protocol failure.
          final error = raisedError(raised);
          expect(error, isA<MontyRuntimeError>());
          expect(_rendered(error), '$type: boom');
        }
      },
    );

    test('REQ-wire-limits-17: a JSON error without its doc keeps the rest', () {
      // The worker leaves out a document over 64 KiB (or one without a
      // UTF-8 form) and keeps the other fields.
      final error = _inbound(
        'json.JSONDecodeError',
        pb.ExcData(
          json: pb.JsonErrorData(
            msg: 'Expecting value',
            pos: Int64(3),
            lineno: Int64(2),
            colno: Int64(5),
          ),
        ),
      );
      final attrs = error.exception.attributes;
      expect(error.exception.excType, 'json.JSONDecodeError');
      expect(attrs['msg'], const MontyString('Expecting value'));
      expect(attrs['pos'], const MontyInt(3));
      expect(attrs['lineno'], const MontyInt(2));
      expect(attrs['colno'], const MontyInt(5));
      expect(attrs['doc'], const MontyString(''));
    });
  });

  group('the Unicode payload attributes', () {
    test('REQ-MontyExceptionValue-8: UnicodeEncodeError attributes', () {
      final error = _inbound(
        'UnicodeEncodeError',
        _unicodeStr(
          object: 'héllo',
          encoding: 'ascii',
          reason: 'ordinal not in range(128)',
          start: 1,
          end: 2,
        ),
      );
      final value = error.exception;
      expect(value.excType, 'UnicodeEncodeError');
      expect(value.attributes.keys.toSet(), {
        'encoding',
        'object',
        'start',
        'end',
        'reason',
      });
      expect(value.attributes['encoding'], const MontyString('ascii'));
      expect(
        value.attributes['reason'],
        const MontyString('ordinal not in range(128)'),
      );
      expect(value.attributes['start'], const MontyInt(1));
      expect(value.attributes['end'], const MontyInt(2));
      expect(value.attributes['object'], const MontyString('héllo'));
      expect(value.attributes['start'], isInt);
      expect(value.attributes['end'], isInt);
      expect(value.attributes['object'], isString);
    });

    test('REQ-errors-and-tracebacks-30: decode and encode errors', () {
      final decode = _inbound(
        'UnicodeDecodeError',
        _unicodeBytes([0xff, 0xfe, 0x41], end: 2),
      ).exception;
      expect(decode.attributes['encoding'], const MontyString('utf-8'));
      expect(
        decode.attributes['reason'],
        const MontyString('invalid start byte'),
      );
      expect(decode.attributes['object'], isBytes);
      expect((decode.attributes['object']! as MontyBytes).value, [
        0xff,
        0xfe,
        0x41,
      ]);
      expect(decode.attributes['start'], const MontyInt(0));
      expect(decode.attributes['end'], const MontyInt(2));
      expect(decode.attributes['start'], isInt);
      expect(decode.attributes['end'], isInt);

      final encode = _inbound(
        'UnicodeEncodeError',
        _unicodeStr(object: 'xyz', start: 1, end: 3),
      ).exception;
      expect(encode.attributes['object'], isString);
      expect(encode.attributes['object'], const MontyString('xyz'));
      expect(encode.attributes['start'], const MontyInt(1));
      expect(encode.attributes['end'], const MontyInt(3));
      expect(encode.attributes['start'], isInt);
      expect(encode.attributes['end'], isInt);
      expect(encode.attributes['encoding'], isString);
      expect(encode.attributes['reason'], isString);
    });

    test(
      'REQ-MontyError-5: unusable data exposes ValueError, render keeps type',
      () {
        final frame = pb.StackFrame(
          filename: 'main.py',
          start: pb.CodeLoc(line: 1, column: 1),
          end: pb.CodeLoc(line: 1, column: 2),
          frameName: '<module>',
        );
        final wrongKind = _unicodeStr();
        for (final (type, data) in <(String, pb.ExcData?)>[
          ('UnicodeDecodeError', null),
          ('UnicodeEncodeError', null),
          ('json.JSONDecodeError', null),
          // A payload of another kind.
          ('UnicodeDecodeError', wrongKind),
          ('UnicodeEncodeError', _unicodeBytes([1])),
          ('json.JSONDecodeError', wrongKind),
          // Unusable: the span is empty.
          ('UnicodeEncodeError', _unicodeStr(start: 1)),
        ]) {
          final error = raisedError(
            pb.RaisedException(
              excType: type,
              message: 'boom',
              data: data,
              traceback: [frame],
            ),
          );
          expect(error, isA<MontyRuntimeError>(), reason: type);
          expect(error.exception.excType, 'ValueError', reason: type);
          expect(error.exception.message, 'boom', reason: type);
          expect(error.exception.attributes, isEmpty, reason: type);
          final runtime = error as MontyRuntimeError;
          expect(runtime.display('type-msg'), '$type: boom', reason: type);
          expect(runtime.display(), endsWith('$type: boom'), reason: type);
          expect(runtime.display('msg'), 'boom', reason: type);
          expect(runtime.toString(), '$type: boom', reason: type);
        }
        // Usable data keeps the type.
        final usable = _inbound('UnicodeEncodeError', _unicodeStr());
        expect(usable.exception.excType, 'UnicodeEncodeError');
        // A SyntaxError has no payload kind: it stays a SyntaxError.
        final syntax = _inbound('SyntaxError', null);
        expect(syntax, isA<MontySyntaxError>());
        expect(syntax.exception.excType, 'SyntaxError');
        expect(_rendered(syntax), 'SyntaxError: boom');
      },
    );
  });
}

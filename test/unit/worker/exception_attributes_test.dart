// Structured exception data (C3-4): a raised exception's payload read into
// its exception's attributes, sanitised as upstream's conversion does; the
// payload-less rule; attributes in ==, hashCode and the value walk's budget;
// ExternalException's attributes sent as upstream sends a live exception's;
// and the writer's refusals that Python makes too. Pure Dart: vm, dart2js
// and dart2wasm.
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_monty_core/src/fake_answers.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/platform/value_graph_budget.dart';
import 'package:dart_monty_core/src/worker/arena_writer.dart';
import 'package:dart_monty_core/src/worker/host_answers.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/monty_snapshot.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/python_rules.dart';
import 'package:dart_monty_core/src/worker/raised_record.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

import '../../_accessors.dart';

/// A Unicode error payload on a `bytes` object.
pb.ExcData _bytesData(
  List<int> object, {
  int start = 0,
  int end = 1,
  String encoding = 'utf-8',
  String reason = 'invalid start byte',
}) => pb.ExcData(
  unicode: pb.UnicodeErrorData(
    encoding: encoding,
    objectBytes: object,
    start: Int64(start),
    end: Int64(end),
    reason: reason,
  ),
);

/// A Unicode error payload on a `str` object.
pb.ExcData _strData(String object, {int start = 0, int end = 1}) => pb.ExcData(
  unicode: pb.UnicodeErrorData(
    encoding: 'utf-8',
    objectStr: object,
    start: Int64(start),
    end: Int64(end),
    reason: 'surrogates not allowed',
  ),
);

/// A JSON error payload.
pb.ExcData _jsonData({
  String msg = 'Expecting value',
  String? doc = '{"a": x}',
  Int64? pos,
  int lineno = 1,
  int colno = 7,
}) => pb.ExcData(
  json: pb.JsonErrorData(
    msg: msg,
    doc: doc,
    pos: pos ?? Int64(6),
    lineno: Int64(lineno),
    colno: Int64(colno),
  ),
);

/// The exception of the error a `RaisedException` of [type] with [data]
/// is.
MontyExceptionValue _read(String type, pb.ExcData? data, [String? message]) =>
    raisedError(
      pb.RaisedException(excType: type, message: message ?? 'm', data: data),
    ).exception;

Map<String, MontyValue> _attrs(MontyExceptionValue e) => e.attributes;

MontyBytes _bytes(List<int> b) => MontyBytes(Uint8List.fromList(b));

void main() {
  group('a raised payload is read into attributes', () {
    test('a decode error: encoding, bytes object, start, end, reason', () {
      final e = _read('UnicodeDecodeError', _bytesData([0xff, 0x41]));
      expect(e.excType, 'UnicodeDecodeError');
      expect(e.message, 'm');
      expect(_attrs(e), {
        'encoding': const MontyString('utf-8'),
        'object': _bytes([0xff, 0x41]),
        'start': const MontyInt(0),
        'end': const MontyInt(1),
        'reason': const MontyString('invalid start byte'),
      });
    });

    test('an encode error: its object is a str', () {
      final e = _read('UnicodeEncodeError', _strData('ab', end: 2));
      expect(e.excType, 'UnicodeEncodeError');
      final attrs = _attrs(e);
      expect(attrs['object'], const MontyString('ab'));
      expect(attrs['end'], const MontyInt(2));
    });

    test('a JSON error: msg, doc, pos, lineno, colno', () {
      final e = _read('json.JSONDecodeError', _jsonData());
      expect(e.excType, 'json.JSONDecodeError');
      expect(_attrs(e), {
        'msg': const MontyString('Expecting value'),
        'doc': const MontyString('{"a": x}'),
        'pos': const MontyInt(6),
        'lineno': const MontyInt(1),
        'colno': const MontyInt(7),
      });
    });

    test("a JSON error whose document the sender dropped: doc is ''", () {
      final e = _read(
        'json.JSONDecodeError',
        _jsonData(doc: null, pos: Int64(2000001), colno: 2000002),
      );
      final attrs = _attrs(e);
      expect(attrs['doc'], const MontyString(''));
      expect(attrs['pos'], const MontyInt(2000001));
      expect(attrs['colno'], const MontyInt(2000002));
    });

    test('an unsigned position past 2^53 reads as a big int', () {
      final huge = Int64.parseHex('ffffffffffffffff');
      final e = _read('json.JSONDecodeError', _jsonData(doc: null, pos: huge));
      expect(
        _attrs(e)['pos'],
        MontyBigInt((BigInt.one << 64) - BigInt.one),
      );
    });

    test('any other type keeps its type, and the payload is not read', () {
      final e = _read('ValueError', _jsonData());
      expect(e.excType, 'ValueError');
      expect(_attrs(e), isEmpty);
    });
  });

  group('without its data a Unicode or JSON error reads as ValueError', () {
    for (final type in [
      'UnicodeDecodeError',
      'UnicodeEncodeError',
      'json.JSONDecodeError',
    ]) {
      test('$type with no payload', () {
        final error = raisedError(
          pb.RaisedException(excType: type, message: 'x'),
        );
        expect(
          error.exception,
          MontyExceptionValue(
            'ValueError',
            'x',
          ),
        );
        expect(_attrs(error.exception), isEmpty);
        // The rendering still names the original type, as upstream's.
        expect((error as MontyRuntimeError).display('type-msg'), '$type: x');
        expect(error.toString(), '$type: x');
      });
    }

    test('a payload of the other kind: ValueError', () {
      expect(_read('UnicodeDecodeError', _jsonData()).excType, 'ValueError');
      expect(
        _read('json.JSONDecodeError', _bytesData([0xff])).excType,
        'ValueError',
      );
      // CPython's constructors: a decode error takes bytes, an encode
      // error a str.
      expect(_read('UnicodeDecodeError', _strData('a')).excType, 'ValueError');
      expect(
        _read('UnicodeEncodeError', _bytesData([0xff])).excType,
        'ValueError',
      );
    });

    test('an absent message reads as empty', () {
      final e = raisedError(
        pb.RaisedException(excType: 'UnicodeDecodeError'),
      ).exception;
      expect(e, MontyExceptionValue('ValueError', ''));
    });
  });

  group('the Unicode range rule (F4): dropped, not rejected', () {
    test('start == end is dropped', () {
      final e = _read('UnicodeDecodeError', _bytesData([1, 2, 3], start: 1));
      expect(e.excType, 'ValueError');
    });

    test('end one past a 3-byte object is dropped; equal to it, kept', () {
      expect(
        _read('UnicodeDecodeError', _bytesData([1, 2, 3], end: 4)).excType,
        'ValueError',
      );
      final kept = _read('UnicodeDecodeError', _bytesData([1, 2, 3], end: 3));
      expect(kept.excType, 'UnicodeDecodeError');
      expect(_attrs(kept)['end'], const MontyInt(3));
    });

    test("a str's end counts characters, not UTF-8 bytes or UTF-16 units", () {
      // 'é😀' is 2 characters, 3 UTF-16 units and 6 UTF-8 bytes.
      expect(
        _read('UnicodeEncodeError', _strData('é😀', end: 3)).excType,
        'ValueError',
      );
      expect(
        _read('UnicodeEncodeError', _strData('é😀', end: 2)).excType,
        'UnicodeEncodeError',
      );
    });

    test('start past end, and a start past 2^63, are dropped', () {
      expect(
        _read(
          'UnicodeDecodeError',
          _bytesData([1, 2], start: 2),
        ).excType,
        'ValueError',
      );
      final data = _bytesData([1, 2]);
      data.unicode.start = Int64.parseHex('ffffffffffffffff');
      expect(_read('UnicodeDecodeError', data).excType, 'ValueError');
    });

    test('a payload with no arm set is none', () {
      final e = _read('json.JSONDecodeError', pb.ExcData());
      expect(e.excType, 'ValueError');
      expect(_attrs(e), isEmpty);
    });

    test('no object is dropped', () {
      final data = pb.ExcData(
        unicode: pb.UnicodeErrorData(
          encoding: 'utf-8',
          start: Int64(),
          end: Int64(1),
          reason: 'r',
        ),
      );
      expect(_read('UnicodeDecodeError', data).excType, 'ValueError');
    });
  });

  group('payload size and value checks: dropped, the error still raised', () {
    const cap = 64 * 1024;

    test('an object, encoding or reason over 64 KiB', () {
      final big = List.filled(cap + 1, 0x41);
      expect(
        _read('UnicodeDecodeError', _bytesData(big, end: 2)).excType,
        'ValueError',
      );
      expect(
        _read('UnicodeDecodeError', _bytesData(List.filled(cap, 0x41))).excType,
        'UnicodeDecodeError',
      );
      final str = 'é' * (cap ~/ 2) + 'a'; // 64 KiB + 1 of UTF-8
      expect(_read('UnicodeEncodeError', _strData(str)).excType, 'ValueError');
      expect(
        _read(
          'UnicodeDecodeError',
          _bytesData([1], encoding: 'x' * (cap + 1)),
        ).excType,
        'ValueError',
      );
      expect(
        _read(
          'UnicodeDecodeError',
          _bytesData([1], reason: 'x' * (cap + 1)),
        ).excType,
        'ValueError',
      );
    });

    test('a JSON msg or doc over 64 KiB of UTF-8', () {
      expect(
        _read('json.JSONDecodeError', _jsonData(msg: 'x' * (cap + 1))).excType,
        'ValueError',
      );
      expect(
        _read(
          'json.JSONDecodeError',
          _jsonData(doc: '€' * (cap ~/ 3 + 1), pos: Int64()),
        ).excType,
        'ValueError',
      );
    });

    test('a zero lineno or colno', () {
      expect(
        _read('json.JSONDecodeError', _jsonData(lineno: 0)).excType,
        'ValueError',
      );
      expect(
        _read('json.JSONDecodeError', _jsonData(colno: 0)).excType,
        'ValueError',
      );
    });

    test('pos past the document, counted in characters; at its end, kept', () {
      // '€€' is 2 characters and 6 UTF-8 bytes.
      expect(
        _read(
          'json.JSONDecodeError',
          _jsonData(doc: '€€', pos: Int64(3)),
        ).excType,
        'ValueError',
      );
      expect(
        _read(
          'json.JSONDecodeError',
          _jsonData(doc: '€€', pos: Int64(2)),
        ).excType,
        'json.JSONDecodeError',
      );
    });

    test('a dropped payload is no protocol violation', () {
      final error = raisedError(
        pb.RaisedException(
          excType: 'json.JSONDecodeError',
          message: 'm',
          data: _jsonData(lineno: 0),
        ),
      );
      expect(error, isA<MontyRuntimeError>());
    });

    test(
      'JSON payload bounds use the optional outer message and allow one past doc',
      () {
        // A JSON error's message is its `msg` with the position appended, so
        // upstream sizes `msg` by that message's UTF-8 bytes when the wire
        // carries one, and by the cap when it does not.
        MontyExceptionValue read(String? message, pb.ExcData data) =>
            raisedError(
              pb.RaisedException(
                excType: 'json.JSONDecodeError',
                message: message,
                data: data,
              ),
            ).exception;

        // Over the cap yet under a longer message: kept. 40 * 1024 'é' are
        // 80 KiB of UTF-8, more than the 70 KiB `msg`.
        final long = 'x' * (70 * 1024);
        final kept = read('é' * (40 * 1024), _jsonData(msg: long));
        expect(kept.excType, 'json.JSONDecodeError');
        expect(_attrs(kept)['msg'], MontyString(long));

        // Under the cap yet longer than the message: dropped. 100 'é' are
        // 200 UTF-8 bytes against 150 ASCII ones.
        expect(
          read('x' * 150, _jsonData(msg: 'é' * 100)).excType,
          'ValueError',
        );

        // An absent message leaves the cap alone: at it kept, past it
        // dropped.
        expect(
          read(null, _jsonData(doc: null, msg: 'x' * cap)).excType,
          'json.JSONDecodeError',
        );
        expect(
          read(null, _jsonData(doc: null, msg: 'x' * (cap + 1))).excType,
          'ValueError',
        );

        // An empty message is a carried one, not an absent one: only an
        // empty `msg` fits under it.
        expect(read('', _jsonData(doc: null)).excType, 'ValueError');
        expect(
          read('', _jsonData(doc: null, msg: '')).excType,
          'json.JSONDecodeError',
        );

        // A doc that is present, empty or absent: a present one bounds
        // `pos`, and an absent one reads as '' and leaves `pos` alone.
        const canonical = 'Expecting value: line 1 column 7 (char 6)';
        expect(
          _attrs(read(canonical, _jsonData()))['doc'],
          const MontyString('{"a": x}'),
        );
        expect(
          read(canonical, _jsonData(doc: '', pos: Int64(1))).excType,
          'json.JSONDecodeError',
        );
        final noDoc = _attrs(
          read(canonical, _jsonData(doc: null, pos: Int64(2000001))),
        );
        expect(noDoc['doc'], const MontyString(''));
        expect(noDoc['pos'], const MontyInt(2000001));

        // One past the doc's characters is kept -- `tomllib` reports an
        // escape cut off by the end of input one past it -- and two past is
        // dropped. The count is characters: '€€€' is 3 of them, 9 bytes.
        expect(
          read(canonical, _jsonData(doc: '[1,', pos: Int64(4))).excType,
          'json.JSONDecodeError',
        );
        expect(
          read(canonical, _jsonData(doc: '€€€', pos: Int64(4))).excType,
          'json.JSONDecodeError',
        );
        expect(
          read(canonical, _jsonData(doc: '[1,', pos: Int64(5))).excType,
          'ValueError',
        );
        expect(
          read(canonical, _jsonData(doc: '€€€', pos: Int64(5))).excType,
          'ValueError',
        );

        // An oversized doc, a zero line or a zero column drops the payload
        // without rejecting the exception it arrived on.
        for (final data in [
          _jsonData(doc: 'x' * (cap + 1)),
          _jsonData(lineno: 0),
          _jsonData(colno: 0),
        ]) {
          final error = raisedError(
            pb.RaisedException(
              excType: 'json.JSONDecodeError',
              message: canonical,
              data: data,
            ),
          );
          expect(error, isA<MontyRuntimeError>());
          expect(error.exception.excType, 'ValueError');
          expect(error.exception.attributes, isEmpty);
          expect(
            (error as MontyRuntimeError).display('type-msg'),
            'json.JSONDecodeError: $canonical',
          );
        }

        // Both `payloadOf` callers read the same bounds: the wire record,
        // and the fake replay of a host answer.
        final carried = pb.RaisedException(
          excType: 'json.JSONDecodeError',
          message: 'x' * (cap + 1),
          data: _jsonData(doc: null, msg: 'x' * (cap + 1)),
        );
        expect(
          RaisedRecord.fromWire(carried).payload?.attributes['msg'],
          MontyString('x' * (cap + 1)),
        );
        expect(
          exceptionOf(carried).attributes['msg'],
          MontyString('x' * (cap + 1)),
        );

        final onePast = pb.RaisedException(
          excType: 'json.JSONDecodeError',
          message: canonical,
          data: _jsonData(doc: '[1,', pos: Int64(4)),
        );
        expect(
          RaisedRecord.fromWire(onePast).payload?.attributes['pos'],
          const MontyInt(4),
        );
        expect(exceptionOf(onePast).attributes['pos'], const MontyInt(4));

        final twoPast = pb.RaisedException(
          excType: 'json.JSONDecodeError',
          message: canonical,
          data: _jsonData(doc: '[1,', pos: Int64(5)),
        );
        expect(RaisedRecord.fromWire(twoPast).payload, isNull);
        expect(exceptionOf(twoPast).attributes, isEmpty);

        final longer = pb.RaisedException(
          excType: 'json.JSONDecodeError',
          message: 'x' * 150,
          data: _jsonData(doc: null, msg: 'é' * 100),
        );
        expect(RaisedRecord.fromWire(longer).payload, isNull);
        final longerReplay = exceptionOf(longer);
        expect(longerReplay.excType, 'json.JSONDecodeError');
        expect(longerReplay.attributes, isEmpty);

        // The Unicode caps stand either way: no message, however long,
        // loosens them, and none, however short, tightens them.
        expect(
          _read(
            'UnicodeEncodeError',
            _strData('x' * (cap + 1)),
            'x' * (cap + 1),
          ).excType,
          'ValueError',
        );
        expect(
          _read('UnicodeEncodeError', _strData('x' * cap), '').excType,
          'UnicodeEncodeError',
        );
      },
    );
  });

  group('attributes in ==, hashCode and the walk budget', () {
    MontyExceptionValue withPos(MontyValue pos) => MontyExceptionValue(
      'json.JSONDecodeError',
      'm',
      {'pos': pos, 'doc': const MontyString('d')},
    );

    test('equal attributes are equal, with equal hashes', () {
      final a = withPos(const MontyInt(1));
      final b = MontyExceptionValue(
        'json.JSONDecodeError',
        'm',
        const {'doc': MontyString('d'), 'pos': MontyInt(1)},
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      // Leaf rules hold inside attributes: an int equals the same big int.
      final big = withPos(MontyBigInt(BigInt.one));
      expect(a, big);
      expect(a.hashCode, big.hashCode);
    });

    test('different attributes, or none, are not equal', () {
      final plain = MontyExceptionValue(
        'json.JSONDecodeError',
        'm',
      );
      final one = withPos(const MontyInt(1));
      expect(one, isNot(withPos(const MontyInt(2))));
      expect(one, isNot(plain));
      expect(plain, isNot(one));
      expect(
        MontyExceptionValue('ValueError', 'm'),
        MontyExceptionValue('ValueError', 'm'),
      );
    });

    test('inside containers too', () {
      MontyList listOf(int pos) => MontyList([withPos(MontyInt(pos))]);
      final one = listOf(1);
      expect(one, isNot(listOf(2)));
      expect(one, listOf(1));
    });

    test("an attribute's payload counts toward the walk's visits", () {
      MontyExceptionValue big() => MontyExceptionValue(
        'UnicodeDecodeError',
        'm',
        {'object': MontyBytes(Uint8List(64 * 1024))},
      );
      final budget = ValueGraphBudget(maxVisits: 1000);
      MontyList listOfBig() => MontyList([big()]);
      final equal = budget.run(() => listOfBig() == listOfBig());
      expect(equal, isTrue);
      expect(budget.fallbacks, 1);
    });

    test('an attribute is a leaf: a container is refused', () {
      expect(
        () => MontyExceptionValue(
          'ValueError',
          null,
          const {'x': MontyList([])},
        ),
        throwsArgumentError,
      );
    });

    test('a value node carries no attributes: the writer drops them', () {
      final writer = ArenaWriter();
      final index = writer.add(withPos(const MontyInt(1)));
      final node = itemAt(writer.arena.nodes, index).exception;
      expect(node.excType, 'json.JSONDecodeError');
      expect(node.arg, 'm');
    });
  });

  group("ExternalException's attributes (SURF3 Q1)", () {
    const full = {
      'msg': MontyString('Expecting value'),
      'doc': MontyString('{"a": x}'),
      'pos': MontyInt(6),
      'lineno': MontyInt(1),
      'colno': MontyInt(7),
    };

    test('value equality, attributes included', () {
      expect(
        const ExternalException('ValueError', 'm', {'a': MontyInt(1)}),
        const ExternalException('ValueError', 'm', {'a': MontyInt(1)}),
      );
      expect(
        const ExternalException('ValueError', 'm', {'a': MontyInt(1)}).hashCode,
        ExternalException('ValueError', 'm', {
          'a': MontyBigInt(BigInt.one),
        }).hashCode,
      );
      expect(
        const ExternalException('ValueError', 'm', {'a': MontyInt(1)}),
        isNot(const ExternalException('ValueError', 'm', {'a': MontyInt(2)})),
      );
      expect(
        const ExternalException('ValueError', 'm'),
        isNot(const ExternalException('ValueError')),
      );
      expect(const ExternalException('ValueError').attributes, isEmpty);
    });

    test("equality compares keys as strings, whatever the map's rules", () {
      final folded = SplayTreeMap<String, MontyValue>(
        (a, b) => a.toLowerCase().compareTo(b.toLowerCase()),
      )..['POS'] = const MontyInt(1);
      const plain = ExternalException('ValueError', 'm', {
        'pos': MontyInt(1),
      });
      final custom = ExternalException('ValueError', 'm', folded);
      expect(plain == custom, isFalse);
      expect(custom == plain, isFalse);
      final same = ExternalException(
        'ValueError',
        'm',
        SplayTreeMap<String, MontyValue>()..['pos'] = const MontyInt(1),
      );
      expect(same, plain);
      expect(same.hashCode, plain.hashCode);
    });

    test('keys equal as strings but distinct objects hash alike', () {
      // Two distinct String objects spelling 'pos'.
      String spelled() => String.fromCharCodes(const [0x70, 0x6f, 0x73]);
      final a = spelled();
      final b = spelled();
      final twice = Map<String, MontyValue>.identity()
        ..[a] = const MontyInt(1)
        ..[b] = const MontyInt(1);
      final dup = ExternalException('ValueError', 'm', twice);
      const plain = ExternalException('ValueError', 'm', {'pos': MontyInt(1)});
      expect(dup == plain, plain == dup);
      if (dup == plain) expect(dup.hashCode, plain.hashCode);
    });

    test("a message with an unpaired surrogate is sent as upstream's "
        'exception_arg reads it', () {
      final lossy = raisedException('ValueError', 'a\uD800', const {});
      expect(lossy.message, 'a\uFFFD\uFFFD\uFFFD');
      final key = raisedFrom(const ExternalException('KeyError', 'k\uD800'));
      expect(key.message, r"'k\ud800'");
    });

    test('a JSON error with all five sends the json arm', () {
      final raised = raisedException('json.JSONDecodeError', 'm', full);
      expect(raised.excType, 'json.JSONDecodeError');
      expect(raised.message, 'm');
      final json = raised.data.json;
      expect(json.msg, 'Expecting value');
      expect(json.doc, '{"a": x}');
      expect(json.pos, Int64(6));
      expect(json.lineno, Int64(1));
      expect(json.colno, Int64(7));
    });

    test('a doc over 64 KiB of UTF-8 is left out, the rest kept', () {
      final raised = raisedException('json.JSONDecodeError', 'm', {
        ...full,
        'doc': MontyString('x' * (70 * 1024)),
      });
      final json = raised.data.json;
      expect(json.hasDoc(), isFalse);
      expect(json.pos, Int64(6));
      final atCap = raisedException('json.JSONDecodeError', 'm', {
        ...full,
        'doc': MontyString('x' * (64 * 1024)),
      });
      expect(atCap.data.json.hasDoc(), isTrue);
    });

    test('no attributes, a missing or mistyped one: no payload', () {
      expect(
        raisedException('json.JSONDecodeError', 'm', const {}).hasData(),
        isFalse,
      );
      for (final bad in <Map<String, MontyValue>>[
        {...full}..remove('colno'),
        {...full, 'pos': const MontyString('6')},
        {...full, 'pos': const MontyInt(-1)},
        {...full, 'pos': MontyBigInt(BigInt.one << 64)},
        {...full, 'msg': const MontyInt(1)},
        {
          ...full,
          'doc': const MontyBytes([1]),
        },
        {...full, 'doc': const MontyString('\uD800')},
      ]) {
        expect(
          raisedException('json.JSONDecodeError', 'm', bad).hasData(),
          isFalse,
          reason: '$bad',
        );
      }
    });

    test('a bool or a big int within 64 bits is an int, as in Python', () {
      final raised = raisedException('json.JSONDecodeError', 'm', {
        ...full,
        'lineno': const MontyBool(true),
        'pos': MontyBigInt((BigInt.one << 64) - BigInt.one),
      });
      final json = raised.data.json;
      expect(json.lineno, Int64.ONE);
      expect(json.pos, Int64.parseHex('ffffffffffffffff'));
    });

    test('an int of 2^64, which dart2js can hold, drops the payload', () {
      // dart2js only: elsewhere an int stops at 2^63 - 1.
      final two64 = math.pow(2, 64) as int;
      final raised = raisedException('json.JSONDecodeError', 'm', {
        ...full,
        'pos': MontyInt(two64),
      });
      expect(raised.hasData(), isFalse);
    }, testOn: 'dart2js');

    test("any other type's attributes are not sent", () {
      final raised = raisedException('UnicodeDecodeError', 'm', {
        'encoding': const MontyString('utf-8'),
        'object': const MontyBytes([0xff]),
        'start': const MontyInt(0),
        'end': const MontyInt(1),
        'reason': const MontyString('invalid start byte'),
      });
      expect(raised.hasData(), isFalse);
      expect(raisedException('ValueError', 'm', full).hasData(), isFalse);
    });

    test(
      'thrown from a host callback: raised as its type, attributes sent',
      () {
        final raised = raisedFrom(
          const ExternalException('json.JSONDecodeError', 'm', full),
        );
        expect(raised.excType, 'json.JSONDecodeError');
        expect(raised.data.json.pos, Int64(6));
        // An unknown type is an ArgumentError, thrown like any other.
        expect(
          raisedFrom(const ExternalException('NoSuchError', 'm')).excType,
          'Exception',
        );
      },
    );
  });

  group('writer refusals Python makes too', () {
    Matcher refusal(String type, String text) => throwsA(
      isA<PythonRefusal>()
          .having((e) => e.excType, 'excType', type)
          .having((e) => e.text, 'text', text),
    );

    test('a cycle: ValueError, Circular reference detected', () {
      final items = <MontyValue>[];
      final cyclic = MontyList(items);
      items.add(cyclic);
      expect(
        () => ArenaWriter().add(cyclic),
        refusal('ValueError', 'Circular reference detected'),
      );
    });

    test("an unpaired surrogate: UnicodeEncodeError with CPython's text", () {
      expect(
        () => ArenaWriter().add(const MontyString('\uD800')),
        refusal(
          'UnicodeEncodeError',
          r"'utf-8' codec can't encode character '\ud800' in position 0: "
              'surrogates not allowed',
        ),
      );
      // Positions count code points: the emoji before it is one.
      expect(
        () => ArenaWriter().add(
          const MontyList([MontyString('ok'), MontyString('😀a\uDC01b')]),
        ),
        refusal(
          'UnicodeEncodeError',
          r"'utf-8' codec can't encode character '\udc01' in position 2: "
              'surrogates not allowed',
        ),
      );
      // A run of surrogates is one error over the run.
      expect(
        () => ArenaWriter().add(MontyPath('x\uDC00\uD800')),
        refusal(
          'UnicodeEncodeError',
          "'utf-8' codec can't encode characters in position 1-2: "
              'surrogates not allowed',
        ),
      );
    });

    test('values Python cannot build stay plain ArgumentErrors', () {
      expect(
        () => ArenaWriter().add(const MontyBytes([256])),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e,
            'refusal',
            isNot(isA<PythonRefusal>()),
          ),
        ),
      );
    });

    test('at an input or a manual resume: MontyRuntimeError, no traceback', () {
      final runtimeError = isA<MontyRuntimeError>();
      final items = <MontyValue>[];
      final cyclic = MontyList(items);
      items.add(cyclic);
      expect(
        () => encodingInput(() => ArenaWriter().add(cyclic)),
        throwsA(
          runtimeError
              .having(
                (e) => e.toString(),
                'message',
                'ValueError: Circular reference detected',
              )
              .having((e) => e.traceback, 'traceback', isEmpty)
              .having(
                (e) => e.display(),
                'display',
                'ValueError: Circular reference detected',
              ),
        ),
      );
      // A surrogate's error has no data, so it reads as ValueError.
      expect(
        () =>
            encodingInput(() => ArenaWriter().add(const MontyString('\uD800'))),
        throwsA(
          runtimeError
              .having((e) => e.exception.excType, 'excType', 'ValueError')
              .having(
                (e) => e.toString(),
                'message',
                startsWith("UnicodeEncodeError: 'utf-8' codec"),
              ),
        ),
      );
      expect(
        () => encodingInput(() => ArenaWriter().add(const MontyBytes([256]))),
        throwsArgumentError,
      );
    });

    test(
      'in an automatic answer: raised in the sandbox as Python raises it',
      () {
        final raised = raisedFrom(
          PythonRefusal(const MontyNone(), 'x', 'ValueError', 'Circular'),
        );
        expect(raised.excType, 'ValueError');
        expect(raised.message, 'Circular');
      },
    );

    test('utf8Length counts what UTF-8 takes', () {
      expect(utf8Length('aé€😀'), 1 + 2 + 3 + 4);
      expect(utf8Length('\uD800'), 3);
    });
  });
}

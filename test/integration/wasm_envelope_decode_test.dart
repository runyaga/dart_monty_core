// A malformed typed envelope must be a DECODE ERROR on the web — not a wasm
// trap, and not a silently-substituted zero (A2).
//
// WHY THIS TEST TALKS TO THE RAW BRIDGE. Since #139 the Dart API cannot express
// a malformed envelope at all: every value-carrying bindings method takes
// `WireJson`, which only `MontyValue`'s encoder can mint. So a test written
// against `MontyRepl` cannot reach `json_to_monty_object`'s error paths — it
// would be asserting on a door that is already locked. The JS bridge is NOT
// WireJson-gated (plain JSON in, and `window.DartMontyBridge` is reachable from
// any script on the page), so it is the surface where these payloads can still
// arrive. That is the surface this test drives.
//
// Measured in Chrome against the shipped wasm BEFORE the fix:
//
//   {"__type":"date","year":2020}              -> error "unreachable", a wasm
//                                                 trap from `map["month"]`
//   {"__type":"datetime",...,"hour":"XX",...}  -> ok:true,
//                                                 datetime(2020,1,1,0,0)
//
// Runs on BOTH Dart compile targets via tool/test_wasm_unit.sh and its
// --dart2wasm twin. The engine under test is the same wasm either way; the
// point of running both is that the harness itself is compiled differently.
@Tags(['integration', 'wasm'])
library;

import 'dart:convert';
import 'dart:js_interop';

import 'package:test/test.dart';

@JS('DartMontyBridge.init')
external JSPromise<JSBoolean> _jsInit();

@JS('DartMontyBridge.replCreate')
external JSPromise<JSString> _jsReplCreate(JSString replId, JSString? name);

@JS('DartMontyBridge.replDispose')
external JSPromise<JSString> _jsReplDispose(JSString replId);

@JS('DartMontyBridge.replFeedRun')
external JSPromise<JSString> _jsReplFeedRun(JSString replId, JSString code);

@JS('DartMontyBridge.replSetExtFns')
external JSPromise<JSString> _jsReplSetExtFns(
  JSString replId,
  JSString extFns,
);

@JS('DartMontyBridge.replFeedStart')
external JSPromise<JSString> _jsReplFeedStart(JSString replId, JSString code);

@JS('DartMontyBridge.replResume')
external JSPromise<JSString> _jsReplResume(
  JSString replId,
  JSString valueJson,
);

var _n = 0;

/// Boots a REPL paused at `echo(1)`, ready to be resumed with a payload.
Future<String> _pausedAtEcho() async {
  await _jsInit().toDart;
  final id = 'envelope-${++_n}';
  await _jsReplCreate(id.toJS, 'main.py'.toJS).toDart;
  await _jsReplSetExtFns(id.toJS, jsonEncode(['echo']).toJS).toDart;
  await _jsReplFeedStart(id.toJS, 'x = echo(1)\nprint(repr(x))'.toJS).toDart;

  return id;
}

Map<String, Object?> _decode(JSString raw) =>
    jsonDecode(raw.toDart) as Map<String, Object?>;

/// Resumes [id] with [payload] and returns the decoded progress map.
Future<Map<String, Object?>> _resumeWith(
  String id,
  Map<String, Object?> payload,
) async =>
    _decode(await _jsReplResume(id.toJS, jsonEncode(payload).toJS).toDart);

void main() {
  group('a malformed envelope is a decode error, not a trap', () {
    test('a missing required field names the field', () async {
      final id = await _pausedAtEcho();
      addTearDown(() => _jsReplDispose(id.toJS).toDart);

      final r = await _resumeWith(id, {'__type': 'date', 'year': 2020});
      final error = (r['error'] as String?) ?? '';

      expect(r['ok'], isFalse);
      expect(
        error,
        contains('month'),
        reason: 'the error must name the missing field',
      );
      expect(
        error,
        isNot(contains('unreachable')),
        reason: 'a wasm trap, not a decode error — the panic is back (A2)',
      );
    });

    test('a wrong-typed field is rejected, not silently zeroed', () async {
      final id = await _pausedAtEcho();
      addTearDown(() => _jsReplDispose(id.toJS).toDart);

      final r = await _resumeWith(id, {
        '__type': 'datetime',
        'year': 2020,
        'month': 1,
        'day': 1,
        'hour': 'XX',
        'minute': 0,
        'second': 0,
        'microsecond': 0,
      });

      expect(
        r['ok'],
        isFalse,
        reason:
            'hour "XX" used to decode as hour 0 with ok:true — a G2 '
            'violation inside a decoder',
      );
      expect((r['error'] as String?) ?? '', contains('hour'));
    });

    test('a present-but-wrong optional field is still an error', () async {
      final id = await _pausedAtEcho();
      addTearDown(() => _jsReplDispose(id.toJS).toDart);

      final r = await _resumeWith(id, {
        '__type': 'datetime',
        'year': 2020,
        'month': 1,
        'day': 1,
        'hour': 0,
        'minute': 0,
        'second': 0,
        'microsecond': 0,
        'offset_seconds': 'XX',
      });

      expect(r['ok'], isFalse);
      expect((r['error'] as String?) ?? '', contains('offset_seconds'));
    });

    test('a well-formed envelope still decodes', () async {
      final id = await _pausedAtEcho();
      addTearDown(() => _jsReplDispose(id.toJS).toDart);

      final r = await _resumeWith(id, {
        '__type': 'date',
        'year': 2020,
        'month': 1,
        'day': 2,
      });

      expect(r['ok'], isTrue, reason: 'error: ${r['error']}');
      expect(
        (r['print_output'] as String?)?.trim(),
        'datetime.date(2020, 1, 2)',
      );
    });
  });

  // FB-9 — recorded as a live assertion of CURRENT behaviour, not as an
  // aspiration. Fixing A2 removed the trap but not this: the engine is left
  // suspended at the external call, and the host cannot abandon or reset it
  // short of disposing the session.
  //
  // Asserting what is true today, rather than skipping, is deliberate — this is
  // the row that tells us the day someone makes rejection recoverable. When
  // that happens this test SHOULD fail, and its replacement is
  // `expect(after['ok'], isTrue)`.
  group('FB-9 — a rejected resume leaves the session unusable', () {
    test('the session is bricked, but only that session', () async {
      final id = await _pausedAtEcho();
      addTearDown(() => _jsReplDispose(id.toJS).toDart);

      await _resumeWith(id, {'__type': 'date', 'year': 2020});

      final after = _decode(
        await _jsReplFeedRun(id.toJS, '1 + 1'.toJS).toDart,
      );
      expect(
        after['ok'],
        isFalse,
        reason:
            'FB-9 may have been FIXED — if a rejected resume is now '
            'recoverable, invert this assertion and delete the row',
      );
      expect(
        (after['error'] as String?) ?? '',
        contains('Idle or Complete'),
        reason: 'the failure mode changed; re-measure FB-9',
      );

      // Containment: the damage must not reach a different session.
      await _jsInit().toDart;
      final fresh = 'envelope-fresh-${++_n}';
      await _jsReplCreate(fresh.toJS, 'main.py'.toJS).toDart;
      addTearDown(() => _jsReplDispose(fresh.toJS).toDart);
      final ok = _decode(
        await _jsReplFeedRun(fresh.toJS, '6 * 7'.toJS).toDart,
      );
      expect(ok['ok'], isTrue, reason: 'a fresh session must be unaffected');
      expect(ok['value'], 42);
    });
  });
}

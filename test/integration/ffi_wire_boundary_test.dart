// The two wire-boundary helpers, against ENGINE-PRODUCED data.
//
// `MontyValue.encodeForWire` and `MontyStackFrame.listFromJson` were the last
// two of the six entry points tool/check_api_exercised.sh flagged in 1e4a875.
// Both had unit tests — and both were only ever fed HAND-WRITTEN JSON, which
// is the failure mode this check exists to catch. A decoder tested only
// against fixtures its own author wrote proves the fixtures parse, not that
// the engine's output does.
//
// So every input below comes out of a real FFI run.
@Tags(['integration', 'ffi'])
library;

import 'dart:convert';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/ffi/monty_ffi.dart';
import 'package:test/test.dart';

void main() {
  group('MontyStackFrame.listFromJson on a real traceback', () {
    late List<MontyStackFrame> frames;

    setUp(() async {
      final m = MontyFfi();
      addTearDown(m.dispose);

      try {
        await m.run('def f():\n    raise ValueError("boom")\nf()\n');
        fail('expected the run to raise');
      } on MontyScriptError catch (e) {
        frames = e.exception!.traceback;
      }
    });

    test('the engine produces a traceback the decoder understands', () {
      // Two frames: the call site at module level and the raise inside f.
      // If listFromJson silently dropped frames it could not name, this would
      // come back short or empty rather than failing loudly.
      expect(frames, hasLength(2));
      expect(frames.map((f) => f.frameName), ['<module>', 'f']);
      expect(frames.map((f) => f.startLine), [3, 2]);
      expect(frames.every((f) => f.filename == '<input>'), isTrue);
    });

    test('optional fields the engine sends are carried, not discarded', () {
      // `preview_line` and `hide_caret` are only present on some frames, and
      // a decoder that ignored unknown-but-present keys would still pass a
      // hand-written fixture that omitted them.
      expect(frames[0].previewLine, 'f()');
      expect(frames[1].previewLine, contains('raise ValueError'));
      expect(frames[1].hideCaret, isTrue);
      expect(frames[0].hideCaret, isFalse);
    });

    test('listFromJson round-trips the engine payload through toJson', () {
      // Re-encode what the engine gave us and decode it again BY NAME. This
      // is the entry point under test, fed data no test author invented.
      final reEncoded = frames.map((f) => f.toJson()).toList();
      final decoded = MontyStackFrame.listFromJson(reEncoded);

      expect(decoded, hasLength(frames.length));
      for (var i = 0; i < frames.length; i++) {
        expect(decoded[i].filename, frames[i].filename);
        expect(decoded[i].startLine, frames[i].startLine);
        expect(decoded[i].startColumn, frames[i].startColumn);
        expect(decoded[i].endLine, frames[i].endLine);
        expect(decoded[i].endColumn, frames[i].endColumn);
        expect(decoded[i].frameName, frames[i].frameName);
        expect(decoded[i].previewLine, frames[i].previewLine);
        expect(decoded[i].hideCaret, frames[i].hideCaret);
      }
    });

    test('an empty traceback decodes to an empty list, not a throw', () {
      expect(MontyStackFrame.listFromJson(const []), isEmpty);
    });
  });

  group('MontyValue.encodeForWire is what the engine accepts', () {
    test('a host Map is wrapped in the dict envelope, not emitted bare', () {
      // The whole reason this helper exists, per its own doc: since wire
      // format v2 a BARE JSON object is a protocol violation and would be
      // rejected. Routing through MontyValue.fromDart adds the envelope.
      final encoded = MontyValue.encodeForWire({'k': 7});
      final decoded = json.decode(encoded) as Map<String, dynamic>;

      expect(
        decoded.containsKey('__type'),
        isTrue,
        reason: 'a bare {"k": 7} is exactly what v2 rejects',
      );
      expect(json.encode({'k': 7}), isNot(encoded));
    });

    test('and the ENGINE consumes that encoding as a Python dict', () async {
      // The assertion above is about shape. This one is about acceptance:
      // the same host Map goes across a real FFI boundary and comes back
      // subscripted by the interpreter.
      final m = MontyFfi();
      addTearDown(m.dispose);

      final paused = await m.start('get_map()["k"] + 1');
      expect(paused, isA<MontyPending>());
      expect((paused as MontyPending).functionName, 'get_map');

      final done = await m.resume({'k': 7});

      // 8, not 7 — the engine indexed the dict and did the arithmetic.
      expect(done, isA<MontyComplete>());
      expect((done as MontyComplete).output, const MontyInt(8));
    });

    test('scalars and null survive the same path', () async {
      final m = MontyFfi();
      addTearDown(m.dispose);

      await m.start('str(get_it())');
      final done = await m.resume(null);

      expect(done, isA<MontyComplete>());
      expect((done as MontyComplete).output, const MontyString('None'));
    });
  });
}

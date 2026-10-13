// WorkerChannel against the COMMITTED lib/assets/dart_monty_core_proto_worker
// .{js,wasm} in Chrome, on dart2js and dart2wasm:
//
//   bash tool/test_worker_web.sh
//
// Turns are built by hand from the generated messages; the driver that
// will normally build them (ProtoSession) is not needed to test the channel.
@TestOn('browser')
@Tags(['worker'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:dart_monty_core/dart_monty_core.dart'
    show MontyBigInt, MontyBool, MontyFloat, MontyInt, MontyTuple, MontyValue;
import 'package:dart_monty_core/src/worker/arena_reader.dart';
import 'package:dart_monty_core/src/worker/arena_writer.dart';
import 'package:dart_monty_core/src/worker/channel_factory.dart';
import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/wire_scalars.dart';
import 'package:dart_monty_core/src/worker/worker_channel.dart';
import 'package:dart_monty_core/src/worker/worker_connection.dart'
    show workerProtocolVersion;
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

import '_kind_round_trips.dart';

/// The package's lib/ as the test server exposes it.
const _assets = 'packages/dart_monty_core/assets';
const _workerUrl = '$_assets/dart_monty_core_proto_worker.js';

/// Every channel a test opened. Each test must leave all of them dead.
final _opened = <WorkerChannel>[];

Future<WorkerChannel> _spawn(
  WasmModuleCache cache, {
  bool forceNoJspi = false,
}) async {
  final ch = await WorkerChannel.spawn(
    cache,
    workerUrl: _workerUrl,
    forceNoJspi: forceNoJspi,
  );
  _opened.add(ch);

  return ch;
}

pb.ParentRequest _configure({int? maxMemory, int? maxRecursion}) =>
    pb.ParentRequest(
      configure: pb.Configure(
        scriptName: 'main.py',
        protocolVersion: workerProtocolVersion,
        limits: pb.ResourceLimits(
          maxMemoryBytes: maxMemory == null ? null : Int64(maxMemory),
          maxRecursionDepth: maxRecursion == null ? null : Int64(maxRecursion),
        ),
      ),
    );

pb.ParentRequest _feed(String code) =>
    pb.ParentRequest(feed: pb.Feed(code: code));

/// Configures [ch] with [config] (default limits otherwise) and checks Ok.
Future<void> _open(WorkerChannel ch, [pb.ParentRequest? config]) async {
  final ok = await ch.turn(config ?? _configure());
  expect(ok.whichKind(), pb.ChildEvent_Kind.ok);
}

/// Feeds [code] and returns the int it completes with.
Future<int> _evalInt(WorkerChannel ch, String code) async {
  final event = await ch.turn(_feed(code));
  expect(event.whichKind(), pb.ChildEvent_Kind.complete, reason: '$event');
  final complete = event.complete;
  final node =
      complete.values.nodes.elementAtOrNull(complete.value) ??
      fail('Complete names node ${complete.value}, not in its arena');
  expect(node.whichKind(), pb.MontyNode_Kind.int_5);

  return intOfNode(node).toInt();
}

/// The event that feeding [code] ends with, each of [inputs] bound under
/// its name.
Future<pb.ChildEvent> _turnWith(
  WorkerChannel ch,
  String code, [
  Map<String, MontyValue> inputs = const {},
]) {
  final writer = ArenaWriter();
  final refs = [
    for (final MapEntry(:key, :value) in inputs.entries)
      pb.NamedRef(name: key, value: writer.add(value)),
  ];

  return ch.turn(
    pb.ParentRequest(
      feed: pb.Feed(code: code, inputs: refs, values: writer.arena),
    ),
  );
}

/// The value a `Complete` carries, decoded by the arena reader.
MontyValue _valueOf(pb.ChildEvent event) {
  expect(event.whichKind(), pb.ChildEvent_Kind.complete, reason: '$event');

  return ArenaReader(event.complete.values)[event.complete.value];
}

/// What feeding [code] completes with, each of [inputs] bound.
Future<MontyValue> _eval(
  WorkerChannel ch,
  String code, [
  Map<String, MontyValue> inputs = const {},
]) async => _valueOf(await _turnWith(ch, code, inputs));

BigInt _bigOf(MontyValue v) => switch (v) {
  MontyInt(:final value) => BigInt.from(value),
  MontyBigInt(:final value) => value,
  _ => fail('$v is not an integer'),
};

/// The IEEE 754 bits of a decoded float, as 16 hex digits.
String _bits(MontyValue v) => switch (v) {
  MontyFloat(:final value) => [
    for (final b in (ByteData(8)..setFloat64(0, value)).buffer.asUint8List())
      b.toRadixString(16).padLeft(2, '0'),
  ].join(),
  _ => fail('$v is not a float'),
};

/// A fresh Worker on [cache] after a crash: configured, and answering.
Future<WorkerChannel> _replacement(
  WasmModuleCache cache, {
  bool forceNoJspi = false,
}) async {
  final fresh = await _spawn(cache, forceNoJspi: forceNoJspi);
  await _open(fresh);
  expect(await _evalInt(fresh, '1 + 1'), 2);

  return fresh;
}

/// Python that overflows the interpreter's native recursion: equality of two
/// 300,000-deep nested lists, with the recursion limit lifted so the
/// interpreter does not stop it first. A memory limit always comes with it.
const _deepCompare =
    'x = []\nfor i in range(300000):\n    x = [x]\n'
    'y = []\nfor i in range(300000):\n    y = [y]\nx == y';

void main() {
  const backend = identical(1, 1.0) ? 'dart2js' : 'dart2wasm';
  final cache = WasmModuleCache('$_assets/dart_monty_core_proto_worker.wasm');

  tearDown(() {
    final alive = _opened.where((c) => c.isAlive).length;
    for (final c in _opened) {
      c.kill();
    }
    _opened.clear();
    expect(alive, 0, reason: 'a test left $alive Worker(s) running');
  });

  kindRoundTripTests(backend, () async {
    final ch = await _spawn(cache);
    await _open(ch);

    return (ch.turn, ch.close);
  });

  test('JSPI is detected on Chrome; protocol matches ($backend)', () async {
    final ch = await _spawn(cache);
    expect(ch.jspi, isTrue);
    expect(ch.protocol, workerProtocolVersion);
    await _open(ch);
    expect(await _evalInt(ch, '1 + 1'), 2);
    await ch.close();
  });

  test('integers at the i64 edges, both ways ($backend)', () async {
    // package:protobuf's own zigzag decoding gets the |v| >= 2^62 ones wrong.
    final ch = await _spawn(cache);
    await _open(ch);
    final top = (BigInt.one << 63) - BigInt.one;
    final bottom = -(BigInt.one << 63);
    final out = await _eval(ch, '(2**62, -2**62 - 1, 2**63 - 1, -2**63)');
    expect(
      [for (final v in (out as MontyTuple).items) _bigOf(v)],
      [
        BigInt.one << 62,
        -(BigInt.one << 62) - BigInt.one,
        top,
        bottom,
      ],
    );
    final back = await _eval(ch, '(a == 2**63 - 1, b == -2**63)', {
      'a': MontyBigInt(top),
      'b': MontyBigInt(bottom),
    });
    expect(
      (back as MontyTuple).items,
      everyElement(const MontyBool(true)),
    );
    await ch.close();
  });

  test(
    "a NaN made in Dart reaches Python as float('nan') ($backend)",
    () async {
      final ch = await _spawn(cache);
      await _open(ch);
      final v = await _eval(
        ch,
        'import math\n(math.copysign(1.0, a), math.copysign(1.0, b))',
        {'a': const MontyFloat(double.nan), 'b': const MontyFloat(-double.nan)},
      );
      expect((v as MontyTuple).items, everyElement(const MontyFloat(1)));
      await ch.close();
    },
  );

  test("a NaN's sign survives Python -> Dart -> Python ($backend)", () async {
    final ch = await _spawn(cache);
    await _open(ch);
    final negative = await _eval(ch, "-float('nan')");
    expect((negative as MontyFloat).value.isNaN, isTrue);
    // A JavaScript number need not keep a NaN's sign (wire_scalars.dart), so
    // on dart2js only the round trip below is exact.
    if (backend == 'dart2wasm') expect(_bits(negative), 'fff8000000000000');
    final event = await _turnWith(
      ch,
      'import math\n(math.copysign(1.0, x), x)',
      {'x': negative},
    );
    final back = _valueOf(event) as MontyTuple;
    expect(back.items.firstOrNull, const MontyFloat(-1));
    // The bits Python sent back, read off the wire.
    final arena = event.complete.values;
    final tuple = arena.nodes.elementAtOrNull(event.complete.value);
    final x = arena.nodes.elementAtOrNull(tuple?.tuple.items.lastOrNull ?? -1);
    expect(x?.whichKind(), pb.MontyNode_Kind.float);
    expect(x?.float.toHexString(), 'FFF8000000000000');
    await ch.close();
  });

  test('two Workers share one compiled Module ($backend)', () async {
    final shared = WasmModuleCache(cache.wasmUrl);
    final [a, b] = await Future.wait(List.generate(2, (_) => _spawn(shared)));
    expect(shared.compileCount, 1);
    final module = await shared.module;
    expect(identical(await shared.module, module), isTrue);
    await Future.wait([_open(a), _open(b)]);
    expect(await _evalInt(a, 'x = 41\nx + 1'), 42);
    // Separate instances: b never saw a's `x`, so it asks the host, and the
    // host's "undefined" ends in NameError.
    final lookup = await b.turn(_feed('x'));
    expect(lookup.whichKind(), pb.ChildEvent_Kind.nameLookup);
    final missing = await b.turn(
      pb.ParentRequest(
        resumeNameLookup: pb.ResumeNameLookup(undefined: pb.Unit()),
      ),
    );
    expect(missing.whichKind(), pb.ChildEvent_Kind.error);
    expect(missing.error.exception.excType, 'NameError');
    expect(await _evalInt(b, '2 * 21'), 42);
    await Future.wait([a.close(), b.close()]);
    expect(shared.compileCount, 1);
  });

  test('Prints arrive in order before the turn end ($backend)', () async {
    final ch = await _spawn(cache);
    await _open(ch);
    final printed = StringBuffer();
    final end = await ch.turn(
      _feed('print("a")\nprint("b")\n3'),
      onPrint: (p) {
        for (final s in p.segments) {
          printed.write(s.text);
        }
      },
    );
    expect(end.whichKind(), pb.ChildEvent_Kind.complete);
    expect(printed.toString(), 'a\nb\n');
    await ch.close();
  });

  test('kill mid-turn is MontyCrashedError(killed) ($backend)', () async {
    final ch = await _spawn(cache);
    await _open(ch);
    final spinning = expectLater(
      ch.turn(_feed('while True:\n    pass')),
      throwsA(
        isA<MontyCrashedError>().having(
          (e) => e.cause,
          'cause',
          CrashCause.killed,
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    ch.kill();
    await spinning;
    expect(ch.isAlive, isFalse);
    await (await _replacement(cache)).close();
  });

  for (final noJspi in [false, true]) {
    final mode = noJspi ? 'forced fallback' : 'JSPI';
    test('a wasm trap is MontyCrashedError(vanished); a replacement '
        'Worker works ($mode, $backend)', () async {
      final ch = await _spawn(cache, forceNoJspi: noJspi);
      expect(ch.jspi, !noJspi);
      await _open(
        ch,
        _configure(maxMemory: 512 * 1024 * 1024, maxRecursion: 100000000),
      );
      await expectLater(
        ch.turn(_feed(_deepCompare)),
        throwsA(
          isA<MontyCrashedError>()
              .having((e) => e.cause, 'cause', CrashCause.vanished)
              // Chrome's text for a wasm stack overflow; CI runs Chrome.
              .having((e) => e.message, 'message', contains('RangeError')),
        ),
      );
      expect(ch.isAlive, isFalse);
      final fresh = await _replacement(cache, forceNoJspi: noJspi);
      // At default limits deep Python recursion stays in-band.
      final rec = await fresh.turn(
        _feed('def f(n):\n    return f(n + 1)\nf(0)'),
      );
      expect(rec.whichKind(), pb.ChildEvent_Kind.error);
      expect(rec.error.exception.excType, 'RecursionError');
      expect(fresh.isAlive, isTrue);
      await fresh.close();
    });
  }

  test('a protocol mismatch is refused before Configure ($backend)', () async {
    // A stand-in Worker that reports protocol 4 and nothing else.
    final url = _scriptUrl(
      'self.onmessage = () => '
      'self.postMessage({ready: true, jspi: false, protocol: 4});',
    );
    await expectLater(
      WorkerChannel.spawn(cache, workerUrl: url),
      throwsA(
        isA<MontyCrashedError>()
            .having((e) => e.cause, 'cause', CrashCause.fatal)
            .having((e) => e.message, 'message', contains('protocol 4')),
      ),
    );
  });

  test('a module that cannot be fetched fails spawn and is retried '
      '($backend)', () async {
    final missing = WasmModuleCache('$_assets/no_such_module.wasm');
    for (var attempt = 1; attempt <= 2; attempt++) {
      await expectLater(
        WorkerChannel.spawn(missing, workerUrl: _workerUrl),
        throwsA(isStateError),
      );
      expect(missing.compileCount, attempt);
    }
  });

  test('a Worker that never greets is terminated by a cancelled start '
      '($backend)', () async {
    // It loads, ignores Start, and beats on a BroadcastChannel until it is
    // terminated.
    final name = 'c1-silent-${DateTime.now().microsecondsSinceEpoch}';
    var beats = 0;
    final channel = _BroadcastChannel(name)
      ..onmessage = ((JSAny _) => beats++).toJS;
    // An interop member cannot be torn off.
    // ignore: unnecessary_lambdas
    addTearDown(() => channel.close());
    final url = _scriptUrl(
      'const c = new BroadcastChannel(${jsonEncode(name)}); '
      'setInterval(() => c.postMessage(1), 10);',
    );
    final cancel = Completer<void>();
    final spawning = WorkerChannel.spawn(
      cache,
      workerUrl: url,
      cancelled: cancel.future,
    );
    while (beats == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    cancel.complete();
    await expectLater(
      spawning,
      throwsA(
        isA<MontyCrashedError>().having(
          (e) => e.cause,
          'cause',
          CrashCause.killed,
        ),
      ),
    );
    final after = await _quiet(() => beats);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(beats, after, reason: 'the Worker still runs');
  });

  test('a cancel after the greeting leaves the channel alone '
      '($backend)', () async {
    final cancel = Completer<void>();
    final ch = await WorkerChannel.spawn(
      cache,
      workerUrl: _workerUrl,
      cancelled: cancel.future,
    );
    _opened.add(ch);
    cancel.complete();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(ch.isAlive, isTrue);
    await _open(ch);
    await ch.close();
  });

  test('workerScriptServed: the script yes; a 404 or a bad URL no '
      '($backend)', () async {
    expect(await workerScriptServed(_workerUrl), isTrue);
    expect(await workerScriptServed('$_assets/no_such_worker.js'), isFalse);
    expect(await workerScriptServed('http://[bad'), isFalse);
  });

  test('a start cancelled before the module is ready creates no Worker '
      '($backend)', () async {
    final unfetched = WasmModuleCache('$_assets/slow_or_missing.wasm');
    final cancel = Completer<void>()..complete();
    await expectLater(
      WorkerChannel.spawn(
        unfetched,
        workerUrl: _workerUrl,
        cancelled: cancel.future,
      ),
      throwsA(
        isA<MontyCrashedError>().having(
          (e) => e.cause,
          'cause',
          CrashCause.killed,
        ),
      ),
    );
  });

  test('openChannel finds the assets with no workerLocation, and a pool '
      'runs on it ($backend)', () async {
    final pool = await WorkerPool.start(
      const PoolOptions(maxProcesses: 1),
    );
    final lease = await pool.acquire();
    final ch = lease.channel as WorkerChannel;
    _opened.add(ch);
    await _open(ch);
    expect(await _evalInt(ch, '6 * 7'), 42);
    await lease.release();
    expect(pool.idleWorkers, 1);
    await pool.close();
    expect(ch.isAlive, isFalse);
    expect(defaultMaxProcesses(), greaterThanOrEqualTo(1));
  });

  test('a Worker that cannot load is MontyCrashedError(vanished) '
      '($backend)', () async {
    await expectLater(
      WorkerChannel.spawn(cache, workerUrl: '$_assets/no_such_worker.js'),
      throwsA(
        isA<MontyCrashedError>().having(
          (e) => e.cause,
          'cause',
          CrashCause.vanished,
        ),
      ),
    );
  });
}

/// Waits until [beats] stops changing for 200 ms.
Future<int> _quiet(int Function() beats) async {
  var last = beats();
  for (;;) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final now = beats();
    if (now == last) return now;
    last = now;
  }
}

String _scriptUrl(String source) => _createObjectUrl(
  _Blob([source.toJS].toJS, _BlobOptions(type: 'text/javascript')),
);

@JS('Blob')
extension type const _Blob._(JSObject _) implements JSObject {
  external factory _Blob(JSArray<JSString> parts, _BlobOptions options);
}

extension type const _BlobOptions._(JSObject _) implements JSObject {
  external factory _BlobOptions({String type});
}

@JS('URL.createObjectURL')
external String _createObjectUrl(_Blob blob);

@JS('BroadcastChannel')
extension type const _BroadcastChannel._(JSObject _) implements JSObject {
  external factory _BroadcastChannel(String name);
  external JSFunction? get onmessage;
  external set onmessage(JSFunction? handler);
  external void close();
}

// ProcessChannel against the real worker executable (tool/build_worker.sh, or
// the CI artefact), with raw monty-proto requests: there is no driver yet.
@Tags(['worker'])
@TestOn('vm')
library;

import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart'
    show MontyBigInt, MontyBool, MontyFloat, MontyInt, MontyTuple, MontyValue;
import 'package:dart_monty_core/src/worker/arena_reader.dart';
import 'package:dart_monty_core/src/worker/arena_writer.dart';
import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/wire_scalars.dart';
import 'package:dart_monty_core/src/worker/worker_locator.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

import '../../_accessors.dart';
import '../../unit/worker/_kind_round_trips.dart';
import '_worker_harness.dart';

/// Upstream monty-proto 1.1.0's `PROTOCOL_VERSION`.
const _protocolVersion = 5;

/// Every test bounds the worker's memory: an unbounded worker running away
/// was measured at 6 GB in three minutes.
const int _maxMemory = 64 * 1024 * 1024;

pb.ParentRequest _configure({
  int protocolVersion = _protocolVersion,
  int maxMemory = _maxMemory,
}) => pb.ParentRequest(
  configure: pb.Configure(
    scriptName: 'main.py',
    protocolVersion: protocolVersion,
    limits: pb.ResourceLimits(maxMemoryBytes: Int64(maxMemory)),
  ),
);

pb.ParentRequest _feed(String code) => pb.ParentRequest(
  feed: pb.Feed(code: code, cwd: '/'),
);

/// The [MontyCrashedError] that [future] fails with (see
/// process_channel_test.dart for why through the matcher).
Future<MontyCrashedError> _crashOf(Future<Object?> future) async {
  MontyCrashedError? seen;
  await expectLater(
    future,
    throwsA(
      isA<MontyCrashedError>().having((e) => seen = e, 'error', isNotNull),
    ),
  );

  return seen ?? fail('the matcher saw no MontyCrashedError');
}

/// A configured real worker, closed after the test.
Future<ProcessChannel> _configured({int maxMemory = _maxMemory}) async {
  final channel = await ProcessChannel.spawn(await realWorker());
  addTearDown(channel.close);
  final ok = await channel.turn(_configure(maxMemory: maxMemory));
  expect(ok.whichKind(), pb.ChildEvent_Kind.ok);

  return channel;
}

/// The int a `Complete` carries at its root node.
int _completeInt(pb.ChildEvent event) {
  expect(event.whichKind(), pb.ChildEvent_Kind.complete);
  final complete = event.complete;
  final root = complete.values.nodes.elementAtOrNull(complete.value);
  expect(root?.whichKind(), pb.MontyNode_Kind.int_5);

  return root == null
      ? fail('no root node in $complete')
      : intOfNode(root).toInt();
}

/// The value a `Complete` carries, decoded by the arena reader.
MontyValue _completeValue(pb.ChildEvent event) {
  expect(event.whichKind(), pb.ChildEvent_Kind.complete, reason: '$event');

  return ArenaReader(event.complete.values)[event.complete.value];
}

BigInt _bigOf(MontyValue v) => switch (v) {
  MontyInt(:final value) => BigInt.from(value),
  MontyBigInt(:final value) => value,
  _ => fail('$v is not an integer'),
};

/// A feed of [code] with each of [inputs] bound under its name.
pb.ParentRequest _feedWith(String code, Map<String, MontyValue> inputs) {
  final writer = ArenaWriter();
  final refs = [
    for (final MapEntry(:key, :value) in inputs.entries)
      pb.NamedRef(name: key, value: writer.add(value)),
  ];

  return pb.ParentRequest(
    feed: pb.Feed(code: code, cwd: '/', inputs: refs, values: writer.arena),
  );
}

void main() {
  expectNoWorkersLeftAfterEachTest();

  test('locates the built worker for this host', () async {
    final launch = await locateWorker();
    expect(
      launch,
      isA<WorkerExecutable>().having(
        (w) => w.path,
        'path',
        endsWith(workerPackagePath(Abi.current())),
      ),
    );
  });

  test('integers across the i64 range decode exactly', () async {
    // package:protobuf's own zigzag decoding gets four of these wrong.
    final channel = await _configured();
    for (final code in [
      '2**62 - 1',
      '2**62',
      '-2**62',
      '-2**62 - 1',
      '2**63 - 1',
      '-2**63',
      '2**64',
      '-2**64',
    ]) {
      final want = _pythonPower(code);
      expect(
        _bigOf(_completeValue(await channel.turn(_feed(code)))),
        want,
        reason: code,
      );
    }
  });

  test('integers at the i64 edges reach Python exactly', () async {
    final channel = await _configured();
    final top = (BigInt.one << 63) - BigInt.one;
    final bottom = -(BigInt.one << 63);
    final v = _completeValue(
      await channel.turn(
        _feedWith(
          '(a == 2**63 - 1, b == -2**63, c == 2**62, d == -2**62 - 1, a, b)',
          {
            'a': MontyBigInt(top),
            'b': MontyBigInt(bottom),
            'c': MontyBigInt(BigInt.one << 62),
            'd': MontyBigInt(-(BigInt.one << 62) - BigInt.one),
          },
        ),
      ),
    );
    final items = (v as MontyTuple).items;
    expect(items.take(4), everyElement(const MontyBool(true)));
    expect(_bigOf(itemAt(items, 4)), top);
    expect(_bigOf(itemAt(items, 5)), bottom);
  });

  test("a NaN's sign survives Python -> Dart -> Python", () async {
    final channel = await _configured();
    final nan = _completeValue(await channel.turn(_feed("float('nan')")));
    final negative = _completeValue(
      await channel.turn(_feed("-float('nan')")),
    );
    expect(_bits(nan), '7ff8000000000000');
    expect(_bits(negative), 'fff8000000000000');
    // Python sees the sign of the NaN it is given, and hands back the same
    // bits.
    final back = _completeValue(
      await channel.turn(
        _feedWith('import math\n(math.copysign(1.0, x), x)', {'x': negative}),
      ),
    );
    final items = (back as MontyTuple).items;
    expect(itemAt(items, 0), const MontyFloat(-1));
    expect(_bits(itemAt(items, 1)), 'fff8000000000000');
  });

  test("a NaN made in Dart reaches Python as float('nan')", () async {
    // double.nan's bits are the host's (fff8... on x86_64); -double.nan
    // flips the sign. Neither came from Python, so both go as 7ff8...
    final channel = await _configured();
    final v = _completeValue(
      await channel.turn(
        _feedWith(
          'import math\n(math.copysign(1.0, a), math.copysign(1.0, b))',
          {
            'a': const MontyFloat(double.nan),
            'b': const MontyFloat(-double.nan),
          },
        ),
      ),
    );
    expect((v as MontyTuple).items, everyElement(const MontyFloat(1)));
  });

  kindRoundTripTests('vm', () async {
    final channel = await _configured();

    return (channel.turn, channel.close);
  });

  test('Configure, Feed 1 + 1, Shutdown', () async {
    final channel = await _configured();
    expect(_completeInt(await channel.turn(_feed('1 + 1'))), 2);
    await channel.close();
    expect(await channel.exitCode, 0);
  });

  test('prints stream to onPrint before the turn ends', () async {
    final channel = await _configured();
    final text = StringBuffer();
    final end = await channel.turn(
      _feed('print("hello")\n3'),
      onPrint: (print) => text.writeAll([
        for (final segment in print.segments) segment.text,
      ]),
    );
    expect(text.toString(), 'hello\n');
    expect(_completeInt(end), 3);
  });

  test('a Python exception is in-band; the worker survives', () async {
    final channel = await _configured();
    final end = await channel.turn(_feed('1 / 0'));
    expect(end.whichKind(), pb.ChildEvent_Kind.error);
    expect(channel.isAlive, isTrue);
    expect(_completeInt(await channel.turn(_feed('2 + 2'))), 4);
  });

  test('max_memory inside the interpreter is in-band MemoryError', () async {
    final channel = await _configured(maxMemory: 16 * 1024 * 1024);
    final end = await channel.turn(
      _feed('x = []\nwhile True:\n    x.append("a" * 100000)'),
    );
    expect(end.whichKind(), pb.ChildEvent_Kind.error);
    expect(end.error.toString(), contains('MemoryError'));
    expect(channel.isAlive, isTrue);
  });

  test('protocol version skew: FatalError, exit 4', () async {
    final channel = await ProcessChannel.spawn(await realWorker());
    addTearDown(channel.close);
    final crash = await _crashOf(
      channel.turn(_configure(protocolVersion: 999)),
    );
    expect(crash.cause, CrashCause.fatal);
    expect(crash.exitCode, 4);
    expect(crash.message, contains('999'));
  });

  test('deadline kill, then a fresh worker answers', () async {
    final channel = await _configured();
    final turn = channel.turn(_feed('while True:\n    pass'));
    Timer(const Duration(milliseconds: 300), channel.kill);
    final crash = await _crashOf(turn);
    expect(crash.cause, CrashCause.killed);
    expect(channel.isAlive, isFalse);

    // Recovery is a new channel; the dead one is never reused.
    final fresh = await ProcessChannel.spawn(await realWorker());
    addTearDown(fresh.close);
    await fresh.turn(_configure());
    expect(_completeInt(await fresh.turn(_feed('1 + 1'))), 2);
  });
}

/// The value of a `2**n` expression in [code], as Python computes it.
BigInt _pythonPower(String code) {
  final m = RegExp(r'^(-?)2\*\*(\d+)(?: - 1)?$').firstMatch(code);
  if (m == null) fail('unexpected expression $code');
  final power = BigInt.one << int.parse(m[2] ?? '');
  final signed = m[1] == '-' ? -power : power;

  return code.endsWith(' - 1') ? signed - BigInt.one : signed;
}

/// The IEEE 754 bits of a decoded float, as 16 hex digits.
String _bits(MontyValue v) => switch (v) {
  MontyFloat(:final value) => [
    for (final b in (ByteData(8)..setFloat64(0, value)).buffer.asUint8List())
      b.toRadixString(16).padLeft(2, '0'),
  ].join(),
  _ => fail('$v is not a float'),
};

// WorkerConnection (lib/src/worker/worker_connection.dart): the browser
// channel's turn logic against a scripted WorkerPort. Pure Dart, so it runs on
// the VM, dart2js and dart2wasm through the unit and unit_web steps; the real
// Worker is exercised by worker_channel_web_test.dart.
import 'dart:async';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:dart_monty_core/dart_monty_core.dart' show MontyInt;
import 'package:dart_monty_core/src/worker/frame.dart';
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart'
    show MontyCrashedErrorInternal;
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/spawn_handle.dart';
import 'package:dart_monty_core/src/worker/wire_scalars.dart';
import 'package:dart_monty_core/src/worker/worker_connection.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

import '../../_accessors.dart';
import '_scripted_channel.dart' as scripted;

/// Records what the connection sends and whether it terminated the Worker.
final class _FakePort implements WorkerPort {
  final List<Uint8List> posted = [];
  int terminated = 0;
  final acknowledged = <int>[];

  @override
  void acknowledge(int bytes) => acknowledged.add(bytes);

  @override
  void post(Uint8List frame) => posted.add(frame);

  @override
  void terminate() => terminated++;
}

/// The ready reply of a Worker that started.
WorkerMessage _hello({
  bool jspi = true,
  int protocol = workerProtocolVersion,
}) => (
  ready: true,
  error: null,
  jspi: jspi,
  protocol: protocol,
  events: null,
  outcome: null,
  trap: null,
  print: null,
  stderr: null,
);

/// A later Worker message: a turn reply, or a trap.
WorkerMessage _message({
  Uint8List? events,
  int? outcome,
  String? trap,
  String? stderr,
  Uint8List? print,
}) => (
  ready: null,
  error: null,
  jspi: null,
  protocol: null,
  events: events,
  outcome: outcome,
  trap: trap,
  print: print,
  stderr: stderr,
);

WorkerConnection _accept(_FakePort port, {Duration? grace}) =>
    WorkerConnection.accept(
      port,
      _hello(),
      closeGrace: grace ?? workerCloseGrace,
    );

Uint8List _frames(List<pb.ChildEvent> events) =>
    Uint8List.fromList([for (final e in events) ...Frame.encode(e)]);

pb.ChildEvent _print(String text) => pb.ChildEvent(
  print: pb.Print(
    segments: [
      pb.PrintSegment(stream: pb.PrintStream.PRINT_STREAM_STDOUT, text: text),
    ],
  ),
);

final pb.ChildEvent _ok = pb.ChildEvent(ok: pb.Ok());
final pb.ParentRequest _feed = pb.ParentRequest(feed: pb.Feed(code: '1 + 1'));

Matcher _crashed(CrashCause cause, [Object? detail]) => isA<MontyCrashedError>()
    .having((e) => e.cause, 'cause', cause)
    .having((e) => e.detail, 'detail', detail ?? anything);

final Matcher _throwsKilled = throwsA(_crashed(CrashCause.killed));
final Matcher _throwsVanished = throwsA(_crashed(CrashCause.vanished));

/// The one request [port] was sent, decoded.
pb.ParentRequest _onlyRequest(_FakePort port) {
  final bodies = [for (final f in port.posted) ...Frame.split(f)];
  expect(bodies, hasLength(1));

  return pb.ParentRequest.fromBuffer(bodies.firstOrNull ?? fail('none sent'));
}

/// Starts a turn, lets it post, and returns its future.
Future<pb.ChildEvent> _start(
  WorkerConnection c, {
  void Function(pb.Print)? onPrint,
}) => c.turn(_feed, onPrint: onPrint);

void main() {
  // Framing failures match terminal replies: torn/oversized frames mean a
  // vanished worker; a whole but invalid payload is a protocol violation.
  for (final (name, batch, cause) in [
    ('truncated', Uint8List.fromList([2, 0, 0, 0, 0x22]), CrashCause.vanished),
    ('oversized', Uint8List.fromList([1, 0, 0, 16]), CrashCause.vanished),
    ('invalid payload', Frame.wrap([0xff]), CrashCause.protocol),
    ('non-Print payload', Frame.encode(_ok), CrashCause.protocol),
  ]) {
    test('R1 malformed streamed $name releases the pool slot', () async {
      final port = _FakePort();
      final c = _accept(port);
      final replacement = scripted.ScriptedChannel([
        scripted.expecting(pb.ParentRequest_Kind.configure, [scripted.ok()]),
        scripted.answer([
          scripted.complete([intNode(42)]),
        ]),
        scripted.expecting(pb.ParentRequest_Kind.reset, [scripted.ok()]),
      ]);
      var starts = 0;
      final pool = await startMonty(
        const PoolOptions(
          minProcesses: 0,
          maxProcesses: 1,
          checkoutTimeout: Duration(seconds: 1),
        ),
        open: () => PendingSpawn((_) async => ++starts == 1 ? c : replacement),
      );
      addTearDown(pool.close);
      final checkout = pool.checkout();
      await pumpEventQueue();
      expect(_onlyRequest(port).whichKind(), pb.ParentRequest_Kind.configure);
      c.onReply(_frames([_ok]), outcomeContinue);
      final session = await checkout;
      addTearDown(session.close);
      var callbacks = 0;
      final failed = expectLater(
        session.feedRun('print("x")', printCallback: (_, _) => callbacks++),
        throwsA(_crashed(cause)),
      );
      await pumpEventQueue();
      c.onMessage(_message(print: batch));
      await failed;
      expect(callbacks, 0);
      expect(c.isAlive, isFalse);
      expect(port.terminated, 1);
      expect(port.acknowledged, isEmpty);
      await expectLater(c.turn(_feed), throwsA(_crashed(cause)));
      expect(pool.liveWorkers, 0);
      // Do not close the failed session before checkout: crash cleanup must
      // release its sole slot without help from the caller.
      final next = await pool.checkout();
      expect(starts, 2);
      expect(
        await next.feedRun('6 * 7', printCallback: (_, _) => callbacks++),
        const MontyInt(42),
      );
      await next.close();
    });
  }

  for (final error in <Exception>[
    const FormatException('sink'),
    const FrameTruncatedException(3),
    const FrameTooLargeException(9, 8),
  ]) {
    test(
      'R1 streamed callback preserves $error and kills the worker',
      () async {
        final port = _FakePort();
        final c = _accept(port);
        final failed = expectLater(
          _start(c, onPrint: (_) => throw error),
          throwsA(same(error)),
        );
        c.onMessage(_message(print: _frames([_print('a')])));
        await failed;
        expect(port.terminated, 1);
        expect(port.acknowledged, isEmpty);
        await expectLater(c.turn(_feed), _throwsKilled);
      },
    );
  }

  test('R1 streamed batches settle in order before the reply', () async {
    final port = _FakePort();
    final c = _accept(port);
    final gate = Completer<void>();
    final seen = <String>[];
    var completed = false;
    Future<pb.ChildEvent> runTurn() async {
      final value = await c.turn(
        _feed,
        onPrint: (p) async {
          seen.add(
            p.segments.firstOrNull?.text ?? fail('missing print segment'),
          );
          if (seen.length == 1) await gate.future;
        },
      );
      completed = true;

      return value;
    }

    final turn = runTurn();
    final a = _frames([_print('a')]);
    final b = _frames([_print('b')]);
    c
      ..onMessage(_message(print: a))
      ..onMessage(_message(print: b))
      ..onReply(_frames([_ok]), outcomeContinue);
    await Future<void>.delayed(Duration.zero);
    expect(seen, ['a']);
    expect(completed, isFalse);
    expect(port.acknowledged, isEmpty);
    expect(c.pendingPrintBytes, a.length + b.length);
    gate.complete();
    await turn;
    expect(seen, ['a', 'b']);
    expect(port.acknowledged, [a.length, b.length]);
    expect(c.pendingPrintBytes, 0);
    c.kill();
  });

  test(
    'R1 kill cancels queued and late prints without awaiting callback',
    () async {
      final port = _FakePort();
      final c = _accept(port);
      final gate = Completer<void>();
      final seen = <String>[];
      final turn = c.turn(
        _feed,
        onPrint: (p) async {
          seen.add(
            p.segments.firstOrNull?.text ?? fail('missing print segment'),
          );
          await gate.future;
        },
      );
      final failed = expectLater(turn, _throwsKilled);
      c
        ..onMessage(_message(print: _frames([_print('a')])))
        ..onMessage(_message(print: _frames([_print('b')])))
        ..onReply(_frames([_ok]), outcomeContinue);
      await Future<void>.delayed(Duration.zero);
      c.kill();
      await failed;
      c.onMessage(_message(print: _frames([_print('late')])));
      gate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(seen, ['a']);
      expect(port.acknowledged, isEmpty);
      expect(c.pendingPrintBytes, 0);
    },
  );

  for (final (tail, expected) in [
    (
      'monty worker: allocation of 123 bytes exceeds the memory limit\n',
      CrashCause.outOfMemory,
    ),
    (
      'noise\nmonty worker: allocation of 123 bytes failed\n\n',
      CrashCause.outOfMemory,
    ),
    (
      'monty worker: allocation of 123 bytes failed\nother\n',
      CrashCause.vanished,
    ),
    (
      'prefix monty worker: allocation of 123 bytes failed',
      CrashCause.vanished,
    ),
    ('', CrashCause.vanished),
  ]) {
    test('R1 trap classifies only last stderr line: $tail', () async {
      final c = _accept(_FakePort());
      final turn = c.turn(_feed);
      final failed = expectLater(
        turn,
        throwsA(
          isA<MontyCrashedError>()
              .having((e) => e.cause, 'cause', expected)
              .having((e) => e.stderrTail, 'stderr', tail),
        ),
      );
      c.onMessage(
        _message(
          trap: 'trap\nmonty worker: allocation of 123 bytes failed',
          stderr: tail,
        ),
      );
      await failed;
    });
  }

  group('accept', () {
    test('a matching protocol is accepted and exposes the probe', () {
      final port = _FakePort();
      final c = _accept(port);
      expect(c.jspi, isTrue);
      expect(c.protocol, workerProtocolVersion);
      expect(c.isAlive, isTrue);
      expect(port.terminated, 0);
    });

    test('protocol skew is refused before any request, as fatal', () {
      final port = _FakePort();
      expect(
        () => WorkerConnection.accept(port, _hello(protocol: 4)),
        throwsA(_crashed(CrashCause.fatal, contains('protocol 4'))),
      );
      expect(port.terminated, 1);
      expect(port.posted, isEmpty);
    });

    test('a Worker that did not start is refused as vanished', () {
      final port = _FakePort();
      expect(
        () => WorkerConnection.accept(port, workerFailure('no module')),
        throwsA(_crashed(CrashCause.vanished, 'no module')),
      );
      expect(port.terminated, 1);
    });

    test('a ready reply without a protocol is skew', () {
      final hello = _hello();
      expect(
        () => WorkerConnection.accept(_FakePort(), (
          ready: true,
          error: null,
          jspi: hello.jspi,
          protocol: null,
          events: null,
          outcome: null,
          trap: null,
          print: null,
          stderr: null,
        )),
        throwsA(_crashed(CrashCause.fatal, contains('protocol null'))),
      );
    });

    test('a ready reply without jspi reads as no JSPI', () {
      final c = WorkerConnection.accept(_FakePort(), (
        ready: true,
        error: null,
        jspi: null,
        protocol: workerProtocolVersion,
        events: null,
        outcome: null,
        trap: null,
        print: null,
        stderr: null,
      ));
      expect(c.jspi, isFalse);
    });
  });

  group('onMessage', () {
    test('routes a turn reply', () async {
      final c = _accept(_FakePort());
      final done = _start(c);
      c.onMessage(_message(events: _frames([_ok]), outcome: outcomeContinue));
      expect((await done).whichKind(), pb.ChildEvent_Kind.ok);
    });

    test('routes a trap', () async {
      final c = _accept(_FakePort());
      final done = expectLater(
        _start(c),
        throwsA(_crashed(CrashCause.vanished, 'unreachable')),
      );
      c.onMessage(_message(trap: 'unreachable'));
      await done;
    });

    test('a reply with no outcome is not a Continue', () async {
      final c = _accept(_FakePort());
      final done = expectLater(_start(c), throwsA(_crashed(CrashCause.fatal)));
      c.onMessage(_message(events: _frames([_ok])));
      await done;
    });

    test('anything else is a Worker error', () {
      final c = _accept(_FakePort())..onMessage(_message());
      expect(c.isAlive, isFalse);
      expect(
        () => c.turn(_feed),
        throwsA(_crashed(CrashCause.vanished, contains('unrecognised'))),
      );
    });
  });

  group('OnceAsync', () {
    test('produces once and shares the value', () async {
      var made = 0;
      final once = OnceAsync<int>(() async => ++made);
      expect(once.runs, 0);
      final values = await Future.wait([once.value, once.value]);
      expect(values, [1, 1]);
      expect(await once.value, 1);
      expect(once.runs, 1);
    });

    test('a failure is not kept; the next use retries', () async {
      var attempt = 0;
      final once = OnceAsync<String>(() async {
        attempt++;
        if (attempt == 1) throw StateError('first');

        return 'second';
      });
      await expectLater(once.value, throwsStateError);
      expect(await once.value, 'second');
      expect(once.runs, 2);
    });
  });

  group('turn', () {
    test('posts one frame, delivers Prints in order, returns the turn '
        'end', () async {
      final port = _FakePort();
      final c = _accept(port);
      final prints = <String>[];
      final done = _start(
        c,
        onPrint: (p) => prints.add(p.segments.map((s) => s.text).join()),
      );
      expect(port.posted, [Frame.encode(_feed)]);
      c.onReply(
        _frames([_print('a'), _print('b'), _ok]),
        outcomeContinue,
      );
      expect((await done).whichKind(), pb.ChildEvent_Kind.ok);
      expect(prints, ['a', 'b']);
      expect(c.isAlive, isTrue);
    });

    test('an async onPrint is awaited before the next event', () async {
      final c = _accept(_FakePort());
      final gates = <Completer<void>>[];
      // A tear-off, not a closure literal, so that it also compiles where
      // onPrint is a `void Function`.
      Future<void> gated(pb.Print _) {
        final gate = Completer<void>();
        gates.add(gate);

        return gate.future;
      }

      var ended = false;
      final done = c
          .turn(_feed, onPrint: gated)
          .whenComplete(() => ended = true);
      c.onReply(_frames([_print('a'), _print('b'), _ok]), outcomeContinue);
      await pumpEventQueue();
      expect(gates, hasLength(1));
      expect(ended, isFalse);
      itemAt(gates, 0).complete();
      await pumpEventQueue();
      expect(gates, hasLength(2));
      expect(ended, isFalse);
      itemAt(gates, 1).complete();
      expect((await done).whichKind(), pb.ChildEvent_Kind.ok);
    });

    test('a kill from inside onPrint fails the turn as killed', () async {
      final port = _FakePort();
      late final WorkerConnection c;
      c = _accept(port);
      final done = expectLater(
        _start(c, onPrint: (_) => c.kill()),
        _throwsKilled,
      );
      c.onReply(_frames([_print('a'), _ok]), outcomeContinue);
      await done;
      expect(c.isAlive, isFalse);
      expect(port.terminated, 1);
    });

    test(
      'onPrint throwing kills the Worker; the error reaches the caller',
      () async {
        final port = _FakePort();
        final c = _accept(port);
        final done = expectLater(
          _start(c, onPrint: (_) => throw const FormatException('host bug')),
          throwsFormatException,
        );
        final lookup = pb.ChildEvent(nameLookup: pb.NameLookup(name: 'x'));
        c.onReply(_frames([_print('a'), lookup]), outcomeContinue);
        await done;
        // The NameLookup was never delivered, so the Worker is left waiting for
        // an answer nobody will send: it must not be reusable.
        expect(c.isAlive, isFalse);
        expect(port.terminated, 1);
        expect(() => c.turn(_feed), _throwsKilled);
      },
    );

    test('no second turn can start from inside onPrint', () async {
      final c = _accept(_FakePort());
      Object? reentered;
      final done = _start(
        c,
        onPrint: (_) => c.turn(_feed).catchError((Object e) {
          reentered = e;

          return _ok;
        }),
      );
      c.onReply(_frames([_print('a'), _ok]), outcomeContinue);
      await done;
      await pumpEventQueue();
      expect(reentered, isStateError);
    });

    test('Prints without a callback are dropped', () async {
      final c = _accept(_FakePort());
      final done = _start(c);
      c.onReply(_frames([_print('x'), _ok]), outcomeContinue);
      expect((await done).whichKind(), pb.ChildEvent_Kind.ok);
    });

    test('one turn at a time', () {
      final c = _accept(_FakePort());
      _start(c).ignore();
      expect(() => c.turn(_feed), throwsStateError);
    });

    test('a reply with no turn waiting is ignored', () async {
      final c = _accept(_FakePort())..onReply(_frames([_ok]), 0);
      expect(c.isAlive, isTrue);
      final done = _start(c);
      c.onReply(_frames([_ok]), outcomeContinue);
      expect((await done).whichKind(), pb.ChildEvent_Kind.ok);
    });

    test('FatalError is a fatal crash and kills the Worker', () async {
      final port = _FakePort();
      final c = _accept(port);
      final done = _start(c);
      c.onReply(
        _frames([
          pb.ChildEvent(fatalError: pb.FatalError(message: 'boom')),
        ]),
        2,
      );
      final boom = throwsA(_crashed(CrashCause.fatal, 'boom'));
      await expectLater(done, boom);
      expect(c.isAlive, isFalse);
      expect(port.terminated, 1);
      expect(() => c.turn(_feed), boom);
    });

    test('a Fatal outcome after a turn end is a fatal crash', () async {
      final c = _accept(_FakePort());
      final done = _start(c);
      c.onReply(_frames([_ok]), 2);
      await expectLater(
        done,
        throwsA(_crashed(CrashCause.fatal, contains('outcome 2'))),
      );
    });

    test('a Shutdown outcome closes the channel after the turn', () async {
      final port = _FakePort();
      final c = _accept(port);
      final done = _start(c);
      c.onReply(_frames([_ok]), outcomeShutdown);
      expect((await done).whichKind(), pb.ChildEvent_Kind.ok);
      expect(c.isAlive, isFalse);
      expect(port.terminated, 1);
      expect(() => c.turn(_feed), throwsStateError);
    });

    test('a torn reply is a vanished crash', () async {
      final c = _accept(_FakePort());
      final done = _start(c);
      final whole = Frame.encode(_ok);
      c.onReply(Uint8List.sublistView(whole, 0, whole.length - 1), 0);
      await expectLater(
        done,
        throwsA(_crashed(CrashCause.vanished, contains('unreadable'))),
      );
    });

    test('a reply frame upstream rejects is a protocol violation, after the '
        'Prints before it', () async {
      final port = _FakePort();
      final c = _accept(port);
      final prints = <String>[];
      final done = _start(
        c,
        onPrint: (p) => prints.add(p.segments.map((s) => s.text).join()),
      );
      // Complete { values { nodes: [ { str: "\xc3\x28" } ] } }: invalid
      // UTF-8, which package:protobuf alone accepts.
      final body = [0x32, 8, 0x12, 6, 0x12, 4, 0x42, 2, 0xc3, 0x28];
      expect(
        pb.ChildEvent.fromBuffer(body).complete.values.nodes,
        hasLength(1),
      );
      final bad = Frame.wrap(body);
      c.onReply(
        Uint8List.fromList([
          ..._frames([_print('before')]),
          ...bad,
        ]),
        outcomeContinue,
      );
      await expectLater(
        done,
        throwsA(
          _crashed(
            CrashCause.protocol,
            startsWith('invalid payload from worker: '),
          ),
        ),
      );
      expect(prints, ['before']);
      expect(c.isAlive, isFalse);
      expect(port.terminated, 1);
    });

    // A payload upstream's decoder rejects, as a whole frame: upstream's
    // pool reports `invalid payload from worker: ` and prost's `DecodeError`
    // display (checkout.rs:1688-1689, lib.rs:251). Texts recorded by decoding
    // each body with monty-proto 1.1.0's `decode_frame`.
    for (final (name, body, error) in <(String, List<int>, String)>[
      (
        'malformed UTF-8 in a str node',
        [0x32, 8, 0x12, 6, 0x12, 4, 0x42, 2, 0xc3, 0x28],
        'MontyNode.kind: Complete.values: ChildEvent.kind: '
            'invalid string value: data is not UTF-8 encoded',
      ),
      (
        'a date outside the date invariants',
        [
          0x32, 0x0e, 0x12, 0x0c, 0x12, 0x0a, 0x8a, 0x01, 0x07, 0x08, 0xe8, //
          0x0f, 0x10, 0x0d, 0x18, 0x01,
        ],
        'Complete.values: ChildEvent.kind: '
            'invalid value for Date.month: 13 is outside the range 1..=12',
      ),
      (
        'a datetime outside the datetime invariants',
        [
          0x32, 0x10, 0x12, 0x0e, 0x12, 0x0c, 0x9a, 0x01, 0x09, 0x08, 0xe8, //
          0x0f, 0x10, 0x01, 0x18, 0x01, 0x20, 0x18,
        ],
        'Complete.values: ChildEvent.kind: '
            'invalid value for DateTime.hour: 24 is outside the range 0..=23',
      ),
      (
        'malformed UTF-8 in a datetime timezoneName',
        [
          0x32, 0x12, 0x12, 0x10, 0x12, 0x0e, 0x9a, 0x01, 0x0b, 0x08, 0xe8, //
          0x0f, 0x10, 0x01, 0x18, 0x01, 0x4a, 0x02, 0xc3, 0x28,
        ],
        'DateTime.timezone_name: MontyNode.kind: Complete.values: '
            'ChildEvent.kind: invalid string value: data is not UTF-8 encoded',
      ),
    ]) {
      test("$name: a protocol violation with upstream's text", () async {
        final port = _FakePort();
        final c = _accept(port);
        final done = _start(c);
        c.onReply(Frame.wrap(body), outcomeContinue);
        final MontyCrashedError crash;
        try {
          await done;
          fail('decoded');
        } on MontyCrashedError catch (e) {
          crash = e;
        }
        expect(
          crash.toString(),
          'monty worker protocol error: invalid payload from worker: '
          'failed to decode Protobuf message: $error',
        );
        expect((crash.timedOut, crash.exitStatus), (false, null));
        expect(c.isAlive, isFalse);
        expect(port.terminated, 1);
      });
    }

    test('an oversized request is refused before it is posted; the channel '
        'stays usable', () async {
      final port = _FakePort();
      final c = _accept(port);
      final node = pb.MontyNode(str: 'x' * (1 << 20));
      final huge = pb.ParentRequest(
        feed: pb.Feed(values: pb.Arena(nodes: List.filled(300, node))),
      );
      await expectLater(
        c.turn(huge),
        throwsA(isA<FrameTooLargeException>()),
      );
      expect(port.posted, isEmpty);
      expect(c.isAlive, isTrue);
      final done = _start(c);
      expect(_onlyRequest(port), _feed);
      c.onReply(_frames([_ok]), outcomeContinue);
      expect((await done).whichKind(), pb.ChildEvent_Kind.ok);
    });

    test('a reply without a turn-ending event is a vanished crash', () async {
      final c = _accept(_FakePort());
      final done = _start(c);
      c.onReply(_frames([_print('only')]), 0);
      await expectLater(
        done,
        throwsA(_crashed(CrashCause.vanished, contains('turn-ending'))),
      );
    });

    test('a trap fails the turn as vanished and poisons the channel', () async {
      final port = _FakePort();
      final c = _accept(port);
      final done = _start(c);
      c.onTrap('RangeError: Maximum call stack size exceeded');
      final trapped = throwsA(
        _crashed(CrashCause.vanished, startsWith('RangeError')),
      );
      await expectLater(done, trapped);
      expect(c.isAlive, isFalse);
      expect(port.terminated, 1);
      expect(() => c.turn(_feed), trapped);
    });

    test('a Worker error between turns poisons the channel', () {
      final c = _accept(_FakePort())..onWorkerError('script error');
      expect(c.isAlive, isFalse);
      expect(
        () => c.turn(_feed),
        throwsA(_crashed(CrashCause.vanished, 'script error')),
      );
    });
  });

  group('kill', () {
    test('mid-turn fails the turn as killed; idempotent', () async {
      final port = _FakePort();
      final c = _accept(port);
      final done = _start(c);
      c
        ..kill()
        ..kill();
      await expectLater(done, _throwsKilled);
      expect(port.terminated, 1);
      expect(c.isAlive, isFalse);
      expect(() => c.turn(_feed), _throwsKilled);
      // A late reply from the terminated Worker changes nothing.
      c.onReply(_frames([_ok]), 0);
      expect(c.isAlive, isFalse);
    });

    test('after a crash keeps the original cause', () async {
      final c = _accept(_FakePort());
      final done = _start(c);
      c
        ..onTrap('trap')
        ..kill();
      await expectLater(done, _throwsVanished);
      expect(() => c.turn(_feed), _throwsVanished);
    });
  });

  group('close', () {
    test('sends Shutdown, terminates on the reply; idempotent', () async {
      final port = _FakePort();
      final c = _accept(port);
      final first = c.close();
      expect(identical(c.close(), first), isTrue);
      expect(c.isAlive, isFalse);
      expect(_onlyRequest(port).whichKind(), pb.ParentRequest_Kind.shutdown);
      c.onReply(Uint8List(0), outcomeShutdown);
      await first;
      expect(port.terminated, 1);
      expect(() => c.turn(_feed), throwsStateError);
      await c.close();
      expect(port.terminated, 1);
    });

    test('terminates after the grace when the Worker never answers', () async {
      final port = _FakePort();
      final c = _accept(port, grace: const Duration(milliseconds: 10));
      await c.close();
      expect(port.terminated, 1);
      expect(c.isAlive, isFalse);
    });

    // Upstream's pool waits SHUTDOWN_EXIT_GRACE, 500 ms, for a closed idle
    // worker (monty-pool pool.rs:184-186).
    test("the default grace is upstream's 500 ms", () async {
      final port = _FakePort();
      final c = _accept(port);
      final clock = Stopwatch()..start();
      await c.close();
      expect(
        clock.elapsedMilliseconds,
        allOf(greaterThanOrEqualTo(450), lessThan(1500)),
      );
      expect(port.terminated, 1);
    });

    test('during a turn kills it', () async {
      final port = _FakePort();
      final c = _accept(port);
      final done = expectLater(_start(c), _throwsKilled);
      await c.close();
      await done;
      expect(port.terminated, 1);
    });

    test('a kill while closing still terminates once', () async {
      final port = _FakePort();
      final c = _accept(port);
      final closing = c.close();
      c.kill();
      await closing;
      expect(port.terminated, 1);
      expect(() => c.turn(_feed), _throwsKilled);
    });

    test('on a dead channel does nothing', () async {
      final port = _FakePort();
      final c = _accept(port)..onTrap('t');
      await c.close();
      expect(port.posted, isEmpty);
      expect(port.terminated, 1);
    });
  });
}

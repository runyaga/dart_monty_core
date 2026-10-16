// Metadata and terminal snapshot state over independent protocol replies.
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:test/test.dart';

import '_arena_fixtures.dart' as arena;
import '_scripted_channel.dart';
import '_spec_proto_support.dart';

Matcher _stateMessage(String message) =>
    isA<StateError>().having((e) => e.message, 'message', message);

void main() {
  for (final kind in ['dict', 'set', 'frozenset']) {
    test('proxy in $kind loses the session', () async {
      final nodes = [
        arena.classType('P', id: arena.uuid(1)),
        arena.instance(0, id: arena.uuid(2), attrs: pb.NodePairs()),
        switch (kind) {
          'dict' => arena.dict([(1, 0)]),
          'set' => arena.set([1]),
          _ => arena.frozen([1]),
        },
      ];
      final (session, channel) = await protoConfiguredSession([
        answer([complete(nodes)]),
      ]);
      await expectLater(
        session.feedRun('result'),
        throwsA(
          protoCrash(
            'invalid payload from worker: TypeError: unhashable '
            "type: 'MontyClassProxy'",
          ),
        ),
      );
      expect(channel.isAlive, isFalse);
      await expectLater(session.feedRun('42'), throwsStateError);
    });
  }

  test(
    'missing position has empty filename and zero offsets',
    () async {
      final (session, _) = await protoConfiguredSession([
        answer([protoCall()]),
        answer([pb.ChildEvent(nameLookup: pb.NameLookup(name: 'x'))]),
        answer([
          pb.ChildEvent(resolveFutures: pb.ResolveFutures(pendingCallIds: [1])),
        ]),
      ]);
      final call = await session.feedStart('f()') as FunctionSnapshot;
      final lookup =
          await call.resume(const ExternalFuture()) as NameLookupSnapshot;
      final futures =
          await lookup.resume(value: const MontyInt(3)) as FutureSnapshot;
      for (final position in [
        call.position,
        lookup.position,
        futures.position,
      ]) {
        expect(position.filename, '');
        expect(position.start, 0);
        expect(position.end, 0);
      }
    },
  );

  for (final restored in [false, true]) {
    test(
      'orphan futures terminate '
      '(restored=$restored)',
      () async {
        final (session, channel) = await protoConfiguredSession([
          answer([
            pb.ChildEvent(
              resolveFutures: pb.ResolveFutures(pendingCallIds: [1]),
            ),
          ]),
        ]);
        final snapshot =
            (restored
                    ? await session.loadSnapshot(Uint8List.fromList([1, 2, 3]))
                    : await session.feedStart('await f()'))
                as FutureSnapshot;
        await expectLater(
          snapshot.resumeAuto(),
          throwsA(
            _stateMessage(
              'No pending async tasks but ResolveFutures requested',
            ),
          ),
        );
        // traceContext publicly reports that the snapshot was consumed.
        expect(
          snapshot.traceContext,
          throwsA(
            _stateMessage('snapshot has already been resumed'),
          ),
        );
        expect(channel.isAlive, isFalse);
        await expectLater(session.feedRun('42'), throwsStateError);
      },
    );
  }
}

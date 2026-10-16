// The Dart boundary for a scripted worker refusal during restore.  This does
// not exercise the native worker's oversized-restoration check.
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:test/test.dart';

import '_scripted_channel.dart';
import '_spec_proto_support.dart';

void main() {
  for (final snapshot in [false, true]) {
    test(
      'scripted restore refusal leaves no suspension '
      '($snapshot)',
      () async {
        const message =
            'protocol violation: argument frame of 268435457 bytes '
            'exceeds the maximum of 268435456 bytes';
        final (session, channel) = await protoConfiguredSession([
          expecting(pb.ParentRequest_Kind.load, [
            raised('RuntimeError', message),
          ]),
          answer([protoInt(42)]),
        ]);
        final bytes = Uint8List.fromList([1, 2, 3]);
        final load = snapshot
            ? session.loadSnapshot(bytes)
            : session.loadSession(bytes);
        await expectLater(load, throwsA(protoRuntime('RuntimeError', message)));
        expect(await session.feedRun('42'), const MontyInt(42));
        expect(channel.kills, 0);
        await expectLater(session.loadSession(bytes), throwsStateError);
        expect(channel.requests, hasLength(3));
      },
    );
  }
}

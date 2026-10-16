// ExternalException and RandomSeed contracts, independent of a real worker.
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/os_policy.dart';
import 'package:test/test.dart';

import '_scripted_channel.dart';
import '_spec_proto_support.dart';

void main() {
  test(
    'dotted exception names can be resumed',
    () async {
      for (final type in [
        'json.JSONDecodeError',
        'io.UnsupportedOperation',
        're.PatternError',
        'binascii.Error',
        'binascii.Incomplete',
      ]) {
        final (session, channel) = await protoSession([
          answer([protoCall()]),
          answer([protoInt(3)]),
        ]);
        final call = await session.feedStart('f()') as FunctionSnapshot;
        final done = await call.resume(ExternalException(type, 'detail'));
        expect((done as MontyComplete).output, const MontyInt(3));
        final request = channel.requests.lastOrNull ?? fail('missing resume');
        final error = request.resumeCall.result.error;
        expect(error.excType, type);
        expect(error.message, 'detail');
      }
    },
  );

  test(
    'equality includes nested attributes and fields',
    () {
      const shared = MontyList([MontyInt(1)]);
      const a = ExternalException('ValueError', 'detail', {
        'nested': MontyTuple([shared, shared]),
      });
      const b = ExternalException('ValueError', 'detail', {
        'nested': MontyTuple([
          MontyList([MontyFloat(1)]),
          MontyList([MontyInt(1)]),
        ]),
      });
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      final variants = [
        ExternalException('TypeError', 'detail', a.attributes),
        ExternalException('ValueError', '', a.attributes),
        ExternalException('ValueError', null, a.attributes),
        const ExternalException('ValueError', 'detail', {
          'nested': MontyTuple([
            MontyList([MontyInt(2)]),
            MontyList([MontyInt(1)]),
          ]),
        }),
      ];
      for (final other in variants) {
        expect(a == other, isFalse);
        expect(other == a, isFalse);
        expect(other.hashCode, isNot(a.hashCode));
      }
      // A cyclic attribute compares equal to itself by identity.
      final cycle = protoCycle();
      expect(
        ExternalException('ValueError', null, {'x': cycle}),
        ExternalException('ValueError', null, {'x': cycle}),
      );
    },
  );

  test(
    'bytes are copied and immutable',
    () {
      final input = Uint8List.fromList([1, 255]);
      final seed = RandomSeed.bytes(input);
      input[0] = 9;
      final bytes = seed.toProto().bytes;
      expect(bytes, [1, 255]);
      expect(() => bytes[0] = 7, throwsUnsupportedError);
      expect(seed, RandomSeed.bytes(Uint8List.fromList([1, 255])));
    },
  );

  test(
    'nonfinite floats survive construction unchanged',
    () {
      for (final value in [
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        final seed = RandomSeed.float(value);
        final wire = seed.toProto();
        expect(wire.hasFloat(), isTrue);
        if (value.isNaN) {
          expect(wire.float.isNaN, isTrue);
        } else {
          expect(wire.float, value);
        }
      }
    },
  );
}

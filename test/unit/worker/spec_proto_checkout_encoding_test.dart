// Checkout settings asserted independently of the implementation's tables.
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:test/test.dart';
import '_spec_proto_support.dart';

void main() {
  test(
    'every diagnostic format and ASCII alias is accepted',
    () async {
      for (final (name, expected) in [
        (null, pb.TypeCheckFormat.TYPE_CHECK_FORMAT_UNSPECIFIED),
        ('FuLl', pb.TypeCheckFormat.TYPE_CHECK_FORMAT_FULL),
        ('CoNcIsE', pb.TypeCheckFormat.TYPE_CHECK_FORMAT_CONCISE),
        ('AZURE', pb.TypeCheckFormat.TYPE_CHECK_FORMAT_AZURE),
        ('JSON', pb.TypeCheckFormat.TYPE_CHECK_FORMAT_JSON),
        ('JSONLINES', pb.TypeCheckFormat.TYPE_CHECK_FORMAT_JSON_LINES),
        ('JSON-LINES', pb.TypeCheckFormat.TYPE_CHECK_FORMAT_JSON_LINES),
        ('RDJSON', pb.TypeCheckFormat.TYPE_CHECK_FORMAT_RDJSON),
        ('PYLINT', pb.TypeCheckFormat.TYPE_CHECK_FORMAT_PYLINT),
        ('GITLAB', pb.TypeCheckFormat.TYPE_CHECK_FORMAT_GITLAB),
        ('GITHUB', pb.TypeCheckFormat.TYPE_CHECK_FORMAT_GITHUB),
      ]) {
        final (_, channel) = await protoConfiguredSession(
          [],
          config: SessionConfig(typeCheckFormat: name),
        );
        final sent = channel.requests.singleOrNull?.configure;
        expect(sent?.typeCheckFormat, expected, reason: '$name');
        expect(sent?.hasTypeCheckFormat(), name != null);
      }
    },
  );

  test(
    'fractional milliseconds truncate '
    'with minimum and saturation',
    () async {
      for (final (duration, expected) in [
        (Duration.zero, 0),
        (const Duration(microseconds: 1), 1),
        (const Duration(microseconds: 1999), 1),
        (const Duration(microseconds: 2999), 2),
        (const Duration(microseconds: 4294967295999), 4294967295),
        (const Duration(days: 60), 4294967295),
      ]) {
        final (_, channel) = await protoConfiguredSession(
          [],
          config: SessionConfig(printFlushInterval: duration),
        );
        expect(
          channel.requests.singleOrNull?.configure.printFlushIntervalMs,
          expected,
        );
      }
    },
  );

  test('numeric uncapped spelling sends all 64 bits', () async {
    final (_, channel) = await protoConfiguredSession(
      [],
      config: const SessionConfig(
        osPolicy: OsPolicy(
          sleepSystemMax: Duration(microseconds: 9007199254740991),
        ),
      ),
    );
    final sleep =
        channel.requests.singleOrNull?.configure.osPolicy.sleep.system;
    expect(sleep?.maxMicros.toStringUnsigned(), '18446744073709551615');
    expect(sleep?.writeToBuffer(), [
      8,
      255,
      255,
      255,
      255,
      255,
      255,
      255,
      255,
      255,
      1,
    ]);
  });

  test(
    'fixed instant retains the supplied microseconds',
    () async {
      final instant = DateTime.utc(2020, 7, 2, 3, 4, 5, 678, 901);
      final (_, channel) = await protoConfiguredSession(
        [],
        config: SessionConfig(
          osPolicy: OsPolicy(fixedDatetime: instant),
        ),
      );
      final policy = channel.requests.singleOrNull?.configure.osPolicy;
      expect(policy?.fixed.unixSeconds.toString(), '1593659045');
      expect(policy?.fixed.microsecond, 678901);
      expect(policy?.timezone.hasUtc(), isTrue);
    },
  );
}

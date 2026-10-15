// The internal members of classes that the cutover makes public (pass-3 G2):
// each is library-private, reached only through an extension in its own
// library that the public `show` lists leave out. Each test calls the member
// through its extension by name, so it fails to compile if the extension is
// renamed or the member is public again. Pure Dart: vm, dart2js and dart2wasm.
import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/resource_limits.dart';
import 'package:test/test.dart';

void main() {
  group('ResourceLimitsInternal', () {
    test('validate refuses a negative limit with upstream text', () {
      expect(
        () => ResourceLimitsInternal(
          const ResourceLimits(maxMemory: -1),
        ).validate(),
        throwsA(
          isA<ArgumentError>().having((e) => e.name, 'name', 'maxMemory'),
        ),
      );
      ResourceLimitsInternal(const ResourceLimits(maxMemory: 1)).validate();
    });

    test('toProto writes the set limits and the two defaults', () {
      final wire = ResourceLimitsInternal(
        const ResourceLimits(
          maxMemory: 7,
          maxFeedDuration: Duration(seconds: 2),
        ),
      ).toProto();
      expect(wire.maxMemoryBytes.toInt(), 7);
      expect(wire.maxFeedDurationMicros.toInt(), 2000000);
      expect(wire.maxRecursionDepth.toInt(), defaultMaxRecursionDepth);
      expect(wire.maxSuspensions.toInt(), defaultMaxSuspensions);
      expect(wire.hasGcInterval(), isFalse);
    });
  });

  group('MontyCrashedErrorInternal', () {
    test('context is what the parent was doing, null by default', () {
      final crash = crashedError(CrashCause.vanished, context: sendingRequest);
      expect(MontyCrashedErrorInternal(crash).context, sendingRequest);
      expect(
        MontyCrashedErrorInternal(crashedError(CrashCause.vanished)).context,
        isNull,
      );
      expect(
        MontyCrashedErrorInternal(inContext(crash, abortingFeed)).context,
        abortingFeed,
      );
    });
  });
}

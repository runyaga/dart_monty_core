// Backend absence uses Dart's unsupported-feature category on every compiler.
import 'package:dart_monty_core/src/worker/channel_factory_stub.dart' as stub;
import 'package:test/test.dart';

void main() {
  test('absent backend is UnsupportedError', () {
    for (final location in <String?>[null, '/custom/worker']) {
      expect(
        () => stub.openChannel(workerLocation: location),
        throwsA(isA<UnsupportedError>()),
      );
    }
  });
}

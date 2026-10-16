@TestOn('browser')
library;

import 'package:dart_monty_core/src/mount/native_mount_service.dart';
import 'package:test/test.dart';

void main() {
  test('host-directory mounts are refused in browsers', () {
    expect(
      () => NativeMountRoot(hostPath: '/host', virtualPath: '/m'),
      throwsA(
        isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          'MountDir needs a host directory; the browser has none',
        ),
      ),
    );
  });
}

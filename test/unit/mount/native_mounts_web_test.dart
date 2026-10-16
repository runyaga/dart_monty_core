// Runs on the VM as well as in Chrome: the browser stub has no JS interop,
// so the VM measures its coverage directly.

import 'package:dart_monty_core/src/mount/native_mounts_web.dart';
import 'package:test/test.dart';

void main() {
  final refusal = throwsA(
    isA<UnsupportedError>().having(
      (error) => error.message,
      'message',
      'MountDir needs a host directory; the browser has none',
    ),
  );

  test('host-directory mounts are refused before validating inputs', () {
    expect(
      () => NativeMountRoot(hostPath: '/host', virtualPath: '/m'),
      refusal,
    );
    expect(
      () => NativeMountRoot(
        hostPath: '',
        virtualPath: 'relative',
        mode: 'invalid',
        writeBytesLimit: -1,
        memoryUsageLimit: -1,
      ),
      refusal,
    );
  });
  test('native lookup route is unavailable in browsers', () {
    expect(() => nativeMountLookupRoute, refusal);
  });
  test('root path getters and close refuse host access', () {
    const root = NativeMountRoot.unsupported();
    expect(() => root.hostPath, refusal);
    expect(() => root.virtualPath, refusal);
    expect(root.close, refusal);
  });
  test('table construction refuses even an empty root list', () {
    expect(() => NativeMountTable([]), refusal);
    expect(
      () => NativeMountTable([const NativeMountRoot.unsupported()]),
      refusal,
    );
  });
  test('table calls and close refuse host access', () {
    const table = NativeMountTable.unsupported();
    expect(() => table.call([]), refusal);
    expect(() => table.call([255]), refusal);
    expect(table.close, refusal);
  });
}

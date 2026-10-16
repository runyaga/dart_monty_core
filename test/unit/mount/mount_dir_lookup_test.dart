@TestOn('vm')
@Tags(['vm-only'])
library;

import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/mount/native_mount_lookup.dart';
import 'package:test/test.dart';

void main() {
  late Directory empty;
  setUp(() {
    empty = Directory.systemTemp.createTempSync('mount-lookup-');
    nativeMountLookup.overridePackageDirectory = null;
  });
  tearDown(() {
    nativeMountLookup.overridePackageDirectory = null;
    empty.deleteSync();
  });
  test('D-098 no library refuses with build_worker opt-in', () {
    // Warm the cache first: the override must invalidate a successful lookup.
    MountDir(hostPath: empty.path, virtualPath: '/d').close();
    nativeMountLookup.overridePackageDirectory = empty.uri;
    expect(
      () => MountDir(hostPath: empty.path, virtualPath: '/d'),
      throwsA(
        isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          contains('build_worker: true'),
        ),
      ),
    );
  });
  test('D-098 package library discovery recovers after override reset', () {
    nativeMountLookup.overridePackageDirectory = empty.uri;
    expect(
      () => MountDir(hostPath: empty.path, virtualPath: '/d'),
      throwsUnsupportedError,
    );
    nativeMountLookup.overridePackageDirectory = null;
    final mount = MountDir(hostPath: empty.path, virtualPath: '/d');
    addTearDown(mount.close);
    expect(mount.hostPath, empty.resolveSymbolicLinksSync());
    expect(nativeMountLookup.bindings.route, 'package');
  });
}

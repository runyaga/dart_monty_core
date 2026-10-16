@Tags(['vm-only'])
@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:dart_monty_core/src/mount/native_mount_bindings.dart';
import 'package:dart_monty_core/src/mount/native_mounts.dart';
import 'package:dart_monty_core/src/worker/worker_locator.dart';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

void main() {
  final libraryName = switch (Platform.operatingSystem) {
    'windows' => 'dart_monty_worker.dll',
    'macos' => 'libdart_monty_worker.dylib',
    _ => 'libdart_monty_worker.so',
  };
  final workerUri = Uri.parse(
    'package:dart_monty_core/${workerPackagePath(Abi.current())}',
  );
  final worker =
      Isolate.resolvePackageUriSync(workerUri) ??
      (throw StateError('test requires package resolution'));
  final library = DynamicLibrary.open(worker.resolve(libraryName).toFilePath());
  final bindings = NativeMountBindings.load();
  final unavailable = throwsA(
    isA<UnsupportedError>().having(
      (error) => error.message,
      'actionable installation guidance',
      'MountDir needs the native mount service. Set hooks: user_defines: '
          'dart_monty_core: build_worker: true in the root pubspec, '
          'or run tool/build_worker.sh for this package checkout.',
    ),
  );

  test('asset discovery wins without resolving a package library', () {
    final resolved = NativeMountBindings.resolve(
      asset: () => bindings,
      resolvePackage: (_) => throw StateError('must not resolve package'),
      openLibrary: (_) => throw StateError('must not open package library'),
    );
    expect(resolved, same(bindings));
  });

  test('absent asset loads the sibling library and resolves every symbol', () {
    final resolved = NativeMountBindings.resolve(
      asset: _missingAsset,
      resolvePackage: (uri) {
        expect(uri, workerUri);

        return worker;
      },
      openLibrary: (path) {
        expect(path, worker.resolve(libraryName).toFilePath());

        return library;
      },
    );
    expect(resolved.route, 'package');
    final dir = Directory.systemTemp.createTempSync('mount-resolve-');
    addTearDown(dir.deleteSync);
    final root = NativeMounts(resolved).openRoot(
      hostPath: dir.path,
      virtualPath: '/resolved',
    );
    addTearDown(root.close);
    expect(root.virtualPath, '/resolved');
    expect(root.hostPath, dir.resolveSymbolicLinksSync());
  });

  test('unresolved package refuses with installation guidance', () {
    expect(
      () => NativeMountBindings.resolve(
        asset: _missingAsset,
        resolvePackage: (_) => null,
        openLibrary: (_) => throw StateError('must not open a library'),
      ),
      unavailable,
    );
  });

  test('AOT package resolver refusal preserves installation guidance', () {
    expect(
      () => NativeMountBindings.resolve(
        asset: _missingAsset,
        resolvePackage: (_) => throw UnsupportedError('no package URIs in AOT'),
        openLibrary: (_) => throw StateError('must not open a library'),
      ),
      unavailable,
    );
  });

  test('missing package library refuses with installation guidance', () {
    final dir = Directory.systemTemp.createTempSync('mount-missing-');
    addTearDown(dir.deleteSync);
    expect(
      () => NativeMountBindings.resolve(
        asset: _missingAsset,
        resolvePackage: (_) => dir.uri.resolve('worker'),
        openLibrary: DynamicLibrary.open,
      ),
      unavailable,
    );
  });

  test('library missing mount symbols refuses with installation guidance', () {
    expect(
      () => NativeMountBindings.resolve(
        asset: _missingAsset,
        resolvePackage: (_) => worker,
        openLibrary: (_) =>
            DynamicLibrary.open(switch (Platform.operatingSystem) {
              'windows' => 'kernel32.dll',
              'macos' => '/usr/lib/libSystem.B.dylib',
              _ => 'libc.so.6',
            }),
      ),
      unavailable,
    );
  });

  test('unexpected loader errors are not disguised as missing assets', () {
    final failure = StateError('asset loader failed');
    expect(
      () => NativeMountBindings.resolve(
        asset: () => throw failure,
        resolvePackage: (_) => throw StateError('must not resolve package'),
        openLibrary: (_) => throw StateError('must not open library'),
      ),
      throwsA(same(failure)),
    );
  });

  for (final failure in ['native error', 'invalid UTF-8', 'unhandled']) {
    test('root acquisition releases its native handle after $failure', () {
      final dir = Directory.systemTemp.createTempSync('mount-cleanup-');
      addTearDown(dir.deleteSync);
      int? acquired;
      final callback =
          NativeCallable<
            Int64 Function(Int64, Pointer<Pointer<Uint8>>, Pointer<UintPtr>)
          >.isolateLocal((
            int id,
            Pointer<Pointer<Uint8>> out,
            Pointer<UintPtr> size,
          ) {
            acquired = id;
            if (failure == 'native error') {
              return bindings.rootInfo(-1, out, size);
            }
            if (failure == 'unhandled') return 0;
            final status = bindings.rootInfo(id, out, size);
            out.value.value = 255; // Invalid UTF-8 in the returned host path.

            return status;
          }, exceptionalReturn: -1);
      addTearDown(callback.close);
      final service = NativeMounts(
        NativeMountBindings.fromPointers('fixture', (
          open: library.lookup('dmfs_open'),
          rootInfo: callback.nativeFunction,
          close: library.lookup('dmfs_close'),
          finalize: library.lookup('dmfs_finalize'),
          beginFeed: library.lookup('dmfs_begin_feed'),
          call: library.lookup('dmfs_call'),
          endFeed: library.lookup('dmfs_end_feed'),
          free: library.lookup('dmfs_free'),
          lastError: library.lookup('dmfs_last_error'),
        )),
      );
      expect(
        () => service.openRoot(hostPath: dir.path, virtualPath: '/cleanup'),
        failure == 'unhandled' ? throwsStateError : throwsFormatException,
      );
      final id = acquired ?? (throw StateError('root was never acquired'));
      // This interrogates the real native registry: close alone retains its
      // label, whereas release must remove the failed acquisition entirely.
      using((arena) {
        expect(bindings.rootInfo(id, arena(), arena()), -1);
        final message = bindings.lastError().ref;
        expect(
          message.data.cast<Utf8>().toDartString(length: message.length),
          'unknown mount root',
        );
      });
    });
  }
}

NativeMountBindings _missingAsset() => throw ArgumentError('missing asset');

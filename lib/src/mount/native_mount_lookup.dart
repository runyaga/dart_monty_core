/// Cached library discovery, with an internal test-only location override.
library;

import 'dart:ffi';
import 'dart:isolate';

import 'package:dart_monty_core/src/mount/native_mount_bindings.dart';
import 'package:meta/meta.dart';

/// The creating isolate's shared lookup.
final nativeMountLookup = NativeMountLookup();

/// Resolves the asset first, then the library beside the package worker.
final class NativeMountLookup {
  NativeMountBindings? _bindings;
  Uri? _packageDirectory;

  /// Resolved symbols, cached after a successful lookup.
  NativeMountBindings get bindings => _bindings ??= _packageDirectory == null
      ? NativeMountBindings.load()
      : NativeMountBindings.resolve(
          asset: _noAsset,
          resolvePackage: _resolvePackage,
          openLibrary: DynamicLibrary.open,
        );

  /// Simulates an unbundled consumer and overrides the package directory,
  /// invalidating previous lookup results. Null restores normal discovery.
  /// Suppress asset lookup too: a previously opened dylib can expose its
  /// symbols to the process-wide fallback used by Native.addressOf.
  @visibleForTesting
  void overridePackageDirectory(Uri? directory) {
    _packageDirectory = directory;
    _bindings = null;
  }

  NativeMountBindings _noAsset() => throw ArgumentError('no test code asset');

  Uri? _resolvePackage(Uri uri) =>
      _packageDirectory?.resolve('dart_monty_worker') ??
      Isolate.resolvePackageUriSync(uri);
}

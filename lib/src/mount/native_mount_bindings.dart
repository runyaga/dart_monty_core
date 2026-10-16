/// Native symbols are resolved once, from the hook asset or package library.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:dart_monty_core/src/worker/worker_locator.dart';

const _asset = 'package:dart_monty_core/src/worker/self_relaunch.dart';

@Native<
  Int64 Function(
    Pointer<MountString>,
    Pointer<MountString>,
    Pointer<MountString>,
    Int64,
    Uint64,
  )
>(symbol: 'dmfs_open', assetId: _asset)
external int _open(
  Pointer<MountString> virtualPath,
  Pointer<MountString> host,
  Pointer<MountString> mode,
  int writes,
  int memory,
);

@Native<Int64 Function(Int64, Pointer<Pointer<Uint8>>, Pointer<UintPtr>)>(
  symbol: 'dmfs_root_info',
  assetId: _asset,
)
external int _rootInfo(
  int id,
  Pointer<Pointer<Uint8>> output,
  Pointer<UintPtr> length,
);

@Native<Void Function(Int64)>(symbol: 'dmfs_close', assetId: _asset)
external void _close(int id);

@Native<Void Function(Pointer<Void>)>(symbol: 'dmfs_finalize', assetId: _asset)
external void _finalize(Pointer<Void> token);

@Native<Int64 Function(Pointer<Int64>, UintPtr)>(
  symbol: 'dmfs_begin_feed',
  assetId: _asset,
)
external int _beginFeed(Pointer<Int64> ids, int count);

@Native<
  Int64 Function(
    Int64,
    Pointer<Uint8>,
    UintPtr,
    Pointer<Pointer<Uint8>>,
    Pointer<UintPtr>,
  )
>(symbol: 'dmfs_call', assetId: _asset)
external int _call(
  int id,
  Pointer<Uint8> bytes,
  int size,
  Pointer<Pointer<Uint8>> output,
  Pointer<UintPtr> length,
);

@Native<Void Function(Int64)>(symbol: 'dmfs_end_feed', assetId: _asset)
external void _endFeed(int id);

@Native<Void Function(Pointer<Uint8>, UintPtr)>(
  symbol: 'dmfs_free',
  assetId: _asset,
)
external void _free(Pointer<Uint8> bytes, int length);

@Native<Pointer<MountString> Function()>(
  symbol: 'dmfs_last_error',
  assetId: _asset,
)
external Pointer<MountString> _lastError();

/// Cached native mount symbols, shared by the root and per-feed services.
final class NativeMountBindings {
  /// Converts a resolved symbol table to Dart calls without changing ownership.
  NativeMountBindings.fromPointers(this.route, MountPointers pointers)
    : open = pointers.open.asFunction(),
      rootInfo = pointers.rootInfo.asFunction(),
      close = pointers.close.asFunction(),
      finalizer = NativeFinalizer(pointers.finalize),
      release = pointers.finalize.asFunction(),
      beginFeed = pointers.beginFeed.asFunction(),
      call = pointers.call.asFunction(),
      endFeed = pointers.endFeed.asFunction(),
      free = pointers.free.asFunction(),
      lastError = pointers.lastError.asFunction();

  /// Asset first; when absent, try beside the package's worker executable.
  factory NativeMountBindings.load() => NativeMountBindings.resolve(
    asset: _assetBindings,
    resolvePackage: Isolate.resolvePackageUriSync,
    openLibrary: DynamicLibrary.open,
  );

  /// Resolves symbols using explicit loaders, also used by packaging tests.
  factory NativeMountBindings.resolve({
    required NativeMountBindings Function() asset,
    required Uri? Function(Uri) resolvePackage,
    required DynamicLibrary Function(String) openLibrary,
  }) {
    try {
      return asset();
      // An unresolved native asset throws ArgumentError, as self-relaunch does.
      // ignore: avoid_catching_errors
    } on ArgumentError {
      return _packageBindings(resolvePackage, openLibrary);
    }
  }

  /// Lookup route used, for the independent JIT and AOT smoke checks.
  final String route;

  /// dmfs_open ABI binding.
  final int Function(
    Pointer<MountString>,
    Pointer<MountString>,
    Pointer<MountString>,
    int,
    int,
  )
  open;

  /// dmfs_root_info ABI binding.
  final int Function(int, Pointer<Pointer<Uint8>>, Pointer<UintPtr>) rootInfo;

  /// dmfs_close ABI binding.
  final void Function(int) close;

  /// dmfs_finalize ABI binding.
  final NativeFinalizer finalizer;

  /// Releases a root when construction failed before attaching the finalizer.
  final void Function(Pointer<Void>) release;

  /// dmfs_begin_feed ABI binding.
  final int Function(Pointer<Int64>, int) beginFeed;

  /// dmfs_call ABI binding.
  final int Function(
    int,
    Pointer<Uint8>,
    int,
    Pointer<Pointer<Uint8>>,
    Pointer<UintPtr>,
  )
  call;

  /// dmfs_end_feed ABI binding.
  final void Function(int) endFeed;

  /// dmfs_free ABI binding.
  final void Function(Pointer<Uint8>, int) free;

  /// dmfs_last_error ABI binding.
  final Pointer<MountString> Function() lastError;
}

/// Borrowed UTF-8 string view used by the native ABI, with no NUL sentinel.
final class MountString extends Struct {
  /// First byte; borrowed for the duration of a call.
  external Pointer<Uint8> data;

  /// Number of bytes (not Unicode characters).
  @UintPtr()
  external int length;
}

NativeMountBindings _assetBindings() => NativeMountBindings.fromPointers(
  'asset',
  (
    open: Native.addressOf<NativeFunction<_Open>>(_open),
    rootInfo: Native.addressOf<NativeFunction<_RootInfo>>(_rootInfo),
    close: Native.addressOf<NativeFunction<_Close>>(_close),
    finalize: Native.addressOf<NativeFunction<_Finalize>>(_finalize),
    beginFeed: Native.addressOf<NativeFunction<_BeginFeed>>(_beginFeed),
    call: Native.addressOf<NativeFunction<_Call>>(_call),
    endFeed: Native.addressOf<NativeFunction<_Close>>(_endFeed),
    free: Native.addressOf<NativeFunction<_Free>>(_free),
    lastError: Native.addressOf<NativeFunction<_LastError>>(_lastError),
  ),
);

NativeMountBindings _packageBindings(
  Uri? Function(Uri) resolvePackage,
  DynamicLibrary Function(String) openLibrary,
) {
  try {
    final worker = resolvePackage(
      Uri.parse('package:dart_monty_core/${workerPackagePath(Abi.current())}'),
    );
    if (worker != null) {
      final name = switch (Platform.operatingSystem) {
        'windows' => 'dart_monty_worker.dll',
        'macos' => 'libdart_monty_worker.dylib',
        _ => 'libdart_monty_worker.so',
      };
      final library = openLibrary(worker.resolve(name).toFilePath());

      return NativeMountBindings.fromPointers('package', (
        open: library.lookup('dmfs_open'),
        rootInfo: library.lookup('dmfs_root_info'),
        close: library.lookup('dmfs_close'),
        finalize: library.lookup('dmfs_finalize'),
        beginFeed: library.lookup('dmfs_begin_feed'),
        call: library.lookup('dmfs_call'),
        endFeed: library.lookup('dmfs_end_feed'),
        free: library.lookup('dmfs_free'),
        lastError: library.lookup('dmfs_last_error'),
      ));
    }
    // DynamicLibrary.open/lookup use ArgumentError for absent libraries/symbols.
    // ignore: avoid_catching_errors
  } on ArgumentError {
    // Fall through to the actionable refusal below.
    // ignore: avoid_catching_errors
  } on UnsupportedError {
    // Package URIs need not resolve in an AOT runtime.
  }

  throw UnsupportedError(
    'MountDir needs the native mount service. Set hooks: user_defines: '
    'dart_monty_core: build_worker: true in the root pubspec, '
    'or run tool/build_worker.sh for this package checkout.',
  );
}

/// Resolved ABI addresses; keeping their native types checks every conversion.
typedef MountPointers = ({
  Pointer<NativeFunction<_Open>> open,
  Pointer<NativeFunction<_RootInfo>> rootInfo,
  Pointer<NativeFunction<_Close>> close,
  Pointer<NativeFunction<_Finalize>> finalize,
  Pointer<NativeFunction<_BeginFeed>> beginFeed,
  Pointer<NativeFunction<_Call>> call,
  Pointer<NativeFunction<_Close>> endFeed,
  Pointer<NativeFunction<_Free>> free,
  Pointer<NativeFunction<_LastError>> lastError,
});

typedef _Open =
    Int64 Function(
      Pointer<MountString>,
      Pointer<MountString>,
      Pointer<MountString>,
      Int64,
      Uint64,
    );
typedef _RootInfo =
    Int64 Function(Int64, Pointer<Pointer<Uint8>>, Pointer<UintPtr>);
typedef _Close = Void Function(Int64);
typedef _Finalize = Void Function(Pointer<Void>);
typedef _BeginFeed = Int64 Function(Pointer<Int64>, UintPtr);
typedef _Call =
    Int64 Function(
      Int64,
      Pointer<Uint8>,
      UintPtr,
      Pointer<Pointer<Uint8>>,
      Pointer<UintPtr>,
    );
typedef _Free = Void Function(Pointer<Uint8>, UintPtr);
typedef _LastError = Pointer<MountString> Function();

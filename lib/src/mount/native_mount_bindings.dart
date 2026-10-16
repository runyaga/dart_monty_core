/// Native symbols are resolved once, from the hook asset or package library.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:dart_monty_core/src/worker/worker_locator.dart';

/// Borrowed UTF-8 string view used by the native ABI, with no NUL sentinel.
final class MountString extends Struct {
  /// First byte; borrowed for the duration of a call.
  external Pointer<Uint8> data;

  /// Number of bytes (not Unicode characters).
  @UintPtr()
  external int length;
}

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

/// Cached bindings; @Native declarations are used only to obtain addresses.
final class MountBindings {
  MountBindings._(
    this.route,
    Pointer<
      NativeFunction<
        Int64 Function(
          Pointer<MountString>,
          Pointer<MountString>,
          Pointer<MountString>,
          Int64,
          Uint64,
        )
      >
    >
    openPointer,
    Pointer<
      NativeFunction<
        Int64 Function(Int64, Pointer<Pointer<Uint8>>, Pointer<UintPtr>)
      >
    >
    rootInfoPointer,
    Pointer<NativeFunction<Void Function(Int64)>> closePointer,
    Pointer<NativeFunction<Void Function(Pointer<Void>)>> finalizePointer,
    Pointer<NativeFunction<Int64 Function(Pointer<Int64>, UintPtr)>>
    beginFeedPointer,
    Pointer<
      NativeFunction<
        Int64 Function(
          Int64,
          Pointer<Uint8>,
          UintPtr,
          Pointer<Pointer<Uint8>>,
          Pointer<UintPtr>,
        )
      >
    >
    callPointer,
    Pointer<NativeFunction<Void Function(Int64)>> endFeedPointer,
    Pointer<NativeFunction<Void Function(Pointer<Uint8>, UintPtr)>> freePointer,
    Pointer<NativeFunction<Pointer<MountString> Function()>> lastErrorPointer,
  ) : open = openPointer
          .asFunction<
            int Function(
              Pointer<MountString>,
              Pointer<MountString>,
              Pointer<MountString>,
              int,
              int,
            )
          >(),
      rootInfo = rootInfoPointer
          .asFunction<
            int Function(int, Pointer<Pointer<Uint8>>, Pointer<UintPtr>)
          >(),
      close = closePointer.asFunction<void Function(int)>(),
      finalizer = NativeFinalizer(finalizePointer),
      release = finalizePointer.asFunction<void Function(Pointer<Void>)>(),
      beginFeed = beginFeedPointer
          .asFunction<int Function(Pointer<Int64>, int)>(),
      call = callPointer
          .asFunction<
            int Function(
              int,
              Pointer<Uint8>,
              int,
              Pointer<Pointer<Uint8>>,
              Pointer<UintPtr>,
            )
          >(),
      endFeed = endFeedPointer.asFunction<void Function(int)>(),
      free = freePointer.asFunction<void Function(Pointer<Uint8>, int)>(),
      lastError = lastErrorPointer
          .asFunction<Pointer<MountString> Function()>();

  /// Asset first; when absent, try beside the package's worker executable.
  factory MountBindings.load() {
    try {
      return MountBindings._(
        'asset',
        Native.addressOf<
          NativeFunction<
            Int64 Function(
              Pointer<MountString>,
              Pointer<MountString>,
              Pointer<MountString>,
              Int64,
              Uint64,
            )
          >
        >(_open),
        Native.addressOf<
          NativeFunction<
            Int64 Function(Int64, Pointer<Pointer<Uint8>>, Pointer<UintPtr>)
          >
        >(_rootInfo),
        Native.addressOf<NativeFunction<Void Function(Int64)>>(_close),
        Native.addressOf<NativeFunction<Void Function(Pointer<Void>)>>(
          _finalize,
        ),
        Native.addressOf<
          NativeFunction<Int64 Function(Pointer<Int64>, UintPtr)>
        >(_beginFeed),
        Native.addressOf<
          NativeFunction<
            Int64 Function(
              Int64,
              Pointer<Uint8>,
              UintPtr,
              Pointer<Pointer<Uint8>>,
              Pointer<UintPtr>,
            )
          >
        >(_call),
        Native.addressOf<NativeFunction<Void Function(Int64)>>(_endFeed),
        Native.addressOf<
          NativeFunction<Void Function(Pointer<Uint8>, UintPtr)>
        >(_free),
        Native.addressOf<NativeFunction<Pointer<MountString> Function()>>(
          _lastError,
        ),
      );
      // An unresolved native asset throws ArgumentError, as self-relaunch does.
      // ignore: avoid_catching_errors
    } on ArgumentError {
      return MountBindings._packageLibrary();
    }
  }

  factory MountBindings._packageLibrary() {
    try {
      final worker = Isolate.resolvePackageUriSync(
        Uri.parse(
          'package:dart_monty_core/${workerPackagePath(Abi.current())}',
        ),
      );
      if (worker != null) {
        final name = Platform.isWindows
            ? 'dart_monty_worker.dll'
            : Platform.isMacOS
            ? 'libdart_monty_worker.dylib'
            : 'libdart_monty_worker.so';
        final library = DynamicLibrary.open(worker.resolve(name).toFilePath());
        return MountBindings._(
          'package',
          library.lookup<
            NativeFunction<
              Int64 Function(
                Pointer<MountString>,
                Pointer<MountString>,
                Pointer<MountString>,
                Int64,
                Uint64,
              )
            >
          >('dmfs_open'),
          library.lookup<
            NativeFunction<
              Int64 Function(Int64, Pointer<Pointer<Uint8>>, Pointer<UintPtr>)
            >
          >('dmfs_root_info'),
          library.lookup<NativeFunction<Void Function(Int64)>>('dmfs_close'),
          library.lookup<NativeFunction<Void Function(Pointer<Void>)>>(
            'dmfs_finalize',
          ),
          library
              .lookup<NativeFunction<Int64 Function(Pointer<Int64>, UintPtr)>>(
                'dmfs_begin_feed',
              ),
          library.lookup<
            NativeFunction<
              Int64 Function(
                Int64,
                Pointer<Uint8>,
                UintPtr,
                Pointer<Pointer<Uint8>>,
                Pointer<UintPtr>,
              )
            >
          >('dmfs_call'),
          library.lookup<NativeFunction<Void Function(Int64)>>('dmfs_end_feed'),
          library
              .lookup<NativeFunction<Void Function(Pointer<Uint8>, UintPtr)>>(
                'dmfs_free',
              ),
          library.lookup<NativeFunction<Pointer<MountString> Function()>>(
            'dmfs_last_error',
          ),
        );
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

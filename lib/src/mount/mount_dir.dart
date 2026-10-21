/// A host directory capability served by upstream monty-fs.
library;

import 'package:dart_monty_core/src/mount/native_mount_service.dart';

/// Maps an opened host directory into Python's virtual filesystem.
///
/// The native finalizer releases an abandoned root. The capability belongs to
/// its creating isolate and must be used there.
final class MountDir {
  /// Opens a host directory capability at a normalized virtual path.
  ///
  /// Overlay writes disappear when their feed ends. Read-only writes raise
  /// `PermissionError` with errno 30. Read-write writes persist on the host.
  /// [writeBytesLimit] and [memoryUsageLimit] bound each feed.
  /// The service is the `build_worker: true` hook asset or the library beside
  /// the package worker in `lib/src/bin/<os>-<arch>/`. The constructor throws
  /// [UnsupportedError] on the web or without that service, [ArgumentError]
  /// for an invalid path or mode, and [RangeError] for a negative limit.
  MountDir({
    required String hostPath,
    required String virtualPath,
    this.mode = 'overlay',
    this.writeBytesLimit,
    this.memoryUsageLimit = 100000000,
  }) : _root = (() {
         final root = NativeMountRoot(
           hostPath: hostPath,
           virtualPath: virtualPath,
           mode: mode,
           writeBytesLimit: writeBytesLimit,
           memoryUsageLimit: memoryUsageLimit,
         );
         // A generative constructor must initialise these final fields here.
         // Rebind only its local path parameters to the single opened root's
         // canonical paths; neither a second open nor a redirect is needed.
         hostPath = root.hostPath;
         virtualPath = root.virtualPath;

         return root;
       })(),
       hostPath = hostPath,
       virtualPath = virtualPath;

  /// Canonical path of the opened directory, retained after close.
  final String hostPath;

  /// Normalised absolute virtual path, retained after close.
  final String virtualPath;

  /// The selected access mode.
  final String mode;

  /// Maximum cumulative bytes written per feed, or null for no limit.
  /// Exceeding it raises `OSError`.
  final int? writeBytesLimit;

  /// Mount memory budget for overlay data and transient directory listings.
  ///
  /// The default is 100000000 bytes.
  /// Exceeding it raises `MemoryError`.
  final int memoryUsageLimit;

  final NativeMountRoot _root;

  /// Prevents new feeds from using the capability and safely repeats.
  ///
  /// Feeds already running retain their opened root.
  void close() => _root.close();

  @override
  String toString() =>
      "MountDir(host_path='$hostPath', "
      "virtual_path='$virtualPath', mode='$mode')";
}

/// Creates a feed's private table from the mounts' opened capabilities.
/// No table means no path validation or routing before the OS handler.
NativeMountTable? beginMountFeed(List<MountDir>? mounts) =>
    mounts == null || mounts.isEmpty
    ? null
    : NativeMountTable([for (final mount in mounts) mount._root]);

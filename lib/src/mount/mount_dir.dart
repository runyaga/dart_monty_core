/// A host directory capability served by upstream monty-fs.
library;

import 'package:dart_monty_core/src/mount/native_mount_service.dart';

/// Maps an opened host directory into Python's virtual filesystem.
///
/// Overlay writes and budgets belong to each feed. Closing this mount
/// prevents new feeds from using it; feeds already running keep their root.
/// Dropping the mount releases its root through the native finalizer.
/// Construction on the web throws [UnsupportedError].
final class MountDir {
  /// Opens [hostPath] immediately and normalises [virtualPath].
  ///
  /// [mode] is 'overlay', 'read-only', or 'read-write'. [writeBytesLimit]
  /// limits each feed's writes; [memoryUsageLimit] bounds retained overlay
  /// data and transient filesystem results in every mode.
  MountDir({
    required String hostPath,
    required String virtualPath,
    String mode = 'overlay',
    int? writeBytesLimit,
    int memoryUsageLimit = 100000000,
  }) : this._(
         NativeMountRoot(
           hostPath: hostPath,
           virtualPath: virtualPath,
           mode: mode,
           writeBytesLimit: writeBytesLimit,
           memoryUsageLimit: memoryUsageLimit,
         ),
         mode,
         writeBytesLimit,
         memoryUsageLimit,
       );

  MountDir._(
    NativeMountRoot root,
    this.mode,
    this.writeBytesLimit,
    this.memoryUsageLimit,
  ) : _root = root,
      hostPath = root.hostPath,
      virtualPath = root.virtualPath;

  /// Canonical path of the opened directory, retained after close.
  final String hostPath;

  /// Normalised absolute virtual path, retained after close.
  final String virtualPath;

  /// The selected access mode.
  final String mode;

  /// Maximum bytes written per feed, or null for no limit.
  final int? writeBytesLimit;

  /// Mount memory budget in bytes.
  final int memoryUsageLimit;

  final NativeMountRoot _root;

  /// Releases the directory capability. Safe to call repeatedly.
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

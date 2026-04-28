import 'package:dart_monty_core/src/mount/mount_mode.dart';

/// Declarative description of a virtual mount point inside the sandbox.
///
/// A `MountDir` declares which paths Python code can reach through
/// `pathlib.Path`. The mount is enforced by the OS-call handler returned
/// from `memoryMountedOsHandler` (or a future filesystem-backed
/// equivalent) — paths outside any mount fall through to the
/// configured fallthrough handler (or raise `PermissionError`).
///
/// ```dart
/// final handler = memoryMountedOsHandler(
///   mounts: const [
///     MountDir(virtualPath: '/data', mode: MountMode.readOnly),
///     MountDir(virtualPath: '/tmp'),
///   ],
///   vfs: {
///     '/data/config.json': '{"debug": true}',
///   },
/// );
/// ```
class MountDir {
  /// Creates a mount declaration.
  const MountDir({
    required this.virtualPath,
    this.mode = MountMode.readWrite,
    this.writeBytesLimit,
  });

  /// The path prefix Python sees inside the sandbox (e.g. `/data`).
  ///
  /// Must be absolute (start with `/`). Files Python can reach must
  /// resolve under this prefix after normalisation.
  final String virtualPath;

  /// Whether this mount allows writes.
  final MountMode mode;

  /// Optional cap on total bytes written through this mount.
  ///
  /// `null` = unlimited.
  final int? writeBytesLimit;
}

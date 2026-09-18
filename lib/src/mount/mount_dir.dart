import 'package:dart_monty_core/src/mount/mount_mode.dart';
import 'package:dart_monty_core/src/mount/vfs_limits.dart';

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
///   files: [MontyMemoryFile('/data/config.json', '{"debug": true}')],
/// );
/// ```
class MountDir {
  /// Creates a mount declaration.
  const MountDir({
    required this.virtualPath,
    this.mode = MountMode.readWrite,
    this.writeBytesLimit,
    this.memoryUsageLimit = defaultMemoryUsageLimit,
  });

  /// The path prefix Python sees inside the sandbox (e.g. `/data`).
  ///
  /// Must be absolute (start with `/`). Files Python can reach must
  /// resolve under this prefix after normalisation.
  final String virtualPath;

  /// Whether this mount allows writes.
  final MountMode mode;

  /// Cap on **cumulative** bytes written through this mount, or `null` for
  /// unlimited.
  ///
  /// Monotonic: deleting a file does not buy budget back, because the bytes
  /// were still written. Exceeding it raises `OSError` in the sandbox, with
  /// upstream's wording — `disk write limit of <n> exceeded`.
  ///
  /// **This was a PER-WRITE cap before 0.19.** A per-write cap does not bound
  /// anything an attacker cares about: `write_bytes(b'x' * limit)` in a loop
  /// passes every check and exhausts host memory. Upstream's parameter of the
  /// same name has always been cumulative — *"Cap on cumulative bytes written
  /// through the mount within one feed"* (`_monty.pyi:111-113`) — so the old
  /// behaviour was a silent contract mismatch for anyone porting.
  final int? writeBytesLimit;

  /// Cap on bytes **currently retained** under this mount, or `null` for
  /// unlimited. Defaults to [defaultMemoryUsageLimit] (100 MB), as upstream
  /// does.
  ///
  /// Unlike [writeBytesLimit] this one is given back when files are deleted —
  /// it bounds how large the live tree may get, not how much has flowed
  /// through. Exceeding it raises `MemoryError`, again with upstream's
  /// wording: `mount memory usage limit of <n> exceeded`.
  ///
  /// Only nodes the **sandbox** created are charged, at [entryMemoryUsage]
  /// each plus their content. Content seeded through `files:` is not charged —
  /// see `VfsAccountant` for why.
  final int? memoryUsageLimit;
}

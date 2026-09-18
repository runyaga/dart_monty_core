import 'package:dart_monty_core/src/mount/mount_dir.dart';
import 'package:dart_monty_core/src/mount/vfs_limits.dart';
import 'package:dart_monty_core/src/platform/os_call_exception.dart';

/// Per-mount byte accounting for a mounted virtual filesystem.
///
/// Two limits, because they bound different things and upstream keeps them
/// separate (`_monty.pyi:111-118`):
///
/// - [MountDir.writeBytesLimit] bounds **cumulative bytes written** through the
///   mount. Monotonic: deleting a file does not buy back budget, because the
///   bytes were still written. Raises `OSError`.
/// - [MountDir.memoryUsageLimit] bounds **currently retained bytes**. Deleting
///   gives the budget back. Raises `MemoryError`.
///
/// A loop of `write_bytes` is caught by the first; a large live tree by the
/// second. Neither subsumes the other.
///
/// ## What "retained" deliberately does NOT include
///
/// Only nodes the **sandbox** created are charged. Content a consumer seeded
/// via `files:` is memory they already allocated and handed us, and charging it
/// would make a large legitimate seed indistinguishable from sandbox growth —
/// the budget exists to bound what untrusted code can make us retain.
///
/// A host-reaching file's content is likewise never charged: the host owns
/// those bytes, we retain none of them. It also must not be *measured*, since
/// asking such a file for its size invokes a host callback — accounting must
/// not have side effects.
///
/// ## Scope is the handler, not a feed
///
/// Upstream scopes its write limit to "one feed". We have no feed boundary to
/// hang state on, so both limits are scoped to the handler instance, which for
/// a one-shot `run()` is the same thing and for a long-lived REPL is stricter.
/// Stated here rather than implied, because it is the one place these diverge.
final class VfsAccountant {
  /// Cumulative bytes written per mount, keyed by the mount's virtual path.
  final Map<String, int> _written = {};

  /// Currently retained bytes per mount, keyed by the mount's virtual path.
  final Map<String, int> _retained = {};

  /// What we charged for each node, keyed by absolute virtual path.
  ///
  /// We remember what we stored rather than asking the tree, so accounting
  /// never touches a node's content and therefore never fires a callback.
  final Map<String, int> _charge = {};

  /// Cumulative bytes written through [mount] so far. Test/diagnostic.
  int writtenFor(MountDir mount) => _written[mount.virtualPath] ?? 0;

  /// Bytes currently retained under [mount]. Test/diagnostic.
  int retainedFor(MountDir mount) => _retained[mount.virtualPath] ?? 0;

  /// Charges a write at [path], throwing if either limit is exceeded. Nothing
  /// is recorded when it throws, so the caller may mutate the tree afterwards.
  ///
  /// The two counts differ, and an append is why: appending 10 bytes to a 1 MB
  /// file *writes* 10 but *retains* 1 MB + 10. Charging `wrote` against the
  /// memory budget would let an appender grow the tree without bound; charging
  /// `retains` against the write cap would bill the same bytes on every append.
  void recordWrite(
    MountDir mount,
    String path, {
    required int wrote,
    required int retains,
  }) {
    final writeLimit = mount.writeBytesLimit;
    final written = writtenFor(mount) + wrote;
    if (writeLimit != null && written > writeLimit) {
      throw OsCallException(
        'disk write limit of ${formatBytesPretty(writeLimit)} exceeded',
        pythonExceptionType: 'OSError',
      );
    }

    // May throw on the memory budget, which leaves `_written` untouched — the
    // operation did not happen, so it must not be billed.
    _applyCharge(mount, path, entryMemoryUsage + retains);
    _written[mount.virtualPath] = written;
  }

  /// Charges the node a `mkdir` creates.
  void recordMkdir(MountDir mount, String path) =>
      _applyCharge(mount, path, entryMemoryUsage);

  /// Releases whatever [path] was charged. Safe on a path never charged.
  void recordRemove(MountDir mount, String path) {
    final prior = _charge.remove(path);
    if (prior == null) return;
    _retained[mount.virtualPath] = retainedFor(mount) - prior;
  }

  /// Re-keys the charges for a moved subtree.
  ///
  /// A rename inside one mount does not change any total, but the per-path keys
  /// must follow the nodes or a later overwrite computes its delta against the
  /// wrong baseline. Across mounts the charge moves with the bytes.
  void recordMove(
    MountDir fromMount,
    String from,
    MountDir toMount,
    String to,
  ) {
    // Snapshot first: we are about to mutate the map we are walking.
    final moved = <String, int>{};
    for (final entry in _charge.entries) {
      if (entry.key == from || entry.key.startsWith('$from/')) {
        moved[entry.key] = entry.value;
      }
    }

    for (final MapEntry(key: oldPath, value: charge) in moved.entries) {
      _charge.remove(oldPath);
      final newPath = oldPath == from
          ? to
          : '$to${oldPath.substring(from.length)}';
      _charge[newPath] = charge;

      if (fromMount.virtualPath != toMount.virtualPath) {
        _retained[fromMount.virtualPath] = retainedFor(fromMount) - charge;
        _retained[toMount.virtualPath] = retainedFor(toMount) + charge;
      }
    }
  }

  /// Applies a new charge for [path], checking the memory budget against the
  /// DELTA so that overwriting a file in place does not double-count it.
  void _applyCharge(MountDir mount, String path, int charge) {
    final prior = _charge[path] ?? 0;
    final delta = charge - prior;
    final limit = mount.memoryUsageLimit;
    final retained = retainedFor(mount) + delta;

    if (limit != null && retained > limit) {
      throw OsCallException(
        'mount memory usage limit of ${formatBytesPretty(limit)} exceeded',
        pythonExceptionType: 'MemoryError',
      );
    }

    _charge[path] = charge;
    _retained[mount.virtualPath] = retained;
  }
}

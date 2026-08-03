import 'package:dart_monty_core/src/mount/vfs_content.dart';
import 'package:dart_monty_core/src/mount/vfs_node.dart';
import 'package:dart_monty_core/src/mount/vfs_path.dart';

/// Reads content for a [VfsCallbackFile]. Runs on the HOST.
typedef VfsReadCallback = VfsContent Function(String path);

/// Writes content for a [VfsCallbackFile]. Runs on the HOST.
typedef VfsWriteCallback = void Function(String path, VfsContent content);

/// A virtual file backed by custom read/write callbacks.
///
/// This class allows you to create files whose content is dynamically generated
/// or persisted through custom logic. When Monty code reads or writes to this
/// file, the provided callbacks are invoked.
///
/// ## Security Warning
///
/// The callbacks execute in the host environment with FULL access to
/// the real filesystem, network, and all system resources. A callback that
/// accesses the real filesystem effectively breaks the Monty sandbox.
///
/// Example of UNSAFE usage that breaks the sandbox:
///
/// ```dart
/// // DON'T DO THIS - allows Monty to read real files!
/// VfsCallbackFile(
///   '/config.txt',
///   read: (p) => VfsText(File('/etc/passwd').readAsStringSync()),
///   write: (p, c) => File('/tmp/out').writeAsStringSync(c.text),
/// );
/// ```
///
/// For sandboxed execution, use `MontyMemoryFile` instead, which stores content
/// purely in memory with no external access.
///
/// Safe use cases for [VfsCallbackFile]:
///
/// - Returning dynamically computed content (e.g. current timestamp)
/// - Logging writes without persisting them
/// - Validating/transforming content before storage in memory
/// - Integration testing with controlled external resources
///
/// (The warning above is upstream's, repeated verbatim in substance from
/// `os_access.py:684-706`, with the Python example translated to Dart.)
///
/// ## This class is not a sandbox boundary
///
/// It is a *labelled* way to do something the shipped API already permits:
/// `VfsFile` is an open interface, so any consumer can write a host-reaching
/// backing with no import at all. Importing this library makes the intent
/// greppable; it does not make the unlabelled route unavailable. Review every
/// `VfsFile` that is not a `MontyMemoryFile`, not just this one.
///
/// ## The callback always receives the SEEDED path
///
/// Sandboxed Python can rename a file, and a rename rewrites the live [path] of
/// every file in the moved subtree. If the callback were handed that live path,
/// untrusted code could choose the argument the host callback receives, simply
/// by renaming the file inside the mount. Upstream has the same exposure via
/// directory rename (`os_access.py:1128-1136`).
///
/// So the callback is handed [seededPath] — the clamped path this file was
/// constructed with — and never [path]. A rename still moves the file within
/// the tree, and [path] still tracks it so `resolve` and `iterdir` stay
/// correct; only the host-facing argument is frozen.
final class VfsCallbackFile implements VfsFile {
  /// Creates a callback-backed virtual file at [path].
  ///
  /// [read] is invoked whenever Monty reads the file, [write] whenever it
  /// writes. Both run on the host — see the security warning on the class.
  VfsCallbackFile(
    String path, {
    required this.read,
    required this.write,
    this.permissions = 0x1A4,
  }) : seededPath = normalizeVfsPath(path),
       path = normalizeVfsPath(path);

  /// The clamped path this file was constructed with.
  ///
  /// This, never [path], is what [read] and [write] receive. See the class
  /// doc for why.
  final String seededPath;

  /// Invoked on every read. Runs on the HOST.
  final VfsReadCallback read;

  /// Invoked on every write. Runs on the HOST.
  final VfsWriteCallback write;

  /// The file's live path in the tree. A rename rewrites it.
  ///
  /// Deliberately NOT what the callbacks receive.
  @override
  String path;

  @override
  final int permissions;

  /// Invokes [read] with [seededPath]. Note that `stat()` reads too — sizing a
  /// file means asking for its content, exactly as upstream does
  /// (`os_access.py:1024`).
  @override
  VfsContent get content => read(seededPath);

  @override
  set content(VfsContent value) => write(seededPath, value);
}

/// Host-reaching virtual files — **importing this library is a security
/// decision.**
///
/// A `VfsCallbackFile`'s callbacks run in the host environment with full access
/// to the real filesystem, network, and all system resources. A callback that
/// touches the real filesystem effectively breaks the Monty sandbox. That is
/// the caller's decision to make, which is why it lives here rather than in
/// `package:dart_monty_core/dart_monty_core.dart`: the import is an
/// affirmative act, visible in review.
///
/// For sandboxed execution, use `MontyMemoryFile` from the main library.
///
/// **This separation is a signal, not a boundary.** `VfsFile` is an open
/// interface, so a host-reaching backing can be written with no import at all.
/// The reviewer's rule is "audit every `VfsFile` that is not a
/// `MontyMemoryFile`" — this library makes the common case greppable, and does
/// not replace that rule.
library;

export 'src/mount/vfs_callback_file.dart'
    show VfsCallbackFile, VfsReadCallback, VfsWriteCallback;

/// Host-reaching virtual files — **importing this library is a security
/// decision.**
///
/// A `CallbackFile`'s callbacks run in the host environment with full access
/// to the real filesystem, network, and all system resources. A callback that
/// touches the real filesystem effectively breaks the Monty sandbox. That is
/// the caller's decision to make, which is why it lives here rather than in
/// `package:dart_monty_core/dart_monty_core.dart`: the import is an
/// affirmative act, visible in review.
///
/// For sandboxed execution, use `MemoryFile` from the main library.
///
/// **This separation is a signal, not a boundary.** `AbstractFile` is an open
/// interface, so a host-reaching backing can be written with no import at all.
/// The reviewer's rule is "audit every `AbstractFile` that is not a
/// `MemoryFile`" — this library makes the common case greppable, and does
/// not replace that rule.
library;

export 'src/mount/callback_file.dart' show CallbackFile;

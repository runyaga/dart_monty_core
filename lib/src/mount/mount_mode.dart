/// Access mode for a `MountDir`.
enum MountMode {
  /// Reads succeed; writes raise `PermissionError` in Python.
  readOnly,

  /// Reads and writes both succeed.
  readWrite,
}

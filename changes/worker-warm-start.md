### Changed

- Cached workers are hashed in full at installation, then later runs compare a
  recorded size, mtime, and change time fingerprint and re-hash only on a
  mismatch. On macOS and Linux, the change time additionally catches a
  same-size modification with the mtime restored. On Windows,
  `FileStat.changed` is the file creation time rather than the metadata change
  time, so the fingerprint is size, mtime, and creation time. A same-size
  Windows modification with the mtime restored is not detected until the next
  full hash.

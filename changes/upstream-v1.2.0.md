### Changed

- Upgraded to upstream pydantic/monty 1.2.0 (the `v1.2.0` tag). The worker
  protocol moves from version 5 to version 6: the driver now sends
  `protocolVersion` 6, the pinned worker answers it, and a worker that
  speaks a version the driver does not serve is still refused with upstream's
  `monty worker protocol error`.
- Python can import a host module: the worker asks the host for a module (the
  `import` OS call) and for the stubs of the modules it is about to type check
  (the `import_stubs` OS call), and the host answers both from the session's
  module map. A host module travels as a module value, not as a plain
  dictionary, and a module that cannot be named raises `ValueError` while a
  missing one raises `ModuleNotFoundError` in the sandbox.
- The worker can ask the host to scan a path subtree (the `scan` OS call), so
  `os.walk`, `os.scandir`, `Path.walk` and `Path.glob` see the mounted tree
  instead of an empty one.
- `open()` follows CPython's text-mode semantics as upstream 1.2.0 pins them:
  the `newline` argument is validated after the file is opened, so a missing
  file still raises `FileNotFoundError` and a write mode still creates the
  file before the `ValueError`; `None`, `''` and an explicit terminator read
  and write what CPython reads and writes.
- A restored session keeps the destination's ceilings: the dump's resource
  limits and the loader's are tightened into the stricter of the two, so a
  session loaded under a feed or turn duration limit is still bounded by it.
  Upstream 1.1.0 forgot the destination's limits; 1.2.0 keeps them.
- The browser worker module grew with the release: its gzip -9 download
  budget is 6.25 MB, and the 1.2.0 build measures 5.98 MB.

### Fixed

- A Python exception now carries its structured payload: the codec error
  fields of a `UnicodeDecodeError` or `UnicodeEncodeError` (encoding, the
  failing object, the failing range and CPython's reason) and the message,
  document, position, line and column of a `JSONDecodeError`. The host
  rebuilds the real exception from them instead of a message-only fallback.
- A string that starts with a byte-order mark keeps it. The native side sends
  Rust strings, and `String::from_utf8` keeps a leading U+FEFF, while
  package:protobuf's reader dropped it; the frame reader now decodes strings
  the way the native side does, so a BOM in a path, a file name or a printed
  line survives the round trip.

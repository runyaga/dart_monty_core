### Changed

- `OSAccess` handles its arguments as upstream's `OSAccess` does. A `MontyFileHandle` is a path only for `Path.read_text`, `Path.read_bytes`, `Path.write_text`, `Path.write_bytes`, `Path.append_text` and `Path.append_bytes`, and any other call refuses it with a `TypeError` (`Path.is_symlink` answers `False` without reading its argument). `Path.mkdir` raises `AssertionError` for more than two keywords and reads `parents` and `exist_ok` by Python truthiness. The write and append calls take text or bytes in either operation and keep the type they were given.

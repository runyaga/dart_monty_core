### Fixed

- `OSAccess` raises `UnicodeEncodeError` for text with an unpaired UTF-16 surrogate when `Path.read_bytes`, `Path.append_bytes` or `Path.stat` needs its UTF-8 bytes, as upstream does. It no longer encodes the surrogate as U+FFFD.

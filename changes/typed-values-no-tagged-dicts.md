### Fixed

- `MontyValue.fromDart` converts a `Uint8List` to `MontyBytes`. It was converted to a list of ints, so bytes read through `dartValue` and handed back reached the sandbox as a `list`.
- `MontyValue.fromDart` refuses the tagged map that `dartValue` returns for `MontyNamedTuple`, `MontyTimeZone`, `MontyComplex`, `MontyFileHandle`, `MontyExceptionValue`, `MontyClassProxy` and `MontyClassTypeProxy`. It raised no error and the map reached sandboxed Python as a dict with `__type` keys, and for a class instance with its instance and class UUIDs. Pass the `MontyValue` itself back. A plain dict that happens to carry a `__type` key is still a dict.

### Breaking

- `MontyValue.fromDart` converts a `Uint8List` to `MontyBytes` (a copy), at the top level and nested. A `Uint8List` handed back from `dartValue` reaches the sandbox as `bytes`, not a `list` of ints.
- `MontyValue.fromDart` throws an `ArgumentError` for the map that `dartValue` returns for `MontyNamedTuple`, `MontyTimeZone`, `MontyComplex`, `MontyFileHandle`, `MontyExceptionValue`, `MontyClassProxy` and `MontyClassTypeProxy`, at the top level or nested in a list or map. Pass the `MontyValue` itself. A map built by the caller converts to a dict whatever its keys, including a copy of such a map, as `pydantic_monty` converts every host dict.

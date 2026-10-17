### Removed

- `SourceRange.unknown` is no longer public. A suspension from a worker that sent no position still reports an empty file name and an empty range at offset 0, and `==`, `hashCode` and `toString()` are unchanged.

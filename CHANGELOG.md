# Changelog

## 0.0.12 - Initial Release

- Multi-REPL support on WASM with snapshot integration tests
- `compile`, `runPrecompiled`, `startPrecompiled` on WASM + `MontySession` snapshot/restore
- API alignment: `inputs`, `MontySyntaxError`, `jsAligned` flag
- Rename `MontyNull` → `MontyNone`, `callbacks` → `externals`
- `resumeWithException` through full stack for typed OS errors
- 464/464 fixture conformance tests passing on native and WASM
- POSIX VFS, dataclass ext-fns, async dispatch loop for WASM

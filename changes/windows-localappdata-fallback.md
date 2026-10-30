### Fixed

- Windows: the build hook no longer fails with `LOCALAPPDATA must be an absolute path`. The Dart hooks runner filters the hook environment to an allowlist that omits `LOCALAPPDATA`, so the worker cache root now falls back to `%USERPROFILE%\AppData\Local` (`USERPROFILE` is allowlisted) when `LOCALAPPDATA` is absent or relative. This unblocks `dart run` / `dart build` / `dart test` on Windows.

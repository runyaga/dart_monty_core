### Changed

- `dart_monty_core` now looks for a verified per-user worker cache before the
  package-relative worker when running with JIT. The cache uses `HOME` on
  macOS and Linux, `LOCALAPPDATA` on Windows, and verifies worker files with
  SHA-256 before launch.

### Internal

- Added a schema-1 worker artifact manifest for published worker releases.

### Internal

- Removed the tracked `native/lcov.info` coverage artifact (now ignored) and reworded comments and defaults in `tool/` scripts and `native/tests/integration.rs` that embedded a personal home path or account name. `check_vfs_regression.sh` and `dmc_container.sh` now default to `$HOME`-relative paths; both still honour their existing environment overrides.

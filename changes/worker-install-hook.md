### Added

- The native build hook installs published worker release assets into the
  per-user cache, verifies them, and publishes them atomically with an
  installation lock and stale-staging sweep.

### Changed

- The `worker_mirror` user-define overrides the worker release mirror for
  build-hook installations.

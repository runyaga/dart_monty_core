### Added

- Native `MountDir` opens a host directory with overlay, read-only, or read-write access and per-feed write and memory budgets. `feedRun`, `feedStart`, and `loadSnapshot` accept `mount:`; mounts answer before the OS handler and retain their table through snapshot resumes. Browser construction throws `UnsupportedError`.

### Added

- Native `MountDir` opens a host directory with overlay, read-only, or read-write access and per-feed write and memory budgets. `feedRun`, `feedStart`, and `loadSnapshot` accept `mount:`; mounts answer before the OS handler and retain their table through snapshot resumes. Browser construction throws `UnsupportedError`.
- A fresh session defaults cwd to its first mount until a feed passes type checking. Session and snapshot restores preserve their saved cwd; invalid cwd is rejected before mount-table construction without consuming the default.

### Internal

- Restore the strict VM mount-fixture adjudicator, including read-only, closed-mount and lying-handler controls. The native corpus now runs the pinned upstream mount fixtures through real host directories and `MountDir` overlays.

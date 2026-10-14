### Internal

- Unit tests in `test/unit/mount/` now cover the lines only the mount-fs corpus adjudicator reached: `mkdir(parents=True)` through a file raises `NotADirectoryError`, renaming a directory moves its descendants' memory charges, and `OsCallNotHandledException.toString` in both of its shapes. Test-only; no library change.

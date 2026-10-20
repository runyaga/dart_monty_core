### Fixed

- Guard worker-pool factory rollback (`_openEach`), startup cleanup (`_startAll`), startup timeout cancellation (`_ready`), and `PendingSpawn` late start/kill paths so secondary cleanup failures and losing sibling failures do not mask the primary error or escape as unhandled zone errors, recording suppressed failures in an internal bounded sink.

### Internal

- Test and tool cleanups ahead of the cutover, with no change to the package: the corpus test helpers pass the dcm rules ratchet again; the export-boundary self-test's fixtures edit `src/externals.dart`, which survives the old engine's removal; and the worker-only hook test writes its Cargo configuration fixture instead of copying the checkout's.

### Internal

- Test and tool cleanups ahead of the cutover, with no change to the package: the corpus test helpers pass the dcm rules ratchet again; the export-boundary self-test's fixtures edit `src/externals.dart`, which survives the old engine's removal; `MontyException`, the error subclasses, the error hierarchy, the suspension-budget error and `MontyLimits` `toJson`/`fromJson`/value-semantics tests are in their own files, apart from the `MontyResult` and `encodeLimitsJson` groups; and the worker-only hook test writes its Cargo configuration fixture instead of copying the checkout's.

### Breaking

- `MontySession.feedRun`, `feedStart` and `loadSnapshot` take `externalLookup` (upstream's `external_lookup`) in place of `externals`. It is a `Map<String, MontyValue>`, as `inputs` now is: an entry is a host function (`MontyHostFunction`, whose `fn` is called), or any other value (a `ClassInstance` or a `ClassType` among them) converted when the code reads the name and then bound as a global. A host function read by name is named by its key, its docstring kept. A call to a name whose entry is a value raises `TypeError` ("'int' object is not callable"), as upstream's does. A value the converter refuses (a cyclic list, an unpaired surrogate) fails the feed with `MontyRuntimeError` and finishes the session, as upstream discards the checkout. A builtin type in `externalLookup` (a `MontyStdTypeProxy` of kind `type`, such as `int`) called directly by name raises `TypeError`, where upstream runs the type on the host; read the name first (`t = p; t("42")`) and it runs in the sandbox, as upstream's does.

### Added

- `feedRun` and `feedStart` take `cwd` (upstream's `cwd`): the sandbox's working directory, switched before the code runs and kept across feeds. A relative path or one with a NUL throws `MontyRuntimeError` (`ValueError`, upstream's text) and the session runs on; one with an unpaired surrogate throws `ArgumentError`.
- `coroutine` is exported: it marks a host function as an `async def` function, whose calls the sandbox awaits (`asyncio.gather` runs them at once).
- `HostClass` is exported, so a `ClassInstance` or `ClassType` can be built from the public library.

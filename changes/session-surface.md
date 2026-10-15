### Breaking

- `MontySession.feedRun`, `feedStart` and `loadSnapshot` take `externalLookup` (upstream's `external_lookup`) in place of `externals`. It is a `Map<String, Object>`: an entry is a host function, or a value (a `MontyValue`, a `ClassInstance` or a `ClassType`) converted when the code reads the name and then bound as a global. A call to a name whose entry is a value raises `TypeError` ("'int' object is not callable"), as upstream's does. A value the converter refuses (a cyclic list, an unpaired surrogate) fails the feed with `MontyRuntimeError` and finishes the session, as upstream discards the checkout. An entry of any other Dart type throws `ArgumentError` before anything is sent. A closure entry in a map literal needs typed parameters, `(List<MontyValue> args, Map<String, MontyValue> kwargs)`.

### Added

- `feedRun` and `feedStart` take `cwd` (upstream's `cwd`): the sandbox's working directory, switched before the code runs and kept across feeds. A relative path or one with a NUL throws `MontyRuntimeError` (`ValueError`, upstream's text) and the session runs on; one with an unpaired surrogate throws `ArgumentError`.
- `coroutine` is exported: it marks a host function as an `async def` function, whose calls the sandbox awaits (`asyncio.gather` runs them at once).
- `HostClass` is exported, so a `ClassInstance` or `ClassType` can be built from the public library.

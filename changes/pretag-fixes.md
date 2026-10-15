### Breaking

- `ExternalReturnValue` takes and holds a `MontyValue` (`const ExternalReturnValue(MontyValue value)`, `final MontyValue value`), and `NameLookupSnapshot.resume` takes `{MontyValue? value}`; both were typed `Object`. Convert a plain Dart value with `MontyValue.fromDart` first. A host object's `ClassInstance` or `ClassType` wrapper is a `MontyValue` and is still accepted.

### Fixed

- Closing a busy `MontySession` fails the call in flight with `MontyCrashedError` reading `monty worker killed: the session was closed during a turn`; the message used to omit that the worker was killed.
- `FakeMontySession.willRaise` checks each attribute value as the wire writer does, and throws `ArgumentError` at the call for a value a worker could not send (a string with an unpaired surrogate, say), as `willReturn` and `willCall` already did.

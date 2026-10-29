### Changed

- `ExternalModule` and the `externalModules` parameter of `Monty.checkout`
  and `Monty.withSession` now document the module contract: the public
  attributes and the protected ones, the nested modules, the host functions,
  the optional `.pyi` stubs, the shallow copy of the attribute mapping and
  the deferred conversion of a value. The claim that a module never changes
  is qualified: its attribute mapping is copied, but the mutable objects
  that mapping holds are shared with the host's own, so a host change to
  one of them reaches the sandbox the next time the value is converted, and
  a value already imported is not changed. A compact usage example shows a
  module given to a session through `Monty.withPool`.
- The `Monty` class documentation now states the whole contract of the
  module map: the map is read live, an entry is a module or a factory, a
  factory may return a future, a factory that succeeds is cached for the
  session and one that fails is not, so the next request runs it again.

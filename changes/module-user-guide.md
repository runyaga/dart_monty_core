### Added

- A documentation guide for host modules: `docs/reference/host-modules.md`
  states how a host builds an `ExternalModule`, registers it with the
  `externalModules` parameter of `Monty.withSession` or `Monty.checkout`,
  and how the sandbox imports and calls it. It covers the nested modules,
  the protected attributes, the `.pyi` stubs and the stub request the worker
  sends before it type checks a feed, the factories and their lifetime,
  the failures of a stub ask and what each of them leaves installed, the
  routing of the import and stub requests before the mounts and the OS
  handler, and the difference between a module and the `externalLookup`
  values of a feed, whose values outlive the map that carried them.

### Fixed

- Release feed mount tables immediately when automatic name lookup or unresolved-future resumption terminates the session. Abandoned tables also have a native finalizer backstop, including on isolate shutdown.

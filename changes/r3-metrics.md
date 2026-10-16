### Added

- Record the 14 upstream telemetry metrics through `MontyTelemetry`, including pool lifetimes, execution and host-call durations, suspensions, print and snapshot bytes, and complete wire-frame sizes. Measurements use an explicit empty context and preserve upstream instrument metadata and attribute vocabularies on native and browser workers.

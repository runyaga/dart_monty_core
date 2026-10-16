### Added

- Add `MontyTelemetry` and `instrumentTelemetry` for host telemetry adapters on native and web: session, execution and suspension spans, logs, callback context, and `SuspendedSnapshot.traceContext()`. Installation lasts for the isolate; adapter failures disable only the failing signal and report once without interrupting execution.

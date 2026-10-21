# Telemetry

[`instrumentTelemetry`](../../lib/src/worker/telemetry.dart) connects Monty's
pool and session instrumentation to an application-owned `MontyTelemetry`
adapter. Monty supplies no exporter, provider, or credentials. The application
passes the records to its telemetry SDK.

## Adapter contract

Context and span objects belong to the adapter. Monty treats them as opaque
tokens while carrying context from checkout through session spans, host
callbacks, and suspended snapshots. This flow lets the adapter connect Monty
work to the application's existing trace.

[`MontyTelemetry`](../../lib/src/worker/monty_telemetry.dart) defines record
shapes, context behavior, delivery, and failure isolation. Its declaration and
`instrumentTelemetry` are the complete adapter contract.

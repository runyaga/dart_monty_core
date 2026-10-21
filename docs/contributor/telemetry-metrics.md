# Metric lifecycle mapping (R-3)

The instrument definitions and turn state machine follow
`pydantic/monty` 1.1.0, `crates/monty-pool/src/telemetry/metrics.rs`.
`tool/probe_telemetry_metrics.py` captures raw Python meter calls for the six
contract scenarios; `metrics_oracle.dart` is its generated fixture. Run it
with the oracle environment's Python and the optional OpenTelemetry API
extra. Both worker test runners share `_telemetry_metrics_cases.dart`.
Timings are masked, increments and print bytes are exact, and snapshot/frame
samples compare by count and attributes. Snapshot lengths are also checked
against each implementation's own dump. Channel unit tests check frame sizes
against the original bytes, including the four-byte header.

| Upstream termination reason | Core event | Test |
| --- | --- | --- |
| `abandoned` | A lease killed without a completed release: finalizer or explicit in-flight session close | `abandoned lease is counted once` |
| `closed` | Idle pool shutdown, or release after pool close with no waiting checkout | `closed workers balance live and idle increments`; `release after pool close` |
| `died_idle` | A dead idle channel found during acquisition | `died_idle worker removed at next checkout` |
| `discarded` | Protocol/transport/encoding failure, rejected configuration, or failed reset | `discarded worker on failed reset`; `protocol failure discards a checked-out worker` |
| `recycled` | Successful reset reaches `maxCheckoutsPerWorker` | `recycled worker at checkout limit` |
| `single_use` | No corresponding core event: upstream uses this only for WebSocket checkouts; both core transports reuse workers | `single_use has no core transport: reusable channel remains pooled` |

Failed spawns release their reserved live count without a termination: no
worker reached the pool. Checkout outcomes are `idle`, `spawned`, `waited`,
`exhausted`, or `error`. Session duration records once per lease, with `ok`
on successful release, `error` on a discarded worker or failed reset, and `abandoned` when a lease
ends without release. Worker and suspended-worker deltas are balanced on
all exits. Protocol discard records an error before releasing the worker, as in
upstream's `Checkout::discard_worker`.

Metric attributes contain only protocol-defined values. Sandbox function
names and paths never become attributes; OS calls carry their fixed protocol
function name on the host-call duration. [`MontyTelemetry.recordMetric`](../../lib/src/worker/monty_telemetry.dart)
and [`instrumentTelemetry`](../../lib/src/worker/telemetry.dart) define context
and adapter failure behavior.

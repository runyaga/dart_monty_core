# The fake session

`package:dart_monty_core/dart_monty_core_testing.dart` exports
`FakeMontySession`, a `MontySession` that drives host code from a queued worker
script. It needs no worker, sandbox, or Python. Use it to test the Dart side of
a feed. Use a worker-backed session when the test depends on Python execution,
type checking, resource limits, or serialization.

## The fake script drives host code

A test queues the suspensions and outcome for each feed, then calls the normal
session API. The fake and worker-backed sessions share the Dart session driver,
so the test exercises host lookup, OS handling, printing, suspension, and close
integration without executing Python. The fake also records source and host
answers for interaction assertions.

[`FakeMontySession`](../../lib/src/fake_monty_session.dart) defines the script
events, answer records, validation rules, and differences from a worker-backed
session.

## The fake has fixed boundaries

The fake is suitable when the test concerns Dart host integration. Use a real
session for interpreter, type-checker, resource-limit, serialization, or host
object behavior. The `FakeMontySession` declaration states its exact limits.

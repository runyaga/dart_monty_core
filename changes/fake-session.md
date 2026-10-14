### Internal

- `FakeMontySession`, a scriptable session for testing host code without a
  worker, is built internally (`lib/src/fake_monty_session.dart`); the
  testing library exports it at the cutover. A test queues what each feed's
  Python does (host calls, OS calls, name lookups, awaits, prints, and the
  end), and the session's own driver answers each suspension as it would
  against a worker; the fake records the feeds and the host's answers.
- A contract suite (`test/contract/`) runs each scenario as Python on a
  worker-backed session and as a script on the fake, and requires the same
  host calls, prints, snapshots, answers and end on both, on vm, dart2js and
  dart2wasm.

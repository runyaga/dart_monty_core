### Internal

- `hook/build.dart` builds the opted-in worker library (`build_worker: true`)
  whether or not the in-process crate's `native/Cargo.toml` is present, and
  declares `native/rust-toolchain.toml` as one of the worker's own inputs.
  Consumers that do not opt in see no change.
- The coverage ratchet reports a baseline file that the change deletes
  (`git diff --diff-filter=D` against `RATCHET_BASE_REF`) as `DELETED`, not
  `VANISHED`, and compares the lib-wide total with the baseline's total over
  the files the change keeps. `--self-test` runs its controls, in the gate and
  in CI.
- CI's `Dart test (JIT)` job and the gate's `unit_tests` step provide the
  worker executable first, so an untagged unit test may start a real pool.

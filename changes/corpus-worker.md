### Internal

- The upstream pydantic-monty 1.1.0 test corpus (643 files, pinned by the git tree hash in `tool/upstream/upstream-pin.json`) runs on the worker: one session per file through the pool, judged by the strict adjudicator, on Linux and macOS natively and in Chrome and Firefox under dart2js and dart2wasm. Every file the worker fails is listed in a manifest with a divergence ID, and a run fails on any difference from it. A crash test kills a worker and checks the same one-worker pool serves the next checkout. The old corpus runner is untouched.

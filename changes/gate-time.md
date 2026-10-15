### Internal

- CI: the export-boundary self-test (about 10.5 of the `gate · source-only · no-browser` job's 11.5 minutes, which kept hitting its 12-minute limit) runs as six parallel `gate · export-boundary self-test (shard N/6)` jobs. `tool/check_export_boundary.dart --self-test --shard <i>/<n>` runs the controls at positions congruent to `i` mod `n`; the shards are every control exactly once, and the job fails if the matrix is not six shards. The source-only job now asserts 24 checks and has an 8-minute limit; `tool/gate.sh` still runs the full self-test (step count unchanged).

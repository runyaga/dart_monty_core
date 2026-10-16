### Internal

- Remove process files: the filesystem design record `vfs-phases.md`, `test/fixtures/repros/`, the unused mount disposition table, a dangling `test_cases` symlink and the four per-area mutation runners.
- The coverage baseline is refreshed once per release in the release PR (`changelog-assembly` label); `record_coverage_baseline.sh` gains `--no-commit` and `check_changelog_fragments.sh` allows the baseline edit in that PR only. The coverage ratchet treats a baseline entry for a file already deleted at the base ref as DELETED, so a deletion merged between releases does not fail later PRs.

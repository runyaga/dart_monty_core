### Internal

- The breaking-change ledger (`tool/breaking-ledger.tsv`) and its check
  (`tool/check_breaking_recorded.sh`, the `Breaking changes announced` CI job
  and the `breaking_rec` gate step) are retired. Breaking changes are recorded
  in the release notes only; the existing `CHANGELOG.md` entries are the
  history.

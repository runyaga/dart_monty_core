# Changelog fragments

Each pull request records its user-visible change here as `changes/<slug>.md`
instead of editing `CHANGELOG.md`. `CHANGELOG.md` is assembled from these files
when a release is cut, so two PRs never conflict on it.

A fragment starts with a section header, then the entry:

```markdown
### Added

- `Foo.bar()` does the thing. Explain it the way the CHANGELOG entry reads.
```

Sections: `Added`, `Changed`, `Fixed`, `Breaking`, `Removed`, `Deprecated`,
`Security`, `Internal`. One fragment may hold several sections. No other line may start with `#` (indented or not), and fenced code blocks
are not supported: assembly splits `CHANGELOG.md` on heading lines. Use inline
code. Keep the slug
short and unique (a feature name, not a PR number you do not have yet).

CI (`.github/workflows/changelog-fragments.yml`) requires a fragment on any PR
that changes `lib/`. Exempt a PR with the `no-changelog` label, or a PR-body
line starting `no-changelog:` and a reason. A PR must not edit `CHANGELOG.md`;
only the assembly or release PR (label `changelog-assembly`) does.

A breaking change also needs its row in `tool/breaking-ledger.tsv`; the ledger
anchor may point at fragment text until assembly moves it into `CHANGELOG.md`.

To assemble (at tag or release time, in its own PR):

```bash
dart tool/changelog_assemble.dart                  # fold into ## Unreleased
dart tool/changelog_assemble.dart --version 0.24.0 # fold into a new ## 0.24.0
```

This folds every fragment into `CHANGELOG.md` and deletes the fragments.
`--dry-run` prints the result instead.

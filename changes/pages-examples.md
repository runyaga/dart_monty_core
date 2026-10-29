### Added

- `tool/build_pages.py`, a standard-library Python builder that assembles
  the GitHub Pages site from repository files alone: `site/index.html`
  from the `docs/index.html` shell plus versions derived from
  `pubspec.yaml` and `tool/upstream/upstream-pin.json`, and a local copy
  of each catalogue entry's source under `site/examples/`. Its `--check`
  mode builds into a temporary directory, verifies every local page link
  and source copy, requires examples 15-18 -- each on the page as a link
  outside an HTML comment, with its `dart run` command as shown text --
  and checks that `deploy-pages.yml` runs the same builder as its build
  step, as exactly `python3 -B tool/build_pages.py`, and uploads exactly
  `site/`; it fails on missing inputs or leftover demo references. The
  check is string and line matching, by owner decision: it verifies
  honest edits, not tampering, so crafted bypasses (links hidden in
  inert wrappers, shell punctuation around the command, interpreter
  flags such as `-c`, `-m` or `-V`) are out of scope. The offline check
  proves assembly and local links only: the Pages upload, the
  OIDC/environment authorization and live serving need a workflow run.

### Changed

- The published site is a static catalogue of the four downloadable
  native examples — `example/15_host_module.dart`,
  `example/16_step_debugger.dart`, `example/17_restore_limits.dart` and
  `example/18_durable_agent.dart` — each with an accurate description,
  its `dart run` command and a link to the local copy of its source.
  Versions shown on the page are derived from the tree instead of being
  written on it, and the obsolete in-browser demo links and stale version
  line are gone from `docs/index.html`.

### Removed

- The Node and Dart SDK setup, `pub get`, the committed-asset copies and
  the web-demo compilation from `deploy-pages.yml`; the workflow now runs
  the builder and uploads what it assembled.

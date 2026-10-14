#!/usr/bin/env bash
# =============================================================================
# CHANGELOG fragments: every lib/ change adds one, nobody edits CHANGELOG.md
# =============================================================================
# Each PR records its user-visible change as changes/<slug>.md. CHANGELOG.md is
# assembled from the fragments at tag or release time (tool/changelog_assemble
# .dart). That moves the one line every PR used to edit, and so conflict on,
# into a file only that PR touches.
#
# Rules, checked against a PR's diff (merge-base with BASE..HEAD):
#   1. A PR that changes lib/ adds at least one changes/<slug>.md, unless it has
#      the `no-changelog` label or a PR-body line starting `no-changelog`.
#   2. A PR does not edit CHANGELOG.md, unless it has the `changelog-assembly`
#      label (the assembly or release PR). That label waives only this rule.
#   3. Every changes/*.md in the tree is well formed: it starts with a
#      `### <Section>` header (Added, Changed, Fixed, Breaking, Removed,
#      Deprecated, Security or Internal) and every section has a body.
#
# Labels and body come from the environment, never from interpolation into a
# shell command: PR_LABELS (JSON array of names) and PR_BODY.
#
# Usage:
#   bash tool/check_changelog_fragments.sh BASE_REF    # a PR (CI)
#   bash tool/check_changelog_fragments.sh --lint      # rule 3 only
#   bash tool/check_changelog_fragments.sh --self-test # negative controls + lint
# Exit 0 pass, 1 finding.
# =============================================================================
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
REPO="${CHANGELOG_CHECK_REPO:-$(git rev-parse --show-toplevel)}"

SECTIONS='Added|Changed|Fixed|Breaking|Removed|Deprecated|Security|Internal'

lint_fragments() {
  local rc=0 f n=0
  while IFS= read -r -d '' f; do
    [ -n "$f" ] || continue
    case "$f" in
      changes/README.md) continue ;;
      changes/*/*) echo "  $f: nested paths are not assembled; use changes/<slug>.md"
                   rc=1; continue ;;
      changes/.*) echo "  $f: hidden files are not assembled; rename it"
                  rc=1; continue ;;
      changes/*.md) ;;
      *) echo "  $f: only changes/<slug>.md files belong in changes/"
         rc=1; continue ;;
    esac
    n=$((n + 1))
    if ! python3 -I - "$REPO/$f" "$SECTIONS" <<'PY'
import re, sys
path, sections = sys.argv[1], sys.argv[2]
text = open(path, encoding='utf-8').read()
lines = [l for l in text.splitlines()]
first = next((l for l in lines if l.strip()), None)
hdr = re.compile(r'^### (%s)\s*$' % sections)
# Assembly splits CHANGELOG.md on heading lines, so a fragment may hold only
# its `### <Section>` headers: no other line may start with '#' (indented or
# not), and fenced blocks, where a '#' line is ordinary text, are not allowed.
for i, l in enumerate(lines, 1):
    t = l.lstrip()
    if t.startswith(('```', '~~~')):
        print(f'  {path}:{i}: fenced code blocks are not supported in a '
              f'fragment; use inline code')
        sys.exit(1)
    if t.startswith('#') and not hdr.match(l):
        if not l.startswith('### ') or t != l:
            print(f'  {path}:{i}: heading-like line {l!r}; only "### <Section>" '
                  f'headers are allowed')
            sys.exit(1)
if first is None or not hdr.match(first):
    print(f'  {path}: must start with a "### <Section>" header '
          f'({sections.replace("|", ", ")})')
    sys.exit(1)
cur, has_body, ok = None, False, True
for l in lines:
    if l.startswith('### '):
        if cur is not None and not has_body:
            print(f'  {path}: section "{cur}" has no body'); ok = False
        if not hdr.match(l):
            print(f'  {path}: unknown section header {l!r}'); ok = False
        cur, has_body = l[4:].strip(), False
    elif l.strip():
        has_body = True
if cur is not None and not has_body:
    print(f'  {path}: section "{cur}" has no body'); ok = False
sys.exit(0 if ok else 1)
PY
    then rc=1; fi
  done < <({ git -C "$REPO" ls-files -z 'changes/*'
             git -C "$REPO" ls-files -z -o --exclude-standard 'changes/*'; } | sort -zu)
  return $rc
}

check_pr() {
  local base="$1" mb rc=0 status path lib=0 chg=0 frag=0 f
  mb="$(git -C "$REPO" merge-base "$base" HEAD)" ||
    { echo "FAIL: no merge-base with $base (fetch-depth: 0?)"; return 1; }
  while IFS= read -r -d '' status && IFS= read -r -d '' path; do
    [ -n "$path" ] || continue
    case "$path" in
      lib/*) lib=1 ;;
      CHANGELOG.md) chg=1 ;;
      changes/README.md) ;;
      changes/*/*) ;;
      changes/*.md) [ "$status" = "A" ] && frag=$((frag + 1)) ;;
    esac
  done < <(git -C "$REPO" diff -z --name-status --no-renames "$mb" HEAD)

  local labels="${PR_LABELS:-[]}" body="${PR_BODY:-}"
  # Exact membership in the JSON array, not a substring of its text.
  has_label(){ python3 -I -c 'import json,sys; sys.exit(0 if sys.argv[1] in json.loads(sys.argv[2]) else 1)' "$1" "$labels"; }

  if [ "$chg" = 1 ] && ! has_label changelog-assembly; then
    echo "FAIL: this PR edits CHANGELOG.md. Add a fragment changes/<slug>.md"
    echo "      instead; CHANGELOG.md is assembled at release time. (An"
    echo "      assembly or release PR carries the changelog-assembly label.)"
    rc=1
  fi
  if [ "$lib" = 1 ] && [ "$frag" = 0 ]; then
    if has_label no-changelog ||
       printf '%s\n' "$body" | grep -qiE '^[[:space:]]*no-changelog\b'; then
      echo "note: lib/ changed with no fragment; exempt (no-changelog)."
    else
      echo "FAIL: this PR changes lib/ but adds no changes/<slug>.md."
      echo "      Add one (see changes/README.md), or label the PR no-changelog"
      echo "      or put a line starting 'no-changelog' in the PR body."
      rc=1
    fi
  fi
  lint_fragments || rc=1
  [ "$rc" = 0 ] && echo "PASS: changelog fragments ($frag added)"
  return $rc
}

self_test() {
  local tmp rc=0 base
  tmp="$(mktemp -d)"; trap '/bin/rm -rf "$tmp"' RETURN
  git init -q "$tmp" && (
    cd "$tmp" && git config user.email t@t && git config user.name t &&
    mkdir lib changes && echo a > lib/a.dart && echo '# Changelog' > CHANGELOG.md &&
    echo '# fragments' > changes/README.md && git add -A && git commit -qm base
  ) || return 1
  base="$(git -C "$tmp" rev-parse HEAD)"
  run(){ # name expect labels body
    local name="$1" want="$2"; shift 2
    local out got=0
    out="$(CHANGELOG_CHECK_REPO="$tmp" PR_LABELS="$1" PR_BODY="$2" bash "$SELF" "$base" 2>&1)" || got=1
    if [ "$got" != "$want" ]; then
      echo "SELF-TEST FAIL: $name (expected exit $want, got $got)"; echo "$out"; rc=1
    else echo "ok: $name"; fi
  }
  reset(){ git -C "$tmp" checkout -q -f "$base" && git -C "$tmp" clean -qfd; }
  commit(){ git -C "$tmp" add -A && git -C "$tmp" commit -qm x; }
  frag(){ printf '### Added\n\n- thing\n' > "$tmp/changes/$1.md"; }

  reset; echo b >> "$tmp/lib/a.dart"; commit
  run "lib change, no fragment: must FAIL" 1 '[]' ''
  run "lib change, no-changelog label" 0 '["no-changelog"]' ''
  run "lib change, body says no-changelog" 0 '[]' $'text\nno-changelog: internal'
  run "body mentions it mid-line only: must FAIL" 1 '[]' 'we say no-changelog here'
  reset; echo b >> "$tmp/lib/a.dart"; frag one; commit
  run "lib change with fragment" 0 '[]' ''
  reset; echo b >> "$tmp/lib/a.dart"; frag one; echo x >> "$tmp/CHANGELOG.md"; commit
  run "edits CHANGELOG.md directly: must FAIL" 1 '[]' ''
  run "edits CHANGELOG.md with no-changelog label: must FAIL" 1 '["no-changelog"]' ''
  run "edits CHANGELOG.md, assembly label" 0 '["changelog-assembly"]' ''
  reset; echo '# docs' > "$tmp/README.md"; commit
  run "docs-only change" 0 '[]' ''
  reset; echo b >> "$tmp/lib/a.dart"; echo 'no header' > "$tmp/changes/bad.md"; commit
  run "malformed fragment: must FAIL" 1 '["no-changelog"]' ''
  reset; echo b >> "$tmp/lib/a.dart"; printf '### Added\n' > "$tmp/changes/empty.md"; commit
  run "fragment header with no body: must FAIL" 1 '[]' ''
  reset; echo b > "$tmp/lib/caf"$'\303\251'".dart"; commit
  run "non-ASCII lib path, no fragment: must FAIL" 1 '[]' ''
  reset; echo x >> "$tmp/CHANGELOG.md"; commit
  run "label that merely contains the waiver text: must FAIL" 1 '["x\"changelog-assembly"]' ''
  reset; echo b >> "$tmp/lib/a.dart"; echo x >> "$tmp/CHANGELOG.md"; commit
  run "lib change, assembly label alone: must FAIL" 1 '["changelog-assembly"]' ''
  reset; echo b >> "$tmp/lib/a.dart"; printf '### Added\n\n- x\n### End\n\n- y\n' > "$tmp/changes/end.md"; commit
  run "unknown section header: must FAIL" 1 '[]' ''
  reset; echo b >> "$tmp/lib/a.dart"; printf '### Added\n\n```\n## Example\n```\n' > "$tmp/changes/h.md"; commit
  run "release-level heading in fragment: must FAIL" 1 '[]' ''
  reset; echo b >> "$tmp/lib/a.dart"; printf '### Fixed\n\n```\n### Added\n```\n' > "$tmp/changes/f2.md"; commit
  run "fenced block: must FAIL" 1 '[]' ''
  reset; echo b >> "$tmp/lib/a.dart"; printf '### Added\n\n    ## Example\n' > "$tmp/changes/ind.md"; commit
  run "indented heading-like line: must FAIL" 1 '[]' ''
  reset; echo b >> "$tmp/lib/a.dart"; printf '### Added\n\n- x\n' > "$tmp/changes/.hid.md"; commit
  run "hidden fragment: must FAIL" 1 '[]' ''
  reset; echo b >> "$tmp/lib/a.dart"; mkdir "$tmp/changes/sub"; printf '### Added\n\n- x\n' > "$tmp/changes/sub/n.md"; commit
  run "nested fragment: must FAIL" 1 '["no-changelog"]' ''
  [ "$rc" = 0 ] && lint_fragments && echo "self-test passed" || rc=1
  return $rc
}

case "${1:-}" in
  --self-test) self_test ;;
  --lint) lint_fragments && echo "PASS: fragments well formed" ;;
  '') echo "usage: $0 BASE_REF | --lint | --self-test" >&2; exit 2 ;;
  *) check_pr "$1" ;;
esac

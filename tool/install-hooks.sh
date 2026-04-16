#!/usr/bin/env bash
# =============================================================================
# Install git hooks for dart_monty_core.
# Run once after cloning:  bash tool/install-hooks.sh
# =============================================================================
set -euo pipefail

PKG="$(cd "$(dirname "$0")/.." && pwd)"
# git rev-parse --git-common-dir returns the shared .git dir even in a
# worktree (where .git is a file, not a directory).
HOOKS_DIR="$(git -C "$PKG" rev-parse --git-common-dir)/hooks"

if [ ! -d "$HOOKS_DIR" ]; then
  mkdir -p "$HOOKS_DIR"
fi

HOOK="$HOOKS_DIR/pre-commit"
cat > "$HOOK" << 'EOF'
#!/usr/bin/env bash
exec "$(git rev-parse --show-toplevel)/tool/pre-commit.sh"
EOF
chmod +x "$HOOK"

echo "Installed: $HOOK → tool/pre-commit.sh"
echo "Done. The pre-commit hook will now run on every 'git commit'."

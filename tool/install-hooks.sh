#!/usr/bin/env bash
# =============================================================================
# Install git hooks for dart_monty_core.
# Run once after cloning:  bash tool/install-hooks.sh
# =============================================================================
set -euo pipefail

PKG="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS_DIR="$PKG/.git/hooks"

if [ ! -d "$HOOKS_DIR" ]; then
  echo "ERROR: $HOOKS_DIR not found. Are you inside a git repo?"
  exit 1
fi

HOOK="$HOOKS_DIR/pre-commit"
cat > "$HOOK" << 'EOF'
#!/usr/bin/env bash
exec "$(git rev-parse --show-toplevel)/tool/pre-commit.sh"
EOF
chmod +x "$HOOK"

echo "Installed: $HOOK → tool/pre-commit.sh"
echo "Done. The pre-commit hook will now run on every 'git commit'."

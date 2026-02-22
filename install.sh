#!/usr/bin/env bash
# Install bmad-autopilot into a BMAD project
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Determine target project
TARGET="${1:-.}"
TARGET="$(cd "$TARGET" && pwd)"

# Verify it's a BMAD project
if [[ ! -d "$TARGET/_bmad" ]]; then
  echo "❌ Not a BMAD project (no _bmad/ directory found in $TARGET)"
  echo "Usage: ./install.sh /path/to/your/bmad-project"
  exit 1
fi

# Create target directory
DEST="$TARGET/.scripts/bmad-auto"
mkdir -p "$DEST/logs"

# Copy files
cp "$SCRIPT_DIR/bmad-loop.sh" "$DEST/"
cp "$SCRIPT_DIR/bmad-prompt.md" "$DEST/"
cp "$SCRIPT_DIR/README.md" "$DEST/"
chmod +x "$DEST/bmad-loop.sh"

echo "✅ BMAD Autopilot installed to $DEST/"
echo ""
echo "Usage:"
echo "  cd \"$TARGET\""
echo "  ./.scripts/bmad-auto/bmad-loop.sh"
echo ""
echo "Make sure 'claude' CLI is available and you have a sprint-status.yaml."

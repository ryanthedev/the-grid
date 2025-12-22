#!/bin/bash
# Reapply layouts to all spaces
# If a space has no layout, applies "default"

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
THEGRID="${THEGRID:-$REPO_DIR/grid-cli/bin/thegrid}"

# Get all space IDs
spaces=$($THEGRID dump --json | jq -r '.spaces | keys[]')

for space_id in $spaces; do
    # Get current layout for this space
    layout_output=$($THEGRID layout current --space "$space_id" --json 2>&1) || true

    if echo "$layout_output" | jq -e '.layoutId' > /dev/null 2>&1; then
        # Has a layout - reapply it
        layout_id=$(echo "$layout_output" | jq -r '.layoutId')
        echo "Space $space_id: reapplying '$layout_id'"
        $THEGRID layout apply "$layout_id" --space "$space_id"
    else
        # No layout - apply default
        echo "Space $space_id: applying 'default'"
        $THEGRID layout apply default --space "$space_id"
    fi
done

echo "Done"

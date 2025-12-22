#!/bin/bash
# Reset accessibility permissions for TheGrid
# Use this when TCC gets confused after signature changes

set -e

BUNDLE_ID="com.thegrid.server"

echo "Resetting accessibility permissions for $BUNDLE_ID..."
tccutil reset Accessibility "$BUNDLE_ID"

echo "Done. Re-run the app to trigger the permission prompt."
echo ""
echo "If you still have issues:"
echo "  1. Open System Settings → Privacy & Security → Accessibility"
echo "  2. Remove GridServer if present"
echo "  3. Run: make run"
echo "  4. Grant permission when prompted"

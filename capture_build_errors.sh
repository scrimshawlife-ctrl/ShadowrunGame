#!/bin/bash
# Run xcodebuild and capture the FIRST real errors.
# Xcode's Issue Navigator often shows cascading downstream errors that hide the root cause.
# The command-line compiler output shows errors in source order.
#
# Run with Xcode CLOSED for a clean build.
set -u

PROJECT_DIR="$HOME/.openclaw/workspace/workspace-coding/ShadowrunGame"
cd "$PROJECT_DIR"

LOG="build.log"
echo "=== Running xcodebuild (this will take 30-60 seconds) ==="
xcodebuild \
    -project ShadowrunGame.xcodeproj \
    -scheme ShadowrunGame \
    -destination 'generic/platform=iOS Simulator' \
    -configuration Debug \
    clean build 2>&1 | tee "$LOG"

echo
echo "=== FIRST 10 errors (real root causes) ==="
grep -E "error:" "$LOG" | head -10
echo
echo "=== FIRST 10 warnings ==="
grep -E "warning:" "$LOG" | head -10
echo
echo "=== Error count ==="
echo "errors:   $(grep -cE "error:" "$LOG")"
echo "warnings: $(grep -cE "warning:" "$LOG")"
echo
echo "Full log at: $PROJECT_DIR/$LOG"

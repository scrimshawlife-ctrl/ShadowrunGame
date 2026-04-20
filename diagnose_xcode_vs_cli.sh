#!/bin/bash
# Pull Xcode's ACTUAL build log (different from Issue Navigator / SourceKit).
# Also builds with the EXACT destination Xcode uses (iPhone 17 Pro) so we rule
# out generic/device differences.

PROJECT_DIR="$HOME/.openclaw/workspace/workspace-coding/ShadowrunGame"
cd "$PROJECT_DIR"

echo "=== 1. Check what's in DerivedData right now ==="
ls -la ~/Library/Developer/Xcode/DerivedData/ 2>&1 | grep -i shadow

echo
echo "=== 2. Find + decode the most recent Xcode build log ==="
LATEST_LOG=$(find ~/Library/Developer/Xcode/DerivedData/ShadowrunGame-*/Logs/Build -name "*.xcactivitylog" 2>/dev/null | xargs ls -t 2>/dev/null | head -1)
if [ -n "$LATEST_LOG" ]; then
    echo "Found Xcode build log: $LATEST_LOG"
    echo
    echo "--- last 80 lines of Xcode's build log ---"
    # xcactivitylog is gzipped. Decode and filter.
    gunzip -c "$LATEST_LOG" 2>/dev/null | tr -d '\0' | tr '\r' '\n' | grep -aE "error:|warning:|FAILED|\.swift:[0-9]+" | tail -80
else
    echo "(no Xcode build log found — did you actually try to build in Xcode?)"
fi

echo
echo "=== 3. Build CLI with EXACT iPhone 17 Pro destination ==="
xcodebuild \
    -project ShadowrunGame.xcodeproj \
    -scheme ShadowrunGame \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
    -configuration Debug \
    clean build 2>&1 | grep -aE "error:|BUILD " | head -20

echo
echo "=== 4. What's the scheme pointing to? ==="
SCHEME=$(find . -name "ShadowrunGame.xcscheme" 2>/dev/null | head -1)
if [ -n "$SCHEME" ]; then
    echo "Scheme file: $SCHEME"
    grep -E "BuildConfiguration|Runnable|BlueprintName" "$SCHEME" | head -10
fi

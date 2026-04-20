#!/bin/bash
# Nuke ALL Xcode caches — SourceKit index, module cache, DerivedData.
# This is the most aggressive thing you can do short of reinstalling Xcode.
# Run with Xcode CLOSED.
set -u

echo "=== 1. DerivedData (build outputs + index) ==="
rm -rfv ~/Library/Developer/Xcode/DerivedData/ShadowrunGame-* 2>/dev/null || echo "  (none)"

echo
echo "=== 2. Swift module cache ==="
rm -rfv ~/Library/Developer/Xcode/DerivedData/ModuleCache.noindex 2>/dev/null || echo "  (none)"

echo
echo "=== 3. SourceKit logs / state ==="
rm -rfv ~/Library/Caches/com.apple.dt.Xcode/* 2>/dev/null || echo "  (none)"

echo
echo "=== 4. Xcode's persisted state for this project ==="
# the workspace-specific state
rm -rfv ~/Library/Saved\ Application\ State/com.apple.dt.Xcode.savedState 2>/dev/null || echo "  (none)"

echo
echo "=== 5. Re-run the build from CLI to confirm code compiles ==="
cd "$HOME/.openclaw/workspace/workspace-coding/ShadowrunGame"
xcodebuild \
    -project ShadowrunGame.xcodeproj \
    -scheme ShadowrunGame \
    -destination 'generic/platform=iOS Simulator' \
    -configuration Debug \
    clean build 2>&1 | tail -5

echo
echo "=== DONE ==="
echo "Now open Xcode FRESH:"
echo "  open ~/.openclaw/workspace/workspace-coding/ShadowrunGame/ShadowrunGame.xcodeproj"
echo "Wait ~30s for indexing (status bar top center). Then ⌘R."

#!/bin/bash
# Complete fix: clean project, regen from new project.yml, nuke all Xcode caches,
# rebuild via xcodebuild to confirm code compiles.
# Run with Xcode CLOSED.
set -u

PROJECT_DIR="$HOME/.openclaw/workspace/workspace-coding/ShadowrunGame"
cd "$PROJECT_DIR"

echo "=== 1. Delete xcodeproj backup folder (pollutes pbxproj groups) ==="
rm -rfv ShadowrunGame.xcodeproj.backup-* 2>/dev/null || echo "  (none)"

echo
echo "=== 2. Regenerate pbxproj from updated project.yml ==="
# stash xcuserdata so we keep breakpoints/windows
USERDATA_BACKUP=""
if [ -d "ShadowrunGame.xcodeproj/xcuserdata" ]; then
    USERDATA_BACKUP=$(mktemp -d)
    cp -a ShadowrunGame.xcodeproj/xcuserdata "$USERDATA_BACKUP/"
fi

xcodegen generate

if [ -n "$USERDATA_BACKUP" ] && [ -d "$USERDATA_BACKUP/xcuserdata" ]; then
    cp -a "$USERDATA_BACKUP/xcuserdata" ShadowrunGame.xcodeproj/
    rm -rf "$USERDATA_BACKUP"
fi

echo
echo "=== 3. Nuke ALL Xcode caches for this project ==="
rm -rfv ~/Library/Developer/Xcode/DerivedData/ShadowrunGame-* 2>/dev/null || true
rm -rf ~/Library/Developer/Xcode/DerivedData/ModuleCache.noindex 2>/dev/null || true

echo
echo "=== 4. Verify no group-duplication or backup-path warnings in new pbxproj ==="
SWIFT_COUNT=$(grep -oE "[A-Za-z_]+\.swift in Sources" ShadowrunGame.xcodeproj/project.pbxproj | sort -u | wc -l | tr -d ' ')
echo "  unique .swift files in pbxproj: $SWIFT_COUNT (want 19)"
echo "  SWIFT_STRICT_CONCURRENCY: $(grep SWIFT_STRICT_CONCURRENCY ShadowrunGame.xcodeproj/project.pbxproj | head -1 | tr -d ' ;')"

echo
echo "=== 5. CLI build to confirm code compiles ==="
xcodebuild \
    -project ShadowrunGame.xcodeproj \
    -scheme ShadowrunGame \
    -destination 'generic/platform=iOS Simulator' \
    -configuration Debug \
    clean build 2>&1 | tail -15 | grep -E "error:|warning:|BUILD " | head -20

echo
echo "=== DONE ==="
echo "If you see 'BUILD SUCCEEDED' above with ~0 errors, code is fine."
echo "Now open Xcode FRESH:"
echo "  open ~/.openclaw/workspace/workspace-coding/ShadowrunGame/ShadowrunGame.xcodeproj"
echo "WAIT ~30 seconds for indexing (watch top-center status bar)."
echo "Then ⇧⌘K (Clean Build Folder), then ⌘R (Run)."

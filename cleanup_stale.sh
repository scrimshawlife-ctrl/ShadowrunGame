#!/bin/bash
# ShadowrunGame stale folder cleanup
# Run this in Terminal with Xcode QUIT first.
set -u

LIVE="$HOME/.openclaw/workspace/workspace-coding/ShadowrunGame"
OLD="$HOME/.openclaw/workspace-coding/ShadowrunGame"

echo "=== 1. Sanity check: live project must exist ==="
if [ ! -d "$LIVE" ]; then
    echo "ERROR: Live project not found at $LIVE — aborting."
    exit 1
fi
if [ ! -f "$LIVE/Rendering/TileMap.swift" ]; then
    echo "ERROR: $LIVE/Rendering/TileMap.swift missing — aborting."
    exit 1
fi
echo "OK: live project present at $LIVE"

echo
echo "=== 2. Delete backup folder inside live project ==="
rm -rfv "$LIVE"/.replaced-* 2>/dev/null || true

echo
echo "=== 3. Delete the OLD duplicate project folder ==="
if [ -d "$OLD" ]; then
    rm -rfv "$OLD"
else
    echo "(already gone)"
fi

# Also nuke the now-empty parent if it only held ShadowrunGame
if [ -d "$HOME/.openclaw/workspace-coding" ] && [ -z "$(ls -A "$HOME/.openclaw/workspace-coding" 2>/dev/null)" ]; then
    rmdir "$HOME/.openclaw/workspace-coding"
    echo "removed empty parent ~/.openclaw/workspace-coding"
fi

echo
echo "=== 4. Delete ALL Xcode DerivedData for ShadowrunGame ==="
rm -rfv ~/Library/Developer/Xcode/DerivedData/ShadowrunGame-* 2>/dev/null || true

echo
echo "=== 5. Clear Xcode's Recent Projects list ==="
defaults delete com.apple.dt.Xcode IDERecentWorkspaceDocuments 2>/dev/null || true
defaults delete com.apple.dt.Xcode NSNavRecentPlaces 2>/dev/null || true
echo "done"

echo
echo "=== 6. Verify the live project is still intact ==="
echo "TileMap.swift:     $(wc -l < "$LIVE/Rendering/TileMap.swift") lines"
echo "SpriteManager:     $(wc -l < "$LIVE/Rendering/SpriteManager.swift") lines"
echo "BattleScene:       $(wc -l < "$LIVE/Rendering/BattleScene.swift") lines"
echo "LIVE BUILD marker: $(grep -c 'LIVE BUILD' "$LIVE/Rendering/TileMap.swift") (want 1)"
echo "DEBUG MARKER:      $(grep -c 'debugMarker' "$LIVE/Rendering/SpriteManager.swift") (want ≥1)"
echo "zPosition = 50:    $(grep -c 'zPosition = 50' "$LIVE/Rendering/BattleScene.swift") (want 2)"

echo
echo "=== DONE ==="
echo "Now open Xcode ONLY from: $LIVE/ShadowrunGame.xcodeproj"
echo "Then: Product → Clean Build Folder (⇧⌘K), then Run."

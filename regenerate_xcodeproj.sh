#!/bin/bash
# Regenerate ShadowrunGame.xcodeproj from project.yml.
# Run with Xcode CLOSED. Run from the project folder.
set -eu

PROJECT_DIR="$HOME/.openclaw/workspace/workspace-coding/ShadowrunGame"
cd "$PROJECT_DIR"

echo "=== 1. Ensure XcodeGen is installed ==="
if ! command -v xcodegen >/dev/null 2>&1; then
    echo "XcodeGen not found. Installing via Homebrew..."
    if ! command -v brew >/dev/null 2>&1; then
        echo "ERROR: Homebrew not installed. Install from https://brew.sh then rerun."
        exit 1
    fi
    brew install xcodegen
else
    echo "XcodeGen: $(xcodegen --version 2>&1 | head -1)"
fi

echo
echo "=== 2. Back up current .xcodeproj ==="
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="ShadowrunGame.xcodeproj.backup-$STAMP"
if [ -d "ShadowrunGame.xcodeproj" ]; then
    cp -a ShadowrunGame.xcodeproj "$BACKUP"
    echo "Backed up to: $BACKUP"
fi

echo
echo "=== 3. Preserve user state (breakpoints, window layout) ==="
USERDATA_BACKUP=""
if [ -d "ShadowrunGame.xcodeproj/xcuserdata" ]; then
    USERDATA_BACKUP=$(mktemp -d)
    cp -a ShadowrunGame.xcodeproj/xcuserdata "$USERDATA_BACKUP/"
    echo "Stashed xcuserdata in $USERDATA_BACKUP"
fi

echo
echo "=== 4. Run XcodeGen ==="
xcodegen generate

echo
echo "=== 5. Restore user state ==="
if [ -n "$USERDATA_BACKUP" ] && [ -d "$USERDATA_BACKUP/xcuserdata" ]; then
    cp -a "$USERDATA_BACKUP/xcuserdata" ShadowrunGame.xcodeproj/
    rm -rf "$USERDATA_BACKUP"
    echo "Restored xcuserdata"
fi

echo
echo "=== 6. Nuke DerivedData so Xcode does a clean index ==="
rm -rfv ~/Library/Developer/Xcode/DerivedData/ShadowrunGame-* 2>/dev/null || true

echo
echo "=== 7. Verify the new project looks healthy ==="
if [ -f "ShadowrunGame.xcodeproj/project.pbxproj" ]; then
    NFILES=$(grep -c "in Sources" ShadowrunGame.xcodeproj/project.pbxproj || echo 0)
    echo "Swift sources in new pbxproj: $NFILES (expect ~19)"
    echo "Swift version: $(grep SWIFT_VERSION ShadowrunGame.xcodeproj/project.pbxproj | head -1 | tr -d ' ;')"
    echo "iOS deployment: $(grep IPHONEOS_DEPLOYMENT_TARGET ShadowrunGame.xcodeproj/project.pbxproj | head -1 | tr -d ' ;')"
fi

echo
echo "=== DONE ==="
echo "Open Xcode:"
echo "  open $PROJECT_DIR/ShadowrunGame.xcodeproj"
echo "Then Product → Build (⌘B). Should compile clean now."
echo
echo "If you want to delete the old .xcodeproj backup after confirming it works:"
echo "  rm -rf $PROJECT_DIR/$BACKUP"

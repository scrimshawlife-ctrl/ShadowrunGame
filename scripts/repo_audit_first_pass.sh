#!/usr/bin/env bash
set -euo pipefail

printf '== Repo Audit Snapshot ==\n'
pwd
printf '\n== Git ==\n'
git status --short || true
git branch --show-current || true
git remote -v || true

printf '\n== Tooling ==\n'
swift --version || true
xcodebuild -version || true

printf '\n== Structure (maxdepth 3 files) ==\n'
find . -maxdepth 3 -type f | sort

printf '\n== Project files ==\n'
find . -maxdepth 4 \( -name "*.xcodeproj" -o -name "*.xcworkspace" -o -name "Package.swift" \) -print | sort

printf '\n== Swift files ==\n'
find . -name "*.swift" ! -path "./.git/*" ! -path "./.build/*" | sort

printf '\n== Swift risk scan (TODO/FIXME/fatalError/etc.) ==\n'
rg -n "TODO|FIXME|fatalError\\(|assertionFailure\\(|placeholder|stub|mock" --glob "*.swift" . | head -100 || true

printf '\n== Swift architecture symbol scan ==\n'
rg -n "class |struct |enum |protocol |@main|SpriteKit|SwiftUI|ObservableObject|GameState" --glob "*.swift" . | head -220 || true

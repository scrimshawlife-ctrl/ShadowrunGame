# Smoke Test Plan — Boot to Combat

Date: 2026-04-20  
Scope: Minimal manual smoke test because no UI test target exists in `ShadowrunGame.xcodeproj`.

## Preconditions
- macOS with Xcode installed.
- Open `ShadowrunGame.xcodeproj`.
- Select scheme `ShadowrunGame`.
- Select an iPhone simulator (iOS 17+).

## Steps
1. Launch app.
2. Verify title screen appears.
3. Tap the primary start button to enter mission select.
4. Pick any mission and confirm transition to briefing.
5. Tap briefing action to begin mission.
6. Verify combat scene appears with hex battlefield and combat overlay.
7. Tap the diagnostics toggle button (ECG icon) in combat UI.
8. Verify compact diagnostics panel appears (phase, round, actor, fps).
9. Tap diagnostics toggle again and verify panel hides.

## Expected Result
- Navigation path reaches combat without crash.
- Combat UI is interactive.
- Diagnostics panel is toggleable and non-blocking.

## Notes
- If simulator/device performance tools are unavailable, diagnostics may report `fps: n/a` until frame sampling stabilizes.

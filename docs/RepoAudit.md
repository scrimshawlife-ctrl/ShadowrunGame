# Repo Audit v1

Date: 2026-04-21

## Executive Summary

- overall health: **mixed**
- main risk: **repo hygiene + authority drift** (duplicate nested workspace plus a very large `GameState` with broad responsibilities)
- safest next move: **stabilization pass** (workspace cleanup planning + real macOS/Xcode validation before new mechanics)

Build validation in this container is **NOT_COMPUTABLE** (`xcodebuild: command not found`).

## Structure Snapshot

Top-level implementation appears to be rooted at repo root:
- `ShadowrunGameApp.swift`
- `Game/`, `Rendering/`, `UI/`, `Entities/`, `Missions/`
- `docs/` + `docs/assets/`
- `ShadowrunGame.xcodeproj`

Observed notable structure risks:
- Nested duplicate workspace folder exists: `ShadowrunGame/` (contains mirrored source, scripts, screenshots, and its own `.git` + `.venv`).
- Large runtime artifact footprint in root (`build/`, `screenshots/`, backup `.xcodeproj` folders).
- No `Tests/` or `UITests/` directories were observed at max depth 3.

## Authority Audit

### GameState status

`GameState` is still the practical runtime authority for combat and mission flow.
Evidence observed:
- owns turn state (`currentTurnIndex`, `roundNumber`, input lock fields)
- owns trace/escalation/role/preset/type/mission objective state
- owns mission setup/reset and enemy phase orchestration
- owns win/loss and combat log mutation

### TurnManager status

`TurnManager` appears **shadow/stale** (compiled source, but not actively driving runtime flow from visible call sites).
- No operational references were found outside comments/docs and the file itself.
- `BattleScene` has a comment mentioning TurnManager, but direct runtime reads/writes use `GameState.shared`.

### UI/render separation status

Separation is **mixed**:
- `CombatUI` is primarily presentational/dispatch.
- `BattleScene` is primarily render/input but still writes back into `GameState` turn/input/selection state and room-transition state.
- This is functional but increases cross-surface mutation coupling.

## Code Health Risks

### Likely compile risks (cannot compile here)

- `GameState.swift` is large (~2,116 lines) and includes multiple domains; this increases accidental coupling risk.
- Repo includes backup project files and duplicate workspace trees that may confuse contributors/tooling.
- `README.md` has minor formatting artifact (extra separator spacing), low severity.

### Likely maintenance risks

- God-object pressure in `GameState` (turn flow + AI orchestration + mission objectives + trace + role/preset/type + logging + movement helpers).
- Shared writes between `BattleScene` and `GameState` for turn/input recovery states.
- Stale model risk: `TurnManager` concept remains present while non-driving.

### Likely drift risks

- Docs are strong but can drift quickly because behavior changes are frequent and runtime cannot be CI-validated in this environment.
- Mission/trace docs likely stay accurate short-term, but status claims depend on macOS simulator runs not currently enforced.

## Documentation Audit

Docs currently present:
- `README.md`
- `docs/TraceSystem.md`
- `docs/TurnAuthorityReport.md`
- `docs/SmokeTestPlan.md`
- `docs/DuplicateWorkspaceAudit.md`
- `docs/MissionMatrix.md`
- `docs/PlaytestChecklist.md`

Alignment status: **partial-to-strong**
- Core trace/authority/mission matrix docs are present and coherent.
- `docs/assets/runtime-architecture.svg` and `docs/assets/turn-flow.svg` exist but are not currently linked from `README.md`/`docs/README.md` (unreferenced artifacts).

## Testability Audit

Current ability to test:
- Manual playtesting support is good (UI toggles, diagnostics panel, checklist docs).
- Automated test coverage is absent from visible repo structure (no XCTest/UI test target files found in tree scan).

Missing validation path:
- No build/test execution possible in this Linux container for iOS toolchain.
- `xcodebuild` unavailable here (`NOT_COMPUTABLE`).

Recommended next validation step on macOS:
1. Run `xcodebuild -project ShadowrunGame.xcodeproj -scheme ShadowrunGame -destination 'platform=iOS Simulator,name=iPhone 16' build`.
2. Execute `docs/SmokeTestPlan.md` and `docs/PlaytestChecklist.md` in simulator.
3. Capture one pass/fail artifact log per objective mode (`Survive`, `Eliminate`).

## Recommended Next Moves

1. **Cleanup (safest first)**
   - Plan/execute dedicated housekeeping patch for nested `ShadowrunGame/` duplicate and backup project clutter (with backup safety).
2. **Validation**
   - Run real macOS/Xcode build + smoke checklist; baseline compile/runtime truth before additional features.
3. **Gameplay**
   - Only after validation, continue pacing tuning (mission type + preset matrix) using documented checklist.

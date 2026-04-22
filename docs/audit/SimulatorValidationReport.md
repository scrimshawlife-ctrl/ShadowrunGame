# Simulator Validation Report

## Environment
- Validation timestamp (UTC): 2026-04-22.
- `xcodebuild` availability: **missing** (`command not found`).
- `xcrun`/Simulator tooling availability: **missing** (`command not found`), so device enumeration is unavailable in this environment.
- Repository root contents were listed successfully.

## Project Discovery
- Project artifacts discovered:
  - `ShadowrunGame.xcodeproj`
  - `ShadowrunGame.xcodeproj/project.xcworkspace`
- Backup workspace artifacts also exist under:
  - `ShadowrunGame.xcodeproj.backup-20260420-111140/project.xcworkspace`
  - `ShadowrunGame.xcodeproj.backup-20260420-104412/project.xcworkspace`
  - `ShadowrunGame.xcodeproj.backup-20260420-104343/project.xcworkspace`
- No `Package.swift` was discovered within `-maxdepth 3`.

## Scheme Discovery
- Attempted:
  - `xcodebuild -list -project ShadowrunGame.xcodeproj`
  - `xcodebuild -list -workspace ShadowrunGame.xcodeproj/project.xcworkspace`
- Result: **NOT_COMPUTABLE** because `xcodebuild` is not installed in this container.

## Simulator Build Result
- Build was **not executable** in this environment.
- Blocking condition: `xcodebuild` missing, so no scheme resolution and no simulator build invocation can be performed.
- Result: **NOT_COMPUTABLE**.

## Simulator Launch Result
- Launch workflow was **not executable** in this environment.
- Blocking conditions:
  1. Build artifact cannot be produced without `xcodebuild`.
  2. `xcrun simctl` is unavailable (`xcrun` missing), so simulator boot/install/launch operations cannot run.
- Result: **NOT_COMPUTABLE**.

## Contract Guard Results
All requested architecture guard scripts were executed and passed:
- `swift scripts/check_outcome_pipeline_contract.swift`
- `swift scripts/check_pathing_helpers_contract.swift`
- `swift scripts/check_mission_setup_service_contract.swift`
- `swift scripts/check_extraction_controller_contract.swift`
- `swift scripts/check_combat_flow_controller_contract.swift`
- `swift scripts/check_game_session_state_contract.swift`
- `swift scripts/check_phase_flow_authority_contract.swift`

## Parse Check Results
Both requested parse checks succeeded:
- `swiftc -parse scripts/simulate_mission_sequence.swift`
- `swiftc -parse scripts/audit_map_situations.swift`

## Blockers
1. Missing Apple toolchain binaries required for simulator validation:
   - `xcodebuild` (required for listing schemes and performing iOS simulator build).
   - `xcrun` / `simctl` (required for simulator device discovery, boot, install, and launch).
2. Because these binaries are unavailable, simulator build/run validation cannot be computed inside this environment.

## Final Verdict
**NOT_COMPUTABLE**

Reason: iOS simulator validation depends on Apple/Xcode tooling not present in this execution environment; architecture/script guard validation remains green.

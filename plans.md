# plans.md

## Active Mission
Stabilize authority seams and eliminate workspace ambiguity so collaborators can ship deterministic gameplay changes safely.

## Current State Snapshot (2026-04-23)
- `GameState` remains gameplay authority for turn/missions/outcomes.
- Rendering/UI are functional projections, but `BattleScene` still contains broad direct writes into authority state.
- Duplicate nested workspace (`./ShadowrunGame/`) is still present and is the highest operational hygiene risk.
- Container validation remains constrained: no `swift` or `xcodebuild` toolchains.

## Priority Queue

### P0 — Repository Source-of-Truth Hygiene
- Choose and document one canonical workspace path.
- Remove/archive or hard-exclude duplicate nested repo from day-to-day collaboration flow.
- Prevent accidental cross-repo edits and commits.

### P1 — Authority Seam Tightening
- Reduce direct `GameState.shared` field mutation in rendering code.
- Introduce intent-level façade calls for scene-triggered state transitions.
- Preserve deterministic turn and mission state progression.

### P2 — Validation Baseline
- Run macOS simulator build and smoke plan (`NOT_COMPUTABLE` in current container).
- Record pass/fail artifact for Survive and Eliminate mission types.

### P3 — Playability + Feedback Expansion
- Continue pressure/trace clarity tuning only after P0–P2 are stabilized.
- Keep new mechanics additive via existing shared systems, not forks.

## Decision Log
- Preserve `GameState` as singular gameplay authority.
- Treat repository path ambiguity as a production risk, not just cleanup debt.
- Favor small, reviewable seam-tightening changes over broad rewrites.

## Handoff Checklist (for next collaborator)
1. Read `README.md`, `AGENTS.md`, and `docs/RepoAudit.md`.
2. Confirm you are editing the canonical workspace only.
3. Ship one focused P0 or P1 change.
4. Update this file and include:
   - what was completed
   - what moved in priority
   - what is blocked (`NOT_COMPUTABLE` where applicable)

## Known Constraints
- Container cannot execute Swift/iOS toolchain commands (`swift`, `xcodebuild`).
- Full compile/runtime validation must be run on macOS with Xcode.

## Next Suggested Move
Create a focused hygiene PR that formally marks the canonical workspace and prevents accidental edits inside the nested duplicate tree.

## Recommended Next Steps (Review: 2026-04-24)

### Changed
- Consolidated immediate execution guidance into a sequenced plan that starts with repository hygiene, then authority-seam refactors, then macOS validation.

### Pending
- Canonical workspace decision is still not codified in-repo (`CONTRIBUTING` or guardrails like `.gitignore`/CI checks).
- `BattleScene` still performs direct authority writes that should move behind intent-level `GameState` APIs.
- Mission smoke validation for both mission types remains unrecorded on macOS.

### Blocked
- iOS build/simulator verification is **NOT_COMPUTABLE** in this container because `xcodebuild` is unavailable.

### Next (Explicit Execution Sequence)
1. **Run 1 — P0 Hygiene PR (first):**
   - Define canonical workspace path in docs (`README.md` + `plans.md` or `CONTRIBUTING.md` if added).
   - Add guardrails preventing accidental nested-tree edits (for example: `.gitignore`, repo note, or CI/path lint if available).
   - Record the exact files changed and the reason each file was touched.
2. **Run 2 — P1 Authority PR (second):**
   - Pick one high-frequency `BattleScene` mutation path into `GameState.shared`.
   - Replace it with one intent-level `GameState` façade API call.
   - Document before/after authority ownership in a short audit note under `docs/`.
3. **Run 3 — P2 Validation artifact (third):**
   - On macOS, run:
     - `xcodebuild -project ShadowrunGame.xcodeproj -scheme ShadowrunGame -destination 'platform=iOS Simulator,name=iPhone 16' build`
   - Execute Survive + Eliminate smoke checks from `docs/SmokeTestPlan.md`.
   - Save dated evidence to `docs/audit/SimulatorValidationReport.md`.
4. **Run 4 — Handoff closeout:**
   - Update this `plans.md` section with completed/pending/blocked/next.
   - Call out remaining risks and the single highest-leverage follow-up action.

### After First Run (Mandatory Explicit Report)
After Run 1, post a complete status block using this exact shape so collaborators can see the full state without inference:

- **Run Scope:** (what was attempted)
- **Files Changed:** (explicit path list)
- **Commands Executed:** (explicit command list, in order)
- **Artifacts Produced:** (docs/reports/commits)
- **Pass/Fail by Check:** (each check with outcome)
- **Blocked:** (`NOT_COMPUTABLE` items with reason)
- **Next Run Entry Conditions:** (what must be true before Run 2 starts)

## Notion Sync (2026-04-24)

Use this as the canonical payload when updating the Notion project tracker so repo state and planning state stay aligned.

### Notion Fields
- **Title:** Shadowrune — Execution Ladder (P0→P2)
- **Date:** 2026-04-24
- **Status:** In Progress
- **Current Run:** Run 1 (P0 Hygiene)
- **Priority:** P0
- **Blocked:** `NOT_COMPUTABLE` for iOS build/simulator in container (requires macOS + Xcode)
- **Source of Truth:** `plans.md`

### Notion Update Body (Copy/Paste)
- **Changed:** Sequenced runbook now explicit (Run 1–Run 4) with required outputs per run.
- **Pending:** Canonical workspace guardrails, one authority seam refactor path, and macOS validation artifact.
- **Blocked:** `xcodebuild` unavailable in container; simulator build must run on macOS.
- **Next:** Execute Run 1 and publish mandatory explicit report (scope/files/commands/artifacts/pass-fail/blocked/entry conditions).

### Sync Rule
- Every time `plans.md` changes priority, run number, or blocked state, update Notion in the same work session before handoff.

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

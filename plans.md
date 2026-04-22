# plans.md

## Active Mission
Stabilize the prototype's pressure loop while preparing the codebase for faster collaborator turnover.

## Current State Snapshot (2026-04-22)
- Core turn authority is centered in `GameState`.
- Trace/escalation loop is implemented with role modifiers.
- Documentation exists for architecture and smoke testing.
- Build/test validation remains limited in container environments (no Xcode).

## Priority Queue

### P0 — Authority Integrity
- Audit any logic currently leaking into SpriteKit scene or view layers.
- Keep turn transitions deterministic and traceable.
- Add lightweight diagnostics for phase transitions if missing.

### P1 — Playability + Feedback
- Expand mission preset coverage (Survive/Eliminate variants).
- Improve in-combat signal clarity around trace thresholds and escalation.
- Tune default pressure preset for consistent onboarding.

### P2 — Role Expansion
- Add at least one role with a unique pressure tradeoff.
- Ensure role rules are modifiers over shared systems, not forks.

### P3 — UX + Surface Layer
- Add role selection UI before mission start.
- Improve run-start context and mission objective visibility.

## Decision Log
- `GameState` remains runtime authority; no gameplay truth in rendering layers.
- Pressure mechanics must remain deterministic and explainable.
- Complexity is only accepted when it lowers ambiguity or increases strategic texture.

## Handoff Checklist (for next collaborator)
1. Read `README.md` handoff section.
2. Read `AGENTS.md` and follow branch/commit conventions.
3. Choose one P0/P1 task and ship in a focused PR.
4. Update this file with:
   - what was completed
   - what moved in priority
   - what is blocked

## Known Constraints
- Container cannot execute iOS simulator builds.
- Real build validation must be done on macOS with Xcode.

## Next Suggested Move
Implement a compact phase/trace debug overlay toggle (dev-only) sourced entirely from `GameState` to improve tuning speed without violating authority boundaries.

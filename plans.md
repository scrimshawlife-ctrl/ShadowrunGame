# plans.md

## Active Mission
Stabilize authority seams and eliminate workspace ambiguity so collaborators can ship deterministic gameplay changes safely.

## Handoff (2026-04-23 evening — open to Danny)

**Branch:** `fix/combat-first-turn` — PR open against `main` on `scrimshawlife-ctrl/ShadowrunGame`.

**Playtest status (iPhone 17 Pro simulator, iOS 26.4) after `d041228` + camera-inset patch:**
- P1 — Hex grid renders, but **character and enemy sprites are not visibly identifiable on their tiles**. Only partial colored glyphs read as runners. Root cause not fully isolated; likely interaction between the new board backplate / scanline layer, `SpriteManager.createCharacter`'s presence-badge hierarchy, and container `zPosition = 40`.
- P1 — **Camera framing still wrong**. The HEAD commit restores HUD-inset compensation in `applyCameraScale` / `positionCameraOnMap` / `focusCamera(on:y:)`, but Aaron's 20:33 MDT playtest still shows the grid mispositioned relative to the strip between the top objective banner and bottom combat panel. More tuning needed — likely interaction with `scaleMode = .aspectFit`, `fitSceneToView()` writing `self.size = view.bounds.size` after `presentScene`, and `updateViewportInsets` only triggering on change > 0.5pt.
- P2 — Mission briefing overflow and HUD density were addressed in `d041228` and need a fresh pass once the combat board renders correctly.

**What shipped in this branch:**
- `d041228` (Forge): unblock first turn, replace debug marker overlays with SpriteManager characters, opaque briefing backdrop, tighter CombatUI.
- HEAD: re-add HUD-aware scale + `verticalBias` so the camera lands in the middle of the unobscured strip.

**Blocked on:**
- Xcode + physical playtest loop — sim screenshots alone aren't enough to iterate on board/sprite z-order. CLI tap automation isn't wired in this env, so handoff assumes Danny drives the sim manually.

**Next suggested moves:**
1. Drop a debug overlay that prints `scene.size`, `mapOrigin`, `cam.position`, `scale`, `topHUDInset`, `bottomHUDInset`, and the first character's final scene position — so the framing math can be diffed against a known-good baseline.
2. Audit `SpriteManager.createCharacter`'s spritesheet lookup (`playerIdleTextures[archKey]`). Confirm whether the procedural fallback path is firing and whether fallback sprites actually sit above the tile layer + backplate.
3. If framing keeps regressing on tall phones, consider reverting to the v17-style oversized "guaranteed visible" character container (`makeCharacterVisual`) as a short-term unblock and iterating from there.

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

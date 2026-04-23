# Repo Audit v2 — Full Read

Date: 2026-04-23 (UTC)

## Executive Summary

- overall health: **mixed, structurally coherent but operationally fragile**
- primary risk: **repository drift + boundary leakage pressure**
- immediate safest move: **contain workspace duplication risk, then harden authority seams before feature expansion**

Validation status in this container:
- `swift` toolchain: **NOT_COMPUTABLE** (`swift: command not found`)
- `xcodebuild`: **NOT_COMPUTABLE** (`xcodebuild: command not found`)

## Scope + Method

This full read pass covered:
1. Tracked source and docs structure (`git ls-files`, targeted `rg`, `find -maxdepth` scans).
2. Authority boundary checks (`GameState` ownership vs Rendering/UI write paths).
3. Repository hygiene and collaborator-friction scan (nested repos, backups, artifacts).
4. Documentation freshness check against current code topology.

## Structure Snapshot

### Strengths
- Clear top-level domain split is present and readable: `Game/`, `Missions/`, `Rendering/`, `UI/`, `Entities/`, `docs/`.
- Architecture and handoff docs are present and mostly current for collaborator onboarding.

### Risks
- Nested duplicate workspace/repo exists at `./ShadowrunGame/` with its own `.git`, scripts, docs, and build artifacts.
- Root contains multiple backup Xcode project directories (`ShadowrunGame.xcodeproj.backup-*`) and large artifact trees (`build/`, `screenshots/`).
- Current branch is `work`, which does not match preferred branch naming convention (`feature/*`, `fix/*`, `docs/*`, `chore/*`).

## Authority Boundary Audit

### Findings
- `GameState` remains practical authority for mission outcome, turn progression, trace state, and extraction flow.
- `TurnManager.swift` still exists but appears runtime-dormant (commentary/docs references plus local file definition).
- Rendering layer (`Rendering/BattleScene.swift`) still performs many direct writes into `GameState.shared` for room transitions, turn/input toggles, selection, and door/extraction interactions.

### Interpretation
- The project intent (“`GameState` authoritative core”) is still intact, but mutation pathways are broad.
- Main pressure line is not missing authority; it is **write-surface breadth**, which increases drift probability during UI/render iterations.

## Size + Complexity Signals

Approximate file sizes from this pass:
- `Game/GameState.swift`: **1,746 lines**
- `Rendering/BattleScene.swift`: **1,841 lines**
- `UI/CombatUI.swift`: **1,754 lines**
- `Game/CombatFlowController.swift`: **592 lines**

Interpretation:
- Large-file concentration in state, rendering, and UI is the key entropy driver.
- Refactor opportunity exists around “narrow seams” (authority façade methods, fewer direct scene writes) rather than large rewrites.

## Documentation Coherence Check

- `docs/README.md` still flags legacy diagrams (`runtime-architecture.svg`, `turn-flow.svg`) as unreferenced; this remains accurate.
- Existing audits (`docs/AuthoritySanityReport.md`, `docs/TurnAuthorityReport.md`, prior `docs/RepoAudit.md`) remain directionally aligned with current code shape.
- No major doc-code contradiction was observed in this pass.

## Risk Register (Current)

1. **High** — Nested repo/workspace (`./ShadowrunGame/`) can cause accidental edits, stale commits, and handoff confusion.
2. **Medium** — Rendering writes directly into authority state through many call sites (harder to guarantee deterministic turn semantics during visual changes).
3. **Medium** — Dormant `TurnManager` model remains in tree, preserving conceptual duplication risk.
4. **Low/Medium** — Toolchain absence in this environment blocks compile-level verification; static review only.

## Recommended Next Moves

1. **Repo hygiene containment (first)**
   - Decide canonical root vs nested workspace and archive/remove one path.
   - Gate future audits to tracked files only and document a single source-of-truth workspace.
2. **Authority seam tightening (second)**
   - Introduce explicit, minimal `GameState` façade methods for scene-driven mutations.
   - Replace direct `GameState.shared.<field>` writes in `BattleScene` incrementally with intent-level calls.
3. **Runtime truth validation (third, macOS required)**
   - Run `xcodebuild -project ShadowrunGame.xcodeproj -scheme ShadowrunGame -destination 'platform=iOS Simulator,name=iPhone 16' build`.
   - Execute smoke checklist and mission matrix validation in simulator.

## Handoff Standard

- **Changed**: Completed a full repository read/audit refresh with updated risk register and prioritization.
- **Pending**: Workspace deduplication decision and authority seam tightening implementation.
- **Blocked**: iOS compile/runtime validation is blocked in this container (`swift`/`xcodebuild` unavailable).
- **Next**: Ship a focused `docs/` + hygiene PR that declares canonical workspace and excludes duplicate tree from active collaboration path.

## Commands Used

- `git status --short`
- `git branch --show-current`
- `git ls-files | head -n 200`
- `find . -maxdepth 2 -type d | sort`
- `wc -l Game/GameState.swift Game/CombatFlowController.swift Game/TurnManager.swift Rendering/BattleScene.swift UI/CombatUI.swift README.md docs/README.md plans.md docs/RepoAudit.md`
- `rg -n "GameState\.shared|missionComplete|combatWon|combatEnded|endTurn\(|requestExtraction\(" Game Rendering UI`
- `rg -n "TurnManager" Game Rendering UI README.md docs`
- `rg -n "runtime-architecture\.svg|turn-flow\.svg|shadowrune-loop\.svg|shadowrune-architecture\.svg|shadowrune-roles\.svg" README.md docs/README.md docs -g'*.md'`
- `bash scripts/repo_audit_first_pass.sh`

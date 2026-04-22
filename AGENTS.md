# AGENTS.md

## Purpose
This file defines how collaborators should operate in this repository so handoffs stay deterministic and low-friction.

## Collaboration Principles
- Preserve `GameState` as gameplay authority.
- Keep rendering and UI as projection layers over authoritative state.
- Prioritize pressure clarity over feature count.
- Prefer small, reviewable PRs over broad mixed-scope changes.

## Branch + Commit Workflow
- Branch naming: `feature/<scope>`, `fix/<scope>`, `docs/<scope>`, `chore/<scope>`.
- Commit message format:
  - `<type>(<scope>): <summary>`
  - Examples: `docs(handoff): add collaborator startup guide`, `fix(trace): clamp escalation threshold`
- Keep commits atomic. If a commit changes gameplay logic, include docs updates in the same commit only when directly coupled.

## Required Validation Before PR
Because this environment cannot run iOS builds, use this validation ladder:
1. Static review for authority boundaries (`GameState` vs rendering).
2. Confirm docs reflect behavior changes.
3. If local macOS is available, run:
   - `xcodebuild -project ShadowrunGame.xcodeproj -scheme ShadowrunGame -destination 'platform=iOS Simulator,name=iPhone 16' build`

If full validation is not possible, explicitly mark `NOT_COMPUTABLE` in PR notes.

## Documentation Handoff Standard
Any handoff update should include:
- **Changed**: what shipped
- **Pending**: what remains and why
- **Blocked**: external dependencies or unresolved risks
- **Next**: the highest-leverage next action

Update `plans.md` whenever priorities shift.

## Ownership Boundaries
- Gameplay loops and progression rules: `Game/`, `Missions/`, and docs under `docs/`.
- Rendering concerns: `Rendering/` and visual assets.
- UI concerns: `UI/` and view state projection.

Cross-boundary changes must call out tradeoffs in PR description.

## PR Expectations
PRs should include:
- concise problem statement
- summary of approach
- risk notes
- validation performed (or why blocked)
- explicit handoff instructions for the next collaborator

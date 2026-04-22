# Repo Cleanup Plan v1

Date: 2026-04-21

## High Risk Items

- Duplicate nested repo/workspace at `./ShadowrunGame/` (contains its own `.git`, `.venv`, scripts, build, screenshots, and mirrored source).
- Root backup project folders (`./ShadowrunGame.xcodeproj.backup-*`) that can confuse source-of-truth.
- Large generated/runtime artifact directories (`./build`, `./screenshots`) checked into working tree context.
- Legacy but valid docs assets (`docs/assets/runtime-architecture.svg`, `docs/assets/turn-flow.svg`) currently unreferenced from active docs index/README.

## Keep / Review / Remove Later

| Path | Category | Recommendation | Reason |
|---|---|---|---|
| `ShadowrunGame/` | Duplicate workspace/repo | REVIEW | Large mirrored tree (~323MB) with tooling/runtime artifacts; must confirm no unique files before deletion. |
| `ShadowrunGame/.git` | Nested VCS metadata | REMOVE LATER | Nested git history is high confusion risk; remove only in dedicated cleanup patch after archive/confirmation. |
| `ShadowrunGame/.venv` | Local tooling env | REMOVE LATER | Environment-specific and reproducible; not source of truth. |
| `ShadowrunGame/build` | Generated artifacts | REMOVE LATER | Build outputs are machine-local and high-churn. |
| `ShadowrunGame/screenshots` | Runtime captures | REVIEW | Likely non-authoritative; preserve only explicitly referenced artifacts if any. |
| `ShadowrunGame.xcodeproj.backup-20260420-104343` | Project backup | REVIEW | Keep until macOS validation confirms current project is stable; then archive/remove. |
| `ShadowrunGame.xcodeproj.backup-20260420-104412` | Project backup | REVIEW | Same as above. |
| `ShadowrunGame.xcodeproj.backup-20260420-111140` | Project backup | REVIEW | Same as above. |
| `build/` | Root generated artifacts | REMOVE LATER | High volume generated files (~137MB); not authoritative source. |
| `screenshots/` | Root runtime captures | REVIEW | Useful for debugging evidence; keep only curated subset if needed. |
| `docs/assets/runtime-architecture.svg` | Legacy docs asset | KEEP | Valid artifact; currently unreferenced but potentially useful historical diagram. |
| `docs/assets/turn-flow.svg` | Legacy docs asset | KEEP | Valid artifact; currently unreferenced but potentially useful historical diagram. |
| `docs/*` (audit/checklist/matrix reports) | Documentation | KEEP | Active clarity/testability docs and current repo guidance. |

## Duplicate Workspace Scope Comparison (filtered)

Comparison excluded nested `.git`, `.venv`, `build`, `screenshots`, and backup-userdata folders.

- Filtered shared files: **231**
- Filtered nested-only source/project files: **0**
- Filtered root-only files: **14** (all README/docs and docs assets)

Interpretation:
- No unique nested source files were detected in filtered code/project scope.
- Root appears to be the only location with current docs (`README.md`, `docs/*`).

## Safe Cleanup Order

1. Backup/confirm unique files
   - Snapshot nested tree and capture a manifest before any deletion.
   - Re-run filtered diff/hash check in macOS workspace.
2. Remove nested tooling junk
   - Target nested `.venv`, nested `build/`, nested screenshots/runtime logs first (after manifest).
3. Normalize project tree
   - Remove nested duplicate workspace and stale backup project folders in one dedicated housekeeping patch.
4. Re-run build validation
   - Validate on macOS/Xcode from root project and run smoke/playtest checklists.

## Blockers

- Needs macOS/Xcode validation before destructive cleanup.
- Do not delete nested workspace/backups until unique-file confirmation is repeated on the target dev machine.
- Build validation remains NOT_COMPUTABLE in this Linux/container environment.

# Legacy Merge Audit v1

Date: 2026-04-21

## Executive Summary

- legacy value level: **low-to-medium**
- safest merge candidates: **none required for runtime code** (root is already newer on key Swift files)
- major junk sources: nested `.git`, nested `.venv`, nested `build/`, and large screenshot/runtime capture sets

High-confidence result from filtered comparison:
- No nested-only source/project files were found after excluding `.git`, `.venv`, `build`, and `screenshots`.
- The key runtime files that differ (`Game/GameState.swift`, `ShadowrunGameApp.swift`, `UI/CombatUI.swift`) are newer in root and contain the current feature set.

## Unique Legacy Items

| Path | Type | Classification | Recommendation | Reason |
|---|---|---|---|---|
| `ShadowrunGame/.git/**` | nested VCS metadata | DELETE_LATER | Remove in cleanup patch after archive snapshot | Causes source-of-truth ambiguity; not app content. |
| `ShadowrunGame/.venv/**` | local Python environment | DELETE_LATER | Remove in cleanup patch | Machine-local tooling cache, reproducible. |
| `ShadowrunGame/build/**` | generated build artifacts | DELETE_LATER | Remove in cleanup patch | Non-authoritative generated output. |
| `ShadowrunGame/screenshots/**` | captures/debug outputs | ARCHIVE_REFERENCE | Keep only curated evidence subset, archive rest | Potentially useful for regression evidence; too large/noisy for active tree. |
| `ShadowrunGame/screenshot-*.png` and `enemy_preview.png` | ad-hoc image artifacts | ARCHIVE_REFERENCE | Archive outside runtime tree | Debug history, not runtime source. |
| `ShadowrunGame/ShadowrunGame.xcodeproj.backup-*` | backup project snapshots | ARCHIVE_REFERENCE | Keep until macOS validation complete, then archive/remove | Safety copies may still be useful during cleanup transition. |

## Swift Source Diff Risks

| File | Legacy differs? | Merge? | Reason |
|---|---|---|---|
| `Game/GameState.swift` | Yes | No | Root is ahead (trace/presets/mission type/objective diagnostics additions); legacy is older. |
| `ShadowrunGameApp.swift` | Yes | No | Root is ahead (diagnostics panel/FPS wiring additions). |
| `UI/CombatUI.swift` | Yes | No | Root is ahead (status/toggle/action wiring for current test knobs). |
| all other mirrored Swift files | No meaningful diff detected in filtered scope | No | Already mirrored between trees. |

## Scripts / Docs / Assets Worth Preserving

| Path | Recommendation | Reason |
|---|---|---|
| `capture_build_errors.sh`, `cleanup_stale.sh`, `diagnose_xcode_vs_cli.sh`, `fix_and_verify.sh`, `nuke_sourcekit_index.sh`, `regenerate_xcodeproj.sh`, `project.yml` (nested copies) | IGNORE (do not merge) | Hashes match root copies; no unique value in legacy duplicates. |
| nested `Sprites/**` and mirrored source/assets | IGNORE | Already present in root; no filtered nested-only files detected. |
| nested screenshot/history artifacts | ARCHIVE_REFERENCE | Useful for retrospective debugging only. |

## Merge Candidates (Shortlist)

1. **None for runtime source at this time** (MERGE_NOW set is empty).
2. Optional archival-only capture: a curated subset of nested screenshots/logs if a historical bug trail must be retained.

## Cleanup Blockers

- Must preserve a manifest/archive of nested tree before destructive cleanup.
- Run macOS/Xcode validation from root before removing backup project snapshots.
- Keep root as canonical; do not merge legacy Swift variants over current root.

## Recommended Next Move

- **Archive patch**, then **cleanup patch**:
  1. Archive-only pass: export manifest + curated historical artifacts from nested tree.
  2. Cleanup pass: remove nested `.git/.venv/build` and duplicate nested workspace tree after validation.
  3. Re-run macOS build + smoke/playtest checklist from root.

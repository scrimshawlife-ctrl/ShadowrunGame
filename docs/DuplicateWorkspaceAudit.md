# Duplicate Workspace Audit — nested `ShadowrunGame/`

Date: 2026-04-20

## Objective
Assess whether untracked nested folder `ShadowrunGame/` contains unique source/assets/scripts compared to repository root.

## Method
1. Confirmed nested directory exists.
2. Compared normalized file-path inventories (excluding `.git`, `build`, screenshot/runtime artifacts, and local virtualenv paths).
3. Compared content hashes (SHA-256) for files present in both root and nested trees.

## Findings
- Nested folder exists.
- Normalized path diff found **no nested-only code/assets/scripts** and no root-only content except the new root `README.md`.
- Hash comparison over 327 shared files found **0 content mismatches**.

## Interpretation
- The nested folder is currently a mirrored duplicate workspace copy, not an independently diverged source of truth (based on audited file classes).
- Uncertainty remains for ignored/non-audited runtime artifacts (e.g., screenshots, cache/build outputs, or hidden local tooling metadata).

## Recommendation
**Migrate later / keep temporarily.**
- Do not delete now during stabilization.
- After one clean macOS build+run pass from repo root, remove nested duplicate in a dedicated housekeeping patch with explicit backup/archive step.

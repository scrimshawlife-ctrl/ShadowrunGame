# Legacy Asset Audit v1
## Scope
- Scanned `ShadowrunGame/` for non-code files excluding `.git`, `.venv`, build artifacts, and `*.swift`.
- Compared each legacy asset path against the root workspace equivalent.
## Results
- Legacy non-code assets scanned: **293**.
- Missing in root (candidates): **0**.
- Archived to `docs/archive/legacy/assets/`: **0**.
- MERGE_NOW candidates: **0**.
## Preserved Assets
No archive copies were required: all scanned legacy non-code assets currently have matching root-path counterparts.
## Candidate Classification
| Classification | Count | Notes |
|---|---:|---|
| ARCHIVE_REFERENCE | 0 | Screenshots/diagrams/debug captures not in root. |
| MERGE_NOW | 0 | Runtime/config assets missing in root (none found). |
| IGNORE | 0 | Non-critical leftovers if present. |
## Runtime-Critical Confirmation
No runtime-critical non-code assets were found missing from root during this pass.
## Cleanup Guardrail
Do not delete the nested legacy workspace until a macOS/Xcode build from root is validated.

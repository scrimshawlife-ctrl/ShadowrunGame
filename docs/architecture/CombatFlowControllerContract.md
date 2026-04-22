## Ownership
- turn progression
- round initialization
- enemy phase execution
- combat-end checks
- combat action orchestration
- defend-state combat helper checks

## Non-Owned
- mission setup
- reward/finalization pipeline
- extraction validation
- pathfinding helper math
- UI rendering
- scene initialization

## Invariants
- no double enemy phase
- round initialization order unchanged
- turn advancement unchanged
- combat-end checks still call finalize path exactly once
- combat actions preserve current cost/side-effect order
- enemyPhase sequencing remains deterministic

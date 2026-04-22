# PathingAndAIHelpers Contract

## Ownership
PathingAndAIHelpers owns:
- hex grid math
- pathfinding
- LOS checks
- AI target selection helpers

## Non-Owned
PathingAndAIHelpers does NOT own:
- combat decisions
- enemy turns
- mission setup
- UI logic

## Invariants
- deterministic output
- no randomness
- no mutation of unrelated state
- path results stable given same input

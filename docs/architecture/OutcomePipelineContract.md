# OutcomePipeline Contract

## Ownership
OutcomePipeline owns:
- combat finalization sequence
- heat finalization
- corp/gang attention application
- attention decay
- reward finalization
- outcome narrative/projection helpers
- mission end summary generation

## Non-Owned
OutcomePipeline does NOT own:
- combat actions
- mission setup
- extraction validation
- map shaping
- phase transitions
- UI rendering

## Required Execution Order
1. guard combatEnded
2. haptics
3. mission log
4. finalizeMissionHeat
5. applyFactionAttention
6. applyGangAttention
7. applyAttentionDecay
8. world reaction log
9. combined pressure log
10. finalizeRewardLayer
11. mission modifier preview
12. terminal log
13. mission end summary
14. terminal flags
15. combatAction notification

## Invariants
- no double execution
- reward math unchanged
- attention math unchanged
- log ordering preserved
- notification posted only after flags are set
- GameState shims remain compatibility-only

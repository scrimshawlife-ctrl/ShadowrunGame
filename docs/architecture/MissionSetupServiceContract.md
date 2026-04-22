# MissionSetupService Contract (v0.1)

## Ownership
- Single-room mission setup orchestration.
- Multi-room mission setup orchestration.
- Mission type assignment during mission load/setup.
- Map situation assignment.
- Map shaping performed during mission setup.
- Initial extraction objective setup.
- Enemy archetype composition at mission initialization.
- World-pressure setup effects applied at mission start.
- Delayed spawn materialization.

## Non-Owned
- Combat action resolution.
- Combat finalization and reward pipeline.
- Pathfinding math and traversal algorithms.
- Phase transition mechanics.
- UI rendering.

## Invariants
- Mission initialization remains deterministic.
- Mission type to map situation mapping remains unchanged.
- Extraction objective is valid after setup completes.
- Spawn safety constraints remain intact.
- Enemy archetype composition remains deterministic.
- Initial logging and setup ordering remain unchanged.

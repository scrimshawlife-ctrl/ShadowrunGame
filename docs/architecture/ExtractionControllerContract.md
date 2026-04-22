# ExtractionController Contract (v0.1)

## Ownership
- Extraction action request validation.
- Extraction victory validation.
- Active extraction objective coordinate usage.
- Extraction mission objective enforcement.

## Non-Owned
- Mission setup and room transitions.
- Combat action resolution beyond extraction request.
- Reward and finalization pipeline.
- Map shaping.

## Invariants
- Extraction requires extraction mission type.
- Extraction uses current active extraction objective.
- Extraction rejects wrong tile, stale selection, and uncleared enemies.
- Extraction path remains deterministic.
- No changes to room-transition extraction synchronization behavior.

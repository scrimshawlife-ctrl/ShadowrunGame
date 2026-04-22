# PhaseFlowAuthority v0.2

## Extracted Transitions

Extracted from both transition engines (`PhaseManager.computeNext` and `GameStateManager.computeNext`) and active `transition(to:)` call sites.

### A) Transition rules in `PhaseManager.computeNext`

1. (`title`, `startGame`) → `missionSelect`
2. (`missionSelect`, `selectMission(id)`) → `briefing`
3. (`briefing`, `beginMission`) → `combat`
4. (`combat`, `endCombat(won)`) → `debrief`
5. (`combat`, `returnToTitle`) → `title`
6. (`debrief`, `returnToTitle`) → `title`
7. (`*`, `returnToTitle`) → `title` (safety catch-all)
8. otherwise: no-op (`state` unchanged)

### B) Transition rules in `GameStateManager.computeNext`

1. (`title`, `startGame`) → `missionSelect`
2. (`missionSelect`, `selectMission(id)`) → `briefing`
3. (`briefing`, `beginMission`) → `combat`
4. (`combat`, `endCombat(won)`) → `debrief`
5. (`debrief`, `returnToTitle`) → `title`
6. otherwise: no-op (`state` unchanged)

### C) Active transition call sites (UI)

1. Title screen button: `startGame`
2. Mission card select: `selectMission(id)`
3. Briefing accept button: `beginMission`
4. Combat end overlay button: `endCombat(won: Bool)`
5. Debrief return button: `returnToTitle`

No active call sites were found for `startCombat`, `viewDebrief`, or `exitGame`.

## Normalized Events

To unify both systems under one vocabulary, use normalized event names while preserving existing event payloads.

| Normalized Event | Existing Event(s) | Payload | Intent |
|---|---|---|---|
| `openMissionSelect` | `startGame` | none | title -> mission select |
| `selectMission` | `selectMission(String)` | missionId | mission select -> briefing |
| `beginMission` | `beginMission`, `startCombat` (alias) | none | briefing -> combat |
| `endCombat` | `endCombat(won: Bool)` | won | combat -> debrief |
| `returnToMenu` | `returnToTitle` | none | return to title/menu |
| `openDebrief` | `viewDebrief` | optional won context | explicit debrief route (currently unused) |
| `exit` | `exitGame` | none | terminate flow (currently unused) |
| `restartMission` | none (future-normalized slot) | optional missionId | restart current mission (currently undefined) |

## Canonical Matrix

Single source-of-truth matrix that consolidates both managers and resolves current drift by explicit precedence.

| Current Phase | Event | Next Phase | Source | Notes |
|---|---|---|---|---|
| `title` | `openMissionSelect` (`startGame`) | `missionSelect` | both | Core entry gate. |
| `missionSelect` | `selectMission(id)` | `briefing` | both | Captures selected mission id. |
| `briefing` | `beginMission` (`beginMission`/`startCombat`) | `combat` | both (`startCombat` unused) | `startCombat` treated as alias for `beginMission`. |
| `combat` | `endCombat(won)` | `debrief` | both | Runtime overlay computes `won`, then dispatches. |
| `combat` | `returnToMenu` (`returnToTitle`) | `title` | PhaseManager only | Canon keeps this as explicit bail-out path. |
| `debrief` | `returnToMenu` (`returnToTitle`) | `title` | both | Standard completion return path. |
| `*` | `returnToMenu` (`returnToTitle`) | `title` | PhaseManager only | Canon adopts as safety fallback. |
| `*` | `openDebrief` (`viewDebrief`) | unchanged (no-op) | neither active | Reserved until explicit route is designed. |
| `*` | `exit` (`exitGame`) | unchanged (no-op) | neither active | Reserved. |
| `*` | `restartMission` | unchanged (no-op) | canonical placeholder | Reserved; not implemented. |
| any unmatched pair | any other event | unchanged (no-op) | both | Transition returns `false` via no state change. |

## Drift Analysis

### Drift 1: `returnToTitle` behavior mismatch
- `PhaseManager` supports direct `combat -> title` and global `* -> title` fallback.
- `GameStateManager` only supports `debrief -> title`.
- **Canonical resolution**: keep explicit `combat -> title` and global fallback as authoritative behavior because UI currently depends on direct bail-out semantics.

### Drift 2: Unused enum cases
- `startCombat`, `viewDebrief`, `exitGame` exist in `StateTransition` but are not used by active call sites and are not routed in either manager.
- **Canonical resolution**: keep as reserved/no-op entries until an explicit route is defined.

### Drift 3: Semantic naming mismatch
- `returnToTitle` is semantically a return-to-menu action.
- **Canonical resolution**: normalized vocabulary uses `returnToMenu`, mapped to existing case `returnToTitle`.

### Drift 4: Restart flow absent
- No restart event currently exists, but flow vocabulary request requires explicit handling.
- **Canonical resolution**: define `restartMission` as reserved canonical slot with current no-op behavior (documentation only).

## Final Rules

1. **Matrix supremacy**: this document is the canonical transition authority for phase flow behavior.
2. **No implicit transitions**: any transition not in the matrix is a no-op.
3. **Return safety**: `returnToMenu` maps to `returnToTitle` and is valid as global fallback.
4. **Combat result handoff**: `endCombat(won)` is the only canonical event carrying mission outcome into debrief flow.
5. **Reserved events**: `openDebrief`/`exit`/`restartMission` remain documented but inactive until implementation explicitly routes them.
6. **Parity rule**: future changes to either manager must update this matrix first to avoid drift.

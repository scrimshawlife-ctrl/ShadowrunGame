# PhaseFlowAuthority Plan v0.1

## Remaining Phase/Flow Responsibilities

Current phase/state-flow responsibility is split across three co-located loci:

1. **Runtime combat authority (`GameState`)**
   - Owns combat runtime truth (`combatEnded`, `combatWon`, turn/round state, mission/runtime flags) and emits combat completion through existing outcome flow.
   - Still contains phase machine types (`GamePhase`, `StateTransition`, `GameStateManager`) at file bottom as co-located non-runtime flow logic.

2. **UI navigation authority (`PhaseManager` in `ShadowrunGameApp.swift`)**
   - Drives top-level app phase rendering (`title`, `missionSelect`, `briefing`, `combat`, `debrief`) and screen routing.
   - Owns selected mission id and debrief result used by app views.

3. **UI-runtime bridge points (views + overlays)**
   - `CombatView` gates overlay/UI rendering by runtime combat fields (`gameState.combatEnded`, `gameState.combatWon`) while also triggering app phase transition (`manager.transition(.endCombat)`).
   - This dual-gate is intentional and behavior-critical today.

## Candidates for Extraction

### Inventory (types/enums/methods/fields/call sites)

| Item | Kind | Location | Primary Call Sites | Class |
|---|---|---|---|---|
| `GamePhase` | enum | `Game/GameState.swift` and used by app manager | `ContentView` phase switch; diagnostics panel phase label | A (extract authority type) |
| `StateTransition` | enum | `Game/GameState.swift` and used by app manager | Title/mission/briefing/combat/debrief buttons and flow events | A |
| `GameStateManager` | class | `Game/GameState.swift` | No active app wiring observed in current app flow | D (bridge/legacy) |
| `PhaseManager` | class | `ShadowrunGameApp.swift` | `ContentView`, `TitleView`, `MissionSelectView`, `BriefingView`, `CombatView`, `DebriefView` | C (UI-layer flow) |
| `PhaseManager.transition(to:)` | method | `ShadowrunGameApp.swift` | All top-level phase navigation events | C |
| `PhaseManager.computeNext(...)` | method | `ShadowrunGameApp.swift` | internal from `transition(to:)` | A (logic), currently UI-owned |
| `GameStateManager.transition(to:)` | method | `Game/GameState.swift` | internal/legacy; not current app router | D |
| `GameStateManager.computeNext(...)` | method | `Game/GameState.swift` | internal from `transition(to:)` | D |
| `gameState.combatEnded` | runtime flow field | `Game/GameState.swift` | Combat overlay gating in `CombatView`; extraction/outcome guards | B (must remain runtime) |
| `gameState.combatWon` | runtime flow field | `Game/GameState.swift` | Combat end overlay text and handoff into debrief event payload | B |
| `manager.selectedMissionId` | flow field | `ShadowrunGameApp.swift` | mission load/briefing/debrief context | C |
| `manager.combatWon` | flow field | `ShadowrunGameApp.swift` | debrief rendering decisions | C |

### Classification key
- **A**: PhaseFlowAuthority candidate
- **B**: Keep in `GameState`
- **C**: UI-layer flow only
- **D**: Bridge / compatibility
- **E**: Unclear

## UI vs Runtime Boundaries

- **UI phase boundary**: Screen-level navigation is currently owned by `PhaseManager.currentPhase` and `transition(to:)`.
- **Runtime combat boundary**: Mission outcome truth is owned by `GameState` (`combatEnded`, `combatWon`) and produced by `OutcomePipeline`.
- **Bridge seam**: `CombatView` consumes runtime truth and then dispatches UI phase event `endCombat(won:)`; this seam is the current coupling point and the safest extraction boundary.

## What Must Stay in GameState

The following should remain in runtime authority (`GameState`) in any future extraction:

1. `combatEnded` / `combatWon` runtime truth and all writes from outcome flow.
2. Combat/mission state that controllers/services mutate (`roundNumber`, team/enemy runtime state, mission flags).
3. `addLog` + `objectWillChange` authority semantics for runtime mutations.
4. Singleton runtime identity (`GameState.shared`) relied upon by scene/combat systems.

## Extraction Risks

1. **Dual-state divergence risk**
   - `PhaseManager.combatWon` (UI copy) and `GameState.combatWon` (runtime truth) can drift if transition/event ordering changes.
2. **Flow table drift risk**
   - Two transition engines exist (`GameStateManager.computeNext` and `PhaseManager.computeNext`) with slightly different rules (`.combat -> .returnToTitle` fallback exists in app manager).
3. **Timing risk at combat end**
   - `CombatView` resets runtime end flags before dispatching transition; changing authority boundaries without preserving this sequence can alter overlays/debrief entry.
4. **Compatibility risk**
   - Legacy `GameStateManager` symbols may still be referenced by tests/tools/docs; removal without migration plan may break contracts.

## Recommended Order

1. **Phase inventory lock (read-only)**
   - Treat `PhaseManager` as current source of truth for UI navigation; treat `GameState` as source of truth for combat runtime completion.
2. **Single transition table plan (no code move yet)**
   - Define one canonical transition matrix for `GamePhase`/`StateTransition` and explicitly record permitted fallbacks.
3. **Compatibility mapping plan**
   - Specify whether `GameStateManager` remains adapter-only or is retired after callers are proven absent.
4. **Extraction execution plan (future phase)**
   - Extract phase authority logic into architecture module only after call-site parity checks ensure no ordering change at combat->debrief handoff.


# GameSessionState Plan v0.1

## Remaining GameState Responsibilities

`GameState` currently combines five responsibility bands:

1. **Runtime state container** (team/enemy/session/combat/mission/trace/economy fields).
2. **Compatibility shims** delegating to extracted modules (`CombatFlowController`, `OutcomePipeline`, `MissionSetupService`, `ExtractionController`, `PathingAndAIHelpers`).
3. **Retained helper methods** still invoked by controllers (spell subroutines, enemy AI step execution, combat finalize bridge).
4. **Authority shell behavior** that should remain coupled to runtime authority (`addLog`, singleton identity, shared mutable references).
5. **Phase/state crossover types** (`GamePhase`, `StateTransition`, `GameStateManager`) embedded in the same file.

## State Candidates

### A. GameSessionState candidates (pure runtime state)

High-confidence pure storage candidates:
- Team/enemy/session containers: `playerTeam`, `enemies`, `loot`, `currentMissionTiles`, `pendingSpawns`.
- Turn/session counters and flags: `currentTurnIndex`, `roundNumber`, `enemyPhaseCount`, `isPlayerTurn`, `isPlayerInputBlocked`, `isEnemyPhaseRunning`, `currentTurnCount`, `missionLoadIndex`.
- Selection and transient UI-facing selection state: `activeCharacterId`, `selectedCharacterId`, `targetCharacterId`, `isItemMenuVisible`.
- Mission and consequence state: `currentMissionType`, `currentMapSituation`, `missionComplete`, `missionHeat`, `missionHeatTier`, `factionAttention`, `lastAppliedCorpEnemyModifier`, `lastAppliedGangAmbushRadius`, `didApplyAttentionRecoveryLastMission`, `didApplyHighTraceEscalationBonusLastMission`, `lastRewardTier`, `lastRewardMultiplier`, `missionTypeBonusMultiplier`, `baseMissionPayout`, `missionTargetTurns`.
- Extraction coordinates and room pointer: `extractionX`, `extractionY`, `currentRoomId`.
- Trace/preset/role state: `actionMode`, `playerRole`, `selectedMissionPreset`, `traceLevel`, `traceEscalationLevel`, `hasLoggedTraceTriggerForCurrentRun`.
- Combat stance flags: `isDefending`, `defendingCharacterId`.
- Log storage array: `combatLog` (storage only; writer stays authority-side).
- Turn-tracking set: `playersWhoHaveNotActed`.

### B. Feasibility grading for extraction to GameSessionState

- **HIGH**: scalar/collection fields with no behavior (most `@Published` and plain vars above).
- **MED**: fields tightly coupled to singleton identity and notification timing (`combatLog`, selection IDs, `isPlayerInputBlocked`, `isEnemyPhaseRunning`).
- **LOW**: derived/computed fields that encode policy and cross-service assumptions (`traceThreshold`, `escalationDamageBonusForCurrentTrace`, payout/risk computed values) unless moved with strict read-only semantics.

## Bridge / Shim Surface

### B. Bridge / compatibility layer

Current shim surface in `GameState` should remain explicit until call sites are migrated:
- Combat shims to `CombatFlowController`: `resetTurnTracking`, `beginRound`, `recoverStunAtRoundStart`, `performAttack`, `performLayLow`, `performSpell`, `performDefend`, `performHack`, `performIntimidate`, `performBlitz`, `moveCharacter`, `showItemMenu`, `completeAction`, `endTurn`, `checkCombatEnd`, `enemyPhase`, `isCharacterDefending`, `showMoveMenu`, `performUseItem`, `selectCharacter`, `handleTileTap`.
- Outcome/reward shims: `generateWorldReactionMessage`, `generateMissionModifierPreview`, `generateGangReactionMessage`, `generateGangMissionPreview`, `generateCombinedPressurePreview`, `rewardTierLabel`, `generateRewardPreview`, `generateRewardPayoutSummary`, `generateMissionEndSummary`.
- Mission setup shims: `processDelayedSpawns`, `assignMissionTypeForCurrentLoad`, `tileKey`, `applyMapSituation`, `archetypeForSpawnIndex`, `applyEnemyArchetype`, `makeEnemy`, `logEnemyComposition`, `applyCorpAttentionEnemyInfluence`, `applyGangAmbushBias`, `setupMission`, `updateTilesForCurrentRoom`, `setupMultiRoomMission`.
- Extraction shims: `checkExtraction`, `requestExtraction`.
- Pathing/AI helper shims: `bestRetreatTile`, `bfsPathfindDrone`, `bfsPathfind`, `findWoundedAlly`, `bfsPathfindToWounded`, `tileWalkableForHealer`, `isLineBlockedByWall`, `findNextLivingCharacter`, `hexNeighbors`, `hexAdjacent`, `hexDistance`, `tileWalkable`, `distanceToNearestPlayer`.

## Phase / State Crossover

### D. Phase/state-flow candidate

In-file crossover types currently co-located with runtime authority:
- `GamePhase` enum
- `StateTransition` enum
- `GameStateManager` class

These are not combat runtime storage and are prime candidates for separation planning as a distinct phase/state-flow concern.

## What Must Stay

### C. Keep in GameState authority shell

Items that should stay in the authority shell (even if state storage is separated):
- Singleton identity (`static let shared`).
- Authoritative mutation/log sink (`addLog`).
- Bridge methods used to preserve module contracts and legacy callers.
- Retained helper methods intentionally left for controller/service interoperability:
  - `castFireball`, `castSingleTarget`, `castHeal`, `handleEnemyKilled`, `performHackOnTarget`, `performBlitzOnTarget`, `runEnemyAI`.
- Finalize bridge preserving OutcomePipeline contract coupling:
  - `finalizeCombatFromCombatFlow` (with private `finalizeCombat` path retained).

## Recommended Extraction Order

1. **State-first split plan (HIGH candidates only)**: move pure fields into a `GameSessionState` structure/class surface while preserving property names and observation behavior.
2. **Authority shell stabilization**: keep `GameState` as mutation gateway + bridge/shim host.
3. **Phase crossover isolation plan**: separate `GamePhase` / `StateTransition` / `GameStateManager` from runtime storage concerns.
4. **MED/LOW candidate review**: only after high-confidence storage extraction is stable.

## Risks

- **Observation drift risk**: moving `@Published` fields without preserving update semantics can break UI refresh timing.
- **Authority leakage risk**: exposing mutable state directly may bypass log/notification authority paths.
- **Contract drift risk**: bridges removed prematurely can break extracted module contracts and existing callers.
- **Singleton identity risk**: any extraction that undermines shared identity semantics may desynchronize scene/runtime consumers.

## UI / Observable State Mapping

Legend:
- **A** = Safe to move (pure storage + low UI coupling)
- **B** = Move with proxy required (UI depends on it)
- **C** = Keep in GameState (core observable surface)
- **D** = Unclear

| Field | Evidence (read/write + UI + module mutation) | Class | Extraction risk |
|---|---|---:|---|
| `playerTeam` | UI/App/Scene reads in `ShadowrunGameApp.swift`, `Rendering/BattleScene.swift`; writes in `MissionSetupService`; read/write in `CombatFlowController`. | B | High |
| `enemies` | UI/App/Scene reads in `ShadowrunGameApp.swift`, `Rendering/BattleScene.swift`; writes in `MissionSetupService`; reads in `CombatFlowController`. | B | High |
| `loot` | UI reads in `UI/CombatUI.swift`; writes in `GameState.generateLoot` and `CombatFlowController.performUseItem`. | B | Med |
| `currentTurnIndex` | Used in turn progression + UI/App display; writes in `MissionSetupService` and `CombatFlowController`. | B | High |
| `roundNumber` | UI/App display and turn/event sequencing; writes in `MissionSetupService` and `CombatFlowController`. | B | High |
| `isPlayerTurn` | UI gating in `UI/CombatUI.swift`, scene flow in `Rendering/BattleScene.swift`; writes in `MissionSetupService` and `CombatFlowController`. | C | High |
| `isPlayerInputBlocked` | UI/Scene input lock surface (`Rendering/BattleScene.swift`, `UI/CombatUI.swift`); writes in `MissionSetupService` and `CombatFlowController`. | C | High |
| `actionMode` | Direct UI binding/toggle in `UI/CombatUI.swift`; writes in UI and reset in `MissionSetupService`; consumed in `CombatFlowController`. | B | High |
| `playerRole` | UI/App display (`UI/CombatUI.swift`, `ShadowrunGameApp.swift`); policy reads in `GameState`. | B | Med |
| `selectedMissionPreset` | Policy/control surface in `GameState` (trace cadence). No direct extracted-module writes observed. | D | Med |
| `traceLevel` | App/summary reads; writes in `MissionSetupService` and `GameState` trace methods. | B | Med |
| `traceEscalationLevel` | App/UI reads; writes in `MissionSetupService` and `GameState` trace methods. | B | Med |
| `combatLog` | UI log display in `UI/CombatUI.swift`; writes in `MissionSetupService` and `GameState.addLog`. | C | High |
| `currentRoomId` | Scene/runtime room transitions in `Rendering/BattleScene.swift`; write in `MissionSetupService`. | B | High |
| `activeCharacterId` | Scene/UI selection/turn targeting; writes in `MissionSetupService` and `CombatFlowController`. | C | High |
| `selectedCharacterId` | Scene/UI selection surface; writes in `MissionSetupService` and `CombatFlowController`. | C | High |
| `targetCharacterId` | Targeting flow in `Rendering/BattleScene.swift`, `GameState`, and `CombatFlowController`. | C | High |
| `combatWon` | Debrief/UI state in `ShadowrunGameApp.swift`; write in `OutcomePipeline`. | B | Med |
| `combatEnded` | Combat/debrief gate in app + extraction/outcome flow; writes in `OutcomePipeline`; reads in `CombatFlowController`/`ExtractionController`. | C | High |
| `currentMissionType` | Objective/UI text + core combat/extraction/outcome branching; writes in `MissionSetupService`; reads in `CombatFlowController`, `OutcomePipeline`, `ExtractionController`. | C | High |
| `currentMapSituation` | Mission map-shaping policy in `MissionSetupService`; label reads in `GameState`. | B | Med |
| `missionComplete` | UI objective state + outcome gate; writes in `MissionSetupService` and `OutcomePipeline`; read in `CombatFlowController`. | C | High |
| `missionHeat` | Outcome/economy pipeline surface; writes in `MissionSetupService` and `OutcomePipeline`. | B | Med |
| `missionHeatTier` | Outcome/economy pipeline surface; writes in `MissionSetupService` and `OutcomePipeline`. | B | Med |
| `factionAttention` | UI pressure display + outcome/mission setup reads; writes in `OutcomePipeline`. | C | High |
| `lastAppliedCorpEnemyModifier` | UI pressure display; writes in `MissionSetupService`; read in `OutcomePipeline` preview. | B | Med |
| `lastAppliedGangAmbushRadius` | UI pressure display; write in `MissionSetupService`; read in `OutcomePipeline` preview. | B | Med |
| `didApplyAttentionRecoveryLastMission` | UI flag; writes in `MissionSetupService` and `OutcomePipeline`. | B | Med |
| `didApplyHighTraceEscalationBonusLastMission` | UI flag; writes in `MissionSetupService` and `OutcomePipeline`. | B | Med |
| `lastRewardTier` | UI reward display + outcome formatting; writes in `MissionSetupService` and `OutcomePipeline`. | B | Med |
| `lastRewardMultiplier` | UI reward display + payout computation; writes in `MissionSetupService` and `OutcomePipeline`. | B | Med |
| `missionTypeBonusMultiplier` | Reward computation surface; writes in `MissionSetupService` and `OutcomePipeline`. | B | Med |
| `baseMissionPayout` | UI/outcome payout display; read in `OutcomePipeline`. | A | Low |
| `missionTargetTurns` | UI objective display + combat objective check in `CombatFlowController`. | B | Med |
| `currentTurnCount` | UI progress + stealth objective check; writes in `MissionSetupService` and `CombatFlowController`. | B | Med |
| `isDefending` | UI indicator and combat damage/turn semantics in `CombatFlowController`. | C | High |
| `isItemMenuVisible` | Controller-driven menu visibility flag (`CombatFlowController`). | B | Med |

Module mutation summary (evidence scope requested):
- **CombatFlowController mutates**: `activeCharacterId`, `selectedCharacterId`, `targetCharacterId`, `isPlayerTurn`, `isPlayerInputBlocked`, `isDefending`, `isItemMenuVisible`, `combatEnded` (read), `missionComplete` (read), `currentTurnCount`, `missionTargetTurns` (read), `currentMissionType` (read), plus team/enemy/loot collections.
- **MissionSetupService mutates**: mission/session initialization fields including `playerTeam`, `enemies`, turn counters, trace state, mission/reward defaults, room/selection state, and pressure modifiers.
- **OutcomePipeline mutates**: end-of-mission observable outcome state (`missionComplete`, `combatWon`, `combatEnded`, heat/attention/reward flags and multipliers).
- **ExtractionController mutates/reads**: extraction gate fields via `combatEnded` guard and `playerTeam` positional authority write.

## Proxy Extraction Contract (v0.5+)

Proxy-managed fields:
- `lastAppliedCorpEnemyModifier`
- `lastAppliedGangAmbushRadius`
- `didApplyAttentionRecoveryLastMission`
- `didApplyHighTraceEscalationBonusLastMission`
- `lastRewardTier`
- `lastRewardMultiplier`
- `missionTypeBonusMultiplier`
- `combatWon`
- `currentMapSituation`
- `missionHeat`
- `missionHeatTier`
- `missionTargetTurns`
- `currentTurnCount`
- `isItemMenuVisible`

Contract rules:
1. **Storage location rule**: backing storage for proxy-managed fields must live in `GameSessionState`.
2. **GameState surface rule**: `GameState` exposes these fields only as computed proxy properties.
3. **Observation rule**: each proxy setter must call `objectWillChange.send()` before forwarding the write.
4. **No duplication rule**: no direct `@Published` (or alternate stored var) duplication of proxy-managed fields in `GameState`.

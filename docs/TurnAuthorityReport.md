# Turn Authority Report

Date: 2026-04-20  
Patch Drop: 1 (Turn Authority Map)

## Scope
Map current turn ownership and mutation flow without changing gameplay behavior.

## Current observed turn authority owner
**Observed owner: `GameState` (runtime authority).**

Reasoning:
- `GameState` owns and mutates turn-critical fields (`currentTurnIndex`, `roundNumber`, `isPlayerTurn`, `isPlayerInputBlocked`, `activeCharacterId`) and executes `endTurn()` / `enemyPhase()`.
- UI actions (`attack/defend/blitz/hack/intimidate/end turn`) call `GameState` methods directly.
- `BattleScene` reacts to notifications and reads/writes `GameState.shared` for turn sync and input lock transitions.

## Candidate authority surfaces

### 1) Active authority surface
- `Game/GameState.swift`
  - Turn counters, active actor tracking, per-round acted set, enemy-phase orchestration.
  - Combat log append path and phase notifications.

### 2) Secondary/coordinator surface
- `Rendering/BattleScene.swift`
  - Consumes `GameState` notifications and synchronizes visual/input state.
  - Also sets some turn-related flags (`isPlayerInputBlocked`, `isPlayerTurn`, active/selected ids) in response to phase events/timeouts.

### 3) Dormant/duplicate authority surface
- `Game/TurnManager.swift`
  - Contains independent initiative/round/actor progression model.
  - Present in sources but no active runtime call sites found from app/combat flow.
  - Represents a duplicate authority model that is currently non-driving.

## Mutation map (write paths)

### Authoritative writes in `GameState`
- Setup/reset:
  - `setupMission` / `setupMultiRoomMission` initialize turn index, round, active/selected actor and begin round.
- Action completion:
  - `completeAction(for:)` funnels actions to `endTurn()` for one-action resolution paths.
- Turn progression:
  - `endTurn()` marks acted actor, advances to next eligible player OR enters enemy phase and increments round.
- Enemy phase:
  - `enemyPhase()` sets running state, posts enemy phase notifications, resolves AI, then calls `beginRound()` and posts completion.

### Cross-surface writes in `BattleScene`
- On `.enemyPhaseCompleted` and safety timeout in `update(_:)`, scene writes back into `GameState` turn flags/active actor ids to recover control if needed.

## Read-only projection surfaces

- `UI/CombatUI.swift`
  - Reads `gameState.roundNumber`, `isPlayerTurn`, `isPlayerInputBlocked`, selected/active actor, combat log.
- `ShadowrunGameApp.swift` (`CombatView` diagnostics)
  - Reads phase from `PhaseManager`, reads turn state summary from `GameState` (diagnostic only).
- `Rendering/BattleScene.swift`
  - Reads turn/input state to gate touches and visual transitions.

## Sprite/render sync dependencies

Turn/render synchronization is notification-driven:
- `.turnChanged` -> selection ring, camera focus, active idle animation.
- `.enemyPhaseBegan` / `.enemyPhaseCompleted` -> UI lock/unlock and player phase resumption.
- `.roundStarted` -> round visual effect.

## Combat log dependencies

`GameState.addLog` is the canonical mutation path for combat log entries. Action resolution, phase transitions, room transitions, and extraction/combat-end checks all append through this path.

## Ambiguous or duplicated authority paths

1. **GameState vs TurnManager model duplication**
   - `TurnManager` has a full turn model but is not observed as runtime driver.

2. **GameState + BattleScene shared writes**
   - `BattleScene` writes turn flags/active actor during completion/safety paths.
   - This is operationally useful for freeze recovery, but it means turn-state mutation is not single-file pure.

3. **Phase naming split**
   - App-level phase state (`PhaseManager.currentPhase`) and combat turn phase (`GameState` flags) are separate and intentionally layered, but can be confused during debugging.

## Recommended future consolidation path (no behavior changes in this patch)

1. Keep `GameState` as runtime turn authority.
2. Formally mark `TurnManager` as dormant/legacy or convert it to a read-only analytics adapter.
3. Constrain `BattleScene` turn writes behind explicit recovery-only helper methods with clear comments.
4. Maintain diagnostics summary string from `GameState` as a single read projection for overlays.

## Validation

Build command requested:
```bash
xcodebuild -project ShadowrunGame.xcodeproj -scheme ShadowrunGame -destination 'platform=iOS Simulator,name=iPhone 16' build
```

Result: **NOT_COMPUTABLE** in this environment because `xcodebuild` is unavailable (`command not found`).

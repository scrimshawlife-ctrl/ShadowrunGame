# Trace System (Patch Drop 2: Street + Signal + Trace)

Date: 2026-04-20

## Definitions

- **Street**: safe action mode. Resolves actions without increasing trace.
- **Signal**: risky shortcut mode. Each hooked action resolution adds +1 trace.
- **Trace**: exposure meter tracked in `GameState` as `traceLevel` with threshold `traceThreshold`.

## Current implementation

- Authority owner remains `GameState`.
- New state:
  - `actionMode: ActionMode` (`street` or `signal`)
  - `traceLevel: Int`
  - `traceThreshold: Int` (currently `4`)
  - `isTraceTriggered` computed (`traceLevel >= traceThreshold`)
- New helpers:
  - `applyStreetAction()` (no trace mutation)
  - `applySignalAction()` (`traceLevel += 1` + one-time trigger log)

## Hook location (minimal)

The Street/Signal hook is currently applied in `performAttack()`:
- if mode is `street` -> `applyStreetAction()`
- if mode is `signal` -> `applySignalAction()`

No turn ownership or turn-resolution architecture was changed.

## Visible consequence behavior

When trace reaches threshold:
- deterministic one-time combat log entry:
  - `TRACE TRIGGERED — hostile network awareness increased.`
- deterministic escalation activation log:
  - `TRACE ESCALATION — enemies adapting`

This consequence is currently informational and intentionally lightweight.

## Trace Escalation v1

- New state: `traceEscalationLevel` (starts at `0`).
- Trigger rule: once `traceLevel >= traceThreshold`, escalation moves from `0 -> 1` exactly once per mission.
- Gameplay effect at escalation `>= 1`:
  - **Player units take +1 incoming damage** from enemy attack/spell resolution paths.
- Hook location:
  - enemy-side damage calculations in `runEnemyAI(...)` call `escalatedIncomingDamage(...)` before applying damage to player characters.
- Determinism:
  - no randomness in escalation activation.
  - escalation resets on mission setup.

## UI visibility

- Combat overlay shows: `TRACE: X/threshold`
- Existing diagnostics panel now also shows trace level and triggered status.
- Added compact action mode toggle button (`STREET`/`SIGNAL`) in combat overlay.

## Trace Recovery v1

- Added `applyTraceRecovery()`:
  - if `traceLevel > 0`, reduce by 1.
  - clamped at 0 (cannot go negative).
- Recovery does **not** reset escalation and does **not** undo escalation once triggered.
- Recovery hook:
  - `performLayLow()` action path (player-activated).
  - calls `applyTraceRecovery()` then ends the actor turn via `completeAction(...)`.
- Action cost:
  - **consumes the full turn**.
- Visibility:
  - combat log emits `TRACE REDUCED — laying low` when trace is reduced.

## Trace Cadence v1

Centralized tuning constants:
- `traceThreshold = 4`
- `traceGainPerSignal = 1`
- `traceRecoveryPerLayLow = 1`
- `escalationDamageBonus = 1`

Intended pacing behavior:
- Players can usually use Signal about 2–3 times before escalation pressure becomes urgent.
- Escalation should feel avoidable with timely Lay Low actions, but never free because recovery costs tempo (full turn).
- Tension should appear around turns ~3–5 in normal combat flow.

Future tuning knobs (numbers only):
- Threshold up/down for faster/slower pressure.
- Recovery/gain parity for aggressive vs conservative runs.
- Escalation damage bonus for severity without adding mechanics.

## Trace Telemetry v1

Log semantics (trace-focused):
- Signal use logs: `TRACE +1 (Signal)`
- Lay Low recovery logs: `TRACE -1 (Lay Low)` (or `TRACE -0 (Lay Low)` at floor)
- Near-threshold warning logs at `traceLevel == traceThreshold - 1`:
  - `TRACE WARNING — near escalation`

Meaning of warning state:
- Warning indicates the next Signal will trigger escalation if no recovery occurs first.
- Intended player interpretation: pause aggression, consider Lay Low tempo tradeoff.

Telemetry snapshot string:
- `traceTelemetrySummary()` returns:
  - `traceLevel/threshold`
  - escalation active flag
  - current action mode

## Mission Presets v1

- Runtime-selectable presets:
  - `MissionPreset.lowPressure`
  - `MissionPreset.standard`
  - `MissionPreset.highPressure`
- Preset effect (v1): **trace threshold only**.
  - `lowPressure` → threshold `5`
  - `standard` → threshold `4`
  - `highPressure` → threshold `3`
- No mechanic changes: Signal gain/recovery cadence and escalation behavior are unchanged.


## Mission Presets + Types Interaction

- Presets control escalation timing
- Mission type controls win condition
- Systems remain identical across combinations

## Role Modifier v1

- Added `PlayerRole` with:
  - `normal`
  - `hacker`
- Current role state defaults to `normal`.
- Hacker modifier (one effect only):
  - keeps normal Signal gain.
  - improves Lay Low recovery by +1 trace.
- No other role abilities are implemented in this pass.

## Role Modifier v2

- Added `street` to `PlayerRole`.
- Street modifier (one effect only):
  - reduces incoming **escalated** damage by 1 in `escalatedIncomingDamage(...)`.
- Escalation trigger, threshold, and trace loop are unchanged.

## Extension ideas (not implemented in this patch)

1. Threshold tiering (soft, hard, critical trace states).
2. Trace decay/recovery windows.
3. Enemy behavior modifiers when trace is triggered.
4. Mission-specific trace thresholds.
5. Different trace gain by action type.

## Validation

Requested command:
`xcodebuild -project ShadowrunGame.xcodeproj -scheme ShadowrunGame -destination 'platform=iOS Simulator,name=iPhone 16' build`

Result in this environment: **NOT_COMPUTABLE** (`xcodebuild: command not found`).

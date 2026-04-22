# Mission Pressure Simulation

Deterministic multi-mission sequence simulation using `ConsequenceEngine` mappings (or deterministic mirror fallback when the game module is unavailable to `swift` script execution).

## Scenario A: Clean Player

| Mission | Trace Tier | Heat | Corp Attention | Gang Attention | Corp Mod | Gang Radius | Combined |
|---|---|---|---:|---:|---:|---:|---|
| 1 | LOW | LOW (0) | 0 | 0 | +0 | 999 | No combined pressure detected. |
| 2 | LOW | LOW (0) | 0 | 0 | +0 | 999 | No combined pressure detected. |
| 3 | LOW | LOW (0) | 0 | 0 | +0 | 999 | No combined pressure detected. |
| 4 | LOW | LOW (0) | 0 | 0 | +0 | 999 | No combined pressure detected. |
| 5 | LOW | LOW (0) | 0 | 0 | +0 | 999 | No combined pressure detected. |
| 6 | LOW | LOW (0) | 0 | 0 | +0 | 999 | No combined pressure detected. |
| 7 | LOW | LOW (0) | 0 | 0 | +0 | 999 | No combined pressure detected. |
| 8 | LOW | LOW (0) | 0 | 0 | +0 | 999 | No combined pressure detected. |

Final State:
- Corp Attention: 0
- Gang Attention: 0
- Corp Modifier: +0 enemies
- Gang Radius: 999
- High Pressure Count: 0
- First HIGH Pressure Mission: none

## Scenario B: Moderate Player

| Mission | Trace Tier | Heat | Corp Attention | Gang Attention | Corp Mod | Gang Radius | Combined |
|---|---|---|---:|---:|---:|---:|---|
| 1 | MED | MEDIUM (1) | 1 | 1 | +1 | 6 | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 2 | MED | MEDIUM (1) | 2 | 2 | +1 | 6 | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 3 | MED | MEDIUM (1) | 3 | 3 | +1 | 4 | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 4 | MED | MEDIUM (1) | 4 | 4 | +2 | 4 | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 5 | MED | MEDIUM (1) | 5 | 5 | +2 | 3 | High combined pressure: increased enemy presence and immediate proximity threats expected. |
| 6 | MED | MEDIUM (1) | 6 | 6 | +2 | 3 | High combined pressure: increased enemy presence and immediate proximity threats expected. |
| 7 | MED | MEDIUM (1) | 7 | 7 | +2 | 3 | High combined pressure: increased enemy presence and immediate proximity threats expected. |
| 8 | MED | MEDIUM (1) | 8 | 8 | +2 | 3 | High combined pressure: increased enemy presence and immediate proximity threats expected. |

Final State:
- Corp Attention: 8
- Gang Attention: 8
- Corp Modifier: +2 enemies
- Gang Radius: 3
- High Pressure Count: 5
- First HIGH Pressure Mission: 4

## Scenario C: Loud Player

| Mission | Trace Tier | Heat | Corp Attention | Gang Attention | Corp Mod | Gang Radius | Combined |
|---|---|---|---:|---:|---:|---:|---|
| 1 | HIGH | HIGH (2) | 2 | 1 | +1 | 6 | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 2 | HIGH | HIGH (2) | 4 | 2 | +2 | 6 | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 3 | HIGH | HIGH (2) | 6 | 3 | +2 | 4 | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 4 | HIGH | HIGH (2) | 8 | 4 | +2 | 4 | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 5 | HIGH | HIGH (2) | 10 | 5 | +2 | 3 | High combined pressure: increased enemy presence and immediate proximity threats expected. |
| 6 | HIGH | HIGH (2) | 12 | 6 | +2 | 3 | High combined pressure: increased enemy presence and immediate proximity threats expected. |
| 7 | HIGH | HIGH (2) | 14 | 7 | +2 | 3 | High combined pressure: increased enemy presence and immediate proximity threats expected. |
| 8 | HIGH | HIGH (2) | 16 | 8 | +2 | 3 | High combined pressure: increased enemy presence and immediate proximity threats expected. |

Final State:
- Corp Attention: 16
- Gang Attention: 8
- Corp Modifier: +2 enemies
- Gang Radius: 3
- High Pressure Count: 7
- First HIGH Pressure Mission: 2

## Scenario D: Escalating Player

| Mission | Trace Tier | Heat | Corp Attention | Gang Attention | Corp Mod | Gang Radius | Combined |
|---|---|---|---:|---:|---:|---:|---|
| 1 | LOW | LOW (0) | 0 | 0 | +0 | 999 | No combined pressure detected. |
| 2 | MED | MEDIUM (1) | 1 | 1 | +1 | 6 | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 3 | HIGH | HIGH (2) | 3 | 2 | +1 | 6 | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 4 | HIGH | HIGH (2) | 5 | 3 | +2 | 4 | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 5 | HIGH | HIGH (2) | 7 | 4 | +2 | 4 | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 6 | HIGH | HIGH (2) | 9 | 5 | +2 | 3 | High combined pressure: increased enemy presence and immediate proximity threats expected. |
| 7 | HIGH | HIGH (2) | 11 | 6 | +2 | 3 | High combined pressure: increased enemy presence and immediate proximity threats expected. |
| 8 | HIGH | HIGH (2) | 13 | 7 | +2 | 3 | High combined pressure: increased enemy presence and immediate proximity threats expected. |

Final State:
- Corp Attention: 13
- Gang Attention: 7
- Corp Modifier: +2 enemies
- Gang Radius: 3
- High Pressure Count: 5
- First HIGH Pressure Mission: 4

## Scenario E: Recovery Player

| Mission | Trace Tier | Heat | Corp Attention | Gang Attention | Corp Mod | Gang Radius | Combined |
|---|---|---|---:|---:|---:|---:|---|
| 1 | MED | MEDIUM (1) | 1 | 1 | +1 | 6 | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 2 | LOW | LOW (0) | 0 | 0 | +0 | 999 | No combined pressure detected. |
| 3 | MED | MEDIUM (1) | 1 | 1 | +1 | 6 | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 4 | LOW | LOW (0) | 0 | 0 | +0 | 999 | No combined pressure detected. |
| 5 | MED | MEDIUM (1) | 1 | 1 | +1 | 6 | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 6 | LOW | LOW (0) | 0 | 0 | +0 | 999 | No combined pressure detected. |
| 7 | MED | MEDIUM (1) | 1 | 1 | +1 | 6 | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 8 | LOW | LOW (0) | 0 | 0 | +0 | 999 | No combined pressure detected. |

Final State:
- Corp Attention: 0
- Gang Attention: 0
- Corp Modifier: +0 enemies
- Gang Radius: 999
- High Pressure Count: 0
- First HIGH Pressure Mission: none

## COMPARISON SUMMARY

| Scenario | Missions to First HIGH Pressure | Total HIGH Pressure Missions | Final Corp Attention | Final Gang Attention |
|---|---:|---:|---:|---:|
| Scenario A: Clean Player | none | 0 | 0 | 0 |
| Scenario B: Moderate Player | 4 | 5 | 8 | 8 |
| Scenario C: Loud Player | 2 | 7 | 16 | 8 |
| Scenario D: Escalating Player | 4 | 5 | 13 | 7 |
| Scenario E: Recovery Player | none | 0 | 0 | 0 |

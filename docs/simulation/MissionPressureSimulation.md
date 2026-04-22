# Mission Pressure Simulation

Deterministic multi-mission sequence simulation using `ConsequenceEngine` mappings (or deterministic mirror fallback when the game module is unavailable to `swift` script execution).

## Scenario A: Clean Player

| Mission | Mission Type | Map Situation | Trace Tier | Heat | Corp Attention | Gang Attention | Corp Mod | Gang Radius | Reward Tier | Base Payout | Risk Bonus | Reward Multiplier | Mission Type Bonus | Final Multiplier | Final Payout | Watchers | Enforcers | Interceptors | Dominant Archetype | Combined |
|---|---|---|---|---|---:|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|
| 1 | STEALTH | CORRIDOR | LOW | LOW (0) | 0 | 0 | +0 | 999 | LOW | 100 | +25 | x1.00 | +0.25 | x1.25 | 125 | 3 | 1 | 1 | WATCHER | No combined pressure detected. |
| 2 | ASSAULT | OPEN ZONE | LOW | LOW (0) | 0 | 0 | +0 | 999 | LOW | 100 | +0 | x1.00 | +0.00 | x1.00 | 100 | 1 | 3 | 1 | ENFORCER | No combined pressure detected. |
| 3 | EXTRACTION | CHOKEPOINT | LOW | LOW (0) | 0 | 0 | +0 | 999 | LOW | 100 | +0 | x1.00 | +0.00 | x1.00 | 100 | 1 | 1 | 3 | INTERCEPTOR | No combined pressure detected. |
| 4 | STEALTH | CORRIDOR | LOW | LOW (0) | 0 | 0 | +0 | 999 | LOW | 100 | +25 | x1.00 | +0.25 | x1.25 | 125 | 3 | 1 | 1 | WATCHER | No combined pressure detected. |
| 5 | ASSAULT | OPEN ZONE | LOW | LOW (0) | 0 | 0 | +0 | 999 | LOW | 100 | +0 | x1.00 | +0.00 | x1.00 | 100 | 1 | 3 | 1 | ENFORCER | No combined pressure detected. |
| 6 | EXTRACTION | CHOKEPOINT | LOW | LOW (0) | 0 | 0 | +0 | 999 | LOW | 100 | +0 | x1.00 | +0.00 | x1.00 | 100 | 1 | 1 | 3 | INTERCEPTOR | No combined pressure detected. |
| 7 | STEALTH | CORRIDOR | LOW | LOW (0) | 0 | 0 | +0 | 999 | LOW | 100 | +25 | x1.00 | +0.25 | x1.25 | 125 | 3 | 1 | 1 | WATCHER | No combined pressure detected. |
| 8 | ASSAULT | OPEN ZONE | LOW | LOW (0) | 0 | 0 | +0 | 999 | LOW | 100 | +0 | x1.00 | +0.00 | x1.00 | 100 | 1 | 3 | 1 | ENFORCER | No combined pressure detected. |

Final State:
- Corp Attention: 0
- Gang Attention: 0
- Corp Modifier: +0 enemies
- Gang Radius: 999
- High Pressure Count: 0
- First HIGH Pressure Mission: none
- Max Corp Modifier Reached: +0
- Minimum Gang Radius Reached: 999
- Recovery Events Count: 0
- Zero Pressure Missions Count: 8
- Average Reward Multiplier: x1.00
- Max Reward Multiplier: x1.00
- Total Payout: 875
- Average Payout per Mission: 109.38
- Total Risk Bonus: 75
- Average Risk Bonus per Mission: 9.38
- Total Mission Type Bonus: 0.75
- Average Mission Type Bonus: 0.09
- Map Situation Distribution: Corridor 3, Open Zone 3, Chokepoint 2
- Dominant Archetype: WATCHER
- Flags: SAFE_ROUTE

## Scenario B: Moderate Player

| Mission | Mission Type | Map Situation | Trace Tier | Heat | Corp Attention | Gang Attention | Corp Mod | Gang Radius | Reward Tier | Base Payout | Risk Bonus | Reward Multiplier | Mission Type Bonus | Final Multiplier | Final Payout | Watchers | Enforcers | Interceptors | Dominant Archetype | Combined |
|---|---|---|---|---|---:|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|
| 1 | STEALTH | CORRIDOR | MED | MEDIUM (1) | 1 | 1 | +1 | 6 | MED | 100 | +25 | x1.25 | +0.00 | x1.25 | 125 | 3 | 1 | 1 | WATCHER | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 2 | ASSAULT | OPEN ZONE | MED | MEDIUM (1) | 2 | 2 | +1 | 6 | MED | 100 | +25 | x1.25 | +0.00 | x1.25 | 125 | 1 | 3 | 1 | ENFORCER | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 3 | EXTRACTION | CHOKEPOINT | MED | MEDIUM (1) | 3 | 3 | +1 | 4 | MED | 100 | +40 | x1.25 | +0.15 | x1.40 | 140 | 1 | 1 | 3 | INTERCEPTOR | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 4 | STEALTH | CORRIDOR | MED | MEDIUM (1) | 4 | 4 | +2 | 4 | HIGH | 100 | +50 | x1.50 | +0.00 | x1.50 | 150 | 3 | 1 | 1 | WATCHER | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 5 | ASSAULT | OPEN ZONE | MED | MEDIUM (1) | 5 | 5 | +2 | 3 | HIGH | 100 | +50 | x1.50 | +0.00 | x1.50 | 150 | 1 | 3 | 1 | ENFORCER | High combined pressure: increased enemy presence and immediate proximity threats expected. |
| 6 | EXTRACTION | CHOKEPOINT | MED | MEDIUM (1) | 6 | 6 | +2 | 3 | HIGH | 100 | +65 | x1.50 | +0.15 | x1.65 | 165 | 1 | 1 | 3 | INTERCEPTOR | High combined pressure: increased enemy presence and immediate proximity threats expected. |
| 7 | STEALTH | CORRIDOR | MED | MEDIUM (1) | 7 | 7 | +2 | 3 | HIGH | 100 | +50 | x1.50 | +0.00 | x1.50 | 150 | 3 | 1 | 1 | WATCHER | High combined pressure: increased enemy presence and immediate proximity threats expected. |
| 8 | ASSAULT | OPEN ZONE | MED | MEDIUM (1) | 8 | 8 | +2 | 3 | HIGH | 100 | +50 | x1.50 | +0.00 | x1.50 | 150 | 1 | 3 | 1 | ENFORCER | High combined pressure: increased enemy presence and immediate proximity threats expected. |

Final State:
- Corp Attention: 8
- Gang Attention: 8
- Corp Modifier: +2 enemies
- Gang Radius: 3
- High Pressure Count: 5
- First HIGH Pressure Mission: 4
- Max Corp Modifier Reached: +2
- Minimum Gang Radius Reached: 3
- Recovery Events Count: 0
- Zero Pressure Missions Count: 0
- Average Reward Multiplier: x1.41
- Max Reward Multiplier: x1.50
- Total Payout: 1155
- Average Payout per Mission: 144.38
- Total Risk Bonus: 355
- Average Risk Bonus per Mission: 44.38
- Total Mission Type Bonus: 0.30
- Average Mission Type Bonus: 0.04
- Map Situation Distribution: Corridor 3, Open Zone 3, Chokepoint 2
- Dominant Archetype: WATCHER
- Flags: none

## Scenario C: Loud Player

| Mission | Mission Type | Map Situation | Trace Tier | Heat | Corp Attention | Gang Attention | Corp Mod | Gang Radius | Reward Tier | Base Payout | Risk Bonus | Reward Multiplier | Mission Type Bonus | Final Multiplier | Final Payout | Watchers | Enforcers | Interceptors | Dominant Archetype | Combined |
|---|---|---|---|---|---:|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|
| 1 | STEALTH | CORRIDOR | HIGH | HIGH (2) | 2 | 1 | +1 | 6 | HIGH | 100 | +50 | x1.50 | +0.00 | x1.50 | 150 | 3 | 1 | 1 | WATCHER | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 2 | ASSAULT | OPEN ZONE | HIGH | HIGH (2) | 4 | 2 | +2 | 6 | HIGH | 100 | +75 | x1.50 | +0.25 | x1.75 | 175 | 1 | 3 | 1 | ENFORCER | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 3 | EXTRACTION | CHOKEPOINT | HIGH | HIGH (2) | 6 | 3 | +2 | 4 | HIGH | 100 | +50 | x1.50 | +0.00 | x1.50 | 150 | 1 | 1 | 3 | INTERCEPTOR | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 4 | STEALTH | CORRIDOR | HIGH | HIGH (2) | 8 | 4 | +2 | 4 | HIGH | 100 | +50 | x1.50 | +0.00 | x1.50 | 150 | 3 | 1 | 1 | WATCHER | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 5 | ASSAULT | OPEN ZONE | HIGH | HIGH (2) | 10 | 5 | +2 | 3 | HIGH | 100 | +75 | x1.50 | +0.25 | x1.75 | 175 | 1 | 3 | 1 | ENFORCER | High combined pressure: increased enemy presence and immediate proximity threats expected. |
| 6 | EXTRACTION | CHOKEPOINT | HIGH | HIGH (2) | 12 | 6 | +2 | 3 | HIGH | 100 | +50 | x1.50 | +0.00 | x1.50 | 150 | 1 | 1 | 3 | INTERCEPTOR | High combined pressure: increased enemy presence and immediate proximity threats expected. |
| 7 | STEALTH | CORRIDOR | HIGH | HIGH (2) | 14 | 7 | +2 | 3 | HIGH | 100 | +50 | x1.50 | +0.00 | x1.50 | 150 | 3 | 1 | 1 | WATCHER | High combined pressure: increased enemy presence and immediate proximity threats expected. |
| 8 | ASSAULT | OPEN ZONE | HIGH | HIGH (2) | 16 | 8 | +2 | 3 | HIGH | 100 | +75 | x1.50 | +0.25 | x1.75 | 175 | 1 | 3 | 1 | ENFORCER | High combined pressure: increased enemy presence and immediate proximity threats expected. |

Final State:
- Corp Attention: 16
- Gang Attention: 8
- Corp Modifier: +2 enemies
- Gang Radius: 3
- High Pressure Count: 7
- First HIGH Pressure Mission: 2
- Max Corp Modifier Reached: +2
- Minimum Gang Radius Reached: 3
- Recovery Events Count: 0
- Zero Pressure Missions Count: 0
- Average Reward Multiplier: x1.50
- Max Reward Multiplier: x1.50
- Total Payout: 1275
- Average Payout per Mission: 159.38
- Total Risk Bonus: 475
- Average Risk Bonus per Mission: 59.38
- Total Mission Type Bonus: 0.75
- Average Mission Type Bonus: 0.09
- Map Situation Distribution: Corridor 3, Open Zone 3, Chokepoint 2
- Dominant Archetype: WATCHER
- Flags: SATURATION_RISK, FLATLINE_RISK

## Scenario D: Escalating Player

| Mission | Mission Type | Map Situation | Trace Tier | Heat | Corp Attention | Gang Attention | Corp Mod | Gang Radius | Reward Tier | Base Payout | Risk Bonus | Reward Multiplier | Mission Type Bonus | Final Multiplier | Final Payout | Watchers | Enforcers | Interceptors | Dominant Archetype | Combined |
|---|---|---|---|---|---:|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|
| 1 | STEALTH | CORRIDOR | LOW | LOW (0) | 0 | 0 | +0 | 999 | LOW | 100 | +25 | x1.00 | +0.25 | x1.25 | 125 | 3 | 1 | 1 | WATCHER | No combined pressure detected. |
| 2 | ASSAULT | OPEN ZONE | MED | MEDIUM (1) | 1 | 1 | +1 | 6 | MED | 100 | +25 | x1.25 | +0.00 | x1.25 | 125 | 1 | 3 | 1 | ENFORCER | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 3 | EXTRACTION | CHOKEPOINT | HIGH | HIGH (2) | 3 | 2 | +1 | 6 | HIGH | 100 | +50 | x1.50 | +0.00 | x1.50 | 150 | 1 | 1 | 3 | INTERCEPTOR | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 4 | STEALTH | CORRIDOR | HIGH | HIGH (2) | 5 | 3 | +2 | 4 | HIGH | 100 | +50 | x1.50 | +0.00 | x1.50 | 150 | 3 | 1 | 1 | WATCHER | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 5 | ASSAULT | OPEN ZONE | HIGH | HIGH (2) | 7 | 4 | +2 | 4 | HIGH | 100 | +75 | x1.50 | +0.25 | x1.75 | 175 | 1 | 3 | 1 | ENFORCER | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 6 | EXTRACTION | CHOKEPOINT | HIGH | HIGH (2) | 9 | 5 | +2 | 3 | HIGH | 100 | +50 | x1.50 | +0.00 | x1.50 | 150 | 1 | 1 | 3 | INTERCEPTOR | High combined pressure: increased enemy presence and immediate proximity threats expected. |
| 7 | STEALTH | CORRIDOR | HIGH | HIGH (2) | 11 | 6 | +2 | 3 | HIGH | 100 | +50 | x1.50 | +0.00 | x1.50 | 150 | 3 | 1 | 1 | WATCHER | High combined pressure: increased enemy presence and immediate proximity threats expected. |
| 8 | ASSAULT | OPEN ZONE | HIGH | HIGH (2) | 13 | 7 | +2 | 3 | HIGH | 100 | +75 | x1.50 | +0.25 | x1.75 | 175 | 1 | 3 | 1 | ENFORCER | High combined pressure: increased enemy presence and immediate proximity threats expected. |

Final State:
- Corp Attention: 13
- Gang Attention: 7
- Corp Modifier: +2 enemies
- Gang Radius: 3
- High Pressure Count: 5
- First HIGH Pressure Mission: 4
- Max Corp Modifier Reached: +2
- Minimum Gang Radius Reached: 3
- Recovery Events Count: 0
- Zero Pressure Missions Count: 1
- Average Reward Multiplier: x1.41
- Max Reward Multiplier: x1.50
- Total Payout: 1200
- Average Payout per Mission: 150.00
- Total Risk Bonus: 400
- Average Risk Bonus per Mission: 50.00
- Total Mission Type Bonus: 0.75
- Average Mission Type Bonus: 0.09
- Map Situation Distribution: Corridor 3, Open Zone 3, Chokepoint 2
- Dominant Archetype: WATCHER
- Flags: FLATLINE_RISK

## Scenario E: Recovery Player

| Mission | Mission Type | Map Situation | Trace Tier | Heat | Corp Attention | Gang Attention | Corp Mod | Gang Radius | Reward Tier | Base Payout | Risk Bonus | Reward Multiplier | Mission Type Bonus | Final Multiplier | Final Payout | Watchers | Enforcers | Interceptors | Dominant Archetype | Combined |
|---|---|---|---|---|---:|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|
| 1 | STEALTH | CORRIDOR | MED | MEDIUM (1) | 1 | 1 | +1 | 6 | MED | 100 | +25 | x1.25 | +0.00 | x1.25 | 125 | 3 | 1 | 1 | WATCHER | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 2 | ASSAULT | OPEN ZONE | LOW | LOW (0) | 0 | 0 | +0 | 999 | LOW | 100 | +0 | x1.00 | +0.00 | x1.00 | 100 | 1 | 3 | 1 | ENFORCER | No combined pressure detected. |
| 3 | EXTRACTION | CHOKEPOINT | MED | MEDIUM (1) | 1 | 1 | +1 | 6 | MED | 100 | +40 | x1.25 | +0.15 | x1.40 | 140 | 1 | 1 | 3 | INTERCEPTOR | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 4 | STEALTH | CORRIDOR | LOW | LOW (0) | 0 | 0 | +0 | 999 | LOW | 100 | +25 | x1.00 | +0.25 | x1.25 | 125 | 3 | 1 | 1 | WATCHER | No combined pressure detected. |
| 5 | ASSAULT | OPEN ZONE | MED | MEDIUM (1) | 1 | 1 | +1 | 6 | MED | 100 | +25 | x1.25 | +0.00 | x1.25 | 125 | 1 | 3 | 1 | ENFORCER | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 6 | EXTRACTION | CHOKEPOINT | LOW | LOW (0) | 0 | 0 | +0 | 999 | LOW | 100 | +0 | x1.00 | +0.00 | x1.00 | 100 | 1 | 1 | 3 | INTERCEPTOR | No combined pressure detected. |
| 7 | STEALTH | CORRIDOR | MED | MEDIUM (1) | 1 | 1 | +1 | 6 | MED | 100 | +25 | x1.25 | +0.00 | x1.25 | 125 | 3 | 1 | 1 | WATCHER | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 8 | ASSAULT | OPEN ZONE | LOW | LOW (0) | 0 | 0 | +0 | 999 | LOW | 100 | +0 | x1.00 | +0.00 | x1.00 | 100 | 1 | 3 | 1 | ENFORCER | No combined pressure detected. |

Final State:
- Corp Attention: 0
- Gang Attention: 0
- Corp Modifier: +0 enemies
- Gang Radius: 999
- High Pressure Count: 0
- First HIGH Pressure Mission: none
- Max Corp Modifier Reached: +1
- Minimum Gang Radius Reached: 6
- Recovery Events Count: 0
- Zero Pressure Missions Count: 4
- Average Reward Multiplier: x1.12
- Max Reward Multiplier: x1.25
- Total Payout: 940
- Average Payout per Mission: 117.50
- Total Risk Bonus: 140
- Average Risk Bonus per Mission: 17.50
- Total Mission Type Bonus: 0.40
- Average Mission Type Bonus: 0.05
- Map Situation Distribution: Corridor 3, Open Zone 3, Chokepoint 2
- Dominant Archetype: WATCHER
- Flags: SAFE_ROUTE

## Scenario F: Alternating Moderate / Loud

| Mission | Mission Type | Map Situation | Trace Tier | Heat | Corp Attention | Gang Attention | Corp Mod | Gang Radius | Reward Tier | Base Payout | Risk Bonus | Reward Multiplier | Mission Type Bonus | Final Multiplier | Final Payout | Watchers | Enforcers | Interceptors | Dominant Archetype | Combined |
|---|---|---|---|---|---:|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|
| 1 | STEALTH | CORRIDOR | MED | MEDIUM (1) | 1 | 1 | +1 | 6 | MED | 100 | +25 | x1.25 | +0.00 | x1.25 | 125 | 3 | 1 | 1 | WATCHER | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 2 | ASSAULT | OPEN ZONE | HIGH | HIGH (2) | 3 | 2 | +1 | 6 | HIGH | 100 | +75 | x1.50 | +0.25 | x1.75 | 175 | 1 | 3 | 1 | ENFORCER | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 3 | EXTRACTION | CHOKEPOINT | MED | MEDIUM (1) | 4 | 3 | +2 | 4 | HIGH | 100 | +65 | x1.50 | +0.15 | x1.65 | 165 | 1 | 1 | 3 | INTERCEPTOR | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 4 | STEALTH | CORRIDOR | HIGH | HIGH (2) | 6 | 4 | +2 | 4 | HIGH | 100 | +50 | x1.50 | +0.00 | x1.50 | 150 | 3 | 1 | 1 | WATCHER | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 5 | ASSAULT | OPEN ZONE | MED | MEDIUM (1) | 7 | 5 | +2 | 3 | HIGH | 100 | +50 | x1.50 | +0.00 | x1.50 | 150 | 1 | 3 | 1 | ENFORCER | High combined pressure: increased enemy presence and immediate proximity threats expected. |
| 6 | EXTRACTION | CHOKEPOINT | HIGH | HIGH (2) | 9 | 6 | +2 | 3 | HIGH | 100 | +50 | x1.50 | +0.00 | x1.50 | 150 | 1 | 1 | 3 | INTERCEPTOR | High combined pressure: increased enemy presence and immediate proximity threats expected. |
| 7 | STEALTH | CORRIDOR | MED | MEDIUM (1) | 10 | 7 | +2 | 3 | HIGH | 100 | +50 | x1.50 | +0.00 | x1.50 | 150 | 3 | 1 | 1 | WATCHER | High combined pressure: increased enemy presence and immediate proximity threats expected. |
| 8 | ASSAULT | OPEN ZONE | HIGH | HIGH (2) | 12 | 8 | +2 | 3 | HIGH | 100 | +75 | x1.50 | +0.25 | x1.75 | 175 | 1 | 3 | 1 | ENFORCER | High combined pressure: increased enemy presence and immediate proximity threats expected. |

Final State:
- Corp Attention: 12
- Gang Attention: 8
- Corp Modifier: +2 enemies
- Gang Radius: 3
- High Pressure Count: 6
- First HIGH Pressure Mission: 3
- Max Corp Modifier Reached: +2
- Minimum Gang Radius Reached: 3
- Recovery Events Count: 0
- Zero Pressure Missions Count: 0
- Average Reward Multiplier: x1.47
- Max Reward Multiplier: x1.50
- Total Payout: 1240
- Average Payout per Mission: 155.00
- Total Risk Bonus: 440
- Average Risk Bonus per Mission: 55.00
- Total Mission Type Bonus: 0.65
- Average Mission Type Bonus: 0.08
- Map Situation Distribution: Corridor 3, Open Zone 3, Chokepoint 2
- Dominant Archetype: WATCHER
- Flags: SATURATION_RISK, FLATLINE_RISK

## Scenario G: Loud Then Recovery

| Mission | Mission Type | Map Situation | Trace Tier | Heat | Corp Attention | Gang Attention | Corp Mod | Gang Radius | Reward Tier | Base Payout | Risk Bonus | Reward Multiplier | Mission Type Bonus | Final Multiplier | Final Payout | Watchers | Enforcers | Interceptors | Dominant Archetype | Combined |
|---|---|---|---|---|---:|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|
| 1 | STEALTH | CORRIDOR | HIGH | HIGH (2) | 2 | 1 | +1 | 6 | HIGH | 100 | +50 | x1.50 | +0.00 | x1.50 | 150 | 3 | 1 | 1 | WATCHER | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 2 | ASSAULT | OPEN ZONE | HIGH | HIGH (2) | 4 | 2 | +2 | 6 | HIGH | 100 | +75 | x1.50 | +0.25 | x1.75 | 175 | 1 | 3 | 1 | ENFORCER | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 3 | EXTRACTION | CHOKEPOINT | HIGH | HIGH (2) | 6 | 3 | +2 | 4 | HIGH | 100 | +50 | x1.50 | +0.00 | x1.50 | 150 | 1 | 1 | 3 | INTERCEPTOR | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 4 | STEALTH | CORRIDOR | LOW | LOW (0) | 5 | 2 | +2 | 6 | HIGH | 100 | +75 | x1.50 | +0.25 | x1.75 | 175 | 3 | 1 | 1 | WATCHER | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 5 | ASSAULT | OPEN ZONE | LOW | LOW (0) | 4 | 1 | +2 | 6 | HIGH | 100 | +50 | x1.50 | +0.00 | x1.50 | 150 | 1 | 3 | 1 | ENFORCER | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 6 | EXTRACTION | CHOKEPOINT | MED | MEDIUM (1) | 5 | 2 | +2 | 6 | HIGH | 100 | +65 | x1.50 | +0.15 | x1.65 | 165 | 1 | 1 | 3 | INTERCEPTOR | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 7 | STEALTH | CORRIDOR | LOW | LOW (0) | 4 | 1 | +2 | 6 | HIGH | 100 | +75 | x1.50 | +0.25 | x1.75 | 175 | 3 | 1 | 1 | WATCHER | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 8 | ASSAULT | OPEN ZONE | LOW | LOW (0) | 3 | 0 | +1 | 999 | MED | 100 | +25 | x1.25 | +0.00 | x1.25 | 125 | 1 | 3 | 1 | ENFORCER | Corporate surveillance is increasing enemy presence. |

Final State:
- Corp Attention: 3
- Gang Attention: 0
- Corp Modifier: +1 enemies
- Gang Radius: 999
- High Pressure Count: 6
- First HIGH Pressure Mission: 2
- Max Corp Modifier Reached: +2
- Minimum Gang Radius Reached: 4
- Recovery Events Count: 4
- Zero Pressure Missions Count: 0
- Average Reward Multiplier: x1.47
- Max Reward Multiplier: x1.50
- Total Payout: 1265
- Average Payout per Mission: 158.12
- Total Risk Bonus: 465
- Average Risk Bonus per Mission: 58.12
- Total Mission Type Bonus: 0.90
- Average Mission Type Bonus: 0.11
- Map Situation Distribution: Corridor 3, Open Zone 3, Chokepoint 2
- Dominant Archetype: WATCHER
- Flags: SATURATION_RISK

## Scenario H: Moderate With Clean Breaks

| Mission | Mission Type | Map Situation | Trace Tier | Heat | Corp Attention | Gang Attention | Corp Mod | Gang Radius | Reward Tier | Base Payout | Risk Bonus | Reward Multiplier | Mission Type Bonus | Final Multiplier | Final Payout | Watchers | Enforcers | Interceptors | Dominant Archetype | Combined |
|---|---|---|---|---|---:|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|
| 1 | STEALTH | CORRIDOR | MED | MEDIUM (1) | 1 | 1 | +1 | 6 | MED | 100 | +25 | x1.25 | +0.00 | x1.25 | 125 | 3 | 1 | 1 | WATCHER | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 2 | ASSAULT | OPEN ZONE | MED | MEDIUM (1) | 2 | 2 | +1 | 6 | MED | 100 | +25 | x1.25 | +0.00 | x1.25 | 125 | 1 | 3 | 1 | ENFORCER | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 3 | EXTRACTION | CHOKEPOINT | LOW | LOW (0) | 1 | 1 | +1 | 6 | LOW | 100 | +0 | x1.00 | +0.00 | x1.00 | 100 | 1 | 1 | 3 | INTERCEPTOR | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 4 | STEALTH | CORRIDOR | MED | MEDIUM (1) | 2 | 2 | +1 | 6 | MED | 100 | +25 | x1.25 | +0.00 | x1.25 | 125 | 3 | 1 | 1 | WATCHER | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 5 | ASSAULT | OPEN ZONE | MED | MEDIUM (1) | 3 | 3 | +1 | 4 | MED | 100 | +25 | x1.25 | +0.00 | x1.25 | 125 | 1 | 3 | 1 | ENFORCER | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 6 | EXTRACTION | CHOKEPOINT | LOW | LOW (0) | 2 | 2 | +1 | 6 | MED | 100 | +25 | x1.25 | +0.00 | x1.25 | 125 | 1 | 1 | 3 | INTERCEPTOR | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 7 | STEALTH | CORRIDOR | MED | MEDIUM (1) | 3 | 3 | +1 | 4 | MED | 100 | +25 | x1.25 | +0.00 | x1.25 | 125 | 3 | 1 | 1 | WATCHER | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 8 | ASSAULT | OPEN ZONE | LOW | LOW (0) | 2 | 2 | +1 | 6 | MED | 100 | +25 | x1.25 | +0.00 | x1.25 | 125 | 1 | 3 | 1 | ENFORCER | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |

Final State:
- Corp Attention: 2
- Gang Attention: 2
- Corp Modifier: +1 enemies
- Gang Radius: 6
- High Pressure Count: 0
- First HIGH Pressure Mission: none
- Max Corp Modifier Reached: +1
- Minimum Gang Radius Reached: 4
- Recovery Events Count: 3
- Zero Pressure Missions Count: 0
- Average Reward Multiplier: x1.22
- Max Reward Multiplier: x1.25
- Total Payout: 975
- Average Payout per Mission: 121.88
- Total Risk Bonus: 175
- Average Risk Bonus per Mission: 21.88
- Total Mission Type Bonus: 0.00
- Average Mission Type Bonus: 0.00
- Map Situation Distribution: Corridor 3, Open Zone 3, Chokepoint 2
- Dominant Archetype: WATCHER
- Flags: HEALTHY_RECOVERY, SAFE_ROUTE

## Scenario I: Spike Player

| Mission | Mission Type | Map Situation | Trace Tier | Heat | Corp Attention | Gang Attention | Corp Mod | Gang Radius | Reward Tier | Base Payout | Risk Bonus | Reward Multiplier | Mission Type Bonus | Final Multiplier | Final Payout | Watchers | Enforcers | Interceptors | Dominant Archetype | Combined |
|---|---|---|---|---|---:|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|
| 1 | STEALTH | CORRIDOR | LOW | LOW (0) | 0 | 0 | +0 | 999 | LOW | 100 | +25 | x1.00 | +0.25 | x1.25 | 125 | 3 | 1 | 1 | WATCHER | No combined pressure detected. |
| 2 | ASSAULT | OPEN ZONE | LOW | LOW (0) | 0 | 0 | +0 | 999 | LOW | 100 | +0 | x1.00 | +0.00 | x1.00 | 100 | 1 | 3 | 1 | ENFORCER | No combined pressure detected. |
| 3 | EXTRACTION | CHOKEPOINT | HIGH | HIGH (2) | 2 | 1 | +1 | 6 | HIGH | 100 | +50 | x1.50 | +0.00 | x1.50 | 150 | 1 | 1 | 3 | INTERCEPTOR | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 4 | STEALTH | CORRIDOR | LOW | LOW (0) | 1 | 0 | +1 | 999 | LOW | 100 | +25 | x1.00 | +0.25 | x1.25 | 125 | 3 | 1 | 1 | WATCHER | Corporate surveillance is increasing enemy presence. |
| 5 | ASSAULT | OPEN ZONE | LOW | LOW (0) | 0 | 0 | +0 | 999 | LOW | 100 | +0 | x1.00 | +0.00 | x1.00 | 100 | 1 | 3 | 1 | ENFORCER | No combined pressure detected. |
| 6 | EXTRACTION | CHOKEPOINT | HIGH | HIGH (2) | 2 | 1 | +1 | 6 | HIGH | 100 | +50 | x1.50 | +0.00 | x1.50 | 150 | 1 | 1 | 3 | INTERCEPTOR | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 7 | STEALTH | CORRIDOR | LOW | LOW (0) | 1 | 0 | +1 | 999 | LOW | 100 | +25 | x1.00 | +0.25 | x1.25 | 125 | 3 | 1 | 1 | WATCHER | Corporate surveillance is increasing enemy presence. |
| 8 | ASSAULT | OPEN ZONE | LOW | LOW (0) | 0 | 0 | +0 | 999 | LOW | 100 | +0 | x1.00 | +0.00 | x1.00 | 100 | 1 | 3 | 1 | ENFORCER | No combined pressure detected. |

Final State:
- Corp Attention: 0
- Gang Attention: 0
- Corp Modifier: +0 enemies
- Gang Radius: 999
- High Pressure Count: 0
- First HIGH Pressure Mission: none
- Max Corp Modifier Reached: +1
- Minimum Gang Radius Reached: 6
- Recovery Events Count: 2
- Zero Pressure Missions Count: 4
- Average Reward Multiplier: x1.12
- Max Reward Multiplier: x1.50
- Total Payout: 975
- Average Payout per Mission: 121.88
- Total Risk Bonus: 175
- Average Risk Bonus per Mission: 21.88
- Total Mission Type Bonus: 0.75
- Average Mission Type Bonus: 0.09
- Map Situation Distribution: Corridor 3, Open Zone 3, Chokepoint 2
- Dominant Archetype: WATCHER
- Flags: HEALTHY_RECOVERY, SAFE_ROUTE

## Scenario J: Sloppy Recovery

| Mission | Mission Type | Map Situation | Trace Tier | Heat | Corp Attention | Gang Attention | Corp Mod | Gang Radius | Reward Tier | Base Payout | Risk Bonus | Reward Multiplier | Mission Type Bonus | Final Multiplier | Final Payout | Watchers | Enforcers | Interceptors | Dominant Archetype | Combined |
|---|---|---|---|---|---:|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|
| 1 | STEALTH | CORRIDOR | HIGH | HIGH (2) | 2 | 1 | +1 | 6 | HIGH | 100 | +50 | x1.50 | +0.00 | x1.50 | 150 | 3 | 1 | 1 | WATCHER | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 2 | ASSAULT | OPEN ZONE | LOW | LOW (0) | 1 | 0 | +1 | 999 | LOW | 100 | +0 | x1.00 | +0.00 | x1.00 | 100 | 1 | 3 | 1 | ENFORCER | Corporate surveillance is increasing enemy presence. |
| 3 | EXTRACTION | CHOKEPOINT | MED | MEDIUM (1) | 2 | 1 | +1 | 6 | MED | 100 | +40 | x1.25 | +0.15 | x1.40 | 140 | 1 | 1 | 3 | INTERCEPTOR | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 4 | STEALTH | CORRIDOR | LOW | LOW (0) | 1 | 0 | +1 | 999 | LOW | 100 | +25 | x1.00 | +0.25 | x1.25 | 125 | 3 | 1 | 1 | WATCHER | Corporate surveillance is increasing enemy presence. |
| 5 | ASSAULT | OPEN ZONE | HIGH | HIGH (2) | 3 | 1 | +1 | 6 | HIGH | 100 | +75 | x1.50 | +0.25 | x1.75 | 175 | 1 | 3 | 1 | ENFORCER | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 6 | EXTRACTION | CHOKEPOINT | LOW | LOW (0) | 2 | 0 | +1 | 999 | MED | 100 | +25 | x1.25 | +0.00 | x1.25 | 125 | 1 | 1 | 3 | INTERCEPTOR | Corporate surveillance is increasing enemy presence. |
| 7 | STEALTH | CORRIDOR | MED | MEDIUM (1) | 3 | 1 | +1 | 6 | MED | 100 | +25 | x1.25 | +0.00 | x1.25 | 125 | 3 | 1 | 1 | WATCHER | Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity. |
| 8 | ASSAULT | OPEN ZONE | LOW | LOW (0) | 2 | 0 | +1 | 999 | MED | 100 | +25 | x1.25 | +0.00 | x1.25 | 125 | 1 | 3 | 1 | ENFORCER | Corporate surveillance is increasing enemy presence. |

Final State:
- Corp Attention: 2
- Gang Attention: 0
- Corp Modifier: +1 enemies
- Gang Radius: 999
- High Pressure Count: 0
- First HIGH Pressure Mission: none
- Max Corp Modifier Reached: +1
- Minimum Gang Radius Reached: 6
- Recovery Events Count: 4
- Zero Pressure Missions Count: 0
- Average Reward Multiplier: x1.25
- Max Reward Multiplier: x1.50
- Total Payout: 1065
- Average Payout per Mission: 133.12
- Total Risk Bonus: 265
- Average Risk Bonus per Mission: 33.12
- Total Mission Type Bonus: 0.65
- Average Mission Type Bonus: 0.08
- Map Situation Distribution: Corridor 3, Open Zone 3, Chokepoint 2
- Dominant Archetype: WATCHER
- Flags: HEALTHY_RECOVERY, SAFE_ROUTE

## COMPARISON SUMMARY

| Scenario | Missions to First HIGH Pressure | Total HIGH Pressure Missions | Final Corp Attention | Final Gang Attention |
|---|---:|---:|---:|---:|
| Scenario A: Clean Player | none | 0 | 0 | 0 |
| Scenario B: Moderate Player | 4 | 5 | 8 | 8 |
| Scenario C: Loud Player | 2 | 7 | 16 | 8 |
| Scenario D: Escalating Player | 4 | 5 | 13 | 7 |
| Scenario E: Recovery Player | none | 0 | 0 | 0 |
| Scenario F: Alternating Moderate / Loud | 3 | 6 | 12 | 8 |
| Scenario G: Loud Then Recovery | 2 | 6 | 3 | 0 |
| Scenario H: Moderate With Clean Breaks | none | 0 | 2 | 2 |
| Scenario I: Spike Player | none | 0 | 0 | 0 |
| Scenario J: Sloppy Recovery | none | 0 | 2 | 0 |

=== SCENARIO MATRIX SUMMARY ===

| Scenario | Pattern | First High | High Count | Final Corp | Final Gang | Max Corp Mod | Min Gang Radius | Recovery Events | Zero Pressure Missions | Avg Reward Multiplier | Max Reward Multiplier | Total Payout | Avg Payout / Mission | Total Risk Bonus | Avg Risk Bonus / Mission | Total Mission Type Bonus | Avg Mission Type Bonus | Situation Distribution | Dominant Archetype |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|
| Scenario A: Clean Player | Clean Player | none | 0 | 0 | 0 | +0 | 999 | 0 | 8 | x1.00 | x1.00 | 875 | 109.38 | 75 | 9.38 | 0.75 | 0.09 | C:3 / O:3 / K:2 | WATCHER |
| Scenario B: Moderate Player | Moderate Player | 4 | 5 | 8 | 8 | +2 | 3 | 0 | 0 | x1.41 | x1.50 | 1155 | 144.38 | 355 | 44.38 | 0.30 | 0.04 | C:3 / O:3 / K:2 | WATCHER |
| Scenario C: Loud Player | Loud Player | 2 | 7 | 16 | 8 | +2 | 3 | 0 | 0 | x1.50 | x1.50 | 1275 | 159.38 | 475 | 59.38 | 0.75 | 0.09 | C:3 / O:3 / K:2 | WATCHER |
| Scenario D: Escalating Player | Escalating Player | 4 | 5 | 13 | 7 | +2 | 3 | 0 | 1 | x1.41 | x1.50 | 1200 | 150.00 | 400 | 50.00 | 0.75 | 0.09 | C:3 / O:3 / K:2 | WATCHER |
| Scenario E: Recovery Player | Recovery Player | none | 0 | 0 | 0 | +1 | 6 | 0 | 4 | x1.12 | x1.25 | 940 | 117.50 | 140 | 17.50 | 0.40 | 0.05 | C:3 / O:3 / K:2 | WATCHER |
| Scenario F: Alternating Moderate / Loud | Alternating Moderate / Loud | 3 | 6 | 12 | 8 | +2 | 3 | 0 | 0 | x1.47 | x1.50 | 1240 | 155.00 | 440 | 55.00 | 0.65 | 0.08 | C:3 / O:3 / K:2 | WATCHER |
| Scenario G: Loud Then Recovery | Loud Then Recovery | 2 | 6 | 3 | 0 | +2 | 4 | 4 | 0 | x1.47 | x1.50 | 1265 | 158.12 | 465 | 58.12 | 0.90 | 0.11 | C:3 / O:3 / K:2 | WATCHER |
| Scenario H: Moderate With Clean Breaks | Moderate With Clean Breaks | none | 0 | 2 | 2 | +1 | 4 | 3 | 0 | x1.22 | x1.25 | 975 | 121.88 | 175 | 21.88 | 0.00 | 0.00 | C:3 / O:3 / K:2 | WATCHER |
| Scenario I: Spike Player | Spike Player | none | 0 | 0 | 0 | +1 | 6 | 2 | 4 | x1.12 | x1.50 | 975 | 121.88 | 175 | 21.88 | 0.75 | 0.09 | C:3 / O:3 / K:2 | WATCHER |
| Scenario J: Sloppy Recovery | Sloppy Recovery | none | 0 | 2 | 0 | +1 | 6 | 4 | 0 | x1.25 | x1.50 | 1065 | 133.12 | 265 | 33.12 | 0.65 | 0.08 | C:3 / O:3 / K:2 | WATCHER |

### Scenario Flags

- Scenario A: Clean Player: SAFE_ROUTE
- Scenario B: Moderate Player: none
- Scenario C: Loud Player: SATURATION_RISK, FLATLINE_RISK
- Scenario D: Escalating Player: FLATLINE_RISK
- Scenario E: Recovery Player: SAFE_ROUTE
- Scenario F: Alternating Moderate / Loud: SATURATION_RISK, FLATLINE_RISK
- Scenario G: Loud Then Recovery: SATURATION_RISK
- Scenario H: Moderate With Clean Breaks: HEALTHY_RECOVERY, SAFE_ROUTE
- Scenario I: Spike Player: HEALTHY_RECOVERY, SAFE_ROUTE
- Scenario J: Sloppy Recovery: HEALTHY_RECOVERY, SAFE_ROUTE

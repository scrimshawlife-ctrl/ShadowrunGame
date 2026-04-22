# Shadowrune

> Tactical cyberpunk-fantasy strategy prototype built in SwiftUI + SpriteKit  
> A pressure-driven combat system where every action trades power for exposure.

---

## 🚧 Status

| Category | Value |
|--------|------|
| Platform | iOS |
| Engine | SwiftUI + SpriteKit |
| State | Prototype |
| Build | Xcode required |
| Validation | NOT_COMPUTABLE (no xcodebuild in container) |

---

## 🎮 Core Loop

![Loop](docs/assets/shadowrune-loop.svg)

- Signal → gain power, increase trace  
- Trace → builds toward escalation  
- Escalation → enemies hit harder  
- Lay Low → reduce trace, lose tempo

---

## 🧠 Roles

![Roles](docs/assets/shadowrune-roles.svg)

| Role | Identity | Effect |
|------|--------|--------|
| Normal | baseline | no modifier |
| Hacker | control | +1 trace recovery on Lay Low |
| Street | resistance | -1 escalated damage |

---


---

## 🗺️ Mission Types

| Type | Objective |
|------|----------|
| Survive | Survive X turns |
| Eliminate | Eliminate all enemies |

---

## 🎚️ Pressure Presets

| Preset | Trace Threshold | Feel |
|--------|----------------|------|
| Low | 5 | Forgiving |
| Standard | 4 | Balanced |
| High | 3 | Stressful |

---

## 🔁 In-Combat Toggles (Dev/Test)

- ROLE → cycle roles
- PRESET → cycle pressure levels
- TYPE → cycle mission type

## ⚙️ Systems

### GameState (Authority)
- single source of truth
- handles turn flow, trace, escalation

### BattleScene (Rendering)
- SpriteKit combat projection
- reflects GameState, does not own logic

### Trace System
- Street / Signal modes
- threshold-based escalation
- deterministic pressure

---

## 📊 Trace Model

| State | Effect |
|------|-------|
| Signal | +trace |
| Warning | threshold - 1 |
| Escalation | +incoming damage |
| Lay Low | -trace (costs turn) |

---

## 🧱 Architecture

![Architecture](docs/assets/shadowrune-architecture.svg)

---

## 📦 Project Structure

```text
.
├── Assets.xcassets/
├── Entities/
├── Game/
├── Missions/
├── Rendering/
├── UI/
├── docs/
│   ├── assets/
│   ├── DuplicateWorkspaceAudit.md
│   ├── README.md
│   ├── SmokeTestPlan.md
│   ├── TraceSystem.md
│   └── TurnAuthorityReport.md
├── Info.plist
├── ShadowrunGameApp.swift
└── ShadowrunGame.xcodeproj/
```

---

## ▶️ Run

### Xcode
1. Open `ShadowrunGame.xcodeproj`
2. Select scheme `ShadowrunGame`
3. Run on an iOS simulator

### CLI
```bash
xcodebuild -project ShadowrunGame.xcodeproj -scheme ShadowrunGame -destination 'platform=iOS Simulator,name=iPhone 16' build
```

Note: iOS builds require macOS + Xcode.

---

## 🧪 Validation

- Container: NOT_COMPUTABLE
- Use local Xcode for real runs

---

## 📜 Patch History

| Patch Drop | Scope | Result |
|-----------|-------|--------|
| 0 | Baseline combat prototype (phase flow + SpriteKit scene) | Playable prototype scaffold |
| 1 | Turn authority mapping and diagnostics reporting | `GameState` documented as runtime authority |
| 2 | Trace loop (`Street/Signal`), Lay Low, role modifiers, escalation hooks | Deterministic pressure loop integrated |
| 3 | Docs + visual cleanup pass | README + SVG visual docs standardized |

---

## 🧭 Roadmap

- role selection UI
- mission presets
- enemy pressure behaviors
- additional roles

---

## 🧠 Design Rules

- GameState is authority
- No system expansion without gameplay pressure
- Roles modify systems, not replace them
- Complexity must reduce ambiguity

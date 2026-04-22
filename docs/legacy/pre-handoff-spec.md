# Shadowrun: One Shot — iOS Game Spec

## 1. Concept & Vision

A single-mission, turn-based tactical RPG for iPhone, built on Shadowrun's core dice mechanics. Player leads a 4-person runner team through one corporate infiltration job. Old-school pixel art aesthetic with a dark cyberpunk palette. Think FTL meets Shadowrun — tight, tense, tactical.

**Scope:** One playable mission. 4 pre-built characters. Core combat + basic gear. No Matrix, no full character creation, no permadeath across sessions.

---

## 2. Core Game Systems

### 2.1 Dice System (Shadowrun TN)
- Roll Xd6, count hits (5 or 6 = 1 hit)
- **Exploding 6s:** reroll 6s, add to count
- Net hits = hits - TNs failed (for opposed rolls)
- **Glitch:** if half or more rolled 1s → glitch (bad outcome)
- **Critical Glitch:** all dice show 1s → severe failure

### 2.2 Attributes (Priority: Core 6)
| Attribute | Abbr | Used For |
|---|---|---|
| Body | BOD | Damage resistance, soak rolls |
| Agility | AGI | Ranged/melee attack, evasion |
| Reaction | REA | Initiative, dodge |
| Strength | STR | Melee damage, carry |
| Charisma | CHA | Social rolls, spread confusion |
| Intuition | INT | Initiative, perception |
| Logic | LOG | Matrix/hacking (N/A for v1) |
| Willpower | WIL | Magic resist, composure |

### 2.3 Skills (Priority: Combat-relevant subset)
- **Firearms** (AGI): Ranged attacks
- **Blades** (AGI): Melee attacks
- **Unarmed Combat** (AGI): Brawling damage
- **Perception** (INT): Enemy detection, traps
- **Sneaking** (AGI): Stealth approach
- **Conjuring** (MAG): Summoning (if mage in party)
- **Spellcasting** (MAG): Casting spells (if mage in party)

### 2.4 Combat Loop
1. Roll initiative: REA + INT + 1d6
2. Highest goes first
3. Each turn: player selects action → rolls dice pool vs TN → resolves
4. Damage: Attacker's weapon damage vs defender's armor (soak roll)
5. Status effects: Prone, Stunned, Wounded

**Combat Actions:**
- Attack (Ranged/Melee)
- Defend (dodge, parry)
- Cast Spell (if mage)
- Use item (stim, medkit)
- Overwatch (hold action for next enemy)

### 2.5 Character Classes (v1 — 4 archetypes)
1. **Street Samurai** — high BOD/AGI, blades/firearms, cybernetic implant
2. **Mage** — high MAG/WIL, spellcasting + conjure, no armor (spellcasting penalty)
3. ** Decker** — high LOG/INT, hacking only (Matrix deferred to v2), social engineering
4. **Face** — high CHA/AGI, social encounters, ranged backup

### 2.6 Gear (v1 — limited)
- Weapons: Pistol, SMG, Blade, Assault rifle
- Armor: Light (no spell penalty), Medium (+1 soak), Heavy (+2 soak, -1 spellcasting)
- Items: Medkit (heal), Stim (temporary stat boost), Grenade

### 2.7 Magic (v1 — basic mage support)
- 3 spell types: Combat (direct damage), Illusion (confuse enemy), Manipulation (buff/debuff)
- Cast: LOG + Magic Skill vs TN (spell difficulty)
- Drain: Unsoaked damage to WIL
- Mana: Per-encounter pool, regenerates between fights

### 2.8 Enemy Types (v1)
- **Corp Security Guard:** Low BOD, pistol, light armor
- **Security Drone:** Medium BOD, no armor, SMG
- **Elite Guard:** High BOD, assault rifle, medium armor
- **Corporate Mage:** Spellcasting, light armor

---

## 3. Data Structures

### Character
```
name: string
archetype: enum (samaritan, mage, decker, face)
attributes: { bod, agi, rea, str, cha, int, log, wil }
skills: { firearms, blades, unarmed, perception, sneaking, conjuring, spellcasting }
derived: {
  initiative: rea + int + 1d6
  soak: armor + bod
  spellDefense: wil + bod
}
cyberware: [string]
spells: [string]  // mage only
currentHP: int
maxHP: int
currentMana: int  // mage only
inventory: [gearItem]
```

### Weapon
```
name: string
type: enum (pistol, smg, rifle, blade, unarmed)
damage: int
accuracy: int  // AGI + skill + weapon accuracy vs TN
armorPiercing: int
```

### Armor
```
name: string
armorValue: int
spellPenalty: int  // 0 for light, -1 medium, -2 heavy
```

### Mission
```
name: string
mapTiles: 2D array of tile types
playerStart: {x, y}
extractionPoint: {x, y}
enemies: [enemySpawn]
props: [destructible cover objects]
storyBeat: string  // intro text
```

---

## 4. UI Layout

### 4.1 Screen Flow
```
Title Screen → Mission Select → Mission Briefing → Combat Arena → Mission Debrief → Title
```

### 4.2 Main Combat Screen (iPhone portrait)
```
┌─────────────────────────┐
│  [Turn Order Queue]     │  ← top bar: next 3 actors
├─────────────────────────┤
│                         │
│    BATTLE MAP           │  ← 2D tile grid (8×10 visible)
│    (tactical view)      │
│                         │
├─────────────────────────┤
│  [Selected Unit Stats]   │  ← HP bar, status, remaining actions
├─────────────────────────┤
│  [ACTION BUTTONS]       │  ← Attack | Defend | Spell | Item | End
├─────────────────────────┤
│  [MOVE / SKILL PANEL]   │  ← Slides up on action select
└─────────────────────────┘
```

### 4.3 Color Palette
- **Background:** #0D0D0D (near black)
- **Primary accent:** #00FF88 (neon green — Shadowrun classic)
- **Secondary accent:** #FF6600 (orange — damage, alerts)
- **Panel BG:** #1A1A2E (dark blue-grey)
- **Text:** #E0E0E0 (light grey)
- **Enemy highlight:** #FF3333 (red)
- **Player highlight:** #00FF88 (green)

### 4.4 Pixel Art Aesthetic
- 16×16 or 32×32 pixel tiles
- Character sprites: ~64×64 pixels (top-down view)
- Font: monospace / pixelated bitmap style
- No gradients — flat colors, hard pixel edges

---

## 5. Technical Approach

### 5.1 Platform
- **SwiftUI + SpriteKit** — SpriteKit for game rendering, SwiftUI for menus/UI chrome
- XcodeGen for project generation
- Target: iOS 16.0+, iPhone only (not iPad priority)

### 5.2 Architecture
- **Game State Machine:** Title → MissionSelect → Combat → Debrief
- **Turn Manager:** Sequencer tracking initiative order
- **Dice Roller:** Configurable pool, handles exploding 6s and glitch detection
- **Map Renderer:** Tile-based SpriteKit scene
- **Entity System:** Characters, enemies, props as nodes in scene

### 5.3 Key Files
```
/ShadowrunGame/
  /Game/
    GameState.swift         — state machine
    DiceEngine.swift        — TN dice, exploding, glitch
    TurnManager.swift       — initiative + turn sequencing
    CombatResolver.swift    — damage calc, soak, status
  /Entities/
    Character.swift          — player unit
    Enemy.swift              — enemy unit
    Weapon.swift / Armor.swift / Item.swift
  /Missions/
    MissionLoader.swift      — JSON mission definitions
    Mission001.json          — first mission data
  /Rendering/
    BattleScene.swift        — SpriteKit scene
    TileMap.swift            — grid renderer
    SpriteManager.swift      — pixel sprite loading
  /UI/
    CombatHUD.swift          — SwiftUI overlay
    ActionPanel.swift        — action button bar
  /Audio/
    AudioManager.swift       — ambient synth tracks
  main.swift
  AppDelegate.swift
```

### 5.4 Mission Data Format (JSON)
```json
{
  "id": "run001",
  "title": "The Extraction",
  "map": {
    "width": 12,
    "height": 10,
    "tiles": [[0,0,1,1,...], ...],  // 0=floor, 1=wall, 2=cover
    "playerSpawn": {"x": 1, "y": 8},
    "extraction": {"x": 11, "y": 1}
  },
  "enemies": [
    {"type": "guard", "x": 6, "y": 5},
    {"type": "drone", "x": 10, "y": 3}
  ],
  "storyIntro": "Your team needs to extract a data package from Arasaka sublevel 3..."
}
```

---

## 6. Asset Requirements

### Sprites (pixel art — external or placeholder)
- 4 player character sprites (16-direction or 4-direction top-down)
- 3 enemy types (guard, drone, mage)
- Tile set: floor, wall, cover, door, extraction point
- Weapon sprites (small, on-character or icon-based)
- UI icons: HP, mana, armor, action buttons

### Audio
- Dungeon synth ambient loop (dark cyberpunk tone)
- Sound FX: gunshot, blade swing, spell cast, hit, footsteps

**Note on assets:** Sprites can start as colored placeholder shapes (rectangles with color coding). The game logic is the hard part. Pixel art and audio are addable later.

---

## 7. Complexity Triage

### v1 (Buildable in 1 sprint)
- [x] Core dice engine (TN, exploding 6s, glitch)
- [x] 4 pre-built characters with correct stats
- [x] Initiative system
- [x] Tile-based movement (4-directional)
- [x] Basic attack action (ranged + melee)
- [x] Armor soak rolls
- [x] Enemy AI (simple: attack nearest player)
- [x] Win/lose conditions (extraction or team wipe)
- [x] One full mission with 3-4 encounters

### v2 (Post-v1)
- [ ] Mage spell system (full casting + mana drain)
- [ ] Decker's hacking/mini-game
- [ ] Multiple missions with branching
- [ ] Full character creation
- [ ] Cyberware implant system

### v3 (Future)
- [ ] Matrix/hacking layer (whole separate UI system)
- [ ] Vehicle combat
- [ ] Full skill list
- [ ] Persistent campaign save

---

## 8. Time Estimates

Assuming SpriteKit/SwiftUI experience:

| Component | Estimate |
|---|---|
| Dice engine + state machine | 2-3 hours |
| Character/entity models | 1-2 hours |
| Initiative + turn manager | 1-2 hours |
| Combat resolver (attack, soak, damage) | 2-3 hours |
| Tile map + movement | 3-4 hours |
| Enemy AI (simple) | 2-3 hours |
| UI/HUD layer | 2-3 hours |
| One full mission (JSON + tuning) | 2-3 hours |
| Audio integration | 1-2 hours |
| Polish, bug fixes, testing | 3-4 hours |
| **Total v1** | **~18-26 hours** |

Mage spell system (v2): +6-8 hours
Decker hacking (v2): +8-10 hours

**Verdict:** Very buildable. The hard part isn't the code — it's the art and balancing. Start with the dice engine and combat resolver, everything else follows.

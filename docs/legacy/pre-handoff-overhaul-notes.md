# Shadowrun Game — Overhaul Handoff

**Purpose:** Drop-in context for a fresh Claude session (e.g., Sonnet) to continue the aggressive overhaul of the Shadowrun-themed turn-based RPG without re-discovery. Read this file top-to-bottom before touching code.

---

## 1. User goals (from Aaron, abgodbout@gmail.com)

> "make shadowrun game as good as possible. improve this dramatically. want it to be a playable, slick looking cyberpunk turn based rpg."

Priorities (all four equally important, confirmed via follow-up):
1. **Visuals & feel** — currently "looks amateur"
2. **Combat depth** — currently "shallow"
3. **Content & missions**
4. **Playability & UX**

Scope: **Aggressive overhaul**.
Reported pain point: "Doesn't run / crashes" — not yet reproduced; may be stale or mission-specific. Treat as *verify, don't assume*.

---

## 2. Source-of-truth files

| File | Role |
| --- | --- |
| `/Users/prabu/.openclaw/workspace-coding/SHADOWRUN-SPEC.md` | Design spec. FTL meets Shadowrun. 4 archetypes, TN6 dice, mission JSON format. |
| `/Users/prabu/.openclaw/workspace-socials/SHADOWRUN-LORE.md` | Lore/narrative content — Raze, Sable, Cipher, Lyra backstories, radio chatter, flavor text. |
| `/Users/prabu/.openclaw/workspace-coding/ShadowrunGame/` | The Xcode project. |

Mount path inside Cowork sandbox: `/sessions/modest-stoic-ritchie/mnt/.openclaw/`.

**No Swift compiler in the sandbox.** `which swift` fails. You cannot verify builds from here — you have to be careful with syntax and match existing patterns exactly. Aaron will build/run on his Mac.

---

## 3. Code map (what lives where)

```
ShadowrunGame/
├── ShadowrunGameApp.swift        46KB  entry point, PhaseManager FSM, ContentView, CombatView, BattleSceneView wrapper
├── project.yml                   XcodeGen spec (excludes *.md, *.yml, *.backup)
├── Assets.xcassets/
├── Info.plist
├── Game/
│   ├── GameState.swift           68KB  GOD OBJECT singleton @MainActor. setupMission, performAttack, performSpell (Firestorm only), performDefend/Hack/Intimidate/Blitz, moveCharacter, endTurn, enemyPhase, runEnemyAI, BFS pathfinding, LOS via Bresenham.
│   ├── DiceEngine.swift          5KB   clean. struct DiceEngine: roll(pool:tn:), opposedRoll, rollInitiative, soakRoll. RollResult { hits, glitch, criticalGlitch, rolls, originalPool, netHits }.
│   ├── TurnManager.swift         12KB  mostly orphan. IMPORTANT: hosts the Enemy class (misplaced — should live in Entities/). Pre-builds: corpGuard, securityDrone, eliteGuard, corpMage, medic. CombatAction enum has .overwatch(targetId:) defined but never wired.
│   ├── GameNotifications.swift   1.5KB all Notification.Name extensions: characterSelected, tileTapped, combatAction, turnChanged, enemyHit, enemyDied, playerHit, characterHit, characterLevelUp, enemyMoved, enemySpawned, characterDefend, roundStarted, roomCleared, enemyPhaseBegan, playerTurnResumed, roomTransitionStarted, roomTransitionCompleted, roomNavigationRequested, enemyPhaseCompleted.
│   └── HapticsManager.swift      2KB   shared singleton, sane methods (buttonTap, attackHit, enemyKilled, playerDamaged, playerKilled, levelUp, roundStart, victory, defeat).
├── Entities/
│   ├── Character.swift           16KB  final class. AttributeSet(bod/agi/rea/str/cha/int/log/wil), SkillSet, CharacterArchetype(.streetSam/.mage/.decker/.face), StatusEffect(.prone/.stunned/.wounded/.dead — NEEDS EXTENSION), pre-builds: Raze/Sable/Cipher/Lyra.
│   ├── Weapon.swift              2KB   struct. WeaponType(.pistol/.smg/.rifle/.blade/.unarmed). Pre-builds: katana, pistol, smg, assaultRifle, smartgunPistol, stunball.
│   └── Armor.swift               2KB   struct Armor + SEPARATE struct Item { id, name, type: ItemType (.medkit/.stim/.grenade/.other), description, uses } — this Item conflicts with GameState's nested Item but compiles (nested type shadows).
├── Rendering/
│   ├── BattleScene.swift         66KB  SKScene subclass — tile tap handling, unit sprites, move/attack animations, notification observers, multi-room transitions.
│   ├── SpriteManager.swift       71KB  shared. Character/enemy sprite generation with archetype-tinted glow, idle pulses, death dissolve.
│   ├── TileMap.swift             27KB  enum TileType: Int { floor=0, wall=1, cover=2, door=3, extraction=4 }. buildNode(), highlightTile, isWalkable. Walls magenta-neon, extraction green EXIT, cover amber half-wall with hatch, doors orange scanner.
│   └── EffectsManager.swift      20KB  RICH. shared singleton. emitSparks, emitBlood, screenShake, emitLevelUp, showCombatText, showDamageNumber ("CRIT! X" when dmg>10), showHealNumber, addScanlines (CRT), emitMuzzleFlash, emitShieldBlock hex, emitCyberGlitch, addRainEffect, pulseNode.
├── UI/
│   └── CombatUI.swift            43KB  SwiftUI. CombatTheme color palette (hex helpers). HPBar/XPBar/ManaBar, PortraitBadge, TeamRosterBar, StatusDisplay, ActionButton, ActionBar (ATK/DEF/<special>/ITM/END), CombatLogView, LootBadge, ItemPickerSheet (filters .consumable only), TurnIndicatorBanner, CornerBracket. Main CombatUI wires: onAttack, onDefend, onSpell, onBlitz, onHack, onIntimidate, onItems, onEndTurn.
├── Missions/                     Mission001.json ... Mission005.json (+ multi versions). Format: id, title, description, difficulty, width, height, playerSpawn, extractionPoint, map [[Int]], enemies [{type, x, y, delay}].
├── Sprites/
└── ShadowrunGame.xcodeproj/      generated by XcodeGen from project.yml
```

### Tile encoding (CRITICAL — burned in everywhere)

```
0 = floor
1 = wall
2 = cover    <-- exists, rendered, but NEVER consulted in combat
3 = door
4 = extraction
```

### Palette (CombatTheme in CombatUI.swift)

| Token | Hex | Use |
| --- | --- | --- |
| background | 000000 | root bg |
| panelBG | 0A0A14 | UI panels |
| darkPanel | 06060E | deeper panels |
| accent | 00FF88 | neon green (primary) |
| damage | FF6600 | damage text, orange |
| enemyColor | FF3333 | enemy red |
| gold | FFD700 | loot / level up / victory |
| neonPink | FF0080 | secondary |
| neonBlue | 00D4FF | allies / info |
| neonPurple | 8B00FF | magic / mana |
| textMuted | 888899 | secondary text |

### Archetype colors (burned in)

| Archetype | Color | Special ability |
| --- | --- | --- |
| streetSam | `#FF6633` orange | **BLITZ** — BOD+STR+blades melee, base 8 dmg, -2 AP |
| mage | `#6699FF` blue | **SPELL** — LOG+spellcasting, currently Firestorm only, costs 3 mana |
| decker | `#00DDFF` cyan | **HACK** — LOG+INT intrusion, stuns target 1 round, costs 2 "matrix" (mana) |
| face | `#FFCC00` yellow | **SCHMZ/Intimidate** — CHA+LOG/2, AoE debuff, -hits attack pool to all enemies this round |

### Dice mechanics (from DiceEngine.swift)

Shadowrun 5e-ish:
- Pool of d6s. **TN6 = hit**. **Exploding 6s** (re-roll).
- **Glitch** when ≥ half the dice show 1s (even if there are hits).
- **Critical glitch** when glitched *and* hits == 0.
- `opposedRoll` = attacker hits − defender hits. `netHits = max(0, opposed)`.

### Combat resolution (GameState.performAttack)

1. Weapon type → skill (blade/unarmed → .blades, else .firearms).
2. Attack pool = AGI + skill. Enemy defense pool = REA + AGI.
3. **LOS check**: `isLineBlockedByWall(...)` (Bresenham, wall=1 only). **Cover tiles are NOT consulted.**
4. Roll attacker; critical glitch = 2 self-damage; glitch = fizzle.
5. Roll defender; netHits = max(0, atk.hits − def.hits).
6. If netHits == 0 → miss.
7. Damage = weapon.damage + netHits.
8. Soak = BOD + armor − AP. Roll. finalDmg = max(0, dmg − soakHits).
9. XP on kill = `maxHP / 2`. Loot rolled from fixed lootTable.

Soft guarantee: `movement is a free action` (movement doesn't call `completeAction`). Only attack/defend/spell/hack/blitz/intimidate/item end the turn.

Round structure: each living player must act once → `playersWhoHaveNotActed: Set<UUID>` empties → `enemyPhase()` staggered async dispatch (0.18s between enemies, 0.5s animation buffer) → `group.notify` → `beginRound()` + `.enemyPhaseCompleted`.

---

## 4. What's been done this session

**Phase 1 — Audit & plan (completed):**
- Delegated thorough code audit to an Explore agent.
- Identified shallow combat (cover unused, 1 spell, no grenades, no overwatch, no hit preview, status effects minimal).
- Verified code isn't obviously broken — likely runs. "Crashes" claim unconfirmed.
- Confirmed dead code: `Rendering/TileMap.swift.bak`, `enemyPhase_new.txt`, `Game/CombatResolver.swift` (264 lines, parallel attack engine never called).

**Phase 2 — Cleanup (completed):**
- Granted delete permission via `mcp__cowork__allow_cowork_file_delete`.
- Deleted the three dead files. ✅

**Phase 3 — Overhaul (STARTED, NOT COMPLETE).**
Nothing else has been changed yet. **Everything below under §6 is pending.**

Task list state:
- #1 Audit current game state — completed ✅
- #2 Design overhaul plan — completed ✅
- #3 Fix runtime / make it build & play — in_progress 🟡
- #4 Visual overhaul — pending
- #5 Deepen combat mechanics — pending
- #6 Playability & UX polish — pending
- #7 Verification — build, run, playtest — pending

---

## 5. Known risks / gotchas before you edit

1. **No Swift compiler in sandbox.** Match existing syntax patterns exactly.
2. **Item type name collision.** `GameState.Item` (nested, used by loot system — has `bonus: Int`, `ItemType = .consumable/.weapon/.armor`) and `Armor.swift`'s standalone `struct Item` (has `description`, `uses`, `ItemType = .medkit/.stim/.grenade/.other`) both exist. `GameState.Item` is what the loot pipeline and UI use. Don't confuse them — if adding grenades, either extend `GameState.Item.ItemType` with `.grenade` or create a new wrapper.
3. **Enemy class lives in `Game/TurnManager.swift`** (misplaced). When you're referencing Enemy, open TurnManager.swift for its definition. Pre-builds: `Enemy.corpGuard()`, `.securityDrone()`, `.eliteGuard()`, `.corpMage()`, `.medic()`.
4. **runEnemyAI has four big branches** (`drone`, `healer`, `elite`, `default`) with massive code duplication for the generic move+shoot pattern. Good candidate for refactor, but that's a bigger change — don't do it mid-feature-add.
5. **StatusEffect `.wounded` is used as the default alive state** (`status: StatusEffect = .wounded`). It's not really a status — it's just "alive and not stunned." Adding `.burning`/`.marked`/`.confused` is fine, but make sure they don't block `isAlive` (`status != .dead && currentHP > 0`).
6. **`CombatUI` reads `activeCharacter ?? currentCharacter`** for archetype-specific UI. New UI that depends on the active char should do the same.
7. **The PhaseManager / GameStateManager FSM and GameState are both singletons.** `GameState.shared`. `@MainActor`. Don't invent parallelism — keep it main-thread.
8. **Bresenham LOS in `isLineBlockedByWall`** only rejects on `tileType == 1`. To add cover-as-LOS-attenuator, don't change this method (other code relies on wall-blocking semantics) — add a new helper `coverBetween(fromX:fromY:toX:toY:) -> Int` that counts tiles with `tileType == 2` along the Bresenham path.
9. **`performAttack` is ~105 lines inline in GameState.** When patching it, do a narrow `Edit` — don't rewrite the whole method.

---

## 6. Planned overhaul — Phase 3 (what Sonnet should do next)

Ordered by priority and dependency. Each step is sized for one or two tool calls.

### 6.1 Cover system (NEW FILE)

Create **`Game/CombatMechanics.swift`**:

- `struct CombatMechanics` (namespace).
- `static func coverBetween(tiles: [[Int]], fromX: Int, fromY: Int, toX: Int, toY: Int) -> Int` — walks Bresenham, counts tileType == 2 between start and target (exclusive of both endpoints).
- `static func coverDefenseBonus(count: Int) -> Int` — 1 cover tile → +2 dice, 2+ → +4 dice (cap).
- `struct HitPreview { let attackPool: Int; let defensePool: Int; let coverBonus: Int; let estimatedHits: Double; let weaponDamage: Int; let estimatedDamage: Double; let blocked: Bool; let reason: String? }`
- `static func computeHitPreview(attacker: Character, target: Enemy, tiles: [[Int]], isBlocked: (Int,Int,Int,Int) -> Bool) -> HitPreview` — returns live preview. Use `attackPool × (1/3)` as rough expected hits (each d6 ~33% to show 6 before explosions).

### 6.2 Patch `performAttack` in `GameState.swift`

Right after the LOS check, add:

```swift
let coverCount = CombatMechanics.coverBetween(
    tiles: currentMissionTiles,
    fromX: a.positionX, fromY: a.positionY,
    toX: targetEnemy.positionX, toY: targetEnemy.positionY
)
let coverBonus = CombatMechanics.coverDefenseBonus(count: coverCount)
```

Then change the defense pool line from:

```swift
let defensePool = targetEnemy.attributes.rea + targetEnemy.attributes.agi
```

to:

```swift
let defensePool = targetEnemy.attributes.rea + targetEnemy.attributes.agi + coverBonus
```

And include cover in the log:

```swift
addLog("\(a.name) attacks with \(weapon.name)! [\(attackPool)d6→\(attackRoll.hits) hits] vs [\(defensePool)d6→\(defenseRoll.hits) dodge\(coverBonus > 0 ? " +\(coverBonus) cover" : "")]")
```

Apply the same change to enemy-side attacks in `runEnemyAI` (all four archetype branches — use a helper to dedupe, or just patch each).

### 6.3 Hit-chance preview (PUBLISHED)

In `GameState.swift` add a computed property:

```swift
var hitPreview: CombatMechanics.HitPreview? {
    guard let attacker = activeCharacter ?? currentCharacter,
          let targetId = targetCharacterId,
          let target = enemies.first(where: { $0.id == targetId && $0.isAlive }) else { return nil }
    return CombatMechanics.computeHitPreview(
        attacker: attacker, target: target,
        tiles: currentMissionTiles,
        isBlocked: { sx, sy, tx, ty in self.isLineBlockedByWall(fromX: sx, fromY: sy, toX: tx, toY: ty) }
    )
}
```

Add to `CombatUI.swift` — below `TeamRosterBar`, add a conditional `HitPreviewCard(preview: gameState.hitPreview)` view that only shows when a target is selected. Style it like the other panels. Show:

```
TARGET: <name>
HIT   6d6 vs 4d6+2cov   ~65%
DMG   ~9  (weapon 8 + ~1 net)
LOS   ✓
```

Use the accent color for high hit chance, damage orange for low, and cover bonus in gold.

### 6.4 Spellbook (NEW FILE)

Create **`Game/Spellbook.swift`**:

```swift
import Foundation

struct Spell: Identifiable, Hashable {
    let id: String
    let name: String
    let manaCost: Int
    let targetMode: TargetMode   // .single, .aoe(radius: Int), .self_
    let baseDamage: Int
    let kind: Kind               // .damage, .heal, .stun, .buff
    let element: String          // "fire", "arcane", "shock", "life"
    let description: String
    enum TargetMode: Hashable { case single, aoe(radius: Int), self_ }
    enum Kind: Hashable { case damage, heal, stun, buff }
}

enum Spellbook {
    static let fireball   = Spell(id: "fireball", name: "Fireball", manaCost: 4, targetMode: .aoe(radius: 1), baseDamage: 5, kind: .damage, element: "fire", description: "AoE — 3x3 blast. Sets burning.")
    static let manaBolt   = Spell(id: "manaBolt", name: "Mana Bolt", manaCost: 3, targetMode: .single, baseDamage: 8, kind: .damage, element: "arcane", description: "Single-target arcane lance. Bypasses armor.")
    static let shock      = Spell(id: "shock", name: "Shock", manaCost: 3, targetMode: .single, baseDamage: 4, kind: .stun, element: "shock", description: "Stun + minor damage.")
    static let heal       = Spell(id: "heal", name: "Heal", manaCost: 4, targetMode: .self_, baseDamage: 8, kind: .heal, element: "life", description: "Restore 8 HP to self.")
    static let all: [Spell] = [.fireball, .manaBolt, .shock, .heal]
}
```

Extend `Character.spells: [String]` default for mage from `["Firestorm", "Confusion", "Increase Attribute"]` to `["fireball", "manaBolt", "shock", "heal"]` (use Spellbook ids).

In `GameState.swift`, replace the current single `performSpell()` with `performSpell(spellId: String)`. Keep the existing no-arg `performSpell()` as a default that picks `"fireball"` for backwards compat with `ShadowrunGameApp.swift`'s `onSpell: { gameState.performSpell() }` callback.

Spell resolution:
- `.single` + `.damage` → opposed vs `target.attributes.wil + armor/2`, like current performSpell. Mana bolt uses 0 armor.
- `.aoe(radius)` → apply to all enemies within `radius` manhattan of `targetCharacterId` tile.
- `.stun` → apply `.stunned` status, plus base damage.
- `.heal` + `.self_` → heal caster `baseDamage + hits`.

### 6.5 Status effects

Extend `Entities/Character.swift` `StatusEffect`:

```swift
enum StatusEffect: Codable, Equatable {
    case prone
    case stunned
    case wounded
    case dead
    case burning(roundsLeft: Int)
    case marked(roundsLeft: Int)
    case confused(roundsLeft: Int)
    // displayName ...
}
```

Add a `@Published var statusEffects: [StatusEffect] = []` alongside the existing single `status` — don't break the existing `.dead` check.

Add a `tickStatusEffects()` call inside `beginRound()`:
- Each `.burning(n)` → 3 dmg, decrement, remove at 0.
- Each `.marked(n)` → +1 die to attackers targeting this unit, decrement.
- Each `.confused(n)` → 50% chance enemy AI picks random target this round.

### 6.6 Grenade / AoE item

Add `.grenade` to `GameState.Item.ItemType`. Update `lootTable` to occasionally drop `"Frag Grenade"` with bonus == blast damage.

Add `performGrenade(tileX: Int, tileY: Int)` in GameState:
- Find `.grenade` item in inventory or loot, remove it.
- For every enemy (and player!) within manhattan distance 1 of (x,y), deal `bonus` dmg minus Soak.
- LOS not required — it's a lob. No walls blocking the ARC, but walls DO block damage (so AoE only hits tiles with no wall between the center and them).
- Emit screen shake + particles via `EffectsManager.shared.emitSparks`.

Wire a `GrenadeTargeter` mode into BattleScene: when a grenade is armed, next tile tap calls `performGrenade` instead of `handleTileTap`. Simplest version: add `@Published var grenadeArmed: Bool` to GameState; `handleTileTap` checks it first.

Update `ItemPickerSheet` filter from `.consumable` only to `{ $0.type == .consumable || $0.type == .grenade }` and branch on tap.

### 6.7 Overwatch

`CombatAction.overwatch(targetId:)` is already defined in TurnManager.swift but never wired.

Add to GameState:

```swift
@Published var overwatchers: [UUID: Int] = [:]   // characterId -> attack pool snapshot

func performOverwatch() {
    guard let a = activeCharacter else { return }
    overwatchers[a.id] = a.attackPool(skill: .firearms)
    addLog("🎯 \(a.name) ENTERS OVERWATCH — holds fire until an enemy moves.")
    completeAction(for: a)
}
```

In `runEnemyAI`, just before each `enemy.positionX = newX; enemy.positionY = newY` (i.e., before each movement step), check every overwatcher: if the enemy's NEW tile has LOS to the overwatcher and no wall block, trigger a reaction shot (reuse the attack resolution, but halve netHits for reaction fire). Clear the overwatcher (single shot).

Add an `OVR` button to ActionBar between DEF and special. Or make overwatch the streetSam's second ability — TBD, Aaron can choose in UI polish phase.

### 6.8 Combat log improvements

Current log lines are verbose but a bit noisy. Light pass:
- Add prefix glyphs: ⚔️ for player attacks, 🛡️ for defenses, ✨ for spells, ⚡ for stun, 🔥 for burn tick.
- Merge the two-line "X attacks Y" + "→ hit for Z" into one line.
- Color-highlight critical glitches and level-ups more strongly in `CombatLogView.entryColor`.

### 6.9 Visual juice (Task #4)

EffectsManager already has: scanlines, muzzle flash, shield block hex, cyber glitch, blood, sparks, rain. It's under-used. Audit BattleScene.swift and make sure every player attack/hit/miss triggers:
- `emitMuzzleFlash` at attacker for firearms
- `emitSparks` at target on miss
- `emitBlood` at target on hit
- `showDamageNumber` floating up on hit
- `screenShake(magnitude: .small)` on big hits (>10 dmg)
- `emitCyberGlitch` on Hack, `emitShieldBlock` on Defend-reduced hits, etc.

Also add:
- A **CRT vignette** overlay on the whole BattleScene (subtle, dark corners).
- A **chromatic aberration** on critical hits (shift RGB by 2px for 0.15s).
- **Enemy-turn color wash** — tint the scene slightly red during enemy phase (fade in on `.enemyPhaseBegan`, out on `.playerTurnResumed`).

### 6.10 Playability (Task #6)

- Add tooltips to action buttons (SwiftUI `.help()` or custom popover on long-press).
- Add a brief tutorial banner on Mission001 that fires: "Tap a runner to select. Tap a tile to move. Tap an enemy then ATK." — one line, dismissible.
- Persist run-progress via `UserDefaults` or a JSON file in Documents. Save on mission complete. Load on TitleView.
- Balance pass: Mission001 right now is trivially easy; verify the cover bonus doesn't invalidate the harder missions.

### 6.11 Verification (Task #7)

Since this sandbox has no Swift:
- Ask Aaron to run `xcodegen generate` in `ShadowrunGame/` then build from Xcode.
- If build fails, he pastes errors, Sonnet fixes.
- Ask for a fresh screenshot of combat (previous one was accidentally a home screen — confirmed).
- Ask him to specifically try: LOS around a cover tile, mage Fireball AoE, grenade throw, overwatch trigger.

---

## 7. Writing style / code conventions in this project

- **4-space indent, tabs expanded.** Match existing files.
- `// MARK: - Section` dividers every ~50-80 lines.
- Singletons use `static let shared` and `private init()`.
- `@MainActor final class` for reactive managers.
- No SwiftUI state is stored on sprite classes. All truth lives in `GameState.shared`.
- Notifications drive BattleScene animations. Never mutate GameState from BattleScene tap handlers — forward to `GameState.shared.handleTileTap(...)`.
- `addLog(...)` is the only UI-facing feedback channel besides notifications. Keep log lines short.
- Color from hex: `Color(hex: "00FF88")` (extension already defined).
- Never use emojis in identifier names; fine in log strings.

---

## 8. Quickstart for the next session

When Sonnet picks this up, run this sequence:

```
1. Read this file (SHADOWRUN-OVERHAUL-HANDOFF.md) top to bottom.
2. TaskList to see state. Task #3 is in_progress.
3. Start with §6.1 Cover system → §6.2 patch performAttack → §6.3 hit preview.
   That's one cohesive block. After it, ask Aaron to build + screenshot.
4. Then §6.4 Spellbook → §6.5 Status effects → §6.6 Grenades. Second block.
5. Then §6.7 Overwatch → §6.8 Log polish. Third block.
6. Then §6.9 Visual juice → §6.10 Playability. Fourth block.
7. Each block ends with: "Build and send me a screenshot of combat."
```

Do NOT try to ship all of §6 in one turn — the Explore agent's audit was thorough, but changes this wide-reaching need compile-in-the-loop. Ship in cohesive blocks and keep Aaron in the loop.

---

## 9. One-line summary for fresh session context

> "Cyberpunk turn-based RPG overhaul. Dead code cleaned, audit done, plan committed. Next: add cover system (CombatMechanics.swift), hit preview, spellbook (4 spells), status effects, grenades, overwatch, visual juice. Build verification lives on Aaron's Mac — no Swift compiler in sandbox."

---
*Handoff written during session eac5c40f. Continue from §6.1.*

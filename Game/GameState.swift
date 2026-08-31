import Foundation

// MARK: - Spell Type
// (Consolidated here from Entities/Spell.swift on 2026-04-19 to work around
//  the same Xcode cross-file type resolution issue that affected MultiRoomMission.)

enum SpellType: String, CaseIterable, Codable {

    case fireball   // AoE Physical — scorches all living enemies
    case manaBolt   // Single-target Physical — raw mana lance
    case shock      // Single-target Stun — lightning jolt
    case heal       // Self-heal — mend flesh and stun
    case confusion  // Single-target control — scramble a mind for a round
    // Black-market / purchasable spells (gated per-character via purchasedSpells).
    case powerBolt  // Single-target Physical — overcharged lance
    case stormBolt  // Single-target Stun — chain-lightning

    /// The starting spells every mage knows. Purchasable spells return false.
    var isBaseSpell: Bool {
        switch self {
        case .fireball, .manaBolt, .shock, .heal, .confusion: return true
        case .powerBolt, .stormBolt: return false
        }
    }

    // MARK: Display

    var displayName: String {
        switch self {
        case .fireball: return "Fireball"
        case .manaBolt: return "Mana Bolt"
        case .shock:    return "Shock"
        case .heal:     return "Heal"
        case .confusion: return "Confusion"
        case .powerBolt: return "Power Bolt"
        case .stormBolt: return "Storm Bolt"
        }
    }

    var icon: String {
        switch self {
        case .fireball: return "flame.fill"
        case .manaBolt: return "bolt.fill"
        case .shock:    return "bolt.circle.fill"
        case .heal:     return "cross.fill"
        case .confusion: return "questionmark.circle.fill"
        case .powerBolt: return "sparkles"
        case .stormBolt: return "cloud.bolt.fill"
        }
    }

    var colorHex: String {
        switch self {
        case .fireball: return "FF4422"
        case .manaBolt: return "6699FF"
        case .shock:    return "FFEE00"
        case .heal:     return "44CC88"
        case .confusion: return "FF66CC"
        case .powerBolt: return "CC66FF"
        case .stormBolt: return "66DDFF"
        }
    }

    var manaCost: Int {
        switch self {
        case .fireball: return 4
        case .manaBolt: return 3
        case .shock:    return 3   // was 2 — base bumped to 8, so cost a real
                                   // 3 mana; stops it being a spammable 2-mana
                                   // hard-stun that one-casts most grunts.
        case .heal:     return 2
        case .confusion: return 3   // control tool priced like the bolts —
                                    // one lost enemy turn (or a friendly-fire
                                    // swing) is worth a Mana Bolt.
        case .powerBolt: return 6   // was 5 — premium nuke, real cost
        case .stormBolt: return 4
        }
    }

    var baseDamage: Int {
        switch self {
        case .fireball: return 5   // AoE, so lower per-target
        case .manaBolt: return 8   // Strong single-target
        case .shock:    return 8   // Stun track — was 6; now reaches the
                                   // full-stun (skip-turn) threshold in ~1-2
                                   // casts so it's a real control tool.
        case .heal:     return 0
        case .confusion: return 0  // pure control — no direct damage
        case .powerBolt: return 10 // was 12 — a sidegrade to Mana Bolt (more
                                   // damage for more mana/price), not a nuke
                                   // that one-shots everything.
        case .stormBolt: return 10 // Strong stun
        }
    }

    var description: String {
        switch self {
        case .fireball: return "Blast ALL enemies. \(baseDamage)+hits Physical each."
        case .manaBolt: return "Focus single target. \(baseDamage)+hits Physical."
        case .shock:    return "Stun single target. \(baseDamage)+hits Stun."
        case .heal:     return "Restore HP & stun to a chosen ally."
        case .confusion: return "Scramble a mind — target attacks blindly or stumbles."
        case .powerBolt: return "Overcharged lance. \(baseDamage)+hits Physical."
        case .stormBolt: return "Chain-lightning. \(baseDamage)+hits Stun."
        }
    }

    var isAreaOfEffect: Bool { self == .fireball }
    var isStunDamage: Bool   { self == .shock || self == .stormBolt }
    var isHeal: Bool         { self == .heal }
    var needsEnemyTarget: Bool { self == .manaBolt || self == .shock || self == .powerBolt || self == .stormBolt || self == .confusion }
}

enum ActionMode: String, CaseIterable {
    case street
    case signal
}

enum MissionPreset: String, CaseIterable {
    case lowPressure
    case standard
    case highPressure
}

enum PlayerRole: String, CaseIterable {
    case normal
    case hacker
    case street
}

enum MissionType {
    case stealth
    case assault
    case extraction
}

/// Additive Stage-1 state machine axis.
/// Legacy booleans remain for compatibility during migration.
enum CombatPhase {
    case idle
    case playerInput
    case playerResolving
    case enemyResolving
    case extractRequested
    case combatResolved
    case rewarding
    case complete
}

/// Additive Stage-1 outcome axis.
/// Legacy booleans remain for compatibility during migration.
enum CombatOutcome {
    case none
    case victory
    case defeat
    case extracted
}

enum EnemyArchetype {
    case watcher
    case enforcer
    case interceptor
}

enum MapSituation {
    case corridor
    case openZone
    case chokepoint
}

enum HeatTier {
    case low
    case medium
    case high
}

enum Faction: String, Hashable {
    case corp
    case gang
    case unknown
}

// MARK: - Singleton combat/game runtime state

/// Singleton combat/game runtime state — accessible across all layers.
@MainActor
final class GameState: ObservableObject {

    static let shared = GameState()
    var sessionState = GameSessionState()

    private init() {
        // Campaign world-reaction state persists across launches — it was
        // memory-only, so a force-quit between missions amnesia'd the
        // corp/gang attention that MissionSetupService feeds into spawns.
        factionAttention = MissionStatsStore.shared.loadFactionAttention()
    }

    private enum TraceCadence {
        static let gainPerSignal = 1
        static let recoveryPerLayLow = 2
        static func threshold(for preset: MissionPreset) -> Int {
            switch preset {
            case .lowPressure: return 5
            case .standard: return 4
            case .highPressure: return 3
            }
        }
        static func escalationDamageBonus(for preset: MissionPreset) -> Int {
            switch preset {
            case .lowPressure: return 1
            case .standard: return 1
            case .highPressure: return 1
            }
        }
    }

    // MARK: - Team

    @Published var playerTeam: [Character] = []
    @Published var enemies: [Enemy] = []

    /// Transient warning banner text (set by BattleScene when player tries to
    /// leave a room without hacking a required terminal, etc.). Auto-clears
    /// after ~3s — SwiftUI overlay observes and renders. nil = no banner.
    @Published var transientWarning: String? = nil

    /// Posts a transient warning and schedules an auto-clear after `duration`s.
    /// Re-firing while a previous warning is active replaces its text and
    /// resets the timer (no stacking).
    func postTransientWarning(_ text: String, duration: TimeInterval = 3.0) {
        transientWarning = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            // Only clear if it's still the same warning — a newer warning may
            // have overwritten it in the meantime, and we'd be cutting its
            // own timer short otherwise.
            if self.transientWarning == text { self.transientWarning = nil }
        }
    }

    // MARK: - Boss Intro (cinematic reveal)

    /// Describes a boss for the full-screen cinematic intro card. Set this and
    /// the SwiftUI `BossIntroOverlay` slams in over the board, holds, and
    /// auto-clears. nil = no intro showing.
    struct BossIntro: Equatable {
        let name: String        // e.g. "MEKTON-7"
        let title: String       // role line, e.g. "HEAVY MECH UNIT"
        let tagline: String     // flavour threat line
        /// Base image name in Sprites/backgrounds/ for the big rendered splash.
        /// Falls back to a tinted gradient + sprite if the art isn't present.
        let splashKey: String
        let accentHex: String   // theme colour for the frame/title
    }

    /// Non-nil while the boss-intro cinematic is on screen. SwiftUI observes it.
    @Published var bossIntro: BossIntro? = nil

    /// Present the cinematic boss intro for a given archetype. The card stays
    /// up until the player TAPS to engage (handled by BossIntroOverlay). The
    /// `duration` here is only a long safety fallback so a missed tap can't
    /// soft-lock the fight behind the overlay.
    /// Centralises the per-boss title/splash/accent mapping so every deploy
    /// path (mech/AGI/corp via `deployBoss`, mage via CombatFlowController)
    /// gets a consistent dramatic reveal.
    func presentBossIntro(archetype: String, name: String, duration: TimeInterval = 30.0) {
        let intro: BossIntro
        switch archetype.lowercased() {
        case "bossagi", "agi", "ai":
            intro = BossIntro(name: name, title: "ROGUE INTELLIGENCE",
                              tagline: "It has already read your mind.",
                              splashKey: "boss_splash_agi", accentHex: "27E0E0")
        case "bosscorp", "corp", "exec":
            intro = BossIntro(name: name, title: "CORPORATE ENFORCER",
                              tagline: "No witnesses. No exceptions.",
                              splashKey: "boss_splash_corp", accentHex: "FF4A4A")
        case "bossmage", "mage":
            intro = BossIntro(name: name, title: "BLOOD MAGE — UNBOUND",
                              tagline: "His blood magic was only the start.",
                              splashKey: "boss_splash_mage", accentHex: "C13AED")
        default: // bossmech / mech / boss
            intro = BossIntro(name: name, title: "HEAVY MECH UNIT",
                              tagline: "Prototype armor. Live weapons.",
                              splashKey: "boss_splash_mech", accentHex: "FF7A1A")
        }
        // Set the intro; the View animates the .transition(.opacity) insertion
        // via an `.animation(value:)` keyed on bossIntro presence (GameState
        // has no SwiftUI import, so the fade is driven from the view layer).
        bossIntro = intro
        let snapshot = intro
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if self.bossIntro == snapshot { self.bossIntro = nil }
        }
    }

    // MARK: - Inventory / Loot

    /// Unequipped items available to the team
    @Published var loot: [Item] = []

    struct Item: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let type: ItemType
        let bonus: Int  // HP heal, armor value, or tactical item base damage
        /// True when this entry was seeded from a runner's purchased inventory
        /// (seedLootFromRoster). Using it must deplete that inventory — looted
        /// freebies (false) must NOT, even when names collide ("Medkit").
        var fromInventory: Bool = false

        enum ItemType: String {
            case consumable  // medkit
            case weapon
            case armor
            case grenade     // tactical throwable
        }
    }

    /// Remove one purchased copy of a consumed item from whichever runner's
    /// persistent inventory backs it. Without this, shop stims re-seed into
    /// the loot pool every mission — one ¥1,500 medkit was an infinite supply.
    func consumeRosterItem(_ item: Item) {
        guard item.fromInventory else { return }
        for char in playerTeam {
            if let idx = char.inventory.firstIndex(where: { $0.name == item.name }) {
                // Multi-use items (medkit ships with uses: 2) burn one charge
                // per consumption and only leave the inventory at 0.
                if char.inventory[idx].uses > 1 {
                    char.inventory[idx].uses -= 1
                } else {
                    char.inventory.remove(at: idx)
                }
                return
            }
        }
    }

    private let lootTable: [(type: Item.ItemType, chance: Double, name: String, bonus: Int)] = [
        (.consumable, 0.6, "Medkit", 10),
        (.consumable, 0.3, "Stimpatch", 5),
        (.consumable, 0.25, "Mana Focus", 6),  // restores mana for the mage
        (.grenade, 0.22, "Frag Grenade", 7),
        (.weapon, 0.2, "Weapon Mod +1 dmg", 1),
        (.weapon, 0.1, "Weapon Mod +2 dmg", 2),
        (.armor, 0.15, "Armor Plate +2", 2),
        (.armor, 0.1, "Armor Plate +3", 3),
    ]

    /// Chance a kill actually drops an item. Was 100% (every kill), which felt
    /// spammy — and AoE spells / burn DoT call this once PER killed enemy, so a
    /// Fireball used to dump a pile of loot at once. A per-kill roll tames both:
    /// most kills drop nothing, and a 3-kill Fireball averages ~1 drop.
    static let lootDropChance = 0.15

    func generateLoot(by killer: Character? = nil) {
        guard Double.random(in: 0..<1) < GameState.lootDropChance else { return }
        // Weighted draw — `chance` is a relative weight. The old
        // `randomElement()` ignored it entirely, making permanent gear
        // upgrades drop as often as medkits.
        let totalWeight = lootTable.reduce(0.0) { $0 + $1.chance }
        var roll = Double.random(in: 0..<totalWeight)
        var drop = lootTable[0]
        for entry in lootTable {
            roll -= entry.chance
            if roll < 0 { drop = entry; break }
        }
        let item = Item(name: drop.name, type: drop.type, bonus: drop.bonus)
        // Weapon/armor "mods" apply IMMEDIATELY to the runner who scored the
        // kill (a permanent +bonus to their gear for the run). For UNATTRIBUTED
        // kills (burn/DoT with no killer) `killer` is nil → the mod goes to the
        // ITM stash instead of buffing an arbitrary runner who didn't earn it.
        // Consumables/grenades always go to the stash.
        let picker = killer
        // Ceilings so permanent loot upgrades can't stack uncapped on top of
        // leveling + cyberware + shop gear over a campaign (which caused a
        // late-game power runaway). Past the cap, the drop converts to a
        // grenade so the kill still feels rewarding.
        let weaponDmgCap = 14, armorCap = 9
        // `stashed` = what actually lands in the usable-items pool, so the
        // toast/log reflect reality. A weapon/armor mod that gets auto-applied
        // to gear adds NOTHING to the stash — toasting it as a "pickup" sent
        // players to an empty ITEMS menu ("got a medkit, none available").
        var stashed: Item? = nil
        switch drop.type {
        case .weapon:
            if let c = picker, var w = c.equippedWeapon, w.damage < weaponDmgCap {
                w.damage = min(weaponDmgCap, w.damage + drop.bonus)
                c.equippedWeapon = w
                addLog("🔧 \(c.name)'s \(w.name) upgraded (\(w.damage) dmg)!")
                presentGearToast(name: "\(w.name) +\(drop.bonus) dmg", icon: "scope", colorHex: "FFCC33")
            } else {
                let g = Item(name: "Grenade", type: .grenade, bonus: 6)
                loot.append(g); stashed = g
                addLog("💼 Loot: spare grenade! (use with ITM)")
            }
        case .armor:
            if let c = picker, (c.equippedArmor?.armorValue ?? 0) < armorCap {
                if var ar = c.equippedArmor {
                    ar.armorValue = min(armorCap, ar.armorValue + drop.bonus); c.equippedArmor = ar
                } else {
                    c.equippedArmor = Armor(name: "Scavenged Plating", armorValue: drop.bonus, spellPenalty: 0)
                }
                addLog("🛡 \(c.name)'s armor reinforced (\(c.equippedArmor?.armorValue ?? 0))!")
                presentGearToast(name: "Armor +\(drop.bonus)", icon: "shield.fill", colorHex: "00C8FF")
            } else {
                let mk = Item(name: "Medkit", type: .consumable, bonus: 5)
                loot.append(mk); stashed = mk
                addLog("💼 Loot: medkit! (use with ITM)")
            }
        default:
            loot.append(item); stashed = item
            addLog("💼 Loot: \(drop.name)! (use with ITM)")
        }
        // Dedicated, prominent pickup toast (its OWN channel — not the shared
        // transientWarning banner). Only for items that actually entered the
        // stash; gear upgrades get their own toast above.
        if let stashed { presentLootToast(stashed) }
    }

    /// Toast for a loot drop that was auto-applied to a runner's GEAR (not a
    /// usable item) — visually distinct from the "use with ITM" pickup toast
    /// so the player doesn't go hunting for it in the ITEMS menu.
    func presentGearToast(name: String, icon: String, colorHex: String) {
        let info = LootInfo(name: name, icon: icon, detail: "Auto-equipped", colorHex: colorHex)
        lootToast = info
        let snapshot = info
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_300_000_000)
            if self.lootToast == snapshot { self.lootToast = nil }
        }
    }

    // MARK: - Loot pickup toast

    struct LootInfo: Equatable {
        let name: String
        let icon: String      // SF Symbol
        let detail: String    // what it does
        let colorHex: String
    }
    @Published var lootToast: LootInfo? = nil

    /// Show a clear "picked up X" card for a loot drop, then auto-clear.
    func presentLootToast(_ item: Item) {
        let info: LootInfo
        switch item.type {
        case .consumable:
            info = LootInfo(name: item.name, icon: "cross.case.fill",
                            detail: "Consumable · use with ITM", colorHex: "44CC88")
        case .grenade:
            info = LootInfo(name: item.name, icon: "circle.hexagongrid.fill",
                            detail: "\(item.bonus)P blast · throw with ITM", colorHex: "FF8844")
        case .weapon:
            info = LootInfo(name: item.name, icon: "scope",
                            detail: "Weapon mod +\(item.bonus)", colorHex: "FFCC33")
        case .armor:
            info = LootInfo(name: item.name, icon: "shield.fill",
                            detail: "Armor +\(item.bonus)", colorHex: "00C8FF")
        }
        lootToast = info
        let snapshot = info
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_300_000_000)
            if self.lootToast == snapshot { self.lootToast = nil }
        }
    }

    // MARK: - Turn

    @Published var currentTurnIndex: Int = 0
    @Published var roundNumber: Int = 1
    var enemyPhaseCount: Int {  // how many enemy phases have completed (for delayed spawns)
        get { sessionState.enemyPhaseCount }
        set { sessionState.enemyPhaseCount = newValue }
    }
    @Published var isPlayerTurn: Bool = true
    /// When true, blocks player input in BattleScene while enemy phase is running.
    @Published var isPlayerInputBlocked: Bool = false
    /// Stage-1 additive migration layer. Owned by CombatFlowController writes only.
    @Published var combatPhase: CombatPhase = .idle
    /// Stage-1 additive migration layer. Owned by CombatFlowController writes only.
    @Published var combatOutcome: CombatOutcome = .none
    /// Guards against double-triggering enemyPhase() within the same frame/turn.
    var isEnemyPhaseRunning: Bool {
        get { sessionState.isEnemyPhaseRunning }
        set { sessionState.isEnemyPhaseRunning = newValue }
    }
    @Published var actionMode: ActionMode = .street
    @Published var playerRole: PlayerRole = .normal
    @Published var selectedMissionPreset: MissionPreset = .standard
    @Published var traceLevel: Int = 0
    var traceThreshold: Int { TraceCadence.threshold(for: selectedMissionPreset) }
    var traceGainPerSignal: Int { TraceCadence.gainPerSignal }
    var traceRecoveryPerLayLow: Int { TraceCadence.recoveryPerLayLow }
    /// TRACE the active LAY LOW would actually vent (Hacker recovers +1).
    var layLowRecoveryAmount: Int { traceRecoveryPerLayLow + (playerRole == .hacker ? 1 : 0) }
    var escalationDamageBonus: Int { TraceCadence.escalationDamageBonus(for: selectedMissionPreset) }
    @Published var traceEscalationLevel: Int = 0
    /// One HIGH-alert response (reinforcement + warning) per climb into HIGH
    /// tier. Reset when trace falls back below HIGH so it can fire again.
    @Published var traceHighAlertFired: Bool = false

    // MARK: - SIGNAL stance ("Ride the Heat")

    /// True while jacked into SIGNAL mode (the loud, aggressive stance).
    var signalActive: Bool { actionMode == .signal }

    /// Bonus combat dice granted by SIGNAL, scaling with TRACE heat.
    /// STREET = 0. SIGNAL: LOW +1, MED +2, HIGH +3. The hotter the net, the
    /// harder you hit — and the harder they hit back.
    var signalDiceBonus: Int {
        guard signalActive else { return 0 }
        switch traceTier { case 2: return 3; case 1: return 2; default: return 1 }
    }

    /// Spell mana discount while running hot (MED+ heat). STREET = 0.
    var signalManaDiscount: Int { (signalActive && traceTier >= 1) ? 1 : 0 }

    /// Net-hits needed to score a CRIT. STREET = 4 (the long-standing bar).
    /// SIGNAL sharpens it: LOW/MED 3, HIGH 2 — running hot fishes for crits.
    var critThreshold: Int {
        guard signalActive else { return 4 }
        return traceTier >= 2 ? 2 : 3
    }

    var hasLoggedTraceTriggerForCurrentRun: Bool {
        get { sessionState.hasLoggedTraceTriggerForCurrentRun }
        set { sessionState.hasLoggedTraceTriggerForCurrentRun = newValue }
    }

    // MARK: - Turn Structure (Issue 1 fix)
    // Track which players have NOT yet acted this round. Empty = all acted = enemy phase.
    var playersWhoHaveNotActed: Set<UUID> {
        get { sessionState.playersWhoHaveNotActed }
        set { sessionState.playersWhoHaveNotActed = newValue }
    }

    /// Per-character movement tracking: if true, character has already moved this turn
    /// and cannot take a major action (attack/defend/cast/item) in the same turn.
    /// Reset at start of each round alongside hasActedThisRound.
    var characterHasMovedThisTurn: [UUID: Bool] {
        get { sessionState.characterHasMovedThisTurn }
        set { sessionState.characterHasMovedThisTurn = newValue }
    }

    /// Number of player turns completed in the current player cycle.
    /// Enemy phase begins after 4 player turns or once all living players have acted.
    var playerTurnsCompleted: Int {
        get { sessionState.playerTurnsCompleted }
        set { sessionState.playerTurnsCompleted = newValue }
    }

    /// True when any living player has HP <= 0 (player death occurred).
    /// Used to block room transitions after player death.
    var playerIsDead: Bool {
        get { sessionState.playerIsDead }
        set { sessionState.playerIsDead = newValue }
    }

    /// Reset turn-tracking state at the start of each round.
    func resetTurnTracking() {
        CombatFlowController.resetTurnTracking(gameState: self)
    }

    var isTraceTriggered: Bool {
        traceLevel >= traceThreshold
    }

    /// Tier 0: below threshold (low), Tier 1: triggered (medium), Tier 2: high pressure.
    /// Deterministic and fully derived from existing trace values.
    var traceTier: Int {
        ConsequenceEngine.traceTier(traceLevel: traceLevel, traceThreshold: traceThreshold)
    }

    var traceTierLabel: String {
        switch traceTier {
        case 2: return "HIGH"
        case 1: return "MED"
        default: return "LOW"
        }
    }

    /// Enemy incoming damage modifier derived from trace tier.
    /// Tier 0 = +0, Tier 1 = +base, Tier 2 = +(base + 1)
    var escalationDamageBonusForCurrentTrace: Int {
        switch traceTier {
        case 2:
            return escalationDamageBonus + 1
        case 1:
            return escalationDamageBonus
        default:
            return 0
        }
    }

    func applyStreetAction() {
        // Explicitly no trace mutation.
    }

    func applySignalAction() {
        let previousTier = traceTier
        addLog("TRACE +\(traceGainPerSignal) (Signal)")
        traceLevel += traceGainPerSignal
        if !isTraceTriggered && traceLevel == traceThreshold - 1 {
            addLog("TRACE WARNING — near escalation")
        }
        if isTraceTriggered && !hasLoggedTraceTriggerForCurrentRun {
            hasLoggedTraceTriggerForCurrentRun = true
            addLog("⚠️ TRACE TRIGGERED — hostile network awareness increased.")
        }
        onTraceTierChanged(from: previousTier, to: traceTier)
    }

    /// Shared trace-tier transition handler. Logs the escalation and, when the
    /// net climbs into HIGH tier for the first time, fires the downside "bite":
    /// a loud warning + a security reinforcement responding to the alarm.
    func onTraceTierChanged(from previous: Int, to newTier: Int) {
        traceEscalationLevel = newTier
        if newTier != previous {
            addLog("⚠️ TRACE \(traceTierLabel) — enemy damage +\(escalationDamageBonusForCurrentTrace)")
        }
        if newTier >= 2 && previous < 2 && !traceHighAlertFired {
            traceHighAlertFired = true
            postTransientWarning("🚨 TRACE CRITICAL — THE NET FIGHTS BACK", duration: 3.0)
            SFXManager.shared.play("mech_warning_alarm", volume: 0.5)
            spawnTraceReinforcement()
        }
    }

    /// Downside of running hot: when TRACE hits HIGH, the host scrambles a
    /// security response. Spawns one elite onto a free floor tile as far from
    /// the party as possible. No-ops during boss fights (reinforcements are
    /// suppressed then) or if no safe tile exists.
    func spawnTraceReinforcement() {
        // Don't pile on during a boss encounter.
        if enemies.contains(where: { $0.isAlive && $0.archetype.lowercased().hasPrefix("boss") }) { return }
        // Don't drop a reinforcement onto a board that's already extracting —
        // a late spawn here can leave a live enemy when the extraction finalizes
        // as a victory.
        if extractionAnimationInProgress { return }
        let tiles = currentMissionTiles
        guard !tiles.isEmpty else { return }
        let occupied = Set(
            livingPlayers.map { "\($0.positionX),\($0.positionY)" }
            + livingEnemies.map { "\($0.positionX),\($0.positionY)" }
        )
        var best: (x: Int, y: Int)? = nil
        var bestDist = -1
        for y in tiles.indices {
            for x in tiles[y].indices where tiles[y][x] == TileType.floor.rawValue {
                if occupied.contains("\(x),\(y)") { continue }
                let d = livingPlayers.map { hexDistance(x1: x, y1: y, x2: $0.positionX, y2: $0.positionY) }.min() ?? 99
                if d > bestDist { bestDist = d; best = (x, y) }
            }
        }
        guard let spot = best, bestDist >= 2 else { return }
        let reinforcement = Enemy.eliteGuard()
        NGPlusStore.shared.scaleForTier(reinforcement)
        reinforcement.positionX = spot.x
        reinforcement.positionY = spot.y
        enemies.append(reinforcement)
        addLog("🚨 SECURITY RESPONSE — \(reinforcement.name) jacks in on your position!")
        NotificationCenter.default.post(
            name: .enemySpawned, object: nil,
            userInfo: ["enemyId": reinforcement.id.uuidString]
        )
        objectWillChange.send()
    }

    // Internal (not private): referenced by the extracted enemy-AI code in EnemyAI.swift.
    func escalatedIncomingDamage(_ baseDamage: Int) -> Int {
        guard baseDamage > 0 else { return baseDamage }
        // TRACE escalation + New Game+ flat damage bonus both make enemies hit harder.
        let dynamicBonus = escalationDamageBonusForCurrentTrace + NGPlusStore.shared.damageBonus
        guard dynamicBonus > 0 else { return baseDamage }
        let escalatedDamage = baseDamage + dynamicBonus
        if playerRole == .street {
            addLog("STREET — bracing against escalation")
            let reducedDamage = max(0, escalatedDamage - 1)
            addLog("STREET — reduced incoming damage")
            return reducedDamage
        }
        return escalatedDamage
    }

    func applyTraceRecovery() {
        let previousTier = traceTier
        let recoveryAmount: Int
        if playerRole == .hacker {
            recoveryAmount = traceRecoveryPerLayLow + 1
            addLog("HACKER — enhanced trace recovery")
        } else {
            recoveryAmount = traceRecoveryPerLayLow
        }
        let previous = traceLevel
        traceLevel = max(0, traceLevel - recoveryAmount)
        let dropped = previous - traceLevel
        if dropped > 0 {
            addLog("TRACE -\(dropped) (Lay Low)")
            postTransientWarning("🛡 LAY LOW — TRACE −\(dropped)  (now \(traceLevel)/\(traceThreshold))", duration: 2.6)
        } else {
            addLog("TRACE -0 (Lay Low)")
            postTransientWarning("🛡 LAY LOW — TRACE already cold (0/\(traceThreshold))", duration: 2.2)
        }
        let newTier = traceTier
        traceEscalationLevel = newTier
        if newTier != previousTier {
            addLog("TRACE \(traceTierLabel) — enemy damage +\(escalationDamageBonusForCurrentTrace)")
        }
        // Cooled back below HIGH — re-arm the security response for next time.
        if newTier < 2 { traceHighAlertFired = false }
    }

    func traceTelemetrySummary() -> String {
        "trace=\(traceLevel)/\(traceThreshold) escalated=\(traceEscalationLevel >= 1) mode=\(actionMode.rawValue) role=\(playerRole.rawValue)"
    }

    var playerRoleLabel: String {
        switch playerRole {
        case .normal: return "NORMAL"
        case .hacker: return "HACKER"
        case .street: return "STREET"
        }
    }

    var missionPresetLabel: String {
        switch selectedMissionPreset {
        case .lowPressure: return "LOW"
        case .standard: return "STANDARD"
        case .highPressure: return "HIGH"
        }
    }

    var missionTypeLabel: String {
        switch currentMissionType {
        case .stealth: return "STEALTH"
        case .assault: return "ASSAULT"
        case .extraction: return "EXTRACTION"
        }
    }

    var missionTypeHint: String {
        switch currentMissionType {
        case .stealth: return "Stay low profile for bonus"
        case .assault: return "High intensity yields bonus"
        case .extraction: return "Balanced approach rewarded"
        }
    }

    var mapSituationLabel: String {
        switch currentMapSituation {
        case .corridor: return "CORRIDOR"
        case .openZone: return "OPEN ZONE"
        case .chokepoint: return "CHOKEPOINT"
        }
    }

    func cyclePlayerRole() {
        switch playerRole {
        case .normal:
            playerRole = .hacker
        case .hacker:
            playerRole = .street
        case .street:
            playerRole = .normal
        }

        addLog("ROLE SET — \(playerRoleLabel)")
    }

    func cycleMissionPreset() {
        switch selectedMissionPreset {
        case .lowPressure:
            selectedMissionPreset = .standard
        case .standard:
            selectedMissionPreset = .highPressure
        case .highPressure:
            selectedMissionPreset = .lowPressure
        }

        addLog("PRESET SET — \(missionPresetLabel)")
    }

    func cycleMissionType() {
        switch currentMissionType {
        case .stealth:
            currentMissionType = .assault
        case .assault:
            currentMissionType = .extraction
        case .extraction:
            currentMissionType = .stealth
        }

        addLog("MISSION TYPE — \(missionTypeLabel)")
    }

    /// Call at the START of each round (before first player acts).
    func beginRound() {
        CombatFlowController.beginRound(gameState: self)
    }

    /// SR5 stun recovery: at the start of each round, each living character rolls BOD+WIL.
    /// Each hit reduces stun by 1 (simplified from real SR5 rest-based recovery).
    func recoverStunAtRoundStart() {
        CombatFlowController.recoverStunAtRoundStart(gameState: self)
    }

    // MARK: - Current Mission Tiles (for enemy pathfinding)

    var currentMissionTiles: [[Int]] {
        get { sessionState.currentMissionTiles }
        set { sessionState.currentMissionTiles = newValue }
    }

    /// True when the active mission/room has a data-terminal objective that must
    /// be hacked before extraction is allowed.
    var missionRequiresData: Bool {
        get { sessionState.missionRequiresData }
        set { sessionState.missionRequiresData = newValue }
    }

    var dataAcquired: Bool {
        get { sessionState.dataAcquired }
        set { sessionState.dataAcquired = newValue }
    }

    /// M3 grimoire pickup status — mirrors sessionState (see GameSessionState).
    var grimoireAcquired: Bool {
        get { sessionState.grimoireAcquired }
        set { sessionState.grimoireAcquired = newValue }
    }

    /// M3 boss-phase-2 trigger flag — mirrors sessionState.
    var mageBossPhase2Triggered: Bool {
        get { sessionState.mageBossPhase2Triggered }
        set { sessionState.mageBossPhase2Triggered = newValue }
    }
    /// M3 boss-phase-2 deferred-spawn flag — see GameSessionState.
    var mageBossPhase2Pending: Bool {
        get { sessionState.mageBossPhase2Pending }
        set { sessionState.mageBossPhase2Pending = newValue }
    }
    var mageBossPendingSpawnX: Int {
        get { sessionState.mageBossPendingSpawnX }
        set { sessionState.mageBossPendingSpawnX = newValue }
    }
    var mageBossPendingSpawnY: Int {
        get { sessionState.mageBossPendingSpawnY }
        set { sessionState.mageBossPendingSpawnY = newValue }
    }

    /// Total kills across all rooms in the current mission.
    var missionEnemiesDefeated: Int {
        get { sessionState.missionEnemiesDefeated }
        set { sessionState.missionEnemiesDefeated = newValue }
    }

    /// Has the first kill in the current room been processed (for barrier drops)?
    /// Reset on room transition.
    var firstKillProcessedInRoom: Bool {
        get { sessionState.firstKillProcessedInRoom }
        set { sessionState.firstKillProcessedInRoom = newValue }
    }

    var extractionAnimationInProgress: Bool {
        get { sessionState.extractionAnimationInProgress }
        set { sessionState.extractionAnimationInProgress = newValue }
    }

    /// M4 corp-boss (Vera Koss) transient combat state — reset on her deploy.
    /// `corpBossMarkedId` = the runner she's locked for an amplified EXECUTE
    /// shot; `corpBossSummons` = how many security drones she's called in.
    var corpBossMarkedId: UUID? = nil
    var corpBossSummons: Int = 0
    /// Lifetime drone summons per rigger (keyed by enemy id) — caps the
    /// rigger's call-ins at 3 so it can't be farmed for infinite XP/loot.
    var riggerSummons: [UUID: Int] = [:]

    /// Round each unit (player OR enemy id) was knocked PRONE. The status
    /// clears in tickStatusEffects, but the tick fires at the top of
    /// beginRound — immediately AFTER the enemy phase. Without this stamp a
    /// riot-shotgun knockdown landed in the enemy phase would be removed
    /// before the runner's input phase ever opened (prone would never
    /// actually pin a player). The tick skips removal while
    /// `roundNumber == inflicted round`, so a knockdown genuinely lasts the
    /// round it was inflicted, then clears. Entries are dropped on stand-up;
    /// stale ids from downed units are inert (transient, like riggerSummons).
    var proneInflictedRound: [UUID: Int] = [:]

    var intimidationOriginalAgi: [UUID: Int] {
        get { sessionState.intimidationOriginalAgi }
        set { sessionState.intimidationOriginalAgi = newValue }
    }

    /// ENEMY overwatch bank — the inverse of the player-side `overwatchers`
    /// dictionary above: enemy id → snapshotted attack pool. A sniper or
    /// turret that finds no target in range/LOS on its AI turn banks its shot
    /// here instead; any player MOVEMENT commit while the bank is live (and
    /// the banker has range + LOS) eats one reaction shot at halved net hits
    /// (see fireEnemyOverwatchShots). Lifecycle: banked during the enemy
    /// phase, live through the following player input phase, and cleared at
    /// the START of the next enemy phase (CombatFlowController.enemyPhase) —
    /// clearing in beginRound like `overwatchers` would wipe fresh banks
    /// before the player ever moved, because beginRound runs immediately
    /// AFTER the enemy phase that set them. Entries for enemies that died are
    /// inert (fire path re-checks liveness) and stale ids across missions
    /// never match the new roster (transient, like riggerSummons).
    var enemyOverwatchers: [UUID: Int] = [:]

    /// Cover tiles destroyed mid-combat (barrel detonations / splintered
    /// crates), keyed by room id → list of [x, y] pairs. Room maps are
    /// rebuilt from their JSON on every room (re)entry, which would silently
    /// resurrect destroyed cover — BattleScene re-applies these to both the
    /// visible map (presentationTileMap) and the pathfinding map (after
    /// updateTilesForCurrentRoom) on transition. In-memory only, mirroring
    /// how barrierDroppedRoomIds handles the retracted-barrier persistence.
    var destroyedCoverByRoom: [String: [[Int]]] = [:]

    /// Drives the Matrix hacking mini-game overlay. SwiftUI binds to this so
    /// it must be @Published directly on GameState (forwarded to sessionState
    /// won't trigger view updates).
    @Published var showMatrixMiniGame: Bool = false
    var pendingHackTerminalX: Int {
        get { sessionState.pendingHackTerminalX }
        set { sessionState.pendingHackTerminalX = newValue }
    }
    var pendingHackTerminalY: Int {
        get { sessionState.pendingHackTerminalY }
        set { sessionState.pendingHackTerminalY = newValue }
    }
    var pendingHackCharacterId: UUID? {
        get { sessionState.pendingHackCharacterId }
        set { sessionState.pendingHackCharacterId = newValue }
    }

    /// Stable display id for the currently-loaded mission (e.g. "Mission001").
    /// Used by OutcomePipeline to record the run's score under the right key.
    var currentMissionDisplayId: String? {
        get { sessionState.currentMissionDisplayId }
        set { sessionState.currentMissionDisplayId = newValue }
    }

    // MARK: - Pending Enemy Spawns

    /// Enemies not yet on the map (waiting for their delay timer)
    var pendingSpawns: [PendingSpawn] {
        get { sessionState.pendingSpawns }
        set { sessionState.pendingSpawns = newValue }
    }

    struct PendingSpawn: Identifiable {
        let id = UUID()
        let enemy: Enemy
        let delayRounds: Int  // spawn after N enemy phases have passed
    }

    /// Called after each enemy phase to check if any delayed enemies should spawn.
    /// enemyPhaseIndex = how many enemy phases have completed (0 = first enemy phase just ran).
    func processDelayedSpawns(enemyPhaseIndex: Int) {
        MissionSetupService.processDelayedSpawns(gameState: self, enemyPhaseIndex: enemyPhaseIndex)
    }

    // MARK: - Combat Log

    @Published var combatLog: [String] = []

    // MARK: - Room

    /// Current room ID — synced with BattleScene.currentRoomId during multi-room transitions.
    @Published var currentRoomId: String = "room_0"

    // MARK: - Selected

    /// The character that is actively taking actions (set by selection or turn order)
    @Published var activeCharacterId: UUID?

    @Published var selectedCharacterId: UUID?
    @Published var targetCharacterId: UUID?
    var combatWon: Bool? {
        get { sessionState.combatWon }
        set {
            objectWillChange.send()
            sessionState.combatWon = newValue
        }
    }
    @Published var combatEnded: Bool = false
    @Published var currentMissionType: MissionType = .stealth
    var currentMapSituation: MapSituation {
        get { sessionState.currentMapSituation }
        set {
            objectWillChange.send()
            sessionState.currentMapSituation = newValue
        }
    }
    @Published var missionComplete: Bool = false
    var missionHeat: Int {
        get { sessionState.missionHeat }
        set {
            objectWillChange.send()
            sessionState.missionHeat = newValue
        }
    }
    var missionHeatTier: HeatTier {
        get { sessionState.missionHeatTier }
        set {
            objectWillChange.send()
            sessionState.missionHeatTier = newValue
        }
    }
    @Published var factionAttention: [Faction: Int] = [
        .corp: 0,
        .gang: 0,
        .unknown: 0
    ]
    var lastAppliedCorpEnemyModifier: Int {
        get { sessionState.lastAppliedCorpEnemyModifier }
        set {
            objectWillChange.send()
            sessionState.lastAppliedCorpEnemyModifier = newValue
        }
    }
    var lastAppliedGangAmbushRadius: Int {
        get { sessionState.lastAppliedGangAmbushRadius }
        set {
            objectWillChange.send()
            sessionState.lastAppliedGangAmbushRadius = newValue
        }
    }
    var didApplyAttentionRecoveryLastMission: Bool {
        get { sessionState.didApplyAttentionRecoveryLastMission }
        set {
            objectWillChange.send()
            sessionState.didApplyAttentionRecoveryLastMission = newValue
        }
    }
    var didApplyHighTraceEscalationBonusLastMission: Bool {
        get { sessionState.didApplyHighTraceEscalationBonusLastMission }
        set {
            objectWillChange.send()
            sessionState.didApplyHighTraceEscalationBonusLastMission = newValue
        }
    }
    var lastRewardTier: RewardTier {
        get { sessionState.lastRewardTier }
        set {
            objectWillChange.send()
            sessionState.lastRewardTier = newValue
        }
    }
    var lastRewardMultiplier: Double {
        get { sessionState.lastRewardMultiplier }
        set {
            objectWillChange.send()
            sessionState.lastRewardMultiplier = newValue
        }
    }
    var missionTypeBonusMultiplier: Double {
        get { sessionState.missionTypeBonusMultiplier }
        set {
            objectWillChange.send()
            sessionState.missionTypeBonusMultiplier = newValue
        }
    }
    @Published var baseMissionPayout: Int = 100
    var missionTargetTurns: Int {
        get { sessionState.missionTargetTurns }
        set {
            objectWillChange.send()
            sessionState.missionTargetTurns = newValue
        }
    }
    var currentTurnCount: Int {
        get { sessionState.currentTurnCount }
        set {
            objectWillChange.send()
            sessionState.currentTurnCount = newValue
        }
    }
    var missionLoadIndex: Int {
        get { sessionState.missionLoadIndex }
        set { sessionState.missionLoadIndex = newValue }
    }
    var activeCharacter: Character? {
        guard let id = activeCharacterId else { return currentCharacter }
        return playerTeam.first(where: { $0.id == id && $0.isAlive })
    }

    // MARK: - Actions

    /// Every runner holding DEFEND / LAY LOW this round. Per-round, like
    /// `overwatchers`: cleared in beginRound, NOT when the next teammate's
    /// turn starts (the old single-slot version meant only the last character
    /// to act kept their bonus into the enemy phase).
    @Published var defenders: Set<UUID> = []

    /// Whether the character the HUD is showing is defending (UI convenience).
    /// Lookup order matches StatusDisplay's `activeCharacter ?? currentCharacter`
    /// so the DEF badge styles the same runner whose name/HP it sits next to.
    var isDefending: Bool {
        guard let id = activeCharacterId ?? selectedCharacterId else { return false }
        return defenders.contains(id)
    }

    var isItemMenuVisible: Bool {
        get { sessionState.isItemMenuVisible }
        set {
            objectWillChange.send()
            sessionState.isItemMenuVisible = newValue
        }
    }

    /// Active overwatch entries: characterId → attack pool snapshot.
    /// Cleared at the start of each round (resetTurnTracking).
    @Published var overwatchers: [UUID: Int] = [:]

    /// This round's player acting order, fastest first — rolled in
    /// resetTurnTracking from REA + INT + 1d6 + cyberware initiative. This is
    /// what makes initiative (and Wired-Reflexes-type implants) a real stat:
    /// auto-advance walks this list instead of fixed roster order.
    @Published var roundInitiativeOrder: [UUID] = []

    /// Monotonic id of the current mission attempt — bumped by mission setup
    /// AND by abort. Every deferred closure (extraction finalize timers,
    /// enemy-phase stagger, AGI boss spawn, force-unblock watchdogs) captures
    /// it and bails if it changed. GameState is a singleton, so
    /// `[weak gameState]` never nils across an abort/restart and
    /// `!combatEnded` is reset by the next setup — which let stale timers
    /// fire into the NEXT mission (instant auto-win, ghost-enemy attacks).
    var missionAttemptId: Int = 0

    // MARK: - Computed

    var currentCharacter: Character? {
        guard isPlayerInputPhase, !playerTeam.isEmpty else { return nil }
        // Find first living player at or after currentTurnIndex
        for i in currentTurnIndex..<playerTeam.count {
            if playerTeam[i].isAlive { return playerTeam[i] }
        }
        // Wrap around
        for i in 0..<currentTurnIndex {
            if playerTeam[i].isAlive { return playerTeam[i] }
        }
        return nil
    }

    var livingPlayers: [Character] { playerTeam.filter { $0.isAlive } }
    var livingEnemies: [Enemy] { enemies.filter { $0.isAlive } }

    var isCombatOver: Bool {
        livingPlayers.isEmpty || livingEnemies.isEmpty
    }

    var playerTeamWon: Bool {
        isCombatOver && !livingPlayers.isEmpty && livingEnemies.isEmpty
    }

    /// Compatibility accessor — prefer phase/outcome, legacy fallback retained temporarily.
    var isPlayerInputPhase: Bool {
        (combatPhase == .playerInput) || isPlayerTurn
    }

    /// Compatibility accessor — prefer phase/outcome, legacy fallback retained temporarily.
    var isInputBlockedByPhase: Bool {
        (combatPhase != .playerInput) || isPlayerInputBlocked
    }

    /// Compatibility accessor — prefer phase/outcome, legacy fallback retained temporarily.
    var isCombatResolvedOrBeyond: Bool {
        (combatPhase == .combatResolved || combatPhase == .rewarding || combatPhase == .complete) || combatEnded
    }

    /// Compatibility accessor — prefer phase/outcome, legacy fallback retained temporarily.
    var isCombatVictoryLike: Bool {
        if combatOutcome == .victory || combatOutcome == .extracted {
            return true
        }
        if combatOutcome == .defeat {
            return false
        }
        return combatWon ?? false
    }

    /// Compatibility accessor — prefer phase/outcome, legacy fallback retained temporarily.
    var isMissionCompleteCompat: Bool {
        (combatPhase == .complete) || missionComplete
    }

    /// Read-only diagnostics summary for turn authority mapping.
    /// Non-authoritative: intended for UI/debug overlays and documentation only.
    var turnAuthoritySummary: String {
        let activeId = (activeCharacter ?? currentCharacter)?.id.uuidString.prefix(8) ?? "n/a"
        return "owner=GameState idx=\(currentTurnIndex) round=\(roundNumber) playerTurn=\(isPlayerTurn) inputBlocked=\(isPlayerInputBlocked) active=\(activeId)"
    }

    var heatTierLabel: String {
        ConsequenceEngine.heatTierLabel(for: missionHeatTier)
    }

    func generateWorldReactionMessage() -> String {
        OutcomePipeline.generateWorldReactionMessage(gameState: self)
    }

    func generateMissionModifierPreview() -> String {
        OutcomePipeline.generateMissionModifierPreview(gameState: self)
    }

    func generateGangReactionMessage() -> String {
        OutcomePipeline.generateGangReactionMessage(gameState: self)
    }

    func generateGangMissionPreview() -> String {
        OutcomePipeline.generateGangMissionPreview(gameState: self)
    }

    func generateCombinedPressurePreview() -> String {
        OutcomePipeline.generateCombinedPressurePreview(gameState: self)
    }

    func rewardTierLabel(_ tier: RewardTier) -> String {
        OutcomePipeline.rewardTierLabel(tier)
    }

    func generateRewardPreview() -> String {
        OutcomePipeline.generateRewardPreview(gameState: self)
    }

    var finalMissionPayout: Int {
        Int(Double(baseMissionPayout) * finalRewardMultiplier)
    }

    var finalRewardMultiplier: Double {
        lastRewardMultiplier + missionTypeBonusMultiplier
    }

    var riskBonus: Int {
        finalMissionPayout - baseMissionPayout
    }

    func generateRewardPayoutSummary() -> String {
        OutcomePipeline.generateRewardPayoutSummary(gameState: self)
    }

    func assignMissionTypeForCurrentLoad() {
        MissionSetupService.assignMissionTypeForCurrentLoad(gameState: self)
    }

    func tileKey(x: Int, y: Int) -> String {
        MissionSetupService.tileKey(gameState: self, x: x, y: y)
    }

    func applyMapSituation(
        to originalMap: [[Int]],
        extractionPoint: (x: Int, y: Int),
        protectedTiles: Set<String>
    ) -> ([[Int]], (x: Int, y: Int)) {
        MissionSetupService.applyMapSituation(
            gameState: self,
            to: originalMap,
            extractionPoint: extractionPoint,
            protectedTiles: protectedTiles
        )
    }

    var currentMissionTilesSnapshot: [[Int]] {
        currentMissionTiles
    }

    func generateMissionEndSummary() -> String {
        OutcomePipeline.generateMissionEndSummary(gameState: self)
    }

    func generateMissionBriefing() -> String {
        let corpAttention = factionAttention[.corp, default: 0]
        let gangAttention = factionAttention[.gang, default: 0]

        let objectiveText: String
        switch currentMissionType {
        case .stealth:
            objectiveText = "Avoid detection and complete the run cleanly."
        case .assault:
            objectiveText = "Push through resistance and secure the objective."
        case .extraction:
            objectiveText = "Maintain momentum and reach extraction safely."
        }

        let expectedThreats: String
        switch currentMissionType {
        case .stealth:
            expectedThreats = "Watchers present. Detection risk high."
        case .assault:
            expectedThreats = "Enforcers present. Direct combat expected."
        case .extraction:
            expectedThreats = "Interceptors present. Movement pressure expected."
        }

        let attentionTotal = corpAttention + gangAttention
        let pressureProfile: String
        switch attentionTotal {
        case 0...2:
            pressureProfile = "Low pressure expected."
        case 3...5:
            pressureProfile = "Moderate escalation likely."
        default:
            pressureProfile = "High escalation risk."
        }

        let rewardProfile: String
        switch currentMissionType {
        case .stealth:
            rewardProfile = "Low trace yields bonus."
        case .assault:
            rewardProfile = "High intensity yields bonus."
        case .extraction:
            rewardProfile = "Balanced approach yields bonus."
        }

        // Prepend story briefing text from mission JSON if available
        let storyBriefing = briefingText.map { "\($0)\n\n" } ?? ""

        return """
        \(storyBriefing)
        ------------------------

        MISSION BRIEFING

        TYPE:
        \(missionTypeLabel)

        OBJECTIVE:
        \(objectiveText)
        \(missionTypeHint)

        EXPECTED THREATS:
        \(expectedThreats)

        PRESSURE PROFILE:
        \(pressureProfile)

        REWARD PROFILE:
        \(rewardProfile)
        \(generateRewardPreview())

        WORLD STATE:
        Corp Attention: \(corpAttention)
        Gang Attention: \(gangAttention)
        \(generateCombinedPressurePreview())

        ------------------------
        """
    }

    func corpAttentionEnemyModifier() -> Int {
        let corpAttention = factionAttention[.corp, default: 0]
        return ConsequenceEngine.corpEnemyModifier(corpAttention: corpAttention)
    }

    /// Live hit-preview for the currently selected attacker → target pair.
    /// Returns nil if no valid attacker or target is selected.
    var hitPreview: CombatMechanics.HitPreview? {
        attackPreview
    }

    var attackPreview: CombatMechanics.HitPreview? {
        guard let attacker = activeCharacter ?? currentCharacter,
              let target = previewTarget(for: attacker) else { return nil }
        let weapon = attacker.equippedWeapon ?? Weapon(name: "Fists", type: .unarmed, damage: 3, accuracy: 3, armorPiercing: 0)
        if (attacker.archetype == .streetSam || attacker.archetype == .decker),
           (weapon.type == .blade || weapon.type == .unarmed),
           hexDistance(x1: attacker.positionX, y1: attacker.positionY,
                       x2: target.positionX, y2: target.positionY) > 1 {
            return CombatMechanics.HitPreview(
                actionLabel: "ATK",
                weaponName: weapon.name,
                targetName: target.name,
                attackPool: 0,
                defensePool: 0,
                coverBonus: 0,
                estimatedHitChance: 0,
                weaponDamage: weapon.damage,
                estimatedDamage: 0,
                blocked: true,
                reason: "Move adjacent first"
            )
        }
        return CombatMechanics.computeHitPreview(
            attacker:  attacker,
            target:    target,
            tiles:     currentMissionTiles,
            weapon:    weapon,
            actionLabel: "ATK",
            signalDiceBonus: signalDiceBonus,
            // Teammate positions so the preview's defense pool includes the
            // FLANKED −2 — matches the check in performAttack exactly.
            attackerAllies: livingPlayers
                .filter { $0.id != attacker.id }
                .map { (x: $0.positionX, y: $0.positionY) },
            isBlocked: { sx, sy, tx, ty in
                self.isLineBlockedByWall(fromX: sx, fromY: sy, toX: tx, toY: ty)
            }
        )
    }

    var shootPreview: CombatMechanics.HitPreview? {
        guard let attacker = activeCharacter ?? currentCharacter,
              attacker.archetype != .streetSam,
              let target = previewTarget(for: attacker) else { return nil }
        let sidearm: Weapon
        switch attacker.archetype {
        case .decker:
            sidearm = Weapon(name: "Smartgun Pistol", type: .pistol, damage: 5, accuracy: 5, armorPiercing: 1)
        default:
            sidearm = Weapon(name: "Sidearm", type: .pistol, damage: 4, accuracy: 4, armorPiercing: 1)
        }
        return CombatMechanics.computeHitPreview(
            attacker: attacker,
            target: target,
            tiles: currentMissionTiles,
            weapon: sidearm,
            actionLabel: "SHT",
            signalDiceBonus: signalDiceBonus,
            // Same flanking context as attackPreview — see comment there.
            attackerAllies: livingPlayers
                .filter { $0.id != attacker.id }
                .map { (x: $0.positionX, y: $0.positionY) },
            isBlocked: { sx, sy, tx, ty in
                self.isLineBlockedByWall(fromX: sx, fromY: sy, toX: tx, toY: ty)
            }
        )
    }

    private func previewTarget(for attacker: Character) -> Enemy? {
        if let targetId = targetCharacterId,
           let selected = enemies.first(where: { $0.id == targetId && $0.isAlive }) {
            return selected
        }
        return livingEnemies
            .map { ($0, hexDistance(x1: attacker.positionX, y1: attacker.positionY, x2: $0.positionX, y2: $0.positionY)) }
            .sorted { $0.1 < $1.1 }
            .first?.0
    }

    // MARK: - Setup

    private func archetypeLabel(_ archetype: EnemyArchetype) -> String {
        switch archetype {
        case .watcher: return "Watcher"
        case .enforcer: return "Enforcer"
        case .interceptor: return "Interceptor"
        }
    }

    func archetypeForSpawnIndex(_ spawnIndex: Int) -> EnemyArchetype {
        MissionSetupService.archetypeForSpawnIndex(gameState: self, spawnIndex: spawnIndex)
    }

    func applyEnemyArchetype(_ archetype: EnemyArchetype, to enemy: Enemy) {
        MissionSetupService.applyEnemyArchetype(gameState: self, archetype: archetype, to: enemy)
    }

    func makeEnemy(for type: String, archetype: EnemyArchetype) -> Enemy {
        MissionSetupService.makeEnemy(gameState: self, for: type, archetype: archetype)
    }

    func logEnemyComposition(totalSpawnCount: Int) {
        MissionSetupService.logEnemyComposition(gameState: self, totalSpawnCount: totalSpawnCount)
    }

    func applyCorpAttentionEnemyInfluence(spawnTemplates: [(type: String, x: Int, y: Int)], map: [[Int]]) {
        MissionSetupService.applyCorpAttentionEnemyInfluence(gameState: self, spawnTemplates: spawnTemplates, map: map)
    }

    func distanceToNearestPlayer(x: Int, y: Int) -> Int {
        PathingAndAIHelpers.distanceToNearestPlayer(gameState: self, x: x, y: y)
    }

    func applyGangAmbushBias(map: [[Int]]) {
        MissionSetupService.applyGangAmbushBias(gameState: self, map: map)
    }

    func setupMission(_ mission: Mission) {
        MissionSetupService.setupMission(gameState: self, mission: mission)
    }

    @discardableResult
    func prepareMissionForCombat(named missionId: String?) -> String {
        MissionSetupService.prepareMissionForCombat(gameState: self, missionId: missionId)
    }

    /// Setup a multi-room mission.
    /// Update tiles for enemy pathfinding (called when a room transition completes).
    func updateTilesForCurrentRoom(_ tiles: [[Int]]) {
        MissionSetupService.updateTilesForCurrentRoom(gameState: self, tiles: tiles)
    }

    func setupMultiRoomMission(_ mission: MultiRoomMission) {
        MissionSetupService.setupMultiRoomMission(gameState: self, mission: mission)
    }

    // MARK: - Actions

    func performAttack() {
        CombatFlowController.performAttack(gameState: self)
    }

    func performShoot() {
        CombatFlowController.performShoot(gameState: self)
    }

    func performLayLow() {
        CombatFlowController.performLayLow(gameState: self)
    }

    // MARK: - Spell Casting

    /// Entry point called from SpellPickerSheet. Validates mage & mana, then dispatches.
    func performSpell(type: SpellType, targetId: UUID? = nil) {
        CombatFlowController.performSpell(gameState: self, type: type, targetId: targetId)
    }

    // MARK: Shared helper — award XP / loot when enemy killed by spell

    func handleEnemyKilled(_ enemy: Enemy, by mage: Character) {
        HapticsManager.shared.enemyKilled()
        // A dead sniper/turret's banked overwatch dies with it. (Belt-and-
        // suspenders: kill paths that bypass this handler are covered by the
        // isAlive re-check in fireEnemyOverwatchShots.)
        enemyOverwatchers.removeValue(forKey: enemy.id)
        missionEnemiesDefeated += 1
        CombatFlowController.handleEnemyKillForRoomEffects(gameState: self)
        let bounty = MissionStatsStore.killBounty(maxHP: enemy.maxHP)
        MissionStatsStore.shared.awardKillNuyen(maxHP: enemy.maxHP)
        addLog("☠️ \(enemy.name) DOWN! +\(enemy.maxHP / 2) XP · +¥\(bounty)")
        generateLoot(by: mage)
        let leveledUp = mage.gainXP(enemy.maxHP / 2)
        if leveledUp {
            HapticsManager.shared.levelUp()
            addLog("🎖️ LEVEL UP! \(mage.name) → Level \(mage.level)!")
            NotificationCenter.default.post(name: .characterLevelUp, object: nil, userInfo: ["characterId": mage.id.uuidString])
        }
        NotificationCenter.default.post(name: .enemyDied, object: nil, userInfo: ["enemyId": enemy.id.uuidString])
        if livingEnemies.isEmpty { onRoomCleared() }
    }

    /// Spawn the room's designated boss enemy AFTER regular enemies are
    /// cleared. Plays the full reveal sequence (arrival horn + thud + radio
    /// + boss music swap) and suppresses any pending reinforcement waves so
    /// the boss is the focal threat. Marks `bossDeployedRoomIds[room]` so
    /// the next `onRoomCleared` call resolves normally.
    func deployBoss(_ boss: BossSpawn, in room: Room) {
        let enemy: Enemy
        switch boss.type {
        case "mech":    enemy = Enemy.bossMech()
        case "boss":    enemy = Enemy.bossMech()
        case "agi", "bossagi", "ai":  enemy = Enemy.bossAGI()
        case "corp", "bosscorp", "exec": enemy = Enemy.bossCorp()
        default:        enemy = Enemy.bossMech()
        }
        NGPlusStore.shared.scaleForTier(enemy)   // New Game+ boss durability scaling
        enemy.positionX = boss.x
        enemy.positionY = boss.y
        // Reset her transient kit state each deploy.
        corpBossMarkedId = nil
        corpBossSummons = 0
        // Name + archetype already set by the factory (MEKTON-7 / AGI-PRIME)
        // so SFX + sprite dispatch route correctly.

        // Mark deployed BEFORE adding to enemies, so the .enemySpawned
        // observer in BattleScene doesn't recurse into onRoomCleared early.
        RoomManager.shared.bossDeployedRoomIds.insert(room.id)

        // Suppress reinforcements for this room — boss fight is the focus.
        pendingSpawns.removeAll()

        // (Removed the old M5 "parked-mech silhouette → floor" reveal: the
        // MEKTON boss fight was moved to its own arena (room_3) because the
        // central parked-mech sprite in room_2 wouldn't clear cleanly. The
        // room_2 wall cluster is now just a static obstacle you walk past, so
        // no tile-conversion happens on boss deploy.)

        // Cinematic reveal card FIRST, then the unit lands on the board — same
        // ordering as the M3 Sato reveal, so the card is already rising as the
        // sprite materialises behind it.
        presentBossIntro(archetype: enemy.archetype, name: enemy.name)

        enemies.append(enemy)
        addLog("⚠️  HEAVY UNIT DEPLOYED — \(enemy.name)")

        // Visual + audio reveal — fire each notification with userInfo so
        // the BattleScene observer can place sprite + run intro sequence.
        NotificationCenter.default.post(
            name: .enemySpawned, object: nil,
            userInfo: [
                "enemyId": enemy.id.uuidString,
                "isBoss": true
            ]
        )
        // Reveal SFX cluster — per-archetype. Mech gets the heavy
        // industrial horn + thud + radio sequence; AGI gets the glitchy
        // hack-intrusion stinger + a paced trace-warning pulse (until
        // dedicated AGI SFX files ship). All calls no-op if files missing.
        if enemy.archetype == "bossagi" {
            // AGI reveal sequence — three-stage cinematic:
            //   1. arrival_glitch: reality-tear
            //   2. manifestation: ringing emergence + heartbeat thud (~1.5s in)
            //   3. voice_mocking: corp-AGI taunt line (~3.0s in)
            SFXManager.shared.play("agi_arrival_glitch")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                SFXManager.shared.play("agi_manifestation")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                SFXManager.shared.play("agi_voice_mocking")
            }
            // Chained boss music — "Intruder Protocol" → "Intruder Protocol 2"
            // alternating with a 3-second early handoff so the fade-out tail
            // of the first track is replaced by the crossfade into the second.
            MusicManager.shared.playBossChain(
                ["m6_boss_a", "m6_boss_b"],
                startOffset: 0,
                endTrimSeconds: 3.0
            )
        } else if enemy.archetype == "bosscorp" {
            // Vera Koss — a corp klaxon + her radioed order (no heavy mech thud).
            // SFX no-op if the files aren't present. Prefer her dedicated theme
            // (m4_boss.mp3) once it ships; until then fall back to the M5 boss
            // cue so the fight is never silent.
            SFXManager.shared.play("mech_engagement_radio")
            if MusicManager.shared.hasTrack("m4_boss") {
                MusicManager.shared.playBossTrack(filename: "m4_boss", startOffset: 0)
            } else {
                MusicManager.shared.playBossTrack(filename: "m5_boss", startOffset: 28)
            }
        } else {
            SFXManager.shared.play("mech_arrival_horn")
            SFXManager.shared.play("mech_thud_landing")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                SFXManager.shared.play("mech_engagement_radio")
            }
            MusicManager.shared.playBossTrack(filename: "m5_boss", startOffset: 28)
        }

        HapticsManager.shared.playerKilled()  // strong shake for the entrance
        objectWillChange.send()
    }

    /// Death from a non-attributed source (burn DoT, environmental hazards,
    /// Confusion friendly fire). No XP awarded — no character "lands the
    /// kill" — but the death pipeline still runs so sprites despawn and the
    /// room-clear state advances. `cause` only flavors the kill log line;
    /// it defaults to the original burn-out wording so the DoT call site
    /// reads exactly as before.
    func handleEnemyKilledByEnvironment(_ enemy: Enemy, cause: String = "burned out") {
        HapticsManager.shared.enemyKilled()
        // Same overwatch-bank cleanup as handleEnemyKilled above.
        enemyOverwatchers.removeValue(forKey: enemy.id)
        missionEnemiesDefeated += 1
        CombatFlowController.handleEnemyKillForRoomEffects(gameState: self)
        // Bounty still pays on an unattributed kill (no XP, since no runner
        // landed it, but the team still cleared the threat).
        let bounty = MissionStatsStore.killBounty(maxHP: enemy.maxHP)
        MissionStatsStore.shared.awardKillNuyen(maxHP: enemy.maxHP)
        addLog("☠️ \(enemy.name) DOWN! (\(cause)) +¥\(bounty)")
        generateLoot()
        NotificationCenter.default.post(name: .enemyDied, object: nil, userInfo: ["enemyId": enemy.id.uuidString])
        if livingEnemies.isEmpty { onRoomCleared() }
    }

    func performDefend() {
        CombatFlowController.performDefend(gameState: self)
    }

    @discardableResult
    func throwGrenade(item: Item, by runner: Character) -> Bool {
        guard CombatFlowController.canAcceptPlayerAction(gameState: self) else { return false }
        guard !CombatFlowController.characterHasAlreadyMoved(gameState: self, runner) else { return false }
        guard let targetId = targetCharacterId,
              let primary = enemies.first(where: { $0.id == targetId && $0.isAlive }) else {
            addLog("Select an enemy before throwing \(item.name).")
            HapticsManager.shared.buttonTap()
            return false
        }
        if isLineBlockedByWall(
            fromX: runner.positionX, fromY: runner.positionY,
            toX: primary.positionX, toY: primary.positionY
        ) {
            addLog("⛔ \(item.name) throw blocked by wall!")
            HapticsManager.shared.buttonTap()
            return false
        }

        switch actionMode {
        case .street: applyStreetAction()
        case .signal: applySignalAction()
        }

        let throwPool = max(1, runner.attributes.agi + max(1, runner.skills.firearms / 2) + runner.level)
        let throwRoll = DiceEngine.roll(pool: throwPool)
        HapticsManager.shared.attackHit()
        NotificationCenter.default.post(
            name: .fireballEffect,
            object: nil,
            userInfo: ["x": primary.positionX, "y": primary.positionY]
        )

        if throwRoll.criticalGlitch {
            let selfDamage = 4
            runner.takeDamage(amount: selfDamage)
            addLog("💥 CRIT GLITCH! \(runner.name)'s \(item.name) detonates early — \(selfDamage) dmg!")
            NotificationCenter.default.post(
                name: .characterHit,
                object: nil,
                userInfo: ["characterId": runner.id.uuidString, "damage": selfDamage]
            )
            if !runner.isAlive { CombatFlowController.handlePlayerKilled(gameState: self, char: runner) }
            completeAction(for: runner)
            return true
        }
        if throwRoll.glitch || throwRoll.hits == 0 {
            addLog("⚠️ \(runner.name) throws \(item.name) wide. [\(throwPool)d6→\(throwRoll.hits)]")
            completeAction(for: runner)
            return true
        }

        let blastTargets = enemies.filter { enemy in
            enemy.isAlive && hexDistance(
                x1: primary.positionX, y1: primary.positionY,
                x2: enemy.positionX, y2: enemy.positionY
            ) <= 1
        }

        addLog("💣 \(runner.name) throws \(item.name)! [\(throwPool)d6→\(throwRoll.hits)] \(blastTargets.count) target\(blastTargets.count == 1 ? "" : "s") in blast.")

        for enemy in blastTargets {
            let distance = hexDistance(
                x1: primary.positionX, y1: primary.positionY,
                x2: enemy.positionX, y2: enemy.positionY
            )
            let falloff = distance == 0 ? 0 : 2
            let baseDamage = max(1, item.bonus + throwRoll.hits - falloff)
            let soakPool = max(0, enemy.computeDerived().soak - 2)
            let soakRoll = DiceEngine.roll(pool: soakPool)
            let finalDamage = max(0, baseDamage - soakRoll.hits)
            enemy.takeDamage(amount: finalDamage, isStun: false)
            addLog("  → \(enemy.name): \(baseDamage)P AP-2 - \(soakRoll.hits) soak = \(finalDamage) dmg. (\(enemy.currentHP)/\(enemy.maxHP) HP)")
            NotificationCenter.default.post(
                name: .enemyHit,
                object: nil,
                userInfo: ["enemyId": enemy.id.uuidString, "damage": finalDamage]
            )
            if !enemy.isAlive {
                handleEnemyKilled(enemy, by: runner)
            }
        }

        // Explosive barrels caught in the grenade's blast go up too — checked
        // AFTER the direct blast resolves so the log reads throw → hits →
        // secondary explosions. One pass, no chaining (see detonateBarrelsNear).
        detonateBarrelsNear(impactTiles: [(x: primary.positionX, y: primary.positionY)])

        if livingEnemies.isEmpty {
            onRoomCleared()
        }
        completeAction(for: runner)
        return true
    }

    /// Decker HACK: Disables target enemy for 1 round (0 attack dice, can't move).
    /// Uses LOG + spellcasting (hacking is logic-based in HexWire).
    func performHack() {
        CombatFlowController.performHack(gameState: self)
    }

    func performHackOnTarget(_ target: Enemy, by decker: Character) {
        // Hack pool: LOG + INT (matrix intrusion)
        let hackPool = decker.attributes.log + decker.attributes.int
        let hackRoll = DiceEngine.roll(pool: hackPool)

        decker.currentMana -= 2
        HapticsManager.shared.attackHit()

        if hackRoll.criticalGlitch {
            let drain = 4
            decker.takeDamage(amount: drain)
            addLog("💥 CRITICAL GLITCH! ICE counterattacks! \(decker.name) takes \(drain) dmg!")
            HapticsManager.shared.playerDamaged()
            NotificationCenter.default.post(name: .characterHit, object: nil, userInfo: ["characterId": decker.id.uuidString, "damage": drain])
            if !decker.isAlive { CombatFlowController.handlePlayerKilled(gameState: self, char: decker) }
            completeAction(for: decker)
            return
        }
        if hackRoll.glitch || hackRoll.hits == 0 {
            addLog("⚠️ GLITCH! \(decker.name)'s intrusion fails — ICE detected!")
            completeAction(for: decker)
            return
        }

        // Opposed resist: the target's firewall/will pushes back. Bosses run
        // hardened ICE (+2). This stops the old "guaranteed stun-lock any enemy,
        // even a boss, every round" exploit — high-WIL targets can shrug it off.
        let isBoss = target.archetype.lowercased().hasPrefix("boss")
        let firewall = target.attributes.wil + (isBoss ? 2 : 0)
        let resistRoll = DiceEngine.roll(pool: max(1, firewall))
        guard hackRoll.hits > resistRoll.hits else {
            addLog("🛡 \(target.name) RESISTS the intrusion! [\(hackPool)→\(hackRoll.hits) vs firewall \(firewall)→\(resistRoll.hits)]")
            // Clear failed-action feedback so the player understands WHY the
            // hack didn't land (it's an opposed roll now, not guaranteed).
            postTransientWarning("🛡 \(target.name) RESISTS THE HACK", duration: 1.8)
            SFXManager.shared.play("armor_block")
            HapticsManager.shared.error()
            TutorialCoach.shared.enqueue(.hackResisted)   // first resist explains hardened ICE
            NotificationCenter.default.post(name: .enemyHit, object: nil, userInfo: ["enemyId": target.id.uuidString, "damage": 0])
            completeAction(for: decker)
            return
        }

        // Disable enemy for one turn: `.stunned` makes them skip their next
        // action, then runEnemyAI auto-recovers them to `.wounded` (a clean
        // 1-turn lock). The opposed resist above is what keeps this from being
        // an unconditional every-round stun-lock.
        target.status = .stunned
        addLog("💻 \(decker.name) HACKS \(target.name)! [\(hackPool)→\(hackRoll.hits) vs \(resistRoll.hits)] — SYSTEM DISABLED!")
        NotificationCenter.default.post(name: .enemyHit, object: nil, userInfo: ["enemyId": target.id.uuidString, "damage": 0])
        // Visual: stream of binary glyphs from decker to target + circuit
        // breach flash on impact.
        NotificationCenter.default.post(
            name: .hackEffect, object: nil,
            userInfo: ["fromX": decker.positionX, "fromY": decker.positionY,
                       "toX": target.positionX, "toY": target.positionY,
                       "targetId": target.id.uuidString]
        )
        completeAction(for: decker)
    }

    /// Face INTIMIDATE: Reduce all living enemies' effective attack this round.
    /// Uses CHA + skills. All enemies get -2 dice to their next attack.
    func performIntimidate() {
        CombatFlowController.performIntimidate(gameState: self)
    }

    /// Street Sam BLITZ: High-damage melee charge attack. Uses BOD+STR.
    /// More powerful than normal attack but costs extra (BOD damage risk).
    func performBlitz() {
        CombatFlowController.performBlitz(gameState: self)
    }

    /// Apply Blitz damage to a single target. Does NOT advance the turn — the
    /// caller (`performBlitz`) does that ONCE after all adjacent targets are
    /// hit, so a multi-target sweep doesn't fire `completeAction` N times.
    func performBlitzOnTarget(_ target: Enemy, by sam: Character) {
        // Blitz pool: BOD + STR + blades skill (raw power charge)
        let blitzPool = sam.attributes.bod + sam.attributes.str + sam.skills.blades
        let attackRoll = DiceEngine.roll(pool: blitzPool)
        HapticsManager.shared.attackHit()

        if attackRoll.criticalGlitch {
            let selfDmg = 3
            sam.takeDamage(amount: selfDmg)
            addLog("💥 CRITICAL GLITCH! \(sam.name) stumbles — \(selfDmg) self-damage!")
            HapticsManager.shared.playerDamaged()
            NotificationCenter.default.post(name: .characterHit, object: nil, userInfo: ["characterId": sam.id.uuidString, "damage": selfDmg])
            if !sam.isAlive { CombatFlowController.handlePlayerKilled(gameState: self, char: sam) }
            return
        }

        // Hacked / stunned enemies can't dodge a Blitz — pool collapses to 0.
        // Defenders get a real reaction pool against a charge — REA+AGI, not
        // the old REA-only / 0-on-stun collapse that made Blitz a guaranteed
        // delete button. A stunned target still defends, just sluggishly (AGI
        // only, no reactions), so hack→Blitz combos are strong but not free.
        let defensePool = (target.status == .stunned)
            ? max(1, target.attributes.agi)
            : max(1, target.attributes.rea + target.attributes.agi)
        let defenseRoll = DiceEngine.roll(pool: defensePool)
        let netHits = max(0, attackRoll.hits - defenseRoll.hits)

        // Blitz deals high physical damage: base 6 + net hits (was 8 — the
        // raw base plus the easy net hits made it eclipse the normal attack).
        let baseDmg = 6 + netHits
        let soakPool = max(0, target.computeDerived().soak - 2)  // -2 AP for charge force
        let soakRoll = DiceEngine.roll(pool: soakPool)
        let finalDmg = max(1, baseDmg - soakRoll.hits)

        target.takeDamage(amount: finalDmg, isStun: false)
        addLog("⚡ \(sam.name) BLITZ → \(target.name)! [\(blitzPool)d6→\(attackRoll.hits)] \(baseDmg)P - \(soakRoll.hits)soak = \(finalDmg) dmg! (\(target.currentHP)/\(target.maxHP))")
        NotificationCenter.default.post(name: .enemyHit, object: nil, userInfo: ["enemyId": target.id.uuidString, "damage": finalDmg])

        // KNOCKDOWN: a decisive hit (net hits ≥ 3) in the sweep bowls the
        // survivor off their feet. Prone lasts until the round tick — they
        // can't reposition, they defend at -2 dice (see performAttack /
        // Character.defensePool), and their AI turn is spent fighting from
        // the ground. Only survivors get the status (a corpse can't be
        // "knocked down"), and it doesn't re-stack on an already-prone target.
        if target.isAlive && netHits >= 3 && !target.statusEffects.contains(.prone) {
            target.statusEffects.append(.prone)
            proneInflictedRound[target.id] = roundNumber
            addLog("  🔻 \(target.name) is bowled off their feet — PRONE!")
        }

        if !target.isAlive {
            HapticsManager.shared.enemyKilled()
            missionEnemiesDefeated += 1
            CombatFlowController.handleEnemyKillForRoomEffects(gameState: self)
            let bounty = MissionStatsStore.killBounty(maxHP: target.maxHP)
            MissionStatsStore.shared.awardKillNuyen(maxHP: target.maxHP)
            addLog("☠️ \(target.name) DOWN! +\(target.maxHP / 2) XP · +¥\(bounty)")
            generateLoot(by: sam)
            let leveledUp = sam.gainXP(target.maxHP / 2)
            if leveledUp {
                HapticsManager.shared.levelUp()
                addLog("🎖️ LEVEL UP! \(sam.name) → Level \(sam.level)!")
                NotificationCenter.default.post(name: .characterLevelUp, object: nil, userInfo: ["characterId": sam.id.uuidString])
            }
            NotificationCenter.default.post(name: .enemyDied, object: nil, userInfo: ["enemyId": target.id.uuidString])
        }
    }

    /// Move a character to a new tile position (called from BattleScene on player tap).
    /// Movement is a FREE action — does NOT consume the turn.
    /// The player can still act (attack, defend, spell, item) after moving.
    func moveCharacter(id: UUID, toTileX tileX: Int, toTileY tileY: Int) {
        CombatFlowController.moveCharacter(gameState: self, id: id, toTileX: tileX, toTileY: tileY)
    }

    func showItemMenu() {
        CombatFlowController.showItemMenu(gameState: self)
    }

    func completeAction(for character: Character) {
        CombatFlowController.completeAction(gameState: self, for: character)
    }

    /// Enter overwatch: lock in the character's attack pool as a reaction trigger.
    /// Any enemy that moves into LOS of this character before their next turn
    /// will be automatically attacked (halved net hits — reaction fire penalty).
    func performOverwatch() {
        guard CombatFlowController.canAcceptPlayerAction(gameState: self) else { return }
        guard let a = activeCharacter ?? currentCharacter else { return }
        let ovwPool = a.attackPool(skill: .firearms)
        overwatchers[a.id] = ovwPool
        addLog("🎯 \(a.name) ENTERS OVERWATCH — holding fire on any movement.")
        NotificationCenter.default.post(name: .characterOverwatch, object: nil, userInfo: ["characterId": a.id.uuidString])
        completeAction(for: a)
    }

    /// Fire an overwatch shot at a moving enemy. Called from runEnemyAI just before
    /// each enemy movement step. Returns the number of shots fired (0 or 1 per overwatcher).
    /// One reaction shot per Overwatch action: the entry is consumed when the shot
    /// resolves (fumble/miss/dodge included), not at round end.
    ///
    /// Discardable: every AI call site fires this for its side effects (the shot
    /// resolving) and has no use for the count, which was generating 18 identical
    /// unused-result warnings and burying the real ones.
    @discardableResult
    func fireOverwatchShot(atEnemy enemy: Enemy, attackerId: UUID) -> Int {
        guard let ovwPool = overwatchers[attackerId] else { return 0 }
        // Only fire if enemy is in LOS with no wall blocking
        guard let attacker = playerTeam.first(where: { $0.id == attackerId }) else { return 0 }
        // Don't waste the (now-consumed-on-fire) overwatch on a corpse — when
        // several runners overwatch the same mover, the first kill must leave
        // the others' shots armed. Likewise a runner downed earlier in the
        // phase can't fire from the floor.
        guard enemy.isAlive, attacker.isAlive else { return 0 }
        if isLineBlockedByWall(fromX: attacker.positionX, fromY: attacker.positionY,
                               toX: enemy.positionX, toY: enemy.positionY) { return 0 }

        // The shot is happening — consume the overwatch and drop this runner's marker.
        overwatchers.removeValue(forKey: attackerId)
        NotificationCenter.default.post(name: .overwatchExpired, object: nil,
                                        userInfo: ["characterId": attackerId.uuidString])

        // Overwatch is reaction *fire* (firearms pool) — a melee loadout falls
        // back to the holdout sidearm instead of somehow throwing a katana.
        var weapon = attacker.equippedWeapon ?? Weapon(name: "Sidearm", type: .pistol, damage: 4, accuracy: 4, armorPiercing: 1)
        if weapon.type == .blade || weapon.type == .unarmed {
            weapon = Weapon(name: "Sidearm", type: .pistol, damage: 4, accuracy: 4, armorPiercing: 1)
        }

        // Tracer + muzzle flash + gunshot SFX — same payload as a deliberate shot.
        NotificationCenter.default.post(
            name: .gunfireEffect, object: nil,
            userInfo: ["fromX": attacker.positionX, "fromY": attacker.positionY,
                       "toX": enemy.positionX, "toY": enemy.positionY,
                       "weaponType": weapon.type.rawValue,
                       "attackerId": attacker.id.uuidString]
        )

        let attackRoll = DiceEngine.roll(pool: ovwPool)
        if attackRoll.criticalGlitch {
            addLog("💥 \(attacker.name) OVERWATCH fumble!")
            attacker.takeDamage(amount: 2)
            return 1
        }
        if attackRoll.glitch || attackRoll.hits == 0 {
            addLog("⚠️ \(attacker.name) OVERWATCH misses!")
            NotificationCenter.default.post(name: .enemyHit, object: nil, userInfo: ["enemyId": enemy.id.uuidString, "damage": 0, "outcome": "miss"])
            return 1
        }
        // Reaction fire: halved net hits (surprise penalty but not a full ambush)
        let defensePool = enemy.attributes.rea + enemy.attributes.agi
        let defenseRoll = DiceEngine.roll(pool: defensePool)
        let netHits = max(0, attackRoll.hits - defenseRoll.hits) / 2
        if netHits == 0 {
            addLog("→ \(attacker.name) OVERWATCH fires at \(enemy.name) — DODGED!")
            NotificationCenter.default.post(name: .enemyHit, object: nil, userInfo: ["enemyId": enemy.id.uuidString, "damage": 0, "outcome": "miss"])
            return 1
        }
        // Ranged falloff — same rule as a deliberate shot: damage drops past
        // the weapon's effective range, capped at -3, floored at 1.
        let effectiveRange: Int
        switch weapon.type {
        case .pistol:          effectiveRange = 3
        case .smg:             effectiveRange = 5
        case .rifle:           effectiveRange = 8
        case .blade, .unarmed: effectiveRange = 99
        }
        let ovwDistance = hexDistance(x1: attacker.positionX, y1: attacker.positionY,
                                      x2: enemy.positionX, y2: enemy.positionY)
        let ovwRangePenalty = min(3, max(0, ovwDistance - effectiveRange))
        let baseDmg = max(1, weapon.damage + netHits - ovwRangePenalty)
        let soakPool = max(0, enemy.computeDerived().soak - weapon.armorPiercing)
        let soakRoll = DiceEngine.roll(pool: soakPool)
        let finalDmg = max(0, baseDmg - soakRoll.hits)
        enemy.takeDamage(amount: finalDmg, isStun: weapon.isStunDamage)
        addLog("⚡ \(attacker.name) OVERWATCH → \(enemy.name)! \(netHits) net hits → \(finalDmg) dmg. (\(enemy.currentHP)/\(enemy.maxHP) HP)")
        NotificationCenter.default.post(name: .enemyHit, object: nil, userInfo: ["enemyId": enemy.id.uuidString, "damage": finalDmg, "outcome": finalDmg > 0 ? "hit" : "soak", "impactDelay": 0.15])
        if !enemy.isAlive {
            HapticsManager.shared.enemyKilled()
            missionEnemiesDefeated += 1
            CombatFlowController.handleEnemyKillForRoomEffects(gameState: self)
            let bounty = MissionStatsStore.killBounty(maxHP: enemy.maxHP)
            MissionStatsStore.shared.awardKillNuyen(maxHP: enemy.maxHP)
            addLog("☠️ \(enemy.name) DOWN from OVERWATCH! +¥\(bounty)")
            NotificationCenter.default.post(name: .enemyDied, object: nil, userInfo: ["enemyId": enemy.id.uuidString])
        }
        return 1
    }

    // MARK: - Log

    func addLog(_ entry: String) {
        // combatLog is @Published — mutating it already fires objectWillChange.
        // (An extra manual send() here doubled every HUD invalidation per log line.)
        combatLog.append(entry)
        if combatLog.count > 50 { combatLog.removeFirst() }

        // Play UI error chirp on user-facing failure messages. We detect by
        // prefix/keyword so call sites stay terse — anything starting with
        // these tokens is treated as a "you can't do that" feedback event.
        // Glitches (⚠️/💥) are gameplay events with their own SFX, so excluded.
        if SFXClassifier.isLockedDoor(entry) {
            // Door-specific buzzy refusal — checked BEFORE generic error so
            // it doesn't get masked by the broader "Move closer" matcher.
            SFXManager.shared.play("door_locked")
        } else if SFXClassifier.isUserError(entry) {
            HapticsManager.shared.error()
        } else if SFXClassifier.isUnlock(entry) {
            HapticsManager.shared.unlock()
        }
    }
}

// MARK: - Combat-Depth Notification Names
// Declared here rather than in GameNotifications.swift to keep this feature's
// surface inside the combat-owned files; same Notification.Name namespace.
extension Notification.Name {
    /// A COVER tile just converted to floor mid-combat (barrel detonation or
    /// splintered crate). userInfo: ["tiles": [["x": Int, "y": Int]]] — same
    /// payload shape as .barriersDropped so BattleScene can reuse the exact
    /// fade-out + sampled-floor-patch redraw pass for both.
    static let coverTileDestroyed = Notification.Name("coverTileDestroyed")
}

/// Helper for classifying combat-log entries so SFX can fire from a single
/// place (addLog) rather than at every error site.
@MainActor
enum SFXClassifier {
    static func isUserError(_ entry: String) -> Bool {
        // Prefixes / keywords that indicate "you can't do that" feedback.
        let triggers = [
            "No target", "No targets",
            "No character",
            "Not enough",
            "Only the ",     // "Only the Face can intimidate", etc.
            "already moved", "already attacked",
            "Move adjacent", "Move closer",
            "Out of ",
            "Invalid target",
            "Cannot move",
            "⛔",            // line-of-sight-blocked emoji prefix
        ]
        return triggers.contains { entry.contains($0) }
    }

    static func isUnlock(_ entry: String) -> Bool {
        // Door / terminal / objective unlocks.
        return entry.contains("Door unlocked") ||
               entry.contains("data acquired") ||
               entry.contains("Terminal hacked")
    }

    static func isLockedDoor(_ entry: String) -> Bool {
        // Player tried to use a still-locked door.
        return entry.contains("Use the marked door tile") ||
               entry.contains("Cannot move onto a door tile") ||
               entry.contains("Move closer to the door first")
    }
}

// MARK: - Game Phase

/// Game state machine managing all major game states and transitions
enum GamePhase: Equatable {
    case title
    case prologue            // Pre-M1 "Neon Lotus" VN-style recruit cinematic
    case missionSelect
    case missionIntro        // Per-mission pre-briefing VN cutscene (M1-M6)
    case briefing
    case combat
    case missionOutro        // Per-mission post-combat VN cutscene (M1-M6) — plays before debrief on victory
    case dropIntro           // M3.5 pre-chase VN cinematic (runners exiting M3, boarding bike)
    case hoverbikeChase      // M3.5 "The Drop" — side-scrolling chase mission
    case basementBrawl       // M4.5 "Basement Brawl" — Raze solo side-on melee duel
    case mirrorline          // M2.5 "Mirrorline" — Sable solo astral sigil-tracing
    case coldTrace           // M5.5 "Cold Trace" — Cipher solo matrix-dive process-triage
    case debrief
    case gameEnding          // Post-M6-victory ending cutscene (epilogue + AI-seed coda)

    var displayName: String {
        switch self {
        case .title:           return "Title"
        case .prologue:        return "Prologue"
        case .missionSelect:   return "Mission Select"
        case .missionIntro:    return "Mission Intro"
        case .briefing:        return "Briefing"
        case .combat:          return "Combat"
        case .missionOutro:    return "Mission Outro"
        case .dropIntro:       return "The Drop — Intro"
        case .hoverbikeChase:  return "The Drop"
        case .basementBrawl:   return "Basement Brawl"
        case .mirrorline:      return "Mirrorline"
        case .coldTrace:       return "Cold Trace"
        case .debrief:         return "Debrief"
        case .gameEnding:      return "Endless Rain"
        }
    }
}

// MARK: - State Transition Event

enum StateTransition {
    case startGame
    case viewPrologue          // Title → Prologue (Neon Lotus recruit scene)
    case finishPrologue        // Prologue → Title (loops back, doesn't auto-start M1)
    case viewMissionIntro      // MissionSelect → MissionIntro (per-mission cutscene)
    case finishMissionIntro    // MissionIntro → Briefing (mission-specific cutscene done)
    case viewDropIntro         // MissionSelect → DropIntro (M3.5 cutscene)
    case finishDropIntro       // DropIntro → HoverbikeChase (auto-into the chase)
    case viewHoverbikeChase    // MissionSelect → HoverbikeChase (skip intro)
    case finishHoverbikeChase  // HoverbikeChase → MissionSelect (legacy/abort path)
    case endChase(won: Bool)   // HoverbikeChase → MissionOutro on win, Debrief on loss
    case viewBasementBrawl     // MissionIntro → BasementBrawl (M4.5 gameplay)
    case endBrawl(won: Bool)   // BasementBrawl → MissionOutro on win, Debrief on loss
    case viewMirrorline        // MissionIntro → Mirrorline (M2.5 gameplay)
    case endMirrorline(won: Bool)  // Mirrorline → MissionOutro on win, Debrief on loss
    case viewColdTrace         // MissionIntro → ColdTrace (M5.5 gameplay)
    case endColdTrace(won: Bool)  // ColdTrace → MissionOutro on win, Debrief on loss
    case selectMission(String)
    case beginMission
    case startCombat
    case endCombat(won: Bool)
    case viewMissionOutro      // Combat → MissionOutro (post-combat cutscene on victory)
    case finishMissionOutro    // MissionOutro → Debrief (outro done, go score the mission)
    case viewGameEnding        // Debrief → GameEnding (only after M6 victory)
    case finishGameEnding      // GameEnding → Title (epilogue done, return to title)
    case viewDebrief
    case returnToTitle
    case exitGame
}

// `GameStateManager` (legacy phase manager) was removed 2026-05 — was
// declared "for compatibility" but had zero call sites. `PhaseManager` in
// HexwireApp.swift is the canonical phase-flow authority.

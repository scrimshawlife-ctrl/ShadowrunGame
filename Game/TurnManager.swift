import Foundation

// MARK: - Turn Order Entry

struct TurnEntry: Identifiable, Equatable {
    let id: UUID
    let characterId: UUID
    let name: String
    let isPlayer: Bool
    var initiative: Int
    var hasActed: Bool = false

    static func == (lhs: TurnEntry, rhs: TurnEntry) -> Bool {
        lhs.id == rhs.id && lhs.initiative == rhs.initiative
    }
}

// MARK: - Combat Action

enum CombatAction: Equatable {
    case attack(skill: SkillKey, targetId: UUID)
    case defend
    case castSpell(spell: String, targetId: UUID)
    case useItem(itemId: UUID, targetId: UUID)
    case overwatch(targetId: UUID?)
    case endTurn

    var displayName: String {
        switch self {
        case .attack:          return "Attack"
        case .defend:           return "Defend"
        case .castSpell:        return "Cast Spell"
        case .useItem:          return "Use Item"
        case .overwatch:        return "Overwatch"
        case .endTurn:          return "End Turn"
        }
    }
}

// MARK: - Turn Manager

/// Manages initiative, turn ordering, and action tracking during combat
@MainActor
final class TurnManager: ObservableObject {

    @Published private(set) var turnOrder: [TurnEntry] = []
    @Published private(set) var currentTurnIndex: Int = 0
    @Published private(set) var roundNumber: Int = 1
    @Published private(set) var isCombatActive: Bool = false

    private var playerCharacters: [Character] = []
    private var enemyCharacters: [Enemy] = []

    // MARK: - Start Combat

    /// Begin combat: roll initiative for all participants
    func startCombat(playerTeam: [Character], enemies: [Enemy]) {
        self.playerCharacters = playerTeam
        self.enemyCharacters = enemies
        self.roundNumber = 1
        self.currentTurnIndex = 0
        self.isCombatActive = true

        rollAllInitiative()

        // Sort descending by initiative
        turnOrder.sort { $0.initiative > $1.initiative }
    }

    private func rollAllInitiative() {
        turnOrder.removeAll()

        // Player characters
        for char in playerCharacters {
            // + cyberInitiative so Wired Reflexes / Synaptic Booster actually
            // move the runner earlier in the order.
            let roll = DiceEngine.rollInitiative(rea: char.attributes.rea, int: char.attributes.int) + char.cyberInitiative
            char.initiativeRoll = roll
            turnOrder.append(TurnEntry(
                id: UUID(),
                characterId: char.id,
                name: char.name,
                isPlayer: true,
                initiative: roll
            ))
        }

        // Enemies
        for enemy in enemyCharacters {
            let roll = DiceEngine.rollInitiative(rea: enemy.attributes.rea, int: enemy.attributes.int)
            enemy.initiativeRoll = roll
            turnOrder.append(TurnEntry(
                id: UUID(),
                characterId: enemy.id,
                name: enemy.name,
                isPlayer: false,
                initiative: roll
            ))
        }
    }

    // MARK: - Turn Progression

    /// Advance to next turn
    func advanceTurn() {
        currentTurnIndex += 1

        // Check if round ended
        if currentTurnIndex >= turnOrder.count {
            roundNumber += 1
            currentTurnIndex = 0
            resetRoundActions()
        }
    }

    /// End current actor's turn and advance
    func endCurrentTurn() {
        if currentTurnIndex < turnOrder.count {
            turnOrder[currentTurnIndex].hasActed = true
        }
        advanceTurn()
    }

    // MARK: - Shared Runtime Turn Ownership

    /// Canonical turn-advance owner for runtime combat flow.
    /// UI/render/request layers should route turn advancement through this entrypoint.
    static func requestTurnAdvance(gameState: GameState) {
        TurnManager.endTurn(gameState: gameState)
    }

    private static func endTurn(gameState: GameState) {
        CombatFlowController.endTurn(gameState: gameState)
    }

    private func resetRoundActions() {
        for i in 0..<turnOrder.count {
            turnOrder[i].hasActed = false
        }
    }

    // MARK: - Query

    var currentActor: TurnEntry? {
        guard isCombatActive, currentTurnIndex < turnOrder.count else { return nil }
        return turnOrder[currentTurnIndex]
    }

    var currentIsPlayerTurn: Bool {
        currentActor?.isPlayer ?? false
    }

    var upcomingActors: [TurnEntry] {
        guard isCombatActive else { return [] }
        let nextIdx = (currentTurnIndex + 1) % turnOrder.count
        let next = turnOrder[nextIdx]
        let after = turnOrder[(nextIdx + 1) % turnOrder.count]
        return [next, after]
    }

    var allActors: [TurnEntry] {
        turnOrder
    }

    var livingPlayers: [Character] {
        playerCharacters.filter { $0.isAlive }
    }

    var livingEnemies: [Enemy] {
        enemyCharacters.filter { $0.isAlive }
    }

    var isCombatOver: Bool {
        !isCombatActive || livingPlayers.isEmpty || livingEnemies.isEmpty
    }

    var playerTeamWon: Bool {
        isCombatOver && !livingPlayers.isEmpty && livingEnemies.isEmpty
    }

    // MARK: - Character Lookup

    func playerCharacter(withId id: UUID) -> Character? {
        playerCharacters.first { $0.id == id }
    }

    func character(withId id: UUID) -> (isPlayer: Bool, character: AnyObject)? {
        if let player = playerCharacters.first(where: { $0.id == id }) {
            return (true, player)
        }
        if let enemy = enemyCharacters.first(where: { $0.id == id }) {
            return (false, enemy)
        }
        return nil
    }

    // MARK: - Reorder (for ties, etc.)

    /// Reroll initiative for a specific character (e.g., after delay)
    func rerollInitiative(forCharacterId id: UUID) {
        if let idx = turnOrder.firstIndex(where: { $0.characterId == id }) {
            if let char = playerCharacters.first(where: { $0.id == id }) {
                let roll = DiceEngine.rollInitiative(rea: char.attributes.rea, int: char.attributes.int)
                char.initiativeRoll = roll
                turnOrder[idx].initiative = roll
            }
            turnOrder.sort { $0.initiative > $1.initiative }
        }
    }

    // MARK: - End Combat

    func endCombat() {
        isCombatActive = false
    }

    func cleanup() {
        turnOrder.removeAll()
        currentTurnIndex = 0
        roundNumber = 1
        isCombatActive = false
    }
}

// MARK: - Enemy (simplified companion to Character)

final class Enemy: ObservableObject, Identifiable, Codable {
    let id: UUID
    var name: String
    var archetype: String  // e.g., "guard", "drone", "elite", "mage"

    @Published var attributes: AttributeSet
    @Published var equippedWeapon: Weapon?
    @Published var equippedArmor: Armor?

    @Published var currentHP: Int
    var maxHP: Int   // var (not let) so NG+ scaling can boost enemy durability

    // Stun damage track (WIL/2+8). Overflow goes to physical.
    @Published var currentStun: Int = 0
    var maxStun: Int { Int(ceil(Double(attributes.wil) / 2.0)) + 8 }

    @Published var positionX: Int = 0
    @Published var positionY: Int = 0

    @Published var status: StatusEffect = .wounded
    /// Active timed status effects (burning, marked, confused).
    @Published var statusEffects: [StatusEffect] = []

    var initiativeRoll: Int = 0

    /// Maximum tiles this enemy can reposition before attempting to attack.
    /// Used by non-drone enemy AI to enforce a move-then-attack economy.
    /// Spider drones move 3 (fast harasser); riot troopers and combat mechs
    /// move 1 (heavy/slow); everyone else uses the default 2.
    var moveRange: Int {
        switch archetype.lowercased() {
        case "turret":      return 0   // bolted down — never repositions
        case "spider", "infiltrator": return 3   // fast flankers
        case "riot", "mech", "juggernaut": return 1   // heavy/slow walls
        // Playtest 2026-07-25: at 2 tiles the mech spent the whole fight walking
        // and never got a shot off — the party out-ranged it and killed it on the
        // approach. 3 lets it actually reach a firing position.
        case "bossmech":    return 3   // boss-class mech advances faster than the regular grunt mech
        case "bossagi":     return 3   // AGI phase-shifts — moves 3 tiles per turn
        case "bossmage":    return 3   // Sato glides fast — closes on the party instead of planting at range (playtest: "doesn't move much")
        default:            return 2
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, archetype, attributes
        case equippedWeapon, equippedArmor
        case currentHP, maxHP, currentStun
        case positionX, positionY, status, statusEffects
    }

    init(id: UUID = UUID(), name: String, archetype: String,
         attributes: AttributeSet,
         weapon: Weapon?, armor: Armor?,
         maxHP: Int) {
        self.id = id
        self.name = name
        self.archetype = archetype
        self.attributes = attributes
        self.equippedWeapon = weapon
        self.equippedArmor = armor
        self.currentHP = maxHP
        self.maxHP = maxHP
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        archetype = try container.decode(String.self, forKey: .archetype)
        attributes = try container.decode(AttributeSet.self, forKey: .attributes)
        equippedWeapon = try container.decodeIfPresent(Weapon.self, forKey: .equippedWeapon)
        equippedArmor = try container.decodeIfPresent(Armor.self, forKey: .equippedArmor)
        currentHP = try container.decode(Int.self, forKey: .currentHP)
        maxHP = try container.decode(Int.self, forKey: .maxHP)
        positionX = try container.decode(Int.self, forKey: .positionX)
        positionY = try container.decode(Int.self, forKey: .positionY)
        status = try container.decode(StatusEffect.self, forKey: .status)
        statusEffects = try container.decodeIfPresent([StatusEffect].self, forKey: .statusEffects) ?? []
        // decodeIfPresent: older saves lack the key. Without persisting this,
        // a save/load wiped enemy stun progress — and an enemy saved
        // .stunned reloaded with an empty track, instantly recovering.
        currentStun = try container.decodeIfPresent(Int.self, forKey: .currentStun) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(archetype, forKey: .archetype)
        try container.encode(attributes, forKey: .attributes)
        try container.encode(equippedWeapon, forKey: .equippedWeapon)
        try container.encode(equippedArmor, forKey: .equippedArmor)
        try container.encode(currentHP, forKey: .currentHP)
        try container.encode(maxHP, forKey: .maxHP)
        try container.encode(currentStun, forKey: .currentStun)
        try container.encode(positionX, forKey: .positionX)
        try container.encode(positionY, forKey: .positionY)
        try container.encode(status, forKey: .status)
        try container.encode(statusEffects, forKey: .statusEffects)
    }

    var isAlive: Bool { status != .dead && currentHP > 0 }

    func computeDerived() -> DerivedStats {
        let soak = attributes.bod + (equippedArmor?.armorValue ?? 0)
        let spellDefense = attributes.wil + attributes.bod
        return DerivedStats(initiative: 0, soak: soak, spellDefense: spellDefense)
    }

    /// Apply damage. isStun=true uses the Stun track; overflow goes to Physical.
    func takeDamage(amount: Int, isStun: Bool = false) {
        if isStun {
            let stunSpace = max(0, maxStun - currentStun)
            let stunApplied = min(amount, stunSpace)
            let overflow = amount - stunApplied
            currentStun += stunApplied
            if overflow > 0 {
                currentHP = max(0, currentHP - overflow)
            }
        } else {
            currentHP = max(0, currentHP - amount)
        }
        if currentHP <= 0 { status = .dead }
        else if currentStun >= maxStun { status = .stunned }
    }

    // MARK: - Pre-built Enemies

    static func corpGuard() -> Enemy {
        var attrs = AttributeSet.zero
        attrs.bod = 3; attrs.agi = 3; attrs.rea = 3; attrs.str = 3
        attrs.cha = 2; attrs.int = 2; attrs.log = 2; attrs.wil = 2

        let weapon = Weapon(name: "Pistol", type: .pistol, damage: 4, accuracy: 4, armorPiercing: 1)
        let armor = Armor(name: "Light Armor", armorValue: 2, spellPenalty: 0)

        return Enemy(name: "Corp Guard", archetype: "guard",
                     attributes: attrs, weapon: weapon, armor: armor, maxHP: 18)
    }

    static func securityDrone() -> Enemy {
        var attrs = AttributeSet.zero
        // Tuned 2026-05: REA 5→4→3, AGI 4→3. Drones were the worst offender
        // for miss rates; even 9-die player attacks were missing ~50%.
        // New defense pool (REA+AGI = 6d → 2.4 hits) puts drones in line
        // with corp guards rather than as an evasion outlier.
        attrs.bod = 4; attrs.agi = 3; attrs.rea = 3; attrs.str = 2
        attrs.cha = 0; attrs.int = 3; attrs.log = 1; attrs.wil = 1

        let weapon = Weapon(name: "SMG", type: .smg, damage: 5, accuracy: 4, armorPiercing: 1)
        return Enemy(name: "Security Drone", archetype: "drone",
                     attributes: attrs, weapon: weapon, armor: nil, maxHP: 14)
    }

    static func eliteGuard() -> Enemy {
        var attrs = AttributeSet.zero
        // Tuned 2026-05: REA 4→3. Old defense pool 8d → 3.2 hits made
        // Elites near-impossible to land net hits on with a 9-die attacker.
        // New defense 7d → 2.8 keeps them tougher than Corp Guards (6d) but
        // beatable by skilled shooters.
        attrs.bod = 5; attrs.agi = 4; attrs.rea = 3; attrs.str = 4
        attrs.cha = 2; attrs.int = 3; attrs.log = 2; attrs.wil = 3

        let weapon = Weapon(name: "Assault Rifle", type: .rifle, damage: 7, accuracy: 4, armorPiercing: 2)
        let armor = Armor(name: "Medium Armor", armorValue: 4, spellPenalty: -1)

        return Enemy(name: "Elite Guard", archetype: "elite",
                     attributes: attrs, weapon: weapon, armor: armor, maxHP: 28)
    }

    static func corpMage() -> Enemy {
        var attrs = AttributeSet.zero
        attrs.bod = 3; attrs.agi = 3; attrs.rea = 3; attrs.str = 2
        attrs.cha = 3; attrs.int = 4; attrs.log = 5; attrs.wil = 5

        let weapon = Weapon(name: "Stunball", type: .unarmed, damage: 6, accuracy: 4, armorPiercing: 0)
        let armor = Armor(name: "Light Armor", armorValue: 2, spellPenalty: 0)

        return Enemy(name: "Corp Mage", archetype: "mage",
                     attributes: attrs, weapon: weapon, armor: armor, maxHP: 16)
    }

    /// **Boss Mage** — M3 finale boss. Blood mage "Sato" — taller scale,
    /// 3x the HP of a regular corp mage, hits harder, casts at longer range.
    /// Sprite key is `bossmage` (falls back to corpmage frames at boss scale).
    static func bossMage() -> Enemy {
        var attrs = AttributeSet.zero
        attrs.bod = 5; attrs.agi = 4; attrs.rea = 4; attrs.str = 3
        attrs.cha = 5; attrs.int = 5; attrs.log = 6; attrs.wil = 7

        // Bigger, scarier spell: harder hitting Bloodbolt with AP.
        // stunOverride: the .unarmed delivery would otherwise infer STUN —
        // a blood mage's signature nuke is decidedly lethal.
        var weapon = Weapon(name: "Bloodbolt",  type: .unarmed,
                            damage: 9, accuracy: 6, armorPiercing: 2)
        weapon.stunOverride = false
        let armor = Armor(name: "Ritual Wardplate", armorValue: 3, spellPenalty: 0)

        return Enemy(name: "Sato", archetype: "bossmage",
                     attributes: attrs, weapon: weapon, armor: armor, maxHP: 48)
    }

    static func medic() -> Enemy {
        var attrs = AttributeSet.zero
        attrs.bod = 3; attrs.agi = 3; attrs.rea = 4; attrs.str = 2
        attrs.cha = 4; attrs.int = 4; attrs.log = 5; attrs.wil = 4

        let weapon = Weapon(name: "Medkit", type: .unarmed, damage: 4, accuracy: 3, armorPiercing: 0)
        let armor = Armor(name: "Light Armor", armorValue: 2, spellPenalty: 0)

        return Enemy(name: "Street Medic", archetype: "healer",
                     attributes: attrs, weapon: weapon, armor: armor, maxHP: 20)
    }

    static func combatMech() -> Enemy {
        var attrs = AttributeSet.zero
        attrs.bod = 7; attrs.agi = 3; attrs.rea = 2; attrs.str = 6
        attrs.cha = 0; attrs.int = 2; attrs.log = 2; attrs.wil = 3

        let weapon = Weapon(name: "Autocannon", type: .rifle, damage: 8, accuracy: 3, armorPiercing: 3)
        let armor = Armor(name: "Mech Plating", armorValue: 5, spellPenalty: -2)

        return Enemy(name: "Combat Mech", archetype: "mech",
                     attributes: attrs, weapon: weapon, armor: armor, maxHP: 34)
    }

    /// **Boss Mech** — M5 finale boss. Heavier armor + 2.5× HP + slightly
    /// punchier weapon. Spawns via `bossSpawn` after r2 regulars are cleared.
    static func bossMech() -> Enemy {
        var attrs = AttributeSet.zero
        attrs.bod = 9; attrs.agi = 3; attrs.rea = 2; attrs.str = 8
        attrs.cha = 0; attrs.int = 2; attrs.log = 2; attrs.wil = 4

        let weapon = Weapon(name: "Heavy Autocannon", type: .rifle,
                            damage: 10, accuracy: 4, armorPiercing: 4)
        let armor = Armor(name: "Heavy Mech Plating", armorValue: 7, spellPenalty: -3)

        return Enemy(name: "MEKTON-7", archetype: "bossmech",
                     attributes: attrs, weapon: weapon, armor: armor, maxHP: 80)
    }

    /// **Boss AGI** — M6 finale boss. Projected combat avatar of the corp
    /// AGI. Hard to hit (high REA/AGI — flickering target), tankier than
    /// elites but less than the mech (it's data, not steel). Spell-style
    /// ranged attack at range 6. Lower physical armor but spell-resistant.
    static func bossAGI() -> Enemy {
        var attrs = AttributeSet.zero
        attrs.bod = 5; attrs.agi = 5; attrs.rea = 5; attrs.str = 3
        attrs.cha = 6; attrs.int = 7; attrs.log = 7; attrs.wil = 6

        let weapon = Weapon(name: "Reality Glitch", type: .rifle,
                            damage: 9, accuracy: 5, armorPiercing: 5)
        let armor = Armor(name: "Data Skin", armorValue: 4, spellPenalty: -2)

        // 95 HP (was 60 — lower than the M5 mech's 80, so the finale boss died
        // before it could act much, reading as passive/easy). As the campaign
        // climax it should outlast the M5 boss and get more turns to kite+strike.
        return Enemy(name: "AGI-PRIME", archetype: "bossagi",
                     attributes: attrs, weapon: weapon, armor: armor, maxHP: 95)
    }

    /// **Boss Corp** — M4 finale boss. Vera Koss, Renraku Extraction Auditor:
    /// the exec who flew in to stop the runners leaving with the package. A
    /// HUMAN boss (contrast to the mage/mech/AGI) — agile, smartlink-precise,
    /// mid armor. Her kit (in EnemyAI) is the real threat: she CALLS IN security
    /// drones, MARKS a runner for an amplified EXECUTE shot, and kites at range.
    static func bossCorp() -> Enemy {
        var attrs = AttributeSet.zero
        attrs.bod = 5; attrs.agi = 6; attrs.rea = 5; attrs.str = 3
        attrs.cha = 7; attrs.int = 6; attrs.log = 6; attrs.wil = 6

        let weapon = Weapon(name: "Smartlink Machine-Pistol", type: .smg,
                            damage: 8, accuracy: 6, armorPiercing: 3)
        let armor = Armor(name: "Executive Armorweave", armorValue: 5, spellPenalty: 0)

        // 58 → 80 HP: playtest "too easy to beat". With the AI rework (presses
        // in to fire instead of kiting + double-tap), she's now a real wall.
        return Enemy(name: "Vera Koss", archetype: "bosscorp",
                     attributes: attrs, weapon: weapon, armor: armor, maxHP: 80)
    }

    // MARK: - Reinforcement / Specialist Archetypes
    // Added 2026-05: rounds out enemy roster for room-clear reinforcement waves.

    /// **Sniper** — long-range high-accuracy specialist. Glass cannon: hits hard
    /// at distance but folds quickly under return fire. Prefers to stay in cover
    /// and rarely closes for melee.
    static func sniper() -> Enemy {
        var attrs = AttributeSet.zero
        attrs.bod = 2; attrs.agi = 4; attrs.rea = 4; attrs.str = 2
        attrs.cha = 2; attrs.int = 4; attrs.log = 4; attrs.wil = 3

        // High accuracy, high damage, hefty AP — rifle scaled for precision fire.
        let weapon = Weapon(name: "Sniper Rifle", type: .rifle, damage: 9, accuracy: 6, armorPiercing: 3)
        let armor = Armor(name: "Stealth Suit", armorValue: 1, spellPenalty: 0)

        return Enemy(name: "Sniper", archetype: "sniper",
                     attributes: attrs, weapon: weapon, armor: armor, maxHP: 14)
    }

    /// **Bruiser** — melee shock trooper. High HP/STR, low REA so easier to hit
    /// at range, but devastating in close quarters. Prefers to charge.
    static func bruiser() -> Enemy {
        var attrs = AttributeSet.zero
        attrs.bod = 6; attrs.agi = 4; attrs.rea = 2; attrs.str = 6
        attrs.cha = 1; attrs.int = 2; attrs.log = 1; attrs.wil = 4

        // Monofilament whip-style melee — brutal damage, mid AP.
        let weapon = Weapon(name: "Shock Baton", type: .unarmed, damage: 8, accuracy: 5, armorPiercing: 2)
        let armor = Armor(name: "Combat Armor", armorValue: 3, spellPenalty: -1)

        return Enemy(name: "Bruiser", archetype: "bruiser",
                     attributes: attrs, weapon: weapon, armor: armor, maxHP: 26)
    }

    /// **Spider Drone** — fast scout drone. Lower HP/damage than the Security
    /// Drone but extra moveRange (3 tiles). Hits-and-runs to harass deckers.
    static func spiderDrone() -> Enemy {
        var attrs = AttributeSet.zero
        attrs.bod = 2; attrs.agi = 5; attrs.rea = 4; attrs.str = 1
        attrs.cha = 0; attrs.int = 3; attrs.log = 1; attrs.wil = 1

        let weapon = Weapon(name: "Taser Pulse", type: .pistol, damage: 4, accuracy: 4, armorPiercing: 0)
        let enemy = Enemy(name: "Spider Drone", archetype: "spider",
                          attributes: attrs, weapon: weapon, armor: nil, maxHP: 10)
        return enemy
    }

    /// **Rigger / Drone Master** — a support specialist who summons security
    /// drones to swarm the party. Weak in a straight fight (low BOD/STR), hangs
    /// back and lets its drones do the work. Killing it stops the drone tap.
    static func rigger() -> Enemy {
        var attrs = AttributeSet.zero
        attrs.bod = 3; attrs.agi = 3; attrs.rea = 3; attrs.str = 2
        attrs.cha = 2; attrs.int = 4; attrs.log = 5; attrs.wil = 3

        let weapon = Weapon(name: "Machine Pistol", type: .pistol, damage: 5, accuracy: 4, armorPiercing: 1)
        let armor = Armor(name: "Lined Vest", armorValue: 2, spellPenalty: 0)
        return Enemy(name: "Rigger", archetype: "rigger",
                     attributes: attrs, weapon: weapon, armor: armor, maxHP: 16)
    }

    /// **Combat Decker** — an enemy netrunner that fires "data spikes" at your
    /// runners: STUN damage that bypasses meat armor (soaked by WIL only). Fills
    /// the stun track and can knock a runner out of the round entirely. Squishy;
    /// hangs back. The mirror of your own decker.
    static func combatDecker() -> Enemy {
        var attrs = AttributeSet.zero
        attrs.bod = 3; attrs.agi = 3; attrs.rea = 4; attrs.str = 2
        attrs.cha = 2; attrs.int = 5; attrs.log = 6; attrs.wil = 4

        let weapon = Weapon(name: "Hold-out Pistol", type: .pistol, damage: 4, accuracy: 4, armorPiercing: 0)
        let armor = Armor(name: "Synthleather Coat", armorValue: 2, spellPenalty: 0)
        return Enemy(name: "Combat Decker", archetype: "netrunner",
                     attributes: attrs, weapon: weapon, armor: armor, maxHP: 15)
    }

    /// **Grenadier** — lobs AoE grenades that hit a target tile AND everyone
    /// adjacent to it, punishing the party for clustering. Forces you to spread
    /// out. Armored and tough, but slow.
    static func grenadier() -> Enemy {
        var attrs = AttributeSet.zero
        attrs.bod = 5; attrs.agi = 3; attrs.rea = 3; attrs.str = 4
        attrs.cha = 1; attrs.int = 2; attrs.log = 2; attrs.wil = 3

        let weapon = Weapon(name: "Grenade Launcher", type: .rifle, damage: 6, accuracy: 4, armorPiercing: 2)
        let armor = Armor(name: "Combat Armor", armorValue: 4, spellPenalty: 0)
        return Enemy(name: "Grenadier", archetype: "grenadier",
                     attributes: attrs, weapon: weapon, armor: armor, maxHP: 22)
    }

    /// **Cyber-Zombie Juggernaut** — a slow, near-unkillable wall of bolted
    /// chrome. Huge HP + heavy plating soak a beating; its hydraulic fists hit
    /// like a truck. Moves only 1 tile/turn — kite it, focus it, don't get cornered.
    static func juggernaut() -> Enemy {
        var attrs = AttributeSet.zero
        attrs.bod = 8; attrs.agi = 2; attrs.rea = 2; attrs.str = 8
        attrs.cha = 0; attrs.int = 1; attrs.log = 1; attrs.wil = 6

        let weapon = Weapon(name: "Hydraulic Fists", type: .blade, damage: 10, accuracy: 5, armorPiercing: 3)
        let armor = Armor(name: "Bolted Plating", armorValue: 7, spellPenalty: 0)
        return Enemy(name: "Cyber-Zombie", archetype: "juggernaut",
                     attributes: attrs, weapon: weapon, armor: armor, maxHP: 44)
    }

    /// **Infiltrator** — a slippery optical-camo assassin. Very evasive (high
    /// AGI/REA → huge defense pool, hard to hit) and fast (moves 3), it closes
    /// to flank and lands armor-piercing monofilament backstabs. Glass cannon —
    /// fragile if you can pin it.
    static func infiltrator() -> Enemy {
        var attrs = AttributeSet.zero
        attrs.bod = 3; attrs.agi = 7; attrs.rea = 7; attrs.str = 4
        attrs.cha = 2; attrs.int = 4; attrs.log = 2; attrs.wil = 3

        let weapon = Weapon(name: "Monofilament Blade", type: .blade, damage: 8, accuracy: 7, armorPiercing: 4)
        return Enemy(name: "Infiltrator", archetype: "infiltrator",
                     attributes: attrs, weapon: weapon, armor: nil, maxHP: 16)
    }

    /// **Repair Drone** — the robotic medic. Each turn it patches up the most
    /// damaged MECHANICAL ally (drones / mechs / turrets). Harmless on its own;
    /// kill it to stop the repairs, or it keeps the machines alive forever.
    static func repairDrone() -> Enemy {
        var attrs = AttributeSet.zero
        attrs.bod = 2; attrs.agi = 4; attrs.rea = 4; attrs.str = 1
        attrs.cha = 0; attrs.int = 3; attrs.log = 4; attrs.wil = 1
        let enemy = Enemy(name: "Repair Drone", archetype: "repairdrone",
                          attributes: attrs, weapon: nil, armor: nil, maxHP: 12)
        return enemy
    }

    /// **Toxic Sprayer** — area denial. Sprays a corrosive cone that hits a
    /// target tile + adjacent runners AND leaves a lingering CORROSION (damage
    /// over time) on anyone caught. Pierces armor. Punishes clustering and
    /// makes you keep moving.
    static func sprayer() -> Enemy {
        var attrs = AttributeSet.zero
        attrs.bod = 4; attrs.agi = 3; attrs.rea = 3; attrs.str = 3
        attrs.cha = 0; attrs.int = 2; attrs.log = 2; attrs.wil = 3
        let weapon = Weapon(name: "Chem Sprayer", type: .rifle, damage: 4, accuracy: 4, armorPiercing: 3)
        let armor = Armor(name: "Hazmat Rig", armorValue: 3, spellPenalty: 0)
        return Enemy(name: "Toxic Sprayer", archetype: "sprayer",
                     attributes: attrs, weapon: weapon, armor: armor, maxHP: 18)
    }

    /// **Riot Trooper** — heavy shielded crowd-control unit. High armor and
    /// soak make ranged attacks bounce; mid-tier damage but reliable. Slow.
    static func riotTrooper() -> Enemy {
        var attrs = AttributeSet.zero
        attrs.bod = 5; attrs.agi = 2; attrs.rea = 2; attrs.str = 5
        attrs.cha = 2; attrs.int = 2; attrs.log = 2; attrs.wil = 4

        let weapon = Weapon(name: "Riot Shotgun", type: .smg, damage: 6, accuracy: 4, armorPiercing: 1)
        let armor = Armor(name: "Riot Plate + Shield", armorValue: 6, spellPenalty: -2)

        return Enemy(name: "Riot Trooper", archetype: "riot",
                     attributes: attrs, weapon: weapon, armor: armor, maxHP: 24)
    }

    /// **Sentry Turret** — M1 signature. A bolted-down automated emplacement:
    /// can't move (moveRange 0) and is easy to HIT (AGI 0 → tiny defense pool),
    /// but smartlinked + armored so it pins a lane with accurate suppressing
    /// fire until the runners flank/destroy it. Fixed weapon platform.
    static func turret() -> Enemy {
        var attrs = AttributeSet.zero
        attrs.bod = 6; attrs.agi = 0; attrs.rea = 2; attrs.str = 0
        attrs.cha = 0; attrs.int = 1; attrs.log = 3; attrs.wil = 2

        let weapon = Weapon(name: "Sentry Autocannon", type: .rifle,
                            damage: 7, accuracy: 6, armorPiercing: 2)
        let armor = Armor(name: "Turret Plating", armorValue: 5, spellPenalty: 0)

        return Enemy(name: "Sentry Turret", archetype: "turret",
                     attributes: attrs, weapon: weapon, armor: armor, maxHP: 20)
    }
}

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
            let roll = DiceEngine.rollInitiative(rea: char.attributes.rea, int: char.attributes.int)
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
    let maxHP: Int

    // Stun damage track (WIL/2+8). Overflow goes to physical.
    @Published var currentStun: Int = 0
    var maxStun: Int { Int(ceil(Double(attributes.wil) / 2.0)) + 8 }

    @Published var positionX: Int = 0
    @Published var positionY: Int = 0

    @Published var status: StatusEffect = .wounded

    var initiativeRoll: Int = 0

    enum CodingKeys: String, CodingKey {
        case id, name, archetype, attributes
        case equippedWeapon, equippedArmor
        case currentHP, maxHP
        case positionX, positionY, status
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
        try container.encode(positionX, forKey: .positionX)
        try container.encode(positionY, forKey: .positionY)
        try container.encode(status, forKey: .status)
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
        attrs.bod = 4; attrs.agi = 4; attrs.rea = 5; attrs.str = 2
        attrs.cha = 0; attrs.int = 3; attrs.log = 1; attrs.wil = 1

        let weapon = Weapon(name: "SMG", type: .smg, damage: 5, accuracy: 4, armorPiercing: 1)
        return Enemy(name: "Security Drone", archetype: "drone",
                     attributes: attrs, weapon: weapon, armor: nil, maxHP: 14)
    }

    static func eliteGuard() -> Enemy {
        var attrs = AttributeSet.zero
        attrs.bod = 5; attrs.agi = 4; attrs.rea = 4; attrs.str = 4
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

    static func medic() -> Enemy {
        var attrs = AttributeSet.zero
        attrs.bod = 3; attrs.agi = 3; attrs.rea = 4; attrs.str = 2
        attrs.cha = 4; attrs.int = 4; attrs.log = 5; attrs.wil = 4

        let weapon = Weapon(name: "Medkit", type: .unarmed, damage: 4, accuracy: 3, armorPiercing: 0)
        let armor = Armor(name: "Light Armor", armorValue: 2, spellPenalty: 0)

        return Enemy(name: "Street Medic", archetype: "healer",
                     attributes: attrs, weapon: weapon, armor: armor, maxHP: 20)
    }
}

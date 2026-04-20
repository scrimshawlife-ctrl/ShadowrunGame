import Foundation

// MARK: - Armor

struct Armor: Codable, Equatable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var armorValue: Int       // added to BOD for soak
    var spellPenalty: Int   // penalty to spellcasting (0 = light, -1 = medium, -2 = heavy)

    init(id: UUID = UUID(), name: String, armorValue: Int, spellPenalty: Int) {
        self.id = id
        self.name = name
        self.armorValue = armorValue
        self.spellPenalty = spellPenalty
    }

    // MARK: - Pre-built Armor

    static let light = Armor(name: "Light Armor", armorValue: 2, spellPenalty: 0)
    static let medium = Armor(name: "Medium Armor", armorValue: 4, spellPenalty: -1)
    static let heavy = Armor(name: "Heavy Armor", armorValue: 6, spellPenalty: -2)

    static let allArmor: [Armor] = [.light, .medium, .heavy]
}

// MARK: - Item Type

enum ItemType: String, Codable, CaseIterable {
    case medkit
    case stim
    case grenade
    case other
}

// MARK: - Item

struct Item: Codable, Equatable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var type: ItemType
    var description: String
    var uses: Int   // number of times item can be used

    init(id: UUID = UUID(), name: String, type: ItemType, description: String, uses: Int = 1) {
        self.id = id
        self.name = name
        self.type = type
        self.description = description
        self.uses = uses
    }

    // MARK: - Pre-built Items

    static let medkit = Item(name: "Medkit", type: .medkit, description: "Heals 4 HP", uses: 2)
    static let stim = Item(name: "Stim", type: .stim, description: "+2 to an attribute for 1 fight", uses: 1)
    static let grenade = Item(name: "Grenade", type: .grenade, description: "6P AP-2 AoE damage", uses: 1)

    static let allItems: [Item] = [.medkit, .stim, .grenade]
}

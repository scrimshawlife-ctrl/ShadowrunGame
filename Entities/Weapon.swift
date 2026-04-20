import Foundation

// MARK: - Weapon Type

enum WeaponType: String, Codable, CaseIterable {
    case pistol
    case smg
    case rifle
    case blade
    case unarmed

    var displayName: String {
        switch self {
        case .pistol:  return "Pistol"
        case .smg:     return "SMG"
        case .rifle:    return "Rifle"
        case .blade:    return "Blade"
        case .unarmed:  return "Unarmed"
        }
    }
}

// MARK: - Weapon

struct Weapon: Codable, Equatable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var type: WeaponType
    var damage: Int          // base damage
    var accuracy: Int       // weapon accuracy modifier (added to pool)
    var armorPiercing: Int  // AP value

    init(id: UUID = UUID(), name: String, type: WeaponType, damage: Int, accuracy: Int, armorPiercing: Int) {
        self.id = id
        self.name = name
        self.type = type
        self.damage = damage
        self.accuracy = accuracy
        self.armorPiercing = armorPiercing
    }

    /// True if this weapon deals Stun damage (unarmed strikes, stun batons, etc.)
    /// vs Physical damage (firearms, blades). Per Shadowrun 5e rules.
    var isStunDamage: Bool {
        switch type {
        case .unarmed: return true
        default: return false
        }
    }

    // MARK: - Pre-built Weapons

    static let katana = Weapon(name: "Katana", type: .blade, damage: 8, accuracy: 6, armorPiercing: 2)
    static let pistol = Weapon(name: "Pistol", type: .pistol, damage: 5, accuracy: 5, armorPiercing: 1)
    static let smg = Weapon(name: "SMG", type: .smg, damage: 6, accuracy: 4, armorPiercing: 1)
    static let assaultRifle = Weapon(name: "Assault Rifle", type: .rifle, damage: 8, accuracy: 4, armorPiercing: 2)
    static let smartgunPistol = Weapon(name: "Smartgun Pistol", type: .pistol, damage: 5, accuracy: 6, armorPiercing: 1)
    static let stunball = Weapon(name: "Stunball", type: .unarmed, damage: 6, accuracy: 4, armorPiercing: 0)

    static let allWeapons: [Weapon] = [.katana, .pistol, .smg, .assaultRifle, .smartgunPistol, .stunball]
}

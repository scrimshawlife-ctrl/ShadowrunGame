import Foundation

/// Shadowrun TN dice system engine
/// Rolls Xd6, counts hits (5 or 6), handles exploding 6s, detects glitches
struct DiceEngine {

    // MARK: - Roll Result

    struct RollResult {
        let hits: Int
        let glitch: Bool
        let criticalGlitch: Bool
        let rolls: [Int]           // individual die results (including rerolls)
        let originalPool: Int      // original dice pool size
        let netHits: Int           // hits after subtracting TNs for opposed rolls

        var description: String {
            var parts: [String] = []
            parts.append("Rolled \(rolls)")
            parts.append("\(hits) hit\(hits == 1 ? "" : "s")")
            if criticalGlitch {
                parts.append("💥 CRITICAL GLITCH")
            } else if glitch {
                parts.append("⚠️ GLITCH")
            }
            return parts.joined(separator: ", ")
        }
    }

    // MARK: - Core Roll

    /// Roll a dice pool against a Target Number
    /// - Parameters:
    ///   - pool: Number of d6 to roll
    ///   - tn: Target Number to beat (each 5 or 6 = 1 hit)
    /// - Returns: RollResult with hits, glitch flags, and full roll breakdown
    static func roll(pool: Int, tn: Int = 4) -> RollResult {
        guard pool > 0 else {
            return RollResult(hits: 0, glitch: false, criticalGlitch: false, rolls: [], originalPool: 0, netHits: 0)
        }

        var allRolls: [Int] = []
        var hits = 0
        var ones = 0

        // First roll
        let firstRolls = rollDice(count: pool)
        allRolls.append(contentsOf: firstRolls)

        // Count hits and ones, collect 6s for exploding
        var sixesToReroll: [Int] = []
        for roll in firstRolls {
            if roll >= 5 {
                hits += 1
            }
            if roll == 6 {
                sixesToReroll.append(6)
            }
            if roll == 1 {
                ones += 1
            }
        }

        // Exploding 6s: reroll and add hits
        while !sixesToReroll.isEmpty {
            let rerollCount = sixesToReroll.count
            sixesToReroll.removeAll()
            let rerolls = rollDice(count: rerollCount)
            allRolls.append(contentsOf: rerolls)
            for roll in rerolls {
                if roll >= 5 {
                    hits += 1
                }
                if roll == 6 {
                    sixesToReroll.append(6)
                }
                if roll == 1 {
                    ones += 1
                }
            }
        }

        // Net hits = hits - TNs (for TN-based comparisons)
        // For simple hit-counting, netHits = hits when tn is the threshold
        let netHits = hits // Will be adjusted if we implement opposed rolls

        // Glitch detection: half or more dice show 1s
        let glitch = ones >= pool / 2

        // Critical glitch: all dice show 1s
        let criticalGlitch = ones == pool && pool > 0

        return RollResult(
            hits: hits,
            glitch: glitch,
            criticalGlitch: criticalGlitch,
            rolls: allRolls,
            originalPool: pool,
            netHits: netHits
        )
    }

    // MARK: - Opposed Roll

    /// Opposed roll: attacker pool vs defender pool
    /// Net hits = attacker's hits - defender's hits
    static func opposedRoll(attackerPool: Int, defenderPool: Int, tn: Int = 4) -> RollResult {
        let attackRoll = roll(pool: attackerPool, tn: tn)
        let defenseRoll = roll(pool: defenderPool, tn: tn)

        let netHits = max(0, attackRoll.hits - defenseRoll.hits)
        let criticalGlitch = attackRoll.criticalGlitch

        // Glitch on attack side
        let glitch = attackRoll.glitch

        // Combine rolls for audit trail
        var combinedRolls = attackRoll.rolls
        combinedRolls.append(contentsOf: defenseRoll.rolls)

        return RollResult(
            hits: netHits,
            glitch: glitch,
            criticalGlitch: criticalGlitch,
            rolls: combinedRolls,
            originalPool: attackerPool,
            netHits: netHits
        )
    }

    // MARK: - Private Helpers

    /// Roll `count` d6 dice, returning array of results
    private static func rollDice(count: Int) -> [Int] {
        var results: [Int] = []
        results.reserveCapacity(count)
        for _ in 0..<count {
            results.append(Int.random(in: 1...6))
        }
        return results
    }

    // MARK: - Initiative Roll

    /// Roll initiative: REA + INT + 1d6
    static func rollInitiative(rea: Int, int: Int) -> Int {
        let base = rea + int
        let die = Int.random(in: 1...6)
        return base + die
    }

    // MARK: - Soak Roll

    /// Roll soak: BOD + armor vs TN (default TN 4)
    /// Returns number of damage actually soaked
    static func soakRoll(pool: Int, tn: Int = 4) -> (soaked: Int, rolls: [Int]) {
        let result = roll(pool: pool, tn: tn)
        return (soaked: result.hits, rolls: result.rolls)
    }
}

// MARK: - Combat Mechanics

/// Stateless helpers for cover detection, hit-preview, and future tactical calculations.
/// Lives in DiceEngine.swift to avoid requiring a separate build-target entry.
struct CombatMechanics {

    // MARK: - Cover System

    /// Walk the Bresenham line between two tile coordinates and count how many
    /// intermediate tiles (exclusive of both endpoints) have tileType == 2 (cover).
    static func coverBetween(
        tiles: [[Int]],
        fromX sx: Int, fromY sy: Int,
        toX dx: Int, toY dy: Int
    ) -> Int {
        guard !tiles.isEmpty else { return 0 }
        var x0 = sx, y0 = sy
        let x1 = dx, y1 = dy
        let absDx = abs(x1 - x0)
        let absDy = abs(y1 - y0)
        let stepX = x0 < x1 ? 1 : -1
        let stepY = y0 < y1 ? 1 : -1
        var err = absDx - absDy
        var count = 0
        while true {
            if !(x0 == sx && y0 == sy) && !(x0 == x1 && y0 == y1) {
                let h = tiles.count
                if y0 >= 0, y0 < h, x0 >= 0, x0 < tiles[y0].count {
                    if tiles[y0][x0] == 2 { count += 1 }
                }
            }
            if x0 == x1 && y0 == y1 { break }
            let e2 = 2 * err
            if e2 > -absDy { err -= absDy; x0 += stepX }
            if e2 < absDx  { err += absDx; y0 += stepY }
        }
        return count
    }

    /// 1 cover tile → +2 dice; 2+ → +4 dice (cap).
    static func coverDefenseBonus(count: Int) -> Int {
        switch count {
        case 0:  return 0
        case 1:  return 2
        default: return 4
        }
    }

    // MARK: - Hit Preview

    struct HitPreview {
        let attackPool: Int
        let defensePool: Int
        let coverBonus: Int
        let estimatedHitChance: Double
        let weaponDamage: Int
        let estimatedDamage: Double
        let blocked: Bool
        let reason: String?
    }

    /// Compute a live hit-preview for display before the player commits to an attack.
    static func computeHitPreview(
        attacker: Character,
        target: Enemy,
        tiles: [[Int]],
        isBlocked: (Int, Int, Int, Int) -> Bool
    ) -> HitPreview {
        if isBlocked(attacker.positionX, attacker.positionY,
                     target.positionX, target.positionY) {
            return HitPreview(attackPool: 0, defensePool: 0, coverBonus: 0,
                              estimatedHitChance: 0, weaponDamage: 0, estimatedDamage: 0,
                              blocked: true, reason: "Wall blocks LOS")
        }
        let weapon = attacker.equippedWeapon
        let skill: SkillKey = (weapon?.type == .blade || weapon?.type == .unarmed) ? .blades : .firearms
        let attackPool = attacker.attackPool(skill: skill)
        let coverCount = coverBetween(tiles: tiles,
                                      fromX: attacker.positionX, fromY: attacker.positionY,
                                      toX: target.positionX, toY: target.positionY)
        let coverBonus  = coverDefenseBonus(count: coverCount)
        let defensePool = target.attributes.rea + target.attributes.agi + coverBonus
        let hitsPerDie  = 1.0 / 3.0
        let atkExp      = Double(attackPool)  * hitsPerDie
        let defExp      = Double(defensePool) * hitsPerDie
        let netExp      = max(0.0, atkExp - defExp)
        let hitChance   = attackPool > 0
            ? min(1.0, max(0.0, 0.5 + (atkExp - defExp) / Double(max(1, attackPool))))
            : 0.0
        let weaponDamage    = weapon?.damage ?? 3
        let estimatedDamage = Double(weaponDamage) + netExp
        return HitPreview(attackPool: attackPool, defensePool: defensePool, coverBonus: coverBonus,
                          estimatedHitChance: hitChance, weaponDamage: weaponDamage,
                          estimatedDamage: estimatedDamage, blocked: false, reason: nil)
    }
}

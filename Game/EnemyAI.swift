import Foundation

// Per-type enemy AI turn logic.
// Extracted from GameState.swift (mechanical move; logic unchanged).
extension GameState {

    /// One boss ranged strike against a single target — rolls attack/defence,
    /// soak, applies damage, logs, and fires the archetype-styled gunfire VFX.
    /// Centralizes the per-hit math so bosses can compose VARIETY (single shot,
    /// AoE barrage, double-tap echo) without duplicating the resolution.
    /// `dmgScale` lets secondary/AoE hits land a touch softer.
    @discardableResult
    func bossRangedStrike(enemy: Enemy, target: Character, label: String, dmgScale: Double = 1.0) -> Bool {
        let attackPool = enemy.attributes.agi + (enemy.equippedWeapon?.accuracy ?? 5) / 2 + 1
        // FLANKED runners defend at -2 (min-1 clamp) — symmetric with the
        // player-side check in performAttack; the helper logs the warning.
        let flankPenalty = flankedDefensePenalty(target: target, attacker: enemy)
        let defensePool = max(1, target.defensePool() - flankPenalty)
        let attackRoll = DiceEngine.roll(pool: attackPool)
        let defenseRoll = DiceEngine.roll(pool: defensePool)
        let netHits = max(0, attackRoll.hits - defenseRoll.hits)
        if netHits == 0 {
            addLog("→ \(label) — \(target.name) evades!")
            return false
        }
        let baseDmg = Int((Double((enemy.equippedWeapon?.damage ?? 9) + netHits) * dmgScale).rounded())
        let ap = enemy.equippedWeapon?.armorPiercing ?? 4
        let soakRoll = DiceEngine.roll(pool: max(0, target.computeDerived().soak - ap))
        let dmg = escalatedIncomingDamage(max(0, baseDmg - soakRoll.hits))
        guard dmg > 0 else {
            addLog("→ \(label) — \(target.name) soaks it!")
            return false
        }
        target.takeDamage(amount: dmg, isStun: false)
        HapticsManager.shared.playerDamaged()
        addLog("💥 \(label) hits \(target.name) — \(dmg)P. (HP \(target.currentHP)/\(target.maxHP))")
        NotificationCenter.default.post(name: .playerHit, object: nil, userInfo: [
            "playerId": target.id.uuidString, "damage": dmg, "enemyId": enemy.id.uuidString
        ])
        NotificationCenter.default.post(name: .gunfireEffect, object: nil, userInfo: [
            "fromX": enemy.positionX, "fromY": enemy.positionY,
            "toX": target.positionX, "toY": target.positionY,
            "weaponType": (enemy.equippedWeapon?.type.rawValue ?? "rifle"),
            "enemyArchetype": enemy.archetype
        ])
        if !target.isAlive { CombatFlowController.handlePlayerKilled(gameState: self, char: target) }
        return true
    }

    /// Vera Koss "CALL IT IN" — drop a Security Drone on a walkable tile next
    /// to her. It joins the enemy roster and acts from the next round.
    func summonCorpDrone(near boss: Enemy) {
        let drone = Enemy.securityDrone()
        let spots = PathingAndAIHelpers.hexNeighbors(gameState: self, x: boss.positionX, y: boss.positionY)
            .filter { PathingAndAIHelpers.tileWalkable(gameState: self, x: $0.0, y: $0.1, excluding: drone.id) }
        if let s = spots.first {
            drone.positionX = s.0; drone.positionY = s.1
        } else {
            drone.positionX = boss.positionX; drone.positionY = boss.positionY
        }
        enemies.append(drone)
        addLog("📡 \(boss.name): \"Call it in.\" — a Security Drone drops in.")
        NotificationCenter.default.post(name: .enemySpawned, object: nil,
            userInfo: ["enemyId": drone.id.uuidString, "isBoss": false])
    }

    /// Shared attack resolver for the specialist archetypes — keeps their
    /// behaviours below short and consistent. Handles VFX, hit/soak math,
    /// physical-or-stun routing, an optional venom DoT, and the kill check.
    /// `aimBonus`/`damageBonus` tune the strike; `melee` skips gunfire VFX.
    private func resolveSpecialistStrike(
        enemy: Enemy, target: Character, melee: Bool,
        aimBonus: Int = 0, damageBonus: Int = 0,
        forceStun: Bool = false, venom: Bool = false,
        knockdownChance: Double = 0,
        hitVerb: String = "strikes"
    ) {
        if !melee, let wt = enemy.equippedWeapon?.type, wt != .blade, wt != .unarmed {
            NotificationCenter.default.post(name: .gunfireEffect, object: nil, userInfo: [
                "fromX": enemy.positionX, "fromY": enemy.positionY,
                "toX": target.positionX, "toY": target.positionY,
                "weaponType": wt.rawValue, "enemyArchetype": enemy.archetype])
        }
        let acc = enemy.equippedWeapon?.accuracy ?? 4
        let pool = enemy.attributes.agi + acc / 2 + 1 + aimBonus
        let defBonus = isCharacterDefending(target.id) ? 3 : 0
        let cover = melee ? 0 : CombatMechanics.coverBetween(
            tiles: currentMissionTiles, fromX: enemy.positionX, fromY: enemy.positionY,
            toX: target.positionX, toY: target.positionY)
        // FLANKED runners defend at -2 (min-1 clamp, stacks with the prone
        // penalty already baked into defensePool) — mirror of performAttack.
        let flankPenalty = flankedDefensePenalty(target: target, attacker: enemy)
        let defPool = max(1, target.defensePool() + defBonus
            + CombatMechanics.coverDefenseBonus(count: cover) - flankPenalty)
        let atk = DiceEngine.roll(pool: pool)
        let def = DiceEngine.roll(pool: defPool)
        let net = max(0, atk.hits - def.hits)
        // DESTRUCTIBLE COVER: enemy ranged fire chews crates too — rolled
        // after the dice (this shot kept the cover benefit), hit or miss.
        if !melee {
            maybeDegradeCoverAlongShot(
                fromX: enemy.positionX, fromY: enemy.positionY,
                toX: target.positionX, toY: target.positionY)
        }
        if net == 0 {
            addLog("→ \(enemy.name) \(hitVerb) \(target.name) — DODGED!")
            return
        }
        let isStun = forceStun || (enemy.equippedWeapon?.isStunDamage ?? false)
        let wd = (enemy.equippedWeapon?.damage ?? 5) + damageBonus
        let ap = enemy.equippedWeapon?.armorPiercing ?? 0
        let soak = DiceEngine.roll(pool: max(0, target.computeDerived().soak - ap)).hits
        let dmg = escalatedIncomingDamage(max(0, wd + net - soak))
        if dmg <= 0 {
            addLog("→ \(enemy.name) \(hitVerb) \(target.name) but the armour holds!")
            return
        }
        target.takeDamage(amount: dmg, isStun: isStun)
        HapticsManager.shared.playerDamaged()
        if venom, target.isAlive {
            if let i = target.statusEffects.firstIndex(where: { if case .burning = $0 { return true } else { return false } }) {
                target.statusEffects[i] = .burning(roundsLeft: 2)
            } else {
                target.statusEffects.append(.burning(roundsLeft: 2))
            }
        }
        let tag = isStun ? "S" : "P"
        let venomTag = venom ? " +VENOM" : ""
        addLog("→ \(enemy.name) \(hitVerb) \(target.name)! [\(pool)d6→\(atk.hits)] \(wd + net)\(tag)\(venomTag) - \(soak) = \(dmg) (HP \(target.currentHP)/\(target.maxHP))")
        // KNOCKDOWN (riot point-blank blast): a survivor caught in the spread
        // can be blown off their feet. Prone until the round tick — pinned in
        // place and defending at -2 dice (Character.defensePool). Same
        // Double.random convention as the boss ability rolls; no re-stack on
        // an already-prone target, and corpses stay corpses.
        if knockdownChance > 0, target.isAlive,
           !target.statusEffects.contains(.prone),
           Double.random(in: 0..<1) < knockdownChance {
            target.statusEffects.append(.prone)
            proneInflictedRound[target.id] = roundNumber
            addLog("  🔻 \(target.name) is blasted off their feet — PRONE!")
        }
        NotificationCenter.default.post(name: .playerHit, object: nil, userInfo: ["playerId": target.id.uuidString, "damage": dmg, "enemyId": enemy.id.uuidString])
        if !target.isAlive { CombatFlowController.handlePlayerKilled(gameState: self, char: target) }
    }

    /// One full CONFUSED turn (Sable's Confusion hex). The enemy never runs
    /// its archetype logic: 50% of the time it attacks a random ADJACENT unit
    /// — friend or foe, friendly fire very much allowed — otherwise it
    /// stumbles to a random walkable neighbouring tile. Either way it does
    /// nothing else this turn; the status ticks down in tickStatusEffects.
    private func runConfusedTurn(enemy: Enemy) {
        // Everything standing within arm's reach, both rosters. The pick is
        // uniform across the combined pool, so a confused guard in a scrum is
        // as likely to shoot its squadmate as the runner next to it.
        let adjacentRunners = playerTeam.filter {
            $0.isAlive && hexDistance(x1: $0.positionX, y1: $0.positionY,
                                      x2: enemy.positionX, y2: enemy.positionY) <= 1
        }
        let adjacentAllies = enemies.filter {
            $0.isAlive && $0.id != enemy.id
                && hexDistance(x1: $0.positionX, y1: $0.positionY,
                               x2: enemy.positionX, y2: enemy.positionY) <= 1
        }
        let totalAdjacent = adjacentRunners.count + adjacentAllies.count

        // 50/50 lash-out vs stumble (same Double.random convention as the
        // boss ability rolls). No one adjacent? The swing has nothing to
        // connect with, so it degenerates into the stumble.
        if totalAdjacent > 0 && Double.random(in: 0..<1) < 0.5 {
            let pick = Int.random(in: 0..<totalAdjacent)
            if pick < adjacentRunners.count {
                // Swung at a runner — resolve exactly like a basic specialist
                // strike so the dice conventions (and kill routing) match.
                let victim = adjacentRunners[pick]
                addLog("🌀 \(enemy.name) lashes out blindly!")
                let isMeleeWeapon = enemy.equippedWeapon?.type == .blade
                    || enemy.equippedWeapon?.type == .unarmed
                resolveSpecialistStrike(enemy: enemy, target: victim, melee: isMeleeWeapon,
                                        hitVerb: "wildly swings at")
            } else {
                // Swung at one of its OWN — the whole point of the spell.
                let victim = adjacentAllies[pick - adjacentRunners.count]
                addLog("🌀 \(enemy.name) lashes out blindly — at \(victim.name)!")
                confusedFriendlyFire(from: enemy, on: victim)
            }
        } else {
            // Stumble to a random walkable neighbour (same walkability/
            // occupancy helpers the drone strafe uses). Boxed in? It just
            // reels in place.
            let spots = PathingAndAIHelpers.hexNeighbors(gameState: self, x: enemy.positionX, y: enemy.positionY)
                .filter { PathingAndAIHelpers.tileWalkable(gameState: self, x: $0.0, y: $0.1, excluding: enemy.id) }
            if let s = spots.randomElement() {
                // A stumble is still movement — overwatch fires at the start
                // position, same as every other AI move step.
                for (attackerId, _) in overwatchers {
                    fireOverwatchShot(atEnemy: enemy, attackerId: attackerId)
                }
                enemy.positionX = s.0; enemy.positionY = s.1
                addLog("🌀 \(enemy.name) stumbles away, eyes unfocused…")
                NotificationCenter.default.post(name: .enemyMoved, object: nil,
                    userInfo: ["enemyId": enemy.id.uuidString, "x": s.0, "y": s.1])
            } else {
                addLog("🌀 \(enemy.name) reels in place, thoroughly scrambled.")
            }
        }
    }

    /// Confusion friendly fire — one enemy shooting/striking ANOTHER enemy.
    /// Same dice shape as the enemy-vs-player paths (AGI + acc/2 + 1 attack,
    /// REA+AGI defense, soak minus the weapon's AP). Deliberately does NOT
    /// apply escalatedIncomingDamage — that escalation models TRACE pressure
    /// on the PLAYERS, not corp-on-corp crossfire. A kill routes through the
    /// environment-death pipeline: bounty pays, no runner XP (nobody landed
    /// the shot), and room-clear/door logic advances normally.
    private func confusedFriendlyFire(from enemy: Enemy, on victim: Enemy) {
        if let wt = enemy.equippedWeapon?.type, wt != .blade, wt != .unarmed {
            NotificationCenter.default.post(name: .gunfireEffect, object: nil, userInfo: [
                "fromX": enemy.positionX, "fromY": enemy.positionY,
                "toX": victim.positionX, "toY": victim.positionY,
                "weaponType": wt.rawValue, "enemyArchetype": enemy.archetype])
        }
        let acc = enemy.equippedWeapon?.accuracy ?? 4
        let atkPool = enemy.attributes.agi + acc / 2 + 1
        let defPool = victim.attributes.rea + victim.attributes.agi
        let net = max(0, DiceEngine.roll(pool: atkPool).hits - DiceEngine.roll(pool: defPool).hits)
        if net == 0 {
            addLog("→ \(victim.name) ducks the stray burst!")
            NotificationCenter.default.post(name: .enemyHit, object: nil,
                userInfo: ["enemyId": victim.id.uuidString, "damage": 0, "outcome": "miss"])
            return
        }
        let wd = enemy.equippedWeapon?.damage ?? 5
        let ap = enemy.equippedWeapon?.armorPiercing ?? 0
        let soak = DiceEngine.roll(pool: max(0, victim.computeDerived().soak - ap)).hits
        let dmg = max(0, wd + net - soak)
        guard dmg > 0 else {
            addLog("→ \(victim.name)'s armour holds against the crossfire!")
            NotificationCenter.default.post(name: .enemyHit, object: nil,
                userInfo: ["enemyId": victim.id.uuidString, "damage": 0, "outcome": "soak"])
            return
        }
        victim.takeDamage(amount: dmg, isStun: enemy.equippedWeapon?.isStunDamage ?? false)
        addLog("💥 FRIENDLY FIRE! \(enemy.name) hits \(victim.name) — \(dmg) dmg. (\(victim.currentHP)/\(victim.maxHP) HP)")
        NotificationCenter.default.post(name: .enemyHit, object: nil,
            userInfo: ["enemyId": victim.id.uuidString, "damage": dmg, "outcome": "hit"])
        if !victim.isAlive {
            handleEnemyKilledByEnvironment(victim, cause: "friendly fire")
        }
    }

    /// Execute a single enemy's full AI turn synchronously (move + attack).
    /// All notifications are posted synchronously here — animations are scheduled
    /// by BattleScene's observers and played by the SpriteKit run loop.
    func runEnemyAI(enemy: Enemy, livingEnemies: [Enemy]) {
        let livingPlayers = playerTeam.filter { $0.isAlive }
        guard !livingPlayers.isEmpty else { return }
        let enemyTurnStartX = enemy.positionX
        let enemyTurnStartY = enemy.positionY
        func enemyMovedThisTurn() -> Bool {
            enemy.positionX != enemyTurnStartX || enemy.positionY != enemyTurnStartY
        }

        // Stunned (Decker hack) or cowering (Face INTIMIDATE) enemies skip their
        // turn, then recover. Same skip behaviour; they differ in how the player
        // can exploit the opening (a stunned enemy is also defenseless, a
        // cowering one is not — see the defense-pool branch in CombatFlowController).
        if enemy.status == .stunned {
            addLog("⚡ \(enemy.name) is stunned — cannot act!")
            enemy.status = .wounded  // recover to wounded after 1 round
            // Vent the track below max as they shake it off — while it sits at
            // max, takeDamage's `currentStun >= maxStun` check re-stuns on ANY
            // hit (even 1 physical), a permanent stun-lock for one Shock cast.
            // Re-stunning now requires actually refilling half the track.
            // min() so the Decker hack's low-track stun isn't raised by this.
            enemy.currentStun = min(enemy.currentStun, enemy.maxStun / 2)
            return
        }
        if enemy.status == .cowered {
            addLog("🫨 \(enemy.name) cowers — too rattled to act!")
            enemy.status = .wounded  // shakes it off after 1 round
            return
        }

        // CONFUSED (Sable's Confusion hex): the enemy's sensorium is scrambled
        // — it never runs its archetype logic this turn. 50/50 it lashes out
        // at a random ADJACENT unit (friend or foe — friendly fire is the
        // spell's whole payoff) or stumbles to a random neighbouring tile.
        // Checked BEFORE prone: a confused unit doesn't have the presence of
        // mind to "fight from the ground" tactically. Ticks down in
        // tickStatusEffects like .burning.
        if enemy.statusEffects.contains(where: { if case .confused = $0 { return true } else { return false } }) {
            runConfusedTurn(enemy: enemy)
            return
        }

        // PRONE (riot knockdown / samurai BLITZ sweep): the enemy spends the
        // round on the deck — no archetype logic, no repositioning. It isn't
        // helpless though: if a runner is already inside its weapon reach it
        // fires from the ground; otherwise it just scrambles for purchase
        // until tickStatusEffects stands it back up at the round tick.
        if enemy.statusEffects.contains(.prone) {
            // Weapon reach mirrors the default archetype path's range table
            // (mage 5 / rifle 6 / pistol-smg 4 / melee 1 / fallback 3).
            let proneWeaponType = enemy.equippedWeapon?.type
            let proneReach: Int
            if enemy.archetype == "mage" {
                proneReach = 5
            } else if proneWeaponType == .rifle {
                proneReach = 6
            } else if proneWeaponType == .pistol || proneWeaponType == .smg {
                proneReach = 4
            } else if proneWeaponType == .blade || proneWeaponType == .unarmed {
                proneReach = 1
            } else {
                proneReach = 3
            }
            let inReach = livingPlayers.min(by: {
                hexDistance(x1: $0.positionX, y1: $0.positionY, x2: enemy.positionX, y2: enemy.positionY) <
                hexDistance(x1: $1.positionX, y1: $1.positionY, x2: enemy.positionX, y2: enemy.positionY)
            })
            if let target = inReach,
               hexDistance(x1: target.positionX, y1: target.positionY,
                           x2: enemy.positionX, y2: enemy.positionY) <= proneReach {
                addLog("🔻 \(enemy.name) fights from the ground!")
                let isMeleeWeapon = enemy.equippedWeapon?.type == .blade
                    || enemy.equippedWeapon?.type == .unarmed
                resolveSpecialistStrike(enemy: enemy, target: target, melee: isMeleeWeapon,
                                        hitVerb: isMeleeWeapon ? "swipes from the ground at"
                                                               : "fires from the deck at")
            } else {
                addLog("🔻 \(enemy.name) is down — struggles behind cover!")
            }
            return
        }

        switch enemy.archetype {

        case "drone":
            let closestPlayer = livingPlayers.min { a, b in
                let distA = hexDistance(x1: a.positionX, y1: a.positionY, x2: enemy.positionX, y2: enemy.positionY)
                let distB = hexDistance(x1: b.positionX, y1: b.positionY, x2: enemy.positionX, y2: enemy.positionY)
                return distA < distB
            }!
            let dist = hexDistance(x1: closestPlayer.positionX, y1: closestPlayer.positionY, x2: enemy.positionX, y2: enemy.positionY)
            if dist >= 2 && dist <= 5 {
                // Reposition before firing so drones don't sit motionless on
                // identical tiles round after round. Pick a neighbor that
                // keeps the player in the optimal 2-5 band, preferring tiles
                // that move toward range 3 (centre of band) and have cover.
                if Double.random(in: 0...1) < 0.55 {
                    let candidates = PathingAndAIHelpers.hexNeighbors(gameState: self, x: enemy.positionX, y: enemy.positionY)
                        .filter { (nx, ny) in
                            PathingAndAIHelpers.tileWalkable(gameState: self, x: nx, y: ny, excluding: enemy.id)
                        }
                        .map { (nx, ny) -> (Int, Int, Int) in
                            let nd = hexDistance(x1: closestPlayer.positionX, y1: closestPlayer.positionY, x2: nx, y2: ny)
                            // Score: prefer distance closer to 3, penalise leaving the band
                            let bandPenalty = (nd >= 2 && nd <= 5) ? 0 : 100
                            let centerDist = abs(nd - 3)
                            return (nx, ny, bandPenalty + centerDist)
                        }
                        .sorted { $0.2 < $1.2 }
                    if let pick = candidates.first, pick.2 < 100 {
                        // Overwatch check: before the enemy moves, fire at their START position
                        for (attackerId, _) in overwatchers {
                            fireOverwatchShot(atEnemy: enemy, attackerId: attackerId)
                        }
                        enemy.positionX = pick.0
                        enemy.positionY = pick.1
                        addLog("→ \(enemy.name) repositions")
                        NotificationCenter.default.post(name: .enemyMoved, object: nil, userInfo: ["enemyId": enemy.id.uuidString, "x": pick.0, "y": pick.1])
                    }
                }
                // NOTE: deliberately NOT returning on enemyMovedThisTurn() here —
                // the strafe above is an explicit PRE-FIRE reposition (the comment
                // says "reposition before firing"). The old early-return cancelled
                // the shot, so in-band drones only fired ~45% of turns.
                // Drones attack at optimal range 2–5 (extended from 2–3 to prevent stall states)
                let weaponAccuracy = enemy.equippedWeapon?.accuracy ?? 3
                let enemyAttackPool = enemy.attributes.agi + (weaponAccuracy / 2 + 1)

                // Player defense pool: REA + AGI + defend bonus + cover
                let defenseBonus = isCharacterDefending(closestPlayer.id) ? 3 : 0
                let enemyCoverCount = CombatMechanics.coverBetween(
                    tiles: currentMissionTiles,
                    fromX: enemy.positionX, fromY: enemy.positionY,
                    toX: closestPlayer.positionX, toY: closestPlayer.positionY
                )
                let playerCoverBonus = CombatMechanics.coverDefenseBonus(count: enemyCoverCount)
                // FLANKED runners defend at -2 (min-1 clamp) — see performAttack.
                let droneFlank = flankedDefensePenalty(target: closestPlayer, attacker: enemy)
                let playerDefensePool = max(1, closestPlayer.defensePool() + defenseBonus + playerCoverBonus - droneFlank)

                let attackRoll = DiceEngine.roll(pool: enemyAttackPool)
                let defenseRoll = DiceEngine.roll(pool: playerDefensePool)
                let netHits = max(0, attackRoll.hits - defenseRoll.hits)
                // Destructible cover — after the dice, hit or miss (see performAttack).
                maybeDegradeCoverAlongShot(
                    fromX: enemy.positionX, fromY: enemy.positionY,
                    toX: closestPlayer.positionX, toY: closestPlayer.positionY)

                if netHits == 0 {
                    addLog("→ \(enemy.name) attacks \(closestPlayer.name) — DODGED!")
                } else {
                    let weaponDmg = enemy.equippedWeapon?.damage ?? 4
                    let baseDmg = weaponDmg + netHits
                    let ap = enemy.equippedWeapon?.armorPiercing ?? 0
                    let soakPool = max(0, closestPlayer.computeDerived().soak - ap)
                    let soakRoll = DiceEngine.roll(pool: soakPool)
                    let dmg = escalatedIncomingDamage(max(0, baseDmg - soakRoll.hits))

                    if dmg > 0 {
                        let isStun = enemy.equippedWeapon?.isStunDamage ?? false
                        closestPlayer.takeDamage(amount: dmg, isStun: isStun)
                        let dmgType = isStun ? "S" : "P"
                        HapticsManager.shared.playerDamaged()
                        addLog("⚠️ \(enemy.name) hits \(closestPlayer.name)! \(netHits) net hits → \(dmg)\(dmgType) dmg. (HP \(closestPlayer.currentHP)/\(closestPlayer.maxHP) | Stun \(closestPlayer.currentStun)/\(closestPlayer.maxStun))")
                        NotificationCenter.default.post(name: .playerHit, object: nil, userInfo: ["playerId": closestPlayer.id.uuidString, "damage": dmg, "enemyId": enemy.id.uuidString])
                        if !closestPlayer.isAlive { CombatFlowController.handlePlayerKilled(gameState: self, char: closestPlayer) }
                    } else {
                        addLog("→ \(enemy.name) attacks — \(closestPlayer.name) soaks all damage!")
                    }
                }
            } else if dist < 2 {
                let (bx, by) = bestRetreatTile(for: enemy, awayFrom: closestPlayer)
                if let (rx, ry) = bfsPathfindDrone(from: enemy, towardX: bx, y: by) {
                    enemy.positionX = rx; enemy.positionY = ry
                    addLog("→ \(enemy.name) retreats")
                    NotificationCenter.default.post(name: .enemyMoved, object: nil, userInfo: ["enemyId": enemy.id.uuidString, "x": rx, "y": ry])
                }
            } else {
                // Multi-step move — collect path silently, post .enemyMoved
                // ONCE at the end so the visual animation doesn't restart
                // mid-flight on every step (caused the corpmage's
                // "walks-right-disappears-half-body" glitch).
                let drStartX = enemy.positionX, drStartY = enemy.positionY
                for _ in 0..<2 {
                    if let (nx, ny) = bfsPathfindDrone(from: enemy, towardX: closestPlayer.positionX, y: closestPlayer.positionY) {
                        // Overwatch: check before each step of multi-step movement
                        for (attackerId, _) in overwatchers {
                            fireOverwatchShot(atEnemy: enemy, attackerId: attackerId)
                        }
                        enemy.positionX = nx; enemy.positionY = ny
                        let newDist = hexDistance(x1: closestPlayer.positionX, y1: closestPlayer.positionY, x2: enemy.positionX, y2: enemy.positionY)
                        if newDist >= 2 { break }
                    } else { break }
                }
                if enemy.positionX != drStartX || enemy.positionY != drStartY {
                    addLog("→ \(enemy.name) advances")
                    NotificationCenter.default.post(name: .enemyMoved, object: nil,
                        userInfo: ["enemyId": enemy.id.uuidString,
                                   "x": enemy.positionX, "y": enemy.positionY])
                }
                if enemyMovedThisTurn() { return }
                let afterDist = hexDistance(x1: closestPlayer.positionX, y1: closestPlayer.positionY, x2: enemy.positionX, y2: enemy.positionY)
                if afterDist >= 2 && afterDist <= 5 {
                    // Drones attack at range 2–5 after advancing
                    let weaponAccuracy = enemy.equippedWeapon?.accuracy ?? 3
                    let enemyAttackPool = enemy.attributes.agi + (weaponAccuracy / 2 + 1)

                    // Player defense pool: REA + AGI + defend bonus + cover
                    let defenseBonus = isCharacterDefending(closestPlayer.id) ? 3 : 0
                    let enemyCoverCount2 = CombatMechanics.coverBetween(
                        tiles: currentMissionTiles,
                        fromX: enemy.positionX, fromY: enemy.positionY,
                        toX: closestPlayer.positionX, toY: closestPlayer.positionY
                    )
                    let playerCoverBonus2 = CombatMechanics.coverDefenseBonus(count: enemyCoverCount2)
                    // FLANKED runners defend at -2 (min-1 clamp) — see performAttack.
                    let droneFlank2 = flankedDefensePenalty(target: closestPlayer, attacker: enemy)
                    let playerDefensePool = max(1, closestPlayer.defensePool() + defenseBonus + playerCoverBonus2 - droneFlank2)

                    let attackRoll = DiceEngine.roll(pool: enemyAttackPool)
                    let defenseRoll = DiceEngine.roll(pool: playerDefensePool)
                    let netHits = max(0, attackRoll.hits - defenseRoll.hits)
                    // Destructible cover — after the dice, hit or miss (see performAttack).
                    maybeDegradeCoverAlongShot(
                        fromX: enemy.positionX, fromY: enemy.positionY,
                        toX: closestPlayer.positionX, toY: closestPlayer.positionY)

                    if netHits == 0 {
                        addLog("→ \(enemy.name) attacks \(closestPlayer.name) — DODGED!")
                    } else {
                        let weaponDmg = enemy.equippedWeapon?.damage ?? 4
                        let baseDmg = weaponDmg + netHits
                        let ap = enemy.equippedWeapon?.armorPiercing ?? 0
                        let soakPool = max(0, closestPlayer.computeDerived().soak - ap)
                        let soakRoll = DiceEngine.roll(pool: soakPool)
                        let dmg = escalatedIncomingDamage(max(0, baseDmg - soakRoll.hits))

                        if dmg > 0 {
                            let isStun = enemy.equippedWeapon?.isStunDamage ?? false
                            closestPlayer.takeDamage(amount: dmg, isStun: isStun)
                            let dmgType = isStun ? "S" : "P"
                            HapticsManager.shared.playerDamaged()
                            addLog("⚠️ \(enemy.name) hits \(closestPlayer.name)! \(netHits) net hits → \(dmg)\(dmgType) dmg. (HP \(closestPlayer.currentHP)/\(closestPlayer.maxHP) | Stun \(closestPlayer.currentStun)/\(closestPlayer.maxStun))")
                            NotificationCenter.default.post(name: .playerHit, object: nil, userInfo: ["playerId": closestPlayer.id.uuidString, "damage": dmg, "enemyId": enemy.id.uuidString])
                            if !closestPlayer.isAlive { CombatFlowController.handlePlayerKilled(gameState: self, char: closestPlayer) }
                        } else {
                            addLog("→ \(enemy.name) attacks — \(closestPlayer.name) soaks all damage!")
                        }
                    }
                }
            }

        case "healer":
            if let woundedAlly = findWoundedAlly(for: enemy) {
                let distToAlly = hexDistance(x1: woundedAlly.positionX, y1: woundedAlly.positionY, x2: enemy.positionX, y2: enemy.positionY)
                if distToAlly > 1 {
                    // Single .enemyMoved post at end (see corpmage fix above).
                    let healStartX = enemy.positionX, healStartY = enemy.positionY
                    for _ in 0..<2 {
                        if let (newX, newY) = bfsPathfindToWounded(from: enemy, toward: woundedAlly) {
                            // Overwatch: check before each step
                            for (attackerId, _) in overwatchers {
                                fireOverwatchShot(atEnemy: enemy, attackerId: attackerId)
                            }
                            enemy.positionX = newX; enemy.positionY = newY
                            let newDist = hexDistance(x1: woundedAlly.positionX, y1: woundedAlly.positionY, x2: enemy.positionX, y2: enemy.positionY)
                            if newDist <= 1 { break }
                        } else { break }
                    }
                    if enemy.positionX != healStartX || enemy.positionY != healStartY {
                        addLog("→ \(enemy.name) moves to assist ally")
                        NotificationCenter.default.post(name: .enemyMoved, object: nil,
                            userInfo: ["enemyId": enemy.id.uuidString,
                                       "x": enemy.positionX, "y": enemy.positionY])
                    }
                    let afterDist = hexDistance(x1: woundedAlly.positionX, y1: woundedAlly.positionY, x2: enemy.positionX, y2: enemy.positionY)
                    if afterDist > 1 { return }
                    if enemyMovedThisTurn() { return }
                }
                // Don't heal a corpse — between findWoundedAlly and the move-to-ally
                // loop the ally could have been killed (async damage events).
                guard woundedAlly.isAlive else { return }
                let healAmount = 8 + Int.random(in: 0...4)
                let actualHeal = max(0, min(healAmount, woundedAlly.maxHP - woundedAlly.currentHP))
                woundedAlly.currentHP += actualHeal
                HapticsManager.shared.attackHit()
                addLog("💉 \(enemy.name) heals \(woundedAlly.name)! +\(actualHeal) HP. (\(woundedAlly.currentHP)/\(woundedAlly.maxHP))")
                NotificationCenter.default.post(name: .enemyHit, object: nil, userInfo: ["enemyId": woundedAlly.id.uuidString, "damage": -actualHeal])
                return
            }
            // No wounded ally — reposition near the nearest living ally OR attack nearest player.
            let nearestAlly = enemies.filter({ $0.isAlive && $0.id != enemy.id }).min { a, b in
                let distA = hexDistance(x1: a.positionX, y1: a.positionY, x2: enemy.positionX, y2: enemy.positionY)
                let distB = hexDistance(x1: b.positionX, y1: b.positionY, x2: enemy.positionX, y2: enemy.positionY)
                return distA < distB
            }
            if let ally = nearestAlly {
                // Allies still alive — stay close to support them
                let distToAlly = hexDistance(x1: ally.positionX, y1: ally.positionY, x2: enemy.positionX, y2: enemy.positionY)
                if distToAlly > 2 {
                    if let (nx, ny) = bfsPathfindToWounded(from: enemy, toward: ally) {
                        // Overwatch: check before movement
                        for (attackerId, _) in overwatchers {
                            fireOverwatchShot(atEnemy: enemy, attackerId: attackerId)
                        }
                        enemy.positionX = nx; enemy.positionY = ny
                        addLog("→ \(enemy.name) repositions near ally")
                        NotificationCenter.default.post(name: .enemyMoved, object: nil, userInfo: ["enemyId": enemy.id.uuidString, "x": nx, "y": ny])
                    }
                }
            } else {
                // No allies alive at all — healer attacks nearest player with its sidearm.
                guard let target = livingPlayers.min(by: {
                    hexDistance(x1: $0.positionX, y1: $0.positionY, x2: enemy.positionX, y2: enemy.positionY) <
                    hexDistance(x1: $1.positionX, y1: $1.positionY, x2: enemy.positionX, y2: enemy.positionY)
                }) else { break }

                // Advance 1 step if out of range (healer weapon range ≤ 3)
                let distToTarget = hexDistance(x1: target.positionX, y1: target.positionY, x2: enemy.positionX, y2: enemy.positionY)
                if distToTarget > 3 {
                    if let (nx, ny) = bfsPathfind(from: enemy, toward: target) {
                        enemy.positionX = nx; enemy.positionY = ny
                        addLog("→ \(enemy.name) advances (no allies)")
                        NotificationCenter.default.post(name: .enemyMoved, object: nil, userInfo: ["enemyId": enemy.id.uuidString, "x": nx, "y": ny])
                    }
                }
                if enemyMovedThisTurn() { return }
                // Ranged attack
                let weaponAccuracy = enemy.equippedWeapon?.accuracy ?? 3
                let attackPool = max(1, enemy.attributes.agi + (weaponAccuracy / 2))
                let defensePool = target.defensePool()
                let attackRoll = DiceEngine.roll(pool: attackPool)
                let defenseRoll = DiceEngine.roll(pool: defensePool)
                let netHits = max(0, attackRoll.hits - defenseRoll.hits)
                if netHits > 0 {
                    let weaponDmg = enemy.equippedWeapon?.damage ?? 3
                    let dmg = escalatedIncomingDamage(max(0, weaponDmg + netHits - DiceEngine.roll(pool: target.computeDerived().soak).hits))
                    if dmg > 0 {
                        target.takeDamage(amount: dmg)
                        addLog("⚠️ \(enemy.name) attacks \(target.name) → \(dmg)P dmg")
                        NotificationCenter.default.post(name: .playerHit, object: nil, userInfo: ["playerId": target.id.uuidString, "damage": dmg, "enemyId": enemy.id.uuidString])
                    } else {
                        addLog("→ \(enemy.name) attacks \(target.name) — soaked!")
                    }
                } else {
                    addLog("→ \(enemy.name) attacks \(target.name) — DODGED!")
                }
            }

        case "elite":
            let closestPlayer = livingPlayers.min { a, b in
                let distA = hexDistance(x1: a.positionX, y1: a.positionY, x2: enemy.positionX, y2: enemy.positionY)
                let distB = hexDistance(x1: b.positionX, y1: b.positionY, x2: enemy.positionX, y2: enemy.positionY)
                return distA < distB
            }!
            let dist = hexDistance(x1: closestPlayer.positionX, y1: closestPlayer.positionY, x2: enemy.positionX, y2: enemy.positionY)
            if dist > 1 {
                // Single .enemyMoved post at end (see corpmage fix above).
                let eliteStartX = enemy.positionX, eliteStartY = enemy.positionY
                for _ in 0..<3 {
                    if let (newX, newY) = bfsPathfind(from: enemy, toward: closestPlayer) {
                        // Overwatch: check before each step
                        for (attackerId, _) in overwatchers {
                            fireOverwatchShot(atEnemy: enemy, attackerId: attackerId)
                        }
                        enemy.positionX = newX; enemy.positionY = newY
                        let newDist = hexDistance(x1: closestPlayer.positionX, y1: closestPlayer.positionY, x2: enemy.positionX, y2: enemy.positionY)
                        if newDist <= 1 { break }
                    } else { break }
                }
                if enemy.positionX != eliteStartX || enemy.positionY != eliteStartY {
                    addLog("→ \(enemy.name) charges!")
                    NotificationCenter.default.post(name: .enemyMoved, object: nil,
                        userInfo: ["enemyId": enemy.id.uuidString,
                                   "x": enemy.positionX, "y": enemy.positionY])
                }
                let afterMoveDist = hexDistance(x1: closestPlayer.positionX, y1: closestPlayer.positionY, x2: enemy.positionX, y2: enemy.positionY)
                if afterMoveDist > 1 { return }
                if enemyMovedThisTurn() { return }
            }
            // Enemy attack pool: AGI + weapon accuracy/2 (approx skill)
            let weaponAccuracy = enemy.equippedWeapon?.accuracy ?? 3
            let enemyAttackPool = enemy.attributes.agi + (weaponAccuracy / 2 + 1)

            // Player defense pool: REA + AGI + defend bonus + cover
            let defenseBonus = isCharacterDefending(closestPlayer.id) ? 3 : 0
            let eliteCoverCount = CombatMechanics.coverBetween(
                tiles: currentMissionTiles,
                fromX: enemy.positionX, fromY: enemy.positionY,
                toX: closestPlayer.positionX, toY: closestPlayer.positionY
            )
            let elitePlayerCoverBonus = CombatMechanics.coverDefenseBonus(count: eliteCoverCount)
            // FLANKED runners defend at -2 (min-1 clamp) — see performAttack.
            // (No cover-degrade roll here: elites strike adjacent, and a
            // 1-tile line has no intermediate cover tiles to splinter.)
            let eliteFlank = flankedDefensePenalty(target: closestPlayer, attacker: enemy)
            let playerDefensePool = max(1, closestPlayer.defensePool() + defenseBonus + elitePlayerCoverBonus - eliteFlank)

            let attackRoll = DiceEngine.roll(pool: enemyAttackPool)
            let defenseRoll = DiceEngine.roll(pool: playerDefensePool)
            let netHits = max(0, attackRoll.hits - defenseRoll.hits)

            if netHits == 0 {
                addLog("→ \(enemy.name) attacks \(closestPlayer.name) — DODGED!")
            } else {
                let weaponDmg = enemy.equippedWeapon?.damage ?? 4
                let baseDmg = weaponDmg + netHits
                let ap = enemy.equippedWeapon?.armorPiercing ?? 0
                let soakPool = max(0, closestPlayer.computeDerived().soak - ap)
                let soakRoll = DiceEngine.roll(pool: soakPool)
                let dmg = escalatedIncomingDamage(max(0, baseDmg - soakRoll.hits))

                if dmg > 0 {
                    let isStun = enemy.equippedWeapon?.isStunDamage ?? false
                    closestPlayer.takeDamage(amount: dmg, isStun: isStun)
                    let dmgType = isStun ? "S" : "P"
                    HapticsManager.shared.playerDamaged()
                    addLog("⚠️ \(enemy.name) hits \(closestPlayer.name)! \(netHits) net hits → \(dmg)\(dmgType) dmg. (HP \(closestPlayer.currentHP)/\(closestPlayer.maxHP) | Stun \(closestPlayer.currentStun)/\(closestPlayer.maxStun))")
                    NotificationCenter.default.post(name: .playerHit, object: nil, userInfo: ["playerId": closestPlayer.id.uuidString, "damage": dmg, "enemyId": enemy.id.uuidString])
                    if !closestPlayer.isAlive { CombatFlowController.handlePlayerKilled(gameState: self, char: closestPlayer) }
                } else {
                    addLog("→ \(enemy.name) attacks — \(closestPlayer.name) soaks all damage!")
                }
            }

        case "bossmage":
            // M3 boss — Sato Unbound. Aggressive blood-magic caster. Per
            // playtest 2026-05-23: boss was "stuck in one place for several
            // turns" — root cause was preferredRange=3 letting him stop the
            // moment a player got near. Re-evaluates the closest target every
            // step and keeps closing. Playtest 2026-06: still "not very
            // aggressive, doesn't move much" — he planted at range 2 and his
            // move budget was only 2. Now moveRange=3 (see TurnManager) AND
            // preferredRange=1, so he glides right up to the party and stays in
            // their faces (his blood nova also wants to be adjacent for max
            // AoE). Still steps one tile per move-budget iteration to avoid the
            // bfsPathfind teleport pattern; only stops when adjacent or cornered.
            do {
                let startX = enemy.positionX
                let startY = enemy.positionY
                let preferredRange = 1
                for _ in 0..<enemy.moveRange {
                    // Re-target every step — players may move past the boss
                    // mid-pursuit; without this he'd commit to a stale target
                    // and miss closer threats.
                    guard let closestPlayer = livingPlayers.min(by: { a, b in
                        let distA = hexDistance(x1: a.positionX, y1: a.positionY, x2: enemy.positionX, y2: enemy.positionY)
                        let distB = hexDistance(x1: b.positionX, y1: b.positionY, x2: enemy.positionX, y2: enemy.positionY)
                        return distA < distB
                    }) else { break }
                    let curDist = hexDistance(x1: closestPlayer.positionX, y1: closestPlayer.positionY,
                                              x2: enemy.positionX, y2: enemy.positionY)
                    if curDist <= preferredRange { break }
                    if let (newX, newY) = bfsNextStep(from: enemy, toward: closestPlayer) {
                        for (attackerId, _) in overwatchers {
                            fireOverwatchShot(atEnemy: enemy, attackerId: attackerId)
                        }
                        enemy.positionX = newX; enemy.positionY = newY
                    } else {
                        break
                    }
                }
                // Re-pick spell target from final position so the cast
                // resolves against whoever is actually closest now.
                guard let closestPlayer = livingPlayers.min(by: { a, b in
                    let distA = hexDistance(x1: a.positionX, y1: a.positionY, x2: enemy.positionX, y2: enemy.positionY)
                    let distB = hexDistance(x1: b.positionX, y1: b.positionY, x2: enemy.positionX, y2: enemy.positionY)
                    return distA < distB
                }) else { return }
                if enemy.positionX != startX || enemy.positionY != startY {
                    addLog("→ \(enemy.name) glides forward, robes trailing red")
                    NotificationCenter.default.post(name: .enemyMoved, object: nil,
                        userInfo: ["enemyId": enemy.id.uuidString,
                                   "x": enemy.positionX, "y": enemy.positionY])
                }
                // ── Spell selection — Sato wields several blood-magic attacks.
                let afterDist = hexDistance(x1: closestPlayer.positionX, y1: closestPlayer.positionY,
                                            x2: enemy.positionX, y2: enemy.positionY)

                // One blood-magic strike vs a single target. Returns net damage
                // dealt (used by the siphon self-heal). Posts the red bloodbolt VFX.
                func castBolt(on target: Character, label: String, dmgScale: Double) -> Int {
                    let attackPool = enemy.attributes.agi + 4
                    // FLANKED runners defend at -2 (min-1 clamp) — see performAttack.
                    let boltFlank = flankedDefensePenalty(target: target, attacker: enemy)
                    let defensePool = max(1, target.defensePool() - boltFlank)
                    let net = max(0, DiceEngine.roll(pool: attackPool).hits - DiceEngine.roll(pool: defensePool).hits)
                    if net == 0 { addLog("→ \(label) — \(target.name) dives clear!"); return 0 }
                    let baseDmg = Int((Double(8 + net) * dmgScale).rounded())
                    let soakPool = max(0, target.computeDerived().soak - 3)
                    let dmg = escalatedIncomingDamage(max(0, baseDmg - DiceEngine.roll(pool: soakPool).hits))
                    guard dmg > 0 else { addLog("→ \(label) — \(target.name) soaks it!"); return 0 }
                    target.takeDamage(amount: dmg, isStun: false)
                    HapticsManager.shared.playerDamaged()
                    addLog("🩸 \(label) hits \(target.name) — \(dmg)P. (HP \(target.currentHP)/\(target.maxHP))")
                    NotificationCenter.default.post(name: .playerHit, object: nil, userInfo: [
                        "playerId": target.id.uuidString, "damage": dmg, "enemyId": enemy.id.uuidString])
                    NotificationCenter.default.post(name: .gunfireEffect, object: nil, userInfo: [
                        "fromX": enemy.positionX, "fromY": enemy.positionY,
                        "toX": target.positionX, "toY": target.positionY,
                        "weaponType": "rifle", "enemyArchetype": enemy.archetype])
                    if !target.isAlive { CombatFlowController.handlePlayerKilled(gameState: self, char: target) }
                    return dmg
                }

                if afterDist <= 6 {
                    // BLOOD NOVA is now a SITUATIONAL trigger, not a blind
                    // 28% coin flip: it fires only when the party is CLUSTERED
                    // — ≥2 living runners inside the nova's footprint (the
                    // closest runner + everyone within 1 of them, i.e. the
                    // same `targets` filter the old roll computed after the
                    // fact). Clustered → HIGH chance (70%, still a dash of
                    // unpredictability); spread out → he never wastes the
                    // AoE on one body and falls through to siphon/bolt.
                    // Design intent: rewards the player for spreading out and
                    // makes Sato read as a caster who PUNISHES clumping.
                    let novaTargets = livingPlayers.filter {
                        hexDistance(x1: $0.positionX, y1: $0.positionY,
                                    x2: closestPlayer.positionX, y2: closestPlayer.positionY) <= 1
                    }
                    let partyClustered = novaTargets.count >= 2
                    if partyClustered && Double.random(in: 0..<1) < 0.70 {
                        // BLOOD NOVA — AoE: the closest runner + everyone within 1.
                        addLog("🩸 \(enemy.name): \"Bleed, all of you.\" — BLOOD NOVA!")
                        for t in novaTargets { _ = castBolt(on: t, label: "\(enemy.name) blood nova", dmgScale: 0.7) }
                    } else if Double.random(in: 0..<1) < 0.5 {
                        // BLOOD SIPHON — drain a runner, heal himself for half.
                        let dealt = castBolt(on: closestPlayer, label: "\(enemy.name) blood siphon", dmgScale: 1.0)
                        if dealt > 0 {
                            let healed = max(1, dealt / 2)
                            enemy.currentHP = min(enemy.maxHP, enemy.currentHP + healed)
                            addLog("🩸 \(enemy.name) siphons \(healed) HP. (HP \(enemy.currentHP)/\(enemy.maxHP))")
                        }
                    } else {
                        // BLOOD-BOLT — single hard hit.
                        _ = castBolt(on: closestPlayer, label: "\(enemy.name) blood-bolt", dmgScale: 1.0)
                    }
                    // BLOOD FRENZY — Sato lashes out a SECOND time most turns.
                    // Playtest: one cast/turn read as "too easy" for a boss, so
                    // ~45% of the time he chains an immediate follow-up bolt at
                    // whoever's closest and still standing — keeps real pressure
                    // on without needing more HP.
                    if let frenzyTarget = livingPlayers.min(by: { a, b in
                        hexDistance(x1: a.positionX, y1: a.positionY, x2: enemy.positionX, y2: enemy.positionY)
                      < hexDistance(x1: b.positionX, y1: b.positionY, x2: enemy.positionX, y2: enemy.positionY)
                    }), Double.random(in: 0..<1) < 0.45 {
                        addLog("🩸 \(enemy.name) — BLOOD FRENZY!")
                        _ = castBolt(on: frenzyTarget, label: "\(enemy.name) blood frenzy", dmgScale: 0.7)
                    }
                }
            }

        case "bossmech":
            // M5 boss — heavy autocannon, range 6, aggressively pursues. The
            // mech holds at preferred range ~4 (close enough to threaten,
            // not so close it walks into melee), advancing ONE tile per
            // move-budget iteration via `bfsNextStep`. Earlier this used
            // `bfsPathfind` which returns a tile ADJACENT TO THE PLAYER —
            // that teleported the mech across the whole room in one tick
            // and looked like a glitch (sometimes the player saw the boss
            // "not moving" because it pinned itself in melee on turn 1 and
            // never moved again). Step-by-step pursuit reads as proper AI.
            do {
                let closestPlayer = livingPlayers.min { a, b in
                    let distA = hexDistance(x1: a.positionX, y1: a.positionY, x2: enemy.positionX, y2: enemy.positionY)
                    let distB = hexDistance(x1: b.positionX, y1: b.positionY, x2: enemy.positionX, y2: enemy.positionY)
                    return distA < distB
                }!
                let startX = enemy.positionX
                let startY = enemy.positionY
                let preferredRange = 4   // autocannon optimal: ~4 tiles
                for _ in 0..<enemy.moveRange {
                    let curDist = hexDistance(x1: closestPlayer.positionX, y1: closestPlayer.positionY,
                                              x2: enemy.positionX, y2: enemy.positionY)
                    // At preferred range — don't just park (that read as the
                    // boss "chilling in one spot"). STRAFE to a walkable
                    // neighbour at roughly the same range so the mech keeps
                    // prowling the arena, then stop advancing for this turn.
                    if curDist <= preferredRange {
                        let options = PathingAndAIHelpers.hexNeighbors(gameState: self, x: enemy.positionX, y: enemy.positionY)
                            .filter { PathingAndAIHelpers.tileWalkable(gameState: self, x: $0.0, y: $0.1, excluding: enemy.id) }
                            .filter { abs(hexDistance(x1: $0.0, y1: $0.1,
                                                      x2: closestPlayer.positionX, y2: closestPlayer.positionY) - preferredRange) <= 1 }
                        if let pick = options.randomElement() {
                            enemy.positionX = pick.0; enemy.positionY = pick.1
                        }
                        break
                    }
                    if let (newX, newY) = bfsNextStep(from: enemy, toward: closestPlayer) {
                        for (attackerId, _) in overwatchers {
                            fireOverwatchShot(atEnemy: enemy, attackerId: attackerId)
                        }
                        enemy.positionX = newX; enemy.positionY = newY
                    } else {
                        break
                    }
                }
                if enemy.positionX != startX || enemy.positionY != startY {
                    addLog("→ \(enemy.name) advances on \(closestPlayer.name)")
                    NotificationCenter.default.post(name: .enemyMoved, object: nil,
                        userInfo: ["enemyId": enemy.id.uuidString,
                                   "x": enemy.positionX, "y": enemy.positionY])
                }
                // Fire from new position. SUPPRESSING BARRAGE is a
                // SITUATIONAL trigger now, not a blind 30% flip: the mech
                // walks the autocannon across the party only when it's
                // actually CLUSTERED — ≥2 living runners inside the barrage
                // footprint (closest runner + anyone within 1, the same
                // `inBlast` filter the old roll computed after committing).
                // Clustered → HIGH chance (70%, a little randomness so it
                // isn't clockwork); spread out → the barrage would be a
                // single-target shot with a damage MALUS (0.75×), so it
                // falls through to the full-power single autocannon shot.
                // Design intent: rewards the player for spreading out.
                let afterDist = hexDistance(x1: closestPlayer.positionX, y1: closestPlayer.positionY,
                                            x2: enemy.positionX, y2: enemy.positionY)
                // Autocannon reach. Was a hard 6, which combined with a 2-tile
                // move budget meant a mech that started the fight across the
                // arena never fired at all — it walked, ate four runners' worth
                // of fire, and died (playtest 2026-07-25). 8 lets a heavy weapon
                // threaten from where it actually spawns; the closing turns are
                // still the party's window to hurt it for free.
                if afterDist <= 8 {
                    let inBlast = livingPlayers.filter {
                        hexDistance(x1: $0.positionX, y1: $0.positionY,
                                    x2: closestPlayer.positionX, y2: closestPlayer.positionY) <= 1
                    }
                    let partyClustered = inBlast.count >= 2
                    if partyClustered && Double.random(in: 0..<1) < 0.70 {
                        addLog("⚠️ \(enemy.name) — SUPPRESSING BARRAGE!")
                        for t in inBlast {
                            bossRangedStrike(enemy: enemy, target: t,
                                             label: "\(enemy.name) barrage", dmgScale: 0.75)
                        }
                    } else {
                        bossRangedStrike(enemy: enemy, target: closestPlayer,
                                         label: "\(enemy.name) autocannon")
                    }
                }
            }

        case "bossagi":
            // M6 boss — a flickering data-construct. Instead of rushing in and
            // freezing at melee (the old behaviour, which made it look static),
            // it KITES at mid range and constantly REPOSITIONS — backing off
            // when crowded, drifting in when too far, and strafing sideways
            // when in the band — so it's never a stationary target. Then it
            // strikes with Reality Glitch (range 6), occasionally ECHOing.
            let closestPlayer = livingPlayers.min { a, b in
                let distA = hexDistance(x1: a.positionX, y1: a.positionY, x2: enemy.positionX, y2: enemy.positionY)
                let distB = hexDistance(x1: b.positionX, y1: b.positionY, x2: enemy.positionX, y2: enemy.positionY)
                return distA < distB
            }!
            let startX = enemy.positionX
            let startY = enemy.positionY
            let preferred = 3
            let dist0 = hexDistance(x1: closestPlayer.positionX, y1: closestPlayer.positionY,
                                    x2: enemy.positionX, y2: enemy.positionY)
            if dist0 < preferred {
                // Crowded — phase away to re-open the gap.
                let (rx, ry) = bestRetreatTile(for: enemy, awayFrom: closestPlayer)
                enemy.positionX = rx; enemy.positionY = ry
            } else if dist0 > preferred + 1 {
                // Too far — drift in a couple of steps (triggering overwatch).
                for _ in 0..<min(2, enemy.moveRange) {
                    if hexDistance(x1: closestPlayer.positionX, y1: closestPlayer.positionY,
                                   x2: enemy.positionX, y2: enemy.positionY) <= preferred { break }
                    if let (nx, ny) = bfsNextStep(from: enemy, toward: closestPlayer) {
                        for (attackerId, _) in overwatchers {
                            fireOverwatchShot(atEnemy: enemy, attackerId: attackerId)
                        }
                        enemy.positionX = nx; enemy.positionY = ny
                    } else { break }
                }
            } else {
                // In the band — STRAFE to a walkable neighbour that keeps
                // roughly the same range, so it keeps shifting around.
                let options = PathingAndAIHelpers.hexNeighbors(gameState: self, x: enemy.positionX, y: enemy.positionY)
                    .filter { PathingAndAIHelpers.tileWalkable(gameState: self, x: $0.0, y: $0.1, excluding: enemy.id) }
                    .filter { abs(hexDistance(x1: $0.0, y1: $0.1,
                                              x2: closestPlayer.positionX, y2: closestPlayer.positionY) - preferred) <= 1 }
                if let pick = options.randomElement() { enemy.positionX = pick.0; enemy.positionY = pick.1 }
            }
            if enemy.positionX != startX || enemy.positionY != startY {
                addLog("→ \(enemy.name) phase-shifts around \(closestPlayer.name)")
                NotificationCenter.default.post(name: .enemyMoved, object: nil,
                    userInfo: ["enemyId": enemy.id.uuidString,
                               "x": enemy.positionX, "y": enemy.positionY])
            }

            // Strike — Reality Glitch, with an occasional GLITCH ECHO 2nd hit.
            let afterDist = hexDistance(x1: closestPlayer.positionX, y1: closestPlayer.positionY,
                                        x2: enemy.positionX, y2: enemy.positionY)
            if afterDist <= 6 {
                bossRangedStrike(enemy: enemy, target: closestPlayer, label: "AGI-PRIME Reality Glitch")
                // GLITCH ECHO is a SITUATIONAL trigger now, not a blind 30%
                // flip: the echo re-fires only when the party is CLUSTERED —
                // ≥2 living runners within 1 of the glitched target (inside
                // the ability's reach). Clustered → HIGH chance (70%, small
                // random element kept); spread out → the construct doesn't
                // burn the echo and the turn stays a single Reality Glitch.
                // Design intent: rewards the player for spreading out —
                // bunching around a runner AGI-PRIME is targeting invites
                // the double-hit, which reads as the AI exploiting density.
                let nearGlitchTarget = livingPlayers.filter {
                    hexDistance(x1: $0.positionX, y1: $0.positionY,
                                x2: closestPlayer.positionX, y2: closestPlayer.positionY) <= 1
                }
                let partyClustered = nearGlitchTarget.count >= 2
                if closestPlayer.isAlive && partyClustered && Double.random(in: 0..<1) < 0.70 {
                    addLog("✨ \(enemy.name) — GLITCH ECHO!")
                    bossRangedStrike(enemy: enemy, target: closestPlayer, label: "AGI-PRIME echo", dmgScale: 0.7)
                }
            }

        case "bosscorp":
            // M4 boss — Vera Koss. Agile smartlink shooter who KITES at mid
            // range, CALLS IN security drones, and MARKS a runner for an
            // amplified EXECUTE shot (telegraphed a turn ahead so the player can
            // move the marked character or kill her drones first).
            let closestPlayer = livingPlayers.min { a, b in
                let dA = hexDistance(x1: a.positionX, y1: a.positionY, x2: enemy.positionX, y2: enemy.positionY)
                let dB = hexDistance(x1: b.positionX, y1: b.positionY, x2: enemy.positionX, y2: enemy.positionY)
                return dA < dB
            }!
            let startX = enemy.positionX
            let startY = enemy.positionY
            // Playtest: Vera "just moved away and didn't really attack" — she
            // kited at range 4 and RETREATED whenever a runner closed, so she
            // rarely committed. Now she PRESSES: closes to range 2 and holds
            // there to fire. Only gives a single step of ground if a runner is
            // literally in her face (adjacent) — never a full cross-room flee.
            let preferred = 2
            let dist0 = hexDistance(x1: closestPlayer.positionX, y1: closestPlayer.positionY,
                                    x2: enemy.positionX, y2: enemy.positionY)
            if dist0 > preferred {
                for _ in 0..<enemy.moveRange {
                    if hexDistance(x1: closestPlayer.positionX, y1: closestPlayer.positionY,
                                   x2: enemy.positionX, y2: enemy.positionY) <= preferred { break }
                    if let (nx, ny) = bfsNextStep(from: enemy, toward: closestPlayer) {
                        for (attackerId, _) in overwatchers {
                            fireOverwatchShot(atEnemy: enemy, attackerId: attackerId)
                        }
                        enemy.positionX = nx; enemy.positionY = ny
                    } else { break }
                }
            } else if dist0 <= 1 {
                let (rx, ry) = bestRetreatTile(for: enemy, awayFrom: closestPlayer)
                enemy.positionX = rx; enemy.positionY = ry
            }
            if enemy.positionX != startX || enemy.positionY != startY {
                addLog("→ \(enemy.name) repositions on \(closestPlayer.name)")
                NotificationCenter.default.post(name: .enemyMoved, object: nil,
                    userInfo: ["enemyId": enemy.id.uuidString,
                               "x": enemy.positionX, "y": enemy.positionY])
            }

            // Drop a stale mark if that runner is already down.
            if let mid = corpBossMarkedId, !livingPlayers.contains(where: { $0.id == mid }) {
                corpBossMarkedId = nil
            }
            let afterDist = hexDistance(x1: closestPlayer.positionX, y1: closestPlayer.positionY,
                                        x2: enemy.positionX, y2: enemy.positionY)

            if let mid = corpBossMarkedId,
               let marked = livingPlayers.first(where: { $0.id == mid }),
               hexDistance(x1: marked.positionX, y1: marked.positionY,
                           x2: enemy.positionX, y2: enemy.positionY) <= 6 {
                // EXECUTE the marked runner — amplified shot, mark consumed.
                addLog("🎯 \(enemy.name): \"Terminate.\" — EXECUTE on \(marked.name)!")
                bossRangedStrike(enemy: enemy, target: marked, label: "\(enemy.name) EXECUTE", dmgScale: 1.7)
                corpBossMarkedId = nil
            } else {
                // Rebalanced so she ATTACKS most turns (playtest: "doesn't
                // really attack"). Summon/mark each got rarer; the default is now
                // a smartlink burst with a chance at a rapid DOUBLE-TAP second
                // shot for extra punch + attack variety.
                let roll = Double.random(in: 0..<1)
                // MARK targeting is board-state driven now: Vera flags the
                // LOWEST-HP living runner in her engagement range (nearest
                // breaks HP ties), not whoever happens to stand closest —
                // she's an executive closing accounts, and it telegraphs a
                // real threat the player must answer (heal, reposition, or
                // kill her before the EXECUTE lands). The roll window (and
                // her summon cap / drone count) are unchanged — the trigger
                // frequency is the same, only the VICTIM selection got smart.
                // Her DOUBLE-TAP follow-up below stays pure-chance as before.
                let executeMark = livingPlayers
                    .filter {
                        hexDistance(x1: $0.positionX, y1: $0.positionY,
                                    x2: enemy.positionX, y2: enemy.positionY) <= 6
                    }
                    .min { a, b in
                        if a.currentHP != b.currentHP { return a.currentHP < b.currentHP }
                        return hexDistance(x1: a.positionX, y1: a.positionY, x2: enemy.positionX, y2: enemy.positionY)
                             < hexDistance(x1: b.positionX, y1: b.positionY, x2: enemy.positionX, y2: enemy.positionY)
                    }
                if roll < 0.15 && corpBossSummons < 2 {
                    corpBossSummons += 1
                    summonCorpDrone(near: enemy)
                } else if roll < 0.35 && corpBossMarkedId == nil, let weakest = executeMark {
                    corpBossMarkedId = weakest.id
                    addLog("⊕ \(enemy.name): \"You're flagged.\" — \(weakest.name) MARKED FOR TERMINATION.")
                } else if afterDist <= 6 {
                    bossRangedStrike(enemy: enemy, target: closestPlayer, label: "\(enemy.name) smartlink burst")
                    if closestPlayer.isAlive && Double.random(in: 0..<1) < 0.35 {
                        addLog("🎯 \(enemy.name) — DOUBLE-TAP!")
                        bossRangedStrike(enemy: enemy, target: closestPlayer, label: "\(enemy.name) double-tap", dmgScale: 0.7)
                    }
                }
            }

        case "turret":
            // Stationary sentry — NEVER moves. Smartlinked (accurate despite
            // AGI 0), it fires at the closest player within its ~6-tile arc.
            // Players beat it by breaking the lane (cover) or destroying it.
            //
            // OVERWATCH: with no target in arc/LOS, the turret doesn't waste
            // the turn "holding" — it banks a reaction shot instead. Any
            // player MOVEMENT commit next round while the bank is live (and
            // the turret has range + LOS) triggers reaction fire at halved
            // net hits — see GameState.fireEnemyOverwatchShots. The stale
            // bank is dropped first: the turret re-decides every turn.
            enemyOverwatchers.removeValue(forKey: enemy.id)
            let turretPool = (enemy.equippedWeapon?.accuracy ?? 6) + 2   // smartlink, not agi
            guard let target = livingPlayers.min(by: {
                hexDistance(x1: $0.positionX, y1: $0.positionY, x2: enemy.positionX, y2: enemy.positionY) <
                hexDistance(x1: $1.positionX, y1: $1.positionY, x2: enemy.positionX, y2: enemy.positionY)
            }) else { return }
            let dist = hexDistance(x1: target.positionX, y1: target.positionY,
                                   x2: enemy.positionX, y2: enemy.positionY)
            guard dist <= 6, !isLineBlockedByWall(fromX: enemy.positionX, fromY: enemy.positionY,
                                                  toX: target.positionX, toY: target.positionY) else {
                bankEnemyOverwatch(for: enemy, pool: turretPool)
                return
            }
            let attackPool = turretPool
            let cover = CombatMechanics.coverBetween(tiles: currentMissionTiles,
                                                     fromX: enemy.positionX, fromY: enemy.positionY,
                                                     toX: target.positionX, toY: target.positionY)
            let defendBonus = isCharacterDefending(target.id) ? 3 : 0
            // FLANKED runners defend at -2 (min-1 clamp) — see performAttack.
            let turretFlank = flankedDefensePenalty(target: target, attacker: enemy)
            let defPool = max(1, target.defensePool()
                + CombatMechanics.coverDefenseBonus(count: cover) + defendBonus - turretFlank)
            let net = max(0, DiceEngine.roll(pool: attackPool).hits - DiceEngine.roll(pool: defPool).hits)
            // Destructible cover — after the dice, hit or miss (see performAttack).
            maybeDegradeCoverAlongShot(
                fromX: enemy.positionX, fromY: enemy.positionY,
                toX: target.positionX, toY: target.positionY)
            if net == 0 {
                addLog("→ \(enemy.name) — \(target.name) stays out of the line of fire!")
            } else {
                let baseDmg = (enemy.equippedWeapon?.damage ?? 7) + net
                let ap = enemy.equippedWeapon?.armorPiercing ?? 2
                let soak = DiceEngine.roll(pool: max(0, target.computeDerived().soak - ap)).hits
                let dmg = escalatedIncomingDamage(max(0, baseDmg - soak))
                if dmg > 0 {
                    target.takeDamage(amount: dmg, isStun: false)
                    HapticsManager.shared.playerDamaged()
                    addLog("🔫 \(enemy.name) suppressing fire hits \(target.name) — \(dmg)P. (HP \(target.currentHP)/\(target.maxHP))")
                    NotificationCenter.default.post(name: .playerHit, object: nil, userInfo: [
                        "playerId": target.id.uuidString, "damage": dmg, "enemyId": enemy.id.uuidString])
                    NotificationCenter.default.post(name: .gunfireEffect, object: nil, userInfo: [
                        "fromX": enemy.positionX, "fromY": enemy.positionY,
                        "toX": target.positionX, "toY": target.positionY,
                        "weaponType": "rifle", "enemyArchetype": enemy.archetype])
                    if !target.isAlive { CombatFlowController.handlePlayerKilled(gameState: self, char: target) }
                } else {
                    addLog("→ \(enemy.name) — \(target.name) soaks the burst!")
                }
            }

        case "rigger":
            // Drone Master — its turn is mostly about TAPPING IN drones; it
            // hangs back and plinks. Kill it to shut off the drone tap.
            guard let target = livingPlayers.min(by: {
                hexDistance(x1: $0.positionX, y1: $0.positionY, x2: enemy.positionX, y2: enemy.positionY) <
                hexDistance(x1: $1.positionX, y1: $1.positionY, x2: enemy.positionX, y2: enemy.positionY)
            }) else { return }
            // Signature: call in a security drone — capped so it can't flood.
            // Lifetime cap too (mirrors Vera's corpBossSummons): the
            // concurrent <3 check alone made the rigger an infinite XP/loot
            // faucet — park the party and farm its free drones forever.
            let droneCount = livingEnemies.filter { $0.archetype.lowercased() == "drone" }.count
            if droneCount < 3 && riggerSummons[enemy.id, default: 0] < 3 {
                riggerSummons[enemy.id, default: 0] += 1
                summonCorpDrone(near: enemy)
            }
            // Stay back: retreat if a runner is breathing down its neck.
            if hexDistance(x1: target.positionX, y1: target.positionY,
                           x2: enemy.positionX, y2: enemy.positionY) < 3 {
                let (rx, ry) = bestRetreatTile(for: enemy, awayFrom: target)
                if rx != enemy.positionX || ry != enemy.positionY {
                    enemy.positionX = rx; enemy.positionY = ry
                    NotificationCenter.default.post(name: .enemyMoved, object: nil,
                        userInfo: ["enemyId": enemy.id.uuidString, "x": rx, "y": ry])
                }
            }
            // Plink at range with the machine pistol.
            if hexDistance(x1: target.positionX, y1: target.positionY,
                           x2: enemy.positionX, y2: enemy.positionY) <= 6 {
                _ = bossRangedStrike(enemy: enemy, target: target, label: "\(enemy.name) machine pistol")
            }

        case "grenadier":
            // Lobs a grenade at the closest runner — the blast also catches any
            // runner ADJACENT to the impact, so a clustered party eats it
            // together. Advances into ~6-tile throwing range first.
            guard let target = livingPlayers.min(by: {
                hexDistance(x1: $0.positionX, y1: $0.positionY, x2: enemy.positionX, y2: enemy.positionY) <
                hexDistance(x1: $1.positionX, y1: $1.positionY, x2: enemy.positionX, y2: enemy.positionY)
            }) else { return }
            if hexDistance(x1: target.positionX, y1: target.positionY,
                           x2: enemy.positionX, y2: enemy.positionY) > 6 {
                for _ in 0..<max(1, enemy.moveRange) {
                    if hexDistance(x1: target.positionX, y1: target.positionY,
                                   x2: enemy.positionX, y2: enemy.positionY) <= 6 { break }
                    if let (nx, ny) = bfsNextStep(from: enemy, toward: target) {
                        enemy.positionX = nx; enemy.positionY = ny
                    } else { break }
                }
                NotificationCenter.default.post(name: .enemyMoved, object: nil,
                    userInfo: ["enemyId": enemy.id.uuidString, "x": enemy.positionX, "y": enemy.positionY])
            }
            if hexDistance(x1: target.positionX, y1: target.positionY,
                           x2: enemy.positionX, y2: enemy.positionY) <= 6 {
                let inBlast = livingPlayers.filter {
                    hexDistance(x1: $0.positionX, y1: $0.positionY,
                                x2: target.positionX, y2: target.positionY) <= 1
                }
                addLog("💣 \(enemy.name) lobs a grenade!\(inBlast.count > 1 ? " — \(inBlast.count) runners caught in the blast!" : "")")
                NotificationCenter.default.post(name: .fireballEffect, object: nil,
                    userInfo: ["x": target.positionX, "y": target.positionY,
                               "fromX": enemy.positionX, "fromY": enemy.positionY])
                // Animate the throw + draw the arc on the primary target.
                NotificationCenter.default.post(name: .playerHit, object: nil, userInfo: [
                    "playerId": target.id.uuidString, "damage": 0, "enemyId": enemy.id.uuidString])
                let acc = enemy.equippedWeapon?.accuracy ?? 4
                let ap = enemy.equippedWeapon?.armorPiercing ?? 2
                let base = enemy.equippedWeapon?.damage ?? 6
                for p in inBlast {
                    let atk = enemy.attributes.agi + acc / 2 + 1
                    let def = p.defensePool() + (isCharacterDefending(p.id) ? 3 : 0)
                    let net = max(0, DiceEngine.roll(pool: atk).hits - DiceEngine.roll(pool: def).hits)
                    let soak = DiceEngine.roll(pool: max(0, p.computeDerived().soak - ap)).hits
                    let dmg = escalatedIncomingDamage(max(0, base + net - soak))
                    if dmg > 0 {
                        p.takeDamage(amount: dmg, isStun: false)
                        addLog("  → \(p.name) takes \(dmg)P from the blast. (HP \(p.currentHP)/\(p.maxHP))")
                        NotificationCenter.default.post(name: .characterHit, object: nil,
                            userInfo: ["characterId": p.id.uuidString, "damage": dmg])
                        if !p.isAlive { CombatFlowController.handlePlayerKilled(gameState: self, char: p) }
                    } else {
                        addLog("  → \(p.name) shrugs off the shrapnel.")
                    }
                }
                HapticsManager.shared.playerDamaged()
                // The grenadier's lob is a real AoE blast — explosive barrels
                // within 1 of the impact tile go up too (and the 6P barrel
                // AoE hits BOTH rosters, so a lob into the barrel stack the
                // grenadier's own squadmate hides behind backfires). One
                // pass, no chaining — see detonateBarrelsNear.
                detonateBarrelsNear(impactTiles: [(x: target.positionX, y: target.positionY)])
            }

        case "repairdrone":
            // Robotic medic — repairs the most-damaged MECHANICAL ally.
            let mechTypes: Set<String> = ["drone", "mech", "turret", "bossmech"]
            let damaged = livingEnemies.filter {
                mechTypes.contains($0.archetype.lowercased()) && $0.currentHP < $0.maxHP && $0.id != enemy.id
            }.min { ($0.currentHP - $0.maxHP) < ($1.currentHP - $1.maxHP) }
            if let ally = damaged {
                // Drift toward the ally to "weld" it (pathfind toward an ally Enemy).
                if hexDistance(x1: ally.positionX, y1: ally.positionY, x2: enemy.positionX, y2: enemy.positionY) > 1 {
                    if let (nx, ny) = bfsPathfindToWounded(from: enemy, toward: ally) {
                        enemy.positionX = nx; enemy.positionY = ny
                        NotificationCenter.default.post(name: .enemyMoved, object: nil,
                            userInfo: ["enemyId": enemy.id.uuidString, "x": enemy.positionX, "y": enemy.positionY])
                    }
                }
                let healed = max(0, min(6, ally.maxHP - ally.currentHP))
                ally.currentHP += healed
                addLog("🔧 \(enemy.name) repairs \(ally.name) — +\(healed) HP. (\(ally.currentHP)/\(ally.maxHP))")
                NotificationCenter.default.post(name: .enemyHit, object: nil,
                    userInfo: ["enemyId": ally.id.uuidString, "damage": -healed])
            } else {
                addLog("→ \(enemy.name) idles — no machines to repair.")
            }

        case "sprayer":
            // Area denial — corrosive cone hits target + adjacent runners and
            // leaves a lingering CORROSION (DoT) on anyone caught. Armor-piercing.
            guard let target = livingPlayers.min(by: {
                hexDistance(x1: $0.positionX, y1: $0.positionY, x2: enemy.positionX, y2: enemy.positionY) <
                hexDistance(x1: $1.positionX, y1: $1.positionY, x2: enemy.positionX, y2: enemy.positionY)
            }) else { return }
            if hexDistance(x1: target.positionX, y1: target.positionY,
                           x2: enemy.positionX, y2: enemy.positionY) > 5 {
                for _ in 0..<max(1, enemy.moveRange) {
                    if hexDistance(x1: target.positionX, y1: target.positionY,
                                   x2: enemy.positionX, y2: enemy.positionY) <= 5 { break }
                    if let (nx, ny) = bfsNextStep(from: enemy, toward: target) {
                        enemy.positionX = nx; enemy.positionY = ny
                    } else { break }
                }
                NotificationCenter.default.post(name: .enemyMoved, object: nil,
                    userInfo: ["enemyId": enemy.id.uuidString, "x": enemy.positionX, "y": enemy.positionY])
            }
            if hexDistance(x1: target.positionX, y1: target.positionY,
                           x2: enemy.positionX, y2: enemy.positionY) <= 6 {
                let inBlast = livingPlayers.filter {
                    hexDistance(x1: $0.positionX, y1: $0.positionY,
                                x2: target.positionX, y2: target.positionY) <= 1
                }
                addLog("☣️ \(enemy.name) sprays a corrosive cone!")
                NotificationCenter.default.post(name: .playerHit, object: nil, userInfo: [
                    "playerId": target.id.uuidString, "damage": 0, "enemyId": enemy.id.uuidString])
                let ap = enemy.equippedWeapon?.armorPiercing ?? 3
                let base = enemy.equippedWeapon?.damage ?? 4
                for p in inBlast {
                    let atk = enemy.attributes.agi + 2
                    let def = p.defensePool() + (isCharacterDefending(p.id) ? 3 : 0)
                    let net = max(0, DiceEngine.roll(pool: atk).hits - DiceEngine.roll(pool: def).hits)
                    let soak = DiceEngine.roll(pool: max(0, p.computeDerived().soak - ap)).hits
                    let dmg = escalatedIncomingDamage(max(0, base + net - soak))
                    if dmg > 0 {
                        p.takeDamage(amount: dmg, isStun: false)
                        // Lingering corrosion DoT — refresh rather than stack.
                        if let i = p.statusEffects.firstIndex(where: { if case .burning = $0 { return true } else { return false } }) {
                            p.statusEffects[i] = .burning(roundsLeft: 2)
                        } else {
                            p.statusEffects.append(.burning(roundsLeft: 2))
                        }
                        addLog("  → \(p.name): \(dmg)P + CORRODING. (HP \(p.currentHP)/\(p.maxHP))")
                        NotificationCenter.default.post(name: .characterHit, object: nil,
                            userInfo: ["characterId": p.id.uuidString, "damage": dmg])
                        if !p.isAlive { CombatFlowController.handlePlayerKilled(gameState: self, char: p) }
                    } else {
                        addLog("  → \(p.name) — hazmat holds against the spray.")
                    }
                }
                HapticsManager.shared.playerDamaged()
            }

        case "netrunner":
            // Combat Decker — fires a DATA SPIKE: a matrix attack dealing STUN
            // damage that bypasses meat armor (soaked by WIL only). Fills the
            // stun track → a maxed runner is STUNNED and skips their next turn.
            guard let target = livingPlayers.min(by: {
                hexDistance(x1: $0.positionX, y1: $0.positionY, x2: enemy.positionX, y2: enemy.positionY) <
                hexDistance(x1: $1.positionX, y1: $1.positionY, x2: enemy.positionX, y2: enemy.positionY)
            }) else { return }
            // Hang back like a caster: retreat if crowded, drift in if too far.
            let dn = hexDistance(x1: target.positionX, y1: target.positionY,
                                 x2: enemy.positionX, y2: enemy.positionY)
            if dn < 3 {
                let (rx, ry) = bestRetreatTile(for: enemy, awayFrom: target)
                if rx != enemy.positionX || ry != enemy.positionY {
                    enemy.positionX = rx; enemy.positionY = ry
                    NotificationCenter.default.post(name: .enemyMoved, object: nil,
                        userInfo: ["enemyId": enemy.id.uuidString, "x": rx, "y": ry])
                }
            } else if dn > 6 {
                for _ in 0..<max(1, enemy.moveRange) {
                    if hexDistance(x1: target.positionX, y1: target.positionY,
                                   x2: enemy.positionX, y2: enemy.positionY) <= 6 { break }
                    if let (nx, ny) = bfsNextStep(from: enemy, toward: target) {
                        enemy.positionX = nx; enemy.positionY = ny
                    } else { break }
                }
                NotificationCenter.default.post(name: .enemyMoved, object: nil,
                    userInfo: ["enemyId": enemy.id.uuidString, "x": enemy.positionX, "y": enemy.positionY])
            }
            // Data Spike (range 6): LOG-based attack vs the runner's defense.
            if hexDistance(x1: target.positionX, y1: target.positionY,
                           x2: enemy.positionX, y2: enemy.positionY) <= 6 {
                let atkPool = enemy.attributes.log + 3
                let defPool = target.defensePool() + (isCharacterDefending(target.id) ? 3 : 0)
                let net = max(0, DiceEngine.roll(pool: atkPool).hits - DiceEngine.roll(pool: defPool).hits)
                if net > 0 {
                    let soak = DiceEngine.roll(pool: max(0, target.attributes.wil)).hits  // WIL only — armor bypassed
                    let dmg = escalatedIncomingDamage(max(0, 4 + net - soak))
                    if dmg > 0 {
                        let wasStunned = target.status == .stunned
                        target.takeDamage(amount: dmg, isStun: true)
                        HapticsManager.shared.playerDamaged()
                        addLog("💉 \(enemy.name) DATA SPIKE → \(target.name): \(dmg) stun. (Stun \(target.currentStun)/\(target.maxStun))")
                        if target.status == .stunned && !wasStunned {
                            addLog("🧠 \(target.name) is STUNNED — they lose their next turn!")
                        }
                        NotificationCenter.default.post(name: .playerHit, object: nil, userInfo: [
                            "playerId": target.id.uuidString, "damage": dmg, "enemyId": enemy.id.uuidString])
                        NotificationCenter.default.post(name: .boltEffect, object: nil, userInfo: [
                            "fromX": enemy.positionX, "fromY": enemy.positionY,
                            "toX": target.positionX, "toY": target.positionY, "color": "#00E5FF"])
                        if !target.isAlive { CombatFlowController.handlePlayerKilled(gameState: self, char: target) }
                    } else {
                        addLog("→ \(enemy.name) — \(target.name) shrugs off the spike!")
                    }
                } else {
                    addLog("→ \(enemy.name)'s data spike — \(target.name) firewalls it!")
                }
            }

        case "sniper":
            // Marksman identity: holds the long lane, KITES if a runner closes
            // inside 3 tiles, and lands a +2-dice AIMED SHOT when it holds
            // still. Previously ran the generic "walk up and plink" default.
            //
            // OVERWATCH: turns where the sniper holds still but has NO shot
            // (lane too long / wall in the way) are banked as a reaction shot
            // instead of wasted — see the bank below and
            // GameState.fireEnemyOverwatchShots for the trigger. Stale bank
            // dropped up front: the sniper re-decides every turn.
            enemyOverwatchers.removeValue(forKey: enemy.id)
            let nearest = livingPlayers.min { a, b in
                hexDistance(x1: a.positionX, y1: a.positionY, x2: enemy.positionX, y2: enemy.positionY) <
                hexDistance(x1: b.positionX, y1: b.positionY, x2: enemy.positionX, y2: enemy.positionY)
            }!
            let sniperRange = 8
            let dNear = hexDistance(x1: nearest.positionX, y1: nearest.positionY, x2: enemy.positionX, y2: enemy.positionY)
            if dNear < 3 {
                // KITE: step to the walkable neighbour that opens the most space.
                let best = PathingAndAIHelpers.hexNeighbors(gameState: self, x: enemy.positionX, y: enemy.positionY)
                    .filter { PathingAndAIHelpers.tileWalkable(gameState: self, x: $0.0, y: $0.1, excluding: enemy.id) }
                    .max { hexDistance(x1: nearest.positionX, y1: nearest.positionY, x2: $0.0, y2: $0.1) <
                           hexDistance(x1: nearest.positionX, y1: nearest.positionY, x2: $1.0, y2: $1.1) }
                if let pick = best,
                   hexDistance(x1: nearest.positionX, y1: nearest.positionY, x2: pick.0, y2: pick.1) > dNear {
                    for (attackerId, _) in overwatchers { fireOverwatchShot(atEnemy: enemy, attackerId: attackerId) }
                    enemy.positionX = pick.0; enemy.positionY = pick.1
                    addLog("↩︎ \(enemy.name) breaks contact, re-opening the lane")
                    NotificationCenter.default.post(name: .enemyMoved, object: nil,
                        userInfo: ["enemyId": enemy.id.uuidString, "x": pick.0, "y": pick.1])
                }
            } else if dNear > sniperRange {
                for _ in 0..<enemy.moveRange {
                    if let (nx, ny) = bfsPathfind(from: enemy, toward: nearest) {
                        for (attackerId, _) in overwatchers { fireOverwatchShot(atEnemy: enemy, attackerId: attackerId) }
                        enemy.positionX = nx; enemy.positionY = ny
                        if hexDistance(x1: nearest.positionX, y1: nearest.positionY, x2: enemy.positionX, y2: enemy.positionY) <= sniperRange { break }
                    } else { break }
                }
                if enemyMovedThisTurn() {
                    addLog("→ \(enemy.name) finds a firing position")
                    NotificationCenter.default.post(name: .enemyMoved, object: nil,
                        userInfo: ["enemyId": enemy.id.uuidString, "x": enemy.positionX, "y": enemy.positionY])
                }
            }
            if enemyMovedThisTurn() { return }
            let acc = enemy.equippedWeapon?.accuracy ?? 6
            let aimPool = enemy.attributes.agi + acc / 2 + 1 + 1  // +1 = aimed shot (was +2 — near one-shot the mage from range)
            let shotDist = hexDistance(x1: nearest.positionX, y1: nearest.positionY, x2: enemy.positionX, y2: enemy.positionY)
            // No shot this turn (lane too long / wall in the way) and it
            // didn't reposition either → the sniper SETTLES INTO OVERWATCH,
            // banking its aimed pool as reaction fire against player
            // movement next round. (A moved sniper returned above — the turn
            // went into repositioning, not a hold.)
            if shotDist < 1 || shotDist > sniperRange
                || isLineBlockedByWall(fromX: enemy.positionX, fromY: enemy.positionY,
                                       toX: nearest.positionX, toY: nearest.positionY) {
                bankEnemyOverwatch(for: enemy, pool: aimPool)
                return
            }
            NotificationCenter.default.post(name: .gunfireEffect, object: nil, userInfo: [
                "fromX": enemy.positionX, "fromY": enemy.positionY,
                "toX": nearest.positionX, "toY": nearest.positionY,
                "weaponType": (enemy.equippedWeapon?.type ?? .rifle).rawValue,
                "enemyArchetype": enemy.archetype])
            let sDefBonus = isCharacterDefending(nearest.id) ? 3 : 0
            let sCover = CombatMechanics.coverBetween(tiles: currentMissionTiles, fromX: enemy.positionX, fromY: enemy.positionY, toX: nearest.positionX, toY: nearest.positionY)
            // FLANKED runners defend at -2 (min-1 clamp) — see performAttack.
            let sniperFlank = flankedDefensePenalty(target: nearest, attacker: enemy)
            let sDefPool = max(1, nearest.defensePool() + sDefBonus + CombatMechanics.coverDefenseBonus(count: sCover) - sniperFlank)
            let sAtk = DiceEngine.roll(pool: aimPool)
            let sDef = DiceEngine.roll(pool: sDefPool)
            let sNet = max(0, sAtk.hits - sDef.hits)
            // Destructible cover — after the dice, hit or miss (see performAttack).
            maybeDegradeCoverAlongShot(
                fromX: enemy.positionX, fromY: enemy.positionY,
                toX: nearest.positionX, toY: nearest.positionY)
            if sNet == 0 {
                addLog("🎯 \(enemy.name) AIMS at \(nearest.name) — MISSED!")
            } else {
                let wd = enemy.equippedWeapon?.damage ?? 8
                let ap = enemy.equippedWeapon?.armorPiercing ?? 3
                let soak = DiceEngine.roll(pool: max(0, nearest.computeDerived().soak - ap)).hits
                let dmg = escalatedIncomingDamage(max(0, wd + sNet - soak))
                if dmg > 0 {
                    nearest.takeDamage(amount: dmg, isStun: false)
                    HapticsManager.shared.playerDamaged()
                    addLog("🎯 \(enemy.name) AIMED SHOT → \(nearest.name)! [\(aimPool)d6→\(sAtk.hits)] \(wd + sNet)P - \(soak) = \(dmg) (HP \(nearest.currentHP)/\(nearest.maxHP))")
                    NotificationCenter.default.post(name: .playerHit, object: nil, userInfo: ["playerId": nearest.id.uuidString, "damage": dmg, "enemyId": enemy.id.uuidString])
                    if !nearest.isAlive { CombatFlowController.handlePlayerKilled(gameState: self, char: nearest) }
                } else {
                    addLog("🎯 \(enemy.name) fires but \(nearest.name)'s armour holds!")
                }
            }

        case "juggernaut":
            // Unstoppable advance: IGNORES overwatch (too armoured to suppress)
            // and grinds toward the nearest runner, then crushes anything in
            // reach. Slow but relentless — was running the generic default.
            let prey = livingPlayers.min { a, b in
                hexDistance(x1: a.positionX, y1: a.positionY, x2: enemy.positionX, y2: enemy.positionY) <
                hexDistance(x1: b.positionX, y1: b.positionY, x2: enemy.positionX, y2: enemy.positionY)
            }!
            if hexDistance(x1: prey.positionX, y1: prey.positionY, x2: enemy.positionX, y2: enemy.positionY) > 1 {
                var stepped = false
                for _ in 0..<max(1, enemy.moveRange) {
                    if let (nx, ny) = bfsPathfind(from: enemy, toward: prey) {
                        // NO overwatch shot here — the juggernaut shrugs it off.
                        enemy.positionX = nx; enemy.positionY = ny; stepped = true
                        if hexDistance(x1: prey.positionX, y1: prey.positionY, x2: enemy.positionX, y2: enemy.positionY) <= 1 { break }
                    } else { break }
                }
                if stepped {
                    addLog("⛓ \(enemy.name) grinds forward, shrugging off fire")
                    NotificationCenter.default.post(name: .enemyMoved, object: nil,
                        userInfo: ["enemyId": enemy.id.uuidString, "x": enemy.positionX, "y": enemy.positionY])
                }
            }
            if enemyMovedThisTurn() { return }
            if hexDistance(x1: prey.positionX, y1: prey.positionY, x2: enemy.positionX, y2: enemy.positionY) <= 1 {
                let jAcc = enemy.equippedWeapon?.accuracy ?? 4
                let jPool = enemy.attributes.agi + jAcc / 2 + 1
                let jDefBonus = isCharacterDefending(prey.id) ? 3 : 0
                // FLANKED runners defend at -2 (min-1 clamp) — see performAttack.
                let jFlank = flankedDefensePenalty(target: prey, attacker: enemy)
                let jAtk = DiceEngine.roll(pool: jPool)
                let jDef = DiceEngine.roll(pool: max(1, prey.defensePool() + jDefBonus - jFlank))
                let jNet = max(0, jAtk.hits - jDef.hits)
                if jNet == 0 {
                    addLog("⛓ \(enemy.name) swings — \(prey.name) ducks the hydraulic fist!")
                } else {
                    let wd = enemy.equippedWeapon?.damage ?? 10
                    let ap = enemy.equippedWeapon?.armorPiercing ?? 3
                    let soak = DiceEngine.roll(pool: max(0, prey.computeDerived().soak - ap)).hits
                    let dmg = escalatedIncomingDamage(max(0, wd + jNet - soak))
                    if dmg > 0 {
                        prey.takeDamage(amount: dmg, isStun: false)
                        HapticsManager.shared.playerDamaged()
                        addLog("⛓ \(enemy.name) CRUSHES \(prey.name)! [\(jPool)d6→\(jAtk.hits)] \(wd + jNet)P - \(soak) = \(dmg) (HP \(prey.currentHP)/\(prey.maxHP))")
                        NotificationCenter.default.post(name: .playerHit, object: nil, userInfo: ["playerId": prey.id.uuidString, "damage": dmg, "enemyId": enemy.id.uuidString])
                        if !prey.isAlive { CombatFlowController.handlePlayerKilled(gameState: self, char: prey) }
                    } else {
                        addLog("⛓ \(enemy.name) hammers \(prey.name) but the armour holds!")
                    }
                }
            }

        case "bruiser":
            // BERSERKER: unlike every other melee unit it CHARGES and still
            // swings in the SAME turn (it does NOT return after moving) —
            // relentless pressure you can't simply walk away from.
            func bdist(_ p: Character) -> Int { hexDistance(x1: p.positionX, y1: p.positionY, x2: enemy.positionX, y2: enemy.positionY) }
            let bTarget = livingPlayers.min { bdist($0) < bdist($1) }!
            if bdist(bTarget) > 1 {
                for _ in 0..<max(1, enemy.moveRange) {
                    if let (nx, ny) = bfsPathfind(from: enemy, toward: bTarget) {
                        for (attackerId, _) in overwatchers { fireOverwatchShot(atEnemy: enemy, attackerId: attackerId) }
                        enemy.positionX = nx; enemy.positionY = ny
                        if bdist(bTarget) <= 1 { break }
                    } else { break }
                }
                if enemyMovedThisTurn() {
                    addLog("💢 \(enemy.name) charges \(bTarget.name)!")
                    NotificationCenter.default.post(name: .enemyMoved, object: nil,
                        userInfo: ["enemyId": enemy.id.uuidString, "x": enemy.positionX, "y": enemy.positionY])
                }
            }
            if bdist(bTarget) <= 1 {
                resolveSpecialistStrike(enemy: enemy, target: bTarget, melee: true, damageBonus: 1, hitVerb: "hammers")
            }

        case "spider":
            // SKIRMISHER: skitters in on its 3-tile move to pick off the
            // WOUNDED (lowest-HP runner) and TASES them (stun track) — a tempo
            // harasser that locks down whoever's already hurt.
            func sdist(_ p: Character) -> Int { hexDistance(x1: p.positionX, y1: p.positionY, x2: enemy.positionX, y2: enemy.positionY) }
            let sPrey = livingPlayers.min { ($0.currentHP, sdist($0)) < ($1.currentHP, sdist($1)) }!
            let taserRange = 4
            if sdist(sPrey) > taserRange {
                for _ in 0..<max(1, enemy.moveRange) {
                    if let (nx, ny) = bfsPathfind(from: enemy, toward: sPrey) {
                        for (attackerId, _) in overwatchers { fireOverwatchShot(atEnemy: enemy, attackerId: attackerId) }
                        enemy.positionX = nx; enemy.positionY = ny
                        if sdist(sPrey) <= taserRange { break }
                    } else { break }
                }
                if enemyMovedThisTurn() {
                    addLog("🕷 \(enemy.name) skitters toward \(sPrey.name)")
                    NotificationCenter.default.post(name: .enemyMoved, object: nil,
                        userInfo: ["enemyId": enemy.id.uuidString, "x": enemy.positionX, "y": enemy.positionY])
                }
            }
            if enemyMovedThisTurn() { return }
            if sdist(sPrey) <= taserRange {
                resolveSpecialistStrike(enemy: enemy, target: sPrey, melee: false, forceStun: true, hitVerb: "tases")
            }

        case "infiltrator":
            // ASSASSIN: ignores the front line and hunts the SQUISHIEST runner
            // (lowest soak — mage/decker), closing fast (move 3) to gut them
            // with the armour-piercing monofilament blade.
            func idist(_ p: Character) -> Int { hexDistance(x1: p.positionX, y1: p.positionY, x2: enemy.positionX, y2: enemy.positionY) }
            let mark = livingPlayers.min { ($0.computeDerived().soak, idist($0)) < ($1.computeDerived().soak, idist($1)) }!
            if idist(mark) > 1 {
                for _ in 0..<max(1, enemy.moveRange) {
                    if let (nx, ny) = bfsPathfind(from: enemy, toward: mark) {
                        for (attackerId, _) in overwatchers { fireOverwatchShot(atEnemy: enemy, attackerId: attackerId) }
                        enemy.positionX = nx; enemy.positionY = ny
                        if idist(mark) <= 1 { break }
                    } else { break }
                }
                if enemyMovedThisTurn() {
                    addLog("🗡 \(enemy.name) slips toward \(mark.name)")
                    NotificationCenter.default.post(name: .enemyMoved, object: nil,
                        userInfo: ["enemyId": enemy.id.uuidString, "x": enemy.positionX, "y": enemy.positionY])
                }
            }
            if enemyMovedThisTurn() { return }
            if idist(mark) <= 1 {
                resolveSpecialistStrike(enemy: enemy, target: mark, melee: true, aimBonus: 1, hitVerb: "guts")
            }

        case "riot":
            // SHIELD ADVANCE: slow, armoured push to point-blank where the riot
            // shotgun spread does the most work (+dice & +damage within 2 tiles).
            // Tanky frontline that wants to be close, not kept at range.
            func rdist(_ p: Character) -> Int { hexDistance(x1: p.positionX, y1: p.positionY, x2: enemy.positionX, y2: enemy.positionY) }
            let rTarget = livingPlayers.min { rdist($0) < rdist($1) }!
            let shotgunRange = 4
            if rdist(rTarget) > shotgunRange {
                for _ in 0..<max(1, enemy.moveRange) {
                    if let (nx, ny) = bfsPathfind(from: enemy, toward: rTarget) {
                        for (attackerId, _) in overwatchers { fireOverwatchShot(atEnemy: enemy, attackerId: attackerId) }
                        enemy.positionX = nx; enemy.positionY = ny
                        if rdist(rTarget) <= shotgunRange { break }
                    } else { break }
                }
                if enemyMovedThisTurn() {
                    addLog("🛡 \(enemy.name) advances behind its shield")
                    NotificationCenter.default.post(name: .enemyMoved, object: nil,
                        userInfo: ["enemyId": enemy.id.uuidString, "x": enemy.positionX, "y": enemy.positionY])
                }
            }
            if enemyMovedThisTurn() { return }
            if rdist(rTarget) <= shotgunRange {
                let pointBlank = rdist(rTarget) <= 2
                // Point-blank spread can also KNOCK THE TARGET DOWN (~35% on
                // a damaging hit) — prone until the round tick: pinned in
                // place, -2 defense dice. See resolveSpecialistStrike.
                resolveSpecialistStrike(enemy: enemy, target: rTarget, melee: false,
                    aimBonus: pointBlank ? 2 : 0, damageBonus: pointBlank ? 2 : 0,
                    knockdownChance: pointBlank ? 0.35 : 0,
                    hitVerb: pointBlank ? "blasts point-blank" : "fires on")
            }

        default:
            // Targeted selection: go for the nearest threat, but when two
            // players are about equally close (within 1 tile of each other),
            // focus the weaker one to finish them off — reads as smarter,
            // more deliberate enemy behaviour than always hitting the literal
            // closest body.
            let closestPlayer = livingPlayers.min { a, b in
                let distA = hexDistance(x1: a.positionX, y1: a.positionY, x2: enemy.positionX, y2: enemy.positionY)
                let distB = hexDistance(x1: b.positionX, y1: b.positionY, x2: enemy.positionX, y2: enemy.positionY)
                if abs(distA - distB) <= 1 {
                    if a.currentHP != b.currentHP { return a.currentHP < b.currentHP }
                    return distA < distB
                }
                return distA < distB
            }!
            let dist = hexDistance(x1: closestPlayer.positionX, y1: closestPlayer.positionY, x2: enemy.positionX, y2: enemy.positionY)
            let target = closestPlayer

            // FIX 2: reposition non-drone enemies before attacking if out of weapon range
            // Melee: range 1. Ranged guards/pistols: range 4. Rifles: range 6. Mages: range 5.
            let maxWeaponRange: Int
            if enemy.archetype == "mage" {
                maxWeaponRange = 5
            } else {
                // Guard / default: pistol/rifle
                switch enemy.equippedWeapon?.type {
                case .rifle: maxWeaponRange = 6
                case .pistol, .smg: maxWeaponRange = 4
                case .blade, .unarmed: maxWeaponRange = 1
                default: maxWeaponRange = 3
                }
            }

            if dist > maxWeaponRange {
                // Move up to moveRange tiles toward player. Post .enemyMoved
                // ONCE at the end with the final destination so the visual
                // animation slides smoothly from start → final without
                // cancelling itself mid-flight on every intermediate step.
                // (The previous version posted inside the loop, which
                // combined with animateMove's "move" action key cancelling
                // produced the corpmage's "walks right, half body, reappears
                // left" glitch — each intermediate post killed the in-flight
                // animation and replaced it with a new one starting from the
                // node's mid-tile position.)
                let startX = enemy.positionX
                let startY = enemy.positionY
                for _ in 0..<enemy.moveRange {
                    if let (newX, newY) = bfsPathfind(from: enemy, toward: closestPlayer) {
                        // Overwatch: check before each step
                        for (attackerId, _) in overwatchers {
                            fireOverwatchShot(atEnemy: enemy, attackerId: attackerId)
                        }
                        enemy.positionX = newX; enemy.positionY = newY
                        let newDist = hexDistance(x1: closestPlayer.positionX, y1: closestPlayer.positionY, x2: enemy.positionX, y2: enemy.positionY)
                        if newDist <= maxWeaponRange { break }
                    } else { break }
                }
                if enemy.positionX != startX || enemy.positionY != startY {
                    addLog("→ \(enemy.name) advances")
                    NotificationCenter.default.post(name: .enemyMoved, object: nil,
                        userInfo: ["enemyId": enemy.id.uuidString,
                                   "x": enemy.positionX, "y": enemy.positionY])
                }
            }

            // Dynamic pressure: a regular enemy already within weapon range
            // shouldn't camp the same tile every round (the old behaviour —
            // "stand and shoot" — made non-drone enemies feel inert). If
            // they're sitting farther than their preferred engagement range,
            // they have a good chance to close the gap and chase the target,
            // mirroring how drones reposition. Like all enemy moves this is
            // move-OR-attack: closing in costs this turn's shot, so they
            // alternate between pressing forward and firing.
            if !enemyMovedThisTurn() {
                let isMeleeEnemy = enemy.equippedWeapon?.type == .blade
                    || enemy.equippedWeapon?.type == .unarmed
                let preferredRange = isMeleeEnemy ? 1 : 2
                if dist > preferredRange && Double.random(in: 0...1) < 0.5 {
                    let rsx = enemy.positionX, rsy = enemy.positionY
                    for _ in 0..<max(1, enemy.moveRange) {
                        if let (nx, ny) = bfsPathfind(from: enemy, toward: closestPlayer) {
                            for (attackerId, _) in overwatchers {
                                fireOverwatchShot(atEnemy: enemy, attackerId: attackerId)
                            }
                            enemy.positionX = nx; enemy.positionY = ny
                            if hexDistance(x1: closestPlayer.positionX, y1: closestPlayer.positionY,
                                           x2: enemy.positionX, y2: enemy.positionY) <= preferredRange { break }
                        } else { break }
                    }
                    if enemy.positionX != rsx || enemy.positionY != rsy {
                        addLog("→ \(enemy.name) presses forward")
                        NotificationCenter.default.post(name: .enemyMoved, object: nil,
                            userInfo: ["enemyId": enemy.id.uuidString,
                                       "x": enemy.positionX, "y": enemy.positionY])
                    }
                }
            }

            if enemyMovedThisTurn() { return }
            let afterMoveDist = hexDistance(x1: closestPlayer.positionX, y1: closestPlayer.positionY, x2: enemy.positionX, y2: enemy.positionY)
            // Only attack if in range after repositioning; mage spells are range 5
            let effectiveRange = enemy.archetype == "mage" ? 5 : (enemy.equippedWeapon?.type == .rifle ? 6 : (enemy.equippedWeapon?.type == .pistol || enemy.equippedWeapon?.type == .smg) ? 4 : 1)
            if afterMoveDist > effectiveRange { return }

            // Handle mage enemy with spellcasting
            if enemy.archetype == "mage" {
                let spellPool = enemy.attributes.log + 3
                let spellRoll = DiceEngine.roll(pool: spellPool)

                if spellRoll.hits == 0 {
                    addLog("✨ \(enemy.name) casts a spell but it fizzles...")
                } else {
                    let baseDamage = 6 + spellRoll.hits
                    let soakPool = target.attributes.wil + (target.equippedArmor?.armorValue ?? 0) / 2
                    let soakRoll = DiceEngine.roll(pool: max(0, soakPool))
                    let dmg = escalatedIncomingDamage(max(1, baseDamage - soakRoll.hits))

                    if dmg > 0 {
                        target.takeDamage(amount: dmg, isStun: false)  // enemy mage spells deal physical
                        HapticsManager.shared.playerDamaged()
                        addLog("✨ \(enemy.name) casts! [\(spellPool)d6→\(spellRoll.hits) hits] \(baseDamage)P - \(soakRoll.hits)soak = \(dmg) dmg. (HP \(target.currentHP)/\(target.maxHP))")
                        NotificationCenter.default.post(name: .playerHit, object: nil, userInfo: ["playerId": target.id.uuidString, "damage": dmg, "enemyId": enemy.id.uuidString])
                        if !target.isAlive { CombatFlowController.handlePlayerKilled(gameState: self, char: target) }
                    } else {
                        addLog("✨ \(enemy.name) casts but \(target.name) resists!")
                    }
                }
            } else {
                // Guard/regular enemy uses melee combat
                let weaponAccuracy = enemy.equippedWeapon?.accuracy ?? 3
                let enemyAttackPool = enemy.attributes.agi + (weaponAccuracy / 2 + 1)

                let defenseBonus = isCharacterDefending(target.id) ? 3 : 0
                let guardCoverCount = CombatMechanics.coverBetween(
                    tiles: currentMissionTiles,
                    fromX: enemy.positionX, fromY: enemy.positionY,
                    toX: target.positionX, toY: target.positionY
                )
                let guardPlayerCoverBonus = CombatMechanics.coverDefenseBonus(count: guardCoverCount)
                // FLANKED runners defend at -2 (min-1 clamp) — see performAttack.
                let guardFlank = flankedDefensePenalty(target: target, attacker: enemy)
                let playerDefensePool = max(1, target.defensePool() + defenseBonus + guardPlayerCoverBonus - guardFlank)

                // Post gunfire effect so SFXManager can play the right
                // weapon clip (sniper enemies share the rifle WeaponType but
                // should sound distinct, so we also pass archetype).
                let weaponType = enemy.equippedWeapon?.type
                if let wt = weaponType, wt != .blade && wt != .unarmed {
                    NotificationCenter.default.post(
                        name: .gunfireEffect, object: nil,
                        userInfo: [
                            "fromX": enemy.positionX, "fromY": enemy.positionY,
                            "toX":   target.positionX,  "toY":   target.positionY,
                            "weaponType":     wt.rawValue,
                            "enemyArchetype": enemy.archetype
                        ]
                    )
                }

                let attackRoll = DiceEngine.roll(pool: enemyAttackPool)
                let defenseRoll = DiceEngine.roll(pool: playerDefensePool)
                let netHits = max(0, attackRoll.hits - defenseRoll.hits)
                // Destructible cover — ranged shots only, after the dice,
                // hit or miss (see performAttack).
                if let wt = weaponType, wt != .blade && wt != .unarmed {
                    maybeDegradeCoverAlongShot(
                        fromX: enemy.positionX, fromY: enemy.positionY,
                        toX: target.positionX, toY: target.positionY)
                }

                if netHits == 0 {
                    addLog("→ \(enemy.name) attacks \(target.name) — DODGED!")
                } else {
                    let weaponDmg = enemy.equippedWeapon?.damage ?? 4
                    let baseDmg = weaponDmg + netHits
                    let ap = enemy.equippedWeapon?.armorPiercing ?? 0
                    let soakPool = max(0, target.computeDerived().soak - ap)
                    let soakRoll = DiceEngine.roll(pool: soakPool)
                    let dmg = escalatedIncomingDamage(max(0, baseDmg - soakRoll.hits))

                    if dmg > 0 {
                        let isStun = enemy.equippedWeapon?.isStunDamage ?? false
                        target.takeDamage(amount: dmg, isStun: isStun)
                        let dmgType = isStun ? "S" : "P"
                        HapticsManager.shared.playerDamaged()
                        addLog("⚠️ \(enemy.name) hits \(target.name)! \(netHits) net hits → \(dmg)\(dmgType) dmg. (HP \(target.currentHP)/\(target.maxHP) | Stun \(target.currentStun)/\(target.maxStun))")
                        NotificationCenter.default.post(name: .playerHit, object: nil, userInfo: ["playerId": target.id.uuidString, "damage": dmg, "enemyId": enemy.id.uuidString])
                        if !target.isAlive { CombatFlowController.handlePlayerKilled(gameState: self, char: target) }
                    } else {
                        addLog("→ \(enemy.name) attacks — \(target.name) soaks all damage!")
                    }
                }
            }
        }
    }
}

import Foundation

struct CombatFlowController {
    static func beginRound(gameState: GameState) {
        CombatFlowController.resetTurnTracking(gameState: gameState)
        gameState.isDefending = false
        gameState.defendingCharacterId = nil
        // Natural stun recovery: each character rolls BOD+WIL to reduce stun (SR5 recovery rules)
        CombatFlowController.recoverStunAtRoundStart(gameState: gameState)
        // Mana regen: mages and deckers recover 1 resource point per round passively
        for char in gameState.playerTeam where char.isAlive {
            if char.archetype == .mage || char.archetype == .decker {
                let prev = char.currentMana
                char.currentMana = min(char.maxMana, char.currentMana + 1)
                if char.currentMana > prev {
                    gameState.addLog("✨ \(char.name) recovers 1 mana. (\(char.currentMana)/\(char.maxMana))")
                }
            }
        }
    }

    static func resetTurnTracking(gameState: GameState) {
        // Stunned characters auto-skip their turn (they can't act while fully stunned)
        // They still count as "acted" so the round advances without them.
        gameState.playersWhoHaveNotActed = Set(
            gameState.playerTeam.filter { $0.isAlive && $0.status != .stunned }.map { $0.id }
        )
        // Reset per-character action flags at start of new round
        for char in gameState.playerTeam {
            char.hasActedThisRound = false
            // Log stunned characters being skipped
            if char.isAlive && char.status == .stunned {
                gameState.addLog("💤 \(char.name) is STUNNED — skipping turn. (Stun \(char.currentStun)/\(char.maxStun))")
                char.hasActedThisRound = true
            }
        }
    }

    static func recoverStunAtRoundStart(gameState: GameState) {
        for char in gameState.playerTeam where char.isAlive && char.currentStun > 0 {
            let recoveryPool = char.attributes.bod + char.attributes.wil
            let roll = DiceEngine.roll(pool: recoveryPool)
            if roll.hits > 0 {
                char.recoverStun(amount: roll.hits)
            }
        }
        for enemy in gameState.enemies where enemy.isAlive && enemy.currentStun > 0 {
            let recoveryPool = enemy.attributes.bod + enemy.attributes.wil
            let roll = DiceEngine.roll(pool: recoveryPool)
            if roll.hits > 0 {
                enemy.currentStun = max(0, enemy.currentStun - roll.hits)
                if enemy.status == .stunned && enemy.currentStun < enemy.maxStun {
                    enemy.status = .wounded
                }
            }
        }
    }

    static func performAttack(gameState: GameState) {
        let attacker: Character?
        if let selected = gameState.selectedCharacterId, let char = gameState.playerTeam.first(where: { $0.id == selected && $0.isAlive }) {
            attacker = char
        } else {
            attacker = gameState.currentCharacter
        }
        guard let a = attacker else { gameState.addLog("No character available."); return }
        guard let targetId = gameState.targetCharacterId else { gameState.addLog("No target selected — tap an enemy first."); return }
        guard let targetEnemy = gameState.enemies.first(where: { $0.id == targetId }) else {
            gameState.addLog("Invalid target."); return
        }

        if gameState.isLineBlockedByWall(
            fromX: a.positionX, fromY: a.positionY,
            toX: targetEnemy.positionX, toY: targetEnemy.positionY
        ) {
            gameState.addLog("⛔ Line of sight blocked by wall!")
            HapticsManager.shared.buttonTap()
            return
        }

        let weapon = a.equippedWeapon ?? Weapon(name: "Fists", type: .unarmed, damage: 3, accuracy: 3, armorPiercing: 0)

        // Determine attack skill from weapon type
        let skill: SkillKey = (weapon.type == .blade || weapon.type == .unarmed) ? .blades : .firearms

        // Attack pool: AGI + skill
        let attackPool = a.attackPool(skill: skill)

        switch gameState.actionMode {
        case .street: gameState.applyStreetAction()
        case .signal: gameState.applySignalAction()
        }

        // Cover bonus: count cover tiles between attacker and target
        let coverCount = CombatMechanics.coverBetween(
            tiles: gameState.currentMissionTiles,
            fromX: a.positionX, fromY: a.positionY,
            toX: targetEnemy.positionX, toY: targetEnemy.positionY
        )
        let coverBonus = CombatMechanics.coverDefenseBonus(count: coverCount)

        // Defense pool: REA + AGI + cover bonus
        let defensePool = targetEnemy.attributes.rea + targetEnemy.attributes.agi + coverBonus

        // Roll attack
        let attackRoll = DiceEngine.roll(pool: attackPool)

        // Critical glitch: attacker fumbles, takes self-damage
        if attackRoll.criticalGlitch {
            let selfDmg = 2
            a.takeDamage(amount: selfDmg)
            gameState.addLog("💥 CRITICAL GLITCH! \(a.name) fumbles — \(selfDmg) self-damage!")
            HapticsManager.shared.playerDamaged()
            NotificationCenter.default.post(name: .characterHit, object: nil, userInfo: ["characterId": a.id.uuidString, "damage": selfDmg])
            CombatFlowController.completeAction(gameState: gameState, for: a)
            return
        }

        if attackRoll.glitch {
            gameState.addLog("⚠️ GLITCH! \(a.name)'s \(weapon.name) misfires!")
            CombatFlowController.completeAction(gameState: gameState, for: a)
            return
        }

        // Defense roll
        let defenseRoll = DiceEngine.roll(pool: defensePool)
        let netHits = max(0, attackRoll.hits - defenseRoll.hits)

        gameState.addLog("⚔️ \(a.name) attacks with \(weapon.name)! [\(attackPool)d6→\(attackRoll.hits)] vs [\(defensePool)d6→\(defenseRoll.hits)\(coverBonus > 0 ? " +\(coverBonus)cov" : "")]")

        if netHits == 0 {
            gameState.addLog("  → MISS! \(targetEnemy.name) dodges!")
            NotificationCenter.default.post(name: .enemyHit, object: nil, userInfo: ["enemyId": targetId.uuidString, "damage": 0])
            CombatFlowController.completeAction(gameState: gameState, for: a)
            return
        }

        // Damage = weapon base + net hits
        let baseDamage = weapon.damage + netHits
        let ap = weapon.armorPiercing

        // Soak: enemy BOD + armor - AP (minimum 0)
        let soakPool = max(0, targetEnemy.computeDerived().soak - ap)
        let soakRoll = DiceEngine.roll(pool: soakPool)
        let finalDamage = max(0, baseDamage - soakRoll.hits)

        HapticsManager.shared.attackHit()
        let isStunDmg = weapon.isStunDamage
        targetEnemy.takeDamage(amount: finalDamage, isStun: isStunDmg)
        let dmgType = isStunDmg ? "S" : "P"

        if finalDamage > 0 {
            gameState.addLog("  → \(netHits) net hits! \(baseDamage)\(dmgType) - \(soakRoll.hits) soak = \(finalDamage) dmg! (\(targetEnemy.currentHP)/\(targetEnemy.maxHP) HP | Stun \(targetEnemy.currentStun)/\(targetEnemy.maxStun))")
        } else {
            gameState.addLog("  → Hit but \(targetEnemy.name) soaks ALL damage!")
        }

        NotificationCenter.default.post(name: .enemyHit, object: nil, userInfo: ["enemyId": targetId.uuidString, "damage": finalDamage])

        if !targetEnemy.isAlive {
            HapticsManager.shared.enemyKilled()
            gameState.addLog("☠️ \(targetEnemy.name) DOWN! +\(targetEnemy.maxHP / 2) XP")
            gameState.generateLoot()
            if let char = gameState.playerTeam.first(where: { $0.id == a.id }) {
                let leveledUp = char.gainXP(targetEnemy.maxHP / 2)
                if leveledUp {
                    HapticsManager.shared.levelUp()
                    gameState.addLog("🎖️ LEVEL UP! \(char.name) → Level \(char.level)!")
                    NotificationCenter.default.post(name: .characterLevelUp, object: nil, userInfo: ["characterId": char.id.uuidString])
                }
            }
            NotificationCenter.default.post(name: .enemyDied, object: nil, userInfo: ["enemyId": targetId.uuidString])
            if gameState.livingEnemies.isEmpty { gameState.onRoomCleared() }
        }

        CombatFlowController.completeAction(gameState: gameState, for: a)
    }

    static func performLayLow(gameState: GameState) {
        let actor: Character?
        if let selected = gameState.selectedCharacterId, let char = gameState.playerTeam.first(where: { $0.id == selected && $0.isAlive }) {
            actor = char
        } else {
            actor = gameState.currentCharacter
        }
        guard let character = actor else {
            gameState.addLog("No character available.")
            return
        }
        gameState.applyTraceRecovery()
        CombatFlowController.completeAction(gameState: gameState, for: character) // Cost: consumes full turn
    }

    static func performSpell(gameState: GameState, type: SpellType, targetId: UUID? = nil) {
        // Resolve caster
        let char: Character?
        if let selected = gameState.selectedCharacterId, let c = gameState.playerTeam.first(where: { $0.id == selected && $0.isAlive }) {
            char = c
        } else {
            char = gameState.currentCharacter
        }
        guard let mage = char, mage.archetype == CharacterArchetype.mage else {
            gameState.addLog("Only mages can cast spells.")
            return
        }
        guard mage.currentMana >= type.manaCost else {
            gameState.addLog("Not enough mana for \(type.displayName)! Need \(type.manaCost), have \(mage.currentMana).")
            HapticsManager.shared.buttonTap()
            return
        }

        // Dispatch by spell type
        switch type {
        case .fireball:
            gameState.castFireball(by: mage)
        case .manaBolt:
            gameState.castSingleTarget(type: type, targetId: targetId ?? gameState.targetCharacterId, by: mage)
        case .shock:
            gameState.castSingleTarget(type: type, targetId: targetId ?? gameState.targetCharacterId, by: mage)
        case .heal:
            gameState.castHeal(by: mage)
        }
    }

    static func performDefend(gameState: GameState) {
        let char: Character
        if let selected = gameState.selectedCharacterId, let c = gameState.playerTeam.first(where: { $0.id == selected && $0.isAlive }) {
            char = c
        } else if let current = gameState.currentCharacter {
            char = current
        } else { return }
        HapticsManager.shared.buttonTap()
        gameState.isDefending = true
        gameState.defendingCharacterId = char.id
        gameState.addLog("\(char.name) takes a defensive stance. (+2 DEF)")
        NotificationCenter.default.post(
            name: .characterDefend,
            object: nil,
            userInfo: ["characterId": char.id.uuidString]
        )
        CombatFlowController.completeAction(gameState: gameState, for: char)
    }

    static func performHack(gameState: GameState) {
        let char: Character?
        if let selected = gameState.selectedCharacterId, let c = gameState.playerTeam.first(where: { $0.id == selected && $0.isAlive }) {
            char = c
        } else {
            char = gameState.currentCharacter
        }
        guard let decker = char, decker.archetype == CharacterArchetype.decker else {
            gameState.addLog("Only Deckers can hack.")
            return
        }
        guard decker.currentMana >= 2 else {
            gameState.addLog("Not enough matrix energy! Need 2, have \(decker.currentMana).")
            HapticsManager.shared.buttonTap()
            return
        }
        guard let targetId = gameState.targetCharacterId,
              let target = gameState.enemies.first(where: { $0.id == targetId && $0.isAlive }) else {
            guard let nearest = gameState.livingEnemies.first else {
                gameState.addLog("No targets in range."); return
            }
            gameState.targetCharacterId = nearest.id
            gameState.performHackOnTarget(nearest, by: decker)
            return
        }
        gameState.performHackOnTarget(target, by: decker)
    }

    static func performIntimidate(gameState: GameState) {
        let char: Character?
        if let selected = gameState.selectedCharacterId, let c = gameState.playerTeam.first(where: { $0.id == selected && $0.isAlive }) {
            char = c
        } else {
            char = gameState.currentCharacter
        }
        guard let face = char, face.archetype == CharacterArchetype.face else {
            gameState.addLog("Only the Face can intimidate.")
            return
        }
        // Social pool: CHA + (LOG / 2)
        let socialPool = face.attributes.cha + face.attributes.log / 2
        let socialRoll = DiceEngine.roll(pool: socialPool)
        HapticsManager.shared.attackHit()

        if socialRoll.hits == 0 {
            gameState.addLog("🎭 \(face.name) tries to intimidate but the guards laugh it off.")
            CombatFlowController.completeAction(gameState: gameState, for: face)
            return
        }

        // Apply intimidation to all living enemies: reduce their attack pool by hits (min 1)
        for enemy in gameState.livingEnemies {
            let penalty = min(socialRoll.hits, enemy.attributes.agi - 1)
            enemy.attributes.agi = max(1, enemy.attributes.agi - penalty)
        }
        gameState.addLog("🎭 \(face.name) INTIMIDATES! [\(socialPool)d6→\(socialRoll.hits)] — Enemies rattled! (-\(socialRoll.hits) ATK this round)")
        CombatFlowController.completeAction(gameState: gameState, for: face)
    }

    static func performBlitz(gameState: GameState) {
        let char: Character?
        if let selected = gameState.selectedCharacterId, let c = gameState.playerTeam.first(where: { $0.id == selected && $0.isAlive }) {
            char = c
        } else {
            char = gameState.currentCharacter
        }
        guard let sam = char, sam.archetype == CharacterArchetype.streetSam else {
            gameState.addLog("Only the Street Samurai can Blitz.")
            return
        }
        guard let targetId = gameState.targetCharacterId,
              let target = gameState.enemies.first(where: { $0.id == targetId && $0.isAlive }) else {
            guard let nearest = gameState.livingEnemies.first else {
                gameState.addLog("No targets in range."); return
            }
            gameState.targetCharacterId = nearest.id
            gameState.performBlitzOnTarget(nearest, by: sam)
            return
        }
        gameState.performBlitzOnTarget(target, by: sam)
    }

    static func moveCharacter(gameState: GameState, id: UUID, toTileX tileX: Int, toTileY tileY: Int) {
        guard let char = gameState.playerTeam.first(where: { $0.id == id && $0.isAlive }) else { return }
        char.positionX = tileX
        char.positionY = tileY
        gameState.addLog("\(char.name) moves to (\(tileX),\(tileY))")
        NotificationCenter.default.post(
            name: .tileTapped,
            object: nil,
            userInfo: ["tileX": tileX, "tileY": tileY, "characterId": id.uuidString]
        )
        // Movement is a FREE action — does NOT consume the turn.
        // Do NOT set hasActedThisRound or call endTurn() here.
    }

    static func showItemMenu(gameState: GameState) {
        gameState.isItemMenuVisible = true
    }

    static func completeAction(gameState: GameState, for character: Character) {
        // Set active to this character so endTurn() marks the right one
        gameState.activeCharacterId = character.id
        CombatFlowController.endTurn(gameState: gameState)
    }

    static func endTurn(gameState: GameState) {
        // NOTE: Do NOT set isPlayerTurn=false or block input here unless we're actually
        // transitioning to the enemy phase. Doing so prematurely disables action buttons
        // for the next player character in the round.
        gameState.isItemMenuVisible = false
        gameState.targetCharacterId = nil

        // Mark current active character as having acted this round.
        // ALWAYS remove from playersWhoHaveNotActed regardless of hasActedThisRound flag —
        // guards against the race condition where the flag was already set but the Set
        // removal was missed (e.g. character died mid-action or endTurn fired twice).
        if let activeId = gameState.activeCharacterId {
            if let char = gameState.playerTeam.first(where: { $0.id == activeId }) {
                char.hasActedThisRound = true
            }
            gameState.playersWhoHaveNotActed.remove(activeId)
        }

        gameState.currentTurnCount += 1
        if gameState.currentMissionType == .stealth && !gameState.missionComplete && gameState.currentTurnCount >= gameState.missionTargetTurns {
            gameState.finalizeCombatFromCombatFlow(
                won: true,
                missionLog: "MISSION COMPLETE — STEALTH WINDOW HELD FOR \(gameState.missionTargetTurns) TURNS"
            )
            return
        }

        let living = gameState.playerTeam.filter { $0.isAlive }
        guard !living.isEmpty else {
            gameState.isPlayerInputBlocked = false
            gameState.isPlayerTurn = true
            return
        }

        // Find next living character who hasn't acted this round
        let nextCharId = gameState.playersWhoHaveNotActed.first { id in
            living.contains { $0.id == id }
        }
        let nextChar = nextCharId.flatMap { id in living.first { $0.id == id } }

        if let char = nextChar {
            // More players still need to act — advance to next player without blocking input.
            gameState.activeCharacterId = char.id
            gameState.selectedCharacterId = char.id
            gameState.currentTurnIndex = gameState.playerTeam.firstIndex(where: { $0.id == char.id }) ?? 0
            gameState.isPlayerInputBlocked = false
            gameState.isPlayerTurn = true      // Stay in player phase — buttons must remain enabled
            gameState.isDefending = false
            gameState.defendingCharacterId = nil
            NotificationCenter.default.post(
                name: .turnChanged,
                object: nil,
                userInfo: ["characterId": char.id.uuidString]
            )
        } else {
            // All living players have acted — NOW lock input and start enemy phase.
            gameState.isPlayerTurn = false
            gameState.isPlayerInputBlocked = true
            gameState.currentTurnIndex = 0
            gameState.enemyPhaseCount += 1
            gameState.roundNumber += 1
            gameState.addLog("═══ ROUND \(gameState.roundNumber) ═══")
            HapticsManager.shared.roundStart()
            NotificationCenter.default.post(name: .roundStarted, object: nil, userInfo: ["round": gameState.roundNumber])
            CombatFlowController.enemyPhase(gameState: gameState)
        }
    }

    static func checkCombatEnd(gameState: GameState) {
        if gameState.currentMissionType == .assault && gameState.livingEnemies.isEmpty && gameState.pendingSpawns.isEmpty {
            gameState.finalizeCombatFromCombatFlow(won: true, missionLog: "MISSION COMPLETE — ASSAULT TARGET ELIMINATED")
            return
        }

        if gameState.livingPlayers.isEmpty {
            gameState.finalizeCombatFromCombatFlow(
                won: false,
                missionLog: "MISSION FAILED — ALL UNITS DOWN",
                terminalLog: "=== DEFEAT ==="
            )
        }
    }

    static func enemyPhase(gameState: GameState) {
        guard !gameState.isEnemyPhaseRunning else { return }
        gameState.isEnemyPhaseRunning = true

        // Post .enemyPhaseBegan so CombatUI can update ("Enemy Turn" UI)
        NotificationCenter.default.post(name: .enemyPhaseBegan, object: nil)

        let livingEnemies = gameState.enemies.filter { $0.isAlive }
        let livingPlayers = gameState.playerTeam.filter { $0.isAlive }
        // Skip enemy phase if no enemies alive — post .enemyPhaseCompleted so player input unlocks.
        guard !livingEnemies.isEmpty else {
            gameState.isEnemyPhaseRunning = false
            CombatFlowController.beginRound(gameState: gameState)
            NotificationCenter.default.post(name: .enemyPhaseCompleted, object: nil)
            return
        }
        // If no players left, combat will end via checkCombatEnd() in the notify block.
        guard !livingPlayers.isEmpty else {
            gameState.isEnemyPhaseRunning = false
            CombatFlowController.beginRound(gameState: gameState)
            NotificationCenter.default.post(name: .enemyPhaseCompleted, object: nil)
            return
        }

        let group = DispatchGroup()
        let staggerDelay: TimeInterval = 0.18  // delay between enemy turns

        for (i, enemy) in livingEnemies.enumerated() {
            let delay = Double(i) * staggerDelay

            group.enter()
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak gameState] in
                guard let gameState = gameState else { group.leave(); return }
                gameState.runEnemyAI(enemy: enemy, livingEnemies: livingEnemies)
                // Leave group only after the enemy's animations would have finished playing.
                // animateEnemyMove = 0.35s, playerHitEffect = 0.25s. Use 0.5s buffer.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    group.leave()
                }
            }
        }

        // When ALL enemies have finished their turns + animation windows, finalize.
        group.notify(queue: .main) { [weak gameState] in
            guard let gameState = gameState else { return }
            gameState.processDelayedSpawns(enemyPhaseIndex: gameState.enemyPhaseCount)
            gameState.checkExtraction()
            CombatFlowController.checkCombatEnd(gameState: gameState)
            if gameState.combatEnded {
                gameState.isEnemyPhaseRunning = false
                NotificationCenter.default.post(name: .enemyPhaseCompleted, object: nil)
                return
            }
            gameState.isEnemyPhaseRunning = false
            // CRITICAL: reset hasActedThisRound for all players so they can act next round
            CombatFlowController.beginRound(gameState: gameState)
            // Signal BattleScene to unblock player input
            NotificationCenter.default.post(name: .enemyPhaseCompleted, object: nil)
            print("[GameState] enemyPhase: all enemies done, beginRound() called, .enemyPhaseCompleted posted")

            // Safety timeout: if .enemyPhaseCompleted notification fails to unblock input
            // (rare but possible if BattleScene observer is not registered), force-unblock
            // after 3 seconds so the player is never permanently locked out.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak gameState] in
                guard let gameState = gameState else { return }
                if gameState.isPlayerInputBlocked && !gameState.combatEnded {
                    print("[GameState] Safety timeout: force-unblocking player input")
                    gameState.isPlayerInputBlocked = false
                    gameState.isPlayerTurn = true
                    NotificationCenter.default.post(name: .enemyPhaseCompleted, object: nil)
                }
            }
        }
    }

    static func isCharacterDefending(gameState: GameState, _ charId: UUID) -> Bool {
        return gameState.isDefending && gameState.defendingCharacterId == charId
    }

    static func showMoveMenu(gameState: GameState) {
        let char: Character
        if let selected = gameState.selectedCharacterId, let c = gameState.playerTeam.first(where: { $0.id == selected && $0.isAlive }) {
            char = c
        } else if let current = gameState.currentCharacter {
            char = current
        } else { return }
        gameState.addLog("\(char.name): tap a tile to move.")
    }

    static func performUseItem(gameState: GameState) {
        let char: Character
        if let selected = gameState.selectedCharacterId, let c = gameState.playerTeam.first(where: { $0.id == selected && $0.isAlive }) {
            char = c
        } else if let current = gameState.currentCharacter {
            char = current
        } else { gameState.addLog("No character to heal."); return }

        // Find a consumable item
        guard let idx = gameState.loot.firstIndex(where: { $0.type == .consumable }) else {
            gameState.addLog("No medkits available.")
            HapticsManager.shared.buttonTap()
            return
        }
        HapticsManager.shared.attackHit()
        let item = gameState.loot.remove(at: idx)
        char.currentHP = min(char.maxHP, char.currentHP + item.bonus)
        // Medkits also clear some stun damage (First Aid = treat stun & physical)
        char.recoverStun(amount: item.bonus / 2)
        gameState.addLog("\(char.name) uses \(item.name)! +\(item.bonus) HP, -\(item.bonus / 2) Stun. (HP \(char.currentHP)/\(char.maxHP) | Stun \(char.currentStun)/\(char.maxStun))")
        CombatFlowController.completeAction(gameState: gameState, for: char)
    }

    static func selectCharacter(gameState: GameState, id: UUID) {
        if let char = gameState.playerTeam.first(where: { $0.id == id }) {
            gameState.selectedCharacterId = char.id
            gameState.activeCharacterId = char.id
            gameState.targetCharacterId = nil
            gameState.addLog("Selected: \(char.name)")
        }
    }

    static func handleTileTap(gameState: GameState, tileX: Int, tileY: Int) {
        if let char = gameState.playerTeam.first(where: { $0.positionX == tileX && $0.positionY == tileY && $0.isAlive }) {
            gameState.selectedCharacterId = char.id
            gameState.targetCharacterId = nil
            gameState.addLog("Selected: \(char.name)")
            NotificationCenter.default.post(name: .characterSelected, object: nil, userInfo: ["characterId": char.id.uuidString])
            return
        }

        if let enemy = gameState.enemies.first(where: { $0.positionX == tileX && $0.positionY == tileY && $0.isAlive }) {
            if gameState.selectedCharacterId == nil { gameState.addLog("Select a character first."); return }
            gameState.targetCharacterId = enemy.id
            gameState.addLog("Targeting: \(enemy.name)")
            return
        }

        if let selectedId = gameState.selectedCharacterId,
           let char = gameState.playerTeam.first(where: { $0.id == selectedId }) {
            let isHexAdj = gameState.hexAdjacent(x1: tileX, y1: tileY, x2: char.positionX, y2: char.positionY)
            if isHexAdj {
                char.positionX = tileX
                char.positionY = tileY
                gameState.addLog("\(char.name) moves to (\(tileX),\(tileY))")
                NotificationCenter.default.post(
                    name: .tileTapped,
                    object: nil,
                    userInfo: ["tileX": tileX, "tileY": tileY, "characterId": char.id.uuidString]
                )
                // Movement is a free action — does NOT consume the turn.
            } else {
                gameState.addLog("Too far. Choose an adjacent hex.")
            }
            return
        }

        gameState.addLog("Empty tile: (\(tileX),\(tileY))")
    }
}

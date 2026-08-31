import Foundation

@MainActor
struct CombatFlowController {
    static func setCombatPhase(gameState: GameState, _ phase: CombatPhase) {
        gameState.combatPhase = phase
        CombatFlowController.syncLegacyState(gameState: gameState)
    }

    static func setCombatOutcome(gameState: GameState, _ outcome: CombatOutcome) {
        gameState.combatOutcome = outcome
        CombatFlowController.syncLegacyState(gameState: gameState)
    }

    /// Legacy fields derived from CombatPhase/CombatOutcome — do not write directly.
    static func syncLegacyState(gameState: GameState) {
        let phase = gameState.combatPhase
        let outcome = gameState.combatOutcome

        gameState.isPlayerTurn = (phase == .playerInput)
        gameState.isPlayerInputBlocked = (phase != .playerInput)

        // Outcome is terminal? Keep combatEnded latched ON regardless of
        // phase. Without this, a stray setCombatPhase(.playerInput) tick
        // (or any non-resolved phase) would reset combatEnded=false,
        // dropping the RUN COMPLETE/RUN FAILED overlay out from under the
        // player and dumping them back on the empty combat scene with
        // enemies still standing — exactly the M6 defeat repro.
        let outcomeIsTerminal: Bool = {
            switch outcome {
            case .victory, .extracted, .defeat: return true
            case .none: return false
            }
        }()

        // Special case: extraction is in flight. The outcome is already
        // .extracted (set when the player stepped on the pad so the
        // ExtractionService and onComplete handlers can read it), but the
        // helicopter animation hasn't finished. If we latch combatEnded /
        // missionComplete here, the debrief overlay pops over the heli
        // sequence. Wait for finalizeExtractionAfterAnimation to do the
        // latch — it runs from the animation's onComplete or the 11s
        // safety net.
        let extractionInFlight = (outcome == .extracted)
            && gameState.extractionAnimationInProgress

        if outcomeIsTerminal && !extractionInFlight {
            gameState.combatEnded = true
            gameState.missionComplete = true
        } else if outcomeIsTerminal && extractionInFlight {
            // Hold off on the terminal flags until the heli leaves.
            gameState.combatEnded = false
            gameState.missionComplete = false
        } else {
            switch phase {
            case .combatResolved, .rewarding, .complete:
                gameState.combatEnded = true
                gameState.missionComplete = true
            default:
                gameState.combatEnded = false
                gameState.missionComplete = false
            }
        }

        switch outcome {
        case .victory, .extracted:
            gameState.combatWon = true
        case .defeat:
            gameState.combatWon = false
        case .none:
            gameState.combatWon = nil
        }
    }

    /// Broad combat closure flags are owned here so setup/outcome flows do not write ad hoc.
    static func resetCombatOutcomeFlagsForNewMission(gameState: GameState) {
        CombatFlowController.setCombatPhase(gameState: gameState, .idle)
        CombatFlowController.setCombatOutcome(gameState: gameState, .none)
    }

    /// Canonical owner path for combat outcome flags once a terminal result is determined.
    static func applyCombatOutcome(gameState: GameState, won: Bool) {
        CombatFlowController.setCombatPhase(gameState: gameState, .combatResolved)
        if won {
            // Preserve extraction-specific terminal outcome if it was set during request path.
            if gameState.combatOutcome != .extracted {
                CombatFlowController.setCombatOutcome(gameState: gameState, .victory)
            }
        } else {
            CombatFlowController.setCombatOutcome(gameState: gameState, .defeat)
        }
    }

    static func beginRound(gameState: GameState) {
        // Resolve damage-over-time FIRST — at the round transition (effectively
        // enemy-phase end), before the input phase opens. Was ticked at the END
        // of beginRound, AFTER .playerInput was set, so a burn death raced the
        // new round's input. If a DoT causes a TPK, bail before opening input.
        CombatFlowController.tickStatusEffects(gameState: gameState)
        if gameState.combatEnded { return }
        CombatFlowController.setCombatPhase(gameState: gameState, .playerInput)
        // Roll stun recovery BEFORE deciding who skips — otherwise a player who
        // rolls out of stun this round is still marked "skip" by the line below,
        // losing a turn they actually recovered. (Enemies recover inside their
        // own AI tick, so they were never affected by this ordering.)
        CombatFlowController.recoverStunAtRoundStart(gameState: gameState)
        CombatFlowController.resetTurnTracking(gameState: gameState)
        gameState.defenders.removeAll()
        // Restore any AGI nerfs from Face's INTIMIDATE — the debuff lasts ONE
        // round, then enemies recover their wits.
        if !gameState.intimidationOriginalAgi.isEmpty {
            for enemy in gameState.enemies {
                if let original = gameState.intimidationOriginalAgi[enemy.id] {
                    enemy.attributes.agi = original
                }
            }
            gameState.intimidationOriginalAgi.removeAll()
        }
        // (stun recovery moved to the top of beginRound — see comment above)
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
        // (status-effect tick moved to the TOP of beginRound — see comment there)
    }

    static func resetTurnTracking(gameState: GameState) {
        // Stunned characters auto-skip their turn (they can't act while fully stunned)
        // They still count as "acted" so the round advances without them.
        gameState.playersWhoHaveNotActed = Set(
            gameState.playerTeam.filter { $0.isAlive && $0.status != .stunned }.map { $0.id }
        )
        gameState.playerTurnsCompleted = 0
        gameState.characterHasMovedThisTurn = [:]
        // Reset per-character action flags at start of new round
        for char in gameState.playerTeam {
            char.hasActedThisRound = false
            gameState.characterHasMovedThisTurn[char.id] = false
            // Log stunned characters being skipped
            if char.isAlive && char.status == .stunned {
                gameState.addLog("💤 \(char.name) is STUNNED — skipping turn. (Stun \(char.currentStun)/\(char.maxStun))")
                char.hasActedThisRound = true
            }
        }
        // Clear overwatch — it expires at end of each round
        gameState.overwatchers.removeAll()
        NotificationCenter.default.post(name: .overwatchExpired, object: nil)

        // Roll initiative for the round: REA + INT + 1d6 + cyberware. The
        // auto-advance order follows these rolls, so initiative implants
        // genuinely move a runner earlier in the round.
        var initiativeRolls: [(char: Character, roll: Int)] = []
        for char in gameState.playerTeam where char.isAlive {
            let roll = DiceEngine.rollInitiative(rea: char.attributes.rea, int: char.attributes.int) + char.cyberInitiative
            char.initiativeRoll = roll
            initiativeRolls.append((char, roll))
        }
        initiativeRolls.sort { $0.roll > $1.roll }
        gameState.roundInitiativeOrder = initiativeRolls.map { $0.char.id }
        if initiativeRolls.count > 1 {
            gameState.addLog("⚡ INITIATIVE: " + initiativeRolls.map { "\($0.char.name) \($0.roll)" }.joined(separator: " › "))
        }
    }

    /// Next living player who hasn't acted yet, in this round's initiative
    /// order (falling back to roster order if no order has been rolled yet,
    /// e.g. before the first beginRound of a mission). Deterministic within a
    /// round, so mid-round roster taps can't reshuffle who comes next.
    static func nextPendingActor(gameState: GameState) -> Character? {
        for id in gameState.roundInitiativeOrder {
            if let char = gameState.playerTeam.first(where: { $0.id == id && $0.isAlive }),
               gameState.playersWhoHaveNotActed.contains(id) {
                return char
            }
        }
        return gameState.playerTeam.first {
            $0.isAlive && gameState.playersWhoHaveNotActed.contains($0.id)
        }
    }

    static func characterHasAlreadyMoved(gameState: GameState, _ character: Character) -> Bool {
        if gameState.characterHasMovedThisTurn[character.id] == true {
            gameState.addLog("\(character.name) already moved this turn — choose move OR action.")
            HapticsManager.shared.buttonTap()
            return true
        }
        return false
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

    static func tickStatusEffects(gameState: GameState) {
        // Tick player status effects
        for char in gameState.playerTeam {
            guard char.isAlive else { continue }
            var toRemove: [Int] = []
            for (i, effect) in char.statusEffects.enumerated() {
                switch effect {
                case .burning(let rounds):
                    char.takeDamage(amount: 3, isStun: false)
                    gameState.addLog("🔥 \(char.name) BURNS! 3 damage. (\(char.currentHP)/\(char.maxHP) HP)")
                    NotificationCenter.default.post(name: .characterHit, object: nil, userInfo: ["characterId": char.id.uuidString, "damage": 3])
                    if char.isAlive {
                        let newRounds = rounds - 1
                        if newRounds <= 0 { toRemove.append(i) }
                        else { char.statusEffects[i] = .burning(roundsLeft: newRounds) }
                    } else {
                        toRemove.append(i)
                        // Bug fix 2026-05: burn-out wasn't firing the death
                        // pipeline, so the corpse stayed on screen and turn
                        // tracking still treated them as a participant.
                        CombatFlowController.handlePlayerKilled(gameState: gameState, char: char)
                    }
                case .prone:
                    // Knockdown lasts the round it was inflicted, then clears.
                    // The round-stamp guard matters for PLAYERS: this tick
                    // fires right after the enemy phase, so a riot knockdown
                    // landed moments ago must survive it to actually pin the
                    // runner through their upcoming input phase.
                    if let inflicted = gameState.proneInflictedRound[char.id],
                       inflicted >= gameState.roundNumber {
                        break
                    }
                    toRemove.append(i)
                    gameState.proneInflictedRound.removeValue(forKey: char.id)
                    gameState.addLog("🔻 \(char.name) gets back up.")
                case .confused(let rounds):
                    // Same countdown shape as .burning (no per-tick damage —
                    // the payoff happens on the confused unit's own turn).
                    // Players can't currently BE confused (the spell targets
                    // enemies), but tick symmetrically so a future source
                    // can't leave the status stuck forever.
                    let newRounds = rounds - 1
                    if newRounds <= 0 {
                        toRemove.append(i)
                        gameState.addLog("🌀 \(char.name) shakes off the confusion.")
                    } else {
                        char.statusEffects[i] = .confused(roundsLeft: newRounds)
                    }
                default:
                    break
                }
            }
            for i in toRemove.reversed() { char.statusEffects.remove(at: i) }
        }
        // Tick enemy status effects
        for enemy in gameState.enemies {
            guard enemy.isAlive else { continue }
            var toRemove: [Int] = []
            for (i, effect) in enemy.statusEffects.enumerated() {
                switch effect {
                case .burning(let rounds):
                    enemy.takeDamage(amount: 3, isStun: false)
                    gameState.addLog("🔥 \(enemy.name) BURNS! 3 damage. (\(enemy.currentHP)/\(enemy.maxHP) HP)")
                    // Visual HP-bar refresh + damage pop. Without this the
                    // enemy's bar stayed frozen at its pre-burn HP, hiding
                    // the actual death from the player.
                    NotificationCenter.default.post(name: .enemyHit, object: nil, userInfo: ["enemyId": enemy.id.uuidString, "damage": 3, "outcome": "hit"])
                    if enemy.isAlive {
                        let newRounds = rounds - 1
                        if newRounds <= 0 { toRemove.append(i) }
                        else { enemy.statusEffects[i] = .burning(roundsLeft: newRounds) }
                    } else {
                        toRemove.append(i)
                        // Bug fix 2026-05: burn-out kills weren't routing
                        // through the death pipeline, so the enemy stayed
                        // on screen "alive-looking" while `livingEnemies`
                        // (and the room-clear / data-acquired logic) saw
                        // them as dead. Symptom: ATK said "no enemies in
                        // range" while the player could clearly see them.
                        gameState.handleEnemyKilledByEnvironment(enemy)
                    }
                case .prone:
                    // Knockdown (BLITZ sweep) clears at the round tick — the
                    // enemy spent its grounded turn, now it stands. The
                    // round-stamp guard is a no-op for enemies today (BLITZ
                    // lands in the player phase, and roundNumber has always
                    // advanced by this tick) but keeps the rule symmetric
                    // with the player loop above.
                    if let inflicted = gameState.proneInflictedRound[enemy.id],
                       inflicted >= gameState.roundNumber {
                        break
                    }
                    toRemove.append(i)
                    gameState.proneInflictedRound.removeValue(forKey: enemy.id)
                    gameState.addLog("🔻 \(enemy.name) gets back up.")
                case .confused(let rounds):
                    // Countdown mirrors .burning; the scrambled turn itself is
                    // handled at the top of runEnemyAI.
                    let newRounds = rounds - 1
                    if newRounds <= 0 {
                        toRemove.append(i)
                        gameState.addLog("🌀 \(enemy.name) shakes off the confusion.")
                    } else {
                        enemy.statusEffects[i] = .confused(roundsLeft: newRounds)
                    }
                default:
                    break
                }
            }
            for i in toRemove.reversed() { enemy.statusEffects.remove(at: i) }
        }
    }

    static func performAttack(gameState: GameState) {
        let attacker: Character?
        guard canAcceptPlayerAction(gameState: gameState) else { return }
        if let selected = gameState.selectedCharacterId, let char = gameState.playerTeam.first(where: { $0.id == selected && $0.isAlive }) {
            attacker = char
        } else {
            attacker = gameState.currentCharacter
        }
        guard let a = attacker else { gameState.addLog("No character available."); return }
        guard !CombatFlowController.characterHasAlreadyMoved(gameState: gameState, a) else { return }

        // Resolve target: prefer the player's tap-selected target, else fall
        // back to the nearest living enemy. This matches `performHack` /
        // `castSingleTarget` behavior and removes the "tap an enemy first"
        // friction step — ATK/SHT now Just Work as long as any enemy exists.
        let targetEnemy: Enemy
        let targetId: UUID
        if let tid = gameState.targetCharacterId,
           let e = gameState.enemies.first(where: { $0.id == tid && $0.isAlive }) {
            targetEnemy = e
            targetId = tid
        } else {
            // Pick closest living enemy by hex distance from the attacker.
            let candidates = gameState.livingEnemies
                .map { ($0, gameState.hexDistance(x1: a.positionX, y1: a.positionY, x2: $0.positionX, y2: $0.positionY)) }
                .sorted { $0.1 < $1.1 }
            guard let nearest = candidates.first?.0 else {
                // Verbose diagnostic — user reported visible enemies still
                // on screen with HP, but `livingEnemies` returned empty. We
                // need to see exactly what GameState thinks vs. what's on
                // screen. Print every enemy with status, HP, position.
                let total = gameState.enemies.count
                let alive = gameState.enemies.filter { $0.isAlive }.count
                let detail = gameState.enemies
                    .map { "\($0.name)@(\($0.positionX),\($0.positionY))[s=\($0.status),hp=\($0.currentHP)/\($0.maxHP),alive=\($0.isAlive)]" }
                    .joined(separator: " | ")
                gameState.addLog("⚠️ DIAG: enemies=\(total) alive=\(alive) | \(detail)")
                return
            }
            targetEnemy = nearest
            targetId = nearest.id
            gameState.targetCharacterId = nearest.id
        }

        var weapon = a.equippedWeapon ?? Weapon(name: "Fists", type: .unarmed, damage: 3, accuracy: 3, armorPiercing: 0)

        // Melee-only enforcement for the Street Samurai. Raze's loadout is
        // a katana, no sidearm — if the target is out of melee range, the
        // action fails cleanly (no turn consumed). Other melee-class chars
        // (mage stunball) still get the sidearm fallback so they have SOME
        // ranged option if their spells are out / out-of-mana.
        if weapon.type == .blade || weapon.type == .unarmed {
            let distance = gameState.hexDistance(
                x1: a.positionX, y1: a.positionY,
                x2: targetEnemy.positionX, y2: targetEnemy.positionY
            )
            if distance > 1 {
                if a.archetype == .streetSam || a.archetype == .decker {
                    gameState.addLog("⚔️ \(a.name)'s \(weapon.name) is melee only — move adjacent first.")
                    HapticsManager.shared.error()
                    return   // no turn consumed
                }
                // Non-samurai melee classes get the sidearm fallback.
                weapon = Weapon(name: "Sidearm", type: .pistol, damage: 4,
                                accuracy: 4, armorPiercing: 1)
                gameState.addLog("\(a.name) is too far for melee — drawing sidearm.")
            }
        }

        if gameState.isLineBlockedByWall(
            fromX: a.positionX, fromY: a.positionY,
            toX: targetEnemy.positionX, toY: targetEnemy.positionY
        ) {
            gameState.addLog("⛔ Line of sight blocked by wall!")
            HapticsManager.shared.buttonTap()
            return
        }

        // Determine attack skill from weapon type
        let skill: SkillKey = (weapon.type == .blade || weapon.type == .unarmed) ? .blades : .firearms

        // Attack pool: AGI + skill + weapon-accuracy bonus.
        // Tuning history:
        //   • Original: just AGI+skill (~6-7d). Vs. defense 6-9d this missed
        //     ~75% of the time — felt broken.
        //   • Bumped to +acc/2 (~+2 dice). Pushed it to ~95% hit rate. Too
        //     deterministic the other way.
        //   • Now: +acc/3 (rounds down). Pistol acc 4 → +1, SMG acc 5 → +1,
        //     Rifle acc 7 → +2, Sniper acc 6 → +2. Lands a typical attacker
        //     at 8d vs. 6d defense → ~70% hit rate with variance.
        let weaponBonus = max(0, weapon.accuracy / 3)
        // SIGNAL "Ride the Heat" — extra attack dice that scale with TRACE heat.
        let signalBonus = gameState.signalDiceBonus

        // Ranged falloff applied to the ATTACK POOL (not just damage). Shots
        // past a weapon's effective range are harder to LAND — fewer net hits,
        // so fewer/no crits at long range, not merely a few points less damage.
        // Melee is adjacency-gated, so it never takes a penalty.
        let isMeleeWeapon = weapon.type == .blade || weapon.type == .unarmed
        let effectiveRange: Int
        switch weapon.type {
        case .pistol:          effectiveRange = 3
        case .smg:             effectiveRange = 5
        case .rifle:           effectiveRange = 8
        case .blade, .unarmed: effectiveRange = 99
        }
        let shotDistance = gameState.hexDistance(
            x1: a.positionX, y1: a.positionY,
            x2: targetEnemy.positionX, y2: targetEnemy.positionY)
        // 1 die per tile past effective range, capped at -4. Each lost die is
        // ~0.33 fewer expected hits, so long-range fire both misses more and
        // can't reach the crit threshold the way point-blank fire does.
        let rangePenalty = isMeleeWeapon ? 0 : min(4, max(0, shotDistance - effectiveRange))
        let rangeNote = rangePenalty > 0 ? " (range -\(rangePenalty)d)" : ""
        let attackPool = max(1, a.attackPool(skill: skill) + weaponBonus + signalBonus - rangePenalty)

        switch gameState.actionMode {
        case .street: gameState.applyStreetAction()
        case .signal: gameState.applySignalAction()
        }
        if signalBonus > 0 { gameState.addLog("📡 SIGNAL +\(signalBonus)d (running hot)") }

        // Cover bonus: count cover tiles between attacker and target
        let coverCount = CombatMechanics.coverBetween(
            tiles: gameState.currentMissionTiles,
            fromX: a.positionX, fromY: a.positionY,
            toX: targetEnemy.positionX, toY: targetEnemy.positionY
        )
        let coverBonus = CombatMechanics.coverDefenseBonus(count: coverCount)

        // Defense pool: REA + AGI + cover bonus.
        // Hacked / stunned enemies take a -2 dice flat penalty (down from
        // halving — halving made hacked targets near-guaranteed multi-hits,
        // which removed the dice-roll tension). -2 keeps the hack meaningful
        // (~33% smaller defense pool against a typical 6d enemy) without
        // making everything an instant kill.
        let baseDefense = targetEnemy.attributes.rea + targetEnemy.attributes.agi + coverBonus
        // FLANKING: a living teammate of the attacker adjacent to the target
        // AND on its far side (see CombatMechanics.isFlanked for the far-side
        // approximation) pins the target in a crossfire — it defends at -2
        // dice. Symmetric with the enemy→player check
        // (GameState.flankedDefensePenalty), and shown in the hit preview
        // (computeHitPreview takes the same ally positions).
        let attackerAllies = gameState.livingPlayers
            .filter { $0.id != a.id }
            .map { (x: $0.positionX, y: $0.positionY) }
        let isTargetFlanked = CombatMechanics.isFlanked(
            targetX: targetEnemy.positionX, targetY: targetEnemy.positionY,
            attackerX: a.positionX, attackerY: a.positionY,
            allies: attackerAllies)
        // Prone enemies (riot knockdown / BLITZ sweep) defend at -2 dice too —
        // no diving for cover from the floor. STACKS with the stun penalty
        // (a hacked target that's ALSO flat on its back is nearly helpless,
        // which is exactly the hack→Blitz combo payoff) AND the flanking
        // penalty, all under the same min-1 clamp.
        let statusPenalty = ((targetEnemy.status == .stunned) ? 2 : 0)
            + (targetEnemy.statusEffects.contains(.prone) ? 2 : 0)
            + (isTargetFlanked ? 2 : 0)
        let defensePool: Int = statusPenalty > 0
            ? max(1, baseDefense - statusPenalty)
            : baseDefense

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
            // "Misfires" only makes sense for firearms — a katana can't misfire.
            // Pick a verb that fits the weapon class.
            let glitchVerb: String
            switch weapon.type {
            case .blade:   glitchVerb = "swings wide and misses"
            case .unarmed: glitchVerb = "loses balance"
            case .pistol, .smg, .rifle: glitchVerb = "misfires"
            }
            gameState.addLog("⚠️ GLITCH! \(a.name)'s \(weapon.name) \(glitchVerb)!")
            CombatFlowController.completeAction(gameState: gameState, for: a)
            return
        }

        // Defense roll
        let defenseRoll = DiceEngine.roll(pool: defensePool)
        let netHits = max(0, attackRoll.hits - defenseRoll.hits)

        // FLANKED! rides the attack line itself so the player connects the
        // positioning (ally behind the target) to the smaller defense pool.
        let flankNote = isTargetFlanked ? " ⚔️ FLANKED! (−2 DEF)" : ""
        gameState.addLog("⚔️ \(a.name) attacks with \(weapon.name)!\(rangeNote)\(flankNote) [\(attackPool)d6→\(attackRoll.hits)] vs [\(defensePool)d6→\(defenseRoll.hits)\(coverBonus > 0 ? " +\(coverBonus)cov" : "")]")

        // Visual: muzzle flash + tracer for ranged, slash arc for melee.
        // Fired regardless of hit/miss so the player always sees something
        // happen when they tap ATK/SHT.
        let isMelee = weapon.type == .blade || weapon.type == .unarmed
        if isMelee {
            NotificationCenter.default.post(
                name: .meleeStrikeEffect, object: nil,
                userInfo: [
                    "x": targetEnemy.positionX,
                    "y": targetEnemy.positionY,
                    "weaponType": weapon.type.rawValue,
                    "attackerId": a.id.uuidString   // animate the attacker's sprite
                ]
            )
        } else {
            NotificationCenter.default.post(
                name: .gunfireEffect, object: nil,
                userInfo: ["fromX": a.positionX, "fromY": a.positionY,
                           "toX": targetEnemy.positionX, "toY": targetEnemy.positionY,
                           "weaponType": weapon.type.rawValue,
                           "attackerId": a.id.uuidString]   // animate the attacker's sprite
            )
        }

        // DESTRUCTIBLE COVER: ranged fire that traced through cover has a 25%
        // chance to splinter the cover tile nearest the target. Rolled here —
        // AFTER the attack/defense dice (so THIS shot still got the full
        // cover bonus) but on hit AND miss alike (bullets chew crates either
        // way). Glitch branches returned above: a misfire never left the
        // barrel, so nothing downrange takes wear.
        if !isMelee {
            gameState.maybeDegradeCoverAlongShot(
                fromX: a.positionX, fromY: a.positionY,
                toX: targetEnemy.positionX, toY: targetEnemy.positionY)
        }

        if netHits == 0 {
            gameState.addLog("  → MISS! \(targetEnemy.name) dodges!")
            NotificationCenter.default.post(name: .enemyHit, object: nil, userInfo: ["enemyId": targetId.uuidString, "damage": 0, "outcome": "miss"])
            CombatFlowController.completeAction(gameState: gameState, for: a)
            return
        }

        // CRIT FISHING — net hits ≥ critThreshold lands a critical. STREET
        // needs 4; SIGNAL sharpens the bar as heat rises (3, then 2 at HIGH).
        // A crit adds flat damage AND bites through armor. Note: the range
        // penalty is already baked into `attackPool` above, so long-range fire
        // produces fewer net hits and reaches this crit bar far less often.
        let isCrit = netHits >= gameState.critThreshold
        if isCrit { gameState.addLog("🎯 CRITICAL HIT!") }
        let critDamage = isCrit ? 2 : 0
        let critAP = isCrit ? 2 : 0

        // Damage = weapon base + net hits (+ crit) (floored at 1). Falloff is
        // handled on the attack pool now, not subtracted again here.
        let baseDamage = max(1, weapon.damage + netHits + critDamage)
        let ap = weapon.armorPiercing + critAP

        // Soak: enemy BOD + armor - AP (minimum 0)
        let soakPool = max(0, targetEnemy.computeDerived().soak - ap)
        let soakRoll = DiceEngine.roll(pool: soakPool)
        let finalDamage = max(0, baseDamage - soakRoll.hits)

        // Ranged shots get a short "bullet-travel" beat so the impact spark,
        // damage number, hit-SFX AND impact haptic all land AFTER the tracer
        // crosses rather than on trigger-pull (melee connects instantly). State
        // already mutated above — this only delays the FEEDBACK.
        let impactDelay: Double = isMelee ? 0.0 : 0.15
        if impactDelay > 0 {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(impactDelay * 1_000_000_000))
                HapticsManager.shared.attackHit()
            }
        } else {
            HapticsManager.shared.attackHit()
        }
        let isStunDmg = weapon.isStunDamage
        targetEnemy.takeDamage(amount: finalDamage, isStun: isStunDmg)
        let dmgType = isStunDmg ? "S" : "P"

        if finalDamage > 0 {
            gameState.addLog("  → \(netHits) net hits!\(rangeNote) \(baseDamage)\(dmgType) - \(soakRoll.hits) soak = \(finalDamage) dmg! (\(targetEnemy.currentHP)/\(targetEnemy.maxHP) HP | Stun \(targetEnemy.currentStun)/\(targetEnemy.maxStun))")
        } else {
            gameState.addLog("  → Hit but \(targetEnemy.name) soaks ALL damage!")
        }

        // Fire melee-impact event so SFXManager plays the wet-thunk clip
        // only when blade actually lands damage (not on full-soak / miss).
        // 4+ net hits = critical (top-tier hit), routed to a beefier SFX.
        if isMelee && finalDamage > 0 {
            NotificationCenter.default.post(
                name: .meleeImpactEffect, object: nil,
                userInfo: [
                    "x": targetEnemy.positionX,
                    "y": targetEnemy.positionY,
                    "critical": isCrit,
                    "weaponType": weapon.type.rawValue
                ]
            )
        }

        // impactDelay (defined above) is forwarded so the BattleScene observers
        // delay the on-screen spark + damage number to match the SFX/haptic.
        NotificationCenter.default.post(name: .enemyHit, object: nil, userInfo: ["enemyId": targetId.uuidString, "damage": finalDamage, "outcome": finalDamage > 0 ? "hit" : "soak", "impactDelay": impactDelay, "critical": isCrit])

        if !targetEnemy.isAlive {
            HapticsManager.shared.enemyKilled()
            gameState.missionEnemiesDefeated += 1
            CombatFlowController.handleEnemyKillForRoomEffects(gameState: gameState)
            let bounty = MissionStatsStore.killBounty(maxHP: targetEnemy.maxHP)
            MissionStatsStore.shared.awardKillNuyen(maxHP: targetEnemy.maxHP)
            gameState.addLog("☠️ \(targetEnemy.name) DOWN! +\(targetEnemy.maxHP / 2) XP · +¥\(bounty)")
            gameState.generateLoot(by: a)
            if let char = gameState.playerTeam.first(where: { $0.id == a.id }) {
                let leveledUp = char.gainXP(targetEnemy.maxHP / 2)
                if leveledUp {
                    HapticsManager.shared.levelUp()
                    gameState.addLog("🎖️ LEVEL UP! \(char.name) → Level \(char.level)!")
                    NotificationCenter.default.post(name: .characterLevelUp, object: nil, userInfo: ["characterId": char.id.uuidString])
                }
            }
            NotificationCenter.default.post(name: .enemyDied, object: nil, userInfo: ["enemyId": targetId.uuidString, "impactDelay": impactDelay, "playerKill": true])
            if gameState.livingEnemies.isEmpty { gameState.onRoomCleared() }
        }

        CombatFlowController.completeAction(gameState: gameState, for: a)
    }

    static func performShoot(gameState: GameState) {
        let attacker: Character?
        guard canAcceptPlayerAction(gameState: gameState) else { return }
        if let selected = gameState.selectedCharacterId, let char = gameState.playerTeam.first(where: { $0.id == selected && $0.isAlive }) {
            attacker = char
        } else {
            attacker = gameState.currentCharacter
        }
        guard let a = attacker else { gameState.addLog("No character available."); return }

        // Per-archetype sidearm. Cipher keeps the Smartgun Pistol he used
        // to carry as primary — when he taps SHT he's drawing his trained
        // backup, not a generic holdout. Everyone else uses the standard
        // Sidearm fallback.
        let sidearm: Weapon
        switch a.archetype {
        case .decker:
            sidearm = Weapon(name: "Smartgun Pistol", type: .pistol, damage: 5, accuracy: 5, armorPiercing: 1)
        default:
            sidearm = Weapon(name: "Sidearm", type: .pistol, damage: 4, accuracy: 4, armorPiercing: 1)
        }

        let originalWeapon = a.equippedWeapon
        let sidearmBaseDamage = sidearm.damage
        a.equippedWeapon = sidearm

        CombatFlowController.performAttack(gameState: gameState)

        // Restore the runner's primary weapon. If a weapon-mod LOOT drop landed
        // on the kill (generateLoot applies +damage to the equipped weapon),
        // it would have hit the TEMPORARY sidearm and been discarded on
        // restore — carry that permanent bonus onto the real weapon instead.
        if var orig = originalWeapon, let used = a.equippedWeapon, used.name == sidearm.name {
            let lootDelta = used.damage - sidearmBaseDamage
            if lootDelta > 0 { orig.damage += lootDelta }
            a.equippedWeapon = orig
        } else {
            a.equippedWeapon = originalWeapon
        }
    }

    static func performLayLow(gameState: GameState) {
        let actor: Character?
        guard canAcceptPlayerAction(gameState: gameState) else { return }
        if let selected = gameState.selectedCharacterId, let char = gameState.playerTeam.first(where: { $0.id == selected && $0.isAlive }) {
            actor = char
        } else {
            actor = gameState.currentCharacter
        }
        guard let character = actor else {
            gameState.addLog("No character available.")
            return
        }
        guard !CombatFlowController.characterHasAlreadyMoved(gameState: gameState, character) else { return }
        gameState.applyTraceRecovery()
        // Hunkering down also BRACES the runner this round (+DEF), so LAY LOW
        // is never a wasted turn — it's a defensive reset, not just a vent.
        gameState.defenders.insert(character.id)
        gameState.addLog("\(character.name) lays low — bracing (+2 DEF).")
        NotificationCenter.default.post(
            name: .characterDefend, object: nil,
            userInfo: ["characterId": character.id.uuidString]
        )
        CombatFlowController.completeAction(gameState: gameState, for: character) // Cost: consumes full turn
    }

    static func performSpell(gameState: GameState, type: SpellType, targetId: UUID? = nil) {
        // Resolve caster
        let char: Character?
        guard canAcceptPlayerAction(gameState: gameState) else { return }
        if let selected = gameState.selectedCharacterId, let c = gameState.playerTeam.first(where: { $0.id == selected && $0.isAlive }) {
            char = c
        } else {
            char = gameState.currentCharacter
        }
        guard let mage = char, mage.archetype == CharacterArchetype.mage else {
            gameState.addLog("Only mages can cast spells.")
            return
        }
        guard !CombatFlowController.characterHasAlreadyMoved(gameState: gameState, mage) else { return }
        let effectiveManaCost = max(0, type.manaCost - gameState.signalManaDiscount)
        guard mage.currentMana >= effectiveManaCost else {
            gameState.addLog("Not enough mana for \(type.displayName)! Need \(effectiveManaCost), have \(mage.currentMana).")
            HapticsManager.shared.buttonTap()
            return
        }

        // Dispatch by spell type
        switch type {
        case .fireball:
            gameState.castFireball(by: mage, targetId: targetId ?? gameState.targetCharacterId)
        case .manaBolt, .shock, .powerBolt, .stormBolt:
            // All single-target damage/stun spells share the resolver; their
            // own manaCost/baseDamage/isStunDamage drive the numbers.
            gameState.castSingleTarget(type: type, targetId: targetId ?? gameState.targetCharacterId, by: mage)
        case .confusion:
            // Control hex — no damage, so it has its own resolver (opposed
            // WIL resist instead of a soak roll).
            gameState.castConfusion(by: mage, targetId: targetId ?? gameState.targetCharacterId)
        case .heal:
            gameState.castHeal(by: mage, targetId: targetId)
        }
    }

    static func performDefend(gameState: GameState) {
        let char: Character
        guard canAcceptPlayerAction(gameState: gameState) else { return }
        if let selected = gameState.selectedCharacterId, let c = gameState.playerTeam.first(where: { $0.id == selected && $0.isAlive }) {
            char = c
        } else if let current = gameState.currentCharacter {
            char = current
        } else { return }
        guard !CombatFlowController.characterHasAlreadyMoved(gameState: gameState, char) else { return }
        HapticsManager.shared.buttonTap()
        gameState.defenders.insert(char.id)
        // DEFEND's distinct niche vs LAY LOW (which vents TRACE): catching your
        // breath also shakes off stun. Without this, DEFEND was strictly
        // dominated by LAY LOW (same +DEF, plus a vent). Now DEFEND is the
        // pick when you're stun-pressured, LAY LOW when you're running hot.
        var recoverNote = ""
        if char.currentStun > 0 {
            let roll = DiceEngine.roll(pool: char.attributes.bod + char.attributes.wil)
            if roll.hits > 0 {
                char.recoverStun(amount: roll.hits)
                recoverNote = " — shakes off \(roll.hits) stun (\(char.currentStun)/\(char.maxStun))"
            }
        }
        gameState.addLog("\(char.name) takes a defensive stance. (+DEF)\(recoverNote)")
        NotificationCenter.default.post(
            name: .characterDefend,
            object: nil,
            userInfo: ["characterId": char.id.uuidString]
        )
        CombatFlowController.completeAction(gameState: gameState, for: char)
    }

    static func performHack(gameState: GameState) {
        let char: Character?
        guard canAcceptPlayerAction(gameState: gameState) else { return }
        if let selected = gameState.selectedCharacterId, let c = gameState.playerTeam.first(where: { $0.id == selected && $0.isAlive }) {
            char = c
        } else {
            char = gameState.currentCharacter
        }
        guard let decker = char, decker.archetype == CharacterArchetype.decker else {
            gameState.addLog("Only Deckers can hack.")
            return
        }
        // Matrix intrusions require jacking in (SIGNAL), and ping TRACE.
        if !gameState.signalActive {
            gameState.addLog("⛔ Switch to SIGNAL to run a matrix intrusion.")
            gameState.postTransientWarning("SWITCH TO SIGNAL TO HACK", duration: 2.0)
            HapticsManager.shared.error()
            return
        }
        guard !CombatFlowController.characterHasAlreadyMoved(gameState: gameState, decker) else { return }
        guard decker.currentMana >= 2 else {
            gameState.addLog("Not enough matrix energy! Need 2, have \(decker.currentMana).")
            HapticsManager.shared.error()
            return
        }
        // TRACE pings only when an intrusion actually runs — a fumbled tap
        // (no mana, no target) shouldn't cost heat for an action that never
        // happened, so applySignalAction() sits BELOW every guard.
        guard let targetId = gameState.targetCharacterId,
              let target = gameState.enemies.first(where: { $0.id == targetId && $0.isAlive }) else {
            guard let nearest = gameState.livingEnemies.first else {
                gameState.addLog("No targets in range."); return
            }
            gameState.targetCharacterId = nearest.id
            gameState.applySignalAction()
            gameState.performHackOnTarget(nearest, by: decker)
            return
        }
        gameState.applySignalAction()
        gameState.performHackOnTarget(target, by: decker)
    }

    static func performIntimidate(gameState: GameState) {
        let char: Character?
        guard canAcceptPlayerAction(gameState: gameState) else { return }
        if let selected = gameState.selectedCharacterId, let c = gameState.playerTeam.first(where: { $0.id == selected && $0.isAlive }) {
            char = c
        } else {
            char = gameState.currentCharacter
        }
        guard let face = char, face.archetype == CharacterArchetype.face else {
            gameState.addLog("Only the Face can intimidate.")
            return
        }
        guard !CombatFlowController.characterHasAlreadyMoved(gameState: gameState, face) else { return }
        // Social pool: CHA + (LOG / 2)
        let socialPool = face.attributes.cha + face.attributes.log / 2
        let socialRoll = DiceEngine.roll(pool: socialPool)
        HapticsManager.shared.attackHit()

        if socialRoll.hits == 0 {
            gameState.addLog("🎭 \(face.name) tries to intimidate but the guards laugh it off.")
            CombatFlowController.completeAction(gameState: gameState, for: face)
            return
        }

        // Apply intimidation to all living enemies: snapshot original AGI so we
        // can restore it at the start of the next round (intimidation lasts a
        // single round). Without the snapshot the AGI mutation was permanent
        // for the rest of the battle, even though the log message said "this
        // round".
        // Each enemy faces a morale check vs the social hits. Those whose WILL
        // is BEATEN outright break and COWER (skip their next turn) — this is
        // the Face's crowd-control identity, shutting down weak-willed grunts.
        // High-WILL targets (elites, bosses) hold their nerve but still get
        // rattled into an AGI penalty for the round. Turns INTIMIDATE from a
        // near-useless −0.7-hit shave into a real "lock down the room" play.
        var cowered = 0, rattled = 0
        for enemy in gameState.livingEnemies {
            // Decisive break only — must beat WILL by 2+ (was >WIL, which cowered
            // most grunts every turn for free, duplicating Shock's hard-CC).
            if socialRoll.hits > enemy.attributes.wil + 1 {
                // Break: COWER and skip their next turn. Uses the dedicated
                // `.cowered` status (not `.stunned`) so it reads as fear and —
                // unlike a hack/stun — does NOT leave them defenseless. Softer
                // CC than the Decker's lock. runEnemyAI clears it after the skip.
                enemy.status = .cowered
                cowered += 1
            } else {
                // Hold but rattled — AGI shave for the round (snapshot/restore).
                if gameState.intimidationOriginalAgi[enemy.id] == nil {
                    gameState.intimidationOriginalAgi[enemy.id] = enemy.attributes.agi
                }
                let penalty = min(socialRoll.hits, enemy.attributes.agi - 1)
                enemy.attributes.agi = max(1, enemy.attributes.agi - penalty)
                rattled += 1
            }
        }
        let cowerNote = cowered > 0 ? " — \(cowered) BREAK and cower!" : ""
        gameState.addLog("🎭 \(face.name) INTIMIDATES! [\(socialPool)d6→\(socialRoll.hits)]\(cowerNote) (\(rattled) rattled −ATK)")
        // Visual: red shockwave radiating from Face's tile.
        NotificationCenter.default.post(
            name: .intimidateEffect, object: nil,
            userInfo: ["x": face.positionX, "y": face.positionY]
        )
        CombatFlowController.completeAction(gameState: gameState, for: face)
    }

    static func performBlitz(gameState: GameState) {
        let char: Character?
        guard canAcceptPlayerAction(gameState: gameState) else { return }
        if let selected = gameState.selectedCharacterId, let c = gameState.playerTeam.first(where: { $0.id == selected && $0.isAlive }) {
            char = c
        } else {
            char = gameState.currentCharacter
        }
        guard let sam = char, sam.archetype == CharacterArchetype.streetSam else {
            gameState.addLog("Only the Street Samurai can Blitz.")
            return
        }
        guard !CombatFlowController.characterHasAlreadyMoved(gameState: gameState, sam) else { return }

        // Charge limit (replaces mana cost — 4 + level charges per mission)
        guard sam.blitzChargesRemaining > 0 else {
            gameState.addLog("⚡ \(sam.name) is out of Blitz charges this run.")
            return
        }

        // Find every enemy within hex-distance 1 of the samurai. Blitz is a
        // melee sweep — it hits ALL adjacent enemies at once, not a
        // long-range pick. We use cube-coordinate hexDistance (rather than
        // the neighbor-list hexAdjacent) so any rendering-vs-logic position
        // ambiguity at the edges of the offset grid still resolves to a
        // proper distance check.
        let adjacents = gameState.livingEnemies.filter {
            gameState.hexDistance(x1: sam.positionX, y1: sam.positionY,
                                  x2: $0.positionX,  y2: $0.positionY) <= 1
        }
        guard !adjacents.isEmpty else {
            // Diagnostic: log positions so we can tell whether the samurai's
            // logical position drifted from where the player thinks he is.
            let sx = sam.positionX, sy = sam.positionY
            let enemyPositions = gameState.livingEnemies
                .map { "\($0.name)@(\($0.positionX),\($0.positionY)):d\(gameState.hexDistance(x1: sx, y1: sy, x2: $0.positionX, y2: $0.positionY))" }
                .joined(separator: ", ")
            gameState.addLog("⚡ Move adjacent first. Samurai @(\(sx),\(sy)) | \(enemyPositions)")
            return
        }

        sam.blitzChargesUsed += 1
        let chargesLeft = sam.blitzChargesRemaining
        gameState.addLog("⚡ \(sam.name) BLITZES \(adjacents.count) target\(adjacents.count == 1 ? "" : "s")! (\(chargesLeft) charges left)")
        // Visual: red slash arc from the samurai's tile.
        NotificationCenter.default.post(
            name: .blitzEffect, object: nil,
            userInfo: ["x": sam.positionX, "y": sam.positionY]
        )
        for enemy in adjacents {
            gameState.performBlitzOnTarget(enemy, by: sam)
        }
        // Final room-cleared check + single turn advance after the sweep.
        if gameState.livingEnemies.isEmpty { gameState.onRoomCleared() }
        CombatFlowController.completeAction(gameState: gameState, for: sam)
    }

    static func moveCharacter(gameState: GameState, id: UUID, toTileX tileX: Int, toTileY tileY: Int) {
        guard let char = gameState.playerTeam.first(where: { $0.id == id && $0.isAlive }) else { return }
        guard canAcceptPlayerAction(gameState: gameState) else { return }
        guard !char.hasActedThisRound else {
            gameState.addLog("\(char.name) has already acted this round.")
            return
        }
        guard gameState.characterHasMovedThisTurn[id] != true else {
            gameState.addLog("\(char.name) already moved this turn.")
            return
        }
        // Prone runners (riot-shotgun knockdown) are pinned to their tile —
        // they can still act (attack/cast/defend from the deck) but cannot
        // reposition until tickStatusEffects stands them back up.
        guard !char.statusEffects.contains(.prone) else {
            gameState.addLog("🔻 \(char.name) is prone — can act but not move this round.")
            HapticsManager.shared.error()
            return
        }
        char.positionX = tileX
        char.positionY = tileY
        gameState.characterHasMovedThisTurn[id] = true
        gameState.addLog("\(char.name) moves to (\(tileX),\(tileY))")
        // Footstep SFX — random variant of the surface material set by
        // mission (street/exterior = concrete, interior corp = metal).
        // 2026-05: bumped 0.45 → 0.52 (+15%) — earlier global trims left
        // them too quiet vs the rest of the SFX layer.
        let surface = (gameState.currentMissionDisplayId == "Mission001") ? "concrete" : "metal"
        let variant = Int.random(in: 1...4)
        SFXManager.shared.play("step_\(surface)_\(variant)", volume: 0.52)
        NotificationCenter.default.post(
            name: .tileTapped,
            object: nil,
            userInfo: ["tileX": tileX, "tileY": tileY, "characterId": id.uuidString]
        )
        // ENEMY OVERWATCH: a sniper/turret that banked its shot last enemy
        // phase reacts to this movement commit — MOVEMENT ONLY (DEFEND, LAY
        // LOW, attacks etc. never trigger it; note performOverwatch on the
        // player side has the same movement-only trigger against enemies).
        // Fired AFTER the position commit so the reaction shot resolves
        // against the tile the runner moved TO, with that tile's cover dice.
        gameState.fireEnemyOverwatchShots(atMovingPlayer: char)
        // A runner dropped by the reaction shot doesn't go on to trigger
        // objective pulses or scoop up terminals from the floor.
        guard char.isAlive else { return }
        // Floor-pulse VFX on objective tile entry (data terminal or
        // extraction). Single expanding ring — fires once per step-on, not
        // per render frame.
        if tileY >= 0, tileY < gameState.currentMissionTiles.count,
           tileX >= 0, tileX < gameState.currentMissionTiles[tileY].count {
            let raw = gameState.currentMissionTiles[tileY][tileX]
            if raw == TileType.dataTerminal.rawValue || raw == TileType.extraction.rawValue {
                NotificationCenter.default.post(
                    name: .objectivePulseRequested,
                    object: nil,
                    userInfo: ["tileX": tileX, "tileY": tileY, "kind": raw]
                )
            }
        }
        checkDataTerminalPickup(gameState: gameState, atX: tileX, y: tileY, by: char)
        checkGrimoirePickup(gameState: gameState, atX: tileX, y: tileY, by: char)
        // STEPPING ONTO EXTRACTION RESOLVES IT. Previously the pad only
        // adjudicated on an explicit tap, or at the end of an enemy phase —
        // and once the last enemy is dead there IS no enemy phase. A player who
        // walked the final runner onto the pad (rather than tapping it) got the
        // objective pulse above and then nothing at all: no extraction, no
        // message, since every messaged rejection lives inside requestExtraction
        // and that was never reached. Data terminals already get a step-on
        // handler one line up; extraction deserves the same.
        // adjudicate* is internally guarded (enemies clear, pendingSpawns empty,
        // extraction active, data satisfied, runner actually on the pad) and is
        // idempotent via extractionAnimationInProgress, so this is safe to call
        // on every move commit.
        adjudicateExtractionIfEligible(gameState: gameState)
        // Movement consumes the character's action choice, but does not auto-advance.
        // Keep player input open so the player can explicitly end early via END.
    }

    /// M3 boss-phase-2 trigger. When the corp mage at the M3R2 altar dies,
    /// his TRUE FORM (the boss mage) manifests on the same tile. Idempotent —
    /// only fires once per attempt via `mageBossPhase2Triggered`. Called from
    /// the BattleScene `.enemyDied` observer with the dead enemy's ID.
    static func checkMageBossPhase2(gameState: GameState, deadEnemyId: UUID) {
        // One-shot per mission attempt — once Triggered, this never re-fires.
        guard !gameState.mageBossPhase2Triggered else {
            // But if Sato already fell and the spawn is DEFERRED, check whether
            // the field is finally clear so the boss can manifest now.
            checkMageBossPhase2PendingResolve(gameState: gameState)
            return
        }
        // Only fires on M3 Ritual Chamber.
        guard gameState.currentMissionDisplayId == "Mission003" else { return }
        guard gameState.currentRoomId == "room_2" else { return }
        // The dead enemy must be the corp mage (archetype "mage"). Other
        // archetypes (the two guards) don't trigger phase 2.
        guard let dead = gameState.enemies.first(where: { $0.id == deadEnemyId }) else { return }
        guard dead.archetype.lowercased() == "mage" else { return }

        gameState.mageBossPhase2Triggered = true

        // If other enemies are still alive, DEFER the boss spawn. The boss
        // emerges only after the room is otherwise empty so he never appears
        // mid-melee. Stash the tile for the eventual spawn.
        let othersAlive = gameState.enemies.contains { e in
            e.id != deadEnemyId && e.isAlive
        }
        if othersAlive {
            gameState.mageBossPhase2Pending   = true
            gameState.mageBossPendingSpawnX   = dead.positionX
            gameState.mageBossPendingSpawnY   = dead.positionY
            // Stop any DELAYED reinforcements from leaking in during the
            // reforming window — otherwise a guard on a spawn delay would
            // appear AFTER "Sato is reforming" with normal music, then the
            // boss would only manifest once that stray guard was also killed
            // (the out-of-order mess from playtest). Clearing here means the
            // room empties exactly once: when the already-present enemies die.
            gameState.pendingSpawns.removeAll()
            gameState.addLog("☠️  Sato falls — but the room thrums. His blood is gathering.")
            gameState.postTransientWarning("SATO IS REFORMING — CLEAR THE ROOM", duration: 3.0)
            return
        }

        // No one else alive — manifest the boss. He rises at the TOP of the
        // chamber (the entrance row) rather than on the altar tile where he
        // fell, so the boss enters from the top of screen like M4/M5/M6 do.
        spawnSatoBoss(gameState: gameState, atX: 3, atY: 9)
    }

    /// Called on every subsequent enemy death after Sato has fallen but the
    /// boss spawn is deferred. Fires the boss spawn once the room is empty.
    static func checkMageBossPhase2PendingResolve(gameState: GameState) {
        guard gameState.mageBossPhase2Pending else { return }
        // Only fires on M3 Ritual Chamber (same scope guard as checkMageBossPhase2).
        guard gameState.currentMissionDisplayId == "Mission003" else { return }
        guard gameState.currentRoomId == "room_2" else { return }
        // Boss already on the field? Bail.
        if gameState.enemies.contains(where: { $0.archetype.lowercased() == "bossmage" && $0.isAlive }) {
            gameState.mageBossPhase2Pending = false
            return
        }
        // Any non-boss living enemy remaining blocks the spawn.
        let othersAlive = gameState.enemies.contains { e in
            let arch = e.archetype.lowercased()
            return e.isAlive && arch != "bossmage"
        }
        if othersAlive { return }

        // Field is clear — boss manifests at the top of the chamber (see the
        // immediate path above; same top-of-screen entrance for consistency).
        spawnSatoBoss(gameState: gameState, atX: 3, atY: 9)
        gameState.mageBossPhase2Pending = false
    }

    /// Actual boss spawn — shared by the immediate and deferred paths. Suppresses
    /// any queued reinforcement waves so the boss is the focal threat (matching
    /// the M5/M6 deployBoss pattern), and posts all the audio/visual beats.
    private static func spawnSatoBoss(gameState: GameState, atX x: Int, atY y: Int) {
        // Pause any timed/pending reinforcement spawns — boss fight is the focus.
        gameState.pendingSpawns.removeAll()

        // The kill that triggered phase 2 ran onRoomCleared() synchronously
        // (this spawn rides the async .enemyDied observer), so the room is
        // already marked cleared with the door open. Re-lock it — the whole
        // boss fight otherwise happened in a "cleared" room the player could
        // simply walk out of, desyncing the room state.
        if RoomManager.shared.unmarkCurrentRoomCleared() {
            gameState.addLog("🔒 The chamber seals — Sato will not let you leave.")
        }

        // Spawn the boss mage on the stashed tile (Sato unleashed).
        let boss = Enemy.bossMage()
        NGPlusStore.shared.scaleForTier(boss)   // NG+ durability/stat scaling (matches deployBoss)
        boss.positionX = x
        boss.positionY = y

        // SPLASH FIRST, then the boss lands on the board. Presenting the reveal
        // before the append means the card is already rising when the sprite
        // materialises behind it, so dismissing the card IS the moment you first
        // see him — rather than watching him pop in and getting a card about it
        // afterwards.
        gameState.presentBossIntro(archetype: "bossmage", name: boss.name)
        gameState.enemies.append(boss)

        // Narrative beats — these are loud on purpose. The player should
        // feel that the fight just got serious.
        gameState.addLog("☠️  SATO RISES — his blood magic was only the start.")
        gameState.addLog("⚠️  BOSS — \(boss.name) (\(boss.maxHP) HP). Burn him down before he summons.")
        HapticsManager.shared.combatStart()

        // Bespoke boss-fight music. Falls back to the mission's track if the
        // user hasn't dropped the file yet (MusicManager logs the miss).
        MusicManager.shared.playLoop(filename: "mage_boss_theme", startOffset: 0)

        // Notify the renderer to place the new boss sprite.
        NotificationCenter.default.post(
            name: .enemySpawned,
            object: nil,
            userInfo: ["enemyId": boss.id.uuidString,
                       "x": boss.positionX, "y": boss.positionY]
        )
    }

    /// M3 grimoire pickup. Sits on the central ritual ALTAR — tile (3, 5) in
    /// `room_2` (Ritual Chamber) — the book-on-an-altar painted into the room
    /// background, dead centre on the pentagram. Collected when any player
    /// walks onto the altar tile (or taps it while on/adjacent) AFTER the boss
    /// mage is dead. Posts `.grimoireAcquired` so the scene animates the
    /// highlight out.
    static let grimoireTileX = 3
    static let grimoireTileY = 5
    static func checkGrimoirePickup(gameState: GameState, atX x: Int, y: Int, by char: Character) {
        // Only matters on M3 in the Ritual Chamber.
        guard gameState.currentMissionDisplayId == "Mission003" else { return }
        guard gameState.currentRoomId == "room_2" else { return }
        // Grimoire altar tile — centre of M3R2, on the pentagram.
        guard x == grimoireTileX, y == grimoireTileY else { return }
        // Don't double-pickup.
        guard !gameState.grimoireAcquired else { return }
        // Phase 2 boss must have been spawned AND killed. The grimoire is
        // bound to Sato while ANY form of him lives — corp mage OR boss form.
        let p2Triggered = gameState.mageBossPhase2Triggered
        let mageAlive = gameState.enemies.contains { e in
            let arch = e.archetype.lowercased()
            return (arch == "mage" || arch == "bossmage") && e.isAlive
        }
        guard p2Triggered, !mageAlive else {
            gameState.addLog("The grimoire pulses red — bound to Sato while he lives.")
            return
        }
        gameState.grimoireAcquired = true
        gameState.addLog("📖 \(char.name) snatches Sato's grimoire — GRIMOIRE ACQUIRED.")
        gameState.postTransientWarning("📖 GRIMOIRE OBTAINED", duration: 2.5)
        SFXManager.shared.play("terminal_correct", volume: 0.65)
        SFXManager.shared.play("mainframe_breach", volume: 0.5)
        NotificationCenter.default.post(
            name: .grimoireAcquired,
            object: nil,
            userInfo: ["x": x, "y": y]
        )
    }

    /// If the tile under the moving character is a data terminal, hack it.
    /// Converts the tile to floor in-memory, marks the objective complete, and
    /// posts .dataTerminalHacked so the scene can update its visual.
    static func checkDataTerminalPickup(gameState: GameState, atX x: Int, y: Int, by char: Character) {
        guard y >= 0, y < gameState.currentMissionTiles.count else { return }
        guard x >= 0, x < gameState.currentMissionTiles[y].count else { return }
        guard gameState.currentMissionTiles[y][x] == TileType.dataTerminal.rawValue else { return }
        // Cipher-only rule: Cipher (the decker) is the team's netrunner and is
        // normally the ONLY runner who can crack a terminal. The run can't be
        // soft-locked, though — if every decker is down, any surviving runner
        // may jack in.
        let deckerAlive = gameState.playerTeam.contains { $0.archetype == .decker && $0.isAlive }
        if char.archetype != .decker && deckerAlive {
            gameState.addLog("⛔ Only Cipher can crack the terminal — get the decker adjacent.")
            HapticsManager.shared.error()
            return
        }
        // SIGNAL-gated: cracking the matrix means jacking in. You must be in
        // SIGNAL mode to hack — and doing so spikes TRACE hard (it's the
        // loudest play on the board). This is the upside/cost that gives the
        // SIGNAL stance its purpose.
        if !gameState.signalActive {
            gameState.addLog("⛔ Jack in first — switch to SIGNAL mode to crack the matrix.")
            gameState.postTransientWarning("SWITCH TO SIGNAL TO HACK", duration: 2.5)
            HapticsManager.shared.error()
            return
        }
        let preCrackTier = gameState.traceTier
        gameState.traceLevel += 2
        gameState.addLog("📡 TRACE +2 — jacking in lights up the host.")
        gameState.onTraceTierChanged(from: preCrackTier, to: gameState.traceTier)
        // Don't auto-acquire — launch the Matrix mini-game first.
        // HexwireApp overlays MatrixMiniGameView when showMatrixMiniGame
        // becomes true; the mini-game's completion handler calls
        // resolveMatrixMiniGame(success:) below to finalise the pickup or bail.
        gameState.pendingHackTerminalX = x
        gameState.pendingHackTerminalY = y
        gameState.pendingHackCharacterId = char.id
        gameState.addLog("📡 \(char.name) jacks into the matrix...")
        gameState.showMatrixMiniGame = true
    }

    /// Called by MatrixMiniGameView when the player either retrieves the data
    /// core (success=true) or dies/bails (success=false).
    static func resolveMatrixMiniGame(gameState: GameState, success: Bool) {
        let x = gameState.pendingHackTerminalX
        let y = gameState.pendingHackTerminalY
        let charName = gameState.pendingHackCharacterId
            .flatMap { id in gameState.playerTeam.first(where: { $0.id == id })?.name }
            ?? "Netrunner"
        gameState.showMatrixMiniGame = false
        gameState.pendingHackCharacterId = nil
        if !success {
            gameState.addLog("💥 \(charName) crashed out of the matrix — terminal still active.")
            SFXManager.shared.play("terminal_wrong", volume: 0.7)
            return
        }
        // Success — layer the rich win SFX on top of the hack_success chime.
        SFXManager.shared.play("terminal_correct", volume: 0.65)
        SFXManager.shared.play("mainframe_breach", volume: 0.6)
        // Success: replace tile with floor, mark data acquired, post visual.
        guard y >= 0, y < gameState.currentMissionTiles.count,
              x >= 0, x < gameState.currentMissionTiles[y].count else { return }
        gameState.currentMissionTiles[y][x] = TileType.floor.rawValue
        gameState.dataAcquired = true
        gameState.addLog("📡 \(charName) extracted the data — DATA ACQUIRED.")
        gameState.addLog("Now reach extraction at (\(gameState.extractionX), \(gameState.extractionY)).")
        NotificationCenter.default.post(
            name: .dataTerminalHacked,
            object: nil,
            userInfo: ["x": x, "y": y]
        )
    }

    static func showItemMenu(gameState: GameState) {
        gameState.isItemMenuVisible = true
    }

    /// True when the player may issue actions. Every perform* checks this:
    /// SwiftUI's `disabled` re-evaluates one render late, so a queued second
    /// tap can land after the round already advanced into the enemy phase —
    /// previously a free extra attack that also double-advanced the round
    /// counters (pulling delayed spawns a phase early).
    static func canAcceptPlayerAction(gameState: GameState) -> Bool {
        gameState.combatPhase == .playerInput
    }

    static func completeAction(gameState: GameState, for character: Character) {
        CombatFlowController.setCombatPhase(gameState: gameState, .playerResolving)
        // Set active to this character so turn-advance marks the right one.
        gameState.activeCharacterId = character.id
        TurnManager.requestTurnAdvance(gameState: gameState)
    }

    /// Turn-advance implementation invoked by TurnManager ownership entrypoint.
    static func endTurn(gameState: GameState) {
        // NOTE: Do NOT set isPlayerTurn=false or block input here unless we're actually
        // transitioning to the enemy phase. Doing so prematurely disables action buttons
        // for the next player character in the round.
        //
        // Phase latch: a queued tap can reach endTurn after the round already
        // advanced into the enemy phase — that double-incremented
        // roundNumber/enemyPhaseCount and pulled delayed spawns a phase early.
        guard gameState.combatPhase != .enemyResolving && gameState.combatPhase != .combatResolved else { return }
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
        gameState.playerTurnsCompleted += 1
        // Single-room stealth: end when turn window closes
        if RoomManager.shared.currentMission == nil
            && gameState.currentMissionType == .stealth
            && !gameState.missionComplete
            && gameState.currentTurnCount >= gameState.missionTargetTurns {
            gameState.finalizeCombatFromCombatFlow(
                won: true,
                missionLog: "MISSION COMPLETE — STEALTH WINDOW HELD FOR \(gameState.missionTargetTurns) TURNS"
            )
            return
        }
        // Multi-room stealth: only end on turn window if ALL rooms cleared (no partial completion)
        if gameState.currentMissionType == .stealth
            && RoomManager.shared.currentMission != nil
            && !gameState.missionComplete
            && gameState.currentTurnCount >= gameState.missionTargetTurns {
            if RoomManager.shared.areAllRoomsCleared {
                gameState.finalizeCombatFromCombatFlow(
                    won: true,
                    missionLog: "MISSION COMPLETE — STEALTH WINDOW HELD FOR \(gameState.missionTargetTurns) TURNS"
                )
            } else {
                gameState.addLog("Stealth window closed — clear remaining rooms!")
            }
            return
        }

        let living = gameState.playerTeam.filter { $0.isAlive }
        guard !living.isEmpty else {
            CombatFlowController.setCombatPhase(gameState: gameState, .playerInput)
            return
        }

        // Find next living character who hasn't acted this round.
        //
        // 2026-05-10 BUG FIX: was `playersWhoHaveNotActed.first` which is a
        // Set — non-deterministic. Now walks this round's initiative order
        // (fixed at round start), so the pick is deterministic across
        // mid-round selection changes AND initiative actually orders turns.
        let nextChar = CombatFlowController.nextPendingActor(gameState: gameState)

        if let char = nextChar, gameState.playerTurnsCompleted < 4 {
            // More players still need to act — advance to next player without blocking input.
            gameState.activeCharacterId = char.id
            gameState.selectedCharacterId = char.id
            gameState.currentTurnIndex = gameState.playerTeam.firstIndex(where: { $0.id == char.id }) ?? 0
            CombatFlowController.setCombatPhase(gameState: gameState, .playerInput)      // Stay in player phase — buttons must remain enabled
            // NOTE: defenders are deliberately NOT cleared here — DEFEND/LAY LOW
            // lasts the whole round (cleared in beginRound), not until the next
            // teammate's turn starts.
            NotificationCenter.default.post(
                name: .turnChanged,
                object: nil,
                userInfo: ["characterId": char.id.uuidString]
            )
        } else {
            // Four player turns completed, or all living players have acted —
            // ALWAYS go through the enemy-phase entrypoint. enemyPhase() has its
            // own fast path for "no enemies" that processes delayed spawns,
            // which is critical for missions like M6 where every enemy starts
            // with a non-zero delay (without this, enemyPhaseCount never
            // advances and the spawns never trigger).
            CombatFlowController.setCombatPhase(gameState: gameState, .enemyResolving)
            gameState.currentTurnIndex = 0
            gameState.enemyPhaseCount += 1
            gameState.roundNumber += 1
            gameState.addLog("═══ ROUND \(gameState.roundNumber) ═══")
            HapticsManager.shared.roundStart()
            NotificationCenter.default.post(name: .roundStarted, object: nil, userInfo: ["round": gameState.roundNumber])
            CombatFlowController.enemyPhase(gameState: gameState)
        }
    }

    /// Centralised player-death handling. Call any time a player's HP just hit 0.
    /// Posts .playerDied so BattleScene can remove the sprite, plays the killed
    /// haptic, and runs checkCombatEnd so a TPK ends the run immediately rather
    /// than waiting for the next phase boundary.
    /// Process post-kill effects that fire ONCE per room — most importantly,
    /// dropping any "removeOnFirstKill" barriers defined on the active room.
    /// Caller must have already incremented `missionEnemiesDefeated`.
    static func handleEnemyKillForRoomEffects(gameState: GameState) {
        guard !gameState.firstKillProcessedInRoom else { return }
        gameState.firstKillProcessedInRoom = true
        guard let room = RoomManager.shared.currentRoom,
              let drops = room.removeOnFirstKill,
              !drops.isEmpty else { return }
        // Mutate the live tile grid so pathfinding immediately sees the
        // dropped barriers as floor.
        var tiles = gameState.currentMissionTiles
        var droppedCoords: [[String: Int]] = []
        for p in drops {
            guard p.y >= 0, p.y < tiles.count, p.x >= 0, p.x < tiles[p.y].count else { continue }
            tiles[p.y][p.x] = TileType.floor.rawValue
            droppedCoords.append(["x": p.x, "y": p.y])
        }
        gameState.currentMissionTiles = tiles
        // Persist the drop — tiles are rebuilt from JSON on every room
        // (re)entry, and a cleared room has no kills left to re-trigger this.
        RoomManager.shared.barrierDroppedRoomIds.insert(room.id)
        gameState.addLog("⚙️ Security barriers retracted.")
        NotificationCenter.default.post(
            name: .barriersDropped,
            object: nil,
            userInfo: ["tiles": droppedCoords]
        )
    }

    static func handlePlayerKilled(gameState: GameState, char: Character) {
        guard !char.isAlive else { return }
        // Lock in the dead state. `isAlive` is `status != .dead && currentHP > 0`,
        // so HP=0 alone marks them dead — but if a future code path ever
        // restores HP (medkit-on-corpse bug, save/load round trip, etc.),
        // the corpse would silently revive. Setting status=.dead here means
        // even if HP comes back, isAlive stays false. Belt-and-suspenders.
        char.status = .dead
        HapticsManager.shared.playerKilled()
        gameState.addLog("💀 \(char.name) is DOWN!")
        // If the dead character had any active selection/turn, clear it so input
        // can't be routed to a corpse.
        if gameState.selectedCharacterId == char.id { gameState.selectedCharacterId = nil }
        if gameState.activeCharacterId == char.id { gameState.activeCharacterId = nil }
        gameState.playersWhoHaveNotActed.remove(char.id)
        NotificationCenter.default.post(
            name: .playerDied,
            object: nil,
            userInfo: ["playerId": char.id.uuidString]
        )
        CombatFlowController.checkCombatEnd(gameState: gameState)
    }

    static func checkCombatEnd(gameState: GameState) {
        // Idempotency guard: once combat has ended (victory or defeat), every
        // subsequent caller is a no-op. Without this, async enemy-phase
        // callbacks plus per-death calls can re-finalize and overwrite the
        // outcome (e.g. assault-victory then immediate TPK overwrite).
        guard !gameState.combatEnded else { return }
        // ASSAULT ENDING: only finalize if we're in a single-room mission or the LAST room of a multi-room mission.
        // Multi-room missions rely on extraction flow for victory (player reaches extraction tile after all rooms cleared).
        let isLastRoom: Bool
        if let mission = RoomManager.shared.currentMission,
           let currentRoom = RoomManager.shared.currentRoom,
           let idx = mission.rooms.firstIndex(where: { $0.id == currentRoom.id }) {
            isLastRoom = (idx == mission.rooms.count - 1)
        } else {
            isLastRoom = true // single-room mission
        }

        if gameState.currentMissionType == .assault
            && gameState.livingEnemies.isEmpty
            && gameState.pendingSpawns.isEmpty
            && isLastRoom {
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

        // ENEMY overwatch banks expire HERE, at the enemy-phase boundary —
        // NOT in beginRound alongside the player-side `overwatchers` clear.
        // beginRound runs immediately AFTER the enemy phase that banks these,
        // so clearing there would wipe every fresh bank before the player got
        // to move at all. Clearing at the top of the NEXT enemy phase gives a
        // bank exactly one full player input phase of life, and each
        // sniper/turret then re-decides (shoot vs re-bank) on its own turn.
        gameState.enemyOverwatchers.removeAll()

        let livingEnemies = gameState.enemies.filter { $0.isAlive }
        let livingPlayers = gameState.playerTeam.filter { $0.isAlive }
        // Skip enemy phase if no enemies alive — post .enemyPhaseCompleted so player input unlocks.
        guard !livingEnemies.isEmpty else {
            gameState.processDelayedSpawns(enemyPhaseIndex: gameState.enemyPhaseCount)
            if gameState.livingEnemies.isEmpty && gameState.pendingSpawns.isEmpty {
                // Room is empty AND no spawns are pending. Try to deploy a
                // reinforcement wave (one per room) before declaring it cleared.
                // If a wave is queued, pendingSpawns becomes non-empty so the
                // door stays locked until those reinforcements are also killed.
                if !ReinforcementService.tryDeployReinforcements(gameState: gameState) {
                    gameState.onRoomCleared()
                }
            }
            gameState.isEnemyPhaseRunning = false
            CombatFlowController.beginRound(gameState: gameState)
            NotificationCenter.default.post(name: .enemyPhaseCompleted, object: nil)
            return
        }

        // Only show "Enemy Turn" badge AFTER we've confirmed there are enemies to act.
        NotificationCenter.default.post(name: .enemyPhaseBegan, object: nil)

        // If no players left, combat will end via checkCombatEnd() in the notify block.
        guard !livingPlayers.isEmpty else {
            gameState.isEnemyPhaseRunning = false
            CombatFlowController.beginRound(gameState: gameState)
            NotificationCenter.default.post(name: .enemyPhaseCompleted, object: nil)
            return
        }

        let group = DispatchGroup()
        // Beat between enemy turns. Was 0.18s, which let a room full of enemies
        // act almost simultaneously — their move slides + attack VFX + hit
        // numbers all overlapped into an unreadable blur. 0.7s gives each enemy
        // a clear window: the player sees it advance, see the attack pose +
        // tracer, and see the hit land or miss before the next one acts.
        let staggerDelay: TimeInterval = 0.7

        // Enemies roll initiative too — the phase resolves fastest-first, so a
        // wired ganger reacts before a lumbering drone.
        for enemy in livingEnemies {
            enemy.initiativeRoll = DiceEngine.rollInitiative(rea: enemy.attributes.rea, int: enemy.attributes.int)
        }
        let enemyActingOrder = livingEnemies.sorted { $0.initiativeRoll > $1.initiativeRoll }

        // Attempt token: these staggered closures strongly capture this
        // mission's enemies; an abort mid-phase can't cancel the queue, and
        // without the token they would run ghost-enemy turns against the
        // NEXT mission's roster.
        let attempt = gameState.missionAttemptId

        for (i, enemy) in enemyActingOrder.enumerated() {
            let delay = Double(i) * staggerDelay

            group.enter()
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak gameState] in
                guard let gameState = gameState else { group.leave(); return }
                guard gameState.missionAttemptId == attempt, !gameState.combatEnded else {
                    group.leave()
                    return
                }
                // An enemy can die mid-phase (overwatch, burn tick) before
                // its slot comes up — a corpse takes no turn.
                if enemy.isAlive {
                    gameState.runEnemyAI(enemy: enemy, livingEnemies: livingEnemies)
                    // BOSS ACTION ECONOMY. A boss is one unit against a squad of
                    // four: the party takes four actions to its one, so it spent
                    // the fight walking and was dead before it could threaten
                    // anyone. Playtest 2026-07-25: "he moves a little, but didn't
                    // make any attacks" (M5) and "he just kinda sat there" (M3).
                    // A second activation lets a boss close AND fire in the same
                    // round, which is what makes it read as a boss rather than a
                    // slow elite. Still one unit, so the party keeps the edge.
                    if Self.isBossArchetype(enemy.archetype), enemy.isAlive,
                       !gameState.combatEnded {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                            guard gameState.missionAttemptId == attempt,
                                  !gameState.combatEnded, enemy.isAlive else { return }
                            gameState.runEnemyAI(enemy: enemy, livingEnemies: livingEnemies)
                        }
                    }
                }
                // Leave group only after the enemy's full move+attack animation
                // window has played (move ≈0.35s + attack pose/VFX ≈0.4s).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                    group.leave()
                }
            }
        }

        // When ALL enemies have finished their turns + animation windows, finalize.
        group.notify(queue: .main) { [weak gameState] in
            guard let gameState = gameState else { return }
            guard gameState.missionAttemptId == attempt else { return }
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
            dlog("[GameState] enemyPhase: all enemies done, beginRound() called, .enemyPhaseCompleted posted")

            // Safety timeout: if .enemyPhaseCompleted notification fails to unblock input
            // (rare but possible if BattleScene observer is not registered), force-unblock
            // after 3 seconds so the player is never permanently locked out.
            // Token + phase guards: with one fast-acting survivor, the NEXT
            // enemy phase can start inside 3s — this must not force-open
            // input (or fade the tint) mid-phase, nor fire across missions.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak gameState] in
                guard let gameState = gameState else { return }
                guard gameState.missionAttemptId == attempt,
                      !gameState.isEnemyPhaseRunning else { return }
                if gameState.isPlayerInputBlocked && !gameState.combatEnded {
                    dlog("[GameState] Safety timeout: force-unblocking player input")
                    CombatFlowController.setCombatPhase(gameState: gameState, .playerInput)
                    NotificationCenter.default.post(name: .enemyPhaseCompleted, object: nil)
                }
            }
        }
    }

    static func isCharacterDefending(gameState: GameState, _ charId: UUID) -> Bool {
        return gameState.defenders.contains(charId)
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
        guard canAcceptPlayerAction(gameState: gameState) else { return }
        if let selected = gameState.selectedCharacterId, let c = gameState.playerTeam.first(where: { $0.id == selected && $0.isAlive }) {
            char = c
        } else if let current = gameState.currentCharacter {
            char = current
        } else { gameState.addLog("No character to heal."); return }

        // Find a consumable item
        guard !CombatFlowController.characterHasAlreadyMoved(gameState: gameState, char) else { return }

        // Skip mana restoratives — this quick path applies HP heals only;
        // Mana Focus goes through the item picker's name-matched mana branch.
        guard let idx = gameState.loot.firstIndex(where: { $0.type == .consumable && $0.name != "Mana Focus" }) else {
            gameState.addLog("No medkits available.")
            HapticsManager.shared.buttonTap()
            return
        }
        // Don't burn a consumable that can't do anything.
        guard char.currentHP < char.maxHP || char.currentStun > 0 else {
            gameState.addLog("\(char.name) is already at full HP.")
            HapticsManager.shared.buttonTap()
            return
        }
        HapticsManager.shared.attackHit()
        let item = gameState.loot.remove(at: idx)
        gameState.consumeRosterItem(item)
        char.currentHP = min(char.maxHP, char.currentHP + item.bonus)
        // Medkits also clear some stun damage (First Aid = treat stun & physical)
        char.recoverStun(amount: item.bonus / 2)
        gameState.addLog("\(char.name) uses \(item.name)! +\(item.bonus) HP, -\(item.bonus / 2) Stun. (HP \(char.currentHP)/\(char.maxHP) | Stun \(char.currentStun)/\(char.maxStun))")
        // HPBar/values are passed by-value (Int snapshots), so changes on the
        // Character object don't propagate to the GameState's observers
        // unless we explicitly poke objectWillChange. Without this, the UI
        // shows the OLD HP until the next gameState mutation.
        gameState.objectWillChange.send()
        CombatFlowController.completeAction(gameState: gameState, for: char)
    }

    static func selectCharacter(gameState: GameState, id: UUID) {
        if let char = gameState.playerTeam.first(where: { $0.id == id && $0.isAlive }) {
            gameState.selectedCharacterId = char.id
            gameState.activeCharacterId = char.id
            gameState.targetCharacterId = nil
            gameState.addLog("Selected: \(char.name)")
            NotificationCenter.default.post(
                name: .characterSelected,
                object: nil,
                userInfo: ["characterId": char.id.uuidString]
            )
        }
    }

    /// Request path for scene/UI attack intent against a specific enemy.
    static func requestAttackOnEnemy(gameState: GameState, enemyId: UUID) {
        gameState.targetCharacterId = enemyId
        CombatFlowController.performAttack(gameState: gameState)
    }

    /// Request path for scene-driven selection updates; selection intent only.
    static func requestCharacterSelectionFromScene(gameState: GameState, id: UUID) {
        guard gameState.playerTeam.contains(where: { $0.id == id && $0.isAlive }) else { return }
        gameState.selectedCharacterId = id
        gameState.activeCharacterId = id
        gameState.targetCharacterId = nil
    }

    /// Scene callback when enemy phase has fully completed and control returns to player.
    static func restorePlayerControlAfterEnemyPhase(gameState: GameState) {
        CombatFlowController.setCombatPhase(gameState: gameState, .playerInput)

        // Initiative winner opens the round (beginRound already re-rolled the order).
        if let char = CombatFlowController.nextPendingActor(gameState: gameState) ?? gameState.findNextLivingCharacter(after: 0) {
            gameState.activeCharacterId = char.id
            gameState.selectedCharacterId = char.id
            NotificationCenter.default.post(
                name: .turnChanged,
                object: nil,
                userInfo: ["characterId": char.id.uuidString]
            )
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
           let char = gameState.playerTeam.first(where: { $0.id == selectedId && $0.isAlive }) {
            let moveDistance = gameState.hexDistance(x1: tileX, y1: tileY, x2: char.positionX, y2: char.positionY)
            if moveDistance >= 1 && moveDistance <= 2 {
                CombatFlowController.moveCharacter(gameState: gameState, id: char.id, toTileX: tileX, toTileY: tileY)
            }
            // Silent no-op when tap is too far — see BattleScene.handleTileTap
            // for full reasoning. Avoids the misleading "out of range" message
            // firing during ranged attack workflows.
            return
        }

        gameState.addLog("Empty tile: (\(tileX),\(tileY))")
    }

    /// Extraction is a request path; CombatFlowController owns extraction outcome adjudication.
    static func requestExtraction(
        gameState: GameState,
        characterId: UUID?,
        tileX: Int,
        tileY: Int
    ) -> Bool {
        guard !gameState.combatEnded else { return false }
        CombatFlowController.setCombatPhase(gameState: gameState, .extractRequested)

        guard tileX == gameState.extractionX && tileY == gameState.extractionY else {
            CombatFlowController.setCombatPhase(gameState: gameState, .playerInput)
            gameState.addLog("That is not the extraction point.")
            return false
        }

        if RoomManager.shared.currentMission != nil {
            guard RoomManager.shared.isExtractionActive() else {
                CombatFlowController.setCombatPhase(gameState: gameState, .playerInput)
                gameState.addLog("Extraction is locked until every room is clear.")
                return false
            }
        }

        guard let id = characterId,
              let char = gameState.playerTeam.first(where: { $0.id == id && $0.isAlive }) else {
            CombatFlowController.setCombatPhase(gameState: gameState, .playerInput)
            gameState.addLog("Select a character, then step onto extraction.")
            return false
        }

        // Keep model-space position aligned with tile tap before adjudication.
        char.positionX = tileX
        char.positionY = tileY

        let hasActiveThreats = !(gameState.livingEnemies.isEmpty && gameState.pendingSpawns.isEmpty)

        if hasActiveThreats {
            CombatFlowController.setCombatPhase(gameState: gameState, .playerInput)
            gameState.addLog("Clear all enemies before extraction!")
            return false
        }

        if gameState.missionRequiresData && !gameState.dataAcquired {
            CombatFlowController.setCombatPhase(gameState: gameState, .playerInput)
            gameState.addLog("Hack the data terminal first — extraction is locked.")
            return false
        }

        adjudicateExtractionIfEligible(gameState: gameState)
        return true
    }

    /// Boss-class archetypes. These get a second activation per enemy phase —
    /// see the action-economy note in the enemy-phase loop.
    static func isBossArchetype(_ archetype: String) -> Bool {
        archetype.lowercased().hasPrefix("boss")
    }

    /// Owner path for extraction mission completion resolution.
    static func adjudicateExtractionIfEligible(gameState: GameState) {
        let isMultiRoomMission = RoomManager.shared.currentMission != nil
        guard isMultiRoomMission || gameState.currentMissionType == .extraction else { return }
        // Both branches require pendingSpawns empty — multi-room previously
        // skipped it, letting the player extract while authored delayed
        // enemies were still due (contradicting the door re-lock design).
        guard gameState.livingEnemies.isEmpty && gameState.pendingSpawns.isEmpty else { return }
        if RoomManager.shared.currentMission != nil {
            guard RoomManager.shared.isExtractionActive() else { return }
        }
        guard !gameState.missionRequiresData || gameState.dataAcquired else { return }

        let onExtraction = gameState.livingPlayers.contains {
            $0.positionX == gameState.extractionX && $0.positionY == gameState.extractionY
        }

        if onExtraction {
            // Idempotency: bail if extraction is already animating. Prevents
            // double-tap stacking two helicopters / two finalize calls.
            guard !gameState.extractionAnimationInProgress else { return }
            gameState.extractionAnimationInProgress = true
            CombatFlowController.setCombatOutcome(gameState: gameState, .extracted)
            // Defer the actual finalize until the extraction animation finishes.
            gameState.addLog("🚁 EXTRACTION SUCCESS — Runners are out!")
            NotificationCenter.default.post(
                name: .extractionAnimationRequested,
                object: nil,
                userInfo: ["x": gameState.extractionX, "y": gameState.extractionY]
            )
            // Safety net: finalize after 14s if the animation observer
            // doesn't run for any reason. 2026-05-10: bumped 11s → 14s after
            // waitOnPad raised to 2.2s (full animation now ~9.8s); the old
            // 11s margin was too tight and would surface the debrief while
            // the chopper was still ascending.
            // Attempt token: without it, this timer survived an abort and
            // its !combatEnded guard passed against the NEXT mission —
            // instant auto-win with a real persisted payout.
            let attempt = gameState.missionAttemptId
            DispatchQueue.main.asyncAfter(deadline: .now() + 14.0) { [weak gameState] in
                guard let gs = gameState, gs.missionAttemptId == attempt, !gs.combatEnded else { return }
                CombatFlowController.finalizeExtractionAfterAnimation(gameState: gs)
            }
        }
    }

    /// Called by BattleScene when the helicopter extraction animation finishes
    /// (or by the safety timer in adjudicateExtractionIfEligible).
    /// Idempotent — safe to call multiple times.
    static func finalizeExtractionAfterAnimation(gameState: GameState) {
        guard !gameState.combatEnded else { return }
        // Clear the in-flight flag BEFORE finalize. Otherwise syncLegacyState
        // (which we made aware of extractionInFlight) refuses to latch
        // combatEnded/missionComplete on terminal outcomes — and the
        // debrief overlay never shows.
        gameState.extractionAnimationInProgress = false
        gameState.finalizeCombatFromCombatFlow(
            won: true,
            missionLog: "🚁 EXTRACTION SUCCESS — Runners are out!",
            terminalLog: "=== VICTORY ==="
        )
    }

    /// Combined finalize — resets animation state, posts completion
    /// notification, and ends combat. Safe to call multiple times
    /// (finalizeExtractionAfterAnimation is idempotent via combatEnded guard).
    /// Used by the helicopter animation's onComplete and 10s safety net so
    /// the mission reliably returns to the menu after extraction.
    @MainActor
    static func completeExtractionFinalize() {
        let gameState = GameState.shared
        gameState.extractionAnimationInProgress = false
        NotificationCenter.default.post(name: .extractionAnimationCompleted, object: nil)
        finalizeExtractionAfterAnimation(gameState: gameState)
    }
}

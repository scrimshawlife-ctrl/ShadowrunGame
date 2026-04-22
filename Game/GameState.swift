import Foundation

// MARK: - Spell Type
// (Consolidated here from Entities/Spell.swift on 2026-04-19 to work around
//  the same Xcode cross-file type resolution issue that affected MultiRoomMission.)

enum SpellType: String, CaseIterable, Codable {

    case fireball   // AoE Physical — scorches all living enemies
    case manaBolt   // Single-target Physical — raw mana lance
    case shock      // Single-target Stun — lightning jolt
    case heal       // Self-heal — mend flesh and stun

    // MARK: Display

    var displayName: String {
        switch self {
        case .fireball: return "Fireball"
        case .manaBolt: return "Mana Bolt"
        case .shock:    return "Shock"
        case .heal:     return "Heal"
        }
    }

    var icon: String {
        switch self {
        case .fireball: return "flame.fill"
        case .manaBolt: return "bolt.fill"
        case .shock:    return "bolt.circle.fill"
        case .heal:     return "cross.fill"
        }
    }

    var colorHex: String {
        switch self {
        case .fireball: return "FF4422"
        case .manaBolt: return "6699FF"
        case .shock:    return "FFEE00"
        case .heal:     return "44CC88"
        }
    }

    var manaCost: Int {
        switch self {
        case .fireball: return 4
        case .manaBolt: return 3
        case .shock:    return 2
        case .heal:     return 2
        }
    }

    var baseDamage: Int {
        switch self {
        case .fireball: return 5   // AoE, so lower per-target
        case .manaBolt: return 8   // Strong single-target
        case .shock:    return 6   // Stun track
        case .heal:     return 0
        }
    }

    var description: String {
        switch self {
        case .fireball: return "Blast ALL enemies. \(baseDamage)+hits Physical each."
        case .manaBolt: return "Focus single target. \(baseDamage)+hits Physical."
        case .shock:    return "Stun single target. \(baseDamage)+hits Stun."
        case .heal:     return "Restore HP & stun to self."
        }
    }

    var isAreaOfEffect: Bool { self == .fireball }
    var isStunDamage: Bool   { self == .shock }
    var isHeal: Bool         { self == .heal }
    var needsEnemyTarget: Bool { self == .manaBolt || self == .shock }
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

    private init() {}

    private enum TraceCadence {
        static let gainPerSignal = 1
        static let recoveryPerLayLow = 1
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

    // MARK: - Inventory / Loot

    /// Unequipped items available to the team
    @Published var loot: [Item] = []

    struct Item: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let type: ItemType
        let bonus: Int  // HP heal or armor value

        enum ItemType: String {
            case consumable  // medkit
            case weapon
            case armor
        }
    }

    private let lootTable: [(type: Item.ItemType, chance: Double, name: String, bonus: Int)] = [
        (.consumable, 0.6, "Medkit", 10),
        (.consumable, 0.3, "Stimpatch", 5),
        (.weapon, 0.2, "Combat Knife +1", 1),
        (.weapon, 0.1, "Heavy Pistol", 2),
        (.armor, 0.15, "Armored Vest", 2),
        (.armor, 0.1, "Shield", 3),
    ]

    func generateLoot() {
        let drop = lootTable.randomElement()!
        loot.append(Item(name: drop.name, type: drop.type, bonus: drop.bonus))
        addLog("Loot: \(drop.name)!")
    }

    // MARK: - Turn

    @Published var currentTurnIndex: Int = 0
    @Published var roundNumber: Int = 1
    var enemyPhaseCount: Int = 0  // how many enemy phases have completed (for delayed spawns)
    @Published var isPlayerTurn: Bool = true
    /// When true, blocks player input in BattleScene while enemy phase is running.
    @Published var isPlayerInputBlocked: Bool = false
    /// Guards against double-triggering enemyPhase() within the same frame/turn.
    var isEnemyPhaseRunning: Bool = false
    @Published var actionMode: ActionMode = .street
    @Published var playerRole: PlayerRole = .normal
    @Published var selectedMissionPreset: MissionPreset = .standard
    @Published var traceLevel: Int = 0
    var traceThreshold: Int { TraceCadence.threshold(for: selectedMissionPreset) }
    var traceGainPerSignal: Int { TraceCadence.gainPerSignal }
    var traceRecoveryPerLayLow: Int { TraceCadence.recoveryPerLayLow }
    var escalationDamageBonus: Int { TraceCadence.escalationDamageBonus(for: selectedMissionPreset) }
    @Published var traceEscalationLevel: Int = 0
    var hasLoggedTraceTriggerForCurrentRun: Bool = false

    // MARK: - Turn Structure (Issue 1 fix)
    // Track which players have NOT yet acted this round. Empty = all acted = enemy phase.
    private var playersWhoHaveNotActed: Set<UUID> = []

    /// Reset turn-tracking state at the start of each round.
    private func resetTurnTracking() {
        // Stunned characters auto-skip their turn (they can't act while fully stunned)
        // They still count as "acted" so the round advances without them.
        playersWhoHaveNotActed = Set(
            playerTeam.filter { $0.isAlive && $0.status != .stunned }.map { $0.id }
        )
        // Reset per-character action flags at start of new round
        for char in playerTeam {
            char.hasActedThisRound = false
            // Log stunned characters being skipped
            if char.isAlive && char.status == .stunned {
                addLog("💤 \(char.name) is STUNNED — skipping turn. (Stun \(char.currentStun)/\(char.maxStun))")
                char.hasActedThisRound = true
            }
        }
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
        let newTier = traceTier
        traceEscalationLevel = newTier
        if newTier != previousTier {
            addLog("⚠️ TRACE \(traceTierLabel) — enemy damage +\(escalationDamageBonusForCurrentTrace)")
        }
    }

    private func escalatedIncomingDamage(_ baseDamage: Int) -> Int {
        guard baseDamage > 0 else { return baseDamage }
        let dynamicBonus = escalationDamageBonusForCurrentTrace
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
        if traceLevel < previous {
            addLog("TRACE -\(previous - traceLevel) (Lay Low)")
        } else {
            addLog("TRACE -0 (Lay Low)")
        }
        let newTier = traceTier
        traceEscalationLevel = newTier
        if newTier != previousTier {
            addLog("TRACE \(traceTierLabel) — enemy damage +\(escalationDamageBonusForCurrentTrace)")
        }
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
        resetTurnTracking()
        isDefending = false
        defendingCharacterId = nil
        // Natural stun recovery: each character rolls BOD+WIL to reduce stun (SR5 recovery rules)
        recoverStunAtRoundStart()
        // Mana regen: mages and deckers recover 1 resource point per round passively
        for char in playerTeam where char.isAlive {
            if char.archetype == .mage || char.archetype == .decker {
                let prev = char.currentMana
                char.currentMana = min(char.maxMana, char.currentMana + 1)
                if char.currentMana > prev {
                    addLog("✨ \(char.name) recovers 1 mana. (\(char.currentMana)/\(char.maxMana))")
                }
            }
        }
    }

    /// SR5 stun recovery: at the start of each round, each living character rolls BOD+WIL.
    /// Each hit reduces stun by 1 (simplified from real SR5 rest-based recovery).
    private func recoverStunAtRoundStart() {
        for char in playerTeam where char.isAlive && char.currentStun > 0 {
            let recoveryPool = char.attributes.bod + char.attributes.wil
            let roll = DiceEngine.roll(pool: recoveryPool)
            if roll.hits > 0 {
                char.recoverStun(amount: roll.hits)
            }
        }
        for enemy in enemies where enemy.isAlive && enemy.currentStun > 0 {
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

    // MARK: - Current Mission Tiles (for enemy pathfinding)

    var currentMissionTiles: [[Int]] = []

    // MARK: - Pending Enemy Spawns

    /// Enemies not yet on the map (waiting for their delay timer)
    var pendingSpawns: [PendingSpawn] = []

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
    @Published var combatWon: Bool?
    @Published var combatEnded: Bool = false
    @Published var currentMissionType: MissionType = .stealth
    @Published var currentMapSituation: MapSituation = .corridor
    @Published var missionComplete: Bool = false
    @Published var missionHeat: Int = 0
    @Published var missionHeatTier: HeatTier = .low
    @Published var factionAttention: [Faction: Int] = [
        .corp: 0,
        .gang: 0,
        .unknown: 0
    ]
    @Published var lastAppliedCorpEnemyModifier: Int = 0
    @Published var lastAppliedGangAmbushRadius: Int = 999
    @Published var didApplyAttentionRecoveryLastMission: Bool = false
    @Published var didApplyHighTraceEscalationBonusLastMission: Bool = false
    @Published var lastRewardTier: RewardTier = .low
    @Published var lastRewardMultiplier: Double = 1.0
    @Published var missionTypeBonusMultiplier: Double = 0.0
    @Published var baseMissionPayout: Int = 100
    @Published var missionTargetTurns: Int = 6
    @Published var currentTurnCount: Int = 0
    var missionLoadIndex: Int = 0
    var activeCharacter: Character? {
        guard let id = activeCharacterId else { return currentCharacter }
        return playerTeam.first(where: { $0.id == id && $0.isAlive })
    }

    // MARK: - Actions

    @Published var isDefending: Bool = false
    @Published var isItemMenuVisible: Bool = false

    /// Which character is currently defending (for turn-scoped defense bonus)
    var defendingCharacterId: UUID?

    // MARK: - Computed

    var currentCharacter: Character? {
        guard isPlayerTurn, !playerTeam.isEmpty else { return nil }
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

        return """
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
        guard let attacker = activeCharacter ?? currentCharacter,
              let targetId  = targetCharacterId,
              let target    = enemies.first(where: { $0.id == targetId && $0.isAlive }) else { return nil }
        return CombatMechanics.computeHitPreview(
            attacker:  attacker,
            target:    target,
            tiles:     currentMissionTiles,
            isBlocked: { sx, sy, tx, ty in
                self.isLineBlockedByWall(fromX: sx, fromY: sy, toX: tx, toY: ty)
            }
        )
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
        let attacker: Character?
        if let selected = selectedCharacterId, let char = playerTeam.first(where: { $0.id == selected && $0.isAlive }) {
            attacker = char
        } else {
            attacker = currentCharacter
        }
        guard let a = attacker else { addLog("No character available."); return }
        guard let targetId = targetCharacterId else { addLog("No target selected — tap an enemy first."); return }
        guard let targetEnemy = enemies.first(where: { $0.id == targetId }) else {
            addLog("Invalid target."); return
        }

        if isLineBlockedByWall(
            fromX: a.positionX, fromY: a.positionY,
            toX: targetEnemy.positionX, toY: targetEnemy.positionY
        ) {
            addLog("⛔ Line of sight blocked by wall!")
            HapticsManager.shared.buttonTap()
            return
        }

        let weapon = a.equippedWeapon ?? Weapon(name: "Fists", type: .unarmed, damage: 3, accuracy: 3, armorPiercing: 0)

        // Determine attack skill from weapon type
        let skill: SkillKey = (weapon.type == .blade || weapon.type == .unarmed) ? .blades : .firearms

        // Attack pool: AGI + skill
        let attackPool = a.attackPool(skill: skill)

        switch actionMode {
        case .street: applyStreetAction()
        case .signal: applySignalAction()
        }

        // Cover bonus: count cover tiles between attacker and target
        let coverCount = CombatMechanics.coverBetween(
            tiles: currentMissionTiles,
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
            addLog("💥 CRITICAL GLITCH! \(a.name) fumbles — \(selfDmg) self-damage!")
            HapticsManager.shared.playerDamaged()
            NotificationCenter.default.post(name: .characterHit, object: nil, userInfo: ["characterId": a.id.uuidString, "damage": selfDmg])
            completeAction(for: a)
            return
        }

        if attackRoll.glitch {
            addLog("⚠️ GLITCH! \(a.name)'s \(weapon.name) misfires!")
            completeAction(for: a)
            return
        }

        // Defense roll
        let defenseRoll = DiceEngine.roll(pool: defensePool)
        let netHits = max(0, attackRoll.hits - defenseRoll.hits)

        addLog("⚔️ \(a.name) attacks with \(weapon.name)! [\(attackPool)d6→\(attackRoll.hits)] vs [\(defensePool)d6→\(defenseRoll.hits)\(coverBonus > 0 ? " +\(coverBonus)cov" : "")]")

        if netHits == 0 {
            addLog("  → MISS! \(targetEnemy.name) dodges!")
            NotificationCenter.default.post(name: .enemyHit, object: nil, userInfo: ["enemyId": targetId.uuidString, "damage": 0])
            completeAction(for: a)
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
            addLog("  → \(netHits) net hits! \(baseDamage)\(dmgType) - \(soakRoll.hits) soak = \(finalDamage) dmg! (\(targetEnemy.currentHP)/\(targetEnemy.maxHP) HP | Stun \(targetEnemy.currentStun)/\(targetEnemy.maxStun))")
        } else {
            addLog("  → Hit but \(targetEnemy.name) soaks ALL damage!")
        }

        NotificationCenter.default.post(name: .enemyHit, object: nil, userInfo: ["enemyId": targetId.uuidString, "damage": finalDamage])

        if !targetEnemy.isAlive {
            HapticsManager.shared.enemyKilled()
            addLog("☠️ \(targetEnemy.name) DOWN! +\(targetEnemy.maxHP / 2) XP")
            generateLoot()
            if let char = playerTeam.first(where: { $0.id == a.id }) {
                let leveledUp = char.gainXP(targetEnemy.maxHP / 2)
                if leveledUp {
                    HapticsManager.shared.levelUp()
                    addLog("🎖️ LEVEL UP! \(char.name) → Level \(char.level)!")
                    NotificationCenter.default.post(name: .characterLevelUp, object: nil, userInfo: ["characterId": char.id.uuidString])
                }
            }
            NotificationCenter.default.post(name: .enemyDied, object: nil, userInfo: ["enemyId": targetId.uuidString])
            if livingEnemies.isEmpty { onRoomCleared() }
        }

        completeAction(for: a)
    }

    func performLayLow() {
        let actor: Character?
        if let selected = selectedCharacterId, let char = playerTeam.first(where: { $0.id == selected && $0.isAlive }) {
            actor = char
        } else {
            actor = currentCharacter
        }
        guard let character = actor else {
            addLog("No character available.")
            return
        }
        applyTraceRecovery()
        completeAction(for: character) // Cost: consumes full turn
    }

    // MARK: - Spell Casting

    /// Entry point called from SpellPickerSheet. Validates mage & mana, then dispatches.
    func performSpell(type: SpellType, targetId: UUID? = nil) {
        // Resolve caster
        let char: Character?
        if let selected = selectedCharacterId, let c = playerTeam.first(where: { $0.id == selected && $0.isAlive }) {
            char = c
        } else {
            char = currentCharacter
        }
        guard let mage = char, mage.archetype == CharacterArchetype.mage else {
            addLog("Only mages can cast spells.")
            return
        }
        guard mage.currentMana >= type.manaCost else {
            addLog("Not enough mana for \(type.displayName)! Need \(type.manaCost), have \(mage.currentMana).")
            HapticsManager.shared.buttonTap()
            return
        }

        // Dispatch by spell type
        switch type {
        case .fireball:
            castFireball(by: mage)
        case .manaBolt:
            castSingleTarget(type: type, targetId: targetId ?? targetCharacterId, by: mage)
        case .shock:
            castSingleTarget(type: type, targetId: targetId ?? targetCharacterId, by: mage)
        case .heal:
            castHeal(by: mage)
        }
    }

    // MARK: Fireball — AoE Physical

    private func castFireball(by mage: Character) {
        let targets = livingEnemies
        guard !targets.isEmpty else { addLog("No targets."); return }

        let spellPool = mage.attributes.log + mage.skills.spellcasting
        let spellRoll = DiceEngine.roll(pool: spellPool)
        mage.currentMana -= SpellType.fireball.manaCost
        HapticsManager.shared.attackHit()

        // Glitch handling
        if spellRoll.criticalGlitch {
            let drain = mage.attributes.wil * 2
            mage.takeDamage(amount: drain)
            addLog("💥 CRIT GLITCH! FIREBALL backfires! \(mage.name) takes \(drain) drain!")
            HapticsManager.shared.playerDamaged()
            NotificationCenter.default.post(name: .characterHit, object: nil, userInfo: ["characterId": mage.id.uuidString, "damage": drain])
            completeAction(for: mage)
            return
        }
        if spellRoll.glitch || spellRoll.hits == 0 {
            let drain = mage.attributes.wil
            mage.takeDamage(amount: drain)
            addLog("⚠️ GLITCH! FIREBALL fizzles. \(mage.name) takes \(drain) drain!")
            completeAction(for: mage)
            return
        }

        addLog("🔥 \(mage.name) FIREBALL! [\(spellPool)d6→\(spellRoll.hits) hits] hits ALL \(targets.count) enemies!")
        for target in targets {
            let baseDamage = SpellType.fireball.baseDamage + spellRoll.hits
            let soakPool = target.attributes.wil + (target.equippedArmor?.armorValue ?? 0) / 2
            let soakRoll = DiceEngine.roll(pool: max(0, soakPool))
            let finalDamage = max(1, baseDamage - soakRoll.hits)
            target.takeDamage(amount: finalDamage, isStun: false)
            addLog("  → \(target.name): \(baseDamage)P - \(soakRoll.hits)soak = \(finalDamage) dmg (\(target.currentHP)/\(target.maxHP) HP)")
            NotificationCenter.default.post(name: .enemyHit, object: nil, userInfo: ["enemyId": target.id.uuidString, "damage": finalDamage])
            if !target.isAlive { handleEnemyKilled(target, by: mage) }
        }
        addLog("  Mana: \(mage.currentMana)/\(mage.maxMana)")
        if livingEnemies.isEmpty { onRoomCleared() }
        completeAction(for: mage)
    }

    // MARK: Mana Bolt & Shock — Single-target

    private func castSingleTarget(type: SpellType, targetId: UUID?, by mage: Character) {
        // Resolve target: use provided id or nearest enemy
        let target: Enemy
        if let tid = targetId, let e = enemies.first(where: { $0.id == tid && $0.isAlive }) {
            target = e
        } else if let nearest = livingEnemies.first {
            target = nearest
            targetCharacterId = nearest.id
        } else {
            addLog("No targets in range."); return
        }

        let spellPool = mage.attributes.log + mage.skills.spellcasting
        let spellRoll = DiceEngine.roll(pool: spellPool)
        mage.currentMana -= type.manaCost
        HapticsManager.shared.attackHit()

        // Glitch handling
        if spellRoll.criticalGlitch {
            let drain = mage.attributes.wil * 2
            mage.takeDamage(amount: drain)
            addLog("💥 CRIT GLITCH! \(type.displayName) backfires! \(mage.name) takes \(drain) drain!")
            HapticsManager.shared.playerDamaged()
            NotificationCenter.default.post(name: .characterHit, object: nil, userInfo: ["characterId": mage.id.uuidString, "damage": drain])
            completeAction(for: mage)
            return
        }
        if spellRoll.glitch || spellRoll.hits == 0 {
            let drain = mage.attributes.wil
            mage.takeDamage(amount: drain)
            addLog("⚠️ GLITCH! \(type.displayName) fizzles. \(mage.name) takes \(drain) drain!")
            completeAction(for: mage)
            return
        }

        let baseDamage = type.baseDamage + spellRoll.hits
        let isStun = type.isStunDamage
        let soakPool = isStun
            ? max(0, target.attributes.wil)
            : max(0, target.attributes.wil + (target.equippedArmor?.armorValue ?? 0) / 2)
        let soakRoll = DiceEngine.roll(pool: soakPool)
        let finalDamage = max(1, baseDamage - soakRoll.hits)
        let dmgType = isStun ? "S" : "P"

        target.takeDamage(amount: finalDamage, isStun: isStun)
        let icon = type == .shock ? "⚡" : "✨"
        addLog("\(icon) \(mage.name) \(type.displayName.uppercased())! [\(spellPool)d6→\(spellRoll.hits) hits] \(baseDamage)\(dmgType) - \(soakRoll.hits)soak = \(finalDamage) dmg. (\(target.currentHP)/\(target.maxHP) HP | Stun \(target.currentStun)/\(target.maxStun))")
        addLog("  Mana: \(mage.currentMana)/\(mage.maxMana)")

        NotificationCenter.default.post(name: .enemyHit, object: nil, userInfo: ["enemyId": target.id.uuidString, "damage": finalDamage])
        if !target.isAlive {
            handleEnemyKilled(target, by: mage)
            if livingEnemies.isEmpty { onRoomCleared() }
        }
        completeAction(for: mage)
    }

    // MARK: Heal

    private func castHeal(by mage: Character) {
        let spellPool = mage.attributes.log + mage.skills.spellcasting
        let spellRoll = DiceEngine.roll(pool: spellPool)
        mage.currentMana -= SpellType.heal.manaCost
        HapticsManager.shared.attackHit()

        if spellRoll.criticalGlitch {
            let drain = mage.attributes.wil * 2
            mage.takeDamage(amount: drain)
            addLog("💥 CRIT GLITCH! HEAL backfires! \(mage.name) takes \(drain) drain!")
            HapticsManager.shared.playerDamaged()
            NotificationCenter.default.post(name: .characterHit, object: nil, userInfo: ["characterId": mage.id.uuidString, "damage": drain])
            completeAction(for: mage)
            return
        }

        let healHP  = max(1, 2 + spellRoll.hits)
        let healStun = max(1, 1 + spellRoll.hits / 2)
        let prevHP = mage.currentHP
        mage.currentHP = min(mage.maxHP, mage.currentHP + healHP)
        mage.recoverStun(amount: healStun)
        let actualHP   = mage.currentHP - prevHP
        addLog("💚 \(mage.name) HEAL! [\(spellPool)d6→\(spellRoll.hits) hits] +\(actualHP) HP, -\(healStun) Stun. (\(mage.currentHP)/\(mage.maxHP) HP | Stun \(mage.currentStun)/\(mage.maxStun))")
        addLog("  Mana: \(mage.currentMana)/\(mage.maxMana)")
        NotificationCenter.default.post(name: .characterHit, object: nil, userInfo: ["characterId": mage.id.uuidString, "damage": -actualHP])
        completeAction(for: mage)
    }

    // MARK: Shared helper — award XP / loot when enemy killed by spell

    private func handleEnemyKilled(_ enemy: Enemy, by mage: Character) {
        HapticsManager.shared.enemyKilled()
        addLog("☠️ \(enemy.name) DOWN! +\(enemy.maxHP / 2) XP")
        generateLoot()
        let leveledUp = mage.gainXP(enemy.maxHP / 2)
        if leveledUp {
            HapticsManager.shared.levelUp()
            addLog("🎖️ LEVEL UP! \(mage.name) → Level \(mage.level)!")
            NotificationCenter.default.post(name: .characterLevelUp, object: nil, userInfo: ["characterId": mage.id.uuidString])
        }
        NotificationCenter.default.post(name: .enemyDied, object: nil, userInfo: ["enemyId": enemy.id.uuidString])
    }

    func performDefend() {
        let char: Character
        if let selected = selectedCharacterId, let c = playerTeam.first(where: { $0.id == selected && $0.isAlive }) {
            char = c
        } else if let current = currentCharacter {
            char = current
        } else { return }
        HapticsManager.shared.buttonTap()
        isDefending = true
        defendingCharacterId = char.id
        addLog("\(char.name) takes a defensive stance. (+2 DEF)")
        NotificationCenter.default.post(
            name: .characterDefend,
            object: nil,
            userInfo: ["characterId": char.id.uuidString]
        )
        completeAction(for: char)
    }

    /// Decker HACK: Disables target enemy for 1 round (0 attack dice, can't move).
    /// Uses LOG + spellcasting (hacking is logic-based in Shadowrun).
    func performHack() {
        let char: Character?
        if let selected = selectedCharacterId, let c = playerTeam.first(where: { $0.id == selected && $0.isAlive }) {
            char = c
        } else {
            char = currentCharacter
        }
        guard let decker = char, decker.archetype == CharacterArchetype.decker else {
            addLog("Only Deckers can hack.")
            return
        }
        guard decker.currentMana >= 2 else {
            addLog("Not enough matrix energy! Need 2, have \(decker.currentMana).")
            HapticsManager.shared.buttonTap()
            return
        }
        guard let targetId = targetCharacterId,
              let target = enemies.first(where: { $0.id == targetId && $0.isAlive }) else {
            guard let nearest = livingEnemies.first else {
                addLog("No targets in range."); return
            }
            targetCharacterId = nearest.id
            performHackOnTarget(nearest, by: decker)
            return
        }
        performHackOnTarget(target, by: decker)
    }

    private func performHackOnTarget(_ target: Enemy, by decker: Character) {
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
            completeAction(for: decker)
            return
        }
        if hackRoll.glitch || hackRoll.hits == 0 {
            addLog("⚠️ GLITCH! \(decker.name)'s intrusion fails — ICE detected!")
            completeAction(for: decker)
            return
        }

        // Disable enemy: mark as stunned (use status effect)
        target.status = .stunned
        addLog("💻 \(decker.name) HACKS \(target.name)! [\(hackPool)d6→\(hackRoll.hits)] — SYSTEM DISABLED for 1 round!")
        NotificationCenter.default.post(name: .enemyHit, object: nil, userInfo: ["enemyId": target.id.uuidString, "damage": 0])
        completeAction(for: decker)
    }

    /// Face INTIMIDATE: Reduce all living enemies' effective attack this round.
    /// Uses CHA + skills. All enemies get -2 dice to their next attack.
    func performIntimidate() {
        let char: Character?
        if let selected = selectedCharacterId, let c = playerTeam.first(where: { $0.id == selected && $0.isAlive }) {
            char = c
        } else {
            char = currentCharacter
        }
        guard let face = char, face.archetype == CharacterArchetype.face else {
            addLog("Only the Face can intimidate.")
            return
        }
        // Social pool: CHA + (LOG / 2)
        let socialPool = face.attributes.cha + face.attributes.log / 2
        let socialRoll = DiceEngine.roll(pool: socialPool)
        HapticsManager.shared.attackHit()

        if socialRoll.hits == 0 {
            addLog("🎭 \(face.name) tries to intimidate but the guards laugh it off.")
            completeAction(for: face)
            return
        }

        // Apply intimidation to all living enemies: reduce their attack pool by hits (min 1)
        for enemy in livingEnemies {
            let penalty = min(socialRoll.hits, enemy.attributes.agi - 1)
            enemy.attributes.agi = max(1, enemy.attributes.agi - penalty)
        }
        addLog("🎭 \(face.name) INTIMIDATES! [\(socialPool)d6→\(socialRoll.hits)] — Enemies rattled! (-\(socialRoll.hits) ATK this round)")
        completeAction(for: face)
    }

    /// Street Sam BLITZ: High-damage melee charge attack. Uses BOD+STR.
    /// More powerful than normal attack but costs extra (BOD damage risk).
    func performBlitz() {
        let char: Character?
        if let selected = selectedCharacterId, let c = playerTeam.first(where: { $0.id == selected && $0.isAlive }) {
            char = c
        } else {
            char = currentCharacter
        }
        guard let sam = char, sam.archetype == CharacterArchetype.streetSam else {
            addLog("Only the Street Samurai can Blitz.")
            return
        }
        guard let targetId = targetCharacterId,
              let target = enemies.first(where: { $0.id == targetId && $0.isAlive }) else {
            guard let nearest = livingEnemies.first else {
                addLog("No targets in range."); return
            }
            targetCharacterId = nearest.id
            performBlitzOnTarget(nearest, by: sam)
            return
        }
        performBlitzOnTarget(target, by: sam)
    }

    private func performBlitzOnTarget(_ target: Enemy, by sam: Character) {
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
            completeAction(for: sam)
            return
        }

        let defensePool = max(1, target.attributes.rea)
        let defenseRoll = DiceEngine.roll(pool: defensePool)
        let netHits = max(0, attackRoll.hits - defenseRoll.hits)

        // Blitz deals high physical damage: base 8 + net hits
        let baseDmg = 8 + netHits
        let soakPool = max(0, target.computeDerived().soak - 2)  // -2 AP for charge force
        let soakRoll = DiceEngine.roll(pool: soakPool)
        let finalDmg = max(1, baseDmg - soakRoll.hits)

        target.takeDamage(amount: finalDmg, isStun: false)
        addLog("⚡ \(sam.name) BLITZ! [\(blitzPool)d6→\(attackRoll.hits)] \(baseDmg)P - \(soakRoll.hits)soak = \(finalDmg) dmg! (\(target.currentHP)/\(target.maxHP) | Stun \(target.currentStun)/\(target.maxStun))")
        NotificationCenter.default.post(name: .enemyHit, object: nil, userInfo: ["enemyId": target.id.uuidString, "damage": finalDmg])

        if !target.isAlive {
            HapticsManager.shared.enemyKilled()
            addLog("☠️ \(target.name) DOWN! +\(target.maxHP / 2) XP")
            generateLoot()
            let leveledUp = sam.gainXP(target.maxHP / 2)
            if leveledUp {
                HapticsManager.shared.levelUp()
                addLog("🎖️ LEVEL UP! \(sam.name) → Level \(sam.level)!")
                NotificationCenter.default.post(name: .characterLevelUp, object: nil, userInfo: ["characterId": sam.id.uuidString])
            }
            NotificationCenter.default.post(name: .enemyDied, object: nil, userInfo: ["enemyId": target.id.uuidString])
            if livingEnemies.isEmpty { onRoomCleared() }
        }

        completeAction(for: sam)
    }

    /// Move a character to a new tile position (called from BattleScene on player tap).
    /// Movement is a FREE action — does NOT consume the turn.
    /// The player can still act (attack, defend, spell, item) after moving.
    func moveCharacter(id: UUID, toTileX tileX: Int, toTileY tileY: Int) {
        guard let char = playerTeam.first(where: { $0.id == id && $0.isAlive }) else { return }
        char.positionX = tileX
        char.positionY = tileY
        addLog("\(char.name) moves to (\(tileX),\(tileY))")
        NotificationCenter.default.post(
            name: .tileTapped,
            object: nil,
            userInfo: ["tileX": tileX, "tileY": tileY, "characterId": id.uuidString]
        )
        // Movement is a FREE action — does NOT consume the turn.
        // Do NOT set hasActedThisRound or call endTurn() here.
    }

    func showItemMenu() {
        isItemMenuVisible = true
    }

    func completeAction(for character: Character) {
        // Set active to this character so endTurn() marks the right one
        activeCharacterId = character.id
        endTurn()
    }

    func endTurn() {
        // NOTE: Do NOT set isPlayerTurn=false or block input here unless we're actually
        // transitioning to the enemy phase. Doing so prematurely disables action buttons
        // for the next player character in the round.
        isItemMenuVisible = false
        targetCharacterId = nil

        // Mark current active character as having acted this round.
        // ALWAYS remove from playersWhoHaveNotActed regardless of hasActedThisRound flag —
        // guards against the race condition where the flag was already set but the Set
        // removal was missed (e.g. character died mid-action or endTurn fired twice).
        if let activeId = activeCharacterId {
            if let char = playerTeam.first(where: { $0.id == activeId }) {
                char.hasActedThisRound = true
            }
            playersWhoHaveNotActed.remove(activeId)
        }

        currentTurnCount += 1
        if currentMissionType == .stealth && !missionComplete && currentTurnCount >= missionTargetTurns {
            finalizeCombat(
                won: true,
                missionLog: "MISSION COMPLETE — STEALTH WINDOW HELD FOR \(missionTargetTurns) TURNS"
            )
            return
        }

        let living = playerTeam.filter { $0.isAlive }
        guard !living.isEmpty else {
            isPlayerInputBlocked = false
            isPlayerTurn = true
            return
        }

        // Find next living character who hasn't acted this round
        let nextCharId = playersWhoHaveNotActed.first { id in
            living.contains { $0.id == id }
        }
        let nextChar = nextCharId.flatMap { id in living.first { $0.id == id } }

        if let char = nextChar {
            // More players still need to act — advance to next player without blocking input.
            activeCharacterId = char.id
            selectedCharacterId = char.id
            currentTurnIndex = playerTeam.firstIndex(where: { $0.id == char.id }) ?? 0
            isPlayerInputBlocked = false
            isPlayerTurn = true      // Stay in player phase — buttons must remain enabled
            isDefending = false
            defendingCharacterId = nil
            NotificationCenter.default.post(
                name: .turnChanged,
                object: nil,
                userInfo: ["characterId": char.id.uuidString]
            )
        } else {
            // All living players have acted — NOW lock input and start enemy phase.
            isPlayerTurn = false
            isPlayerInputBlocked = true
            currentTurnIndex = 0
            enemyPhaseCount += 1
            roundNumber += 1
            addLog("═══ ROUND \(roundNumber) ═══")
            HapticsManager.shared.roundStart()
            NotificationCenter.default.post(name: .roundStarted, object: nil, userInfo: ["round": roundNumber])
            enemyPhase()
        }
    }

    /// Check if combat is over
    func checkCombatEnd() {
        if currentMissionType == .assault && livingEnemies.isEmpty && pendingSpawns.isEmpty {
            finalizeCombat(won: true, missionLog: "MISSION COMPLETE — ASSAULT TARGET ELIMINATED")
            return
        }

        if livingPlayers.isEmpty {
            finalizeCombat(
                won: false,
                missionLog: "MISSION FAILED — ALL UNITS DOWN",
                terminalLog: "=== DEFEAT ==="
            )
        }
    }

    /// Check if any living player is standing on the extraction tile with no enemies alive.
    /// If so, trigger extraction win immediately.
    func checkExtraction() {
        ExtractionController.checkExtraction(gameState: self)
    }

    /// Request extraction resolution through GameState authority.
    /// Callers should pass the selected living character id (if available) and tapped tile.
    /// GameState validates extraction tile, updates model position, and finalizes mission state.
    func requestExtraction(characterId: UUID?, tileX: Int, tileY: Int) -> Bool {
        ExtractionController.requestExtraction(
            gameState: self,
            characterId: characterId,
            tileX: tileX,
            tileY: tileY
        )
    }

    /// Centralized mission outcome finalization.
    /// Ensures all victory/defeat paths mutate through GameState and emit one shared completion signal.
    private func finalizeCombat(won: Bool, missionLog: String, terminalLog: String? = nil) {
        OutcomePipeline.execute(
            gameState: self,
            won: won,
            missionLog: missionLog,
            terminalLog: terminalLog
        )
    }

    /// Mission's extraction point — set by setupMission from the mission JSON.
    var extractionX: Int = 8
    var extractionY: Int = 1


    /// MULTI-ROOM PROGRESSION: called when livingEnemies becomes empty.
    func onRoomCleared() {
        addLog("★ ROOM CLEARED ★")
        NotificationCenter.default.post(name: .roomCleared, object: nil)
    }

    // MARK: - Per-Type Enemy AI
    /// Run all enemy AI actions asynchronously with staggered per-enemy dispatch.
    /// Posts .enemyPhaseCompleted notification ONLY after all animations have finished,
    /// so BattleScene can unblock player input at the right moment.
    func enemyPhase() {
        guard !isEnemyPhaseRunning else { return }
        isEnemyPhaseRunning = true

        // Post .enemyPhaseBegan so CombatUI can update ("Enemy Turn" UI)
        NotificationCenter.default.post(name: .enemyPhaseBegan, object: nil)

        let livingEnemies = enemies.filter { $0.isAlive }
        let livingPlayers = playerTeam.filter { $0.isAlive }
        // Skip enemy phase if no enemies alive — post .enemyPhaseCompleted so player input unlocks.
        guard !livingEnemies.isEmpty else {
            isEnemyPhaseRunning = false
            beginRound()
            NotificationCenter.default.post(name: .enemyPhaseCompleted, object: nil)
            return
        }
        // If no players left, combat will end via checkCombatEnd() in the notify block.
        guard !livingPlayers.isEmpty else {
            isEnemyPhaseRunning = false
            beginRound()
            NotificationCenter.default.post(name: .enemyPhaseCompleted, object: nil)
            return
        }

        let group = DispatchGroup()
        let staggerDelay: TimeInterval = 0.18  // delay between enemy turns

        for (i, enemy) in livingEnemies.enumerated() {
            let delay = Double(i) * staggerDelay

            group.enter()
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self else { group.leave(); return }
                self.runEnemyAI(enemy: enemy, livingEnemies: livingEnemies)
                // Leave group only after the enemy's animations would have finished playing.
                // animateEnemyMove = 0.35s, playerHitEffect = 0.25s. Use 0.5s buffer.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    group.leave()
                }
            }
        }

        // When ALL enemies have finished their turns + animation windows, finalize.
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            self.processDelayedSpawns(enemyPhaseIndex: self.enemyPhaseCount)
            self.checkExtraction()
            self.checkCombatEnd()
            if self.combatEnded {
                self.isEnemyPhaseRunning = false
                NotificationCenter.default.post(name: .enemyPhaseCompleted, object: nil)
                return
            }
            self.isEnemyPhaseRunning = false
            // CRITICAL: reset hasActedThisRound for all players so they can act next round
            self.beginRound()
            // Signal BattleScene to unblock player input
            NotificationCenter.default.post(name: .enemyPhaseCompleted, object: nil)
            print("[GameState] enemyPhase: all enemies done, beginRound() called, .enemyPhaseCompleted posted")

            // Safety timeout: if .enemyPhaseCompleted notification fails to unblock input
            // (rare but possible if BattleScene observer is not registered), force-unblock
            // after 3 seconds so the player is never permanently locked out.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self = self else { return }
                if self.isPlayerInputBlocked && !self.combatEnded {
                    print("[GameState] Safety timeout: force-unblocking player input")
                    self.isPlayerInputBlocked = false
                    self.isPlayerTurn = true
                    NotificationCenter.default.post(name: .enemyPhaseCompleted, object: nil)
                }
            }
        }
    }

    /// Execute a single enemy's full AI turn synchronously (move + attack).
    /// All notifications are posted synchronously here — animations are scheduled
    /// by BattleScene's observers and played by the SpriteKit run loop.
    private func runEnemyAI(enemy: Enemy, livingEnemies: [Enemy]) {
        let livingPlayers = playerTeam.filter { $0.isAlive }
        guard !livingPlayers.isEmpty else { return }

        // Stunned enemies skip their turn (Decker hack effect)
        if enemy.status == .stunned {
            addLog("⚡ \(enemy.name) is stunned — cannot act!")
            enemy.status = .wounded  // recover to wounded after 1 round
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
                let playerDefensePool = closestPlayer.attributes.rea + closestPlayer.attributes.agi + defenseBonus + playerCoverBonus

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
                        if !closestPlayer.isAlive { HapticsManager.shared.playerKilled(); addLog("💀 \(closestPlayer.name) is DOWN!") }
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
                for _ in 0..<2 {
                    if let (nx, ny) = bfsPathfindDrone(from: enemy, towardX: closestPlayer.positionX, y: closestPlayer.positionY) {
                        enemy.positionX = nx; enemy.positionY = ny
                        let newDist = hexDistance(x1: closestPlayer.positionX, y1: closestPlayer.positionY, x2: enemy.positionX, y2: enemy.positionY)
                        addLog("→ \(enemy.name) advances")
                        NotificationCenter.default.post(name: .enemyMoved, object: nil, userInfo: ["enemyId": enemy.id.uuidString, "x": nx, "y": ny])
                        if newDist >= 2 { break }
                    } else { break }
                }
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
                    let playerDefensePool = closestPlayer.attributes.rea + closestPlayer.attributes.agi + defenseBonus + playerCoverBonus2

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
                            if !closestPlayer.isAlive { HapticsManager.shared.playerKilled(); addLog("💀 \(closestPlayer.name) is DOWN!") }
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
                    for _ in 0..<2 {
                        if let (newX, newY) = bfsPathfindToWounded(from: enemy, toward: woundedAlly) {
                            enemy.positionX = newX; enemy.positionY = newY
                            addLog("→ \(enemy.name) moves to assist ally")
                            NotificationCenter.default.post(name: .enemyMoved, object: nil, userInfo: ["enemyId": enemy.id.uuidString, "x": newX, "y": newY])
                            let newDist = hexDistance(x1: woundedAlly.positionX, y1: woundedAlly.positionY, x2: enemy.positionX, y2: enemy.positionY)
                            if newDist <= 1 { break }
                        } else { break }
                    }
                    let afterDist = hexDistance(x1: woundedAlly.positionX, y1: woundedAlly.positionY, x2: enemy.positionX, y2: enemy.positionY)
                    if afterDist > 1 { return }
                }
                let healAmount = 8 + Int.random(in: 0...4)
                let actualHeal = min(healAmount, woundedAlly.maxHP - woundedAlly.currentHP)
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
                // Ranged attack
                let weaponAccuracy = enemy.equippedWeapon?.accuracy ?? 3
                let attackPool = max(1, enemy.attributes.agi + (weaponAccuracy / 2))
                let defensePool = target.attributes.rea + target.attributes.agi
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
                for _ in 0..<3 {
                    if let (newX, newY) = bfsPathfind(from: enemy, toward: closestPlayer) {
                        enemy.positionX = newX; enemy.positionY = newY
                        addLog("→ \(enemy.name) charges!")
                        NotificationCenter.default.post(name: .enemyMoved, object: nil, userInfo: ["enemyId": enemy.id.uuidString, "x": newX, "y": newY])
                        let newDist = hexDistance(x1: closestPlayer.positionX, y1: closestPlayer.positionY, x2: enemy.positionX, y2: enemy.positionY)
                        if newDist <= 1 { break }
                    } else { break }
                }
                let afterMoveDist = hexDistance(x1: closestPlayer.positionX, y1: closestPlayer.positionY, x2: enemy.positionX, y2: enemy.positionY)
                if afterMoveDist > 1 { return }
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
            let playerDefensePool = closestPlayer.attributes.rea + closestPlayer.attributes.agi + defenseBonus + elitePlayerCoverBonus

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
                    if !closestPlayer.isAlive { HapticsManager.shared.playerKilled(); addLog("💀 \(closestPlayer.name) is DOWN!") }
                } else {
                    addLog("→ \(enemy.name) attacks — \(closestPlayer.name) soaks all damage!")
                }
            }

        default:
            let closestPlayer = livingPlayers.min { a, b in
                let distA = hexDistance(x1: a.positionX, y1: a.positionY, x2: enemy.positionX, y2: enemy.positionY)
                let distB = hexDistance(x1: b.positionX, y1: b.positionY, x2: enemy.positionX, y2: enemy.positionY)
                return distA < distB
            }!
            let dist = hexDistance(x1: closestPlayer.positionX, y1: closestPlayer.positionY, x2: enemy.positionX, y2: enemy.positionY)
            if dist > 1 {
                for _ in 0..<2 {
                    if let (newX, newY) = bfsPathfind(from: enemy, toward: closestPlayer) {
                        enemy.positionX = newX; enemy.positionY = newY
                        addLog("→ \(enemy.name) advances")
                        NotificationCenter.default.post(name: .enemyMoved, object: nil, userInfo: ["enemyId": enemy.id.uuidString, "x": newX, "y": newY])
                        let newDist = hexDistance(x1: closestPlayer.positionX, y1: closestPlayer.positionY, x2: enemy.positionX, y2: enemy.positionY)
                        if newDist <= 1 { break }
                    } else { break }
                }
                let afterMoveDist = hexDistance(x1: closestPlayer.positionX, y1: closestPlayer.positionY, x2: enemy.positionX, y2: enemy.positionY)
                if afterMoveDist > 1 { return }
            }
            let target = closestPlayer

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
                        if !target.isAlive { HapticsManager.shared.playerKilled(); addLog("💀 \(target.name) is DOWN!") }
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
                let playerDefensePool = target.attributes.rea + target.attributes.agi + defenseBonus + guardPlayerCoverBonus

                let attackRoll = DiceEngine.roll(pool: enemyAttackPool)
                let defenseRoll = DiceEngine.roll(pool: playerDefensePool)
                let netHits = max(0, attackRoll.hits - defenseRoll.hits)

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
                        if !target.isAlive { HapticsManager.shared.playerKilled(); addLog("💀 \(target.name) is DOWN!") }
                    } else {
                        addLog("→ \(enemy.name) attacks — \(target.name) soaks all damage!")
                    }
                }
            }
        }
    }

    /// Find the best retreat tile for a drone — step AWAY from the target (hex-aware).
    func bestRetreatTile(for enemy: Enemy, awayFrom target: Character) -> (Int, Int) {
        PathingAndAIHelpers.bestRetreatTile(gameState: self, for: enemy, awayFrom: target)
    }

    /// BFS pathfinding for drone (hex-aware).
    func bfsPathfindDrone(from enemy: Enemy, towardX gx: Int, y gy: Int) -> (Int, Int)? {
        PathingAndAIHelpers.bfsPathfindDrone(gameState: self, from: enemy, towardX: gx, y: gy)
    }
    /// BFS pathfinding — returns best hex-adjacent tile to move toward target.
    func bfsPathfind(from enemy: Enemy, toward target: Character) -> (Int, Int)? {
        PathingAndAIHelpers.bfsPathfind(gameState: self, from: enemy, toward: target)
    }

    /// Find a wounded ally (enemy) within 5 hex tiles to heal.
    func findWoundedAlly(for enemy: Enemy) -> Enemy? {
        PathingAndAIHelpers.findWoundedAlly(gameState: self, for: enemy)
    }

    /// BFS pathfinding to a wounded ally (hex-aware, healer can pass through other enemies).
    func bfsPathfindToWounded(from enemy: Enemy, toward target: Enemy) -> (Int, Int)? {
        PathingAndAIHelpers.bfsPathfindToWounded(gameState: self, from: enemy, toward: target)
    }

    /// Check if a tile is walkable for the healer (medic can walk through other enemies).
    func tileWalkableForHealer(x: Int, y: Int, excluding enemyId: UUID) -> Bool {
        PathingAndAIHelpers.tileWalkableForHealer(gameState: self, x: x, y: y, excluding: enemyId)
    }

    /// Expose isDefending for enemyPhase damage check.
    func isCharacterDefending(_ charId: UUID) -> Bool {
        return isDefending && defendingCharacterId == charId
    }

    /// FIX 2: Check if any wall tile intersects the straight line between two tiles.
    /// Uses Bresenham's line algorithm to check each tile along the path.
    /// Returns true if a wall blocks the attack.
    func isLineBlockedByWall(fromX sx: Int, fromY sy: Int, toX dx: Int, toY dy: Int) -> Bool {
        PathingAndAIHelpers.isLineBlockedByWall(gameState: self, fromX: sx, fromY: sy, toX: dx, toY: dy)
    }

    func findNextLivingCharacter(after index: Int) -> Character? {
        PathingAndAIHelpers.findNextLivingCharacter(gameState: self, after: index)
    }

    // MARK: - Hex Grid Helpers

    /// Returns the 6 valid hex neighbors for a flat-top odd-q offset coordinate.
    func hexNeighbors(x: Int, y: Int) -> [(Int, Int)] {
        PathingAndAIHelpers.hexNeighbors(gameState: self, x: x, y: y)
    }

    /// True if (x2,y2) is one of the 6 hex neighbors of (x1,y1).
    func hexAdjacent(x1: Int, y1: Int, x2: Int, y2: Int) -> Bool {
        PathingAndAIHelpers.hexAdjacent(gameState: self, x1: x1, y1: y1, x2: x2, y2: y2)
    }

    /// Hex distance between two tiles using cube coordinate conversion (flat-top odd-q offset).
    func hexDistance(x1: Int, y1: Int, x2: Int, y2: Int) -> Int {
        PathingAndAIHelpers.hexDistance(gameState: self, x1: x1, y1: y1, x2: x2, y2: y2)
    }

    /// Check if a tile is walkable for enemies (not wall/door, not occupied by player or other enemy)
    func tileWalkable(x: Int, y: Int, excluding enemyId: UUID) -> Bool {
        PathingAndAIHelpers.tileWalkable(gameState: self, x: x, y: y, excluding: enemyId)
    }

    func showMoveMenu() {
        let char: Character
        if let selected = selectedCharacterId, let c = playerTeam.first(where: { $0.id == selected && $0.isAlive }) {
            char = c
        } else if let current = currentCharacter {
            char = current
        } else { return }
        addLog("\(char.name): tap a tile to move.")
    }

    /// Use first available consumable on the active character.
    func performUseItem() {
        let char: Character
        if let selected = selectedCharacterId, let c = playerTeam.first(where: { $0.id == selected && $0.isAlive }) {
            char = c
        } else if let current = currentCharacter {
            char = current
        } else { addLog("No character to heal."); return }

        // Find a consumable item
        guard let idx = loot.firstIndex(where: { $0.type == .consumable }) else {
            addLog("No medkits available.")
            HapticsManager.shared.buttonTap()
            return
        }
        HapticsManager.shared.attackHit()
        let item = loot.remove(at: idx)
        char.currentHP = min(char.maxHP, char.currentHP + item.bonus)
        // Medkits also clear some stun damage (First Aid = treat stun & physical)
        char.recoverStun(amount: item.bonus / 2)
        addLog("\(char.name) uses \(item.name)! +\(item.bonus) HP, -\(item.bonus / 2) Stun. (HP \(char.currentHP)/\(char.maxHP) | Stun \(char.currentStun)/\(char.maxStun))")
        completeAction(for: char)
    }

    /// Select a character by UUID and update active character.
    func selectCharacter(id: UUID) {
        if let char = playerTeam.first(where: { $0.id == id }) {
            selectedCharacterId = char.id
            activeCharacterId = char.id
            targetCharacterId = nil
            addLog("Selected: \(char.name)")
        }
    }

    /// Handle a tap on a tile from BattleScene.
    func handleTileTap(tileX: Int, tileY: Int) {
        if let char = playerTeam.first(where: { $0.positionX == tileX && $0.positionY == tileY && $0.isAlive }) {
            selectedCharacterId = char.id
            targetCharacterId = nil
            addLog("Selected: \(char.name)")
            NotificationCenter.default.post(name: .characterSelected, object: nil, userInfo: ["characterId": char.id.uuidString])
            return
        }

        if let enemy = enemies.first(where: { $0.positionX == tileX && $0.positionY == tileY && $0.isAlive }) {
            if selectedCharacterId == nil { addLog("Select a character first."); return }
            targetCharacterId = enemy.id
            addLog("Targeting: \(enemy.name)")
            return
        }

        if let selectedId = selectedCharacterId,
           let char = playerTeam.first(where: { $0.id == selectedId }) {
            let isHexAdj = hexAdjacent(x1: tileX, y1: tileY, x2: char.positionX, y2: char.positionY)
            if isHexAdj {
                char.positionX = tileX
                char.positionY = tileY
                addLog("\(char.name) moves to (\(tileX),\(tileY))")
                NotificationCenter.default.post(
                    name: .tileTapped,
                    object: nil,
                    userInfo: ["tileX": tileX, "tileY": tileY, "characterId": char.id.uuidString]
                )
                // Movement is a free action — does NOT consume the turn.
            } else {
                addLog("Too far. Choose an adjacent hex.")
            }
            return
        }

        addLog("Empty tile: (\(tileX),\(tileY))")
    }

    // MARK: - Log

    func addLog(_ entry: String) {
        combatLog.append(entry)
        if combatLog.count > 50 { combatLog.removeFirst() }
        // Force SwiftUI refresh for array mutations
        objectWillChange.send()
    }
}

// MARK: - Game Phase

/// Game state machine managing all major game states and transitions
enum GamePhase: Equatable {
    case title
    case missionSelect
    case briefing
    case combat
    case debrief

    var displayName: String {
        switch self {
        case .title:         return "Title"
        case .missionSelect: return "Mission Select"
        case .briefing:      return "Briefing"
        case .combat:       return "Combat"
        case .debrief:       return "Debrief"
        }
    }
}

// MARK: - State Transition Event

enum StateTransition {
    case startGame
    case selectMission(String)
    case beginMission
    case startCombat
    case endCombat(won: Bool)
    case viewDebrief
    case returnToTitle
    case exitGame
}

// MARK: - Game State Manager

@MainActor
final class GameStateManager: ObservableObject {

    @Published private(set) var currentState: GamePhase = .title
    @Published private(set) var selectedMissionId: String?
    @Published private(set) var combatWon: Bool?

    private var stateHistory: [GamePhase] = [.title]

    // MARK: - Transition

    func transition(to event: StateTransition) -> Bool {
        let nextState = computeNext(from: currentState, event: event)

        if nextState == currentState {
            return false
        }

        if let missionId = extractMissionId(from: event) {
            selectedMissionId = missionId
        }

        if let won = extractCombatResult(from: event) {
            combatWon = won
        }

        stateHistory.append(nextState)
        currentState = nextState
        return true
    }

    // MARK: - Query

    var canStartGame: Bool { currentState == .title }
    var canSelectMission: Bool { currentState == .missionSelect }
    var isInCombat: Bool { currentState == .combat }
    var stateStack: [GamePhase] { stateHistory }

    // MARK: - Private

    private func computeNext(from state: GamePhase, event: StateTransition) -> GamePhase {
        switch (state, event) {
        case (.title, .startGame):         return .missionSelect
        case (.missionSelect, .selectMission): return .briefing
        case (.briefing, .beginMission):    return .combat
        case (.combat, .endCombat):        return .debrief
        case (.debrief, .returnToTitle):   return .title
        default:                            return state
        }
    }

    private func extractMissionId(from event: StateTransition) -> String? {
        if case .selectMission(let id) = event { return id }
        return nil
    }

    private func extractCombatResult(from event: StateTransition) -> Bool? {
        if case .endCombat(let won) = event { return won }
        return nil
    }
}

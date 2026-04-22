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
    private var enemyPhaseCount: Int = 0  // how many enemy phases have completed (for delayed spawns)
    @Published var isPlayerTurn: Bool = true
    /// When true, blocks player input in BattleScene while enemy phase is running.
    @Published var isPlayerInputBlocked: Bool = false
    /// Guards against double-triggering enemyPhase() within the same frame/turn.
    private var isEnemyPhaseRunning: Bool = false
    @Published var actionMode: ActionMode = .street
    @Published var playerRole: PlayerRole = .normal
    @Published var selectedMissionPreset: MissionPreset = .standard
    @Published var traceLevel: Int = 0
    var traceThreshold: Int { TraceCadence.threshold(for: selectedMissionPreset) }
    var traceGainPerSignal: Int { TraceCadence.gainPerSignal }
    var traceRecoveryPerLayLow: Int { TraceCadence.recoveryPerLayLow }
    var escalationDamageBonus: Int { TraceCadence.escalationDamageBonus(for: selectedMissionPreset) }
    @Published var traceEscalationLevel: Int = 0
    private var hasLoggedTraceTriggerForCurrentRun: Bool = false

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

    private var currentMissionTiles: [[Int]] = []

    // MARK: - Pending Enemy Spawns

    /// Enemies not yet on the map (waiting for their delay timer)
    private var pendingSpawns: [PendingSpawn] = []

    struct PendingSpawn: Identifiable {
        let id = UUID()
        let enemy: Enemy
        let delayRounds: Int  // spawn after N enemy phases have passed
    }

    /// Called after each enemy phase to check if any delayed enemies should spawn.
    /// enemyPhaseIndex = how many enemy phases have completed (0 = first enemy phase just ran).
    func processDelayedSpawns(enemyPhaseIndex: Int) {
        let due = pendingSpawns.filter { $0.delayRounds <= enemyPhaseIndex }
        for spawn in due {
            enemies.append(spawn.enemy)
            addLog("⚠️ \(spawn.enemy.name) reinforcements arrive!")
            NotificationCenter.default.post(
                name: .enemySpawned,
                object: nil,
                userInfo: ["enemyId": spawn.enemy.id.uuidString]
            )
        }
        pendingSpawns.removeAll { $0.delayRounds <= enemyPhaseIndex }
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
    private var missionLoadIndex: Int = 0
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
        let corpAttention = factionAttention[.corp, default: 0]
        return ConsequenceEngine.worldReactionMessage(
            missionHeatTier: missionHeatTier,
            corpAttention: corpAttention
        )
    }

    func generateMissionModifierPreview() -> String {
        let corpAttention = factionAttention[.corp, default: 0]
        return ConsequenceEngine.missionModifierPreview(corpAttention: corpAttention)
    }

    func generateGangReactionMessage() -> String {
        let gangAttention = factionAttention[.gang, default: 0]
        return ConsequenceEngine.gangReactionMessage(
            missionHeatTier: missionHeatTier,
            gangAttention: gangAttention
        )
    }

    func generateGangMissionPreview() -> String {
        let gangAttention = factionAttention[.gang, default: 0]
        return ConsequenceEngine.gangMissionPreview(gangAttention: gangAttention)
    }

    func generateCombinedPressurePreview() -> String {
        ConsequenceEngine.combinedPressurePreview(
            corpModifier: lastAppliedCorpEnemyModifier,
            gangRadius: lastAppliedGangAmbushRadius
        )
    }

    func rewardTierLabel(_ tier: RewardTier) -> String {
        switch tier {
        case .low: return "LOW"
        case .medium: return "MED"
        case .high: return "HIGH"
        }
    }

    func generateRewardPreview() -> String {
        switch lastRewardTier {
        case .low:
            return "Low risk operation. Standard payout."
        case .medium:
            return "Moderate risk. Increased payout expected."
        case .high:
            return "High risk operation. Significant rewards expected."
        }
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
        let emphasis: String
        switch lastRewardTier {
        case .high:
            emphasis = "HIGH RISK BONUS\n"
        case .medium:
            emphasis = "INCREASED PAYOUT\n"
        case .low:
            emphasis = ""
        }

        return """
        \(emphasis)MISSION PAYOUT:
        Base: \(baseMissionPayout)
        Risk Bonus: +\(riskBonus)
        Total: \(finalMissionPayout)
        """
    }

    private func assignMissionTypeForCurrentLoad() {
        let assignedType: MissionType
        switch missionLoadIndex % 3 {
        case 1:
            assignedType = .assault
        case 2:
            assignedType = .extraction
        default:
            assignedType = .stealth
        }
        currentMissionType = assignedType
        switch currentMissionType {
        case .stealth:
            currentMapSituation = .corridor
        case .assault:
            currentMapSituation = .openZone
        case .extraction:
            currentMapSituation = .chokepoint
        }
        missionLoadIndex += 1
        addLog("MISSION TYPE — \(missionTypeLabel)")
        addLog("MISSION TYPE HINT — \(missionTypeHint)")
        addLog("Map situation: \(mapSituationLabel)")
    }

    private func tileKey(x: Int, y: Int) -> String { "\(x),\(y)" }

    private func applyMapSituation(
        to originalMap: [[Int]],
        extractionPoint: (x: Int, y: Int),
        protectedTiles: Set<String>
    ) -> ([[Int]], (x: Int, y: Int)) {
        guard !originalMap.isEmpty else { return (originalMap, extractionPoint) }

        var map = originalMap
        let height = map.count
        let width = map.first?.count ?? TileMap.mapWidth
        let laneX = width / 2
        var updatedExtraction = extractionPoint

        func isProtected(_ x: Int, _ y: Int) -> Bool {
            protectedTiles.contains(tileKey(x: x, y: y))
        }

        func canRewrite(_ x: Int, _ y: Int) -> Bool {
            guard y >= 0, y < height, x >= 0, x < map[y].count else { return false }
            if isProtected(x, y) { return false }
            let tile = map[y][x]
            return tile != TileType.door.rawValue && tile != TileType.extraction.rawValue
        }

        switch currentMapSituation {
        case .corridor:
            for y in 0..<height {
                if canRewrite(laneX, y) { map[y][laneX] = TileType.floor.rawValue }
                if laneX - 1 >= 0, canRewrite(laneX - 1, y), y % 2 == 0 {
                    map[y][laneX - 1] = TileType.cover.rawValue
                }
                if laneX + 1 < width, canRewrite(laneX + 1, y), y % 2 == 1 {
                    map[y][laneX + 1] = TileType.cover.rawValue
                }
            }
        case .openZone:
            let xStart = max(1, width / 2 - 2)
            let xEnd = min(width - 2, width / 2 + 2)
            let yStart = max(1, height / 2 - 2)
            let yEnd = min(height - 2, height / 2 + 2)
            if xStart <= xEnd && yStart <= yEnd {
                for y in yStart...yEnd {
                    for x in xStart...xEnd where canRewrite(x, y) {
                        map[y][x] = TileType.floor.rawValue
                    }
                }
            }
            if height > 2 && width > 2 {
                for y in 1..<(height - 1) {
                    for x in 1..<(width - 1) where canRewrite(x, y) {
                        if map[y][x] == TileType.wall.rawValue && (x + y) % 2 == 0 {
                            map[y][x] = TileType.floor.rawValue
                        }
                    }
                }
            }
        case .chokepoint:
            let targetY = extractionPoint.y < height / 2 ? 1 : max(1, height - 2)
            let targetX = max(0, width - 1)
            if extractionPoint.y >= 0, extractionPoint.y < height, extractionPoint.x >= 0, extractionPoint.x < map[extractionPoint.y].count,
               map[extractionPoint.y][extractionPoint.x] == TileType.extraction.rawValue {
                map[extractionPoint.y][extractionPoint.x] = TileType.floor.rawValue
            }
            if targetY >= 0, targetY < height, targetX >= 0, targetX < map[targetY].count {
                map[targetY][targetX] = TileType.extraction.rawValue
                updatedExtraction = (targetX, targetY)
            }

            let laneY = targetY
            for x in min(laneX, targetX)...max(laneX, targetX) where canRewrite(x, laneY) {
                map[laneY][x] = TileType.floor.rawValue
            }
            for y in min(height / 2, laneY)...max(height / 2, laneY) where canRewrite(laneX, y) {
                map[y][laneX] = TileType.floor.rawValue
            }

            for y in 0..<height {
                for x in 0..<min(width, map[y].count) where canRewrite(x, y) {
                    let isLane = (x == laneX) || (y == laneY && x >= min(laneX, targetX) && x <= max(laneX, targetX))
                    if !isLane && (x <= 1 || x >= width - 2 || abs(x - laneX) >= 3) {
                        map[y][x] = TileType.wall.rawValue
                    }
                }
            }
        }

        return (map, updatedExtraction)
    }

    var currentMissionTilesSnapshot: [[Int]] {
        currentMissionTiles
    }

    func generateMissionEndSummary() -> String {
        let corpAttention = factionAttention[.corp, default: 0]
        let gangAttention = factionAttention[.gang, default: 0]

        return """
        ------------------------

        MISSION COMPLETE

        Mission Type: \(missionTypeLabel)
        Pressure: \(traceTierLabel) (+\(escalationDamageBonusForCurrentTrace) dmg)
        Heat: \(heatTierLabel)
        Corp Attention: \(corpAttention)
        Gang Attention: \(gangAttention)

        COMBINED PRESSURE:
        \(generateCombinedPressurePreview())

        REWARD:
        Base: \(baseMissionPayout)
        Risk Bonus: +\(riskBonus)
        Total: \(finalMissionPayout)

        WORLD REACTION:
        \(generateWorldReactionMessage())

        NEXT MISSION:
        Corp: \(generateMissionModifierPreview())
        Gang: \(generateGangMissionPreview())

        ------------------------
        """
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

    private func archetypeForSpawnIndex(_ spawnIndex: Int) -> EnemyArchetype {
        switch currentMissionType {
        case .stealth:
            let pattern: [EnemyArchetype] = [.watcher, .watcher, .interceptor, .watcher, .enforcer]
            return pattern[spawnIndex % pattern.count]
        case .assault:
            let pattern: [EnemyArchetype] = [.enforcer, .enforcer, .interceptor, .enforcer, .watcher]
            return pattern[spawnIndex % pattern.count]
        case .extraction:
            let pattern: [EnemyArchetype] = [.interceptor, .watcher, .interceptor, .enforcer, .interceptor]
            return pattern[spawnIndex % pattern.count]
        }
    }

    private func applyEnemyArchetype(_ archetype: EnemyArchetype, to enemy: Enemy) {
        enemy.name = "\(enemy.name) (\(archetypeLabel(archetype)))"
        switch archetype {
        case .watcher:
            enemy.currentHP = max(1, enemy.currentHP - 2) // slightly lower HP
        case .enforcer:
            if var weapon = enemy.equippedWeapon {
                weapon.damage += 1 // higher damage using existing weapon scaling
                enemy.equippedWeapon = weapon
            }
        case .interceptor:
            enemy.attributes.rea += 1 // more mobile feel via existing attributes
            enemy.attributes.agi += 1
        }
    }

    private func makeEnemy(for type: String, archetype: EnemyArchetype) -> Enemy {
        let enemy: Enemy
        switch type {
        case "guard": enemy = Enemy.corpGuard()
        case "drone": enemy = Enemy.securityDrone()
        case "elite": enemy = Enemy.eliteGuard()
        case "mage": enemy = Enemy.corpMage()
        case "healer": enemy = Enemy.medic()
        default: enemy = Enemy.corpGuard()
        }
        applyEnemyArchetype(archetype, to: enemy)
        return enemy
    }

    private func logEnemyComposition(totalSpawnCount: Int) {
        guard totalSpawnCount > 0 else { return }
        var watcherCount = 0
        var enforcerCount = 0
        var interceptorCount = 0

        for index in 0..<totalSpawnCount {
            switch archetypeForSpawnIndex(index) {
            case .watcher: watcherCount += 1
            case .enforcer: enforcerCount += 1
            case .interceptor: interceptorCount += 1
            }
        }

        let dominant: String
        if watcherCount >= enforcerCount && watcherCount >= interceptorCount {
            dominant = "WATCHERS"
        } else if enforcerCount >= watcherCount && enforcerCount >= interceptorCount {
            dominant = "ENFORCERS"
        } else {
            dominant = "INTERCEPTORS"
        }

        addLog("Enemy composition: \(dominant)")
        addLog("Archetypes — Watcher: \(watcherCount), Enforcer: \(enforcerCount), Interceptor: \(interceptorCount)")
    }

    private func applyCorpAttentionEnemyInfluence(spawnTemplates: [(type: String, x: Int, y: Int)], map: [[Int]]) {
        let modifier = corpAttentionEnemyModifier()
        lastAppliedCorpEnemyModifier = 0

        guard modifier > 0 else {
            addLog("No enemy presence increase from corp attention.")
            return
        }
        guard !spawnTemplates.isEmpty else {
            addLog("Corp attention modifier available (+\(modifier)), but no spawn templates found.")
            return
        }

        let width = map.first?.count ?? TileMap.mapWidth
        let height = map.count
        let offsets: [(Int, Int)] = [(0, 0), (1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, 1)]

        var occupied = Set(playerTeam.filter(\.isAlive).map { "\($0.positionX),\($0.positionY)" })
        for enemy in enemies where enemy.isAlive {
            occupied.insert("\(enemy.positionX),\(enemy.positionY)")
        }
        for pending in pendingSpawns where pending.enemy.isAlive {
            occupied.insert("\(pending.enemy.positionX),\(pending.enemy.positionY)")
        }

        var applied = 0
        for i in 0..<modifier {
            let template = spawnTemplates[i % spawnTemplates.count]
            let archetype = archetypeForSpawnIndex(enemies.count + pendingSpawns.count + applied)
            let enemy = makeEnemy(for: template.type, archetype: archetype)

            var placed = false
            for probe in 0..<offsets.count {
                let offset = offsets[(probe + i) % offsets.count]
                let x = max(0, min(width - 1, template.x + offset.0))
                let y = max(0, min(height - 1, template.y + offset.1))
                guard y >= 0, y < map.count, x >= 0, x < map[y].count else { continue }
                guard map[y][x] != 1 else { continue }
                let key = "\(x),\(y)"
                guard !occupied.contains(key) else { continue }
                enemy.positionX = x
                enemy.positionY = y
                enemies.append(enemy)
                occupied.insert(key)
                applied += 1
                addLog("\(archetypeLabel(archetype)) deployed")
                placed = true
                break
            }

            if !placed {
                addLog("Corp attention spawn skipped: no safe tile for extra enemy \(i + 1)/\(modifier).")
            }
        }

        lastAppliedCorpEnemyModifier = applied
        if applied == 0 {
            addLog("Corp attention increased threat profile, but no extra enemies could be placed.")
        } else if applied < modifier {
            addLog("Corp attention increased enemy presence by +\(applied) (requested +\(modifier)).")
        } else {
            addLog("Corp attention increased enemy presence by +\(applied).")
        }
    }

    func distanceToNearestPlayer(x: Int, y: Int) -> Int {
        let living = playerTeam.filter(\.isAlive)
        guard !living.isEmpty else { return Int.max }
        var best = Int.max
        for player in living {
            let distance = abs(player.positionX - x) + abs(player.positionY - y)
            if distance < best {
                best = distance
            }
        }
        return best
    }

    private func applyGangAmbushBias(map: [[Int]]) {
        let gangAttention = factionAttention[.gang, default: 0]
        let baseRadius = ConsequenceEngine.gangAmbushRadius(gangAttention: gangAttention)
        lastAppliedGangAmbushRadius = baseRadius

        guard baseRadius < 999 else {
            addLog("No ambush bias applied.")
            return
        }

        addLog("Gang ambush bias applied: radius \(baseRadius)")

        let width = map.first?.count ?? TileMap.mapWidth
        let height = map.count
        let maxRadius = max(width, height) * 2

        var occupied = Set(playerTeam.filter(\.isAlive).map { "\($0.positionX),\($0.positionY)" })
        var didLogRelaxation = false

        let allSpawnedEnemies = enemies + pendingSpawns.map(\.enemy)
        for enemy in allSpawnedEnemies where enemy.isAlive {
            var effectiveRadius = baseRadius
            var placed = false

            while effectiveRadius <= maxRadius && !placed {
                for y in 0..<height {
                    for x in 0..<width {
                        guard y < map.count, x < map[y].count else { continue }
                        guard map[y][x] != 1 else { continue }
                        guard distanceToNearestPlayer(x: x, y: y) <= effectiveRadius else { continue }
                        let key = "\(x),\(y)"
                        guard !occupied.contains(key) else { continue }
                        enemy.positionX = x
                        enemy.positionY = y
                        occupied.insert(key)
                        placed = true
                        break
                    }
                    if placed { break }
                }

                if !placed {
                    effectiveRadius += 1
                    if !didLogRelaxation {
                        addLog("Ambush bias relaxed due to no valid positions.")
                        didLogRelaxation = true
                    }
                }
            }

            if !placed {
                let key = "\(enemy.positionX),\(enemy.positionY)"
                occupied.insert(key)
            }
        }
    }

    func setupMission(_ mission: Mission) {
        print("[GameState] setupMission: \(mission.title)")
        playerTeam = Character.allRunners
        if let spawn = Optional(mission.playerSpawn) {
            for (i, char) in playerTeam.enumerated() {
                char.positionX = spawn.x + i
                char.positionY = spawn.y
            }
        }

        enemies = []
        pendingSpawns = []
        assignMissionTypeForCurrentLoad()

        for (spawnIndex, spawn) in mission.enemies.enumerated() {
            let archetype = archetypeForSpawnIndex(spawnIndex)
            let enemy = makeEnemy(for: spawn.type, archetype: archetype)
            enemy.positionX = spawn.x
            enemy.positionY = spawn.y

            if spawn.delay == 0 {
                enemies.append(enemy)
                addLog("\(archetypeLabel(archetype)) deployed")
            } else {
                // Store as pending spawn: delay is in turns, we count enemy phases
                pendingSpawns.append(PendingSpawn(enemy: enemy, delayRounds: spawn.delay))
            }
        }

        // Store mission tiles for enemy pathfinding, then apply deterministic map situation emphasis.
        let protectedTiles = Set(
            mission.enemies.map { tileKey(x: $0.x, y: $0.y) } +
            [tileKey(x: mission.playerSpawn.x, y: mission.playerSpawn.y)]
        )
        let adjustedMissionMap = applyMapSituation(
            to: mission.map,
            extractionPoint: (mission.extractionPoint.x, mission.extractionPoint.y),
            protectedTiles: protectedTiles
        )
        currentMissionTiles = adjustedMissionMap.0

        currentTurnIndex = 0
        roundNumber = 1
        enemyPhaseCount = 0
        traceLevel = 0
        traceEscalationLevel = 0
        hasLoggedTraceTriggerForCurrentRun = false
        actionMode = .street
        logEnemyComposition(totalSpawnCount: mission.enemies.count)
        missionComplete = false
        didApplyAttentionRecoveryLastMission = false
        didApplyHighTraceEscalationBonusLastMission = false
        lastRewardTier = .low
        lastRewardMultiplier = 1.0
        missionTypeBonusMultiplier = 0.0
        missionHeat = 0
        missionHeatTier = .low
        currentTurnCount = 0
        combatLog = ["Mission started: \(mission.title)"]
        extractionX = adjustedMissionMap.1.x
        extractionY = adjustedMissionMap.1.y
        applyCorpAttentionEnemyInfluence(
            spawnTemplates: mission.enemies.map { ($0.type, $0.x, $0.y) },
            map: currentMissionTiles
        )
        applyGangAmbushBias(map: currentMissionTiles)
        addLog(generateCombinedPressurePreview())
        addLog(generateMissionBriefing())
        addLog("Reach extraction at (\(extractionX), \(extractionY))")
        // Spawn immediate enemies (delay=0) before combat starts
        processDelayedSpawns(enemyPhaseIndex: 0)
        activeCharacterId = playerTeam.first?.id
        selectedCharacterId = playerTeam.first?.id
        beginRound()
        // CRITICAL: Reset player input block so game isn't locked at mission start
        isPlayerInputBlocked = false
        isPlayerTurn = true
        isEnemyPhaseRunning = false
    }

    /// Setup a multi-room mission.
    /// Update tiles for enemy pathfinding (called when a room transition completes).
    func updateTilesForCurrentRoom(_ tiles: [[Int]]) {
        currentMissionTiles = tiles
    }

    func setupMultiRoomMission(_ mission: MultiRoomMission) {
        print("[GameState] setupMultiRoomMission: \(mission.title)")
        playerTeam = Character.allRunners

        let firstRoom = mission.rooms.first!
        // Mark first room as entered so back-navigation preserves positions correctly.
        RoomManager.shared.markRoomEntered(firstRoom.id)
        let spawn = firstRoom.playerSpawn
        for (i, char) in playerTeam.enumerated() {
            char.positionX = spawn.x + i
            char.positionY = spawn.y
        }

        enemies = []
        pendingSpawns = []
        assignMissionTypeForCurrentLoad()

        // Only load enemies from the first room (others spawn when entered)
        for (spawnIndex, spawn) in firstRoom.enemies.enumerated() {
            let archetype = archetypeForSpawnIndex(spawnIndex)
            let enemy = makeEnemy(for: spawn.type, archetype: archetype)
            enemy.positionX = spawn.x
            enemy.positionY = spawn.y

            if spawn.delay == 0 {
                enemies.append(enemy)
                addLog("\(archetypeLabel(archetype)) deployed")
            } else {
                pendingSpawns.append(PendingSpawn(enemy: enemy, delayRounds: spawn.delay))
            }
        }

        // Store first room's tiles for pathfinding, then apply deterministic map situation emphasis.
        let firstRoomExtraction = firstRoom.extractionPoint ?? SpawnPoint(x: firstRoom.playerSpawn.x, y: firstRoom.playerSpawn.y)
        let protectedTiles = Set(
            firstRoom.enemies.map { tileKey(x: $0.x, y: $0.y) } +
            [tileKey(x: firstRoom.playerSpawn.x, y: firstRoom.playerSpawn.y)]
        )
        let adjustedFirstRoomMap = applyMapSituation(
            to: firstRoom.map,
            extractionPoint: (firstRoomExtraction.x, firstRoomExtraction.y),
            protectedTiles: protectedTiles
        )
        currentMissionTiles = adjustedFirstRoomMap.0

        // Set current room ID
        currentRoomId = firstRoom.id

        currentTurnIndex = 0
        roundNumber = 1
        enemyPhaseCount = 0
        traceLevel = 0
        traceEscalationLevel = 0
        hasLoggedTraceTriggerForCurrentRun = false
        actionMode = .street
        logEnemyComposition(totalSpawnCount: firstRoom.enemies.count)
        missionComplete = false
        didApplyAttentionRecoveryLastMission = false
        didApplyHighTraceEscalationBonusLastMission = false
        lastRewardTier = .low
        lastRewardMultiplier = 1.0
        missionTypeBonusMultiplier = 0.0
        missionHeat = 0
        missionHeatTier = .low
        currentTurnCount = 0
        combatLog = ["Mission started: \(mission.title)", "Entering: \(firstRoom.title)"]
        applyCorpAttentionEnemyInfluence(
            spawnTemplates: firstRoom.enemies.map { ($0.type, $0.x, $0.y) },
            map: currentMissionTiles
        )
        applyGangAmbushBias(map: currentMissionTiles)
        addLog(generateCombinedPressurePreview())
        addLog(generateMissionBriefing())

        if let ext = firstRoom.extractionPoint {
            extractionX = adjustedFirstRoomMap.1.x
            extractionY = adjustedFirstRoomMap.1.y
            addLog("Reach extraction at (\(extractionX), \(extractionY))")
        } else {
            // Use the first door connection as the "exit" of the first room
            if let firstConn = firstRoom.connections.first {
                extractionX = firstConn.triggerTileX
                extractionY = firstConn.triggerTileY
                addLog("Find a way through to: \(firstConn.targetRoomId)")
            }
        }

        processDelayedSpawns(enemyPhaseIndex: 0)
        activeCharacterId = playerTeam.first?.id
        selectedCharacterId = playerTeam.first?.id
        beginRound()
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
        guard currentMissionType == .extraction else { return }
        // Both livingEnemies AND pendingSpawns must be empty before extraction is allowed.
        // This prevents premature victory when delayed reinforcements are still pending.
        guard livingEnemies.isEmpty && pendingSpawns.isEmpty else { return }
        let onExtraction = livingPlayers.contains { $0.positionX == extractionX && $0.positionY == extractionY }
        if onExtraction {
            finalizeCombat(
                won: true,
                missionLog: "🚁 EXTRACTION SUCCESS — Runners are out!",
                terminalLog: "=== VICTORY ==="
            )
        }
    }

    /// Request extraction resolution through GameState authority.
    /// Callers should pass the selected living character id (if available) and tapped tile.
    /// GameState validates extraction tile, updates model position, and finalizes mission state.
    func requestExtraction(characterId: UUID?, tileX: Int, tileY: Int) {
        guard !combatEnded else { return }

        guard tileX == extractionX && tileY == extractionY else {
            addLog("That is not the extraction point.")
            return
        }

        guard let id = characterId,
              let char = playerTeam.first(where: { $0.id == id && $0.isAlive }) else {
            addLog("Select a character, then step onto extraction.")
            return
        }

        // Authority write: synchronize model-space position with the tile the player tapped.
        char.positionX = tileX
        char.positionY = tileY

        if !(livingEnemies.isEmpty && pendingSpawns.isEmpty) {
            addLog("Clear all enemies before extraction!")
            return
        }

        checkExtraction()
    }

    /// Centralized mission outcome finalization.
    /// Ensures all victory/defeat paths mutate through GameState and emit one shared completion signal.
    private func finalizeCombat(won: Bool, missionLog: String, terminalLog: String? = nil) {
        guard !combatEnded else { return }
        if won {
            HapticsManager.shared.victory()
        } else {
            HapticsManager.shared.defeat()
        }
        addLog(missionLog)
        finalizeMissionHeat()
        applyFactionAttention(traceTier: traceTier)
        applyGangAttention()
        applyAttentionDecay(traceTier: traceTier)
        addLog(generateWorldReactionMessage())
        addLog(generateCombinedPressurePreview())
        finalizeRewardLayer()
        addLog(generateMissionModifierPreview())
        if let terminalLog {
            addLog(terminalLog)
        }
        addLog(generateMissionEndSummary())
        missionComplete = true
        combatWon = won
        combatEnded = true
        NotificationCenter.default.post(
            name: .combatAction,
            object: nil,
            userInfo: ["result": won ? "victory" : "defeat"]
        )
    }

    /// Heat is mission-boundary consequence state.
    /// v0.1 intentionally has no gameplay effect.
    private func finalizeMissionHeat() {
        let sourceTraceTier = traceTier
        let derivedTier = ConsequenceEngine.heatValue(fromTraceTier: sourceTraceTier)
        missionHeat = derivedTier
        missionHeatTier = ConsequenceEngine.heatTier(fromHeatValue: derivedTier)

        addLog("Mission complete: Heat level \(heatTierLabel) (derived from trace \(traceTierLabel))")
    }

    /// Heat -> world awareness scaffold.
    /// v0.1 only records/logs attention; it does not affect gameplay.
    private func applyFactionAttention(traceTier: Int) {
        let attentionResult = ConsequenceEngine.factionAttentionIncrement(for: missionHeatTier)
        let highTraceBonus = ConsequenceEngine.highTraceCorpEscalationBonus(traceTier: traceTier)
        factionAttention[.corp, default: 0] += attentionResult.increment + highTraceBonus
        didApplyHighTraceEscalationBonusLastMission = highTraceBonus > 0
        addLog(attentionResult.reactionLog)
        if highTraceBonus > 0 {
            addLog("High-profile operation increased corporate escalation risk.")
        }
        addLog("CORP ATTENTION: \(factionAttention[.corp, default: 0])")
    }

    private func applyGangAttention() {
        let increment = ConsequenceEngine.gangAttentionIncrement(for: missionHeatTier)
        factionAttention[.gang, default: 0] += increment
        addLog(generateGangReactionMessage())
        addLog("GANG ATTENTION: \(factionAttention[.gang, default: 0])")
    }

    private func applyAttentionDecay(traceTier: Int) {
        let decayAmount = ConsequenceEngine.attentionDecayAmount(for: traceTier)
        guard decayAmount > 0 else {
            didApplyAttentionRecoveryLastMission = false
            return
        }

        factionAttention[.corp, default: 0] = max(0, factionAttention[.corp, default: 0] - decayAmount)
        factionAttention[.gang, default: 0] = max(0, factionAttention[.gang, default: 0] - decayAmount)
        didApplyAttentionRecoveryLastMission = true
        addLog("Attention reduced due to low-profile mission.")
    }

    private func finalizeRewardLayer() {
        let corpAttention = factionAttention[.corp, default: 0]
        let gangAttention = factionAttention[.gang, default: 0]
        let tier = ConsequenceEngine.rewardTier(
            heatTier: missionHeat,
            corpAttention: corpAttention,
            gangAttention: gangAttention
        )
        let multiplier = ConsequenceEngine.rewardMultiplier(for: tier)
        lastRewardTier = tier
        lastRewardMultiplier = multiplier
        let bonus: Double
        let bonusReason: String
        switch currentMissionType {
        case .stealth:
            if traceTier == 0 {
                bonus = 0.25
                bonusReason = "stealth success"
            } else {
                bonus = 0.0
                bonusReason = "no stealth bonus"
            }
        case .assault:
            if traceTier == 2 {
                bonus = 0.25
                bonusReason = "assault intensity"
            } else {
                bonus = 0.0
                bonusReason = "no assault bonus"
            }
        case .extraction:
            if traceTier == 1 {
                bonus = 0.15
                bonusReason = "balanced extraction"
            } else {
                bonus = 0.0
                bonusReason = "no extraction bonus"
            }
        }
        missionTypeBonusMultiplier = bonus

        addLog("Mission Type: \(missionTypeLabel)")
        addLog("Reward tier: \(rewardTierLabel(tier)) (x\(String(format: "%.2f", multiplier)) payout)")
        if bonus > 0 {
            addLog("Mission bonus: +\(String(format: "%.2f", bonus)) (\(bonusReason))")
        }
        addLog("Final reward multiplier: x\(String(format: "%.2f", finalRewardMultiplier))")
        addLog(generateRewardPayoutSummary())
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
        var candidates: [(Int, Int, Int)] = [] // (x, y, score=hex distance from target)

        for (nx, ny) in hexNeighbors(x: enemy.positionX, y: enemy.positionY) {
            if tileWalkable(x: nx, y: ny, excluding: enemy.id) {
                let newDist = hexDistance(x1: nx, y1: ny, x2: target.positionX, y2: target.positionY)
                candidates.append((nx, ny, newDist))
            }
        }

        if let best = candidates.max(by: { $0.2 < $1.2 }) {
            return (best.0, best.1)
        }
        return (enemy.positionX, enemy.positionY)
    }

    /// BFS pathfinding for drone (hex-aware).
    func bfsPathfindDrone(from enemy: Enemy, towardX gx: Int, y gy: Int) -> (Int, Int)? {
        let sx = enemy.positionX, sy = enemy.positionY
        if hexAdjacent(x1: sx, y1: sy, x2: gx, y2: gy) { return nil }

        struct Node { let x: Int; let y: Int }
        var queue: [Node] = [Node(x: sx, y: sy)]
        var visited: Set<String> = ["\(sx),\(sy)"]
        var i = 0

        while i < queue.count {
            let cur = queue[i]; i += 1
            for (nx, ny) in hexNeighbors(x: cur.x, y: cur.y) {
                let k = "\(nx),\(ny)"
                guard !visited.contains(k), tileWalkable(x: nx, y: ny, excluding: enemy.id) else { continue }
                visited.insert(k)
                if hexAdjacent(x1: nx, y1: ny, x2: gx, y2: gy) || (nx == gx && ny == gy) { return (nx, ny) }
                queue.append(Node(x: nx, y: ny))
            }
        }
        // Fallback: greedy step toward goal using first walkable hex neighbor
        let neighbors = hexNeighbors(x: sx, y: sy)
        let sorted = neighbors.filter { tileWalkable(x: $0.0, y: $0.1, excluding: enemy.id) }
            .sorted { hexDistance(x1: $0.0, y1: $0.1, x2: gx, y2: gy) < hexDistance(x1: $1.0, y1: $1.1, x2: gx, y2: gy) }
        return sorted.first
    }
    /// BFS pathfinding — returns best hex-adjacent tile to move toward target.
    func bfsPathfind(from enemy: Enemy, toward target: Character) -> (Int, Int)? {
        let sx = enemy.positionX, sy = enemy.positionY
        let gx = target.positionX, gy = target.positionY
        if hexAdjacent(x1: sx, y1: sy, x2: gx, y2: gy) { return nil }

        struct Node { let x: Int; let y: Int }
        var queue: [Node] = [Node(x: sx, y: sy)]
        var visited: Set<String> = ["\(sx),\(sy)"]
        var i = 0

        while i < queue.count {
            let cur = queue[i]; i += 1
            for (nx, ny) in hexNeighbors(x: cur.x, y: cur.y) {
                let k = "\(nx),\(ny)"
                guard !visited.contains(k), tileWalkable(x: nx, y: ny, excluding: enemy.id) else { continue }
                visited.insert(k)
                if hexAdjacent(x1: nx, y1: ny, x2: gx, y2: gy) || (nx == gx && ny == gy) { return (nx, ny) }
                queue.append(Node(x: nx, y: ny))
            }
        }
        // Fallback: greedy step toward target using best hex neighbor
        let neighbors = hexNeighbors(x: sx, y: sy)
        let sorted = neighbors.filter { tileWalkable(x: $0.0, y: $0.1, excluding: enemy.id) }
            .sorted { hexDistance(x1: $0.0, y1: $0.1, x2: gx, y2: gy) < hexDistance(x1: $1.0, y1: $1.1, x2: gx, y2: gy) }
        return sorted.first
    }

    /// Find a wounded ally (enemy) within 5 hex tiles to heal.
    func findWoundedAlly(for enemy: Enemy) -> Enemy? {
        let wounded = enemies.filter { ally in
            guard ally.id != enemy.id, ally.isAlive else { return false }
            let dist = hexDistance(x1: ally.positionX, y1: ally.positionY, x2: enemy.positionX, y2: enemy.positionY)
            let isWounded = Double(ally.currentHP) / Double(ally.maxHP) < 0.75  // below 75% HP = wounded
            return dist <= 5 && isWounded
        }
        // Return most wounded ally
        return wounded.min { a, b in
            Double(a.currentHP) / Double(a.maxHP) < Double(b.currentHP) / Double(b.maxHP)
        }
    }

    /// BFS pathfinding to a wounded ally (hex-aware, healer can pass through other enemies).
    func bfsPathfindToWounded(from enemy: Enemy, toward target: Enemy) -> (Int, Int)? {
        let sx = enemy.positionX, sy = enemy.positionY
        let gx = target.positionX, gy = target.positionY
        if hexAdjacent(x1: sx, y1: sy, x2: gx, y2: gy) { return nil }

        struct Node { let x: Int; let y: Int }
        var queue: [Node] = [Node(x: sx, y: sy)]
        var visited: Set<String> = ["\(sx),\(sy)"]
        var i = 0

        while i < queue.count {
            let cur = queue[i]; i += 1
            for (nx, ny) in hexNeighbors(x: cur.x, y: cur.y) {
                let k = "\(nx),\(ny)"
                guard !visited.contains(k), tileWalkableForHealer(x: nx, y: ny, excluding: enemy.id) else { continue }
                visited.insert(k)
                if hexAdjacent(x1: nx, y1: ny, x2: gx, y2: gy) || (nx == gx && ny == gy) { return (nx, ny) }
                queue.append(Node(x: nx, y: ny))
            }
        }
        // Fallback greedy step using best hex neighbor
        let neighbors = hexNeighbors(x: sx, y: sy)
        let sorted = neighbors.filter { tileWalkableForHealer(x: $0.0, y: $0.1, excluding: enemy.id) }
            .sorted { hexDistance(x1: $0.0, y1: $0.1, x2: gx, y2: gy) < hexDistance(x1: $1.0, y1: $1.1, x2: gx, y2: gy) }
        return sorted.first
    }

    /// Check if a tile is walkable for the healer (medic can walk through other enemies).
    func tileWalkableForHealer(x: Int, y: Int, excluding enemyId: UUID) -> Bool {
        let h = currentMissionTiles.isEmpty ? 14 : currentMissionTiles.count
        guard x >= 0, x < TileMap.mapWidth, y >= 0, y < h else { return false }
        // Healer can walk through other enemies (unlike regular pathfinding)
        let playerBlocking = playerTeam.contains { $0.isAlive && $0.positionX == x && $0.positionY == y }
        if playerBlocking { return false }
        guard !currentMissionTiles.isEmpty, y < currentMissionTiles.count, x < currentMissionTiles[y].count else { return true }
        let tileType = currentMissionTiles[y][x]
        return tileType != 1  // walls(1) block; doors(3) are walkable
    }

    /// Expose isDefending for enemyPhase damage check.
    func isCharacterDefending(_ charId: UUID) -> Bool {
        return isDefending && defendingCharacterId == charId
    }

    /// FIX 2: Check if any wall tile intersects the straight line between two tiles.
    /// Uses Bresenham's line algorithm to check each tile along the path.
    /// Returns true if a wall blocks the attack.
    func isLineBlockedByWall(fromX sx: Int, fromY sy: Int, toX dx: Int, toY dy: Int) -> Bool {
        // Bresenham's line algorithm — checks all tiles on the attack path
        var x0 = sx, y0 = sy
        let x1 = dx, y1 = dy

        let dx = abs(x1 - x0)
        let dy = abs(y1 - y0)
        let sx_ = x0 < x1 ? 1 : -1
        let sy_ = y0 < y1 ? 1 : -1
        var err = dx - dy

        while true {
            // Skip the starting tile (attacker's position) and target tile
            if !(x0 == sx && y0 == sy) && !(x0 == x1 && y0 == y1) {
                guard x0 >= 0, x0 < TileMap.mapWidth, y0 >= 0 else { break }
                let h = currentMissionTiles.isEmpty ? 14 : currentMissionTiles.count
                guard y0 < h, x0 < currentMissionTiles[y0].count else { break }
                let tileType = currentMissionTiles[y0][x0]
                if tileType == 1 {  // wall tile
                    return true
                }
            }

            if x0 == x1 && y0 == y1 { break }
            let e2 = 2 * err
            if e2 > -dy {
                err -= dy
                x0 += sx_
            }
            if e2 < dx {
                err += dx
                y0 += sy_
            }
        }
        return false
    }

    func findNextLivingCharacter(after index: Int) -> Character? {
        for i in index..<playerTeam.count {
            if playerTeam[i].isAlive { return playerTeam[i] }
        }
        for i in 0..<index {
            if playerTeam[i].isAlive { return playerTeam[i] }
        }
        return nil
    }

    // MARK: - Hex Grid Helpers

    /// Returns the 6 valid hex neighbors for a flat-top odd-q offset coordinate.
    func hexNeighbors(x: Int, y: Int) -> [(Int, Int)] {
        if x % 2 == 0 {
            return [(x,y-1),(x,y+1),(x-1,y-1),(x-1,y),(x+1,y-1),(x+1,y)]
        } else {
            return [(x,y-1),(x,y+1),(x-1,y),(x-1,y+1),(x+1,y),(x+1,y+1)]
        }
    }

    /// True if (x2,y2) is one of the 6 hex neighbors of (x1,y1).
    func hexAdjacent(x1: Int, y1: Int, x2: Int, y2: Int) -> Bool {
        hexNeighbors(x: x1, y: y1).contains { $0.0 == x2 && $0.1 == y2 }
    }

    /// Hex distance between two tiles using cube coordinate conversion (flat-top odd-q offset).
    func hexDistance(x1: Int, y1: Int, x2: Int, y2: Int) -> Int {
        // flat-top odd-q → cube: cx = x;  cz = y - (x - (x&1))/2;  cy = -cx - cz
        let cx1 = x1
        let cz1 = y1 - (x1 - (x1 & 1)) / 2
        let cy1 = -cx1 - cz1
        let cx2 = x2
        let cz2 = y2 - (x2 - (x2 & 1)) / 2
        let cy2 = -cx2 - cz2
        return max(abs(cx1 - cx2), abs(cy1 - cy2), abs(cz1 - cz2))
    }

    /// Check if a tile is walkable for enemies (not wall/door, not occupied by player or other enemy)
    func tileWalkable(x: Int, y: Int, excluding enemyId: UUID) -> Bool {
        let h = currentMissionTiles.isEmpty ? 14 : currentMissionTiles.count
        guard x >= 0, x < TileMap.mapWidth, y >= 0, y < h else { return false }
        // Check if any player occupies this tile
        let playerBlocking = playerTeam.contains { $0.isAlive && $0.positionX == x && $0.positionY == y }
        if playerBlocking { return false }
        // Check if any OTHER enemy occupies this tile
        let enemyBlocking = enemies.contains { $0.isAlive && $0.id != enemyId && $0.positionX == x && $0.positionY == y }
        if enemyBlocking { return false }
        // Tile type check: walls and doors are impassable; extraction tile (4) is walkable
        guard !currentMissionTiles.isEmpty, y < currentMissionTiles.count, x < currentMissionTiles[y].count else { return true }
        let tileType = currentMissionTiles[y][x]
        return tileType != 1  // walls(1) block movement; doors(3) and extraction(4) are walkable
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

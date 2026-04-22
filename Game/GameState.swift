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
    var sessionState = GameSessionState()

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
    var enemyPhaseCount: Int {  // how many enemy phases have completed (for delayed spawns)
        get { sessionState.enemyPhaseCount }
        set { sessionState.enemyPhaseCount = newValue }
    }
    @Published var isPlayerTurn: Bool = true
    /// When true, blocks player input in BattleScene while enemy phase is running.
    @Published var isPlayerInputBlocked: Bool = false
    /// Guards against double-triggering enemyPhase() within the same frame/turn.
    var isEnemyPhaseRunning: Bool {
        get { sessionState.isEnemyPhaseRunning }
        set { sessionState.isEnemyPhaseRunning = newValue }
    }
    @Published var actionMode: ActionMode = .street
    @Published var playerRole: PlayerRole = .normal
    @Published var selectedMissionPreset: MissionPreset = .standard
    @Published var traceLevel: Int = 0
    var traceThreshold: Int { TraceCadence.threshold(for: selectedMissionPreset) }
    var traceGainPerSignal: Int { TraceCadence.gainPerSignal }
    var traceRecoveryPerLayLow: Int { TraceCadence.recoveryPerLayLow }
    var escalationDamageBonus: Int { TraceCadence.escalationDamageBonus(for: selectedMissionPreset) }
    @Published var traceEscalationLevel: Int = 0
    var hasLoggedTraceTriggerForCurrentRun: Bool {
        get { sessionState.hasLoggedTraceTriggerForCurrentRun }
        set { sessionState.hasLoggedTraceTriggerForCurrentRun = newValue }
    }

    // MARK: - Turn Structure (Issue 1 fix)
    // Track which players have NOT yet acted this round. Empty = all acted = enemy phase.
    var playersWhoHaveNotActed: Set<UUID> {
        get { sessionState.playersWhoHaveNotActed }
        set { sessionState.playersWhoHaveNotActed = newValue }
    }

    /// Reset turn-tracking state at the start of each round.
    func resetTurnTracking() {
        CombatFlowController.resetTurnTracking(gameState: self)
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
        CombatFlowController.beginRound(gameState: self)
    }

    /// SR5 stun recovery: at the start of each round, each living character rolls BOD+WIL.
    /// Each hit reduces stun by 1 (simplified from real SR5 rest-based recovery).
    func recoverStunAtRoundStart() {
        CombatFlowController.recoverStunAtRoundStart(gameState: self)
    }

    // MARK: - Current Mission Tiles (for enemy pathfinding)

    var currentMissionTiles: [[Int]] {
        get { sessionState.currentMissionTiles }
        set { sessionState.currentMissionTiles = newValue }
    }

    // MARK: - Pending Enemy Spawns

    /// Enemies not yet on the map (waiting for their delay timer)
    var pendingSpawns: [PendingSpawn] {
        get { sessionState.pendingSpawns }
        set { sessionState.pendingSpawns = newValue }
    }

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
    var combatWon: Bool? {
        get { sessionState.combatWon }
        set {
            objectWillChange.send()
            sessionState.combatWon = newValue
        }
    }
    @Published var combatEnded: Bool = false
    @Published var currentMissionType: MissionType = .stealth
    var currentMapSituation: MapSituation {
        get { sessionState.currentMapSituation }
        set {
            objectWillChange.send()
            sessionState.currentMapSituation = newValue
        }
    }
    @Published var missionComplete: Bool = false
    var missionHeat: Int {
        get { sessionState.missionHeat }
        set {
            objectWillChange.send()
            sessionState.missionHeat = newValue
        }
    }
    var missionHeatTier: HeatTier {
        get { sessionState.missionHeatTier }
        set {
            objectWillChange.send()
            sessionState.missionHeatTier = newValue
        }
    }
    @Published var factionAttention: [Faction: Int] = [
        .corp: 0,
        .gang: 0,
        .unknown: 0
    ]
    var lastAppliedCorpEnemyModifier: Int {
        get { sessionState.lastAppliedCorpEnemyModifier }
        set {
            objectWillChange.send()
            sessionState.lastAppliedCorpEnemyModifier = newValue
        }
    }
    var lastAppliedGangAmbushRadius: Int {
        get { sessionState.lastAppliedGangAmbushRadius }
        set {
            objectWillChange.send()
            sessionState.lastAppliedGangAmbushRadius = newValue
        }
    }
    var didApplyAttentionRecoveryLastMission: Bool {
        get { sessionState.didApplyAttentionRecoveryLastMission }
        set {
            objectWillChange.send()
            sessionState.didApplyAttentionRecoveryLastMission = newValue
        }
    }
    var didApplyHighTraceEscalationBonusLastMission: Bool {
        get { sessionState.didApplyHighTraceEscalationBonusLastMission }
        set {
            objectWillChange.send()
            sessionState.didApplyHighTraceEscalationBonusLastMission = newValue
        }
    }
    var lastRewardTier: RewardTier {
        get { sessionState.lastRewardTier }
        set {
            objectWillChange.send()
            sessionState.lastRewardTier = newValue
        }
    }
    var lastRewardMultiplier: Double {
        get { sessionState.lastRewardMultiplier }
        set {
            objectWillChange.send()
            sessionState.lastRewardMultiplier = newValue
        }
    }
    var missionTypeBonusMultiplier: Double {
        get { sessionState.missionTypeBonusMultiplier }
        set {
            objectWillChange.send()
            sessionState.missionTypeBonusMultiplier = newValue
        }
    }
    @Published var baseMissionPayout: Int = 100
    var missionTargetTurns: Int {
        get { sessionState.missionTargetTurns }
        set {
            objectWillChange.send()
            sessionState.missionTargetTurns = newValue
        }
    }
    var currentTurnCount: Int {
        get { sessionState.currentTurnCount }
        set {
            objectWillChange.send()
            sessionState.currentTurnCount = newValue
        }
    }
    var missionLoadIndex: Int {
        get { sessionState.missionLoadIndex }
        set { sessionState.missionLoadIndex = newValue }
    }
    var activeCharacter: Character? {
        guard let id = activeCharacterId else { return currentCharacter }
        return playerTeam.first(where: { $0.id == id && $0.isAlive })
    }

    // MARK: - Actions

    @Published var isDefending: Bool = false
    var isItemMenuVisible: Bool {
        get { sessionState.isItemMenuVisible }
        set {
            objectWillChange.send()
            sessionState.isItemMenuVisible = newValue
        }
    }

    /// Which character is currently defending (for turn-scoped defense bonus)
    var defendingCharacterId: UUID? {
        get { sessionState.defendingCharacterId }
        set { sessionState.defendingCharacterId = newValue }
    }

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
        CombatFlowController.performAttack(gameState: self)
    }

    func performLayLow() {
        CombatFlowController.performLayLow(gameState: self)
    }

    // MARK: - Spell Casting

    /// Entry point called from SpellPickerSheet. Validates mage & mana, then dispatches.
    func performSpell(type: SpellType, targetId: UUID? = nil) {
        CombatFlowController.performSpell(gameState: self, type: type, targetId: targetId)
    }

    // MARK: Fireball — AoE Physical

    func castFireball(by mage: Character) {
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

    func castSingleTarget(type: SpellType, targetId: UUID?, by mage: Character) {
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

    func castHeal(by mage: Character) {
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

    func handleEnemyKilled(_ enemy: Enemy, by mage: Character) {
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
        CombatFlowController.performDefend(gameState: self)
    }

    /// Decker HACK: Disables target enemy for 1 round (0 attack dice, can't move).
    /// Uses LOG + spellcasting (hacking is logic-based in Shadowrun).
    func performHack() {
        CombatFlowController.performHack(gameState: self)
    }

    func performHackOnTarget(_ target: Enemy, by decker: Character) {
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
        CombatFlowController.performIntimidate(gameState: self)
    }

    /// Street Sam BLITZ: High-damage melee charge attack. Uses BOD+STR.
    /// More powerful than normal attack but costs extra (BOD damage risk).
    func performBlitz() {
        CombatFlowController.performBlitz(gameState: self)
    }

    func performBlitzOnTarget(_ target: Enemy, by sam: Character) {
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
        CombatFlowController.moveCharacter(gameState: self, id: id, toTileX: tileX, toTileY: tileY)
    }

    func showItemMenu() {
        CombatFlowController.showItemMenu(gameState: self)
    }

    func completeAction(for character: Character) {
        CombatFlowController.completeAction(gameState: self, for: character)
    }

    func endTurn() {
        CombatFlowController.endTurn(gameState: self)
    }

    /// Check if combat is over
    func checkCombatEnd() {
        CombatFlowController.checkCombatEnd(gameState: self)
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

    func finalizeCombatFromCombatFlow(won: Bool, missionLog: String, terminalLog: String? = nil) {
        finalizeCombat(won: won, missionLog: missionLog, terminalLog: terminalLog)
    }

    /// Mission's extraction point — set by setupMission from the mission JSON.
    var extractionX: Int {
        get { sessionState.extractionX }
        set { sessionState.extractionX = newValue }
    }
    var extractionY: Int {
        get { sessionState.extractionY }
        set { sessionState.extractionY = newValue }
    }


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
        CombatFlowController.enemyPhase(gameState: self)
    }

    /// Execute a single enemy's full AI turn synchronously (move + attack).
    /// All notifications are posted synchronously here — animations are scheduled
    /// by BattleScene's observers and played by the SpriteKit run loop.
    func runEnemyAI(enemy: Enemy, livingEnemies: [Enemy]) {
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
        CombatFlowController.isCharacterDefending(gameState: self, charId)
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
        CombatFlowController.showMoveMenu(gameState: self)
    }

    /// Use first available consumable on the active character.
    func performUseItem() {
        CombatFlowController.performUseItem(gameState: self)
    }

    /// Select a character by UUID and update active character.
    func selectCharacter(id: UUID) {
        CombatFlowController.selectCharacter(gameState: self, id: id)
    }

    /// Handle a tap on a tile from BattleScene.
    func handleTileTap(tileX: Int, tileY: Int) {
        CombatFlowController.handleTileTap(gameState: self, tileX: tileX, tileY: tileY)
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

/// Legacy compatibility phase manager retained for older references.
/// Not the primary phase-flow authority; `PhaseManager` is canonical.
/// Future transition rule edits must be made in
/// `docs/architecture/PhaseFlowAuthorityMatrix.md` and mirrored here only
/// for compatibility parity.
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

    /// Compatibility mirror of the canonical matrix for active transitions.
    private func computeNext(from state: GamePhase, event: StateTransition) -> GamePhase {
        switch (state, event) {
        case (.title, .startGame):         return .missionSelect
        case (.missionSelect, .selectMission): return .briefing
        case (.briefing, .beginMission):    return .combat
        case (.combat, .endCombat):        return .debrief
        case (.combat, .returnToTitle):    return .title
        case (.debrief, .returnToTitle):   return .title
        case (_, .returnToTitle):          return .title
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

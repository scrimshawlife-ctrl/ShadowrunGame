import Foundation

struct Check {
    let name: String
    let pass: Bool
    let detail: String
}

func readFile(_ path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
}

func contains(_ needle: String, in haystack: String) -> Bool {
    haystack.contains(needle)
}

let cwd = FileManager.default.currentDirectoryPath
let gameStatePath = cwd + "/Game/GameState.swift"
let missionSetupPath = cwd + "/Game/MissionSetupService.swift"

var checks: [Check] = []

let gameStateExists = FileManager.default.fileExists(atPath: gameStatePath)
let missionSetupExists = FileManager.default.fileExists(atPath: missionSetupPath)

checks.append(Check(name: "GameState file exists", pass: gameStateExists, detail: gameStatePath))
checks.append(Check(name: "MissionSetupService file exists", pass: missionSetupExists, detail: missionSetupPath))

guard gameStateExists, missionSetupExists else {
    for c in checks {
        print("\(c.pass ? "PASS" : "FAIL") - \(c.name): \(c.detail)")
    }
    exit(1)
}

let gameState: String
let missionSetup: String
do {
    gameState = try readFile(gameStatePath)
    missionSetup = try readFile(missionSetupPath)
} catch {
    print("FAIL - Unable to read files: \(error)")
    exit(1)
}

let requiredServiceSignatures = [
    "static func setupMission(gameState: GameState, mission: Mission)",
    "static func setupMultiRoomMission(gameState: GameState, mission: MultiRoomMission)",
    "static func updateTilesForCurrentRoom(gameState: GameState, tiles: [[Int]])",
    "static func assignMissionTypeForCurrentLoad(gameState: GameState)",
    "static func applyMapSituation(",
    "static func tileKey(gameState: GameState, x: Int, y: Int) -> String",
    "static func archetypeForSpawnIndex(gameState: GameState, spawnIndex: Int) -> EnemyArchetype",
    "static func applyEnemyArchetype(gameState: GameState, archetype: EnemyArchetype, to enemy: Enemy)",
    "static func makeEnemy(gameState: GameState, for type: String, archetype: EnemyArchetype) -> Enemy",
    "static func logEnemyComposition(gameState: GameState, totalSpawnCount: Int)",
    "static func applyCorpAttentionEnemyInfluence(",
    "static func applyGangAmbushBias(gameState: GameState, map: [[Int]])",
    "static func processDelayedSpawns(gameState: GameState, enemyPhaseIndex: Int)"
]

for signature in requiredServiceSignatures {
    checks.append(Check(
        name: "MissionSetupService contains required setup body",
        pass: contains(signature, in: missionSetup),
        detail: signature
    ))
}

let forbiddenGameStateBodySnippets = [
    "func setupMission(_ mission: Mission) {\n        print(\"[GameState] setupMission:",
    "func setupMultiRoomMission(_ mission: MultiRoomMission) {\n        print(\"[GameState] setupMultiRoomMission:",
    "func updateTilesForCurrentRoom(_ tiles: [[Int]]) {\n        currentMissionTiles = tiles",
    "func assignMissionTypeForCurrentLoad() {\n        let assignedType: MissionType",
    "func applyMapSituation(\n        to originalMap: [[Int]],\n        extractionPoint: (x: Int, y: Int),\n        protectedTiles: Set<String>\n    ) -> ([[Int]], (x: Int, y: Int)) {\n        guard !originalMap.isEmpty else",
    "func tileKey(x: Int, y: Int) -> String { \"\\(x),\\(y)\" }",
    "func archetypeForSpawnIndex(_ spawnIndex: Int) -> EnemyArchetype {\n        switch currentMissionType",
    "func applyEnemyArchetype(_ archetype: EnemyArchetype, to enemy: Enemy) {\n        enemy.name =",
    "func makeEnemy(for type: String, archetype: EnemyArchetype) -> Enemy {\n        let enemy: Enemy",
    "func logEnemyComposition(totalSpawnCount: Int) {\n        guard totalSpawnCount > 0 else { return }",
    "func applyCorpAttentionEnemyInfluence(spawnTemplates: [(type: String, x: Int, y: Int)], map: [[Int]]) {\n        let modifier = corpAttentionEnemyModifier()",
    "func applyGangAmbushBias(map: [[Int]]) {\n        let gangAttention = factionAttention[.gang, default: 0]",
    "func processDelayedSpawns(enemyPhaseIndex: Int) {\n        let due = pendingSpawns.filter { $0.delayRounds <= enemyPhaseIndex }"
]

for snippet in forbiddenGameStateBodySnippets {
    checks.append(Check(
        name: "GameState does not contain full moved setup body",
        pass: !contains(snippet, in: gameState),
        detail: snippet.components(separatedBy: "\n").first ?? snippet
    ))
}

let requiredGameStateShims = [
    "func setupMission(_ mission: Mission) {\n        MissionSetupService.setupMission(gameState: self, mission: mission)",
    "func setupMultiRoomMission(_ mission: MultiRoomMission) {\n        MissionSetupService.setupMultiRoomMission(gameState: self, mission: mission)",
    "func updateTilesForCurrentRoom(_ tiles: [[Int]]) {\n        MissionSetupService.updateTilesForCurrentRoom(gameState: self, tiles: tiles)",
    "func assignMissionTypeForCurrentLoad() {\n        MissionSetupService.assignMissionTypeForCurrentLoad(gameState: self)",
    "func applyMapSituation(",
    "func tileKey(x: Int, y: Int) -> String {\n        MissionSetupService.tileKey(gameState: self, x: x, y: y)",
    "func archetypeForSpawnIndex(_ spawnIndex: Int) -> EnemyArchetype {\n        MissionSetupService.archetypeForSpawnIndex(gameState: self, spawnIndex: spawnIndex)",
    "func applyEnemyArchetype(_ archetype: EnemyArchetype, to enemy: Enemy) {\n        MissionSetupService.applyEnemyArchetype(gameState: self, archetype: archetype, to: enemy)",
    "func makeEnemy(for type: String, archetype: EnemyArchetype) -> Enemy {\n        MissionSetupService.makeEnemy(gameState: self, for: type, archetype: archetype)",
    "func logEnemyComposition(totalSpawnCount: Int) {\n        MissionSetupService.logEnemyComposition(gameState: self, totalSpawnCount: totalSpawnCount)",
    "func applyCorpAttentionEnemyInfluence(spawnTemplates: [(type: String, x: Int, y: Int)], map: [[Int]]) {\n        MissionSetupService.applyCorpAttentionEnemyInfluence(gameState: self, spawnTemplates: spawnTemplates, map: map)",
    "func applyGangAmbushBias(map: [[Int]]) {\n        MissionSetupService.applyGangAmbushBias(gameState: self, map: map)",
    "func processDelayedSpawns(enemyPhaseIndex: Int) {\n        MissionSetupService.processDelayedSpawns(gameState: self, enemyPhaseIndex: enemyPhaseIndex)"
]

for shim in requiredGameStateShims {
    checks.append(Check(
        name: "GameState shim delegates to MissionSetupService",
        pass: contains(shim, in: gameState),
        detail: shim.components(separatedBy: "\n").first ?? shim
    ))
}

let applyMapSituationShim = """
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
"""
checks.append(Check(
    name: "GameState applyMapSituation shim delegates to MissionSetupService",
    pass: contains(applyMapSituationShim, in: gameState),
    detail: "func applyMapSituation(...) -> MissionSetupService.applyMapSituation(...)"
))

var failed = false
for c in checks {
    print("\(c.pass ? "PASS" : "FAIL") - \(c.name): \(c.detail)")
    if !c.pass { failed = true }
}

exit(failed ? 1 : 0)

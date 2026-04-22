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
let controllerPath = cwd + "/Game/CombatFlowController.swift"

var checks: [Check] = []

let gameStateExists = FileManager.default.fileExists(atPath: gameStatePath)
let controllerExists = FileManager.default.fileExists(atPath: controllerPath)

checks.append(Check(name: "GameState file exists", pass: gameStateExists, detail: gameStatePath))
checks.append(Check(name: "CombatFlowController file exists", pass: controllerExists, detail: controllerPath))

guard gameStateExists, controllerExists else {
    for c in checks {
        print((c.pass ? "PASS" : "FAIL") + " - " + c.name + ": " + c.detail)
    }
    exit(1)
}

let gameState: String
let controller: String
do {
    gameState = try readFile(gameStatePath)
    controller = try readFile(controllerPath)
} catch {
    print("FAIL - Unable to read files: \(error)")
    exit(1)
}

// 2) Controller must contain full logic bodies.
let requiredControllerBodies = [
    "static func beginRound(gameState: GameState) {\n        CombatFlowController.resetTurnTracking(gameState: gameState)",
    "static func resetTurnTracking(gameState: GameState) {\n        // Stunned characters auto-skip their turn",
    "static func recoverStunAtRoundStart(gameState: GameState) {\n        for char in gameState.playerTeam where char.isAlive && char.currentStun > 0",
    "static func completeAction(gameState: GameState, for character: Character) {\n        // Set active to this character so endTurn() marks the right one",
    "static func endTurn(gameState: GameState) {\n        // NOTE: Do NOT set isPlayerTurn=false or block input here unless we're actually",
    "static func enemyPhase(gameState: GameState) {\n        guard !gameState.isEnemyPhaseRunning else { return }",
    "static func checkCombatEnd(gameState: GameState) {\n        if gameState.currentMissionType == .assault && gameState.livingEnemies.isEmpty && gameState.pendingSpawns.isEmpty",
    "static func isCharacterDefending(gameState: GameState, _ charId: UUID) -> Bool {\n        return gameState.isDefending && gameState.defendingCharacterId == charId",
    "static func performAttack(gameState: GameState) {\n        let attacker: Character?",
    "static func performLayLow(gameState: GameState) {\n        let actor: Character?",
    "static func performSpell(gameState: GameState, type: SpellType, targetId: UUID? = nil) {\n        // Resolve caster",
    "static func performDefend(gameState: GameState) {\n        let char: Character",
    "static func performHack(gameState: GameState) {\n        let char: Character?",
    "static func performIntimidate(gameState: GameState) {\n        let char: Character?",
    "static func performBlitz(gameState: GameState) {\n        let char: Character?",
    "static func performUseItem(gameState: GameState) {\n        let char: Character",
    "static func moveCharacter(gameState: GameState, id: UUID, toTileX tileX: Int, toTileY tileY: Int) {\n        guard let char = gameState.playerTeam.first(where: { $0.id == id && $0.isAlive }) else { return }",
    "static func selectCharacter(gameState: GameState, id: UUID) {\n        if let char = gameState.playerTeam.first(where: { $0.id == id }) {",
    "static func handleTileTap(gameState: GameState, tileX: Int, tileY: Int) {\n        if let char = gameState.playerTeam.first(where: { $0.positionX == tileX && $0.positionY == tileY && $0.isAlive }) {",
    "static func showMoveMenu(gameState: GameState) {\n        let char: Character",
    "static func showItemMenu(gameState: GameState) {\n        gameState.isItemMenuVisible = true"
]

for body in requiredControllerBodies {
    checks.append(Check(
        name: "CombatFlowController contains full logic body",
        pass: contains(body, in: controller),
        detail: body.components(separatedBy: "\n").first ?? body
    ))
}

// 3) GameState must not contain old full bodies for moved methods.
let forbiddenGameStateBodies = [
    "func beginRound() {\n        resetTurnTracking()",
    "func resetTurnTracking() {\n        // Stunned characters auto-skip their turn",
    "func recoverStunAtRoundStart() {\n        for char in playerTeam where char.isAlive && char.currentStun > 0",
    "func completeAction(for character: Character) {\n        // Set active to this character so endTurn() marks the right one",
    "func endTurn() {\n        // NOTE: Do NOT set isPlayerTurn=false or block input here unless we're actually",
    "func enemyPhase() {\n        guard !isEnemyPhaseRunning else { return }",
    "func checkCombatEnd() {\n        if currentMissionType == .assault && livingEnemies.isEmpty && pendingSpawns.isEmpty",
    "func isCharacterDefending(_ charId: UUID) -> Bool {\n        return isDefending && defendingCharacterId == charId",
    "func performAttack() {\n        let attacker: Character?",
    "func performLayLow() {\n        let actor: Character?",
    "func performSpell(type: SpellType, targetId: UUID? = nil) {\n        // Resolve caster",
    "func performDefend() {\n        let char: Character",
    "func performHack() {\n        let char: Character?",
    "func performIntimidate() {\n        let char: Character?",
    "func performBlitz() {\n        let char: Character?",
    "func performUseItem() {\n        let char: Character",
    "func moveCharacter(id: UUID, toTileX tileX: Int, toTileY tileY: Int) {\n        guard let char = playerTeam.first(where: { $0.id == id && $0.isAlive }) else { return }",
    "func selectCharacter(id: UUID) {\n        if let char = playerTeam.first(where: { $0.id == id }) {",
    "func handleTileTap(tileX: Int, tileY: Int) {\n        if let char = playerTeam.first(where: { $0.positionX == tileX && $0.positionY == tileY && $0.isAlive }) {",
    "func showMoveMenu() {\n        let char: Character",
    "func showItemMenu() {\n        isItemMenuVisible = true"
]

for snippet in forbiddenGameStateBodies {
    checks.append(Check(
        name: "GameState does not contain moved full body",
        pass: !contains(snippet, in: gameState),
        detail: snippet.components(separatedBy: "\n").first ?? snippet
    ))
}

// 4) GameState must contain thin delegating shims for moved methods.
let requiredShims = [
    "func beginRound() {\n        CombatFlowController.beginRound(gameState: self)",
    "func resetTurnTracking() {\n        CombatFlowController.resetTurnTracking(gameState: self)",
    "func recoverStunAtRoundStart() {\n        CombatFlowController.recoverStunAtRoundStart(gameState: self)",
    "func completeAction(for character: Character) {\n        CombatFlowController.completeAction(gameState: self, for: character)",
    "func endTurn() {\n        CombatFlowController.endTurn(gameState: self)",
    "func enemyPhase() {\n        CombatFlowController.enemyPhase(gameState: self)",
    "func checkCombatEnd() {\n        CombatFlowController.checkCombatEnd(gameState: self)",
    "func isCharacterDefending(_ charId: UUID) -> Bool {\n        CombatFlowController.isCharacterDefending(gameState: self, charId)",
    "func performAttack() {\n        CombatFlowController.performAttack(gameState: self)",
    "func performLayLow() {\n        CombatFlowController.performLayLow(gameState: self)",
    "func performSpell(type: SpellType, targetId: UUID? = nil) {\n        CombatFlowController.performSpell(gameState: self, type: type, targetId: targetId)",
    "func performDefend() {\n        CombatFlowController.performDefend(gameState: self)",
    "func performHack() {\n        CombatFlowController.performHack(gameState: self)",
    "func performIntimidate() {\n        CombatFlowController.performIntimidate(gameState: self)",
    "func performBlitz() {\n        CombatFlowController.performBlitz(gameState: self)",
    "func performUseItem() {\n        CombatFlowController.performUseItem(gameState: self)",
    "func moveCharacter(id: UUID, toTileX tileX: Int, toTileY tileY: Int) {\n        CombatFlowController.moveCharacter(gameState: self, id: id, toTileX: tileX, toTileY: tileY)",
    "func selectCharacter(id: UUID) {\n        CombatFlowController.selectCharacter(gameState: self, id: id)",
    "func handleTileTap(tileX: Int, tileY: Int) {\n        CombatFlowController.handleTileTap(gameState: self, tileX: tileX, tileY: tileY)",
    "func showMoveMenu() {\n        CombatFlowController.showMoveMenu(gameState: self)",
    "func showItemMenu() {\n        CombatFlowController.showItemMenu(gameState: self)"
]

for shim in requiredShims {
    checks.append(Check(
        name: "GameState shim delegates to CombatFlowController",
        pass: contains(shim, in: gameState),
        detail: shim.components(separatedBy: "\n").first ?? shim
    ))
}

// 5) Explicit allow-list checks for intentional bridges/helpers retained in GameState.
let allowedRetainedSignatures = [
    "func finalizeCombatFromCombatFlow(won: Bool, missionLog: String, terminalLog: String? = nil)",
    "func castFireball(by mage: Character)",
    "func castSingleTarget(type: SpellType, targetId: UUID?, by mage: Character)",
    "func castHeal(by mage: Character)",
    "func handleEnemyKilled(_ enemy: Enemy, by mage: Character)",
    "func performHackOnTarget(_ target: Enemy, by decker: Character)",
    "func performBlitzOnTarget(_ target: Enemy, by sam: Character)",
    "func runEnemyAI(enemy: Enemy, livingEnemies: [Enemy])"
]

for sig in allowedRetainedSignatures {
    checks.append(Check(
        name: "Allowed bridge/helper retained in GameState",
        pass: contains(sig, in: gameState),
        detail: sig
    ))
}

var failed = false
for c in checks {
    print((c.pass ? "PASS" : "FAIL") + " - " + c.name + ": " + c.detail)
    if !c.pass { failed = true }
}

exit(failed ? 1 : 0)

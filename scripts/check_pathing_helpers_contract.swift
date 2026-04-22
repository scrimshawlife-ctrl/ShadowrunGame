import Foundation

struct Check {
    let name: String
    let pass: Bool
    let detail: String
}

func readFile(_ path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
}

let cwd = FileManager.default.currentDirectoryPath
let gameStatePath = cwd + "/Game/GameState.swift"
let helpersPath = cwd + "/Game/PathingAndAIHelpers.swift"

var checks: [Check] = []

let gameStateExists = FileManager.default.fileExists(atPath: gameStatePath)
let helpersExists = FileManager.default.fileExists(atPath: helpersPath)

checks.append(Check(name: "GameState file exists", pass: gameStateExists, detail: gameStatePath))
checks.append(Check(name: "PathingAndAIHelpers file exists", pass: helpersExists, detail: helpersPath))

guard gameStateExists, helpersExists else {
    for c in checks {
        print("\(c.pass ? "PASS" : "FAIL") - \(c.name): \(c.detail)")
    }
    exit(1)
}

let gameState: String
let helpers: String
do {
    gameState = try readFile(gameStatePath)
    helpers = try readFile(helpersPath)
} catch {
    print("FAIL - Unable to read files: \(error)")
    exit(1)
}

func contains(_ needle: String, in haystack: String) -> Bool {
    haystack.contains(needle)
}

let helperSignatures = [
    "static func hexNeighbors(gameState: GameState",
    "static func hexAdjacent(gameState: GameState",
    "static func hexDistance(gameState: GameState",
    "static func tileWalkable(gameState: GameState",
    "static func tileWalkableForHealer(gameState: GameState",
    "static func isLineBlockedByWall(gameState: GameState",
    "static func bfsPathfind(gameState: GameState",
    "static func bfsPathfindDrone(gameState: GameState",
    "static func bfsPathfindToWounded(gameState: GameState",
    "static func bestRetreatTile(gameState: GameState",
    "static func findWoundedAlly(gameState: GameState",
    "static func distanceToNearestPlayer(gameState: GameState",
    "static func findNextLivingCharacter(gameState: GameState"
]

for sig in helperSignatures {
    checks.append(Check(name: "Helper body exists in PathingAndAIHelpers", pass: contains(sig, in: helpers), detail: sig))
}

let forbiddenGameStateBodies = [
    "func hexNeighbors(x: Int, y: Int) -> [(Int, Int)] {\n        if x % 2 == 0",
    "func hexAdjacent(x1: Int, y1: Int, x2: Int, y2: Int) -> Bool {\n        hexNeighbors",
    "func hexDistance(x1: Int, y1: Int, x2: Int, y2: Int) -> Int {\n        // flat-top odd-q",
    "func tileWalkable(x: Int, y: Int, excluding enemyId: UUID) -> Bool {\n        let h = currentMissionTiles",
    "func tileWalkableForHealer(x: Int, y: Int, excluding enemyId: UUID) -> Bool {\n        let h = currentMissionTiles",
    "func isLineBlockedByWall(fromX sx: Int, fromY sy: Int, toX dx: Int, toY dy: Int) -> Bool {\n        // Bresenham",
    "func bfsPathfind(from enemy: Enemy, toward target: Character) -> (Int, Int)? {\n        let sx = enemy.positionX",
    "func bfsPathfindDrone(from enemy: Enemy, towardX gx: Int, y gy: Int) -> (Int, Int)? {\n        let sx = enemy.positionX",
    "func bfsPathfindToWounded(from enemy: Enemy, toward target: Enemy) -> (Int, Int)? {\n        let sx = enemy.positionX",
    "func bestRetreatTile(for enemy: Enemy, awayFrom target: Character) -> (Int, Int) {\n        var candidates",
    "func findWoundedAlly(for enemy: Enemy) -> Enemy? {\n        let wounded = enemies.filter",
    "func distanceToNearestPlayer(x: Int, y: Int) -> Int {\n        let living = playerTeam",
    "func findNextLivingCharacter(after index: Int) -> Character? {\n        for i in index..<playerTeam.count"
]

for snippet in forbiddenGameStateBodies {
    checks.append(Check(name: "GameState no longer contains moved full body", pass: !contains(snippet, in: gameState), detail: snippet.components(separatedBy: "\\n").first ?? snippet))
}

let requiredShims = [
    "func hexNeighbors(x: Int, y: Int) -> [(Int, Int)] {\n        PathingAndAIHelpers.hexNeighbors(gameState: self, x: x, y: y)",
    "func hexAdjacent(x1: Int, y1: Int, x2: Int, y2: Int) -> Bool {\n        PathingAndAIHelpers.hexAdjacent(gameState: self, x1: x1, y1: y1, x2: x2, y2: y2)",
    "func hexDistance(x1: Int, y1: Int, x2: Int, y2: Int) -> Int {\n        PathingAndAIHelpers.hexDistance(gameState: self, x1: x1, y1: y1, x2: x2, y2: y2)",
    "func tileWalkable(x: Int, y: Int, excluding enemyId: UUID) -> Bool {\n        PathingAndAIHelpers.tileWalkable(gameState: self, x: x, y: y, excluding: enemyId)",
    "func tileWalkableForHealer(x: Int, y: Int, excluding enemyId: UUID) -> Bool {\n        PathingAndAIHelpers.tileWalkableForHealer(gameState: self, x: x, y: y, excluding: enemyId)",
    "func isLineBlockedByWall(fromX sx: Int, fromY sy: Int, toX dx: Int, toY dy: Int) -> Bool {\n        PathingAndAIHelpers.isLineBlockedByWall(gameState: self, fromX: sx, fromY: sy, toX: dx, toY: dy)",
    "func bfsPathfind(from enemy: Enemy, toward target: Character) -> (Int, Int)? {\n        PathingAndAIHelpers.bfsPathfind(gameState: self, from: enemy, toward: target)",
    "func bfsPathfindDrone(from enemy: Enemy, towardX gx: Int, y gy: Int) -> (Int, Int)? {\n        PathingAndAIHelpers.bfsPathfindDrone(gameState: self, from: enemy, towardX: gx, y: gy)",
    "func bfsPathfindToWounded(from enemy: Enemy, toward target: Enemy) -> (Int, Int)? {\n        PathingAndAIHelpers.bfsPathfindToWounded(gameState: self, from: enemy, toward: target)",
    "func bestRetreatTile(for enemy: Enemy, awayFrom target: Character) -> (Int, Int) {\n        PathingAndAIHelpers.bestRetreatTile(gameState: self, for: enemy, awayFrom: target)",
    "func findWoundedAlly(for enemy: Enemy) -> Enemy? {\n        PathingAndAIHelpers.findWoundedAlly(gameState: self, for: enemy)",
    "func distanceToNearestPlayer(x: Int, y: Int) -> Int {\n        PathingAndAIHelpers.distanceToNearestPlayer(gameState: self, x: x, y: y)",
    "func findNextLivingCharacter(after index: Int) -> Character? {\n        PathingAndAIHelpers.findNextLivingCharacter(gameState: self, after: index)"
]

for shim in requiredShims {
    checks.append(Check(name: "GameState thin wrapper routes to PathingAndAIHelpers", pass: contains(shim, in: gameState), detail: shim.components(separatedBy: "\\n").first ?? shim))
}

var failed = false
for c in checks {
    print("\(c.pass ? "PASS" : "FAIL") - \(c.name): \(c.detail)")
    if !c.pass { failed = true }
}

exit(failed ? 1 : 0)

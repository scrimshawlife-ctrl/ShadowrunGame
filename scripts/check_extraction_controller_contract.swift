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
let extractionControllerPath = cwd + "/Game/ExtractionController.swift"

var checks: [Check] = []

let gameStateExists = FileManager.default.fileExists(atPath: gameStatePath)
let extractionControllerExists = FileManager.default.fileExists(atPath: extractionControllerPath)

checks.append(Check(name: "GameState file exists", pass: gameStateExists, detail: gameStatePath))
checks.append(Check(name: "ExtractionController file exists", pass: extractionControllerExists, detail: extractionControllerPath))

guard gameStateExists, extractionControllerExists else {
    for c in checks {
        print("\(c.pass ? "PASS" : "FAIL") - \(c.name): \(c.detail)")
    }
    exit(1)
}

let gameState: String
let extractionController: String
do {
    gameState = try readFile(gameStatePath)
    extractionController = try readFile(extractionControllerPath)
} catch {
    print("FAIL - Unable to read files: \(error)")
    exit(1)
}

let requiredControllerBodies = [
    """
    static func checkExtraction(gameState: GameState) {
            guard gameState.currentMissionType == .extraction else { return }
    """,
    """
    static func requestExtraction(
            gameState: GameState,
            characterId: UUID?,
            tileX: Int,
            tileY: Int
        ) -> Bool {
            guard !gameState.combatEnded else { return false }
    """
]

for body in requiredControllerBodies {
    checks.append(Check(
        name: "ExtractionController contains extraction body",
        pass: contains(body, in: extractionController),
        detail: body.components(separatedBy: "\n").first ?? body
    ))
}

let requiredCoordinateHelpers = [
    "static func extractionObjective(gameState: GameState) -> (x: Int, y: Int)",
    "static func setExtractionObjective(gameState: GameState, x: Int, y: Int)"
]

for helper in requiredCoordinateHelpers {
    checks.append(Check(
        name: "ExtractionController coordinate helper exists",
        pass: contains(helper, in: extractionController),
        detail: helper
    ))
}

let forbiddenGameStateBodies = [
    "func checkExtraction() {\n        guard currentMissionType == .extraction else { return }",
    "func requestExtraction(characterId: UUID?, tileX: Int, tileY: Int) {\n        guard !combatEnded else { return }",
    "func requestExtraction(characterId: UUID?, tileX: Int, tileY: Int) -> Bool {\n        guard !combatEnded else { return false }"
]

for snippet in forbiddenGameStateBodies {
    checks.append(Check(
        name: "GameState does not contain full extraction body",
        pass: !contains(snippet, in: gameState),
        detail: snippet.components(separatedBy: "\n").first ?? snippet
    ))
}

let requiredShims = [
    "func checkExtraction() {\n        ExtractionController.checkExtraction(gameState: self)",
    """
    func requestExtraction(characterId: UUID?, tileX: Int, tileY: Int) -> Bool {
            ExtractionController.requestExtraction(
                gameState: self,
                characterId: characterId,
                tileX: tileX,
                tileY: tileY
            )
        }
    """
]

for shim in requiredShims {
    checks.append(Check(
        name: "GameState extraction shim delegates to ExtractionController",
        pass: contains(shim, in: gameState),
        detail: shim.components(separatedBy: "\n").first ?? shim
    ))
}

var failed = false
for c in checks {
    print("\(c.pass ? "PASS" : "FAIL") - \(c.name): \(c.detail)")
    if !c.pass { failed = true }
}

exit(failed ? 1 : 0)

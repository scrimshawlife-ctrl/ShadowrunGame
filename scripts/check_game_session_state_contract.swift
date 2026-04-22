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
let sessionStatePath = cwd + "/Game/GameSessionState.swift"

var checks: [Check] = []

let gameStateExists = FileManager.default.fileExists(atPath: gameStatePath)
let sessionStateExists = FileManager.default.fileExists(atPath: sessionStatePath)

checks.append(Check(name: "GameState file exists", pass: gameStateExists, detail: gameStatePath))
checks.append(Check(name: "GameSessionState file exists", pass: sessionStateExists, detail: sessionStatePath))

guard gameStateExists, sessionStateExists else {
    for c in checks {
        print((c.pass ? "PASS" : "FAIL") + " - " + c.name + ": " + c.detail)
    }
    exit(1)
}

let gameState: String
let sessionState: String
do {
    gameState = try readFile(gameStatePath)
    sessionState = try readFile(sessionStatePath)
} catch {
    print("FAIL - Unable to read files: \(error)")
    exit(1)
}

let proxyManagedFields: [(name: String, typeSig: String)] = [
    ("lastAppliedCorpEnemyModifier", "Int"),
    ("lastAppliedGangAmbushRadius", "Int"),
    ("didApplyAttentionRecoveryLastMission", "Bool"),
    ("didApplyHighTraceEscalationBonusLastMission", "Bool"),
    ("lastRewardTier", "RewardTier"),
    ("lastRewardMultiplier", "Double"),
    ("missionTypeBonusMultiplier", "Double"),
    ("combatWon", "Bool?"),
    ("currentMapSituation", "MapSituation"),
    ("missionHeat", "Int"),
    ("missionHeatTier", "HeatTier"),
    ("missionTargetTurns", "Int"),
    ("currentTurnCount", "Int"),
    ("isItemMenuVisible", "Bool")
]

for (field, typeSig) in proxyManagedFields {
    // 2) Field must exist as stored var in GameSessionState
    let sessionStored = "var \(field): \(typeSig)"
    checks.append(Check(
        name: "GameSessionState contains extracted field",
        pass: contains(sessionStored, in: sessionState),
        detail: sessionStored
    ))

    // 3) Field must NOT exist as stored var in GameState
    let forbiddenStoredPublished = "@Published var \(field):"
    let forbiddenStoredPlain = "var \(field): \(typeSig) ="
    checks.append(Check(
        name: "GameState does not store extracted field as @Published",
        pass: !contains(forbiddenStoredPublished, in: gameState),
        detail: forbiddenStoredPublished
    ))
    checks.append(Check(
        name: "GameState does not store extracted field as plain stored var",
        pass: !contains(forbiddenStoredPlain, in: gameState),
        detail: forbiddenStoredPlain
    ))

    // 4) GameState must expose computed proxy with objectWillChange in setter
    let computedStart = "var \(field): \(typeSig) {"
    checks.append(Check(
        name: "GameState exposes computed proxy",
        pass: contains(computedStart, in: gameState),
        detail: computedStart
    ))

    let getterNeedle = "get { sessionState.\(field) }"
    checks.append(Check(
        name: "GameState proxy getter reads sessionState",
        pass: contains(getterNeedle, in: gameState),
        detail: getterNeedle
    ))

    // setter contract: objectWillChange + sessionState write
    let setterBlockNeedle = "set {\n            objectWillChange.send()\n            sessionState.\(field) = newValue"
    checks.append(Check(
        name: "GameState proxy setter triggers observation and forwards write",
        pass: contains(setterBlockNeedle, in: gameState),
        detail: "set { objectWillChange.send(); sessionState.\(field) = newValue }"
    ))
}

var failed = false
for c in checks {
    print((c.pass ? "PASS" : "FAIL") + " - " + c.name + ": " + c.detail)
    if !c.pass { failed = true }
}

exit(failed ? 1 : 0)

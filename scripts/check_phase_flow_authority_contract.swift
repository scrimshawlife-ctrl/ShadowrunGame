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
let appPath = cwd + "/ShadowrunGameApp.swift"
let matrixPath = cwd + "/docs/architecture/PhaseFlowAuthorityMatrix.md"

var checks: [Check] = []

let gameStateExists = FileManager.default.fileExists(atPath: gameStatePath)
let appExists = FileManager.default.fileExists(atPath: appPath)
let matrixExists = FileManager.default.fileExists(atPath: matrixPath)

checks.append(Check(name: "GameState file exists", pass: gameStateExists, detail: gameStatePath))
checks.append(Check(name: "ShadowrunGameApp file exists", pass: appExists, detail: appPath))
checks.append(Check(name: "PhaseFlowAuthorityMatrix doc exists", pass: matrixExists, detail: matrixPath))

guard gameStateExists, appExists, matrixExists else {
    for c in checks {
        print((c.pass ? "PASS" : "FAIL") + " - " + c.name + ": " + c.detail)
    }
    exit(1)
}

let gameState: String
let app: String
let matrix: String
do {
    gameState = try readFile(gameStatePath)
    app = try readFile(appPath)
    matrix = try readFile(matrixPath)
} catch {
    print("FAIL - Unable to read required files: \(error)")
    exit(1)
}

// 2) Canonical authority marker for PhaseManager
checks.append(Check(
    name: "PhaseManager documented as canonical authority",
    pass: contains("Canonical active phase-flow authority", in: app),
    detail: "Canonical active phase-flow authority"
))
checks.append(Check(
    name: "PhaseManager comment references canonical matrix",
    pass: contains("PhaseFlowAuthorityMatrix.md", in: app),
    detail: "PhaseFlowAuthorityMatrix.md"
))

// 3) Legacy/compat marker for GameStateManager
checks.append(Check(
    name: "GameStateManager documented as legacy compatibility manager",
    pass: contains("Legacy compatibility phase manager", in: gameState),
    detail: "Legacy compatibility phase manager"
))
checks.append(Check(
    name: "GameStateManager comment states PhaseManager is canonical",
    pass: contains("`PhaseManager` is canonical", in: gameState),
    detail: "`PhaseManager` is canonical"
))

// Matrix sanity marker
checks.append(Check(
    name: "Canonical matrix document version present",
    pass: contains("# PhaseFlowAuthority v0.2", in: matrix),
    detail: "# PhaseFlowAuthority v0.2"
))

let gameStateManagerTransitionCases = [
    "case (.title, .startGame):",
    "case (.missionSelect, .selectMission):",
    "case (.briefing, .beginMission):",
    "case (.combat, .endCombat):",
    "case (.combat, .returnToTitle):",
    "case (.debrief, .returnToTitle):",
    "case (_, .returnToTitle):",
    "default:                            return state"
]

for transitionCase in gameStateManagerTransitionCases {
    checks.append(Check(
        name: "GameStateManager contains active transition rule",
        pass: contains(transitionCase, in: gameState),
        detail: transitionCase
    ))
}

let phaseManagerTransitionCases = [
    "case (.title, .startGame):",
    "case (.missionSelect, .selectMission):",
    "case (.briefing, .beginMission):",
    "case (.combat, .endCombat):",
    "case (.combat, .returnToTitle):",
    "case (.debrief, .returnToTitle):",
    "case (_, .returnToTitle):",
    "default:                                 return state"
]

for transitionCase in phaseManagerTransitionCases {
    checks.append(Check(
        name: "PhaseManager contains active transition rule",
        pass: contains(transitionCase, in: app),
        detail: transitionCase
    ))
}

var failed = false
for c in checks {
    print((c.pass ? "PASS" : "FAIL") + " - " + c.name + ": " + c.detail)
    if !c.pass { failed = true }
}

exit(failed ? 1 : 0)

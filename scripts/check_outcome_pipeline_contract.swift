import Foundation

struct Check {
    let name: String
    let pass: Bool
    let detail: String
}

func load(_ path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
}

let repo = FileManager.default.currentDirectoryPath
let gameStatePath = repo + "/Game/GameState.swift"
let pipelinePath = repo + "/Game/OutcomePipeline.swift"

var checks: [Check] = []

let gameStateExists = FileManager.default.fileExists(atPath: gameStatePath)
checks.append(Check(name: "GameState file exists", pass: gameStateExists, detail: gameStatePath))

let pipelineExists = FileManager.default.fileExists(atPath: pipelinePath)
checks.append(Check(name: "OutcomePipeline file exists", pass: pipelineExists, detail: pipelinePath))

guard gameStateExists, pipelineExists else {
    for c in checks {
        print("\(c.pass ? "PASS" : "FAIL") - \(c.name): \(c.detail)")
    }
    exit(1)
}

let gameState: String
let pipeline: String
do {
    gameState = try load(gameStatePath)
    pipeline = try load(pipelinePath)
} catch {
    print("FAIL - Unable to read source files: \(error)")
    exit(1)
}

func has(_ text: String, in source: String) -> Bool { source.contains(text) }

// Core ownership checks
checks.append(Check(
    name: "OutcomePipeline.execute exists",
    pass: has("static func execute(", in: pipeline),
    detail: "static func execute"
))

checks.append(Check(
    name: "GameState.finalizeCombat delegates to OutcomePipeline.execute",
    pass: has("private func finalizeCombat", in: gameState) && has("OutcomePipeline.execute(", in: gameState),
    detail: "finalizeCombat -> OutcomePipeline.execute"
))

// Ensure moved stage helpers are no longer full bodies in GameState
let forbiddenInGameState = [
    "func finalizeMissionHeat(",
    "func applyFactionAttention(",
    "func applyGangAttention(",
    "func applyAttentionDecay(",
    "func finalizeRewardLayer("
]
for symbol in forbiddenInGameState {
    checks.append(Check(
        name: "GameState does not contain full body for \(symbol)",
        pass: !has(symbol, in: gameState),
        detail: symbol
    ))
}

// Stage helpers must exist in OutcomePipeline
let requiredStageHelpers = [
    "static func finalizeMissionHeat(gameState: GameState)",
    "static func applyFactionAttention(gameState: GameState, traceTier: Int)",
    "static func applyGangAttention(gameState: GameState)",
    "static func applyAttentionDecay(gameState: GameState, traceTier: Int)",
    "static func finalizeRewardLayer(gameState: GameState)"
]
for symbol in requiredStageHelpers {
    checks.append(Check(name: "OutcomePipeline contains \(symbol)", pass: has(symbol, in: pipeline), detail: symbol))
}

// Projection helper bodies must exist in OutcomePipeline
let requiredProjectionHelpers = [
    "static func generateWorldReactionMessage(gameState: GameState)",
    "static func generateMissionModifierPreview(gameState: GameState)",
    "static func generateGangReactionMessage(gameState: GameState)",
    "static func generateGangMissionPreview(gameState: GameState)",
    "static func generateCombinedPressurePreview(gameState: GameState)",
    "static func rewardTierLabel(_ tier: RewardTier)",
    "static func generateRewardPreview(gameState: GameState)",
    "static func generateRewardPayoutSummary(gameState: GameState)",
    "static func generateMissionEndSummary(gameState: GameState)"
]
for symbol in requiredProjectionHelpers {
    checks.append(Check(name: "OutcomePipeline contains \(symbol)", pass: has(symbol, in: pipeline), detail: symbol))
}

// GameState compatibility shims route through OutcomePipeline
let requiredShimCalls = [
    "func generateWorldReactionMessage() -> String {\n        OutcomePipeline.generateWorldReactionMessage(gameState: self)",
    "func generateMissionModifierPreview() -> String {\n        OutcomePipeline.generateMissionModifierPreview(gameState: self)",
    "func generateGangReactionMessage() -> String {\n        OutcomePipeline.generateGangReactionMessage(gameState: self)",
    "func generateGangMissionPreview() -> String {\n        OutcomePipeline.generateGangMissionPreview(gameState: self)",
    "func generateCombinedPressurePreview() -> String {\n        OutcomePipeline.generateCombinedPressurePreview(gameState: self)",
    "func rewardTierLabel(_ tier: RewardTier) -> String {\n        OutcomePipeline.rewardTierLabel(tier)",
    "func generateRewardPreview() -> String {\n        OutcomePipeline.generateRewardPreview(gameState: self)",
    "func generateRewardPayoutSummary() -> String {\n        OutcomePipeline.generateRewardPayoutSummary(gameState: self)",
    "func generateMissionEndSummary() -> String {\n        OutcomePipeline.generateMissionEndSummary(gameState: self)"
]
for snippet in requiredShimCalls {
    checks.append(Check(name: "GameState shim routes to OutcomePipeline", pass: has(snippet, in: gameState), detail: snippet.components(separatedBy: "\\n").first ?? snippet))
}

var failed = false
for c in checks {
    print("\(c.pass ? "PASS" : "FAIL") - \(c.name): \(c.detail)")
    if !c.pass { failed = true }
}

exit(failed ? 1 : 0)

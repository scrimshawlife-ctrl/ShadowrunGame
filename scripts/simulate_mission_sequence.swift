import Foundation

#if canImport(ShadowrunGame)
import ShadowrunGame
#endif

struct MissionInput {
    let traceLevel: Int
    let traceThreshold: Int
}

struct MissionOutput {
    let missionIndex: Int
    let traceTier: Int
    let heatValue: Int
    let heatTierLabel: String
    let corpAttentionTotal: Int
    let gangAttentionTotal: Int
    let corpModifier: Int
    let gangRadius: Int
    let combinedPreview: String
}

struct ScenarioSummary {
    let finalCorpAttention: Int
    let finalGangAttention: Int
    let finalCorpModifier: Int
    let finalGangRadius: Int
    let highPressureCount: Int
    let firstHighPressureMission: Int?
}

#if canImport(ShadowrunGame)
typealias SimHeatTier = HeatTier
#else
enum SimHeatTier {
    case low
    case medium
    case high
}
#endif

enum SimConsequence {
    static func traceTier(traceLevel: Int, traceThreshold: Int) -> Int {
        #if canImport(ShadowrunGame)
        return ConsequenceEngine.traceTier(traceLevel: traceLevel, traceThreshold: traceThreshold)
        #else
        if traceLevel >= traceThreshold * 2 { return 2 }
        if traceLevel >= traceThreshold { return 1 }
        return 0
        #endif
    }

    static func heatValue(fromTraceTier sourceTraceTier: Int) -> Int {
        #if canImport(ShadowrunGame)
        return ConsequenceEngine.heatValue(fromTraceTier: sourceTraceTier)
        #else
        var derivedTier = sourceTraceTier
        if sourceTraceTier >= 2 {
            derivedTier = min(2, derivedTier + 1)
        }
        return derivedTier
        #endif
    }

    static func heatTier(fromHeatValue heatValue: Int) -> SimHeatTier {
        #if canImport(ShadowrunGame)
        return ConsequenceEngine.heatTier(fromHeatValue: heatValue)
        #else
        switch heatValue {
        case 2: return .high
        case 1: return .medium
        default: return .low
        }
        #endif
    }

    static func heatTierLabel(for heatTier: SimHeatTier) -> String {
        #if canImport(ShadowrunGame)
        return ConsequenceEngine.heatTierLabel(for: heatTier)
        #else
        switch heatTier {
        case .low: return "LOW"
        case .medium: return "MEDIUM"
        case .high: return "HIGH"
        }
        #endif
    }

    static func corpAttentionIncrement(for heatTier: SimHeatTier) -> Int {
        #if canImport(ShadowrunGame)
        return ConsequenceEngine.factionAttentionIncrement(for: heatTier).increment
        #else
        switch heatTier {
        case .low: return 0
        case .medium: return 1
        case .high: return 1
        }
        #endif
    }

    static func gangAttentionIncrement(for heatTier: SimHeatTier) -> Int {
        #if canImport(ShadowrunGame)
        return ConsequenceEngine.gangAttentionIncrement(for: heatTier)
        #else
        switch heatTier {
        case .low: return 0
        case .medium, .high: return 1
        }
        #endif
    }

    static func corpModifier(corpAttention: Int) -> Int {
        #if canImport(ShadowrunGame)
        return ConsequenceEngine.corpEnemyModifier(corpAttention: corpAttention)
        #else
        switch corpAttention {
        case 0: return 0
        case 1...3: return 1
        default: return 2
        }
        #endif
    }

    static func gangRadius(gangAttention: Int) -> Int {
        #if canImport(ShadowrunGame)
        return ConsequenceEngine.gangAmbushRadius(gangAttention: gangAttention)
        #else
        switch gangAttention {
        case 0: return 999
        case 1...2: return 6
        case 3...4: return 4
        default: return 3
        }
        #endif
    }

    static func combinedPressure(corpModifier: Int, gangRadius: Int) -> String {
        #if canImport(ShadowrunGame)
        return ConsequenceEngine.combinedPressurePreview(corpModifier: corpModifier, gangRadius: gangRadius)
        #else
        let gangNoBiasRadius = 999
        let gangActive = gangRadius < gangNoBiasRadius

        if corpModifier >= 2 && gangRadius <= 3 {
            return "High combined pressure: increased enemy presence and immediate proximity threats expected."
        }
        if corpModifier == 0 && !gangActive {
            return "No combined pressure detected."
        }
        if corpModifier > 0 && !gangActive {
            return "Corporate surveillance is increasing enemy presence."
        }
        if corpModifier == 0 && gangActive {
            return "Gang activity is tightening spawn proximity."
        }
        return "Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity."
        #endif
    }

    static func attentionDecayAmount(for traceTier: Int) -> Int {
        #if canImport(ShadowrunGame)
        return ConsequenceEngine.attentionDecayAmount(for: traceTier)
        #else
        switch traceTier {
        case 0:
            return 1
        default:
            return 0
        }
        #endif
    }

    static func highTraceCorpEscalationBonus(traceTier: Int) -> Int {
        #if canImport(ShadowrunGame)
        return ConsequenceEngine.highTraceCorpEscalationBonus(traceTier: traceTier)
        #else
        switch traceTier {
        case 2:
            return 1
        default:
            return 0
        }
        #endif
    }
}

func summarizeScenario(_ results: [MissionOutput]) -> ScenarioSummary {
    let highPressureMissions = results.filter { $0.corpModifier == 2 || $0.gangRadius <= 3 }
    let firstHigh = highPressureMissions.first?.missionIndex
    let final = results.last

    return ScenarioSummary(
        finalCorpAttention: final?.corpAttentionTotal ?? 0,
        finalGangAttention: final?.gangAttentionTotal ?? 0,
        finalCorpModifier: final?.corpModifier ?? 0,
        finalGangRadius: final?.gangRadius ?? 999,
        highPressureCount: highPressureMissions.count,
        firstHighPressureMission: firstHigh
    )
}

func runScenario(name: String, missions: [MissionInput]) -> ([MissionOutput], ScenarioSummary) {
    var corpAttention = 0
    var gangAttention = 0
    var results: [MissionOutput] = []

    for (index, mission) in missions.enumerated() {
        let traceTier = SimConsequence.traceTier(traceLevel: mission.traceLevel, traceThreshold: mission.traceThreshold)
        let heatValue = SimConsequence.heatValue(fromTraceTier: traceTier)
        let heatTier = SimConsequence.heatTier(fromHeatValue: heatValue)
        let highTraceBonus = SimConsequence.highTraceCorpEscalationBonus(traceTier: traceTier)

        corpAttention += SimConsequence.corpAttentionIncrement(for: heatTier) + highTraceBonus
        gangAttention += SimConsequence.gangAttentionIncrement(for: heatTier)
        let decayAmount = SimConsequence.attentionDecayAmount(for: traceTier)
        if decayAmount > 0 {
            corpAttention = max(0, corpAttention - decayAmount)
            gangAttention = max(0, gangAttention - decayAmount)
        }

        let corpModifier = SimConsequence.corpModifier(corpAttention: corpAttention)
        let gangRadius = SimConsequence.gangRadius(gangAttention: gangAttention)
        let combined = SimConsequence.combinedPressure(corpModifier: corpModifier, gangRadius: gangRadius)

        results.append(MissionOutput(
            missionIndex: index + 1,
            traceTier: traceTier,
            heatValue: heatValue,
            heatTierLabel: SimConsequence.heatTierLabel(for: heatTier),
            corpAttentionTotal: corpAttention,
            gangAttentionTotal: gangAttention,
            corpModifier: corpModifier,
            gangRadius: gangRadius,
            combinedPreview: combined
        ))
    }

    print("=== \(name) ===")
    for result in results {
        let traceLabel: String
        switch result.traceTier {
        case 2: traceLabel = "HIGH"
        case 1: traceLabel = "MED"
        default: traceLabel = "LOW"
        }

        print("\nMission \(result.missionIndex):")
        print("Trace: \(traceLabel)")
        print("Heat: \(result.heatTierLabel) (\(result.heatValue))")
        print("Corp Attention: \(result.corpAttentionTotal)")
        print("Gang Attention: \(result.gangAttentionTotal)")
        print("Corp Mod: +\(result.corpModifier) enemies")
        print("Gang Radius: \(result.gangRadius)")
        print("Combined: \(result.combinedPreview)")
    }
    let summary = summarizeScenario(results)
    let firstHighText = summary.firstHighPressureMission.map(String.init) ?? "none"
    print("\nFinal State:")
    print("Corp Attention: \(summary.finalCorpAttention)")
    print("Gang Attention: \(summary.finalGangAttention)")
    print("Corp Modifier: +\(summary.finalCorpModifier) enemies")
    print("Gang Radius: \(summary.finalGangRadius)")
    print("High Pressure Count: \(summary.highPressureCount)")
    print("First HIGH Pressure Mission: \(firstHighText)")
    print("\n")

    return (results, summary)
}

func markdownForScenario(name: String, results: [MissionOutput], summary: ScenarioSummary) -> String {
    var lines: [String] = []
    lines.append("## \(name)")
    lines.append("")
    lines.append("| Mission | Trace Tier | Heat | Corp Attention | Gang Attention | Corp Mod | Gang Radius | Combined |")
    lines.append("|---|---|---|---:|---:|---:|---:|---|")

    for result in results {
        let traceLabel: String
        switch result.traceTier {
        case 2: traceLabel = "HIGH"
        case 1: traceLabel = "MED"
        default: traceLabel = "LOW"
        }

        lines.append("| \(result.missionIndex) | \(traceLabel) | \(result.heatTierLabel) (\(result.heatValue)) | \(result.corpAttentionTotal) | \(result.gangAttentionTotal) | +\(result.corpModifier) | \(result.gangRadius) | \(result.combinedPreview) |")
    }

    let firstHighText = summary.firstHighPressureMission.map(String.init) ?? "none"
    lines.append("")
    lines.append("Final State:")
    lines.append("- Corp Attention: \(summary.finalCorpAttention)")
    lines.append("- Gang Attention: \(summary.finalGangAttention)")
    lines.append("- Corp Modifier: +\(summary.finalCorpModifier) enemies")
    lines.append("- Gang Radius: \(summary.finalGangRadius)")
    lines.append("- High Pressure Count: \(summary.highPressureCount)")
    lines.append("- First HIGH Pressure Mission: \(firstHighText)")
    lines.append("")
    return lines.joined(separator: "\n")
}

func repeatedMissions(_ traceLevels: [Int], threshold: Int) -> [MissionInput] {
    traceLevels.map { MissionInput(traceLevel: $0, traceThreshold: threshold) }
}

let threshold = 5
let scenarios: [(String, [MissionInput])] = [
    ("Scenario A: Clean Player", repeatedMissions([0, 2, 1, 0, 1, 2, 0, 1], threshold: threshold)),
    ("Scenario B: Moderate Player", repeatedMissions([5, 6, 5, 7, 5, 6, 5, 7], threshold: threshold)),
    ("Scenario C: Loud Player", repeatedMissions([10, 11, 10, 12, 10, 11, 10, 12], threshold: threshold)),
    ("Scenario D: Escalating Player", repeatedMissions([1, 5, 10, 10, 10, 10, 10, 10], threshold: threshold)),
    ("Scenario E: Recovery Player", repeatedMissions([5, 0, 5, 0, 5, 0, 5, 0], threshold: threshold))
]

var markdown: [String] = [
    "# Mission Pressure Simulation",
    "",
    "Deterministic multi-mission sequence simulation using `ConsequenceEngine` mappings (or deterministic mirror fallback when the game module is unavailable to `swift` script execution).",
    ""
]

var comparisonRows: [(name: String, summary: ScenarioSummary)] = []

for (name, missions) in scenarios {
    let (result, summary) = runScenario(name: name, missions: missions)
    markdown.append(markdownForScenario(name: name, results: result, summary: summary))
    comparisonRows.append((name: name, summary: summary))
}

print("=== COMPARISON SUMMARY ===")
for row in comparisonRows {
    let firstHighText = row.summary.firstHighPressureMission.map(String.init) ?? "none"
    print("\(row.name)")
    print("- Missions to first HIGH pressure: \(firstHighText)")
    print("- Total HIGH pressure missions: \(row.summary.highPressureCount)")
    print("- Final Corp Attention: \(row.summary.finalCorpAttention)")
    print("- Final Gang Attention: \(row.summary.finalGangAttention)")
}
print("")

markdown.append("## COMPARISON SUMMARY")
markdown.append("")
markdown.append("| Scenario | Missions to First HIGH Pressure | Total HIGH Pressure Missions | Final Corp Attention | Final Gang Attention |")
markdown.append("|---|---:|---:|---:|---:|")
for row in comparisonRows {
    let firstHighText = row.summary.firstHighPressureMission.map(String.init) ?? "none"
    markdown.append("| \(row.name) | \(firstHighText) | \(row.summary.highPressureCount) | \(row.summary.finalCorpAttention) | \(row.summary.finalGangAttention) |")
}
markdown.append("")

let docsDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("docs")
    .appendingPathComponent("simulation")

try? FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
let docsFile = docsDir.appendingPathComponent("MissionPressureSimulation.md")

if let data = markdown.joined(separator: "\n").data(using: .utf8) {
    do {
        try data.write(to: docsFile)
        print("Saved simulation report: \(docsFile.path)")
    } catch {
        print("Could not write markdown report: \(error)")
    }
}

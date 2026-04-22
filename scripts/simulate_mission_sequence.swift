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
    let missionTypeLabel: String
    let traceTier: Int
    let heatValue: Int
    let heatTierLabel: String
    let corpAttentionTotal: Int
    let gangAttentionTotal: Int
    let corpModifier: Int
    let gangRadius: Int
    let rewardTierLabel: String
    let rewardMultiplier: Double
    let missionTypeBonusMultiplier: Double
    let finalMultiplier: Double
    let basePayout: Int
    let riskBonus: Int
    let finalPayout: Int
    let mapSituationLabel: String
    let watcherCount: Int
    let enforcerCount: Int
    let interceptorCount: Int
    let dominantArchetype: String
    let combinedPreview: String
}

struct ScenarioSummary {
    let finalCorpAttention: Int
    let finalGangAttention: Int
    let finalCorpModifier: Int
    let finalGangRadius: Int
    let highPressureCount: Int
    let firstHighPressureMission: Int?
    let maxCorpModifierReached: Int
    let minimumGangRadiusReached: Int
    let recoveryEventsCount: Int
    let zeroPressureMissionsCount: Int
    let averageRewardMultiplier: Double
    let maxRewardMultiplier: Double
    let totalPayout: Int
    let averagePayoutPerMission: Double
    let totalRiskBonus: Int
    let averageRiskBonusPerMission: Double
    let totalMissionTypeBonus: Double
    let averageMissionTypeBonus: Double
    let corridorCount: Int
    let openZoneCount: Int
    let chokepointCount: Int
    let dominantArchetype: String
    let flags: [String]
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

#if canImport(ShadowrunGame)
typealias SimRewardTier = RewardTier
#else
enum SimRewardTier {
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

    static func rewardTier(heatTier: Int, corpAttention: Int, gangAttention: Int) -> SimRewardTier {
        #if canImport(ShadowrunGame)
        return ConsequenceEngine.rewardTier(heatTier: heatTier, corpAttention: corpAttention, gangAttention: gangAttention)
        #else
        if heatTier >= 2 || corpAttention >= 4 || gangAttention >= 4 {
            return .high
        }
        if heatTier == 1 || (2...3).contains(corpAttention) {
            return .medium
        }
        if heatTier == 0 && corpAttention < 2 {
            return .low
        }
        return .medium
        #endif
    }

    static func rewardTierLabel(for tier: SimRewardTier) -> String {
        switch tier {
        case .low: return "LOW"
        case .medium: return "MED"
        case .high: return "HIGH"
        }
    }

    static func rewardMultiplier(for tier: SimRewardTier) -> Double {
        #if canImport(ShadowrunGame)
        return ConsequenceEngine.rewardMultiplier(for: tier)
        #else
        switch tier {
        case .low:
            return 1.0
        case .medium:
            return 1.25
        case .high:
            return 1.5
        }
        #endif
    }
}

enum SimMissionType: CaseIterable {
    case stealth
    case assault
    case extraction

    var label: String {
        switch self {
        case .stealth: return "STEALTH"
        case .assault: return "ASSAULT"
        case .extraction: return "EXTRACTION"
        }
    }
}

enum SimEnemyArchetype {
    case watcher
    case enforcer
    case interceptor

    var label: String {
        switch self {
        case .watcher: return "WATCHER"
        case .enforcer: return "ENFORCER"
        case .interceptor: return "INTERCEPTOR"
        }
    }
}

enum SimMapSituation {
    case corridor
    case openZone
    case chokepoint

    var label: String {
        switch self {
        case .corridor: return "CORRIDOR"
        case .openZone: return "OPEN ZONE"
        case .chokepoint: return "CHOKEPOINT"
        }
    }
}

func mapSituation(for missionType: SimMissionType) -> SimMapSituation {
    switch missionType {
    case .stealth: return .corridor
    case .assault: return .openZone
    case .extraction: return .chokepoint
    }
}

func archetypeForSpawnIndex(missionType: SimMissionType, spawnIndex: Int) -> SimEnemyArchetype {
    switch missionType {
    case .stealth:
        let pattern: [SimEnemyArchetype] = [.watcher, .watcher, .interceptor, .watcher, .enforcer]
        return pattern[spawnIndex % pattern.count]
    case .assault:
        let pattern: [SimEnemyArchetype] = [.enforcer, .enforcer, .interceptor, .enforcer, .watcher]
        return pattern[spawnIndex % pattern.count]
    case .extraction:
        let pattern: [SimEnemyArchetype] = [.interceptor, .watcher, .interceptor, .enforcer, .interceptor]
        return pattern[spawnIndex % pattern.count]
    }
}

func archetypeMix(missionType: SimMissionType, spawnCount: Int = 5) -> (watchers: Int, enforcers: Int, interceptors: Int, dominant: String) {
    var watcherCount = 0
    var enforcerCount = 0
    var interceptorCount = 0
    for spawnIndex in 0..<spawnCount {
        switch archetypeForSpawnIndex(missionType: missionType, spawnIndex: spawnIndex) {
        case .watcher: watcherCount += 1
        case .enforcer: enforcerCount += 1
        case .interceptor: interceptorCount += 1
        }
    }

    let dominant: String
    if watcherCount >= enforcerCount && watcherCount >= interceptorCount {
        dominant = "WATCHER"
    } else if enforcerCount >= watcherCount && enforcerCount >= interceptorCount {
        dominant = "ENFORCER"
    } else {
        dominant = "INTERCEPTOR"
    }

    return (watcherCount, enforcerCount, interceptorCount, dominant)
}

func summarizeScenario(_ results: [MissionOutput]) -> ScenarioSummary {
    let highPressureMissions = results.filter { $0.corpModifier == 2 || $0.gangRadius <= 3 }
    let recoveryEvents = results.filter { $0.traceTier == 0 && ($0.corpAttentionTotal > 0 || $0.gangAttentionTotal > 0) }
    let zeroPressureMissions = results.filter { $0.corpModifier == 0 && $0.gangRadius == 999 }
    let firstHigh = highPressureMissions.first?.missionIndex
    let final = results.last
    let maxCorpModifier = results.map(\.corpModifier).max() ?? 0
    let minimumGangRadius = results.map(\.gangRadius).min() ?? 999
    let averageRewardMultiplier = results.isEmpty ? 1.0 : results.map(\.rewardMultiplier).reduce(0, +) / Double(results.count)
    let maxRewardMultiplier = results.map(\.rewardMultiplier).max() ?? 1.0
    let totalPayout = results.map(\.finalPayout).reduce(0, +)
    let averagePayoutPerMission = results.isEmpty ? 0.0 : Double(totalPayout) / Double(results.count)
    let totalRiskBonus = results.map(\.riskBonus).reduce(0, +)
    let averageRiskBonusPerMission = results.isEmpty ? 0.0 : Double(totalRiskBonus) / Double(results.count)
    let totalMissionTypeBonus = results.map(\.missionTypeBonusMultiplier).reduce(0, +)
    let averageMissionTypeBonus = results.isEmpty ? 0.0 : totalMissionTypeBonus / Double(results.count)
    let corridorCount = results.filter { $0.mapSituationLabel == "CORRIDOR" }.count
    let openZoneCount = results.filter { $0.mapSituationLabel == "OPEN ZONE" }.count
    let chokepointCount = results.filter { $0.mapSituationLabel == "CHOKEPOINT" }.count
    let totalWatchers = results.map(\.watcherCount).reduce(0, +)
    let totalEnforcers = results.map(\.enforcerCount).reduce(0, +)
    let totalInterceptors = results.map(\.interceptorCount).reduce(0, +)
    let highPressureCount = highPressureMissions.count
    let finalCorpAttention = final?.corpAttentionTotal ?? 0
    let finalGangAttention = final?.gangAttentionTotal ?? 0

    var flags: [String] = []
    if highPressureCount >= 6 {
        flags.append("SATURATION_RISK")
    }
    if finalCorpAttention >= 12 && finalGangAttention >= 6 {
        flags.append("FLATLINE_RISK")
    }
    if recoveryEvents.count >= 2 && highPressureCount <= 3 {
        flags.append("HEALTHY_RECOVERY")
    }
    if highPressureCount == 0 {
        flags.append("SAFE_ROUTE")
    }
    if flags.isEmpty {
        flags.append("none")
    }
    let dominantArchetype: String
    if totalWatchers >= totalEnforcers && totalWatchers >= totalInterceptors {
        dominantArchetype = "WATCHER"
    } else if totalEnforcers >= totalWatchers && totalEnforcers >= totalInterceptors {
        dominantArchetype = "ENFORCER"
    } else {
        dominantArchetype = "INTERCEPTOR"
    }

    return ScenarioSummary(
        finalCorpAttention: finalCorpAttention,
        finalGangAttention: finalGangAttention,
        finalCorpModifier: final?.corpModifier ?? 0,
        finalGangRadius: final?.gangRadius ?? 999,
        highPressureCount: highPressureCount,
        firstHighPressureMission: firstHigh,
        maxCorpModifierReached: maxCorpModifier,
        minimumGangRadiusReached: minimumGangRadius,
        recoveryEventsCount: recoveryEvents.count,
        zeroPressureMissionsCount: zeroPressureMissions.count,
        averageRewardMultiplier: averageRewardMultiplier,
        maxRewardMultiplier: maxRewardMultiplier,
        totalPayout: totalPayout,
        averagePayoutPerMission: averagePayoutPerMission,
        totalRiskBonus: totalRiskBonus,
        averageRiskBonusPerMission: averageRiskBonusPerMission,
        totalMissionTypeBonus: totalMissionTypeBonus,
        averageMissionTypeBonus: averageMissionTypeBonus,
        corridorCount: corridorCount,
        openZoneCount: openZoneCount,
        chokepointCount: chokepointCount,
        dominantArchetype: dominantArchetype,
        flags: flags
    )
}

func runScenario(name: String, missions: [MissionInput]) -> ([MissionOutput], ScenarioSummary) {
    let baseMissionPayout = 100
    var corpAttention = 0
    var gangAttention = 0
    var results: [MissionOutput] = []

    for (index, mission) in missions.enumerated() {
        let missionType = SimMissionType.allCases[index % SimMissionType.allCases.count]
        let missionMapSituation = mapSituation(for: missionType)
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
        let rewardTier = SimConsequence.rewardTier(heatTier: heatValue, corpAttention: corpAttention, gangAttention: gangAttention)
        let rewardMultiplier = SimConsequence.rewardMultiplier(for: rewardTier)
        let missionTypeBonusMultiplier: Double
        switch missionType {
        case .stealth:
            missionTypeBonusMultiplier = traceTier == 0 ? 0.25 : 0.0
        case .assault:
            missionTypeBonusMultiplier = traceTier == 2 ? 0.25 : 0.0
        case .extraction:
            missionTypeBonusMultiplier = traceTier == 1 ? 0.15 : 0.0
        }
        let finalMultiplier = rewardMultiplier + missionTypeBonusMultiplier
        let finalPayout = Int(Double(baseMissionPayout) * finalMultiplier)
        let riskBonus = finalPayout - baseMissionPayout
        let archetypeCounts = archetypeMix(missionType: missionType)
        let combined = SimConsequence.combinedPressure(corpModifier: corpModifier, gangRadius: gangRadius)

        results.append(MissionOutput(
            missionIndex: index + 1,
            missionTypeLabel: missionType.label,
            traceTier: traceTier,
            heatValue: heatValue,
            heatTierLabel: SimConsequence.heatTierLabel(for: heatTier),
            corpAttentionTotal: corpAttention,
            gangAttentionTotal: gangAttention,
            corpModifier: corpModifier,
            gangRadius: gangRadius,
            rewardTierLabel: SimConsequence.rewardTierLabel(for: rewardTier),
            rewardMultiplier: rewardMultiplier,
            missionTypeBonusMultiplier: missionTypeBonusMultiplier,
            finalMultiplier: finalMultiplier,
            basePayout: baseMissionPayout,
            riskBonus: riskBonus,
            finalPayout: finalPayout,
            mapSituationLabel: missionMapSituation.label,
            watcherCount: archetypeCounts.watchers,
            enforcerCount: archetypeCounts.enforcers,
            interceptorCount: archetypeCounts.interceptors,
            dominantArchetype: archetypeCounts.dominant,
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
        print("Mission Type: \(result.missionTypeLabel)")
        print("Map Situation: \(result.mapSituationLabel)")
        print("Trace: \(traceLabel)")
        print("Heat: \(result.heatTierLabel) (\(result.heatValue))")
        print("Corp Attention: \(result.corpAttentionTotal)")
        print("Gang Attention: \(result.gangAttentionTotal)")
        print("Corp Mod: +\(result.corpModifier) enemies")
        print("Gang Radius: \(result.gangRadius)")
        print("Reward: \(result.rewardTierLabel) (x\(String(format: "%.2f", result.rewardMultiplier)))")
        print("Mission Bonus: +\(String(format: "%.2f", result.missionTypeBonusMultiplier))")
        print("Final Multiplier: x\(String(format: "%.2f", result.finalMultiplier))")
        print("Payout: Base \(result.basePayout) + Risk Bonus +\(result.riskBonus) = \(result.finalPayout)")
        print("Enemy Archetypes: W\(result.watcherCount) / E\(result.enforcerCount) / I\(result.interceptorCount) (Dominant: \(result.dominantArchetype))")
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
    print("Max Corp Mod Reached: +\(summary.maxCorpModifierReached)")
    print("Min Gang Radius Reached: \(summary.minimumGangRadiusReached)")
    print("Recovery Events: \(summary.recoveryEventsCount)")
    print("Zero Pressure Missions: \(summary.zeroPressureMissionsCount)")
    print("Avg Reward Multiplier: x\(String(format: "%.2f", summary.averageRewardMultiplier))")
    print("Max Reward Multiplier: x\(String(format: "%.2f", summary.maxRewardMultiplier))")
    print("Total Payout: \(summary.totalPayout)")
    print("Average Payout per Mission: \(String(format: "%.2f", summary.averagePayoutPerMission))")
    print("Total Risk Bonus: \(summary.totalRiskBonus)")
    print("Average Risk Bonus per Mission: \(String(format: "%.2f", summary.averageRiskBonusPerMission))")
    print("Total Mission Type Bonus: \(String(format: "%.2f", summary.totalMissionTypeBonus))")
    print("Average Mission Type Bonus: \(String(format: "%.2f", summary.averageMissionTypeBonus))")
    print("Map Situations: Corridor \(summary.corridorCount), Open Zone \(summary.openZoneCount), Chokepoint \(summary.chokepointCount)")
    print("Dominant Archetype: \(summary.dominantArchetype)")
    print("Flags: \(summary.flags.joined(separator: ", "))")
    print("\n")

    return (results, summary)
}

func markdownForScenario(name: String, results: [MissionOutput], summary: ScenarioSummary) -> String {
    var lines: [String] = []
    lines.append("## \(name)")
    lines.append("")
    lines.append("| Mission | Mission Type | Map Situation | Trace Tier | Heat | Corp Attention | Gang Attention | Corp Mod | Gang Radius | Reward Tier | Base Payout | Risk Bonus | Reward Multiplier | Mission Type Bonus | Final Multiplier | Final Payout | Watchers | Enforcers | Interceptors | Dominant Archetype | Combined |")
    lines.append("|---|---|---|---|---|---:|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|")

    for result in results {
        let traceLabel: String
        switch result.traceTier {
        case 2: traceLabel = "HIGH"
        case 1: traceLabel = "MED"
        default: traceLabel = "LOW"
        }

        lines.append("| \(result.missionIndex) | \(result.missionTypeLabel) | \(result.mapSituationLabel) | \(traceLabel) | \(result.heatTierLabel) (\(result.heatValue)) | \(result.corpAttentionTotal) | \(result.gangAttentionTotal) | +\(result.corpModifier) | \(result.gangRadius) | \(result.rewardTierLabel) | \(result.basePayout) | +\(result.riskBonus) | x\(String(format: "%.2f", result.rewardMultiplier)) | +\(String(format: "%.2f", result.missionTypeBonusMultiplier)) | x\(String(format: "%.2f", result.finalMultiplier)) | \(result.finalPayout) | \(result.watcherCount) | \(result.enforcerCount) | \(result.interceptorCount) | \(result.dominantArchetype) | \(result.combinedPreview) |")
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
    lines.append("- Max Corp Modifier Reached: +\(summary.maxCorpModifierReached)")
    lines.append("- Minimum Gang Radius Reached: \(summary.minimumGangRadiusReached)")
    lines.append("- Recovery Events Count: \(summary.recoveryEventsCount)")
    lines.append("- Zero Pressure Missions Count: \(summary.zeroPressureMissionsCount)")
    lines.append("- Average Reward Multiplier: x\(String(format: "%.2f", summary.averageRewardMultiplier))")
    lines.append("- Max Reward Multiplier: x\(String(format: "%.2f", summary.maxRewardMultiplier))")
    lines.append("- Total Payout: \(summary.totalPayout)")
    lines.append("- Average Payout per Mission: \(String(format: "%.2f", summary.averagePayoutPerMission))")
    lines.append("- Total Risk Bonus: \(summary.totalRiskBonus)")
    lines.append("- Average Risk Bonus per Mission: \(String(format: "%.2f", summary.averageRiskBonusPerMission))")
    lines.append("- Total Mission Type Bonus: \(String(format: "%.2f", summary.totalMissionTypeBonus))")
    lines.append("- Average Mission Type Bonus: \(String(format: "%.2f", summary.averageMissionTypeBonus))")
    lines.append("- Map Situation Distribution: Corridor \(summary.corridorCount), Open Zone \(summary.openZoneCount), Chokepoint \(summary.chokepointCount)")
    lines.append("- Dominant Archetype: \(summary.dominantArchetype)")
    lines.append("- Flags: \(summary.flags.joined(separator: ", "))")
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
    ("Scenario E: Recovery Player", repeatedMissions([5, 0, 5, 0, 5, 0, 5, 0], threshold: threshold)),
    ("Scenario F: Alternating Moderate / Loud", repeatedMissions([5, 10, 5, 10, 5, 10, 5, 10], threshold: threshold)),
    ("Scenario G: Loud Then Recovery", repeatedMissions([10, 10, 10, 0, 0, 5, 0, 0], threshold: threshold)),
    ("Scenario H: Moderate With Clean Breaks", repeatedMissions([5, 5, 0, 5, 5, 0, 5, 0], threshold: threshold)),
    ("Scenario I: Spike Player", repeatedMissions([0, 0, 10, 0, 0, 10, 0, 0], threshold: threshold)),
    ("Scenario J: Sloppy Recovery", repeatedMissions([10, 0, 5, 0, 10, 0, 5, 0], threshold: threshold))
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
    print("- Max Corp Modifier Reached: +\(row.summary.maxCorpModifierReached)")
    print("- Minimum Gang Radius Reached: \(row.summary.minimumGangRadiusReached)")
    print("- Recovery Events Count: \(row.summary.recoveryEventsCount)")
    print("- Zero Pressure Missions Count: \(row.summary.zeroPressureMissionsCount)")
    print("- Avg Reward Multiplier: x\(String(format: "%.2f", row.summary.averageRewardMultiplier))")
    print("- Max Reward Multiplier: x\(String(format: "%.2f", row.summary.maxRewardMultiplier))")
    print("- Total Payout: \(row.summary.totalPayout)")
    print("- Average Payout per Mission: \(String(format: "%.2f", row.summary.averagePayoutPerMission))")
    print("- Total Risk Bonus: \(row.summary.totalRiskBonus)")
    print("- Average Risk Bonus per Mission: \(String(format: "%.2f", row.summary.averageRiskBonusPerMission))")
    print("- Total Mission Type Bonus: \(String(format: "%.2f", row.summary.totalMissionTypeBonus))")
    print("- Average Mission Type Bonus: \(String(format: "%.2f", row.summary.averageMissionTypeBonus))")
    print("- Map Situation Distribution: Corridor \(row.summary.corridorCount), Open Zone \(row.summary.openZoneCount), Chokepoint \(row.summary.chokepointCount)")
    print("- Dominant Archetype: \(row.summary.dominantArchetype)")
    print("- Flags: \(row.summary.flags.joined(separator: ", "))")
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
markdown.append("=== SCENARIO MATRIX SUMMARY ===")
markdown.append("")
markdown.append("| Scenario | Pattern | First High | High Count | Final Corp | Final Gang | Max Corp Mod | Min Gang Radius | Recovery Events | Zero Pressure Missions | Avg Reward Multiplier | Max Reward Multiplier | Total Payout | Avg Payout / Mission | Total Risk Bonus | Avg Risk Bonus / Mission | Total Mission Type Bonus | Avg Mission Type Bonus | Situation Distribution | Dominant Archetype |")
markdown.append("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|")
for row in comparisonRows {
    let firstHighText = row.summary.firstHighPressureMission.map(String.init) ?? "none"
    let pattern = row.name.components(separatedBy: ": ").dropFirst().joined(separator: ": ")
    let situationDistribution = "C:\(row.summary.corridorCount) / O:\(row.summary.openZoneCount) / K:\(row.summary.chokepointCount)"
    markdown.append("| \(row.name) | \(pattern) | \(firstHighText) | \(row.summary.highPressureCount) | \(row.summary.finalCorpAttention) | \(row.summary.finalGangAttention) | +\(row.summary.maxCorpModifierReached) | \(row.summary.minimumGangRadiusReached) | \(row.summary.recoveryEventsCount) | \(row.summary.zeroPressureMissionsCount) | x\(String(format: "%.2f", row.summary.averageRewardMultiplier)) | x\(String(format: "%.2f", row.summary.maxRewardMultiplier)) | \(row.summary.totalPayout) | \(String(format: "%.2f", row.summary.averagePayoutPerMission)) | \(row.summary.totalRiskBonus) | \(String(format: "%.2f", row.summary.averageRiskBonusPerMission)) | \(String(format: "%.2f", row.summary.totalMissionTypeBonus)) | \(String(format: "%.2f", row.summary.averageMissionTypeBonus)) | \(situationDistribution) | \(row.summary.dominantArchetype) |")
}
markdown.append("")
markdown.append("### Scenario Flags")
markdown.append("")
for row in comparisonRows {
    markdown.append("- \(row.name): \(row.summary.flags.joined(separator: ", "))")
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

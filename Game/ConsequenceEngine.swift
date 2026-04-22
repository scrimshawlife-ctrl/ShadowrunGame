import Foundation

struct ConsequenceEngine {
    struct FactionAttentionResult {
        let increment: Int
        let reactionLog: String
    }

    static func traceTier(traceLevel: Int, traceThreshold: Int) -> Int {
        if traceLevel >= traceThreshold * 2 { return 2 }
        if traceLevel >= traceThreshold { return 1 }
        return 0
    }

    static func heatValue(fromTraceTier sourceTraceTier: Int) -> Int {
        var derivedTier = sourceTraceTier
        if sourceTraceTier >= 2 {
            derivedTier = min(2, derivedTier + 1)
        }
        return derivedTier
    }

    static func heatTier(fromHeatValue heatValue: Int) -> HeatTier {
        switch heatValue {
        case 2:
            return .high
        case 1:
            return .medium
        default:
            return .low
        }
    }

    static func heatTierLabel(for heatTier: HeatTier) -> String {
        switch heatTier {
        case .low: return "LOW"
        case .medium: return "MEDIUM"
        case .high: return "HIGH"
        }
    }

    static func factionAttentionIncrement(for heatTier: HeatTier) -> FactionAttentionResult {
        switch heatTier {
        case .low:
            return FactionAttentionResult(increment: 0, reactionLog: "No significant attention detected.")
        case .medium:
            return FactionAttentionResult(increment: 1, reactionLog: "Corporate systems flagged unusual activity.")
        case .high:
            return FactionAttentionResult(increment: 1, reactionLog: "High alert: corporate surveillance increased.")
        }
    }

    static func worldReactionMessage(missionHeatTier: HeatTier, corpAttention: Int) -> String {
        if corpAttention >= 3 {
            return "Persistent attention detected. Future operations may be compromised."
        }

        switch missionHeatTier {
        case .low:
            return "Run completed clean. No significant attention."
        case .medium:
            return "Corporate systems flagged unusual activity."
        case .high:
            return "High alert triggered. Surveillance and response risk increased."
        }
    }

    static func missionModifierPreview(corpAttention: Int) -> String {
        switch corpAttention {
        case 0:
            return "No increased security detected."
        case 1...2:
            return "Moderate surveillance expected next mission."
        default:
            return "High security expected: increased enemy presence likely."
        }
    }

    static func corpEnemyModifier(corpAttention: Int) -> Int {
        switch corpAttention {
        case 0:
            return 0
        case 1...3:
            return 1
        default:
            return 2
        }
    }

    static func gangAttentionIncrement(for heatTier: HeatTier) -> Int {
        switch heatTier {
        case .low:
            return 0
        case .medium, .high:
            return 1
        }
    }

    static func gangReactionMessage(missionHeatTier: HeatTier, gangAttention: Int) -> String {
        if gangAttention >= 3 {
            return "Street rumor web is hot. Crews are watching your routes."
        }

        switch missionHeatTier {
        case .low:
            return "Back alleys stay quiet. No gang buzz."
        case .medium:
            return "Word is moving through local crews."
        case .high:
            return "Heat spilled to the street. Gang eyes are up."
        }
    }

    static func gangMissionPreview(gangAttention: Int) -> String {
        switch gangAttention {
        case 0:
            return "No gang movement flagged."
        case 1...2:
            return "Gang scouts may shadow your next route."
        default:
            return "Turf is active: expect gang pressure next mission."
        }
    }

    static func gangAmbushRadius(gangAttention: Int) -> Int {
        switch gangAttention {
        case 0:
            return 999
        case 1...2:
            return 6
        case 3...4:
            return 4
        default:
            return 3
        }
    }

    static func combinedPressurePreview(
        corpModifier: Int,
        gangRadius: Int
    ) -> String {
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
    }

    static func attentionDecayAmount(for traceTier: Int) -> Int {
        switch traceTier {
        case 0:
            return 1
        default:
            return 0
        }
    }

    static func highTraceCorpEscalationBonus(traceTier: Int) -> Int {
        switch traceTier {
        case 2:
            return 1
        default:
            return 0
        }
    }
}

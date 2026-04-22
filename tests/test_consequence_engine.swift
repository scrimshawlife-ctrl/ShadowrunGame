import XCTest
#if canImport(ShadowrunGame)
@testable import ShadowrunGame

final class ConsequenceEngineGoldenTests: XCTestCase {

    func testTraceTierMapping() {
        XCTAssertEqual(ConsequenceEngine.traceTier(traceLevel: 0, traceThreshold: 5), 0)
        XCTAssertEqual(ConsequenceEngine.traceTier(traceLevel: 4, traceThreshold: 5), 0)
        XCTAssertEqual(ConsequenceEngine.traceTier(traceLevel: 5, traceThreshold: 5), 1)
        XCTAssertEqual(ConsequenceEngine.traceTier(traceLevel: 9, traceThreshold: 5), 1)
        XCTAssertEqual(ConsequenceEngine.traceTier(traceLevel: 10, traceThreshold: 5), 2)
    }

    func testHeatMappingFromTraceTierAndHeatTierValue() {
        XCTAssertEqual(ConsequenceEngine.heatValue(fromTraceTier: 0), 0)
        XCTAssertEqual(ConsequenceEngine.heatValue(fromTraceTier: 1), 1)
        XCTAssertEqual(ConsequenceEngine.heatValue(fromTraceTier: 2), 2)

        XCTAssertEqual(ConsequenceEngine.heatTier(fromHeatValue: 0), .low)
        XCTAssertEqual(ConsequenceEngine.heatTier(fromHeatValue: 1), .medium)
        XCTAssertEqual(ConsequenceEngine.heatTier(fromHeatValue: 2), .high)

        XCTAssertEqual(ConsequenceEngine.heatTierLabel(for: .low), "LOW")
        XCTAssertEqual(ConsequenceEngine.heatTierLabel(for: .medium), "MEDIUM")
        XCTAssertEqual(ConsequenceEngine.heatTierLabel(for: .high), "HIGH")
    }

    func testFactionAttentionIncrementMapping() {
        let lowResult = ConsequenceEngine.factionAttentionIncrement(for: .low)
        XCTAssertEqual(lowResult.increment, 0)
        XCTAssertEqual(lowResult.reactionLog, "No significant attention detected.")

        let mediumResult = ConsequenceEngine.factionAttentionIncrement(for: .medium)
        XCTAssertEqual(mediumResult.increment, 1)
        XCTAssertEqual(mediumResult.reactionLog, "Corporate systems flagged unusual activity.")

        let highResult = ConsequenceEngine.factionAttentionIncrement(for: .high)
        XCTAssertEqual(highResult.increment, 1)
        XCTAssertEqual(highResult.reactionLog, "High alert: corporate surveillance increased.")
    }

    func testWorldReactionMessages() {
        XCTAssertEqual(
            ConsequenceEngine.worldReactionMessage(missionHeatTier: .low, corpAttention: 0),
            "Run completed clean. No significant attention."
        )
        XCTAssertEqual(
            ConsequenceEngine.worldReactionMessage(missionHeatTier: .medium, corpAttention: 0),
            "Corporate systems flagged unusual activity."
        )
        XCTAssertEqual(
            ConsequenceEngine.worldReactionMessage(missionHeatTier: .high, corpAttention: 0),
            "High alert triggered. Surveillance and response risk increased."
        )

        XCTAssertEqual(
            ConsequenceEngine.worldReactionMessage(missionHeatTier: .low, corpAttention: 3),
            "Persistent attention detected. Future operations may be compromised."
        )
        XCTAssertEqual(
            ConsequenceEngine.worldReactionMessage(missionHeatTier: .high, corpAttention: 99),
            "Persistent attention detected. Future operations may be compromised."
        )
    }

    func testMissionModifierPreviewMessages() {
        XCTAssertEqual(ConsequenceEngine.missionModifierPreview(corpAttention: 0), "No increased security detected.")
        XCTAssertEqual(ConsequenceEngine.missionModifierPreview(corpAttention: 1), "Moderate surveillance expected next mission.")
        XCTAssertEqual(ConsequenceEngine.missionModifierPreview(corpAttention: 2), "Moderate surveillance expected next mission.")
        XCTAssertEqual(ConsequenceEngine.missionModifierPreview(corpAttention: 3), "High security expected: increased enemy presence likely.")
        XCTAssertEqual(ConsequenceEngine.missionModifierPreview(corpAttention: 10), "High security expected: increased enemy presence likely.")
    }

    func testCorpEnemyModifierMapping() {
        XCTAssertEqual(ConsequenceEngine.corpEnemyModifier(corpAttention: 0), 0)
        XCTAssertEqual(ConsequenceEngine.corpEnemyModifier(corpAttention: 1), 1)
        XCTAssertEqual(ConsequenceEngine.corpEnemyModifier(corpAttention: 2), 1)
        XCTAssertEqual(ConsequenceEngine.corpEnemyModifier(corpAttention: 3), 1)
        XCTAssertEqual(ConsequenceEngine.corpEnemyModifier(corpAttention: 4), 2)
        XCTAssertEqual(ConsequenceEngine.corpEnemyModifier(corpAttention: 50), 2)
    }

    func testGangAttentionIncrementMapping() {
        XCTAssertEqual(ConsequenceEngine.gangAttentionIncrement(for: .low), 0)
        XCTAssertEqual(ConsequenceEngine.gangAttentionIncrement(for: .medium), 1)
        XCTAssertEqual(ConsequenceEngine.gangAttentionIncrement(for: .high), 1)
    }

    func testGangReactionMessages() {
        XCTAssertEqual(
            ConsequenceEngine.gangReactionMessage(missionHeatTier: .low, gangAttention: 0),
            "Back alleys stay quiet. No gang buzz."
        )
        XCTAssertEqual(
            ConsequenceEngine.gangReactionMessage(missionHeatTier: .medium, gangAttention: 0),
            "Word is moving through local crews."
        )
        XCTAssertEqual(
            ConsequenceEngine.gangReactionMessage(missionHeatTier: .high, gangAttention: 0),
            "Heat spilled to the street. Gang eyes are up."
        )
        XCTAssertEqual(
            ConsequenceEngine.gangReactionMessage(missionHeatTier: .low, gangAttention: 3),
            "Street rumor web is hot. Crews are watching your routes."
        )
        XCTAssertEqual(
            ConsequenceEngine.gangReactionMessage(missionHeatTier: .high, gangAttention: 8),
            "Street rumor web is hot. Crews are watching your routes."
        )
    }

    func testGangMissionPreviewMessages() {
        XCTAssertEqual(ConsequenceEngine.gangMissionPreview(gangAttention: 0), "No gang movement flagged.")
        XCTAssertEqual(ConsequenceEngine.gangMissionPreview(gangAttention: 1), "Gang scouts may shadow your next route.")
        XCTAssertEqual(ConsequenceEngine.gangMissionPreview(gangAttention: 2), "Gang scouts may shadow your next route.")
        XCTAssertEqual(ConsequenceEngine.gangMissionPreview(gangAttention: 3), "Turf is active: expect gang pressure next mission.")
        XCTAssertEqual(ConsequenceEngine.gangMissionPreview(gangAttention: 10), "Turf is active: expect gang pressure next mission.")
    }

    func testGangAmbushRadiusMapping() {
        XCTAssertEqual(ConsequenceEngine.gangAmbushRadius(gangAttention: 0), 999)
        XCTAssertEqual(ConsequenceEngine.gangAmbushRadius(gangAttention: 1), 6)
        XCTAssertEqual(ConsequenceEngine.gangAmbushRadius(gangAttention: 2), 6)
        XCTAssertEqual(ConsequenceEngine.gangAmbushRadius(gangAttention: 3), 4)
        XCTAssertEqual(ConsequenceEngine.gangAmbushRadius(gangAttention: 4), 4)
        XCTAssertEqual(ConsequenceEngine.gangAmbushRadius(gangAttention: 5), 3)
        XCTAssertEqual(ConsequenceEngine.gangAmbushRadius(gangAttention: 99), 3)
    }

    func testCombinedPressurePreviewMessages() {
        XCTAssertEqual(
            ConsequenceEngine.combinedPressurePreview(corpModifier: 0, gangRadius: 999),
            "No combined pressure detected."
        )
        XCTAssertEqual(
            ConsequenceEngine.combinedPressurePreview(corpModifier: 1, gangRadius: 999),
            "Corporate surveillance is increasing enemy presence."
        )
        XCTAssertEqual(
            ConsequenceEngine.combinedPressurePreview(corpModifier: 0, gangRadius: 6),
            "Gang activity is tightening spawn proximity."
        )
        XCTAssertEqual(
            ConsequenceEngine.combinedPressurePreview(corpModifier: 1, gangRadius: 6),
            "Corporate surveillance is increasing enemy presence while gang activity is tightening spawn proximity."
        )
        XCTAssertEqual(
            ConsequenceEngine.combinedPressurePreview(corpModifier: 2, gangRadius: 3),
            "High combined pressure: increased enemy presence and immediate proximity threats expected."
        )
    }

    func testAttentionDecayAmountMapping() {
        XCTAssertEqual(ConsequenceEngine.attentionDecayAmount(for: 0), 1)
        XCTAssertEqual(ConsequenceEngine.attentionDecayAmount(for: 1), 0)
        XCTAssertEqual(ConsequenceEngine.attentionDecayAmount(for: 2), 0)
    }

    func testHighTraceCorpEscalationBonusMapping() {
        XCTAssertEqual(ConsequenceEngine.highTraceCorpEscalationBonus(traceTier: 0), 0)
        XCTAssertEqual(ConsequenceEngine.highTraceCorpEscalationBonus(traceTier: 1), 0)
        XCTAssertEqual(ConsequenceEngine.highTraceCorpEscalationBonus(traceTier: 2), 1)
    }

    func testDeterminismRepeatedCallsReturnSameOutputs() {
        for _ in 0..<25 {
            XCTAssertEqual(ConsequenceEngine.traceTier(traceLevel: 10, traceThreshold: 5), 2)
            XCTAssertEqual(ConsequenceEngine.heatValue(fromTraceTier: 2), 2)
            XCTAssertEqual(ConsequenceEngine.heatTier(fromHeatValue: 2), .high)
            XCTAssertEqual(ConsequenceEngine.heatTierLabel(for: .high), "HIGH")

            let attention = ConsequenceEngine.factionAttentionIncrement(for: .medium)
            XCTAssertEqual(attention.increment, 1)
            XCTAssertEqual(attention.reactionLog, "Corporate systems flagged unusual activity.")

            XCTAssertEqual(
                ConsequenceEngine.worldReactionMessage(missionHeatTier: .high, corpAttention: 3),
                "Persistent attention detected. Future operations may be compromised."
            )
            XCTAssertEqual(
                ConsequenceEngine.missionModifierPreview(corpAttention: 2),
                "Moderate surveillance expected next mission."
            )
            XCTAssertEqual(ConsequenceEngine.corpEnemyModifier(corpAttention: 2), 1)
            XCTAssertEqual(ConsequenceEngine.corpEnemyModifier(corpAttention: 3), 1)
            XCTAssertEqual(ConsequenceEngine.gangAttentionIncrement(for: .high), 1)
            XCTAssertEqual(
                ConsequenceEngine.gangReactionMessage(missionHeatTier: .medium, gangAttention: 3),
                "Street rumor web is hot. Crews are watching your routes."
            )
            XCTAssertEqual(
                ConsequenceEngine.gangMissionPreview(gangAttention: 2),
                "Gang scouts may shadow your next route."
            )
            XCTAssertEqual(ConsequenceEngine.gangAmbushRadius(gangAttention: 3), 4)
            XCTAssertEqual(
                ConsequenceEngine.combinedPressurePreview(corpModifier: 2, gangRadius: 3),
                "High combined pressure: increased enemy presence and immediate proximity threats expected."
            )
            XCTAssertEqual(ConsequenceEngine.attentionDecayAmount(for: 0), 1)
            XCTAssertEqual(ConsequenceEngine.attentionDecayAmount(for: 2), 0)
            XCTAssertEqual(ConsequenceEngine.highTraceCorpEscalationBonus(traceTier: 0), 0)
            XCTAssertEqual(ConsequenceEngine.highTraceCorpEscalationBonus(traceTier: 2), 1)
        }
    }
}
#endif

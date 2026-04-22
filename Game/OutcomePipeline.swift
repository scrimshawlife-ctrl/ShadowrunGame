import Foundation

@MainActor
struct OutcomePipeline {

    static func execute(
        gameState: GameState,
        won: Bool,
        missionLog: String,
        terminalLog: String?
    ) {

        guard !gameState.combatEnded else { return }

        // 1. Haptics
        if won {
            HapticsManager.shared.victory()
        } else {
            HapticsManager.shared.defeat()
        }

        // 2. Log mission result
        gameState.addLog(missionLog)

        // 3. finalizeMissionHeat()
        OutcomePipeline.finalizeMissionHeat(gameState: gameState)

        // 4. applyFactionAttention()
        OutcomePipeline.applyFactionAttention(gameState: gameState, traceTier: gameState.traceTier)

        // 5. applyGangAttention()
        OutcomePipeline.applyGangAttention(gameState: gameState)

        // 6. applyAttentionDecay()
        OutcomePipeline.applyAttentionDecay(gameState: gameState, traceTier: gameState.traceTier)

        // 7. world reaction log
        gameState.addLog(OutcomePipeline.generateWorldReactionMessage(gameState: gameState))

        // 8. combined pressure log
        gameState.addLog(OutcomePipeline.generateCombinedPressurePreview(gameState: gameState))

        // 9. finalizeRewardLayer()
        OutcomePipeline.finalizeRewardLayer(gameState: gameState)

        // 10. mission modifier log
        gameState.addLog(OutcomePipeline.generateMissionModifierPreview(gameState: gameState))

        // 11. terminalLog
        if let terminalLog {
            gameState.addLog(terminalLog)
        }

        // 12. mission end summary
        gameState.addLog(OutcomePipeline.generateMissionEndSummary(gameState: gameState))

        // 13. set flags
        gameState.missionComplete = true
        gameState.combatWon = won
        gameState.combatEnded = true

        // 14. post notification
        NotificationCenter.default.post(
            name: .combatAction,
            object: nil,
            userInfo: ["result": won ? "victory" : "defeat"]
        )
    }

    /// Heat is mission-boundary consequence state.
    /// v0.1 intentionally has no gameplay effect.
    static func finalizeMissionHeat(gameState: GameState) {
        let sourceTraceTier = gameState.traceTier
        let derivedTier = ConsequenceEngine.heatValue(fromTraceTier: sourceTraceTier)
        gameState.missionHeat = derivedTier
        gameState.missionHeatTier = ConsequenceEngine.heatTier(fromHeatValue: derivedTier)

        gameState.addLog("Mission complete: Heat level \(gameState.heatTierLabel) (derived from trace \(gameState.traceTierLabel))")
    }

    /// Heat -> world awareness scaffold.
    /// v0.1 only records/logs attention; it does not affect gameplay.
    static func applyFactionAttention(gameState: GameState, traceTier: Int) {
        let attentionResult = ConsequenceEngine.factionAttentionIncrement(for: gameState.missionHeatTier)
        let highTraceBonus = ConsequenceEngine.highTraceCorpEscalationBonus(traceTier: traceTier)
        gameState.factionAttention[.corp, default: 0] += attentionResult.increment + highTraceBonus
        gameState.didApplyHighTraceEscalationBonusLastMission = highTraceBonus > 0
        gameState.addLog(attentionResult.reactionLog)
        if highTraceBonus > 0 {
            gameState.addLog("High-profile operation increased corporate escalation risk.")
        }
        gameState.addLog("CORP ATTENTION: \(gameState.factionAttention[.corp, default: 0])")
    }

    static func applyGangAttention(gameState: GameState) {
        let increment = ConsequenceEngine.gangAttentionIncrement(for: gameState.missionHeatTier)
        gameState.factionAttention[.gang, default: 0] += increment
        gameState.addLog(OutcomePipeline.generateGangReactionMessage(gameState: gameState))
        gameState.addLog("GANG ATTENTION: \(gameState.factionAttention[.gang, default: 0])")
    }

    static func applyAttentionDecay(gameState: GameState, traceTier: Int) {
        let decayAmount = ConsequenceEngine.attentionDecayAmount(for: traceTier)
        guard decayAmount > 0 else {
            gameState.didApplyAttentionRecoveryLastMission = false
            return
        }

        gameState.factionAttention[.corp, default: 0] = max(0, gameState.factionAttention[.corp, default: 0] - decayAmount)
        gameState.factionAttention[.gang, default: 0] = max(0, gameState.factionAttention[.gang, default: 0] - decayAmount)
        gameState.didApplyAttentionRecoveryLastMission = true
        gameState.addLog("Attention reduced due to low-profile mission.")
    }

    static func finalizeRewardLayer(gameState: GameState) {
        let corpAttention = gameState.factionAttention[.corp, default: 0]
        let gangAttention = gameState.factionAttention[.gang, default: 0]
        let tier = ConsequenceEngine.rewardTier(
            heatTier: gameState.missionHeat,
            corpAttention: corpAttention,
            gangAttention: gangAttention
        )
        let multiplier = ConsequenceEngine.rewardMultiplier(for: tier)
        gameState.lastRewardTier = tier
        gameState.lastRewardMultiplier = multiplier
        let bonus: Double
        let bonusReason: String
        switch gameState.currentMissionType {
        case .stealth:
            if gameState.traceTier == 0 {
                bonus = 0.25
                bonusReason = "stealth success"
            } else {
                bonus = 0.0
                bonusReason = "no stealth bonus"
            }
        case .assault:
            if gameState.traceTier == 2 {
                bonus = 0.25
                bonusReason = "assault intensity"
            } else {
                bonus = 0.0
                bonusReason = "no assault bonus"
            }
        case .extraction:
            if gameState.traceTier == 1 {
                bonus = 0.15
                bonusReason = "balanced extraction"
            } else {
                bonus = 0.0
                bonusReason = "no extraction bonus"
            }
        }
        gameState.missionTypeBonusMultiplier = bonus

        gameState.addLog("Mission Type: \(gameState.missionTypeLabel)")
        gameState.addLog("Reward tier: \(OutcomePipeline.rewardTierLabel(tier)) (x\(String(format: "%.2f", multiplier)) payout)")
        if bonus > 0 {
            gameState.addLog("Mission bonus: +\(String(format: "%.2f", bonus)) (\(bonusReason))")
        }
        gameState.addLog("Final reward multiplier: x\(String(format: "%.2f", gameState.finalRewardMultiplier))")
        gameState.addLog(OutcomePipeline.generateRewardPayoutSummary(gameState: gameState))
    }

    static func generateWorldReactionMessage(gameState: GameState) -> String {
        let corpAttention = gameState.factionAttention[.corp, default: 0]
        return ConsequenceEngine.worldReactionMessage(
            missionHeatTier: gameState.missionHeatTier,
            corpAttention: corpAttention
        )
    }

    static func generateMissionModifierPreview(gameState: GameState) -> String {
        let corpAttention = gameState.factionAttention[.corp, default: 0]
        return ConsequenceEngine.missionModifierPreview(corpAttention: corpAttention)
    }

    static func generateGangReactionMessage(gameState: GameState) -> String {
        let gangAttention = gameState.factionAttention[.gang, default: 0]
        return ConsequenceEngine.gangReactionMessage(
            missionHeatTier: gameState.missionHeatTier,
            gangAttention: gangAttention
        )
    }

    static func generateGangMissionPreview(gameState: GameState) -> String {
        let gangAttention = gameState.factionAttention[.gang, default: 0]
        return ConsequenceEngine.gangMissionPreview(gangAttention: gangAttention)
    }

    static func generateCombinedPressurePreview(gameState: GameState) -> String {
        ConsequenceEngine.combinedPressurePreview(
            corpModifier: gameState.lastAppliedCorpEnemyModifier,
            gangRadius: gameState.lastAppliedGangAmbushRadius
        )
    }

    static func rewardTierLabel(_ tier: RewardTier) -> String {
        switch tier {
        case .low: return "LOW"
        case .medium: return "MED"
        case .high: return "HIGH"
        }
    }

    static func generateRewardPreview(gameState: GameState) -> String {
        switch gameState.lastRewardTier {
        case .low:
            return "Low risk operation. Standard payout."
        case .medium:
            return "Moderate risk. Increased payout expected."
        case .high:
            return "High risk operation. Significant rewards expected."
        }
    }

    static func generateRewardPayoutSummary(gameState: GameState) -> String {
        let emphasis: String
        switch gameState.lastRewardTier {
        case .high:
            emphasis = "HIGH RISK BONUS\n"
        case .medium:
            emphasis = "INCREASED PAYOUT\n"
        case .low:
            emphasis = ""
        }

        return """
        \(emphasis)MISSION PAYOUT:
        Base: \(gameState.baseMissionPayout)
        Risk Bonus: +\(gameState.riskBonus)
        Total: \(gameState.finalMissionPayout)
        """
    }

    static func generateMissionEndSummary(gameState: GameState) -> String {
        let corpAttention = gameState.factionAttention[.corp, default: 0]
        let gangAttention = gameState.factionAttention[.gang, default: 0]

        return """
        ------------------------

        MISSION COMPLETE

        Mission Type: \(gameState.missionTypeLabel)
        Pressure: \(gameState.traceTierLabel) (+\(gameState.escalationDamageBonusForCurrentTrace) dmg)
        Heat: \(gameState.heatTierLabel)
        Corp Attention: \(corpAttention)
        Gang Attention: \(gangAttention)

        COMBINED PRESSURE:
        \(generateCombinedPressurePreview(gameState: gameState))

        REWARD:
        Base: \(gameState.baseMissionPayout)
        Risk Bonus: +\(gameState.riskBonus)
        Total: \(gameState.finalMissionPayout)

        WORLD REACTION:
        \(generateWorldReactionMessage(gameState: gameState))

        NEXT MISSION:
        Corp: \(generateMissionModifierPreview(gameState: gameState))
        Gang: \(generateGangMissionPreview(gameState: gameState))

        ------------------------
        """
    }
}

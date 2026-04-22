import Foundation

@MainActor
struct ExtractionController {
    static func checkExtraction(gameState: GameState) {
        guard gameState.currentMissionType == .extraction else { return }
        // Both livingEnemies AND pendingSpawns must be empty before extraction is allowed.
        // This prevents premature victory when delayed reinforcements are still pending.
        guard gameState.livingEnemies.isEmpty && gameState.pendingSpawns.isEmpty else { return }
        let onExtraction = gameState.livingPlayers.contains {
            $0.positionX == gameState.extractionX && $0.positionY == gameState.extractionY
        }
        if onExtraction {
            OutcomePipeline.execute(
                gameState: gameState,
                won: true,
                missionLog: "🚁 EXTRACTION SUCCESS — Runners are out!",
                terminalLog: "=== VICTORY ==="
            )
        }
    }

    static func requestExtraction(
        gameState: GameState,
        characterId: UUID?,
        tileX: Int,
        tileY: Int
    ) -> Bool {
        guard !gameState.combatEnded else { return false }

        guard tileX == gameState.extractionX && tileY == gameState.extractionY else {
            gameState.addLog("That is not the extraction point.")
            return false
        }

        guard let id = characterId,
              let char = gameState.playerTeam.first(where: { $0.id == id && $0.isAlive }) else {
            gameState.addLog("Select a character, then step onto extraction.")
            return false
        }

        // Authority write: synchronize model-space position with the tile the player tapped.
        char.positionX = tileX
        char.positionY = tileY

        if !(gameState.livingEnemies.isEmpty && gameState.pendingSpawns.isEmpty) {
            gameState.addLog("Clear all enemies before extraction!")
            return false
        }

        checkExtraction(gameState: gameState)
        return true
    }

    static func extractionObjective(gameState: GameState) -> (x: Int, y: Int) {
        (x: gameState.extractionX, y: gameState.extractionY)
    }

    static func setExtractionObjective(gameState: GameState, x: Int, y: Int) {
        gameState.extractionX = x
        gameState.extractionY = y
    }
}

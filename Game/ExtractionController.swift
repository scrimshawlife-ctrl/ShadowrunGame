import Foundation

@MainActor
struct ExtractionController {
    static func checkExtraction(gameState: GameState) {
        CombatFlowController.adjudicateExtractionIfEligible(gameState: gameState)
    }

    static func requestExtraction(
        gameState: GameState,
        characterId: UUID?,
        tileX: Int,
        tileY: Int
    ) -> Bool {
        // ExtractionController is request shim only; CombatFlowController owns adjudication.
        CombatFlowController.requestExtraction(
            gameState: gameState,
            characterId: characterId,
            tileX: tileX,
            tileY: tileY
        )
    }

    static func extractionObjective(gameState: GameState) -> (x: Int, y: Int) {
        (x: gameState.extractionX, y: gameState.extractionY)
    }

    static func setExtractionObjective(gameState: GameState, x: Int, y: Int) {
        gameState.extractionX = x
        gameState.extractionY = y
    }
}

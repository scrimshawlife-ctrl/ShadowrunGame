import Foundation

// MARK: - Shared Notification Names

extension Notification.Name {
    static let characterSelected = Notification.Name("characterSelected")
    static let tileTapped     = Notification.Name("tileTapped")
    static let combatAction   = Notification.Name("combatAction")
    static let turnChanged    = Notification.Name("turnChanged")
    static let enemyHit       = Notification.Name("enemyHit")
    static let enemyDied      = Notification.Name("enemyDied")
    static let playerHit      = Notification.Name("playerHit")
    static let characterHit   = Notification.Name("characterHit")
    static let characterLevelUp = Notification.Name("characterLevelUp")
    static let enemyMoved     = Notification.Name("enemyMoved")
    static let enemySpawned    = Notification.Name("enemySpawned")
    static let characterDefend  = Notification.Name("characterDefend")
    static let roundStarted    = Notification.Name("roundStarted")
    static let roomCleared     = Notification.Name("roomCleared")
    static let enemyPhaseBegan  = Notification.Name("enemyPhaseBegan")
    static let playerTurnResumed = Notification.Name("playerTurnResumed")
    static let roomTransitionStarted = Notification.Name("roomTransitionStarted")
    static let roomTransitionCompleted = Notification.Name("roomTransitionCompleted")
    static let roomNavigationRequested = Notification.Name("roomNavigationRequested")
    static let enemyPhaseCompleted = Notification.Name("enemyPhaseCompleted")
}

// MARK: - Character Events

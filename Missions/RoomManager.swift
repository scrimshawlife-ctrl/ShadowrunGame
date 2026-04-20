import Foundation
import SpriteKit

// MARK: - Room Manager

/// Manages multi-room missions: tracks current room, handles transitions.
@MainActor
final class RoomManager: ObservableObject {

    static let shared = RoomManager()

    @Published private(set) var currentMission: MultiRoomMission?
    @Published private(set) var currentRoom: Room?
    @Published private(set) var currentRoomIndex: Int = 0
    @Published private(set) var isTransitioning: Bool = false

    /// Current room ID — BattleScene reads this to pass to attemptTransition.
    var currentRoomId: String { currentRoom?.id ?? "" }

    /// Set when a room transition is complete — BattleScene reads this to reload the map.
    var pendingRoomTransition: Room?

    /// Target spawn position from the RoomConnection used for door transitions.
    /// This is set by attemptTransition() so handleRoomTransitionCompleted can use
    /// connection.targetSpawn instead of room.playerSpawn.
    var pendingConnectionTargetX: Int?
    var pendingConnectionTargetY: Int?

    /// Tracks which rooms have been entered (for position-preservation on back-navigation).
    /// A room is "entered" if the player has loaded it at least once.
    /// First entry uses spawn; back-navigation preserves the player's last position in that room.
    private var enteredRoomIds: Set<String> = []

    /// Mark a room as entered (call before beginTransition so the flag is set
    /// before handleRoomTransitionCompleted checks it).
    func markRoomEntered(_ roomId: String) {
        enteredRoomIds.insert(roomId)
    }

    /// Returns true if the player has entered this room at least once before.
    func isRoomEntered(_ roomId: String) -> Bool {
        enteredRoomIds.contains(roomId)
    }

    private init() {}

    // MARK: - Setup

    /// Load a multi-room mission by id.
    @discardableResult
    func loadMission(named id: String) -> MultiRoomMission? {
        if let mission = MissionLoader.shared.loadMultiRoomMission(named: id) {
            currentMission = mission
            currentRoom = mission.rooms.first
            currentRoomIndex = 0
            return mission
        }
        return nil
    }

    /// Called by BattleScene when player steps on a door tile.
    /// Returns the target Room if a transition should occur.
    func attemptTransition(from roomId: String, atTileX x: Int, y: Int) -> Room? {
        guard !isTransitioning else { return nil }
        guard let room = currentMission?.rooms.first(where: { $0.id == roomId }) else { return nil }

        // Find a connection from this room at the given tile
        guard let connection = room.connections.first(where: {
            $0.triggerTileX == x && $0.triggerTileY == y
        }) else { return nil }

        // Find the target room
        guard let targetRoom = currentMission?.rooms.first(where: { $0.id == connection.targetRoomId }) else {
            return nil
        }

        // Store the connection's target spawn so handleRoomTransitionCompleted can use it
        // instead of room.playerSpawn (which may be on a different side of the room).
        pendingConnectionTargetX = connection.targetSpawnX
        pendingConnectionTargetY = connection.targetSpawnY

        return targetRoom
    }

    /// Begin the transition to a new room.
    /// The scene should call this, then perform the fade, then call completeTransition.
    func beginTransition(to targetRoom: Room) {
        isTransitioning = true
        pendingRoomTransition = targetRoom
    }

    /// Complete the transition — update current room state.
    func completeTransition(to room: Room) {
        currentRoom = room
        currentRoomIndex = currentMission?.rooms.firstIndex(where: { $0.id == room.id }) ?? 0
        isTransitioning = false
        pendingRoomTransition = nil
        pendingConnectionTargetX = nil
        pendingConnectionTargetY = nil
    }

    /// Cancel an in-progress transition (e.g., if combat state changed).
    func cancelTransition() {
        isTransitioning = false
        pendingRoomTransition = nil
    }

    /// Spawn position for the current room.
    var currentSpawn: SpawnPoint {
        currentRoom?.playerSpawn ?? SpawnPoint(x: 1, y: 16)
    }

    /// Build a TileMap for the current room.
    func currentTileMap() -> TileMap? {
        guard let room = currentRoom else { return nil }
        return TileMap(tiles: room.tileMap)
    }
}

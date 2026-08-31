import XCTest
#if canImport(HexWire)
@testable import HexWire

/// Spawn placement and seeded replay-encounter tests.
/// Tile legend: 0 floor, 1 wall, 2 cover, 3 door, 4 extraction, 5 terminal.
@MainActor
final class ReplaySpawnTests: XCTestCase {

    // MARK: - Backtrack spawn placement (door-mirrored)

    /// Walking BACK through a door must land the squad beside that door — the
    /// connection's authored targetSpawn — not at the room's original
    /// playerSpawn, which sits at the far end. Regression for the 2026-07-23
    /// fix; re-reported against M5 on 2026-07-25.
    func testBacktrackUsesConnectionTargetSpawnNotPlayerSpawn() throws {
        struct Case { let mission: String; let from: String; let doorX: Int; let doorY: Int }
        let cases = [
            Case(mission: "Mission001", from: "room_2", doorX: 3, doorY: 1),
            Case(mission: "Mission005", from: "room_2", doorX: 3, doorY: 1),
        ]
        for c in cases {
            RoomManager.shared.unloadMission()
            guard let mission = RoomManager.shared.loadMission(named: c.mission) else {
                throw XCTSkip("mission JSONs not bundled")
            }
            guard let source = mission.rooms.first(where: { $0.id == c.from }),
                  let conn = source.connections.first(where: {
                      $0.triggerTileX == c.doorX && $0.triggerTileY == c.doorY
                  }),
                  let target = mission.rooms.first(where: { $0.id == conn.targetRoomId })
            else { return XCTFail("\(c.mission): no connection at (\(c.doorX),\(c.doorY)) in \(c.from)") }

            // Simulate having already been in the target room, then walking back.
            RoomManager.shared.markRoomEntered(target.id)
            RoomManager.shared.markRoomEntered(source.id)
            GameState.shared.playerIsDead = false
            _ = RoomManager.shared.attemptTransition(from: c.from, atTileX: c.doorX, y: c.doorY)

            XCTAssertEqual(RoomManager.shared.pendingConnectionTargetX, conn.targetSpawnX,
                           "\(c.mission) \(c.from)->\(target.id): must use the door's targetSpawn x")
            XCTAssertEqual(RoomManager.shared.pendingConnectionTargetY, conn.targetSpawnY,
                           "\(c.mission) \(c.from)->\(target.id): must use the door's targetSpawn y")
            XCTAssertNotEqual(RoomManager.shared.pendingConnectionTargetY, target.playerSpawn.y,
                              "\(c.mission): backtrack must NOT fall back to playerSpawn "
                              + "(\(target.playerSpawn.x),\(target.playerSpawn.y)) — that is the far end")
        }
        RoomManager.shared.unloadMission()
    }

    /// A door back to a room you have already entered is walkable even while
    /// the current room is uncleared (attemptTransition waives the requirement),
    /// so it must not be PAINTED as locked. Playtest 2026-07-25, M5R2: "it shows
    /// the door you just came through as locked ... can easily just walk back
    /// through it, so it is not locked."
    func testBacktrackDoorIsNotLockedWhileRoomUncleared() throws {
        RoomManager.shared.unloadMission()
        guard let mission = RoomManager.shared.loadMission(named: "Mission005") else {
            throw XCTSkip("mission JSONs not bundled")
        }
        guard let room2 = mission.rooms.first(where: { $0.id == "room_2" }),
              let back = room2.connections.first(where: { $0.targetRoomId == "room_1" }),
              let fwd  = room2.connections.first(where: { $0.targetRoomId == "room_3" })
        else { return XCTFail("M5 room_2 connections missing") }

        // Player has been through room_1 and is now standing in an UNCLEARED room_2.
        RoomManager.shared.markRoomEntered("room_1")
        RoomManager.shared.markRoomEntered("room_2")
        XCTAssertFalse(RoomManager.shared.isRoomCleared("room_2"))

        XCTAssertTrue(RoomManager.shared.doorIsBacktrack(inRoom: "room_2",
                                                         tileX: back.triggerTileX,
                                                         y: back.triggerTileY),
                      "the door back to room_1 must read as an open backtrack door")
        XCTAssertFalse(RoomManager.shared.doorIsBacktrack(inRoom: "room_2",
                                                          tileX: fwd.triggerTileX,
                                                          y: fwd.triggerTileY),
                       "the door onward to an UNVISITED room must still read as locked")
        RoomManager.shared.unloadMission()
    }

    // MARK: - Backtrack patrols

    private func patrolRoom(id: String = "patrol_room") -> Room {
        Room(id: id, title: "t",
             map: [
                [1, 1, 1, 1, 1, 1],
                [1, 0, 0, 0, 0, 1],
                [1, 0, 0, 0, 0, 1],
                [1, 0, 0, 0, 0, 1],
                [1, 1, 1, 1, 1, 1],
             ],
             playerSpawn: SpawnPoint(x: 1, y: 1),
             extractionPoint: nil,
             enemies: [
                EnemySpawn(type: "guard", x: 1, y: 3, delay: 0),
                EnemySpawn(type: "juggernaut", x: 4, y: 3, delay: 0),
                EnemySpawn(type: "drone", x: 4, y: 1, delay: 0),
             ],
             connections: [], removeOnFirstKill: nil, bossSpawn: nil)
    }

    /// The roll must be fixed for a given visit — walking out and back in
    /// cannot be used to re-roll a patrol the player didn't like.
    func testBacktrackPatrolIsDeterministicForAGivenVisit() {
        let room = patrolRoom()
        RoomManager.shared.patrolRespawnedRoomIds.removeAll()
        let a = MissionSetupService.backtrackPatrol(
            for: room, gameState: GameState.shared, entryX: 1, entryY: 1)
        let b = MissionSetupService.backtrackPatrol(
            for: room, gameState: GameState.shared, entryX: 1, entryY: 1)
        XCTAssertEqual(a.map { "\($0.type)@\($0.x),\($0.y)" },
                       b.map { "\($0.type)@\($0.x),\($0.y)" },
                       "same attempt + room + visit must roll identically")
    }

    /// Occasional means occasional: across many rooms it must fire sometimes
    /// and stay quiet sometimes. A patrol every single time turns backtracking
    /// into a chore; never firing means the feature does nothing.
    func testBacktrackPatrolFiresSometimesNotAlways() {
        var fired = 0
        let trials = 60
        for i in 0..<trials {
            RoomManager.shared.patrolRespawnedRoomIds.removeAll()
            let room = patrolRoom(id: "room_\(i)")
            if !MissionSetupService.backtrackPatrol(
                for: room, gameState: GameState.shared, entryX: 1, entryY: 1).isEmpty {
                fired += 1
            }
        }
        XCTAssertGreaterThan(fired, 0, "patrols must actually happen")
        XCTAssertLessThan(fired, trials, "patrols must not be guaranteed")
    }

    /// One patrol per room per attempt — otherwise a corridor between two
    /// objectives becomes an infinite XP/nuyen faucet.
    func testBacktrackPatrolOnlyOncePerRoom() {
        RoomManager.shared.patrolRespawnedRoomIds.removeAll()
        // Find a room id that does roll a patrol, then re-ask after marking it.
        var seeded: Room?
        for i in 0..<80 {
            let candidate = patrolRoom(id: "once_\(i)")
            if !MissionSetupService.backtrackPatrol(
                for: candidate, gameState: GameState.shared, entryX: 1, entryY: 1).isEmpty {
                seeded = candidate
                break
            }
        }
        guard let room = seeded else {
            return XCTFail("no seed produced a patrol — chance constant may be broken")
        }
        RoomManager.shared.patrolRespawnedRoomIds.insert(room.id)
        XCTAssertTrue(MissionSetupService.backtrackPatrol(
            for: room, gameState: GameState.shared, entryX: 1, entryY: 1).isEmpty,
            "a room that already coughed up a patrol must not do it again")
        RoomManager.shared.patrolRespawnedRoomIds.removeAll()
    }

    /// A patrol must never draw the room's heaviest authored type, and must
    /// never materialise on top of the party's entry tile.
    func testBacktrackPatrolStaysCheapAndAwayFromEntry() {
        RoomManager.shared.patrolRespawnedRoomIds.removeAll()
        for i in 0..<80 {
            let room = patrolRoom(id: "cheap_\(i)")
            let patrol = MissionSetupService.backtrackPatrol(
                for: room, gameState: GameState.shared, entryX: 1, entryY: 1)
            guard !patrol.isEmpty else { continue }
            for s in patrol {
                XCTAssertNotEqual(s.type, "juggernaut",
                                  "patrol must draw the cheapest authored type, not the heaviest")
                XCTAssertFalse(s.x == 1 && s.y == 1, "patrol must not spawn on the entry tile")
            }
            XCTAssertLessThanOrEqual(patrol.count, 2, "patrol is a squad of 1-2")
        }
        RoomManager.shared.patrolRespawnedRoomIds.removeAll()
    }

    // MARK: - Party spawn placement (pure)

    func testGroupSpawnSlotsAreDeterministicDistinctAndWalkable() {
        let map = [
            [1, 1, 1, 1, 1, 1],
            [1, 0, 0, 2, 0, 1],
            [1, 0, 1, 0, 0, 1],
            [1, 1, 1, 1, 1, 1],
        ]
        let anchor = SpawnPoint(x: 1, y: 1)
        let a = MissionSetupService.findGroupSpawnSlots(map: map, anchor: anchor, count: 4)
        let b = MissionSetupService.findGroupSpawnSlots(map: map, anchor: anchor, count: 4)
        XCTAssertEqual(a.map { "\($0.x),\($0.y)" }, b.map { "\($0.x),\($0.y)" },
                       "same inputs must place the party identically")
        XCTAssertEqual(Set(a.map { "\($0.x),\($0.y)" }).count, a.count, "no two runners share a tile")
        for p in a {
            XCTAssertTrue(p.y >= 0 && p.y < map.count && p.x >= 0 && p.x < map[0].count,
                          "spawn (\(p.x),\(p.y)) out of bounds")
            let t = map[p.y][p.x]
            XCTAssertTrue([0, 2, 5].contains(t), "spawn (\(p.x),\(p.y)) on non-walkable tile \(t)")
        }
    }

    func testGroupSpawnSlotsExcludeDoorsExtractionAndOccupiedTiles() {
        let map = [
            [3, 0, 0, 4, 0],
            [0, 0, 0, 0, 0],
        ]
        let occupied: Set<String> = ["1,0"]   // an enemy stands here
        let slots = MissionSetupService.findGroupSpawnSlots(
            map: map, anchor: SpawnPoint(x: 0, y: 0), count: 4, occupied: occupied)
        for p in slots {
            XCTAssertNotEqual(map[p.y][p.x], 3, "runner must not spawn on a door")
            XCTAssertNotEqual(map[p.y][p.x], 4, "runner must not spawn on the extraction pad")
            XCTAssertFalse(occupied.contains("\(p.x),\(p.y)"), "runner must not spawn on an enemy")
        }
    }

    func testOverflowRunnersSpreadFromBottomRowsWhenEnteringLow() {
        // Entry point in the BOTTOM half, entry row nearly full: overflow
        // runners must fan out across walkable tiles sweeping from the bottom
        // rows up — never stack on the anchor.
        let map = [
            [0, 0, 0, 0, 0, 0],   // y0 — open top row (should be used LAST)
            [1, 1, 1, 1, 1, 0],   // y1
            [1, 1, 1, 1, 1, 1],   // y2
            [0, 1, 1, 1, 1, 1],   // y3 — entry corner, isolated from its row
        ]
        let anchor = SpawnPoint(x: 0, y: 3)
        let slots = MissionSetupService.findGroupSpawnSlots(map: map, anchor: anchor, count: 4)
        XCTAssertEqual(slots.count, 4)
        XCTAssertEqual(Set(slots.map { "\($0.x),\($0.y)" }).count, 4,
                       "runners must spread out, not stack")
        for p in slots {
            XCTAssertEqual(map[p.y][p.x], 0, "every slot is walkable")
        }
        // Bottom-up sweep: the isolated y1 tile seats before any top-row tile.
        XCTAssertTrue(slots.contains { $0.x == 5 && $0.y == 1 },
                      "bottom-up sweep must reach (5,1) before falling back to the top row")
        let again = MissionSetupService.findGroupSpawnSlots(map: map, anchor: anchor, count: 4)
        XCTAssertEqual(again.map { "\($0.x),\($0.y)" }, slots.map { "\($0.x),\($0.y)" },
                       "placement is deterministic")
    }

    func testOverflowRunnersSpreadAcrossTopRowWhenEnteringHigh() {
        // Entry point in the TOP half with a blocked entry row: the overflow
        // sweep starts at the top row so the team lines the entry edge.
        let map = [
            [0, 1, 1, 0, 0, 0],   // y0 — entry row, anchor isolated at x0
            [1, 1, 1, 1, 1, 1],   // y1
            [1, 1, 1, 1, 1, 1],   // y2
            [0, 0, 0, 0, 0, 0],   // y3 — open bottom row (should NOT be used)
        ]
        let anchor = SpawnPoint(x: 0, y: 0)
        let slots = MissionSetupService.findGroupSpawnSlots(map: map, anchor: anchor, count: 4)
        XCTAssertEqual(Set(slots.map { "\($0.x),\($0.y)" }).count, 4, "no stacking")
        XCTAssertTrue(slots.allSatisfy { $0.y == 0 },
                      "entering from the top must seat the whole team on top-row tiles")
    }

    func testAbsoluteLastResortStacksOnlyWhenRoomIsSmallerThanTeam() {
        // Fewer walkable tiles than runners: the two real tiles are used
        // first; only the unseatable remainder repeats the anchor.
        let map = [[1, 0, 1], [1, 0, 1]]
        let anchor = SpawnPoint(x: 1, y: 0)
        let slots = MissionSetupService.findGroupSpawnSlots(map: map, anchor: anchor, count: 4)
        XCTAssertEqual(slots.count, 4, "caller always receives a slot per runner")
        for p in slots { XCTAssertEqual(map[p.y][p.x], 0, "never on a wall") }
        XCTAssertEqual(Set(slots.map { "\($0.x),\($0.y)" }), ["1,0", "1,1"],
                       "every distinct walkable tile is used before any repeat")
    }

    // MARK: - NG+ extra enemy placement

    func testNGPlusExtraEnemiesRespectOccupancyFloorAndCount() {
        let store = NGPlusStore.shared
        let savedTier = store.tier
        defer { store.tier = savedTier }

        store.tier = 0
        XCTAssertTrue(MissionSetupService.ngPlusExtraEnemies(
            gameState: GameState.shared, map: [[0, 0], [0, 0]], occupied: []).isEmpty,
            "first playthrough gets no extra enemies")

        store.tier = 1   // extraEnemiesPerRoom == 1
        let map = [
            [1, 1, 1],
            [0, 2, 0],   // one cover tile — extras must land on FLOOR only
            [0, 0, 0],
        ]
        let occupied: Set<String> = ["0,2", "1,2", "2,2", "0,1"]  // bottom row + one more taken
        let extras = MissionSetupService.ngPlusExtraEnemies(
            gameState: GameState.shared, map: map, occupied: occupied)
        XCTAssertEqual(extras.count, 1)
        for e in extras {
            XCTAssertEqual(map[e.positionY][e.positionX], 0, "extra enemy must stand on floor")
            XCTAssertFalse(occupied.contains("\(e.positionX),\(e.positionY)"),
                           "extra enemy must not stack on an occupied tile")
        }
    }

    // MARK: - Seeded replay squad rerolls

    private let statsKeys = [
        "HexWire.MissionStats.v1", "HexWire.MissionStats.v1.lastGood",
        "HexWire.PlayerNuyen.v1", "HexWire.PaidThisRun.v1",
    ]
    private var statsSnapshot: [String: Any] = [:]

    private func snapshotStats() {
        statsSnapshot = [:]
        for key in statsKeys {
            if let v = UserDefaults.standard.object(forKey: key) { statsSnapshot[key] = v }
        }
    }

    private func restoreStats() {
        MissionStatsStore.shared.resetAll()   // zero memory+disk BEFORE restoring
        for key in statsKeys { UserDefaults.standard.removeObject(forKey: key) }
        for (key, v) in statsSnapshot { UserDefaults.standard.set(v, forKey: key) }
        RoomManager.shared.unloadMission()
        GameState.shared.currentMissionDisplayId = nil
        GameState.shared.missionAttemptId = 0
    }

    /// Load a real authored mission and return a room with enough enemies to
    /// make reroll assertions meaningful.
    private func loadReplayFixture() throws -> Room {
        snapshotStats()
        guard let mission = RoomManager.shared.loadMission(named: "Mission005") else {
            throw XCTSkip("Mission005 JSON not bundled in test host")
        }
        guard let room = mission.rooms.first(where: { $0.enemies.count >= 3 }) else {
            throw XCTSkip("no room with ≥3 enemies in Mission005")
        }
        GameState.shared.currentMissionDisplayId = "Mission005"
        MissionStatsStore.shared.resetAll()
        // attempts > 0 marks this a REPLAY, which arms the reroll path.
        MissionStatsStore.shared.recordVictory(missionId: "Mission005", score: 1)
        return room
    }

    func testFirstClearKeepsAuthoredSquadVerbatim() throws {
        snapshotStats()
        defer { restoreStats() }
        guard let mission = RoomManager.shared.loadMission(named: "Mission005"),
              let room = mission.rooms.first(where: { $0.enemies.count >= 3 }) else {
            throw XCTSkip("Mission005 fixture unavailable")
        }
        GameState.shared.currentMissionDisplayId = "Mission005"
        MissionStatsStore.shared.resetAll()   // zero attempts = first clear
        let squad = MissionSetupService.replaySquad(for: room, gameState: GameState.shared)
        XCTAssertEqual(squad.map(\.type), room.enemies.map(\.type),
                       "first clears must field the hand-authored squad")
    }

    func testReplaySquadIsDeterministicForSameAttempt() throws {
        defer { restoreStats() }
        let room = try loadReplayFixture()
        GameState.shared.missionAttemptId = 424_242
        let a = MissionSetupService.replaySquad(for: room, gameState: GameState.shared)
        let b = MissionSetupService.replaySquad(for: room, gameState: GameState.shared)
        XCTAssertEqual(a.map(\.type), b.map(\.type),
                       "same attempt + room must rebuild the same squad (no door-flap scumming)")
    }

    func testReplaySquadKeepsPositionsDelaysAndThreatBudget() throws {
        defer { restoreStats() }
        let room = try loadReplayFixture()
        GameState.shared.missionAttemptId = 77
        let squad = MissionSetupService.replaySquad(for: room, gameState: GameState.shared)
        XCTAssertEqual(squad.count, room.enemies.count, "reroll never adds or removes slots")

        guard let mission = RoomManager.shared.currentMission else { return XCTFail() }
        var authoredPool = Set<String>()
        for r in mission.rooms {
            for s in r.enemies where MissionSetupService.spawnCost[s.type] != nil {
                authoredPool.insert(s.type)
            }
        }
        for (orig, rolled) in zip(room.enemies, squad) {
            XCTAssertEqual(rolled.x, orig.x, "authored spatial design is preserved")
            XCTAssertEqual(rolled.y, orig.y)
            XCTAssertEqual(rolled.delay, orig.delay)
            if let origCost = MissionSetupService.spawnCost[orig.type] {
                guard let newCost = MissionSetupService.spawnCost[rolled.type] else {
                    return XCTFail("rerolled type \(rolled.type) has no cost — outside the budget table")
                }
                XCTAssertLessThanOrEqual(abs(newCost - origCost), 1,
                                         "\(orig.type)→\(rolled.type) breaks the ±1 threat budget")
                XCTAssertTrue(authoredPool.contains(rolled.type),
                              "\(rolled.type) was never authored in this mission")
            } else {
                XCTAssertEqual(rolled.type, orig.type,
                               "boss/unknown slots must never reroll")
            }
        }
    }

    func testDifferentAttemptsProduceVariation() throws {
        defer { restoreStats() }
        let room = try loadReplayFixture()
        var outcomes = Set<String>()
        for attempt in 1...30 {
            GameState.shared.missionAttemptId = attempt
            let squad = MissionSetupService.replaySquad(for: room, gameState: GameState.shared)
            outcomes.insert(squad.map(\.type).joined(separator: ","))
        }
        XCTAssertGreaterThan(outcomes.count, 1,
                             "30 attempts should not all roll the identical squad")
    }
}
#endif

import Foundation

@MainActor
struct MissionSetupService {
    @discardableResult
    static func prepareMissionForCombat(gameState: GameState, missionId: String?) -> String {
        let resolvedMissionId = missionId ?? "Mission001"

        // Clear the combat log so stale lines from a PREVIOUS mission (e.g.
        // "move adjacent first") don't bleed into the next mission's opening
        // screen under the "select a runner" prompt while the tutorial is up.
        gameState.combatLog.removeAll()

        // currentMissionDisplayId is assigned BEFORE setup runs — setup reads
        // it for the payout preview and the replay-variant gate, and when it
        // was assigned afterwards those reads saw the PREVIOUS load's id
        // (a stale id could grant another mission's variant roll and quote
        // the wrong contract in the debrief).
        if let multiMission = MissionLoader.shared.loadMultiRoomMission(named: resolvedMissionId) {
            gameState.currentMissionDisplayId = resolvedMissionId
            RoomManager.shared.loadMission(named: resolvedMissionId)
            setupMultiRoomMission(gameState: gameState, mission: multiMission)
            return resolvedMissionId
        }

        if let mission = MissionLoader.shared.loadMission(named: resolvedMissionId) {
            gameState.currentMissionDisplayId = resolvedMissionId
            setupMission(gameState: gameState, mission: mission)
            return resolvedMissionId
        }

        // Ultimate fallback: every shipped mission has a multi-room variant.
        if let fallbackMulti = MissionLoader.shared.loadMultiRoomMission(named: "Mission001") {
            gameState.currentMissionDisplayId = "Mission001"
            RoomManager.shared.loadMission(named: "Mission001")
            setupMultiRoomMission(gameState: gameState, mission: fallbackMulti)
            return "Mission001"
        }
        return resolvedMissionId
    }

    private static func archetypeLabel(_ archetype: EnemyArchetype) -> String {
        switch archetype {
        case .watcher: return "Watcher"
        case .enforcer: return "Enforcer"
        case .interceptor: return "Interceptor"
        }
    }

    static func setupMission(gameState: GameState, mission: Mission) {
        dlog("[GameState] setupMission: \(mission.title)")
        // Invalidate every deferred closure armed by a previous attempt.
        gameState.missionAttemptId += 1
        gameState.riggerSummons.removeAll()
        RoomManager.shared.unloadMission()
        // Carry progression across missions/runs: load the saved roster
        // (freshened to full HP, keeping level/xp/stats). First mission of a
        // brand-new game falls back to the default Level-1 runners.
        gameState.playerTeam = RosterStore.shared.loadForMission() ?? Character.allRunners
        // Fresh per-mission consumable loadout, seeded from purchased stims.
        gameState.loot = seedLootFromRoster(gameState.playerTeam)
        let spawn = mission.playerSpawn
        let positions = findGroupSpawnSlots(map: mission.map, anchor: spawn, count: gameState.playerTeam.count)
        for (i, char) in gameState.playerTeam.enumerated() {
            let p = positions[i]
            char.positionX = p.x
            char.positionY = p.y
        }

        gameState.enemies = []
        gameState.pendingSpawns = []
        assignMissionTypeForCurrentLoad(gameState: gameState)

        for (spawnIndex, spawn) in mission.enemies.enumerated() {
            let archetype = archetypeForSpawnIndex(gameState: gameState, spawnIndex: spawnIndex)
            let enemy = makeEnemy(gameState: gameState, for: spawn.type, archetype: archetype)
            enemy.positionX = spawn.x
            enemy.positionY = spawn.y

            if spawn.delay == 0 {
                gameState.enemies.append(enemy)
                gameState.addLog("\(archetypeLabel(archetype)) deployed")
            } else {
                gameState.pendingSpawns.append(GameState.PendingSpawn(enemy: enemy, delayRounds: spawn.delay))
            }
        }
        // New Game+ extras for this (single-room) mission.
        let singleRoomOccupied = Set(
            gameState.enemies.map { "\($0.positionX),\($0.positionY)" }
            + gameState.pendingSpawns.map { "\($0.enemy.positionX),\($0.enemy.positionY)" }
            + [ "\(mission.playerSpawn.x),\(mission.playerSpawn.y)" ]
        )
        gameState.enemies.append(contentsOf: ngPlusExtraEnemies(
            gameState: gameState, map: mission.map, occupied: singleRoomOccupied))

        let protectedTiles = Set(
            mission.enemies.map { tileKey(gameState: gameState, x: $0.x, y: $0.y) } +
            [tileKey(gameState: gameState, x: mission.playerSpawn.x, y: mission.playerSpawn.y)]
        )
        let adjustedMissionMap = applyMapSituation(
            gameState: gameState,
            to: mission.map,
            extractionPoint: (mission.extractionPoint.x, mission.extractionPoint.y),
            protectedTiles: protectedTiles
        )
        gameState.currentMissionTiles = adjustedMissionMap.0

        gameState.missionRequiresData = mapContainsDataTerminal(gameState.currentMissionTiles)
        gameState.dataAcquired = false
        gameState.grimoireAcquired = false   // M3 bonus item — reset per attempt (single-room)
        // Defensive: if combat ended/aborted with the matrix mini-game flag
        // still up, the next mission would open with the overlay stuck (and
        // music parked ducked). Every other setup flag is zeroed here.
        gameState.showMatrixMiniGame = false
        gameState.mageBossPhase2Triggered = false   // M3 boss phase 2 — reset per attempt
        gameState.mageBossPhase2Pending = false
        gameState.mageBossPendingSpawnX = 0
        gameState.mageBossPendingSpawnY = 0
        if gameState.missionRequiresData {
            gameState.addLog("OBJECTIVE — Hack data terminal (cyan tile) before extracting.")
        }

        gameState.currentTurnIndex = 0
        gameState.roundNumber = 1
        gameState.enemyPhaseCount = 0
        gameState.traceLevel = 0
        gameState.traceEscalationLevel = 0
        gameState.traceHighAlertFired = false
        gameState.traceEscalationLevel = 0
        gameState.hasLoggedTraceTriggerForCurrentRun = false
        gameState.actionMode = .street
        logEnemyComposition(gameState: gameState, totalSpawnCount: mission.enemies.count)
        CombatFlowController.resetCombatOutcomeFlagsForNewMission(gameState: gameState)
        gameState.didApplyAttentionRecoveryLastMission = false
        gameState.didApplyHighTraceEscalationBonusLastMission = false
        gameState.lastRewardTier = .low
        gameState.lastRewardMultiplier = 1.0
        gameState.missionTypeBonusMultiplier = 0.0
        // Seed the debrief's Base/Risk/Total payout preview with the REAL
        // contract value. baseMissionPayout was never assigned before, so the
        // reward summary showed a meaningless "Base 100 / Total 125"
        // placeholder next to a wallet that moved by thousands.
        gameState.baseMissionPayout = MissionStatsStore.basePayout(
            missionId: gameState.currentMissionDisplayId ?? "Mission001")
        gameState.missionHeat = 0
        gameState.missionHeatTier = .low
        gameState.currentTurnCount = 0
        gameState.missionEnemiesDefeated = 0
        gameState.firstKillProcessedInRoom = false
        // Refresh per-mission charges (Blitz, etc.) on each new run.
        for char in gameState.playerTeam { char.blitzChargesUsed = 0 }
        gameState.combatLog = ["Mission started: \(mission.title)"]
        gameState.extractionX = adjustedMissionMap.1.x
        gameState.extractionY = adjustedMissionMap.1.y
        applyCorpAttentionEnemyInfluence(
            gameState: gameState,
            spawnTemplates: mission.enemies.map { ($0.type, $0.x, $0.y) },
            map: gameState.currentMissionTiles
        )
        applyGangAmbushBias(gameState: gameState, map: gameState.currentMissionTiles)
        gameState.addLog(gameState.generateCombinedPressurePreview())
        gameState.addLog(gameState.generateMissionBriefing())
        gameState.addLog("Reach extraction at (\(gameState.extractionX), \(gameState.extractionY))")
        processDelayedSpawns(gameState: gameState, enemyPhaseIndex: 0)
        gameState.activeCharacterId = gameState.playerTeam.first?.id
        gameState.selectedCharacterId = gameState.playerTeam.first?.id
        gameState.beginRound()
        gameState.isEnemyPhaseRunning = false
        gameState.addLog("『 BATTLE START — SELECT A RUNNER 』")
    }

    static func setupMultiRoomMission(gameState: GameState, mission: MultiRoomMission) {
        dlog("[GameState] setupMultiRoomMission: \(mission.title)")
        // Invalidate every deferred closure armed by a previous attempt.
        gameState.missionAttemptId += 1
        gameState.riggerSummons.removeAll()
        // BUG FIX 2026-05-10: zero out terminal-state flags from any previous
        // run BEFORE we start setting up the new one. The "M3 first-time-only
        // RUN COMPLETE" repro happens when the user finishes M2, then enters
        // M3 — stale extractionAnimationInProgress / combatEnded / combatWon
        // from M2's extraction win leak into M3 setup, and some observer
        // fires the debrief overlay before this method finishes setting up.
        // Resetting them up-front (not just via resetCombatOutcomeFlags below)
        // guarantees no terminal flag is true during the setup window.
        CombatFlowController.resetCombatOutcomeFlagsForNewMission(gameState: gameState)
        gameState.extractionAnimationInProgress = false
        gameState.combatEnded = false
        gameState.missionComplete = false
        gameState.combatWon = nil
        // Carry progression across missions/runs: load the saved roster
        // (freshened to full HP, keeping level/xp/stats). First mission of a
        // brand-new game falls back to the default Level-1 runners.
        gameState.playerTeam = RosterStore.shared.loadForMission() ?? Character.allRunners
        // Fresh per-mission consumable loadout, seeded from purchased stims.
        gameState.loot = seedLootFromRoster(gameState.playerTeam)

        let firstRoom = mission.rooms.first!
        RoomManager.shared.markRoomEntered(firstRoom.id)
        let spawn = firstRoom.playerSpawn
        let positions = findGroupSpawnSlots(map: firstRoom.map, anchor: spawn, count: gameState.playerTeam.count)
        for (i, char) in gameState.playerTeam.enumerated() {
            let p = positions[i]
            char.positionX = p.x
            char.positionY = p.y
        }

        gameState.enemies = []
        gameState.pendingSpawns = []
        assignMissionTypeForCurrentLoad(gameState: gameState)
        // Multi-room missions are structured around door progression to a final
        // extraction tile. The FIRST clear of any mission always plays the
        // authored .extraction contract. On REPLAYS of boss-less missions
        // (M1/M2) the rolled variant is allowed to stand — the multi-room win
        // checks in CombatFlowController were hardened since this override
        // was written (stealth requires areAllRoomsCleared, assault requires
        // isLastRoom + room cleared), so neither can complete in room_0.
        // Variants give replays a different playstyle contract: stealth pays
        // +25% for a trace-0 run, assault pays +25% for going loud, and both
        // reroll the enemy archetype pattern. Boss missions stay
        // extraction-only (M3's scripted Sato phase-2 and the M4-6 bossSpawn
        // door seals assume the extraction flow).
        let missionId = gameState.currentMissionDisplayId ?? ""
        // NOTE: currentMissionDisplayId is assigned by prepareMissionForCombat
        // AFTER this setup runs, so `missionId` here is the PREVIOUS load's id.
        // For story missions that's benign (a stale id only mis-grants a
        // variant when the previous mission happened to be an M1/M2 replay),
        // but an armed Endless Gauntlet floor must ALWAYS play the authored
        // .extraction contract — the gauntlet's underlying mission is randomly
        // one of M1/M2/M4/M5 and a stale "Mission001" id could otherwise let
        // a stealth/assault variant leak onto the floor. Gate it explicitly.
        let variantEligible = ["Mission001", "Mission002"].contains(missionId)
            && MissionStatsStore.shared.record(for: missionId).attempts > 0
            && !GauntletStore.shared.isActive
        if gameState.currentMissionType != .extraction && !variantEligible {
            gameState.currentMissionType = .extraction
            gameState.currentMapSituation = .chokepoint
            gameState.addLog("MISSION TYPE — \(gameState.missionTypeLabel) (multi-room override)")
        }
        if gameState.currentMissionType == .stealth {
            // The 6-turn default window is tuned for single-room skirmishes; a
            // multi-room crawl needs room to breathe. currentTurnCount ticks
            // once per PLAYER turn (4 runners ≈ 4 ticks/round), so 12 per
            // room ≈ 3 rounds a room — tight enough to matter, loose enough
            // to be winnable.
            gameState.missionTargetTurns = mission.rooms.count * 12
        }

        // Load mission story/briefing text from JSON
        if let briefing = mission.briefing {
            gameState.briefingText = briefing
        }
        if let summary = mission.missionCompleteSummary {
            gameState.missionCompleteSummaryText = summary
        }

        for (spawnIndex, spawn) in replaySquad(for: firstRoom, gameState: gameState).enumerated() {
            let archetype = archetypeForSpawnIndex(gameState: gameState, spawnIndex: spawnIndex)
            let enemy = makeEnemy(gameState: gameState, for: spawn.type, archetype: archetype)
            enemy.positionX = spawn.x
            enemy.positionY = spawn.y

            if spawn.delay == 0 {
                gameState.enemies.append(enemy)
                gameState.addLog("\(archetypeLabel(archetype)) deployed")
            } else {
                gameState.pendingSpawns.append(GameState.PendingSpawn(enemy: enemy, delayRounds: spawn.delay))
            }
        }
        // New Game+ extras for the opening room.
        let firstRoomOccupied = Set(
            gameState.enemies.map { "\($0.positionX),\($0.positionY)" }
            + gameState.pendingSpawns.map { "\($0.enemy.positionX),\($0.enemy.positionY)" }
            + [ "\(firstRoom.playerSpawn.x),\(firstRoom.playerSpawn.y)" ]
        )
        gameState.enemies.append(contentsOf: ngPlusExtraEnemies(
            gameState: gameState, map: firstRoom.map, occupied: firstRoomOccupied))

        let firstRoomExtraction = firstRoom.extractionPoint ?? SpawnPoint(x: firstRoom.playerSpawn.x, y: firstRoom.playerSpawn.y)
        // Multi-room missions are hand-authored — respect the JSON map exactly.
        // applyMapSituation rewrites cover/floor tiles for single-shot missions to
        // give them a procedural variation, but for multi-room runs the level
        // designer placed crates / barriers deliberately. Skip the transform so
        // we don't sprinkle extra cover into open dock floors and chambers.
        gameState.currentMissionTiles = firstRoom.map

        gameState.missionRequiresData = anyRoomHasDataTerminal(rooms: mission.rooms)
        gameState.dataAcquired = false
        gameState.grimoireAcquired = false   // M3 bonus item — reset per attempt
        gameState.showMatrixMiniGame = false // see single-room note above
        gameState.mageBossPhase2Triggered = false   // M3 boss phase 2 — reset per attempt
        gameState.mageBossPhase2Pending = false
        gameState.mageBossPendingSpawnX = 0
        gameState.mageBossPendingSpawnY = 0
        if gameState.missionRequiresData {
            gameState.addLog("OBJECTIVE — Hack data terminal (cyan tile) before extracting.")
        }

        gameState.currentRoomId = firstRoom.id

        gameState.currentTurnIndex = 0
        gameState.roundNumber = 1
        gameState.enemyPhaseCount = 0
        gameState.traceLevel = 0
        gameState.traceEscalationLevel = 0
        gameState.traceHighAlertFired = false
        gameState.traceEscalationLevel = 0
        gameState.hasLoggedTraceTriggerForCurrentRun = false
        gameState.actionMode = .street
        logEnemyComposition(gameState: gameState, totalSpawnCount: firstRoom.enemies.count)
        CombatFlowController.resetCombatOutcomeFlagsForNewMission(gameState: gameState)
        gameState.didApplyAttentionRecoveryLastMission = false
        gameState.didApplyHighTraceEscalationBonusLastMission = false
        gameState.lastRewardTier = .low
        gameState.lastRewardMultiplier = 1.0
        gameState.missionTypeBonusMultiplier = 0.0
        // Seed the debrief's Base/Risk/Total payout preview with the REAL
        // contract value. baseMissionPayout was never assigned before, so the
        // reward summary showed a meaningless "Base 100 / Total 125"
        // placeholder next to a wallet that moved by thousands.
        gameState.baseMissionPayout = MissionStatsStore.basePayout(
            missionId: gameState.currentMissionDisplayId ?? "Mission001")
        gameState.missionHeat = 0
        gameState.missionHeatTier = .low
        gameState.currentTurnCount = 0
        gameState.missionEnemiesDefeated = 0
        gameState.firstKillProcessedInRoom = false
        // Refresh per-mission charges (Blitz, etc.) on each new run.
        for char in gameState.playerTeam { char.blitzChargesUsed = 0 }
        gameState.combatLog = ["Mission started: \(mission.title)", "Entering: \(firstRoom.title)"]
        applyCorpAttentionEnemyInfluence(
            gameState: gameState,
            spawnTemplates: firstRoom.enemies.map { ($0.type, $0.x, $0.y) },
            map: gameState.currentMissionTiles
        )
        applyGangAmbushBias(gameState: gameState, map: gameState.currentMissionTiles)
        gameState.addLog(gameState.generateCombinedPressurePreview())
        gameState.addLog(gameState.generateMissionBriefing())

        // A room can declare extraction EITHER as an explicit extractionPoint
        // OR as an extraction tile painted into its map — `roomHasExtraction`
        // accepts both, so this must too. Honouring only extractionPoint left
        // tile-based rooms (the procedural contract/arena rooms) rendering a
        // labelled extraction pad whose coords were the off-map sentinel:
        // isExtractionActive() passed, the player stood on the pad, and
        // nothing ever fired because (-1,-1) matched no one.
        if let _ = firstRoom.extractionPoint {
            gameState.extractionX = firstRoomExtraction.x
            gameState.extractionY = firstRoomExtraction.y
            gameState.addLog("🚁 Extraction marker active — reach it when all rooms are clear!")
        // Uses the SAME lookup the room-entry path uses. A private copy lived
        // here briefly; two implementations of "where is the extraction tile"
        // is exactly how the backtrack-spawn bug happened (RoomManager and
        // BattleScene each had their own answer and disagreed).
        } else if let pad = GameState.firstExtractionTile(in: firstRoom.map) {
            gameState.extractionX = pad.x
            gameState.extractionY = pad.y
            gameState.addLog("🚁 Extraction marker active — reach it when all rooms are clear!")
        } else {
            // CRITICAL: reset extraction coords to a SAFE OFF-MAP sentinel
            // when the first room has no extraction point. Without this,
            // stale extractionX/Y from a previous mission (e.g. M6's (3,10))
            // can match a player spawn slot here and instantly fire the
            // "extracted" outcome → "RUN COMPLETE" after 2 moves.
            gameState.extractionX = -1
            gameState.extractionY = -1
        }

        processDelayedSpawns(gameState: gameState, enemyPhaseIndex: 0)
        gameState.activeCharacterId = gameState.playerTeam.first?.id
        gameState.selectedCharacterId = gameState.playerTeam.first?.id
        gameState.beginRound()
        gameState.isEnemyPhaseRunning = false
        gameState.addLog("『 BATTLE START — SELECT A RUNNER 』")
    }

    static func updateTilesForCurrentRoom(gameState: GameState, tiles: [[Int]]) {
        // ── ENDLESS GAUNTLET ── room-transition enemies are built directly
        // in BattleScene's transition handler (which bypasses makeEnemy and
        // applies only NG+ scaling), and this method runs right after that
        // handler installs them into gameState.enemies / pendingSpawns — so
        // it's the editable choke point for scaling later-room spawns.
        // scaleForFloor is idempotent per enemy (and a no-op outside an
        // armed gauntlet run), so re-sweeping already-scaled enemies here is
        // safe.
        for enemy in gameState.enemies where enemy.isAlive {
            GauntletStore.shared.scaleForFloor(enemy)
        }
        for pending in gameState.pendingSpawns {
            GauntletStore.shared.scaleForFloor(pending.enemy)
        }
        var adjusted = gameState.dataAcquired ? tilesWithoutDataTerminals(tiles) : tiles
        // Re-apply barriers already dropped in this room (callers run after
        // completeTransition, so currentRoom is the room these tiles are from).
        if let room = RoomManager.shared.currentRoom {
            RoomManager.shared.applyDroppedBarriers(to: &adjusted, room: room)
        }
        gameState.currentMissionTiles = adjusted
    }

    private static func tilesWithoutDataTerminals(_ tiles: [[Int]]) -> [[Int]] {
        tiles.map { row in
            row.map { tile in
                tile == TileType.dataTerminal.rawValue ? TileType.floor.rawValue : tile
            }
        }
    }

    static func assignMissionTypeForCurrentLoad(gameState: GameState) {
        let assignedType: MissionType
        switch gameState.missionLoadIndex % 3 {
        case 1:
            assignedType = .assault
        case 2:
            assignedType = .extraction
        default:
            assignedType = .stealth
        }
        gameState.currentMissionType = assignedType
        switch gameState.currentMissionType {
        case .stealth:
            gameState.currentMapSituation = .corridor
        case .assault:
            gameState.currentMapSituation = .openZone
        case .extraction:
            gameState.currentMapSituation = .chokepoint
        }
        gameState.missionLoadIndex += 1
        gameState.addLog("MISSION TYPE — \(gameState.missionTypeLabel)")
        gameState.addLog("MISSION TYPE HINT — \(gameState.missionTypeHint)")
        gameState.addLog("Map situation: \(gameState.mapSituationLabel)")
    }

    static func applyMapSituation(
        gameState: GameState,
        to originalMap: [[Int]],
        extractionPoint: (x: Int, y: Int),
        protectedTiles: Set<String>
    ) -> ([[Int]], (x: Int, y: Int)) {
        guard !originalMap.isEmpty else { return (originalMap, extractionPoint) }

        var map = originalMap
        let height = map.count
        let width = map.first?.count ?? TileMap.mapWidth
        let laneX = width / 2
        var updatedExtraction = extractionPoint

        func isProtected(_ x: Int, _ y: Int) -> Bool {
            protectedTiles.contains(tileKey(gameState: gameState, x: x, y: y))
        }

        func canRewrite(_ x: Int, _ y: Int) -> Bool {
            guard y >= 0, y < height, x >= 0, x < map[y].count else { return false }
            if isProtected(x, y) { return false }
            let tile = map[y][x]
            return tile != TileType.door.rawValue && tile != TileType.extraction.rawValue && tile != TileType.dataTerminal.rawValue
        }

        switch gameState.currentMapSituation {
        case .corridor:
            for y in 0..<height {
                if canRewrite(laneX, y) { map[y][laneX] = TileType.floor.rawValue }
                if laneX - 1 >= 0, canRewrite(laneX - 1, y), y % 2 == 0 {
                    map[y][laneX - 1] = TileType.cover.rawValue
                }
                if laneX + 1 < width, canRewrite(laneX + 1, y), y % 2 == 1 {
                    map[y][laneX + 1] = TileType.cover.rawValue
                }
            }
        case .openZone:
            let xStart = max(1, width / 2 - 2)
            let xEnd = min(width - 2, width / 2 + 2)
            let yStart = max(1, height / 2 - 2)
            let yEnd = min(height - 2, height / 2 + 2)
            if xStart <= xEnd && yStart <= yEnd {
                for y in yStart...yEnd {
                    for x in xStart...xEnd where canRewrite(x, y) {
                        map[y][x] = TileType.floor.rawValue
                    }
                }
            }
            if height > 2 && width > 2 {
                for y in 1..<(height - 1) {
                    for x in 1..<(width - 1) where canRewrite(x, y) {
                        if map[y][x] == TileType.wall.rawValue && (x + y) % 2 == 0 {
                            map[y][x] = TileType.floor.rawValue
                        }
                    }
                }
            }
        case .chokepoint:
            let targetY = extractionPoint.y < height / 2 ? 1 : max(1, height - 2)
            let targetX = max(0, width - 1)
            if extractionPoint.y >= 0, extractionPoint.y < height, extractionPoint.x >= 0, extractionPoint.x < map[extractionPoint.y].count,
               map[extractionPoint.y][extractionPoint.x] == TileType.extraction.rawValue {
                map[extractionPoint.y][extractionPoint.x] = TileType.floor.rawValue
            }
            if targetY >= 0, targetY < height, targetX >= 0, targetX < map[targetY].count {
                map[targetY][targetX] = TileType.extraction.rawValue
                updatedExtraction = (targetX, targetY)
            }

            let laneY = targetY
            for x in min(laneX, targetX)...max(laneX, targetX) where canRewrite(x, laneY) {
                map[laneY][x] = TileType.floor.rawValue
            }
            for y in min(height / 2, laneY)...max(height / 2, laneY) where canRewrite(laneX, y) {
                map[y][laneX] = TileType.floor.rawValue
            }

            for y in 0..<height {
                for x in 0..<min(width, map[y].count) where canRewrite(x, y) {
                    let isLane = (x == laneX) || (y == laneY && x >= min(laneX, targetX) && x <= max(laneX, targetX))
                    if !isLane && (x <= 1 || x >= width - 2 || abs(x - laneX) >= 3) {
                        map[y][x] = TileType.wall.rawValue
                    }
                }
            }
        }

        return (map, updatedExtraction)
    }

    static func tileKey(gameState: GameState, x: Int, y: Int) -> String {
        "\(x),\(y)"
    }

    /// Find N walkable tiles for the runner team, anchored on `anchor`.
    /// Walks outward from the anchor in BFS order picking only walkable tiles
    /// (not walls), so all 4 runners land on floor / cover / door / extraction
    /// regardless of where the anchor sits relative to the room edges.
    /// Used to be the naive `(spawn.x + i, spawn.y)` which dumped char 4 on
    /// the right wall whenever the anchor sat in the middle of the room.
    /// `occupied` = tiles the party must NOT spawn on (e.g. enemy positions).
    /// Kept out of both the horizontal row-walk and the BFS fallback so a
    /// runner never lands on an enemy's hex.
    static func findGroupSpawnSlots(map: [[Int]], anchor: SpawnPoint, count: Int,
                                    occupied: Set<String> = []) -> [SpawnPoint] {
        // Spawn-placeable tile types: floor(0), cover(2), dataTerminal(5).
        // Doors(3) are deliberately EXCLUDED — a runner standing on a door
        // reads wrong and sits on a transition trigger; the party straddles
        // the door instead. Extraction(4) excluded so entry never lands a
        // runner on the exit pad.
        let walkable: Set<Int> = [0, 2, 5]
        func tile(_ x: Int, _ y: Int) -> Int? {
            guard y >= 0, y < map.count, x >= 0, x < map[y].count else { return nil }
            return map[y][x]
        }
        func isWalkable(_ x: Int, _ y: Int) -> Bool {
            guard let t = tile(x, y) else { return false }
            return walkable.contains(t) && !occupied.contains("\(x),\(y)")
        }
        // Hex distance — same odd-q axial conversion used in PathingAndAIHelpers.
        func hexDist(_ ax: Int, _ ay: Int, _ bx: Int, _ by: Int) -> Int {
            let aq = ax
            let ar = ay - (ax - (ax & 1)) / 2
            let bq = bx
            let br = by - (bx - (bx & 1)) / 2
            return (abs(aq - bq) + abs(ar - br) + abs(-aq - ar + bq + br)) / 2
        }

        // HORIZONTAL ROW LAYOUT — lay the team out left-to-right along the
        // anchor's Y row, starting at anchor.x and walking right. If a tile
        // is blocked, skip it and try the next one. Falls back to BFS only
        // if the row can't fit the team (small rooms).
        var candidates: [SpawnPoint] = []
        var seen: Set<String> = []
        let mapW = map.first?.count ?? 0
        // Walk RIGHT along the row starting at anchor.x
        for dx in 0..<mapW {
            let x = anchor.x + dx
            guard x < mapW else { break }
            if isWalkable(x, anchor.y) && !seen.contains("\(x),\(anchor.y)") {
                candidates.append(SpawnPoint(x: x, y: anchor.y))
                seen.insert("\(x),\(anchor.y)")
                if candidates.count >= count { break }
            }
        }
        // If the row didn't have enough room (small map), also walk LEFT.
        if candidates.count < count {
            for dx in 1..<mapW {
                let x = anchor.x - dx
                guard x >= 0 else { break }
                if isWalkable(x, anchor.y) && !seen.contains("\(x),\(anchor.y)") {
                    candidates.append(SpawnPoint(x: x, y: anchor.y))
                    seen.insert("\(x),\(anchor.y)")
                    if candidates.count >= count { break }
                }
            }
        }
        // Final fallback: BFS within radius 2 if even both directions
        // couldn't fit the team (extreme edge case).
        if candidates.count < count {
            let maxRadius = 2
            var queue: [(Int, Int)] = [(anchor.x, anchor.y)]
            seen.insert("\(anchor.x),\(anchor.y)")
            while !queue.isEmpty && candidates.count < count {
                let (cx, cy) = queue.removeFirst()
                if isWalkable(cx, cy)
                    && hexDist(cx, cy, anchor.x, anchor.y) <= maxRadius
                    && !candidates.contains(where: { $0.x == cx && $0.y == cy }) {
                    candidates.append(SpawnPoint(x: cx, y: cy))
                }
                let neighbors: [(Int, Int)] = (cx % 2 == 0)
                    ? [(cx, cy-1),(cx, cy+1),(cx-1, cy-1),(cx-1, cy),(cx+1, cy-1),(cx+1, cy)]
                    : [(cx, cy-1),(cx, cy+1),(cx-1, cy),(cx-1, cy+1),(cx+1, cy),(cx+1, cy+1)]
                for (nx, ny) in neighbors {
                    let key = "\(nx),\(ny)"
                    if seen.contains(key) { continue }
                    if hexDist(nx, ny, anchor.x, anchor.y) > maxRadius { continue }
                    seen.insert(key)
                    queue.append((nx, ny))
                }
            }
        }

        // Pick the first `count` candidates in order (row order from the
        // horizontal-row pass, otherwise BFS-distance order).
        var picked: [SpawnPoint] = []
        for cand in candidates {
            if picked.count >= count { break }
            if picked.contains(where: { $0.x == cand.x && $0.y == cand.y }) { continue }
            picked.append(cand)
        }
        // Fallback: the entry row + BFS ring couldn't seat the team. Spread
        // the remainder across the room's walkable tiles, sweeping from the
        // row band nearest the ENTRY point — entering high fills from the top
        // row down, entering low fills from the bottom row up — so runners
        // fan out along the entry edge instead of stacking on the anchor.
        if picked.count < count {
            let entersFromTop = anchor.y <= (map.count - 1) / 2
            let rowOrder = entersFromTop ? Array(map.indices) : Array(map.indices.reversed())
            for y in rowOrder {
                guard picked.count < count else { break }
                for x in map[y].indices where picked.count < count {
                    if isWalkable(x, y) && !picked.contains(where: { $0.x == x && $0.y == y }) {
                        picked.append(SpawnPoint(x: x, y: y))
                    }
                }
            }
        }
        // Absolute last resort: the room has fewer walkable tiles than
        // runners — repeat the anchor (caller can still play, characters
        // stack visually). Unreachable in authored rooms.
        while picked.count < count {
            picked.append(SpawnPoint(x: anchor.x, y: anchor.y))
        }
        return picked
    }

    /// True if the tile grid contains at least one data terminal (TileType 5).
    static func mapContainsDataTerminal(_ tiles: [[Int]]) -> Bool {
        for row in tiles {
            if row.contains(TileType.dataTerminal.rawValue) { return true }
        }
        return false
    }

    /// True if any room in a multi-room mission contains a data terminal.
    static func anyRoomHasDataTerminal(rooms: [Room]) -> Bool {
        for room in rooms {
            if mapContainsDataTerminal(room.map) { return true }
        }
        return false
    }

    static func archetypeForSpawnIndex(gameState: GameState, spawnIndex: Int) -> EnemyArchetype {
        switch gameState.currentMissionType {
        case .stealth:
            let pattern: [EnemyArchetype] = [.watcher, .watcher, .interceptor, .watcher, .enforcer]
            return pattern[spawnIndex % pattern.count]
        case .assault:
            let pattern: [EnemyArchetype] = [.enforcer, .enforcer, .interceptor, .enforcer, .watcher]
            return pattern[spawnIndex % pattern.count]
        case .extraction:
            let pattern: [EnemyArchetype] = [.interceptor, .watcher, .interceptor, .enforcer, .interceptor]
            return pattern[spawnIndex % pattern.count]
        }
    }

    static func applyEnemyArchetype(gameState: GameState, archetype: EnemyArchetype, to enemy: Enemy) {
        enemy.name = "\(enemy.name) (\(archetypeLabel(archetype)))"
        switch archetype {
        case .watcher:
            enemy.currentHP = max(1, enemy.currentHP - 2)
        case .enforcer:
            if var weapon = enemy.equippedWeapon {
                weapon.damage += 1
                enemy.equippedWeapon = weapon
            }
        case .interceptor:
            enemy.attributes.rea += 1
            enemy.attributes.agi += 1
        }
    }

    static func makeEnemy(gameState: GameState, for type: String, archetype: EnemyArchetype) -> Enemy {
        let enemy: Enemy
        switch type {
        case "guard":   enemy = Enemy.corpGuard()
        case "drone":   enemy = Enemy.securityDrone()
        case "elite":   enemy = Enemy.eliteGuard()
        case "mage":    enemy = Enemy.corpMage()
        case "bossmage": enemy = Enemy.bossMage()
        case "healer":  enemy = Enemy.medic()
        case "mech":    enemy = Enemy.combatMech()
        case "sniper":  enemy = Enemy.sniper()
        case "bruiser": enemy = Enemy.bruiser()
        case "spider":  enemy = Enemy.spiderDrone()
        case "riot":    enemy = Enemy.riotTrooper()
        case "turret":  enemy = Enemy.turret()
        case "rigger":  enemy = Enemy.rigger()
        case "netrunner": enemy = Enemy.combatDecker()
        case "grenadier": enemy = Enemy.grenadier()
        case "juggernaut": enemy = Enemy.juggernaut()
        case "infiltrator": enemy = Enemy.infiltrator()
        case "repairdrone": enemy = Enemy.repairDrone()
        case "sprayer": enemy = Enemy.sprayer()
        default:        enemy = Enemy.corpGuard()
        }
        applyEnemyArchetype(gameState: gameState, archetype: archetype, to: enemy)
        NGPlusStore.shared.scaleForTier(enemy)   // New Game+ durability scaling
        // Endless Gauntlet floor scaling — stacks ON TOP of NG+ (order
        // matters: the +15%/floor HP multiplier compounds the NG+-scaled
        // base). No-op outside an armed gauntlet run and on floor 1.
        GauntletStore.shared.scaleForFloor(enemy)
        return enemy
    }

    /// Build the mission's starting consumable loadout from the roster's
    /// purchased stims (Character.inventory → the combat `loot` pool the ITM
    /// button actually reads). Maps the persisted Entities.Item types onto the
    /// runtime GameState.Item the combat UI uses, so shop stims are usable.
    // MARK: - Replay squad reroll ("spawn budget")

    /// Threat cost (squad points) per regular spawn `type`. Roughly
    /// HP-and-lethality tiered: 3 = fodder, 4 = utility, 5 = specialist,
    /// 6 = heavy, 8 = juggernaut. Boss types (mech/corp/agi/bossmage) are
    /// deliberately ABSENT — a reroll must never conjure or replace a boss.
    static let spawnCost: [String: Int] = [
        "guard": 3, "drone": 3, "repairdrone": 3,
        "healer": 4, "turret": 4, "netrunner": 4, "spider": 4,
        "sniper": 5, "bruiser": 5, "riot": 5, "grenadier": 5,
        "sprayer": 5, "infiltrator": 5,
        "elite": 6, "mage": 6, "rigger": 6,
        "juggernaut": 8,
    ]

    /// Seeded RNG for squad rerolls (SplitMix64 — same rationale as
    /// ReinforcementService's: deterministic within an attempt, different
    /// across attempts). Fileprivate duplicate of that service's generator;
    /// both are 10 lines and neither wants a cross-file dependency for it.
    private struct SquadRNG: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// "Spawn budget" reroll: on a REPLAY (mission already beaten once) or a
    /// gauntlet floor, each authored enemy slot swaps to a random type of
    /// comparable cost (±1 point) drawn from the pool of types this mission
    /// actually ships — so difficulty stays inside the authored envelope,
    /// theming holds (M1 never rolls a juggernaut it never shipped), and the
    /// squad composition differs run to run. Positions and spawn delays are
    /// authored SPATIAL design and are kept verbatim; only WHO stands there
    /// changes. First clears (and failed first attempts) always get the
    /// hand-authored squad — the story balance is the tuned experience.
    ///
    /// Seeded by (missionAttemptId, room id): re-entering an uncleared room
    /// in the same attempt rebuilds the SAME squad (no reroll-scumming by
    /// door-flapping), while every new attempt rolls fresh.
    /// Odds that re-entering an already-cleared room turns up a patrol.
    private static let backtrackPatrolChance = 0.35

    /// A small patrol that has wandered into a room the player already cleared.
    /// Empty most of the time — backtracking is usually meant to be a quick
    /// errand, and a guaranteed fight would make returning for a missed
    /// objective a chore rather than a risk.
    ///
    /// Seeded on (attempt, room, visit index) so the roll is fixed for a given
    /// visit: stepping out and back in cannot re-roll it. Capped at one patrol
    /// per room per attempt by `patrolRespawnedRoomIds`, so a corridor between
    /// two objectives can't be farmed.
    ///
    /// Squad is 1–2 of the CHEAPEST types authored in this mission, placed on
    /// the room's own authored spawn tiles (known-good hexes) farthest from
    /// where the player walked in — never on top of the party.
    static func backtrackPatrol(for room: Room,
                                gameState: GameState,
                                entryX: Int,
                                entryY: Int) -> [EnemySpawn] {
        guard !RoomManager.shared.patrolRespawnedRoomIds.contains(room.id) else { return [] }
        guard !room.enemies.isEmpty else { return [] }          // nothing authored to draw from
        guard room.bossSpawn == nil else { return [] }          // never re-populate a boss arena

        var roomHash: UInt64 = 5381
        for b in room.id.utf8 { roomHash = (roomHash << 5) &+ roomHash &+ UInt64(b) }
        let visit = UInt64(RoomManager.shared.reentryCount(room.id))
        var rng = SquadRNG(seed: UInt64(bitPattern: Int64(gameState.missionAttemptId))
                                &* 0x9E37_79B9_7F4A_7C15
                                &+ roomHash
                                &+ visit &* 0x1000_0000_0000_0193)

        guard Double(rng.next() % 1000) / 1000.0 < backtrackPatrolChance else { return [] }

        // Cheapest authored types keep a wandering patrol from out-punching the
        // squad that originally held the room.
        let pool = room.enemies
            .map(\.type)
            .filter { spawnCost[$0] != nil }
            .sorted { (spawnCost[$0] ?? 0, $0) < (spawnCost[$1] ?? 0, $1) }
        guard let cheapest = pool.first else { return [] }
        let count = (rng.next() % 2 == 0) ? 1 : 2

        // Farthest authored tiles from the door the player just came through.
        let tiles = room.enemies
            .map { (x: $0.x, y: $0.y) }
            .sorted {
                let a = CombatMechanics.hexDistance(x1: entryX, y1: entryY, x2: $0.x, y2: $0.y)
                let b = CombatMechanics.hexDistance(x1: entryX, y1: entryY, x2: $1.x, y2: $1.y)
                return a == b ? ($0.x, $0.y) < ($1.x, $1.y) : a > b
            }
            .prefix(count)

        return tiles.map { EnemySpawn(type: cheapest, x: $0.x, y: $0.y, delay: 0) }
    }

    static func replaySquad(for room: Room, gameState: GameState) -> [EnemySpawn] {
        let missionId = gameState.currentMissionDisplayId ?? ""
        let isReplay = MissionStatsStore.shared.record(for: missionId).attempts > 0
        guard isReplay || GauntletStore.shared.isActive || ContractStore.shared.isActive
        else { return room.enemies }
        guard let mission = RoomManager.shared.currentMission else { return room.enemies }

        // Pool = union of costed types authored anywhere in this mission.
        var pool = Set<String>()
        for r in mission.rooms {
            for s in r.enemies where spawnCost[s.type] != nil { pool.insert(s.type) }
        }
        guard pool.count > 1 else { return room.enemies }

        // Launch-stable room hash (String.hashValue is salted per process).
        var roomHash: UInt64 = 5381
        for b in room.id.utf8 { roomHash = (roomHash << 5) &+ roomHash &+ UInt64(b) }
        // Contracts use the OFFER's seed (not the attempt counter) so an
        // offer has one signature squad: retries face the same opposition,
        // fresh offers roll fresh squads.
        let attemptSeed = ContractStore.shared.isActive
            ? (ContractStore.shared.activeOffer?.seed ?? gameState.missionAttemptId)
            : gameState.missionAttemptId
        var rng = SquadRNG(seed: UInt64(bitPattern: Int64(attemptSeed))
                                &* 0x9E37_79B9_7F4A_7C15 &+ roomHash)

        var rerolled = 0
        let squad = room.enemies.map { s -> EnemySpawn in
            guard let cost = spawnCost[s.type] else { return s }   // boss/unknown: keep
            let candidates = pool.filter { abs(spawnCost[$0, default: 0] - cost) <= 1 }
            guard let pick = candidates.sorted().randomElement(using: &rng), pick != s.type else { return s }
            rerolled += 1
            return EnemySpawn(type: pick, x: s.x, y: s.y, delay: s.delay)
        }
        if rerolled > 0 {
            gameState.addLog("📡 SQUAD INTEL — opposition roster differs from the last run (\(rerolled) change\(rerolled == 1 ? "" : "s")).")
        }
        return squad
    }

    static func seedLootFromRoster(_ team: [Character]) -> [GameState.Item] {
        var result: [GameState.Item] = []
        for member in team {
            for item in member.inventory {
                // One combat-loot entry per remaining USE — `Item.uses` was
                // persisted but never read, so a 2-use medkit was silently a
                // 1-use medkit. consumeRosterItem decrements uses to match.
                for _ in 0..<max(1, item.uses) {
                    switch item.type {
                    case .medkit:  result.append(GameState.Item(name: item.name, type: .consumable, bonus: 10, fromInventory: true))
                    case .stim:    result.append(GameState.Item(name: item.name, type: .consumable, bonus: 5, fromInventory: true))
                    case .grenade: result.append(GameState.Item(name: item.name, type: .grenade,    bonus: 7, fromInventory: true))
                    case .other:   break
                    }
                }
            }
        }
        return result
    }

    /// New Game+ adds `extraEnemiesPerRoom` extra (already-scaled) elite guards
    /// per room, placed on free floor tiles of `map`, avoiding `occupied`.
    /// Iterates bottom-up so extras tend to land away from the usual top spawn.
    /// Returns [] on the first playthrough (tier 0).
    static func ngPlusExtraEnemies(gameState: GameState, map: [[Int]], occupied: Set<String>) -> [Enemy] {
        let count = NGPlusStore.shared.extraEnemiesPerRoom
        guard count > 0, !map.isEmpty else { return [] }
        var taken = occupied
        var result: [Enemy] = []
        for y in stride(from: map.count - 1, through: 0, by: -1) {
            for x in map[y].indices where map[y][x] == TileType.floor.rawValue {
                if result.count >= count { return result }
                let key = "\(x),\(y)"
                if taken.contains(key) { continue }
                taken.insert(key)
                let e = makeEnemy(gameState: gameState, for: "elite", archetype: .enforcer)
                e.positionX = x; e.positionY = y
                result.append(e)
            }
        }
        return result
    }

    static func logEnemyComposition(gameState: GameState, totalSpawnCount: Int) {
        guard totalSpawnCount > 0 else { return }
        var watcherCount = 0
        var enforcerCount = 0
        var interceptorCount = 0

        for index in 0..<totalSpawnCount {
            switch archetypeForSpawnIndex(gameState: gameState, spawnIndex: index) {
            case .watcher: watcherCount += 1
            case .enforcer: enforcerCount += 1
            case .interceptor: interceptorCount += 1
            }
        }

        let dominant: String
        if watcherCount >= enforcerCount && watcherCount >= interceptorCount {
            dominant = "WATCHERS"
        } else if enforcerCount >= watcherCount && enforcerCount >= interceptorCount {
            dominant = "ENFORCERS"
        } else {
            dominant = "INTERCEPTORS"
        }

        gameState.addLog("Enemy composition: \(dominant)")
        gameState.addLog("Archetypes — Watcher: \(watcherCount), Enforcer: \(enforcerCount), Interceptor: \(interceptorCount)")
    }

    static func applyCorpAttentionEnemyInfluence(
        gameState: GameState,
        spawnTemplates: [(type: String, x: Int, y: Int)],
        map: [[Int]]
    ) {
        let modifier = gameState.corpAttentionEnemyModifier()
        gameState.lastAppliedCorpEnemyModifier = 0

        guard modifier > 0 else {
            gameState.addLog("No enemy presence increase from corp attention.")
            return
        }
        guard !spawnTemplates.isEmpty else {
            gameState.addLog("Corp attention modifier available (+\(modifier)), but no spawn templates found.")
            return
        }

        let width = map.first?.count ?? TileMap.mapWidth
        let height = map.count
        let offsets: [(Int, Int)] = [(0, 0), (1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, 1)]

        var occupied = Set(gameState.playerTeam.filter(\.isAlive).map { "\($0.positionX),\($0.positionY)" })
        for enemy in gameState.enemies where enemy.isAlive {
            occupied.insert("\(enemy.positionX),\(enemy.positionY)")
        }
        for pending in gameState.pendingSpawns where pending.enemy.isAlive {
            occupied.insert("\(pending.enemy.positionX),\(pending.enemy.positionY)")
        }

        var applied = 0
        for i in 0..<modifier {
            let template = spawnTemplates[i % spawnTemplates.count]
            let archetype = archetypeForSpawnIndex(gameState: gameState, spawnIndex: gameState.enemies.count + gameState.pendingSpawns.count + applied)
            let enemy = makeEnemy(gameState: gameState, for: template.type, archetype: archetype)

            var placed = false
            for probe in 0..<offsets.count {
                let offset = offsets[(probe + i) % offsets.count]
                let x = max(0, min(width - 1, template.x + offset.0))
                let y = max(0, min(height - 1, template.y + offset.1))
                guard y >= 0, y < map.count, x >= 0, x < map[y].count else { continue }
                guard map[y][x] != 1 else { continue }
                let key = "\(x),\(y)"
                guard !occupied.contains(key) else { continue }
                enemy.positionX = x
                enemy.positionY = y
                gameState.enemies.append(enemy)
                occupied.insert(key)
                applied += 1
                gameState.addLog("\(archetypeLabel(archetype)) deployed")
                placed = true
                break
            }

            if !placed {
                gameState.addLog("Corp attention spawn skipped: no safe tile for extra enemy \(i + 1)/\(modifier).")
            }
        }

        gameState.lastAppliedCorpEnemyModifier = applied
        if applied == 0 {
            gameState.addLog("Corp attention increased threat profile, but no extra enemies could be placed.")
        } else if applied < modifier {
            gameState.addLog("Corp attention increased enemy presence by +\(applied) (requested +\(modifier)).")
        } else {
            gameState.addLog("Corp attention increased enemy presence by +\(applied).")
        }
    }

    static func applyGangAmbushBias(gameState: GameState, map: [[Int]]) {
        let gangAttention = gameState.factionAttention[.gang, default: 0]
        let baseRadius = ConsequenceEngine.gangAmbushRadius(gangAttention: gangAttention)
        gameState.lastAppliedGangAmbushRadius = baseRadius

        guard baseRadius < 999 else {
            gameState.addLog("No ambush bias applied.")
            return
        }

        gameState.addLog("Gang ambush bias applied: radius \(baseRadius)")

        let width = map.first?.count ?? TileMap.mapWidth
        let height = map.count
        let maxRadius = max(width, height) * 2

        var occupied = Set(gameState.playerTeam.filter(\.isAlive).map { "\($0.positionX),\($0.positionY)" })
        var didLogRelaxation = false

        let allSpawnedEnemies = gameState.enemies + gameState.pendingSpawns.map(\.enemy)
        for enemy in allSpawnedEnemies where enemy.isAlive {
            var effectiveRadius = baseRadius
            var placed = false

            while effectiveRadius <= maxRadius && !placed {
                for y in 0..<height {
                    for x in 0..<width {
                        guard y < map.count, x < map[y].count else { continue }
                        guard map[y][x] != 1 else { continue }
                        let key = "\(x),\(y)"
                        if occupied.contains(key) { continue }

                        let distance = gameState.distanceToNearestPlayer(x: x, y: y)
                        if distance <= effectiveRadius { continue }

                        enemy.positionX = x
                        enemy.positionY = y
                        occupied.insert(key)
                        placed = true
                        break
                    }
                    if placed { break }
                }

                if !placed {
                    effectiveRadius += 1
                    if !didLogRelaxation && effectiveRadius > baseRadius {
                        didLogRelaxation = true
                        gameState.addLog("Ambush radius relaxed due to constrained map.")
                    }
                }
            }

            if !placed {
                let key = "\(enemy.positionX),\(enemy.positionY)"
                occupied.insert(key)
            }
        }
    }

    static func processDelayedSpawns(gameState: GameState, enemyPhaseIndex: Int) {
        // ── ENDLESS GAUNTLET ── this runs every enemy phase, making it the
        // catch-all sweep for spawn paths that bypass makeEnemy AND the
        // room-transition sweep: ReinforcementService waves (queued straight
        // into pendingSpawns with only NG+ scaling) and bosses (deployBoss /
        // the mage phase-2 path append directly to gameState.enemies — they
        // get swept on the next enemy-phase tick, before their first act).
        // Idempotent per enemy; no-op outside an armed gauntlet run. Runs
        // BEFORE the boss-active early return below so a live boss is swept.
        for enemy in gameState.enemies where enemy.isAlive {
            GauntletStore.shared.scaleForFloor(enemy)
        }
        for pending in gameState.pendingSpawns {
            GauntletStore.shared.scaleForFloor(pending.enemy)
        }
        // Boss-active gate. If a boss (M3 Sato, M5 MEKTON-7, M6 AGI-PRIME) is
        // on the field, suppress all timed/queued reinforcement spawns so the
        // boss is the focal threat and the room can't get re-cluttered mid-
        // fight. Mirrors the deployBoss `pendingSpawns.removeAll()` pattern
        // but acts as a per-tick gate rather than a one-shot purge.
        let bossActive = gameState.enemies.contains { e in
            let arch = e.archetype.lowercased()
            return e.isAlive && (arch == "bossmage" || arch == "bossmech"
                                 || arch == "bossagi" || arch == "bosscorp")
        }
        if bossActive {
            // Boss fight is the focal threat — DROP any queued reinforcements
            // outright so they can't all flush onto the board the instant the
            // boss dies (the gate opening would otherwise dump a stale wave on
            // a player who just won). Nothing spawns during or after the boss.
            if !gameState.pendingSpawns.isEmpty { gameState.pendingSpawns.removeAll() }
            return
        }
        let due = gameState.pendingSpawns.filter { $0.delayRounds <= enemyPhaseIndex }
        // Build the occupied-tile set BEFORE spawning so each new arrival
        // also avoids tiles claimed by earlier arrivals in this same wave.
        // Players + already-living enemies count. M5R1 repro: a drone with
        // a hand-authored spawn coord (3,5) landed on top of Raze who'd
        // moved there during the delay window — two sprites stacked.
        var occupied = Set<String>()
        for char in gameState.playerTeam where char.isAlive {
            occupied.insert("\(char.positionX),\(char.positionY)")
        }
        for e in gameState.enemies where e.isAlive {
            occupied.insert("\(e.positionX),\(e.positionY)")
        }
        for spawn in due {
            // If the spawn tile is occupied (or off-map / non-walkable),
            // search outward through hex neighbours for the nearest free
            // walkable tile and shift the spawn there.
            let key = "\(spawn.enemy.positionX),\(spawn.enemy.positionY)"
            if occupied.contains(key) || !isSpawnableTile(gameState: gameState,
                                                          x: spawn.enemy.positionX,
                                                          y: spawn.enemy.positionY) {
                if let (nx, ny) = findFreeAdjacentTile(gameState: gameState,
                                                       fromX: spawn.enemy.positionX,
                                                       fromY: spawn.enemy.positionY,
                                                       occupied: occupied) {
                    dlog("[ProcessDelayedSpawns] tile (\(spawn.enemy.positionX),\(spawn.enemy.positionY)) occupied — relocating \(spawn.enemy.name) to (\(nx),\(ny))")
                    spawn.enemy.positionX = nx
                    spawn.enemy.positionY = ny
                }
            }
            occupied.insert("\(spawn.enemy.positionX),\(spawn.enemy.positionY)")
            gameState.enemies.append(spawn.enemy)
            gameState.addLog("⚠️ \(spawn.enemy.name) reinforcements arrive!")
            NotificationCenter.default.post(
                name: .enemySpawned,
                object: nil,
                userInfo: ["enemyId": spawn.enemy.id.uuidString]
            )
        }
        gameState.pendingSpawns.removeAll { $0.delayRounds <= enemyPhaseIndex }
        // If reinforcements actually spawned and the room was previously
        // marked cleared, re-lock the door — players have to defeat the
        // new wave before they can leave.
        if !due.isEmpty {
            if RoomManager.shared.unmarkCurrentRoomCleared() {
                gameState.addLog("🔒 Door re-locked — defeat reinforcements first.")
                // Force the BattleScene to refresh door visuals.
                NotificationCenter.default.post(name: .roomNavigationRequested, object: nil)
            }
        }
    }

    /// True if the tile is a walkable, in-bounds floor (or floor-equivalent)
    /// suitable for spawning an enemy onto. Walls, off-map, and non-floor
    /// tile types return false. Doors / data terminals / extraction are
    /// considered NON-spawnable since something else lives on them.
    private static func isSpawnableTile(gameState: GameState, x: Int, y: Int) -> Bool {
        let map = gameState.currentMissionTiles
        guard y >= 0, y < map.count, x >= 0, x < map[y].count else { return false }
        return map[y][x] == TileType.floor.rawValue
    }

    /// BFS outward from (fromX, fromY) for the nearest walkable, unoccupied
    /// tile. Used by processDelayedSpawns to relocate a spawn when its
    /// authored tile got claimed by a player who moved into it during the
    /// delay window. Returns nil only if no free tile exists within ~8 rings
    /// (effectively never, on the current map sizes).
    private static func findFreeAdjacentTile(
        gameState: GameState,
        fromX: Int,
        fromY: Int,
        occupied: Set<String>
    ) -> (Int, Int)? {
        var visited: Set<String> = ["\(fromX),\(fromY)"]
        var frontier: [(Int, Int)] = [(fromX, fromY)]
        let maxRings = 8
        for _ in 0..<maxRings {
            var next: [(Int, Int)] = []
            for (cx, cy) in frontier {
                for (nx, ny) in gameState.hexNeighbors(x: cx, y: cy) {
                    let key = "\(nx),\(ny)"
                    if visited.contains(key) { continue }
                    visited.insert(key)
                    if isSpawnableTile(gameState: gameState, x: nx, y: ny)
                        && !occupied.contains(key) {
                        return (nx, ny)
                    }
                    if isSpawnableTile(gameState: gameState, x: nx, y: ny) {
                        // Walkable but occupied — keep expanding through it.
                        next.append((nx, ny))
                    }
                }
            }
            if next.isEmpty { break }
            frontier = next
        }
        return nil
    }
}

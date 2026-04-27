import Foundation

@MainActor
struct MissionSetupService {
    @discardableResult
    static func prepareMissionForCombat(gameState: GameState, missionId: String?) -> String {
        let resolvedMissionId = missionId ?? "Mission001"

        if let multiMission = MissionLoader.shared.loadMultiRoomMission(named: resolvedMissionId) {
            RoomManager.shared.loadMission(named: resolvedMissionId)
            setupMultiRoomMission(gameState: gameState, mission: multiMission)
            return resolvedMissionId
        }

        if let mission = MissionLoader.shared.loadMission(named: resolvedMissionId) {
            setupMission(gameState: gameState, mission: mission)
            return resolvedMissionId
        }

        guard let fallbackMission = MissionLoader.shared.loadMission(named: "Mission001") else {
            return resolvedMissionId
        }

        setupMission(gameState: gameState, mission: fallbackMission)
        return "Mission001"
    }

    private static func archetypeLabel(_ archetype: EnemyArchetype) -> String {
        switch archetype {
        case .watcher: return "Watcher"
        case .enforcer: return "Enforcer"
        case .interceptor: return "Interceptor"
        }
    }

    static func setupMission(gameState: GameState, mission: Mission) {
        print("[GameState] setupMission: \(mission.title)")
        gameState.playerTeam = Character.allRunners
        if let spawn = Optional(mission.playerSpawn) {
            for (i, char) in gameState.playerTeam.enumerated() {
                char.positionX = spawn.x + i
                char.positionY = spawn.y
            }
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

        gameState.currentTurnIndex = 0
        gameState.roundNumber = 1
        gameState.enemyPhaseCount = 0
        gameState.traceLevel = 0
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
        gameState.missionHeat = 0
        gameState.missionHeatTier = .low
        gameState.currentTurnCount = 0
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
        print("[GameState] setupMultiRoomMission: \(mission.title)")
        gameState.playerTeam = Character.allRunners

        let firstRoom = mission.rooms.first!
        RoomManager.shared.markRoomEntered(firstRoom.id)
        let spawn = firstRoom.playerSpawn
        for (i, char) in gameState.playerTeam.enumerated() {
            char.positionX = spawn.x + i
            char.positionY = spawn.y
        }

        gameState.enemies = []
        gameState.pendingSpawns = []
        assignMissionTypeForCurrentLoad(gameState: gameState)

        for (spawnIndex, spawn) in firstRoom.enemies.enumerated() {
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

        let firstRoomExtraction = firstRoom.extractionPoint ?? SpawnPoint(x: firstRoom.playerSpawn.x, y: firstRoom.playerSpawn.y)
        let protectedTiles = Set(
            firstRoom.enemies.map { tileKey(gameState: gameState, x: $0.x, y: $0.y) } +
            [tileKey(gameState: gameState, x: firstRoom.playerSpawn.x, y: firstRoom.playerSpawn.y)]
        )
        let adjustedFirstRoomMap = applyMapSituation(
            gameState: gameState,
            to: firstRoom.map,
            extractionPoint: (firstRoomExtraction.x, firstRoomExtraction.y),
            protectedTiles: protectedTiles
        )
        gameState.currentMissionTiles = adjustedFirstRoomMap.0

        gameState.currentRoomId = firstRoom.id

        gameState.currentTurnIndex = 0
        gameState.roundNumber = 1
        gameState.enemyPhaseCount = 0
        gameState.traceLevel = 0
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
        gameState.missionHeat = 0
        gameState.missionHeatTier = .low
        gameState.currentTurnCount = 0
        gameState.combatLog = ["Mission started: \(mission.title)", "Entering: \(firstRoom.title)"]
        applyCorpAttentionEnemyInfluence(
            gameState: gameState,
            spawnTemplates: firstRoom.enemies.map { ($0.type, $0.x, $0.y) },
            map: gameState.currentMissionTiles
        )
        applyGangAmbushBias(gameState: gameState, map: gameState.currentMissionTiles)
        gameState.addLog(gameState.generateCombinedPressurePreview())
        gameState.addLog(gameState.generateMissionBriefing())

        if let _ = firstRoom.extractionPoint {
            gameState.extractionX = adjustedFirstRoomMap.1.x
            gameState.extractionY = adjustedFirstRoomMap.1.y
            gameState.addLog("Reach extraction at (\(gameState.extractionX), \(gameState.extractionY))")
        } else if let firstConn = firstRoom.connections.first {
            gameState.extractionX = firstConn.triggerTileX
            gameState.extractionY = firstConn.triggerTileY
            gameState.addLog("Find a way through to: \(firstConn.targetRoomId)")
        }

        processDelayedSpawns(gameState: gameState, enemyPhaseIndex: 0)
        gameState.activeCharacterId = gameState.playerTeam.first?.id
        gameState.selectedCharacterId = gameState.playerTeam.first?.id
        gameState.beginRound()
        gameState.isEnemyPhaseRunning = false
        gameState.addLog("『 BATTLE START — SELECT A RUNNER 』")
    }

    static func updateTilesForCurrentRoom(gameState: GameState, tiles: [[Int]]) {
        gameState.currentMissionTiles = tiles
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
            return tile != TileType.door.rawValue && tile != TileType.extraction.rawValue
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
        case "guard": enemy = Enemy.corpGuard()
        case "drone": enemy = Enemy.securityDrone()
        case "elite": enemy = Enemy.eliteGuard()
        case "mage": enemy = Enemy.corpMage()
        case "healer": enemy = Enemy.medic()
        default: enemy = Enemy.corpGuard()
        }
        applyEnemyArchetype(gameState: gameState, archetype: archetype, to: enemy)
        return enemy
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
        let due = gameState.pendingSpawns.filter { $0.delayRounds <= enemyPhaseIndex }
        for spawn in due {
            gameState.enemies.append(spawn.enemy)
            gameState.addLog("⚠️ \(spawn.enemy.name) reinforcements arrive!")
            NotificationCenter.default.post(
                name: .enemySpawned,
                object: nil,
                userInfo: ["enemyId": spawn.enemy.id.uuidString]
            )
        }
        gameState.pendingSpawns.removeAll { $0.delayRounds <= enemyPhaseIndex }
    }
}

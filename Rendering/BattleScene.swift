import SpriteKit

/// Main SpriteKit scene for battle rendering and interaction.
final class BattleScene: SKScene {

    // MARK: - Properties

    private var tileMap: TileMap?
    /// Bottom padding added to scene height so the bottom row sits above the CombatUI bar.
    private let mapBottomPadding: CGFloat = 30
    /// Cached map dimensions for coordinate conversion — derived from the TileMap instance.
    /// Pointy-top odd-r bounding box:
    ///   width  = cols · hexColSpacing + R/2       (right-side pointy vertex extends 0.5R)
    ///   height = (rows + 0.5) · hexRowSpacing     (odd-col shift adds half a row down)
    private var mapPixelWidth: CGFloat { CGFloat(TileMap.mapWidth) * TileMap.hexColSpacing + TileMap.hexRadius * 0.5 }
    private var mapPixelHeight: CGFloat { (CGFloat(tileMap?.mapHeight ?? 9) + 0.5) * TileMap.hexRowSpacing }
    /// Scene-space offset of the tile map's bottom-left corner.
    /// With scene.size = map pixel dims and .aspectFit, this is (.zero) — map fills scene exactly.
    private let firstTurnCameraYOffset: CGFloat = 0
    private var mapOrigin: CGPoint {
        CGPoint(
            x: max(0, (self.size.width  - mapPixelWidth)  / 2),
            y: max(0, (self.size.height - mapPixelHeight) / 2)
        )
    }
    private var characterNodes: [UUID: SKNode] = [:]
    private var selectedCharacterNode: SKNode?
    private var currentTurnIndex: Int = 0
    private var lastRenderedTraceTier: Int = -1

    /// Movement range for BFS pathfinding — 2 hexes per turn (SR5 standard walk range)
    private var movementRange: Int { return 2 }

    /// Current room ID — synced with RoomManager.currentRoomId during transitions.
    var currentRoomId: String = "room_0"

    /// Turn order list — set externally from TurnManager
    var turnOrder: [Character] = []

    /// Fade overlay for room transitions — stored so fadeOutFromTransition
    /// can use a direct reference instead of a name-based child lookup.
    private var fadeNode: SKNode?

    /// Track which door tiles have been auto-opened so we don't re-trigger.
    private var openedDoorKeys: Set<String> = []

    /// Blocks player input during enemy phase — set to true when player takes an action
    /// that ends their turn, and false when runEnemyPhase() completes.
    private var playerInputLocked: Bool = false

    /// Tracks whether an enemy phase is currently running.
    private var isEnemyPhaseRunning: Bool = false

    /// Timestamp (from update's currentTime) when isPlayerInputBlocked was last set to true.
    /// Used by the safety timeout to force-unblock if the enemy phase notification never fires.
    private var inputBlockedSince: TimeInterval?

    /// Tracks which character triggered the most recent door transition.
    /// Only this character gets moved to the connection target spawn — others keep their positions.
    private var doorTransitionCharacterId: UUID?

    // MARK: - Pending Initial Load
    // BattleSceneView stashes these BEFORE presentScene; didMove processes them AFTER
    // the view is attached. This eliminates timing issues around scene.size / mapOrigin
    // that caused characters to be invisible on first render.
    private var pendingInitialTileMap: TileMap?
    private var pendingInitialRoomId: String?
    private var pendingInitialCharacters: [Character] = []
    private var pendingInitialEnemies: [Enemy] = []

    #if DEBUG
    private let debugOverlayName = "cameraDebugOverlay"
    #endif

    /// Called by BattleSceneView BEFORE presentScene. Stashes the initial tilemap and
    /// roster so didMove can perform the actual loadMap/placeCharacter/placeEnemy with
    /// the view attached and scene.size final.
    func scheduleInitialLoad(tileMap: TileMap, roomId: String, characters: [Character], enemies: [Enemy]) {
        self.pendingInitialTileMap = tileMap
        self.pendingInitialRoomId = roomId
        self.pendingInitialCharacters = characters
        self.pendingInitialEnemies = enemies
    }

    // MARK: - Scene Setup

    override func didMove(to view: SKView) {
        backgroundColor = UIColor(hex: "#05060A")  // near-black, makes hex gaps look good
        // Now that the view is attached, make scene.size match the view bounds so
        // mapOrigin centers the map correctly in the viewport.
        fitSceneToView()
        setupCamera()
        positionCameraOnMap()
        setupEnemyNotifications()
        setupRoomNotifications()
        EffectsManager.shared.addRainEffect(to: self)

        // Process pending initial load NOW, with the view attached and scene sized.
        // This is the single-source-of-truth path for first-frame characters/enemies.
        if let tmap = pendingInitialTileMap {
            if childNode(withName: "TileMap") == nil {
                loadMap(tmap)
            }
            if let rid = pendingInitialRoomId { currentRoomId = rid }
            for character in pendingInitialCharacters { placeCharacter(character) }
            for enemy in pendingInitialEnemies { placeEnemy(enemy) }
            let initialFocusId =
                GameState.shared.activeCharacterId
                ?? GameState.shared.selectedCharacterId
                ?? pendingInitialCharacters.first(where: { $0.isAlive })?.id
            pendingInitialTileMap = nil
            pendingInitialRoomId = nil
            pendingInitialCharacters = []
            pendingInitialEnemies = []
            if let initialFocusId {
                focusCamera(on: initialFocusId)
                showSelectionRing(for: initialFocusId)
                updatePlayerIdleAnimations(activeId: initialFocusId)
            } else {
                positionCameraOnMap()
            }
            print("[BattleScene] didMove: initial load complete, characterNodes=\(characterNodes.count)")
        }

        // Safety net: if the first-frame handoff raced and the pending arrays were empty,
        // reconcile directly from GameState once the scene is live. This makes the scene
        // robust against SwiftUI / SpriteKit timing weirdness during the title → briefing → combat hop.
        syncCombatantsFromGameState(reason: "didMove")
        DispatchQueue.main.async { [weak self] in
            self?.syncCombatantsFromGameState(reason: "didMove-async")
        }

        // Camera-attached overlays: vignette + scanlines. Adding to the camera
        // ensures they stay fixed on screen regardless of camera position.
        if let cam = camera {
            // Vignette — dark border around the viewport edge
            let vignette = SKShapeNode(rectOf: CGSize(width: self.size.width * 1.6, height: self.size.height * 1.6))
            vignette.fillColor = .clear
            vignette.strokeColor = UIColor.black.withAlphaComponent(0.35)
            vignette.lineWidth = self.size.width * 0.28
            vignette.position = .zero   // camera center
            vignette.zPosition = 90
            vignette.name = "vignette"
            cam.addChild(vignette)

            // Subtle CRT scanlines — fixed overlay on viewport
            addSubtleScanlines(to: cam)
        }
        refreshTraceVisuals(force: true)
    }

    private func addSubtleScanlines(to parent: SKNode) {
        let scanlineNode = SKNode()
        scanlineNode.zPosition = 85
        scanlineNode.name = "subtleScanlines"

        // Camera space: (0,0) = center. Scanlines cover full viewport.
        let scanlineSpacing: CGFloat = 3
        let startY = -size.height / 2
        let endY = size.height / 2
        var y: CGFloat = startY

        while y < endY {
            let scanline = SKShapeNode(rectOf: CGSize(width: size.width, height: 0.5))
            scanline.fillColor = UIColor.black.withAlphaComponent(0.05)
            scanline.strokeColor = .clear
            scanline.position = CGPoint(x: 0, y: y)
            scanlineNode.addChild(scanline)
            y += scanlineSpacing
        }

        parent.addChild(scanlineNode)
    }

    private func setupRoomNotifications() {
        NotificationCenter.default.addObserver(forName: .roomTransitionStarted, object: nil, queue: .main) { [weak self] _ in
            self?.performRoomTransitionFade()
        }
        NotificationCenter.default.addObserver(forName: .roomTransitionCompleted, object: nil, queue: .main) { [weak self] _ in
            self?.handleRoomTransitionCompleted()
        }
        // Room navigation arrows in CombatUI
        NotificationCenter.default.addObserver(forName: .roomNavigationRequested, object: nil, queue: .main) { [weak self] notification in
            guard let dir = notification.userInfo?["direction"] as? String else { return }
            self?.handleRoomNavigationArrow(direction: dir)
        }
    }

    /// Handle LEFT/RIGHT arrow tap from CombatUI — navigate to adjacent room without a door.
    private func handleRoomNavigationArrow(direction: String) {
        guard let currentIdx = RoomManager.shared.currentMission?.rooms.firstIndex(where: { $0.id == currentRoomId }) else { return }
        let targetIdx: Int
        if direction == "left" {
            targetIdx = currentIdx - 1
        } else {
            targetIdx = currentIdx + 1
        }
        guard targetIdx >= 0, targetIdx < (RoomManager.shared.currentMission?.rooms.count ?? 0) else {
            GameState.shared.addLog("No room in that direction.")
            return
        }
        let targetRoom = RoomManager.shared.currentMission!.rooms[targetIdx]
        GameState.shared.addLog("Entering: \(targetRoom.title)...")

        // Do NOT pre-mark room as entered here — handleRoomTransitionCompleted checks
        // isRoomEntered to decide whether to reset spawn positions. Marking early would
        // cause first-entry rooms to skip spawn reset, leaving characters at their
        // previous-room positions (which are off-map in the new room → disappear bug).

        // Begin transition (fade handled by .roomTransitionStarted notification)
        RoomManager.shared.beginTransition(to: targetRoom)
        NotificationCenter.default.post(name: .roomTransitionStarted, object: nil)
    }

    private func handleRoomTransitionCompleted() {
        guard let targetRoom = RoomManager.shared.pendingRoomTransition else { return }

        // Determine spawn position for this transition:
        // - Door transition (pendingConnectionTargetX/Y set by attemptTransition): use connection target spawn
        // - Arrow navigation: use room's playerSpawn
        // Only reset positions on FIRST entry to this room; for back-navigation, preserve
        // the player's position from their last visit (positions carry over from previous loadRoom).
        let spawnX: Int
        let spawnY: Int
        if let connX = RoomManager.shared.pendingConnectionTargetX,
           let connY = RoomManager.shared.pendingConnectionTargetY {
            spawnX = validatedSpawnX(in: targetRoom, proposedX: connX, proposedY: connY).x
            spawnY = validatedSpawnX(in: targetRoom, proposedX: connX, proposedY: connY).y
            print("[BattleScene] room transition target room=\(targetRoom.id) requestedSpawn=(\(connX),\(connY)) resolvedSpawn=(\(spawnX),\(spawnY)) tile=\(targetRoom.map[spawnY][spawnX])")
        } else {
            // No connection target (arrow navigation) — always use this room's spawn.
            // We don't store per-room character positions, so the characters' current
            // positionX/Y reflect the room they JUST LEFT, not this one. Using those
            // stale coords here causes characters to land on walls/off-map and disappear.
            spawnX = targetRoom.playerSpawn.x
            spawnY = targetRoom.playerSpawn.y
        }

        // Set character positions for this room entry.
        // Each character is placed at the base spawn offset by index, then individually
        // validated so no runner ends up inside a wall or off-map.
        if spawnX >= 0 {
            for i in GameState.shared.playerTeam.indices {
                let candidate = validatedSpawnX(in: targetRoom,
                                                proposedX: spawnX + i,
                                                proposedY: spawnY)
                GameState.shared.playerTeam[i].positionX = candidate.x
                GameState.shared.playerTeam[i].positionY = candidate.y
                print("Room transition: char=\(GameState.shared.playerTeam[i].name) x=\(candidate.x) y=\(candidate.y)")
            }
        }

        // Mark room as entered (for future back-navigation)
        RoomManager.shared.markRoomEntered(targetRoom.id)

        // Replace GameState enemies with this room's enemies only.
        // Old-room enemies are removed — each room spawns fresh on entry.
        let newEnemies = targetRoom.enemies.map { enemySpawn -> Enemy in
            let enemy: Enemy
            switch enemySpawn.type {
            case "guard":   enemy = Enemy.corpGuard()
            case "drone":   enemy = Enemy.securityDrone()
            case "elite":   enemy = Enemy.eliteGuard()
            case "mage":    enemy = Enemy.corpMage()
            case "healer":  enemy = Enemy.medic()
            default:        enemy = Enemy.corpGuard()
            }
            enemy.positionX = enemySpawn.x
            enemy.positionY = enemySpawn.y
            return enemy
        }
        GameState.shared.enemies = newEnemies

        RoomManager.shared.completeTransition(to: targetRoom)

        // Sync GameState's current room ID
        GameState.shared.currentRoomId = targetRoom.id

        // Recompute extraction objective for the room we just entered.
        // Priority:
        // 1) explicit room extractionPoint
        // 2) extraction tile embedded in map
        // 3) first room connection trigger tile (fallback objective)
        if let extraction = targetRoom.extractionPoint {
            GameState.shared.extractionX = extraction.x
            GameState.shared.extractionY = extraction.y
            GameState.shared.addLog("Reach extraction at (\(extraction.x), \(extraction.y))")
        } else if let mapExtraction = firstExtractionTile(in: targetRoom.map) {
            GameState.shared.extractionX = mapExtraction.x
            GameState.shared.extractionY = mapExtraction.y
            GameState.shared.addLog("Reach extraction at (\(mapExtraction.x), \(mapExtraction.y))")
        } else if let firstConn = targetRoom.connections.first {
            GameState.shared.extractionX = firstConn.triggerTileX
            GameState.shared.extractionY = firstConn.triggerTileY
            GameState.shared.addLog("Find a way through to: \(firstConn.targetRoomId)")
        }

        // Update tiles for enemy pathfinding
        GameState.shared.updateTilesForCurrentRoom(targetRoom.map)

        // Clear stale door-open state from previous room
        openedDoorKeys.removeAll()

        // Reset combat state for the new room
        CombatFlowController.restorePlayerControlAfterEnemyPhase(gameState: GameState.shared)

        // Reload the room with the new map, characters, and enemies
        loadRoom(targetRoom, characters: GameState.shared.playerTeam, enemies: newEnemies)

        // Start a fresh round in the new room
        GameState.shared.beginRound()

        // Fade back in
        fadeOutFromTransition()

        GameState.shared.addLog("Arrived at: \(targetRoom.title)")
    }

    private func firstExtractionTile(in map: [[Int]]) -> (x: Int, y: Int)? {
        for (y, row) in map.enumerated() {
            if let x = row.firstIndex(of: TileType.extraction.rawValue) {
                return (x: x, y: y)
            }
        }
        return nil
    }

    private func setupEnemyNotifications() {
        NotificationCenter.default.addObserver(forName: .characterLevelUp, object: nil, queue: .main) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let idStr = userInfo["characterId"] as? String,
                  let id = UUID(uuidString: idStr) else { return }
            self?.playLevelUpEffect(on: id)
        }

        NotificationCenter.default.addObserver(forName: .enemyHit, object: nil, queue: .main) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let idStr = userInfo["enemyId"] as? String,
                  let id = UUID(uuidString: idStr) else { return }
            let dmg = userInfo["damage"] as? Int ?? 0
            self?.playHitEffect(on: id, damage: dmg)
        }
        NotificationCenter.default.addObserver(forName: .enemyDied, object: nil, queue: .main) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let idStr = userInfo["enemyId"] as? String,
                  let id = UUID(uuidString: idStr) else { return }
            self?.playDeathEffect(on: id)
        }
        NotificationCenter.default.addObserver(forName: .enemyMoved, object: nil, queue: .main) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let idStr = userInfo["enemyId"] as? String,
                  let id = UUID(uuidString: idStr),
                  let newX = userInfo["x"] as? Int,
                  let newY = userInfo["y"] as? Int else { return }
            print("[BattleScene] .enemyMoved received — enemyId=\(idStr), to=(\(newX),\(newY))")
            self?.animateEnemyMove(id: id, toX: newX, toY: newY)
        }
        NotificationCenter.default.addObserver(forName: .enemySpawned, object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            guard let userInfo = notification.userInfo,
                  let idStr = userInfo["enemyId"] as? String,
                  let id = UUID(uuidString: idStr) else { return }
            Task { @MainActor in
                // Find the newly spawned enemy in GameState and place it on the map
                if let enemy = GameState.shared.enemies.first(where: { $0.id == id }) {
                    self.placeEnemy(enemy)
                    self.playRoundStartEffect()
                }
            }
        }
        NotificationCenter.default.addObserver(forName: .roundStarted, object: nil, queue: .main) { [weak self] _ in
            self?.playRoundStartEffect()
        }
        NotificationCenter.default.addObserver(forName: .characterDefend, object: nil, queue: .main) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let idStr = userInfo["characterId"] as? String,
                  let id = UUID(uuidString: idStr) else { return }
            self?.playDefendEffect(on: id)
            // Re-focus camera on the defending character
            self?.focusCamera(on: id)
        }
        NotificationCenter.default.addObserver(forName: .turnChanged, object: nil, queue: .main) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let idStr = userInfo["characterId"] as? String,
                  let id = UUID(uuidString: idStr) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Auto-select the new active character AND show their movement range
                self.showSelectionRing(for: id)
                CombatFlowController.requestCharacterSelectionFromScene(gameState: GameState.shared, id: id)
                self.focusCamera(on: id)
                // Selective idle animation: only the active player character animates.
                // All other player characters are frozen on their first idle frame.
                self.updatePlayerIdleAnimations(activeId: id)
            }
        }
        NotificationCenter.default.addObserver(forName: .characterSelected, object: nil, queue: .main) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let idStr = userInfo["characterId"] as? String,
                  let id = UUID(uuidString: idStr) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.showSelectionRing(for: id)
                self.focusCamera(on: id)
                self.updatePlayerIdleAnimations(activeId: id)
            }
        }
        NotificationCenter.default.addObserver(forName: .playerHit, object: nil, queue: .main) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let idStr = userInfo["playerId"] as? String,
                  let id = UUID(uuidString: idStr) else { return }
            let dmg = userInfo["damage"] as? Int ?? 0
            let enemyIdStr = userInfo["enemyId"] as? String
            print("[BattleScene] .playerHit received — playerId=\(idStr), damage=\(dmg)")
            // Trigger attack animation on the attacking enemy
            if let eIdStr = enemyIdStr, let enemyId = UUID(uuidString: eIdStr),
               let enemyNode = self?.characterNodes[enemyId] as? SpriteNode {
                SpriteManager.shared.animate(state: .attack, target: enemyNode)
            }
            // playEnemyAttackEffect draws the slash line and plays the player flash together
            if let eIdStr = enemyIdStr, let enemyId = UUID(uuidString: eIdStr) {
                self?.playEnemyAttackEffect(enemyId: enemyId, playerId: id, damage: dmg)
            } else {
                self?.playPlayerHitEffect(on: id, damage: dmg, enemyIdStr: enemyIdStr)
            }
        }
        // FIX Issue 1: Unblock player input ONLY when all enemy animations have finished.
        // The fixed 0.8s asyncAfter was too short for multiple enemies with staggered moves.
        // GameState.enemyPhase() posts .enemyPhaseCompleted when its DispatchGroup finishes.
        NotificationCenter.default.addObserver(forName: .enemyPhaseCompleted, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.playerInputLocked = false
                self.isEnemyPhaseRunning = false
                // Render layer is projection-only; combat flow owns progression state restoration.
                CombatFlowController.restorePlayerControlAfterEnemyPhase(gameState: GameState.shared)
                print("[BattleScene] .enemyPhaseCompleted received — player input unlocked")
            }
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Block input during enemy phase or when player input is locked.
        if playerInputLocked || GameState.shared.isInputBlockedByPhase {
            GameState.shared.addLog("Enemy phase — wait for your turn.")
            HapticsManager.shared.buttonTap()
            return
        }
        guard let touch = touches.first else { return }
        let sceneLocation = touch.location(in: self)

        // Reset block flag in case it got stuck (safety check)
        playerInputLocked = false

        // Flat-top odd-q touch → tile conversion using correct hex grid spacing.
        // hexColSpacing = 1.5·R, hexRowSpacing = R·√3·isoSquash — matches tileCenter exactly.
        // Odd COLUMNS shift down by hexRowSpacing/2 (column parity, not row parity).
        let rawX = Int((sceneLocation.x - mapOrigin.x) / TileMap.hexColSpacing)
        let clampedX = max(0, min(rawX, TileMap.mapWidth - 1))
        let colYOffset: CGFloat = (clampedX % 2 == 1) ? TileMap.hexRowSpacing / 2.0 : 0
        let rawY = Int((sceneLocation.y - mapOrigin.y - colYOffset) / TileMap.hexRowSpacing)
        let clampedY = max(0, min(rawY, (tileMap?.mapHeight ?? 9) - 1))

        // DEBUG: verify touch → tile conversion
        print("[BattleScene] touchesBegan scene=(\(sceneLocation.x),\(sceneLocation.y)) mapOrigin=(\(mapOrigin.x),\(mapOrigin.y)) colOffset=\(colYOffset) → clamped=(\(clampedX),\(clampedY))")

        // Visual feedback - always flash within clamped tile bounds
        flashTile(tileX: clampedX, tileY: clampedY)

        // Handle selection / movement
        handleTileTap(tileX: clampedX, tileY: clampedY)
    }

    /// Start idle animation on the active player character; freeze all other player characters.
    /// Called whenever .turnChanged fires so only the current actor is visually animated.
    private func updatePlayerIdleAnimations(activeId: UUID) {
        let playerIds = Set(GameState.shared.playerTeam.map { $0.id })
        for (charId, node) in characterNodes {
            guard playerIds.contains(charId), let spriteNode = node as? SpriteNode else { continue }
            if charId == activeId {
                SpriteManager.shared.animate(state: .idle, target: spriteNode)
            } else {
                SpriteManager.shared.stopIdle(target: spriteNode)
            }
        }
        refreshActiveUnitHighlight(activeId: activeId)
    }

    /// Keep one obvious ring on the currently active unit for turn readability.
    private func refreshActiveUnitHighlight(activeId: UUID?) {
        let playerIds = Set(GameState.shared.playerTeam.map(\.id))
        for (id, node) in characterNodes where playerIds.contains(id) {
            node.childNode(withName: "activeTurnRing")?.removeFromParent()
        }

        guard let activeId, let activeNode = characterNodes[activeId] else { return }
        let ring = SKShapeNode(circleOfRadius: TileMap.hexRadius * 0.56)
        ring.name = "activeTurnRing"
        ring.strokeColor = UIColor(hex: "#00D8FF")
        ring.lineWidth = 3
        ring.fillColor = .clear
        ring.zPosition = 12
        activeNode.addChild(ring)

        ring.run(SKAction.repeatForever(SKAction.sequence([
            SKAction.fadeAlpha(to: 0.35, duration: 0.45),
            SKAction.fadeAlpha(to: 0.95, duration: 0.45)
        ])), withKey: "activePulse")
        ring.run(SKAction.repeatForever(SKAction.rotate(byAngle: .pi * 2, duration: 2.8)), withKey: "activeSpin")
    }

    private func showSelectionRing(for characterId: UUID) {
        // Deselect previous and clear highlights
        if let prev = selectedCharacterNode {
            SpriteManager.shared.deselect(target: prev)
        }
        clearHighlights()

        // Select new
        if let node = characterNodes[characterId] {
            SpriteManager.shared.animateSelect(target: node)
            selectedCharacterNode = node
            HapticsManager.shared.selectionChanged()
            let pop = SKAction.sequence([
                SKAction.scale(to: 1.05, duration: 0.08),
                SKAction.scale(to: 1.0, duration: 0.10)
            ])
            node.run(pop, withKey: "selectionPop")
            // Highlight attackable enemy tiles and movable empty tiles
            if let sprite = node as? SpriteNode {
                highlightTiles(aroundX: sprite.tileX, y: sprite.tileY)
            }
        }

        let activeId = GameState.shared.activeCharacter?.id ?? GameState.shared.currentCharacter?.id
        refreshActiveUnitHighlight(activeId: activeId)
    }

    private var highlightNodes: [SKNode] = []

    private func clearHighlights() {
        for n in highlightNodes { n.removeFromParent() }
        highlightNodes = []
    }

    private func highlightTiles(aroundX cx: Int, y cy: Int) {
        clearHighlights()

        // Highlight all enemy-occupied tiles (attackable) — bright red with flickering effect
        for (_, node) in characterNodes {
            guard let sprite = node as? SpriteNode, sprite.team == "enemy" else { continue }
            let n = SKShapeNode(path: TileMap.hexPath(radius: TileMap.hexRadius - 2))
            n.strokeColor = UIColor(hex: "#FF3333")
            n.lineWidth = 2.5
            n.fillColor = UIColor(hex: "#FF3333").withAlphaComponent(0.25)
            n.position = CGPoint(
                x: tileCenter(sprite.tileX, sprite.tileY).x,
                y: tileCenter(sprite.tileX, sprite.tileY).y
            )
            n.zPosition = 8
            n.name = "highlight"
            addChild(n)
            highlightNodes.append(n)

            // Add flickering animation for attack range tiles
            let enemyFlicker = SKAction.sequence([
                SKAction.fadeAlpha(to: 0.35, duration: 0.15),
                SKAction.fadeAlpha(to: 0.7, duration: 0.15),
                SKAction.fadeAlpha(to: 0.25, duration: 0.1),
                SKAction.fadeAlpha(to: 0.6, duration: 0.2)
            ])
            n.run(SKAction.repeatForever(enemyFlicker))

            // Add a crosshair marker on attackable enemies for clarity
            let crossH = SKShapeNode(rectOf: CGSize(width: 14, height: 2))
            crossH.fillColor = UIColor(hex: "#FF3333").withAlphaComponent(0.9)
            crossH.strokeColor = .clear
            crossH.position = n.position
            crossH.zPosition = 9
            crossH.name = "highlight"
            addChild(crossH)
            highlightNodes.append(crossH)

            let crossV = SKShapeNode(rectOf: CGSize(width: 2, height: 14))
            crossV.fillColor = UIColor(hex: "#FF3333").withAlphaComponent(0.9)
            crossV.strokeColor = .clear
            crossV.position = n.position
            crossV.zPosition = 9
            crossV.name = "highlight"
            addChild(crossV)
            highlightNodes.append(crossV)
        }

        // Use BFS to find all reachable tiles within movement range
        let reachableTiles = bfsReachable(fromX: cx, fromY: cy, maxSteps: movementRange)
        for tile in reachableTiles {
            let tx = tile.x, ty = tile.y
            let occupied = characterNodes.values.contains { node in
                guard let sprite = node as? SpriteNode else { return false }
                return sprite.tileX == tx && sprite.tileY == ty
            }
            if !occupied {
                let n = SKShapeNode(path: TileMap.hexPath(radius: TileMap.hexRadius - 4))
                n.strokeColor = UIColor(hex: "#00D8FF").withAlphaComponent(0.95)
                n.lineWidth = 2.5
                n.fillColor = UIColor(hex: "#00D8FF").withAlphaComponent(0.20)
                n.position = CGPoint(
                    x: tileCenter(tx, ty).x,
                    y: tileCenter(tx, ty).y
                )
                n.zPosition = 6
                n.name = "highlight"
                addChild(n)
                highlightNodes.append(n)

                // Add pulsing opacity animation for move tiles (0.4→0.8→0.4)
                let movePulse = SKAction.sequence([
                    SKAction.fadeAlpha(to: 0.8, duration: 0.5),
                    SKAction.fadeAlpha(to: 0.4, duration: 0.5)
                ])
                n.run(SKAction.repeatForever(movePulse))

            }
        }
    }

    private func animateCharacterMove(characterId: UUID, toTileX: Int, toTileY: Int) {
        guard let node = characterNodes[characterId] else { return }
        SpriteManager.shared.animateMove(target: node, toTileX: toTileX, toTileY: toTileY, duration: 0.3, mapOrigin: mapOrigin)
    }

    /// Set up the camera node. Call after scene.size is set (ideally after fitSceneToView).
    /// Safe to call multiple times; only creates camera once.
    func setupCamera() {
        guard self.camera == nil else { return }
        let cameraNode = SKCameraNode()
        cameraNode.name = "MainCamera"
        cameraNode.xScale = 1.0
        cameraNode.yScale = 1.0
        addChild(cameraNode)
        self.camera = cameraNode
        // Position after map is loaded so mapOrigin is valid — call positionCameraOnMap() after loadMap().
    }

    // SwiftUI overlays cover the top objective banner and the bottom combat panel.
    // These are updated from CombatView after layout so first-turn framing matches
    // the real HUD footprint on the current device instead of a hardcoded guess.
    private var topHUDInset: CGFloat = 96
    private var bottomHUDInset: CGFloat = 280

    func updateViewportInsets(top: CGFloat, bottom: CGFloat) {
        let resolvedTop = max(0, top)
        let resolvedBottom = max(0, bottom)
        let changed = abs(resolvedTop - topHUDInset) > 0.5 || abs(resolvedBottom - bottomHUDInset) > 0.5

        topHUDInset = resolvedTop
        bottomHUDInset = resolvedBottom

        guard changed, camera != nil else { return }

        positionCameraOnMap()
    }

    private func applyCameraScale(_ cam: SKCameraNode) -> CGFloat {
        // Scale to fit the UNOBSCURED play corridor (between top objective banner and
        // bottom combat panel). Using full scene.height here makes the map scale so
        // small that the HUD overlays eat the bottom half of the board.
        let visibleWidth = max(1, size.width)
        let visibleHeight = unobscuredViewportHeight
        let targetMapScreenWidth = visibleWidth * 1.14
        let targetMapScreenHeight = visibleHeight * 0.88
        let requiredScaleX = mapPixelWidth / targetMapScreenWidth
        let requiredScaleY = mapPixelHeight / targetMapScreenHeight
        let scale = max(0.86, max(requiredScaleX, requiredScaleY))
        cam.setScale(scale)
        return scale
    }

    /// Reposition camera to map center within the actually visible play corridor.
    func positionCameraOnMap() {
        guard let cam = camera else { return }
        let scale = applyCameraScale(cam)
        let visibleSize = cameraVisibleSize(scale: scale)
        // Bottom HUD is taller than the top banner, so shift the camera DOWN
        // in scene space (lower Y) by half the delta. That puts the map's visual
        // center in the middle of the unobscured strip, not the full view.
        let verticalBias = ((bottomHUDInset - topHUDInset) / 2.0) * scale
        let nextPosition = CGPoint(
            x: clampedCameraCoordinate(
                desired: mapOrigin.x + mapPixelWidth / 2,
                mapStart: mapOrigin.x,
                mapLength: mapPixelWidth,
                visibleLength: visibleSize.width
            ),
            y: clampedCameraCoordinate(
                desired: mapOrigin.y + mapPixelHeight / 2 - verticalBias - firstTurnCameraYOffset,
                mapStart: mapOrigin.y,
                mapLength: mapPixelHeight,
                visibleLength: visibleSize.height
            )
        )
        cam.position = nextPosition
        refreshCameraDebugOverlay(reason: "positionCameraOnMap")
        print("[BattleScene] positionCameraOnMap camera=\(nextPosition) topInset=\(topHUDInset) bottomInset=\(bottomHUDInset) bias=\(verticalBias)")
    }

    /// Focus camera on a specific tile, clamped so map edges stay within the unobscured viewport.
    func focusCamera(on tileX: Int, y tileY: Int) {
        positionCameraOnMap()
        print("[BattleScene] focusCamera locked to board center; requested tile=(\(tileX),\(tileY))")
    }

    private var unobscuredViewportHeight: CGFloat {
        max(1, size.height - topHUDInset - bottomHUDInset)
    }

    private func cameraVisibleSize(scale: CGFloat) -> CGSize {
        CGSize(width: size.width * scale, height: unobscuredViewportHeight * scale)
    }

    private func clampedCameraCoordinate(
        desired: CGFloat,
        mapStart: CGFloat,
        mapLength: CGFloat,
        visibleLength: CGFloat
    ) -> CGFloat {
        guard mapLength > visibleLength else { return desired }

        let halfVisible = visibleLength / 2.0
        let minValue = mapStart + halfVisible
        let maxValue = mapStart + mapLength - halfVisible
        return minValue <= maxValue ? max(minValue, min(maxValue, desired)) : desired
    }

    // MARK: - Scene Size / Map Fit

    /// Adjust scene size to match the SKView's bounds.
    /// IMPORTANT: Call BEFORE loadMap() so mapOrigin is computed from the correct scene.size.
    /// Adjust scene size to match the SKView's available bounds, then compute mapOrigin.
    /// IMPORTANT: Call BEFORE loadMap() so mapOrigin is computed from the correct scene.size.
    /// With scene.size = SKView bounds, the map is centered and mapOrigin ≠ zero.
    func fitSceneToView() {
        guard let view = self.view else { return }
        self.size = view.bounds.size
    }

    #if DEBUG
    private func refreshCameraDebugOverlay(reason: String) {
        guard let cam = camera else { return }

        let overlay: SKNode
        if let existing = childNode(withName: debugOverlayName) {
            overlay = existing
            overlay.removeAllChildren()
        } else {
            overlay = SKNode()
            overlay.name = debugOverlayName
            overlay.zPosition = 300
            addChild(overlay)
        }

        let scale = max(cam.xScale, 1.0)
        overlay.setScale(scale)
        overlay.position = CGPoint(
            x: cam.position.x - (size.width * scale / 2.0) + 10 * scale,
            y: cam.position.y + (size.height * scale / 2.0) - 18 * scale
        )

        let firstCharacter = GameState.shared.playerTeam.first.flatMap { character -> (Character, SpriteNode)? in
            guard let node = characterNodes[character.id] as? SpriteNode else { return nil }
            return (character, node)
        }
        let firstText: String
        if let (character, node) = firstCharacter {
            firstText = "first \(character.name.prefix(8)) tile(\(node.tileX),\(node.tileY)) pos \(fmt(node.position))"
        } else {
            firstText = "first n/a"
        }

        let lines = [
            "scene \(fmt(size)) origin \(fmt(mapOrigin)) cam \(fmt(cam.position)) s \(fmt(cam.xScale))",
            "insets t \(fmt(topHUDInset)) b \(fmt(bottomHUDInset)) visibleH \(fmt(unobscuredViewportHeight))",
            "map \(fmt(mapPixelWidth))x\(fmt(mapPixelHeight)) \(firstText)",
            "debug \(reason)"
        ]

        let bg = SKShapeNode(rectOf: CGSize(width: 340, height: 58), cornerRadius: 4)
        bg.fillColor = UIColor.black.withAlphaComponent(0.68)
        bg.strokeColor = UIColor(hex: "#00FF88").withAlphaComponent(0.45)
        bg.lineWidth = 1
        bg.position = CGPoint(x: 170, y: -22)
        bg.zPosition = -1
        overlay.addChild(bg)

        for (index, text) in lines.enumerated() {
            let label = SKLabelNode(text: text)
            label.fontName = "Menlo-Bold"
            label.fontSize = 8
            label.fontColor = UIColor(hex: "#00FF88")
            label.horizontalAlignmentMode = .left
            label.verticalAlignmentMode = .top
            label.position = CGPoint(x: 6, y: -CGFloat(index) * 13)
            overlay.addChild(label)
        }

        print("[BattleScene][CameraDebug] \(lines.joined(separator: " | "))")
    }

    private func fmt(_ value: CGFloat) -> String {
        String(format: "%.1f", value)
    }

    private func fmt(_ point: CGPoint) -> String {
        "(\(fmt(point.x)),\(fmt(point.y)))"
    }

    private func fmt(_ size: CGSize) -> String {
        "\(fmt(size.width))x\(fmt(size.height))"
    }
    #endif

    #if !DEBUG
    private func refreshCameraDebugOverlay(reason: String) {}
    #endif

    // MARK: - Load Map

    /// Load a mission's tile map.
    func loadMap(_ tileMap: TileMap) {
        self.tileMap = tileMap
        addBoardBackplate(for: tileMap)
        let mapNode = tileMap.buildNode()
        // Center the map node in the scene so all tiles are within the camera's view.
        mapNode.position = mapOrigin
        addChild(mapNode)

        // Add ambient effects
        tileMap.addAmbientEffects(to: mapNode, mapSize: tileMap.size)

        // Add coordinate labels at map edges for tactical clarity
        addMapCoordinateLabels(tileMap: tileMap)

        // Re-center camera on the now-centered map.
        positionCameraOnMap()
        refreshTraceVisuals(force: true)

        print("[BattleScene] loadMap: mapNode at \(mapNode.position), mapSize=\(tileMap.size), scene.size=\(self.size), mapOrigin=\(mapOrigin)")
    }

    /// Adds a deterministic backplate under the map to improve board readability and depth.
    private func addBoardBackplate(for tileMap: TileMap) {
        childNode(withName: "boardBackplate")?.removeFromParent()

        let backplate = SKShapeNode(
            rectOf: CGSize(width: tileMap.size.width + 44, height: tileMap.size.height + 36),
            cornerRadius: 16
        )
        backplate.name = "boardBackplate"
        backplate.fillColor = UIColor(hex: "#050A11").withAlphaComponent(0.88)
        backplate.strokeColor = UIColor(hex: "#1B2E43").withAlphaComponent(0.9)
        backplate.lineWidth = 1.6
        backplate.zPosition = -40
        backplate.position = CGPoint(
            x: mapOrigin.x + tileMap.size.width / 2,
            y: mapOrigin.y + tileMap.size.height / 2
        )
        addChild(backplate)

        // Subtle deterministic scan-lines clipped to the backplate footprint.
        let scanlineLayer = SKNode()
        scanlineLayer.zPosition = -39
        let lineSpacing: CGFloat = 9
        var y = -tileMap.size.height / 2
        while y <= tileMap.size.height / 2 {
            let line = SKShapeNode(rectOf: CGSize(width: tileMap.size.width + 32, height: 0.6))
            line.fillColor = UIColor(hex: "#00B8FF").withAlphaComponent(0.06)
            line.strokeColor = .clear
            line.position = CGPoint(x: 0, y: y)
            scanlineLayer.addChild(line)
            y += lineSpacing
        }
        scanlineLayer.position = backplate.position
        addChild(scanlineLayer)
    }

    private func refreshTraceVisuals(force: Bool = false) {
        let tier = GameState.shared.traceTier
        guard force || tier != lastRenderedTraceTier else { return }
        lastRenderedTraceTier = tier

        guard let backplate = childNode(withName: "boardBackplate") as? SKShapeNode else { return }
        let scanlineNodes = children
            .filter { $0.zPosition == -39 }
            .flatMap(\.children)
            .compactMap { $0 as? SKShapeNode }

        switch tier {
        case 2:
            backplate.fillColor = UIColor(hex: "#22060A").withAlphaComponent(0.9)
            backplate.strokeColor = UIColor(hex: "#FF5566").withAlphaComponent(0.9)
            for node in scanlineNodes {
                node.fillColor = UIColor(hex: "#FF5544").withAlphaComponent(0.08)
            }
        case 1:
            backplate.fillColor = UIColor(hex: "#1E1408").withAlphaComponent(0.9)
            backplate.strokeColor = UIColor(hex: "#FFAA44").withAlphaComponent(0.9)
            for node in scanlineNodes {
                node.fillColor = UIColor(hex: "#FFAA44").withAlphaComponent(0.07)
            }
        default:
            backplate.fillColor = UIColor(hex: "#050A11").withAlphaComponent(0.88)
            backplate.strokeColor = UIColor(hex: "#1B2E43").withAlphaComponent(0.9)
            for node in scanlineNodes {
                node.fillColor = UIColor(hex: "#00B8FF").withAlphaComponent(0.06)
            }
        }
    }

    private func addMapCoordinateLabels(tileMap: TileMap) {
        let labelNode = SKNode()
        labelNode.zPosition = 80
        labelNode.name = "coordinateLabels"

        // X-axis labels (column numbers) at top — use tileCenter for hex-stagger-aware x positions.
        // Use the last row to get the most accurate label positions (row 0 = bottom, mapHeight-1 = top).
        let topRowY = tileMap.mapHeight - 1
        for x in 0..<TileMap.mapWidth {
            let label = SKLabelNode(text: "\(x)")
            label.fontName = "Courier"
            label.fontSize = 8
            label.fontColor = UIColor(hex: "#00D4FF").withAlphaComponent(0.5)
            label.position = CGPoint(
                x: tileCenter(x, topRowY).x,
                y: mapOrigin.y + CGFloat(tileMap.mapHeight) * TileMap.hexRowSpacing + 12
            )
            label.zPosition = 80
            labelNode.addChild(label)
        }

        // Y-axis labels (row numbers) at left — delegate vertical position to tileCenter
        // so labels line up exactly with each row's hex center, regardless of hex orientation.
        for y in 0..<tileMap.mapHeight {
            let label = SKLabelNode(text: "\(y)")
            label.fontName = "Courier"
            label.fontSize = 8
            label.fontColor = UIColor(hex: "#00D4FF").withAlphaComponent(0.5)
            label.position = CGPoint(
                x: mapOrigin.x - 12,
                y: tileCenter(0, y).y
            )
            label.zPosition = 80
            labelNode.addChild(label)
        }

        addChild(labelNode)
    }

    /// Reconcile the visible roster directly from GameState.
    /// Used as a safety net when the initial scheduled load loses the first-frame team/enemy arrays.
    private func syncCombatantsFromGameState(reason: String) {
        guard tileMap != nil else { return }

        let desiredPlayers = GameState.shared.playerTeam.filter { $0.isAlive }
        let desiredEnemies = GameState.shared.enemies.filter { $0.isAlive }
        let desiredIds = Set(desiredPlayers.map(\.id)).union(desiredEnemies.map(\.id))

        for (id, node) in characterNodes where !desiredIds.contains(id) {
            node.removeFromParent()
            characterNodes.removeValue(forKey: id)
        }

        for character in desiredPlayers {
            if let node = characterNodes[character.id] as? SpriteNode {
                node.tileX = character.positionX
                node.tileY = character.positionY
                node.position = tileCenter(character.positionX, character.positionY)
                node.isHidden = false
                node.alpha = 1.0
            } else {
                placeCharacter(character)
            }
        }

        for enemy in desiredEnemies {
            if let node = characterNodes[enemy.id] as? SpriteNode {
                node.tileX = enemy.positionX
                node.tileY = enemy.positionY
                node.position = tileCenter(enemy.positionX, enemy.positionY)
                node.isHidden = false
                node.alpha = 1.0
            } else {
                placeEnemy(enemy)
            }
        }

        if let activeId = GameState.shared.activeCharacterId ?? GameState.shared.selectedCharacterId {
            focusCamera(on: activeId)
        } else if let first = desiredPlayers.first {
            focusCamera(on: first.positionX, y: first.positionY)
        }

        let activeId = GameState.shared.activeCharacter?.id ?? GameState.shared.currentCharacter?.id
        refreshActiveUnitHighlight(activeId: activeId)

        print("[BattleScene] syncCombatantsFromGameState(\(reason)) players=\(desiredPlayers.count) enemies=\(desiredEnemies.count) nodes=\(characterNodes.count)")
    }

    // MARK: - Coordinate Helpers

    /// Single source of truth for converting a tile coord to scene position.
    /// Delegates to TileMap.tileCenter(x:y:) so hex row stagger is applied consistently
    /// for both tile rendering and character/highlight placement.
    func tileCenter(_ tileX: Int, _ tileY: Int) -> CGPoint {
        let local = TileMap.tileCenter(x: tileX, y: tileY)
        print("[BattleScene] tileCenter(\(tileX),\(tileY)) → local=\(local) mapOrigin=\(mapOrigin)")
        return CGPoint(x: mapOrigin.x + local.x, y: mapOrigin.y + local.y)
    }

    /// 6 hex neighbours for a flat-top odd-q offset grid (column stagger).
    /// Even columns: upper-left/right neighbours use y-1.
    /// Odd columns:  upper-left/right neighbours use y (same row).
    func hexNeighbors(x: Int, y: Int) -> [(Int, Int)] {
        if x % 2 == 0 {
            return [(x,y-1),(x,y+1),(x-1,y-1),(x-1,y),(x+1,y-1),(x+1,y)]
        } else {
            return [(x,y-1),(x,y+1),(x-1,y),(x-1,y+1),(x+1,y),(x+1,y+1)]
        }
    }

    // MARK: - Character Placement

    /// Place a character sprite on the map, accounting for map centering offset.
    func placeCharacter(_ character: Character) {
        let node = SpriteManager.shared.createCharacter(
            type: character.archetype.rawValue,
            team: "player",
            x: character.positionX,
            y: character.positionY,
            name: character.name,
            level: character.level
        )
        node.name = "player_\(character.id.uuidString)"
        node.characterId = character.id.uuidString
        node.tileX = character.positionX
        node.tileY = character.positionY
        node.team = "player"
        node.position = tileCenter(character.positionX, character.positionY)
        node.zPosition = 40
        node.alpha = 1.0
        node.isHidden = false
        addChild(node)
        characterNodes[character.id] = node
        SpriteManager.shared.updateHP(on: node, currentHP: character.currentHP, maxHP: character.maxHP, currentStun: character.currentStun, maxStun: character.maxStun, level: character.level, isPlayer: true)
        refreshCameraDebugOverlay(reason: "placeCharacter")
        print("[BattleScene] placeCharacter \(character.name) at tile(\(character.positionX),\(character.positionY)) → pos \(node.position) scene.size=\(self.size) mapOrigin=\(mapOrigin) parent=\(node.parent?.name ?? "nil")")
    }

    /// Place an enemy sprite on the map, accounting for map centering offset.
    func placeEnemy(_ enemy: Enemy) {
        let node = SpriteManager.shared.createCharacter(
            type: enemy.archetype,
            team: "enemy",
            x: enemy.positionX,
            y: enemy.positionY,
            name: enemy.name,
            level: 1
        )
        node.name = "enemy_\(enemy.id.uuidString)"
        node.enemyId = enemy.id.uuidString
        node.tileX = enemy.positionX
        node.tileY = enemy.positionY
        node.team = "enemy"
        node.position = tileCenter(enemy.positionX, enemy.positionY)
        node.zPosition = 41
        node.alpha = 1.0
        node.isHidden = false

        let threatRing = SKShapeNode(circleOfRadius: TileMap.hexRadius * 0.48)
        threatRing.name = "enemyThreatRing"
        threatRing.strokeColor = UIColor(hex: "#FF3344").withAlphaComponent(0.65)
        threatRing.lineWidth = 2
        threatRing.fillColor = .clear
        threatRing.position = CGPoint(x: 0, y: -8)
        threatRing.zPosition = 5
        node.addChild(threatRing)
        threatRing.run(SKAction.repeatForever(SKAction.sequence([
            SKAction.fadeAlpha(to: 0.25, duration: 0.55),
            SKAction.fadeAlpha(to: 0.75, duration: 0.55)
        ])))

        // HP bar — floats above enemy tile.
        let enemyBarWidth: CGFloat = 32.0
        let hpBarBg = SKShapeNode(rectOf: CGSize(width: enemyBarWidth, height: 4), cornerRadius: 2)
        hpBarBg.fillColor = UIColor.black.withAlphaComponent(0.7)
        hpBarBg.strokeColor = UIColor.clear
        hpBarBg.position = CGPoint(x: 0, y: 22)
        hpBarBg.zPosition = 20
        hpBarBg.name = "hpBarBg"
        hpBarBg.userData = NSMutableDictionary()
        hpBarBg.userData?["barWidth"] = enemyBarWidth
        node.addChild(hpBarBg)

        let hpBarFill = SKShapeNode()
        hpBarFill.fillColor = UIColor(red: 0.2, green: 1.0, blue: 0.3, alpha: 0.9)
        hpBarFill.strokeColor = UIColor.clear
        hpBarFill.position = CGPoint(x: 0, y: 22)
        hpBarFill.zPosition = 21
        hpBarFill.name = "hpBarFill"
        node.addChild(hpBarFill)

        let hpLabel = SKLabelNode(text: "\(enemy.currentHP)/\(enemy.maxHP)")
        hpLabel.fontSize = 7
        hpLabel.fontName = "Menlo-Bold"
        hpLabel.fontColor = UIColor(red: 0.2, green: 1.0, blue: 0.3, alpha: 1.0)
        hpLabel.position = CGPoint(x: 0, y: 28)
        hpLabel.zPosition = 21
        hpLabel.name = "hpLabel"
        node.addChild(hpLabel)

        addChild(node)
        characterNodes[enemy.id] = node
        SpriteManager.shared.updateHP(on: node, currentHP: enemy.currentHP, maxHP: enemy.maxHP, currentStun: enemy.currentStun, maxStun: enemy.maxStun)
        refreshCameraDebugOverlay(reason: "placeEnemy")
        print("[BattleScene] placeEnemy \(enemy.name) at tile(\(enemy.positionX),\(enemy.positionY)) → pos \(node.position)")
    }

    /// Update character position.
    func moveCharacter(id: UUID, toX: Int, toY: Int) {
        guard let node = characterNodes[id] else { return }
        SpriteManager.shared.animateMove(target: node, toTileX: toX, toTileY: toY, mapOrigin: mapOrigin)
    }

    /// Remove a character sprite.
    func removeCharacter(id: UUID) {
        guard let node = characterNodes[id] else { return }
        SpriteManager.shared.animateDeath(target: node)
        characterNodes.removeValue(forKey: id)
    }

    // MARK: - Selection

    /// Select a character by ID and highlight it.
    func selectCharacter(id: UUID) {
        deselectCurrent()

        guard let node = characterNodes[id] else { return }
        selectedCharacterNode = node
        SpriteManager.shared.animateSelect(target: node)

        // Update UI
        NotificationCenter.default.post(
            name: .characterSelected,
            object: nil,
            userInfo: ["characterId": id.uuidString]
        )
    }

    /// Deselect the current character.
    func deselectCurrent() {
        if let node = selectedCharacterNode {
            SpriteManager.shared.deselect(target: node)
            selectedCharacterNode = nil
        }
    }

    /// Get character at a tile position.

    // MARK: - Turn Indicator

    /// Highlight the current actor.
    func updateTurnIndicator() {
        guard !turnOrder.isEmpty, currentTurnIndex < turnOrder.count else { return }
        let current = turnOrder[currentTurnIndex]
        selectCharacter(id: current.id)

        NotificationCenter.default.post(
            name: .turnChanged,
            object: nil,
            userInfo: ["characterId": current.id.uuidString]
        )
    }

    /// Show movement range on the map.
    func showMoveRange(tiles: [(Int, Int)]) {
        tileMap?.clearHighlights()
        for (x, y) in tiles {
            tileMap?.highlightTile(at: x, y: y, color: UIColor(hex: "#00FF88"))
        }
    }

    func showAttackRange(tiles: [(Int, Int)]) {
        tileMap?.clearHighlights()
        for (x, y) in tiles {
            tileMap?.highlightTile(at: x, y: y, color: UIColor(hex: "#FF6600"))
        }
    }

    // MARK: - Room Transition

    /// Trigger a fade-to-black room transition.
    private func performRoomTransitionFade() {
        // Update currentRoomId immediately so any code checking it during transition
        // gets the NEW room's ID (prevents stale references when transition completes).
        if let targetRoom = RoomManager.shared.pendingRoomTransition {
            currentRoomId = targetRoom.id
        }

        // Create a full-screen black overlay. Attach it to the camera node so it
        // always covers the entire viewport regardless of camera position.
        // Camera-space: (0,0) = screen center, size matches the scene's viewport.
        let fade = SKSpriteNode(color: .black, size: self.size)
        fade.position = .zero   // center of camera viewport
        fade.zPosition = 500
        fade.alpha = 0
        fade.name = "fadeOverlay"

        guard let cam = camera else {
            // No camera yet — fall back to adding directly in scene space
            fade.position = CGPoint(x: self.size.width / 2, y: self.size.height / 2)
            addChild(fade)
            self.fadeNode = fade
            let fadeIn = SKAction.fadeAlpha(to: 1.0, duration: 0.4)
            fade.run(fadeIn) {
                NotificationCenter.default.post(name: .roomTransitionCompleted, object: nil)
            }
            return
        }
        cam.addChild(fade)
        self.fadeNode = fade   // store reference so fadeOutFromTransition can use it directly

        // Add room title label as child of the overlay (fades with it)
        if let targetRoom = RoomManager.shared.pendingRoomTransition {
            let roomLabel = SKLabelNode(text: targetRoom.title.uppercased())
            roomLabel.fontName = "Helvetica-Bold"
            roomLabel.fontSize = 24
            roomLabel.fontColor = UIColor(hex: "#00FF88")
            roomLabel.position = .zero   // center of overlay
            roomLabel.zPosition = 1      // relative to fade parent
            roomLabel.alpha = 0
            roomLabel.name = "roomTransitionLabel"
            fade.addChild(roomLabel)
            let labelFadeIn  = SKAction.fadeAlpha(to: 1.0, duration: 0.3)
            let labelWait    = SKAction.wait(forDuration: 0.5)
            let labelFadeOut = SKAction.fadeOut(withDuration: 0.3)
            let labelRemove  = SKAction.removeFromParent()
            roomLabel.run(SKAction.sequence([SKAction.wait(forDuration: 0.2), labelFadeIn, labelWait, labelFadeOut, labelRemove]))
        }

        // Fade in — on completion, fire the transition-completed notification
        let fadeIn = SKAction.fadeAlpha(to: 1.0, duration: 0.4)
        fade.run(fadeIn) { [weak self] in
            guard self != nil else { return }
            NotificationCenter.default.post(name: .roomTransitionCompleted, object: nil)
        }
    }

    /// Reload the scene with a new room's map after a transition fade completes.
    func loadRoom(_ room: Room, characters: [Character], enemies: [Enemy]) {
        currentRoomId = room.id
        GameState.shared.currentRoomId = room.id

        // Remove old tilemap
        childNode(withName: "TileMap")?.removeFromParent()
        childNode(withName: "coordinateLabels")?.removeFromParent()

        // Remove all character sprites
        for (_, node) in characterNodes {
            node.removeFromParent()
        }
        characterNodes.removeAll()

        // Build new tilemap
        let newTileMap = TileMap(tiles: room.tileMap)
        self.tileMap = newTileMap

        // Sync tiles to GameState for enemy pathfinding
        Task { @MainActor in
            GameState.shared.updateTilesForCurrentRoom(room.map)
        }
        let mapNode = newTileMap.buildNode()
        mapNode.position = mapOrigin
        addBoardBackplate(for: newTileMap)
        addChild(mapNode)

        // Center camera on map first — will be refined to character position below.
        positionCameraOnMap()

        // Place characters — validate every position against the NEW room's tile map.
        // Characters may carry coordinates from a different room (e.g. back-navigation or
        // first load) that land on walls, out-of-bounds tiles, or enemy spawn points here.
        // validatedSpawnX() checks room.map directly, so it's always correct for this room.
        let spawn = room.playerSpawn
        for (i, character) in characters.enumerated() {
            // Check 1: uninitialized position
            let isUnset = character.positionX == 0 && character.positionY == 0
            // Check 2: position out of bounds for this room
            let outOfBounds = character.positionY < 0
                || character.positionY >= room.map.count
                || character.positionX < 0
                || character.positionX >= (room.map.first?.count ?? 0)
            // Check 3: position is a wall / unwalkable tile in this room
            let isBlocked: Bool = {
                guard !isUnset && !outOfBounds else { return false }
                let tile = room.map[character.positionY][character.positionX]
                return tile != TileType.floor.rawValue
                    && tile != TileType.cover.rawValue
                    && tile != TileType.door.rawValue
                    && tile != TileType.extraction.rawValue
            }()

            if isUnset || outOfBounds || isBlocked {
                let candidate = validatedSpawnX(in: room,
                                                proposedX: spawn.x + i,
                                                proposedY: spawn.y)
                character.positionX = candidate.x
                character.positionY = candidate.y
                print("[BattleScene] loadRoom: repositioned \(character.name) → (\(candidate.x),\(candidate.y)) reason: unset=\(isUnset) oob=\(outOfBounds) blocked=\(isBlocked)")
            }
            placeCharacter(character)
        }

        // Place enemies for this room.
        for enemy in enemies {
            placeEnemy(enemy)
        }

        // Clear highlights
        clearHighlights()

        // Select first character
        if let first = characters.first(where: { $0.isAlive }) {
            selectCharacter(id: first.id)

            // After room load, focus camera on the first character so they're
            // always visible — prevents spawn-at-edge-of-map invisible placement.
            focusCamera(on: first.positionX, y: first.positionY)

            // Freeze all player characters except the active one so only
            // the current actor's idle animation runs at mission start.
            updatePlayerIdleAnimations(activeId: first.id)
        }
    }

    /// Check if the given tile is a door tile in the current room.
    /// Returns false if the door has already been auto-opened.
    func isDoorTile(_ tileX: Int, _ tileY: Int) -> Bool {
        guard let tm = tileMap else { return false }
        let key = "\(tileX),\(tileY)"
        if openedDoorKeys.contains(key) { return false }  // already opened
        return tm.tiles[tileY][tileX] == .door
    }

    /// Check if the given tile is an extraction tile.
    func isExtractionTile(_ tileX: Int, _ tileY: Int) -> Bool {
        guard let tm = tileMap else { return false }
        return tm.tiles[tileY][tileX] == .extraction
    }

    /// Check if a given tile is walkable (floor, door, extraction, or cover — NOT wall).
    func isWalkableTile(_ tileX: Int, _ tileY: Int) -> Bool {
        guard let tm = tileMap else { return false }
        guard tileX >= 0, tileX < TileMap.mapWidth, tileY >= 0, tileY < tm.mapHeight else { return false }
        let t = tm.tiles[tileY][tileX]
        return t == .floor || t == .door || t == .extraction || t == .cover
    }

    private func validatedSpawnX(in room: Room, proposedX: Int, proposedY: Int) -> (x: Int, y: Int) {
        func isWalkable(_ x: Int, _ y: Int) -> Bool {
            guard y >= 0, y < room.map.count, x >= 0, x < room.map[y].count else { return false }
            let tile = room.map[y][x]
            return tile == TileType.floor.rawValue || tile == TileType.cover.rawValue || tile == TileType.door.rawValue || tile == TileType.extraction.rawValue
        }

        if isWalkable(proposedX, proposedY) {
            return (proposedX, proposedY)
        }

        let offsets = [(0,1),(1,0),(0,-1),(-1,0),(1,1),(1,-1),(-1,1),(-1,-1)]
        for (dx, dy) in offsets {
            let nx = proposedX + dx
            let ny = proposedY + dy
            if isWalkable(nx, ny) {
                return (nx, ny)
            }
        }

        return (room.playerSpawn.x, room.playerSpawn.y)
    }

    /// Fade out after room load.
    func fadeOutFromTransition() {
        // Prefer the stored reference; fall back to child-name search in camera then scene.
        let fade: SKNode? = fadeNode
            ?? camera?.childNode(withName: "fadeOverlay")
            ?? childNode(withName: "fadeOverlay")
        guard let fade = fade else { return }
        let fadeOut = SKAction.fadeAlpha(to: 0.0, duration: 0.4)
        fadeOut.timingMode = .easeOut
        fade.run(fadeOut) { [weak self] in
            fade.removeFromParent()
            self?.fadeNode = nil
        }
    }

    // MARK: - Tap / Touch

    private func flashTile(tileX: Int, tileY: Int) {
        // Only flash if no existing flash on this tile (prevent stacking)
        if childNode(withName: "flashTile_\(tileX)_\(tileY)") != nil { return }
        HapticsManager.shared.tileTap()
        let tileNode = SKShapeNode(path: TileMap.hexPath(radius: TileMap.hexRadius - 2))
        tileNode.strokeColor = UIColor(hex: "#FFD700").withAlphaComponent(0.6)
        tileNode.lineWidth = 1.5
        tileNode.fillColor = UIColor(hex: "#FFD700").withAlphaComponent(0.15)
        tileNode.position = tileCenter(tileX, tileY)
        tileNode.zPosition = 5
        tileNode.name = "flashTile_\(tileX)_\(tileY)"
        addChild(tileNode)

        let fade = SKAction.fadeOut(withDuration: 0.25)
        let remove = SKAction.removeFromParent()
        tileNode.run(SKAction.sequence([fade, remove]))

        // Ripple effect — expanding ring
        let ripple = SKShapeNode(circleOfRadius: 5)
        ripple.strokeColor = UIColor(hex: "#FFD700").withAlphaComponent(0.5)
        ripple.lineWidth = 1.5
        ripple.fillColor = .clear
        ripple.position = tileNode.position
        ripple.zPosition = 6
        ripple.name = "flashRipple"
        addChild(ripple)
        let expand = SKAction.scale(to: 3.0, duration: 0.4)
        let fadeRipple = SKAction.fadeOut(withDuration: 0.4)
        let removeRipple = SKAction.removeFromParent()
        ripple.run(SKAction.sequence([SKAction.group([expand, fadeRipple]), removeRipple]))
    }

    private func handleTileTap(tileX: Int, tileY: Int) {
        // Guard: block all taps while player input is locked during enemy phase
        guard !playerInputLocked else {
            print("[BattleScene] Input locked — waiting for enemy phase")
            return
        }
        // Check if this is a door tile — if so, attempt room transition
        if isDoorTile(tileX, tileY) {
            handleDoorTileTap(tileX: tileX, tileY: tileY)
            return
        }

        // Check extraction tile — win immediately if all enemies are cleared and player stands on it
        if isExtractionTile(tileX, tileY) {
            // Extraction resolution is GameState-authoritative.
            if let sprite = selectedCharacterNode as? SpriteNode,
               let charEntry = characterNodes.first(where: { $0.value === sprite }) {
                animateCharacterMove(characterId: charEntry.key, toTileX: tileX, toTileY: tileY)
                sprite.tileX = tileX
                sprite.tileY = tileY
                GameState.shared.requestExtraction(characterId: charEntry.key, tileX: tileX, tileY: tileY)
            } else {
                GameState.shared.requestExtraction(characterId: nil, tileX: tileX, tileY: tileY)
            }
            return
        }

        // Find what's on this tile
        var characterOnTile: (id: UUID, sprite: SpriteNode)?
        var enemyOnTile: (id: UUID, sprite: SpriteNode)?

        for (id, node) in characterNodes {
            guard let sprite = node as? SpriteNode else { continue }
            if sprite.tileX == tileX && sprite.tileY == tileY {
                if sprite.team == "player" {
                    characterOnTile = (id, sprite)
                } else {
                    enemyOnTile = (id, sprite)
                }
            }
        }

        // 1. Tap on player character -> select it (always allowed)
        if let (id, _) = characterOnTile {
            showSelectionRing(for: id)
            // Render layer emits selection intent only.
            CombatFlowController.requestCharacterSelectionFromScene(gameState: GameState.shared, id: id)
            return
        }

        // 2. Tap on enemy with a character selected -> attack!
        if let (_, enemySprite) = enemyOnTile {
            if GameState.shared.activeCharacterId != nil || GameState.shared.selectedCharacterId != nil {
                if let enemyId = UUID(uuidString: enemySprite.enemyId), !enemySprite.enemyId.isEmpty {
                    CombatFlowController.requestAttackOnEnemy(gameState: GameState.shared, enemyId: enemyId)
                } else {
                    GameState.shared.addLog("Cannot target this enemy.")
                }
                return
            } else {
                GameState.shared.addLog("Select a character first.")
                return
            }
        }

        // 3. Tap empty tile -> move the selected character (FREE action, no turn cost)
        guard let sprite = selectedCharacterNode as? SpriteNode else {
            GameState.shared.addLog("Select a character first.")
            return
        }

        guard let charEntry = characterNodes.first(where: { $0.value === sprite }) else { return }
        let charId = charEntry.key

        let reachable = bfsReachable(fromX: sprite.tileX, fromY: sprite.tileY, maxSteps: movementRange)
        let isInRange = reachable.contains(where: { $0.x == tileX && $0.y == tileY })

        if isInRange {
            guard isWalkableTile(tileX, tileY) else {
                GameState.shared.addLog("Cannot move to wall tile (\(tileX),\(tileY))")
                return
            }
            // Movement is a FREE action — no turn cost
            animateCharacterMove(characterId: charId, toTileX: tileX, toTileY: tileY)
            GameState.shared.moveCharacter(id: charId, toTileX: tileX, toTileY: tileY)
            sprite.tileX = tileX
            sprite.tileY = tileY

            if isDoorTile(tileX, tileY) {
                openDoor(tileX: tileX, tileY: tileY)
            }
            clearHighlights()
        } else {
            GameState.shared.addLog("Out of range (max \(movementRange) steps).")
        }
    }

    /// Auto-open a door tile when the player steps adjacent to it.
    /// Changes the door tile to a floor tile so it becomes walkable.
    private func openDoor(tileX: Int, tileY: Int) {
        guard isDoorTile(tileX, tileY) else { return }
        let key = "\(tileX),\(tileY)"
        openedDoorKeys.insert(key)  // mark as opened so we don't re-trigger

        // Update the tile visual in the scene — replace door appearance with hex floor.
        if let tileNode = childNode(withName: "tile_\(tileX)_\(tileY)") {
            tileNode.removeAllChildren()
            let isEven = (tileX + tileY) % 2 == 0
            let R = TileMap.hexRadius

            // Base hex fill matching floor style
            let base = SKShapeNode(path: TileMap.hexPath(radius: R))
            base.fillColor = isEven
                ? UIColor(red: 0.03, green: 0.05, blue: 0.09, alpha: 1.0)
                : UIColor(red: 0.04, green: 0.06, blue: 0.11, alpha: 1.0)
            base.strokeColor = .clear
            base.zPosition = 0
            tileNode.addChild(base)

            // Neon cyan hex border — open doorway glows slightly brighter
            let border = SKShapeNode(path: TileMap.hexPath(radius: R))
            border.fillColor = .clear
            border.strokeColor = UIColor(hex: "#00E4FF").withAlphaComponent(0.75)
            border.lineWidth = 1.5
            border.zPosition = 1
            tileNode.addChild(border)

            // Brief flash to signal the door opened
            border.run(SKAction.sequence([
                SKAction.fadeAlpha(to: 1.0, duration: 0.1),
                SKAction.fadeAlpha(to: 0.75, duration: 0.4)
            ]))
        }

        GameState.shared.addLog("Door opened at (\(tileX),\(tileY))")
        HapticsManager.shared.buttonTap()
    }

    private func handleDoorTileTap(tileX: Int, tileY: Int) {
        // Only trigger if a player character is selected and either adjacent to or standing on the door
        guard let sprite = selectedCharacterNode as? SpriteNode else {
            GameState.shared.addLog("Select a character, then step onto the door.")
            return
        }
        let dx = abs(tileX - sprite.tileX)
        let dy = abs(tileY - sprite.tileY)
        // Trigger if standing on the door tile (dx=0,dy=0) OR adjacent to it (one of 8 surrounding tiles)
        let canTrigger = (dx == 0 && dy == 0) || (dx <= 1 && dy <= 1 && (dx + dy > 0))
        guard canTrigger else {
            GameState.shared.addLog("Move adjacent to the door first.")
            return
        }

        // Attempt room transition
        if let targetRoom = RoomManager.shared.attemptTransition(from: currentRoomId, atTileX: tileX, y: tileY) {
            // Update GameState position to the door tile — animateCharacterMove does NOT update
            // GameState, so we must update it here so loadRoom places character at spawn correctly.
            if let charEntry = characterNodes.first(where: { $0.value === sprite }) {
                let charId = charEntry.key
                // Track WHICH character triggered the door — only this one moves to the connection spawn.
                doorTransitionCharacterId = charId
                // Update position directly (don't call moveCharacter — that would trigger endTurn
                // which would immediately kick off an enemy phase during the room fade transition).
                // NOTE: hasActedThisRound is NOT set here — the character retains their action for
                // the new room. They keep their turn, allowing all players to cycle before enemies.
                if let char = GameState.shared.playerTeam.first(where: { $0.id == charId }) {
                    char.positionX = tileX
                    char.positionY = tileY
                }
            }
            GameState.shared.addLog("Entering: \(targetRoom.title)...")
            // Mark room as entered (before beginTransition so the flag is set for handleRoomTransitionCompleted)
            RoomManager.shared.markRoomEntered(targetRoom.id)
            // Begin fade transition — do NOT animate character move here; the sprite is removed
            // on room load anyway and characters are placed at the connection's target spawn.
            RoomManager.shared.beginTransition(to: targetRoom)
            NotificationCenter.default.post(name: .roomTransitionStarted, object: nil)
        } else {
            GameState.shared.addLog("Door is locked or leads nowhere.")
        }
    }

    // MARK: - Update Loop

    /// Safety timeout: if isPlayerInputBlocked stays true for >5 seconds without
    /// .enemyPhaseCompleted firing (e.g. DispatchGroup leak or silent crash in enemy AI),
    /// force-unblock and restore the player's turn so the game doesn't freeze permanently.
    override func update(_ currentTime: TimeInterval) {
        refreshTraceVisuals()
        if GameState.shared.isInputBlockedByPhase {
            if inputBlockedSince == nil {
                inputBlockedSince = currentTime
            } else if currentTime - inputBlockedSince! > 5.0 {
                print("[BattleScene] ⚠️ Safety timeout: isPlayerInputBlocked stuck for >5s — force-unblocking")
                playerInputLocked = false
                isEnemyPhaseRunning = false
                // Safety fallback still routes authority through combat flow owner.
                CombatFlowController.restorePlayerControlAfterEnemyPhase(gameState: GameState.shared)
                inputBlockedSince = nil
            }
        } else {
            inputBlockedSince = nil
        }
    }

    // MARK: - Enemy Phase

    /// Runs the enemy phase: calls into GameState to process all enemy AI moves,
    /// then unlocks player input when complete.
    private func runEnemyPhase() {
        print("[BattleScene] enemyPhase started")
        guard playerInputLocked else {
            print("[BattleScene] runEnemyPhase called but input is not locked — ignoring")
            return
        }
        // Bug 3 fix: skip enemy phase if no enemies are alive
        if GameState.shared.enemies.filter({ $0.isAlive }).isEmpty {
            print("Forge: enemy doing turn — no enemies alive, skipping")
            NotificationCenter.default.post(name: .enemyPhaseCompleted, object: nil)
            return
        }
        print("Forge: enemy doing turn")
        isEnemyPhaseRunning = true

        // Update UI to show enemy turn
        NotificationCenter.default.post(name: .enemyPhaseBegan, object: nil)

        // Trigger GameState's enemy phase — this runs all enemy AI and will call
        // back via notifications (enemyMoved, enemyDied, etc.) as each enemy acts.
        // When it completes it posts .enemyPhaseCompleted to unblock player input.
        GameState.shared.enemyPhase()
    }

    // MARK: - Enemy Attack Visual

    /// Play a clear enemy attack animation: slash line from enemy to player, player flash.
    /// Called when the .playerHit notification is received (during enemy phase).
    func playEnemyAttackEffect(enemyId: UUID, playerId: UUID, damage: Int) {
        // Show slash line immediately at the attack moment
        showEnemyAttackSlash(fromEnemy: enemyId, toPlayer: playerId)
        // Flash the player sprite red + show floating damage
        playPlayerHitEffect(on: playerId, damage: damage, enemyIdStr: enemyId.uuidString)
    }

    // MARK: - Animations

    func playHitEffect(on id: UUID, damage: Int = 0) {
        guard let node = characterNodes[id] else { return }
        SpriteManager.shared.animateHit(target: node)
        // Emit spark particles at hit location
        EffectsManager.shared.emitSparks(at: node.position, in: self, count: 14)
        // Show floating damage number
        if damage > 0 {
            EffectsManager.shared.showDamageNumber(damage, at: node.position, in: self)
        }
        // Screen shake for enemy hits
        EffectsManager.shared.screenShake(on: self, intensity: 5, duration: 0.2)
        // Update HP label if it's an enemy
        if let sprite = node as? SpriteNode,
           let enemyId = UUID(uuidString: sprite.enemyId),
           let enemy = GameState.shared.enemies.first(where: { $0.id == enemyId }) {
            SpriteManager.shared.updateHP(on: node, currentHP: enemy.currentHP, maxHP: enemy.maxHP, currentStun: enemy.currentStun, maxStun: enemy.maxStun)

            // Update HP bar visual
            let pct = CGFloat(max(0, enemy.currentHP)) / CGFloat(max(1, enemy.maxHP))
            if let fill = node.childNode(withName: "hpBarFill_\(enemyId.uuidString)") as? SKShapeNode {
                let newWidth = max(1, 36 * pct)
                let newFill = SKShapeNode(rectOf: CGSize(width: newWidth, height: 4), cornerRadius: 2)
                newFill.fillColor = pct > 0.5
                    ? UIColor(red: 0.2, green: 1.0, blue: 0.3, alpha: 0.9)
                    : pct > 0.25
                        ? UIColor(red: 1.0, green: 0.6, blue: 0.0, alpha: 0.9)
                        : UIColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 0.9)
                newFill.strokeColor = UIColor.clear
                newFill.position = CGPoint(x: -(36 - newWidth) / 2, y: 22)
                newFill.zPosition = 16
                newFill.name = "hpBarFill_\(enemyId.uuidString)"
                fill.removeFromParent()
                node.addChild(newFill)
            }
            if let label = node.childNode(withName: "hpLabel_\(enemyId.uuidString)") as? SKLabelNode {
                label.text = "\(max(0, enemy.currentHP))/\(enemy.maxHP)"
            }
        }
    }

    func playPlayerHitEffect(on id: UUID, damage: Int, enemyIdStr: String? = nil) {
        guard let node = characterNodes[id] else { return }

        // Show attack indicator: slash line from enemy to player
        if let eIdStr = enemyIdStr, let enemyId = UUID(uuidString: eIdStr),
           let enemyNode = characterNodes[enemyId] {
            showAttackSlash(from: enemyNode.position, to: node.position)
        }

        SpriteManager.shared.animateHit(target: node)
        // Show orange floating damage text
        if damage > 0 {
            EffectsManager.shared.showFloatingText("-\(damage)", at: node.position, in: self, color: UIColor(hex: "#FF8800"))
        }
        // Red flash for player hits
        let flash = SKAction.run {
            for child in node.children {
                if let shape = child as? SKShapeNode {
                    let orig = shape.fillColor
                    shape.fillColor = UIColor.red.withAlphaComponent(0.6)
                    let restore = SKAction.run { shape.fillColor = orig }
                    shape.run(SKAction.sequence([
                        SKAction.wait(forDuration: 0.1),
                        restore
                    ]))
                }
            }
        }
        node.run(flash)
        EffectsManager.shared.screenShake(on: self, intensity: 8, duration: 0.25)
        // Update player HP bar
        if let sprite = node as? SpriteNode,
           !sprite.characterId.isEmpty,
           let charId = UUID(uuidString: sprite.characterId),
           let char = GameState.shared.playerTeam.first(where: { $0.id == charId }) {
            SpriteManager.shared.updateHP(on: node, currentHP: char.currentHP, maxHP: char.maxHP, currentStun: char.currentStun, maxStun: char.maxStun, level: char.level, isPlayer: true)
        }
    }

    /// Play a shield pulse effect on a defending character.
    func playDefendEffect(on id: UUID) {
        guard let node = characterNodes[id] else { return }
        // Brief blue/cyan ring expand
        let ring = SKShapeNode(circleOfRadius: 22)
        ring.strokeColor = UIColor(hex: "#4488FF")
        ring.lineWidth = 3
        ring.fillColor = UIColor(hex: "#4488FF").withAlphaComponent(0.1)
        ring.name = "shieldRing"
        ring.zPosition = 12
        ring.alpha = 0
        node.addChild(ring)

        let fadeIn = SKAction.fadeAlpha(to: 1.0, duration: 0.1)
        let expand = SKAction.scale(to: 1.5, duration: 0.4)
        let fadeOut = SKAction.fadeOut(withDuration: 0.3)
        let remove = SKAction.removeFromParent()
        ring.run(SKAction.sequence([fadeIn, SKAction.group([expand, fadeOut]), remove]))
        HapticsManager.shared.selectionChanged()
    }

    func playLevelUpEffect(on id: UUID) {
        guard let node = characterNodes[id] else { return }
        EffectsManager.shared.emitLevelUp(at: node.position, in: self)
        // Golden flash on the sprite
        let flash = SKAction.run {
            for child in node.children {
                if let shape = child as? SKShapeNode {
                    let orig = shape.fillColor
                    let gold = UIColor(hex: "#FFD700")
                    shape.run(SKAction.sequence([
                        SKAction.run { shape.fillColor = gold },
                        SKAction.wait(forDuration: 0.15),
                        SKAction.run { shape.fillColor = orig }
                    ]))
                }
            }
        }
        node.run(flash)
    }

    func playDeathEffect(on id: UUID) {
        guard let node = characterNodes[id] else { return }
        let pos = node.position
        EffectsManager.shared.emitBlood(at: pos, in: self, count: 12)
        EffectsManager.shared.emitCyberGlitch(at: pos, in: self)
        EffectsManager.shared.screenShake(on: self, intensity: 10, duration: 0.3)
        removeCharacter(id: id)
    }

    private func animateEnemyMove(id: UUID, toX: Int, toY: Int) {
        guard let node = characterNodes[id] else {
            print("[BattleScene] animateEnemyMove: no node found for id=\(id)")
            return
        }

        // Emit brief smoke/ember trail at old position before moving
        let oldPos = node.position
        let trail = SKEmitterNode()
        trail.particleBirthRate = 0
        trail.numParticlesToEmit = 6
        trail.particleLifetime = 0.4
        trail.particleLifetimeRange = 0.1
        trail.particleSpeed = 15
        trail.particleSpeedRange = 10
        trail.emissionAngleRange = .pi * 2
        trail.particleAlpha = 0.6
        trail.particleAlphaSpeed = -1.5
        trail.particleScale = 0.8
        trail.particleScaleSpeed = -1.5
        trail.particleColor = UIColor(hex: "#FF4400")
        trail.particleColorBlendFactor = 1.0
        trail.position = oldPos
        trail.zPosition = 30
        addChild(trail)
        trail.run(SKAction.sequence([SKAction.wait(forDuration: 0.6), SKAction.removeFromParent()]))

        // Switch to walk animation BEFORE moving, return to idle on completion.
        // animateMove handles this for SpriteNode targets (which enemies always are).
        // The explicit call here ensures it fires even if animateMove's cast fails.
        if let sprite = node as? SpriteNode {
            SpriteManager.shared.animate(state: .walk, target: sprite)
        }
        SpriteManager.shared.animateMove(target: node, toTileX: toX, toTileY: toY, duration: 0.35, mapOrigin: mapOrigin)
        if let sprite = node as? SpriteNode {
            sprite.tileX = toX
            sprite.tileY = toY
        }
    }

    private func focusCamera(on characterId: UUID) {
        if let node = characterNodes[characterId] as? SpriteNode {
            focusCamera(on: node.tileX, y: node.tileY)
            return
        }

        if let character = GameState.shared.playerTeam.first(where: { $0.id == characterId }) {
            focusCamera(on: character.positionX, y: character.positionY)
            return
        }

        if let enemy = GameState.shared.enemies.first(where: { $0.id == characterId }) {
            focusCamera(on: enemy.positionX, y: enemy.positionY)
            return
        }

        positionCameraOnMap()
    }

    /// Enemy attack: draw an orange slash line FROM enemy TO player.
    /// This is called synchronously from runEnemyAI via the .playerHit notification
    /// BEFORE animateEnemyMove runs, so the slash appears at the attack moment.
    private func showEnemyAttackSlash(fromEnemy enemyId: UUID, toPlayer playerId: UUID) {
        guard let enemyNode = characterNodes[enemyId],
              let playerNode = characterNodes[playerId] else { return }
        showAttackSlash(from: enemyNode.position, to: playerNode.position)
    }

    /// Draw a brief orange slash line from attacker position to target position
    /// to make enemy attacks visually obvious.
    private func showAttackSlash(from start: CGPoint, to end: CGPoint) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = sqrt(dx * dx + dy * dy)
        guard length > 0 else { return }

        let angle = atan2(dy, dx)

        // Main slash line — wider for more impact
        let slash = SKShapeNode(rectOf: CGSize(width: length, height: 4))
        slash.fillColor = UIColor(hex: "#FF4400").withAlphaComponent(0.85)
        slash.strokeColor = .clear
        slash.position = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        slash.zRotation = angle
        slash.zPosition = 25  // above characters (z=10) and HP bars (z=21)
        slash.name = "attackSlash"
        slash.alpha = 0
        addChild(slash)

        // Glow halo — wider for more dramatic effect
        let glow = SKShapeNode(rectOf: CGSize(width: length, height: 12))
        glow.fillColor = UIColor(hex: "#FF6600").withAlphaComponent(0.3)
        glow.strokeColor = .clear
        glow.position = slash.position
        glow.zRotation = angle
        glow.zPosition = 24
        glow.name = "attackSlash"
        glow.alpha = 0
        addChild(glow)

        let fadeIn = SKAction.fadeAlpha(to: 1.0, duration: 0.05)
        let fadeOut = SKAction.fadeOut(withDuration: 0.2)
        let remove = SKAction.removeFromParent()
        let wait = SKAction.wait(forDuration: 0.05)

        slash.run(SKAction.sequence([fadeIn, fadeOut, remove]))
        glow.run(SKAction.sequence([wait, fadeIn, fadeOut, remove]))

        // Impact sparks at hit location
        EffectsManager.shared.emitSparks(at: end, in: self, count: 8)
    }

    private func playRoundStartEffect() {
        // Brief flash at top of screen to signal new round
        let flashBar = SKShapeNode(rectOf: CGSize(width: mapPixelWidth, height: 6))
        flashBar.fillColor = UIColor(hex: "#00FF88").withAlphaComponent(0.3)
        flashBar.strokeColor = .clear
        flashBar.position = CGPoint(
            x: mapOrigin.x + mapPixelWidth / 2,
            y: mapOrigin.y + mapPixelHeight - 10
        )
        flashBar.zPosition = 200
        flashBar.name = "roundFlash"
        addChild(flashBar)

        let fadeUp = SKAction.moveBy(x: 0, y: -30, duration: 0.4)
        let fadeOut = SKAction.fadeOut(withDuration: 0.4)
        let remove = SKAction.removeFromParent()
        flashBar.run(SKAction.sequence([SKAction.group([fadeUp, fadeOut]), remove]))
    }

    /// Returns all tile positions reachable within `maxSteps` steps using BFS.
    /// Respects walls and occupied tiles (enemies block, players don't block for pathfinding).
    private func bfsReachable(fromX: Int, fromY: Int, maxSteps: Int) -> [(x: Int, y: Int)] {
        var visited: Set<String> = ["\(fromX),\(fromY)"]
        var frontier: [(x: Int, y: Int, steps: Int)] = [(fromX, fromY, 0)]
        var reachable: [(x: Int, y: Int)] = []
        let mapH = tileMap?.mapHeight ?? 14

        // Get enemy positions to block movement through them
        let enemyPositions = characterNodes.values.compactMap { node -> String? in
            guard let sprite = node as? SpriteNode, sprite.team == "enemy" else { return nil }
            return "\(sprite.tileX),\(sprite.tileY)"
        }

        while !frontier.isEmpty {
            let (cx, cy, steps) = frontier.removeFirst()
            if steps >= maxSteps { continue }

            for (nx, ny) in hexNeighbors(x: cx, y: cy) {
                guard nx >= 0, nx < TileMap.mapWidth, ny >= 0, ny < mapH else { continue }
                let key = "\(nx),\(ny)"
                guard !visited.contains(key) else { continue }
                guard isWalkableTile(nx, ny) else { continue }
                // Enemies block movement
                guard !enemyPositions.contains(key) else { continue }
                visited.insert(key)
                reachable.append((nx, ny))
                frontier.append((nx, ny, steps + 1))
            }
        }
        return reachable
    }
}

import SpriteKit

/// Main SpriteKit scene for battle rendering and interaction.
final class BattleScene: SKScene {

    /// Tokens for every block-based NotificationCenter observer this scene
    /// registers. A fresh BattleScene is created per mission, so without
    /// removing these the registrations pile up in NotificationCenter across a
    /// session (each old scene's 33 closures keep firing as no-ops). `observe`
    /// stores the token; `deinit` removes them all.
    private var notificationTokens: [NSObjectProtocol] = []

    /// Register a block observer and retain its token for teardown.
    private func observe(_ name: Notification.Name, _ handler: @escaping (Notification) -> Void) {
        notificationTokens.append(
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main, using: handler)
        )
    }

    deinit {
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Long-press recognizer added to the (reused) SKView in `didMove`;
    /// removed in `willMove(from:)` so the view doesn't retain this scene.
    private weak var longPressRecognizer: UILongPressGestureRecognizer?

    // MARK: - Properties

    private var tileMap: TileMap?
    /// Bottom padding added to scene height so the bottom row sits above the CombatUI bar.
    private let mapBottomPadding: CGFloat = 0
    /// Cached map dimensions for coordinate conversion — derived from the TileMap instance.
    /// Pointy-top odd-r bounding box:
    ///   width  = cols · hexColSpacing + R/2       (right-side pointy vertex extends 0.5R)
    ///   height = (rows + 0.5) · hexRowSpacing     (odd-col shift adds half a row down)
    private var mapPixelWidth: CGFloat { CGFloat(TileMap.mapWidth) * TileMap.hexColSpacing + TileMap.hexRadius * 0.5 }
    private var mapPixelHeight: CGFloat { (CGFloat(tileMap?.mapHeight ?? 9) + 0.5) * TileMap.hexRowSpacing }
    /// Scene-space offset of the tile map's bottom-left corner.
    /// With scene.size = map pixel dims and .aspectFit, this is (.zero) — map fills scene exactly.
    /// Scene-space Y offset applied to camera target; positive lowers the camera so the map sits higher on screen.
    private let firstTurnCameraYOffset: CGFloat = 36
    private var mapOrigin: CGPoint {
        CGPoint(
            x: max(0, (self.size.width  - mapPixelWidth)  / 2),
            y: max(0, (self.size.height - mapPixelHeight) / 2)
        )
    }
    private var characterNodes: [UUID: SKNode] = [:]
    private var selectedCharacterNode: SKNode?
    private var lastRenderedTraceTier: Int = -1

    /// Movement range for BFS pathfinding — 4 hexes per turn (SR5 sprint range for tactical mobility)
    private var movementRange: Int { return 2 }

    /// Current room ID — synced with RoomManager.currentRoomId during transitions.
    var currentRoomId: String = "room_0"


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

    /// First-tap timestamp of the "hack the terminal" warning. When the player
    /// tries to leave a room that still contains an unhacked required terminal,
    /// we BLOCK the transition once and post a warning. A second tap on the
    /// door within `warnConfirmWindow` seconds confirms they want to skip the
    /// terminal anyway and lets the transition through. Reset to nil when the
    /// room changes.
    private var lastTerminalWarningAt: Date?
    private let warnConfirmWindow: TimeInterval = 5.0

    // MARK: - Pending Initial Load
    // BattleSceneView stashes these BEFORE presentScene; didMove processes them AFTER
    // the view is attached. This eliminates timing issues around scene.size / mapOrigin
    // that caused characters to be invisible on first render.
    private var pendingInitialTileMap: TileMap?
    private var pendingInitialRoomId: String?
    private var pendingInitialCharacters: [Character] = []
    private var pendingInitialEnemies: [Enemy] = []

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
        setupLongPressRecognizer()
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
            dlog("[BattleScene] didMove: initial load complete, characterNodes=\(characterNodes.count)")
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

    /// Add a UIKit long-press recognizer to the SKView so a sustained press
    /// on a character or enemy tile surfaces their info-dossier sheet. Single
    /// taps still flow through `touchesBegan` → `handleTileTap` for
    /// move/select/attack — long-press doesn't consume that path.
    private func setupLongPressRecognizer() {
        guard let view = self.view else { return }
        guard longPressRecognizer == nil else { return }
        let lpr = UILongPressGestureRecognizer(target: self,
                                               action: #selector(handleLongPress(_:)))
        lpr.minimumPressDuration = 0.45
        lpr.allowableMovement = 12
        lpr.delaysTouchesBegan = false
        view.addGestureRecognizer(lpr)
        longPressRecognizer = lpr
    }

    /// The SKView is reused across missions; the recognizer holds a strong
    /// reference to its target (this scene), so leaving it attached pins every
    /// replaced scene — and its notification observers — alive forever.
    override func willMove(from view: SKView) {
        if let lpr = longPressRecognizer {
            view.removeGestureRecognizer(lpr)
            longPressRecognizer = nil
        }
        super.willMove(from: view)
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        // Only fire on .began so we don't spam multiple sheet requests.
        guard gesture.state == .began else { return }
        guard let view = self.view else { return }
        // Convert UIKit point → scene point via SpriteKit's helper.
        let viewPoint = gesture.location(in: view)
        let scenePoint = convertPoint(fromView: viewPoint)
        // Same hex math as touchesBegan.
        let rawX = Int((scenePoint.x - mapOrigin.x) / TileMap.hexColSpacing)
        let clampedX = max(0, min(rawX, TileMap.mapWidth - 1))
        let colYOffset: CGFloat = (clampedX % 2 == 1) ? TileMap.hexRowSpacing / 2.0 : 0
        let rawY = Int((scenePoint.y - mapOrigin.y - colYOffset) / TileMap.hexRowSpacing)
        let clampedY = max(0, min(rawY, (tileMap?.mapHeight ?? 9) - 1))

        // Find a character or enemy at this tile; ignore if neither.
        if let char = GameState.shared.playerTeam.first(where: {
            $0.positionX == clampedX && $0.positionY == clampedY && $0.isAlive
        }) {
            HapticsManager.shared.selectionChanged()
            NotificationCenter.default.post(
                name: .entityInfoRequested,
                object: nil,
                userInfo: ["kind": "player", "characterId": char.id.uuidString]
            )
        } else if let enemy = GameState.shared.enemies.first(where: {
            $0.positionX == clampedX && $0.positionY == clampedY && $0.isAlive
        }) {
            HapticsManager.shared.selectionChanged()
            NotificationCenter.default.post(
                name: .entityInfoRequested,
                object: nil,
                userInfo: ["kind": "enemy", "enemyId": enemy.id.uuidString]
            )
        }
    }

    private func setupRoomNotifications() {
        observe(.roomTransitionStarted) { [weak self] _ in
            self?.performRoomTransitionFade()
        }
        observe(.roomTransitionCompleted) { [weak self] _ in
            self?.handleRoomTransitionCompleted()
        }
        // Room navigation arrows in CombatUI
        observe(.roomNavigationRequested) { [weak self] notification in
            guard let dir = notification.userInfo?["direction"] as? String else { return }
            self?.handleRoomNavigationArrow(direction: dir)
        }
        observe(.roomCleared) { [weak self] _ in
            self?.refreshObjectiveMarkers()
            // Reveal the grimoire highlight now that the boss/room is clear —
            // it's suppressed during the fight so the text doesn't clutter the
            // ritual scene. Fades in. No-op outside M3R2.
            self?.spawnRoomSpecificProps(roomId: GameState.shared.currentRoomId, announce: true)
        }
        observe(.grimoireAcquired) { [weak self] _ in
            self?.handleGrimoireAcquired()
        }
        observe(.barriersDropped) { [weak self] note in
            guard let coords = note.userInfo?["tiles"] as? [[String: Int]] else { return }
            self?.dropBarrierTiles(coords: coords)
        }
        // Cover destroyed mid-combat (barrel detonation / splintered crate).
        // NOT routed through dropBarrierTiles: that pass patches the tile by
        // sampling "clean floor" pixels from the room background image, and
        // the sample offset is only reliable for the one authored M1 barrier
        // wall — on arbitrary cover tiles it grabbed mismatched chunks of BG
        // art. Destroyed cover instead gets a SCORCH overlay (charred hex +
        // soot), which is coordinate-exact by construction and thematically
        // honest for a detonated barrel / shot-up crate. Detonations also
        // post .fireballEffect from GameState.detonateBarrelsNear, so the
        // blast bloom + screen shake ride the existing explosion pipeline.
        observe(.coverTileDestroyed) { [weak self] note in
            guard let coords = note.userInfo?["tiles"] as? [[String: Int]] else { return }
            self?.stampScorchedFloor(coords: coords)
        }
        observe(.extractionAnimationRequested) { [weak self] note in
            guard let x = note.userInfo?["x"] as? Int,
                  let y = note.userInfo?["y"] as? Int else { return }
            // The notification queue is `.main`, so the closure already runs
            // on the main thread, but Swift's strict concurrency check needs
            // an explicit @MainActor hop to verify it.
            Task { @MainActor [weak self] in
                let type = RoomManager.shared.currentMission?.extractionType ?? "helicopter"
                switch type {
                case "ladder":
                    self?.playLadderExtractionAnimation(extractionX: x, extractionY: y)
                case "door":
                    self?.playDoorExtractionAnimation(extractionX: x, extractionY: y)
                case "rooftop_heli":
                    // M4 — heli is already parked on the rooftop. Skip the
                    // dramatic descent and just animate the takeoff.
                    self?.playRooftopHeliExtraction(extractionX: x, extractionY: y)
                default:
                    self?.playExtractionHelicopterAnimation(extractionX: x, extractionY: y)
                }
            }
        }
    }

    // MARK: - Helicopter Extraction Animation

    /// Plays the helicopter extraction sequence over the given extraction tile.
    /// 1. Players fade out (beamed up)
    /// 2. Heli appears at the tile, spins up, hovers
    /// 3. Heli ascends and flies off-screen
    /// 4. On completion, posts .extractionAnimationCompleted and calls
    ///    CombatFlowController.finalizeExtractionAfterAnimation so the debrief shows.
    /// Park a stationary helicopter on the extraction tile of the current room
    /// (if there is one). Loaded at room start so the player sees the heli
    /// waiting for them on the helipad. Removed when the actual extraction
    /// animation begins so the animated heli takes over.
    func addStationaryExtractionHelicopter() {
        // Remove any previous stationary heli (e.g. from a different room)
        childNode(withName: "stationaryHeli")?.removeFromParent()

        // Skip stationary heli for non-helicopter extraction types
        // (ladder = climb-out, door = freight elevator, etc.).
        // "rooftop_heli" (M4) also wants the parked heli visible during play —
        // its takeoff sequence reuses this same stationary node.
        let type = RoomManager.shared.currentMission?.extractionType ?? "helicopter"
        guard type == "helicopter" || type == "rooftop_heli" else { return }

        // Only show if there's an active extraction tile in the current room
        guard let _ = RoomManager.shared.currentRoom else {
            if !hasExtractionTile() { return }
            placeStationaryHeli()
            return
        }
        guard RoomManager.shared.isExtractionActive() else { return }
        placeStationaryHeli()
    }

    /// Returns true if the active tile map contains an extraction tile.
    private func hasExtractionTile() -> Bool {
        guard let tm = self.tileMap else { return false }
        for row in tm.tiles { if row.contains(.extraction) { return true } }
        return false
    }

    private func placeStationaryHeli() {
        let extractX = GameState.shared.extractionX
        let extractY = GameState.shared.extractionY
        let center = TileMap.tileCenter(x: extractX, y: extractY)
        let mapNode = childNode(withName: "TileMap") ?? self
        let origin = mapNode.position

        guard let idleTex = loadHeliTexture("idle_0") else { return }
        let heli = SKSpriteNode(texture: idleTex)
        // Preserve source aspect. The 2026-06 clean heli art is 1448×1086
        // (≈4:3) full-body with transparent background and NO baked helipad
        // base — width-anchor at 3.4 hex-radii; height follows source aspect.
        let heliW: CGFloat = TileMap.hexRadius * 4.8
        let heliH: CGFloat = heliW * (idleTex.size().height / max(1, idleTex.size().width))
        heli.size = CGSize(width: heliW, height: heliH)
        // Anchor centered. The y-offset lifts the sprite so its BOTTOM edge
        // sits AT the tile center — with anchor (0.5, 0.5) the sprite extends
        // ±heliH/2 from the position, so the multiplier must be 0.5 (not 0.35)
        // to fully clear the lower play-area / HUD edge. The previous 0.35
        // left ~15% of the chopper's lower body (skids/wash) dangling below
        // tile center where it got visually cropped — that was the "M1 heli
        // is cut off at the bottom" bug. 0.55 hovers it just slightly above
        // the pad for a "parked, blades idling" read.
        heli.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        // Lift 0.5×H: the new art is a centered full-body chopper (skids near
        // the bottom of the frame), so a 0.3×H lift seats the skids right
        // around the pad tile for a "parked, blades idling" read. (Earlier
        // values 0.72/0.5 floated this cleaner, no-pad-base art too high.)
        // Matches the takeoff landedPos (0.1×H) so the animated chopper lands
        // exactly where this parked one sits — low on the pad, fully on-screen.
        heli.position = CGPoint(x: origin.x + center.x,
                                y: origin.y + center.y + heliH * 0.1)
        // z=1100 (was 8): ABOVE the whole character layer so runners standing
        // on the pad no longer occlude the chopper's lower body — that overlap
        // was the "heli cut off at the bottom" report. Must clear the active
        // runner too, which BattleScene bumps to ~1046 (depthZ + 1000), so a
        // plain "above z=11" wouldn't be enough if the pad runner is selected.
        heli.zPosition = 1100
        heli.alpha = 0.92
        heli.name = "stationaryHeli"
        addChild(heli)

        // Slow rotor idle cycle (3 frames at 0.45s each — feels grounded, not poised to take off)
        let idleFrames = (0..<3).compactMap { loadHeliTexture("idle_\($0)") }
        if idleFrames.count >= 2 {
            heli.run(SKAction.repeatForever(SKAction.animate(with: idleFrames, timePerFrame: 0.45)))
        }
    }

    private func playExtractionHelicopterAnimation(extractionX: Int, extractionY: Int) {
        playerInputLocked = true

        let center = TileMap.tileCenter(x: extractionX, y: extractionY)
        let mapNode = childNode(withName: "TileMap") ?? self
        let mapOriginPos = mapNode.position
        // Pre-compute heliH so `landedPos` can lift the chopper UP by 0.55×H.
        // Anchor is centered (0.5, 0.5), so the sprite extends ±heliH/2 from
        // its position. A 0.55 multiplier puts the BOTTOM edge slightly
        // ABOVE the tile center — keeping the entire sprite (including the
        // chopper's lower skids / rotor downwash) inside the visible play
        // area. Previous 0.35 was too conservative and left ~15% of the
        // image getting clipped by the HUD / lower tile-grid edge.
        let landedHeliW: CGFloat = TileMap.hexRadius * 4.8
        // Derive aspect from the actual idle texture (new art is ≈4:3) so the
        // landed/taking-off chopper is sized identically to the stationary one
        // — a hardcoded old-art aspect made it resize/jump on takeoff.
        let landedAspect: CGFloat = loadHeliTexture("idle_0").map {
            $0.size().height / max(1, $0.size().width)
        } ?? (1086.0 / 1448.0)
        let landedHeliH: CGFloat = landedHeliW * landedAspect
        // Lift 0.1×H — seats the chopper LOW on the pad, well within the
        // visible play area (playtest, repeatedly: "needs to come down further
        // onto the screen"). Must match the stationary placement below so
        // takeoff begins exactly where the parked chopper sat (no jump).
        let landedPos = CGPoint(x: mapOriginPos.x + center.x,
                                y: mapOriginPos.y + center.y + landedHeliH * 0.1)

        // Remove any leftover stationary heli from a previous load.
        childNode(withName: "stationaryHeli")?.removeAllActions()
        childNode(withName: "stationaryHeli")?.removeFromParent()
        // Also clear any in-flight extraction heli (defensive — should never
        // exist, but if a prior animation didn't finish cleanly, kill it).
        childNode(withName: "extractionHelicopter")?.removeAllActions()
        childNode(withName: "extractionHelicopter")?.removeFromParent()

        // Load all the per-phase rotor-cycle frame sets. The sprite sheet
        // gives us the SAME chopper position with the rotor at 3 different
        // blade angles per phase — so cycling these now actually animates
        // the rotor properly (no body wobble like the bad cuts before).
        // Used as the body texture cycle in setRotor() below.
        let idleFrames      = (0..<3).compactMap { loadHeliTexture("idle_\($0)") }
        let hoverFrames     = (0..<3).compactMap { loadHeliTexture("hover_\($0)") }
        let spinFrames      = (0..<3).compactMap { loadHeliTexture("spinup_\($0)") }
        let takeoffFrames   = (0..<3).compactMap { loadHeliTexture("takeoff_\($0)") }
        let ascendFrames    = (0..<3).compactMap { loadHeliTexture("ascending_\($0)") }
        let departingFrames = (0..<3).compactMap { loadHeliTexture("departing_\($0)") }
        // Legacy "flightFrames" alias for descent — uses idle frames since
        // the sheet has no separate flight column.
        let flightFrames = idleFrames

        // First-frame fallback chain — descent uses flight (= idle) as start.
        let firstTex: SKTexture? = flightFrames.first
            ?? hoverFrames.first
            ?? loadHeliTexture("idle_0")

        // Spawn well above the visible scene so the heli flies in from above.
        let skyOffset: CGFloat = self.size.height * 0.65 + 200
        let skyStart = CGPoint(x: landedPos.x - 80, y: landedPos.y + skyOffset)

        let heli = SKSpriteNode()
        if let tex = firstTex { heli.texture = tex }
        // Size using source aspect — same fix as stationary heli, prevents
        // the vertical stretch that read as a "cut-off bottom."
        let heliW: CGFloat = TileMap.hexRadius * 4.8
        let heliH: CGFloat = {
            guard let tex = firstTex else { return TileMap.hexRadius * 3.0 }
            return heliW * (tex.size().height / max(1, tex.size().width))
        }()
        heli.size = CGSize(width: heliW, height: heliH)
        // Centered anchor — same fix as the stationary heli. The `landedPos`
        // y-offset above (landedHeliH * 0.5) seats the centered full-body
        // chopper's skids around the pad tile, keeping the whole sprite inside
        // the visible play area. Anchor (0.5, 0.5) is just centered; the lift
        // does the rest.
        heli.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        heli.position = skyStart
        heli.zPosition = 1100   // above the character layer (incl. the active runner's +1000 bump)
        heli.alpha = 1.0
        heli.setScale(0.55)   // small at the start of descent (perspective)
        heli.name = "extractionHelicopter"
        addChild(heli)

        // The helicopter sprite-sheet's "flight/hover/spinup/takeoff" frames
        // are different CAMERA ANGLES of the chopper, not rotor-only animation
        // states. Cycling between them rapidly made the whole body appear to
        // spin/wobble. We lock the body to a single texture and add a
        // procedural ROTOR overlay — a fast-spinning thin black ellipse
        // positioned at the rotor head + a faint translucent disc for
        // motion-blur — so the rotor LOOKS like it's whirling without
        // touching the body texture.
        let rotorContainer = SKNode()
        rotorContainer.name = "heliRotor"
        // Position relative to the chopper sprite — rotor sits near the top
        // of the body (sprite is anchored center, so +y from center).
        // With heli.size.height = 108, the rotor head is roughly +30px above
        // sprite center. Tuned by visual fit.
        rotorContainer.position = CGPoint(x: 0, y: 30)
        rotorContainer.zPosition = 0.5  // above the body texture
        heli.addChild(rotorContainer)

        // ── Real rotor frames take precedence ─────────────────────────────
        // Drop frames named rotor_0.png … rotor_3.png (or as many as you
        // have, named consecutively starting at 0) into
        // Sprites/effects/helicopter/, and we'll cycle them as a real
        // SKSpriteNode on the rotor head — same camera angle, just blade
        // rotation. Frame duration is set per phase by setRotor().
        var rotorFrameTextures: [SKTexture] = []
        if let resourceURL = Bundle.main.resourceURL {
            for i in 0..<8 {
                let url = resourceURL.appendingPathComponent("Sprites/effects/helicopter/rotor_\(i).png")
                guard let img = UIImage(contentsOfFile: url.path) else { break }
                rotorFrameTextures.append(SKTexture(image: img))
            }
        }
        let rotorSprite: SKSpriteNode? = {
            guard let first = rotorFrameTextures.first else { return nil }
            // Size the rotor sprite to match the chopper's rotor disc footprint.
            // We assume the source frame's PNG is already cropped to just the
            // rotor (transparent body), at roughly chopper-rotor proportions.
            let s = SKSpriteNode(texture: first)
            // Default to a width similar to the previous procedural disc; the
            // sprite's own aspect drives the height.
            let targetWidth: CGFloat = 90
            let scale = targetWidth / max(1, s.size.width)
            s.setScale(scale)
            s.zPosition = 1
            return s
        }()
        if let rs = rotorSprite {
            rotorContainer.addChild(rs)
            dlog("[BattleScene] heli rotor: using \(rotorFrameTextures.count) sprite frame(s)")
        } else {
            // ── Procedural fallback ─────────────────────────────────────
            // No rotor sprite frames found — fall back to the motion-blur
            // disc + thin streak so the rotor still reads as spinning.
            // This is a placeholder; real frames look better.
            let rotorDiscOuter = SKShapeNode(ellipseOf: CGSize(width: 76, height: 14))
            rotorDiscOuter.fillColor = UIColor.black.withAlphaComponent(0.18)
            rotorDiscOuter.strokeColor = .clear
            rotorDiscOuter.zPosition = 0
            rotorContainer.addChild(rotorDiscOuter)

            let rotorDiscInner = SKShapeNode(ellipseOf: CGSize(width: 60, height: 6))
            rotorDiscInner.fillColor = UIColor.black.withAlphaComponent(0.42)
            rotorDiscInner.strokeColor = .clear
            rotorDiscInner.zPosition = 1
            rotorContainer.addChild(rotorDiscInner)

            let bladeHint = SKShapeNode(rectOf: CGSize(width: 70, height: 1.2), cornerRadius: 0.6)
            bladeHint.fillColor = UIColor.black.withAlphaComponent(0.55)
            bladeHint.strokeColor = .clear
            bladeHint.zPosition = 2
            rotorContainer.addChild(bladeHint)

            let hub = SKShapeNode(circleOfRadius: 2.5)
            hub.fillColor = UIColor(white: 0.25, alpha: 1.0)
            hub.strokeColor = UIColor(white: 0.05, alpha: 1.0)
            hub.lineWidth = 0.5
            hub.zPosition = 3
            rotorContainer.addChild(hub)
        }

        // setRotor: drives the rotor visual per phase.
        //
        // Priority order:
        //   1. Real rotor sprite frames (rotor_*.png) — cycle them on a
        //      transparent overlay above the body. Most accurate.
        //   2. Body-texture cycle — phase frames (idle_0..2, hover_0..2,
        //      etc.) are "same chopper, rotor at different blade angles."
        //      Cycling them animates the in-body rotor.
        //   3. Procedural disc overlay — last-ditch rotating ellipse if
        //      neither sprite frames nor body frames exist.
        //
        // The procedural overlay (option 3) used to render on top of
        // option 2's body cycle, producing a double-rotor look. Hide it
        // whenever option 1 or 2 is active.
        func setRotor(_ frames: [SKTexture], timePerFrame: TimeInterval) {
            // Option 1: dedicated rotor sprite frames.
            if let rs = rotorSprite, rotorFrameTextures.count >= 2 {
                heli.removeAction(forKey: "rotorCycle")
                rotorContainer.isHidden = false
                rs.removeAction(forKey: "rotorSpriteCycle")
                let cycle = SKAction.animate(with: rotorFrameTextures,
                                              timePerFrame: timePerFrame,
                                              resize: false, restore: false)
                rs.run(SKAction.repeatForever(cycle), withKey: "rotorSpriteCycle")
                return
            }
            // Option 2: body-texture cycle. Hide the procedural overlay so
            // it doesn't render on top of the body's baked-in rotor.
            if frames.count >= 2 {
                heli.removeAction(forKey: "rotorCycle")
                let cycle = SKAction.animate(with: frames,
                                              timePerFrame: timePerFrame,
                                              resize: false, restore: false)
                heli.run(SKAction.repeatForever(cycle), withKey: "rotorCycle")
                rotorContainer.isHidden = true
                rotorContainer.removeAction(forKey: "spin")
                return
            }
            // Option 3: procedural overlay (last resort).
            rotorContainer.isHidden = false
            let revolutionDuration = max(0.06, min(0.11, timePerFrame))
            rotorContainer.removeAction(forKey: "spin")
            rotorContainer.run(
                SKAction.repeatForever(
                    SKAction.rotate(byAngle: .pi * 2, duration: revolutionDuration)
                ),
                withKey: "spin"
            )
        }
        // Kick off an initial rotor spin so it reads as "running" while the
        // sprite is descending from the sky. Phases below adjust the speed.
        setRotor(flightFrames, timePerFrame: 0.06)

        // Phase 1 — DESCENT (4.0s, slower + smoother). Single locked body
        // texture. easeInEaseOut + extended duration reads as a real chopper
        // settling in. Bumped 3.0 → 4.0 per playtest note "make heli movement
        // a bit slower and smoother."
        setRotor(flightFrames, timePerFrame: 0.06)
        let descend = SKAction.group([
            SKAction.move(to: landedPos, duration: 4.0),
            SKAction.scale(to: 1.0, duration: 4.0)
        ])
        descend.timingMode = .easeInEaseOut

        // Triggered VFX: ~1s code-rain burst behind the chopper, kicked off
        // ~0.4s into descent so it reads as the chopper "breaking through"
        // the data atmosphere on approach. Procedural cyan glyphs falling.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self,
                  let heli = self.childNode(withName: "extractionHelicopter")
            else { return }
            EffectsManager.shared.emitChopperCodeRain(behind: heli, in: self)
        }

        // Helipad ambience — dust swirl that intensifies during touchdown/
        // lift-off. No-op if the dust VFX PNGs haven't been sliced yet.
        // (The looping floor_ring "helipad circle" was removed — the room
        // background art already paints the helipad, so the procedural ring
        // just doubled it up under the chopper.)
        let padNodeName = "heliPadVFX"
        childNode(withName: padNodeName)?.removeFromParent()
        let padContainer = SKNode()
        padContainer.position = landedPos
        padContainer.zPosition = 5  // under the heli, above floor tiles
        padContainer.name = padNodeName
        addChild(padContainer)
        // Dust loop that lives under the chopper for the entire animation —
        // alpha-blended so it reads as actual dust, not a glow.
        if let dust = VFXManager.shared.makeAmbientNode(effect: .dust, baseDuration: 1.0) {
            dust.position = CGPoint(x: 0, y: -8)
            dust.alpha = 0.0
            dust.run(SKAction.fadeAlpha(to: 0.55, duration: 0.6))
            padContainer.addChild(dust)
        }

        // Phase 2 — TOUCHDOWN bob (0.6s, smoother). Slight easing so the
        // chopper settles instead of jerking on contact.
        let bobDown = SKAction.moveBy(x: 0, y: -3, duration: 0.28)
        bobDown.timingMode = .easeInEaseOut
        let bobUp = SKAction.moveBy(x: 0, y: 3, duration: 0.32)
        bobUp.timingMode = .easeInEaseOut
        let touchdown = SKAction.sequence([bobDown, bobUp])

        // Phase 3 — runners board + heli idles on pad (2.2s total).
        // 2026-05-10: was "fade in place". Runners now actually WALK to the
        // helicopter then fade as they "board it" — visually clear that they
        // left the map. waitOnPad bumped 1.4 → 2.2s so the walk + fade has
        // time to complete before takeoff.
        let onLanded = SKAction.run { [weak self] in
            guard let self = self else { return }
            // Switch to hover/idle frames (slower rotor) while parked.
            setRotor(hoverFrames, timePerFrame: 0.12)
            // Walk each living player to the heli, then fade out as they board.
            // Only player characters — enemies should be dead/cleared by now.
            let boardPos = self.tileCenter(extractionX, extractionY)
            for char in GameState.shared.playerTeam where char.isAlive {
                guard let node = self.characterNodes[char.id] else { continue }
                let walk = SKAction.move(to: boardPos, duration: 1.0)
                walk.timingMode = .easeIn
                let fade = SKAction.fadeOut(withDuration: 0.5)
                // Walk first, then fade as they reach/enter the chopper.
                node.run(SKAction.sequence([walk, fade]))
            }
            // Touchdown dust burst — one-shot.
            if let burst = VFXManager.shared.makeBurstNode(effect: .dust, totalDuration: 0.6) {
                burst.position = landedPos
                burst.zPosition = 6
                self.addChild(burst)
            }
        }
        let waitOnPad = SKAction.wait(forDuration: 2.2)

        // Phase 4 — SPIN-UP rotor (0.5s).
        let spinUp = SKAction.run { setRotor(spinFrames, timePerFrame: 0.08) }
        let spinPause = SKAction.wait(forDuration: 0.5)

        // Phase 5 — LIFT-OFF (1.4s upward, slower + smoother). easeInEaseOut
        // so the chopper unsticks gradually instead of snapping skyward.
        // Was 1.0s/easeIn.
        let liftOffPhase = SKAction.run { [weak self] in
            setRotor(takeoffFrames, timePerFrame: 0.07)
            // Second dust burst as the chopper kicks off.
            if let self = self,
               let burst = VFXManager.shared.makeBurstNode(effect: .dust, totalDuration: 0.7) {
                burst.position = landedPos
                burst.zPosition = 6
                self.addChild(burst)
            }
        }
        let liftOff = SKAction.moveBy(x: 0, y: 40, duration: 1.4)
        liftOff.timingMode = .easeInEaseOut

        // Phase 6 — ASCEND off-screen (4.0s, slower + smoother). easeInEaseOut
        // so the chopper accelerates gradually rather than yanking upward.
        // Bumped 3.0 → 4.0 to match the new descent pacing.
        let ascendPhase = SKAction.run { setRotor(ascendFrames, timePerFrame: 0.10) }
        let ascend = SKAction.group([
            SKAction.move(to: CGPoint(x: landedPos.x + 80, y: landedPos.y + skyOffset),
                          duration: 4.0),
            SKAction.scale(to: 0.55, duration: 4.0)
        ])
        ascend.timingMode = .easeInEaseOut

        // Phase 7 — DEPART fade (0.7s). Body texture stays locked — the
        // departingFrames cycle would spin the body (see flight-frame note
        // above).
        _ = departingFrames
        let depart = SKAction.fadeOut(withDuration: 0.7)

        // Final closure — must run BEFORE removeFromParent so the node still
        // ticks when this fires. Resets state + tells the game logic the
        // animation is done and combat can finalize.
        let onComplete = SKAction.run { [weak self] in
            // Fade out pad VFX with the chopper.
            self?.childNode(withName: "heliPadVFX")?
                .run(SKAction.sequence([
                    SKAction.fadeOut(withDuration: 0.5),
                    SKAction.removeFromParent()
                ]))
            CombatFlowController.completeExtractionFinalize()
        }

        let sequence = SKAction.sequence([
            descend,
            touchdown,
            onLanded,
            waitOnPad,
            spinUp,
            spinPause,
            liftOffPhase,
            liftOff,
            ascendPhase,
            ascend,
            depart,
            onComplete,
            SKAction.removeFromParent()
        ])
        heli.run(sequence, withKey: "heliSequence")

        // Belt-and-suspenders: a dispatched timer that fires the same
        // finalize as a safety net.
        // 2026-05-10: 10s → 13s. After waitOnPad bumped to 2.2s,
        // animation grew to ~9.8s.
        // 2026-05-14: 13s → 14s. Smoother descent (2.5→3.0s), touchdown
        // (0.4→0.6s) and ascend (2.5→3.0s) pushed the full sequence to
        // ~11s — keep ~3s of safety-net lead.
        // 2026-05-18: 14s → 17s. Slower + smoother heli per playtest:
        // descent 3.0→4.0, liftOff 1.0→1.4, ascend 3.0→4.0. Total ~13.4s.
        // Attempt token: this net had NO guard at all — after an abort (or
        // just tapping through debrief into the next mission within ~3.6s)
        // it would finalize an extraction win against the NEW mission.
        let attempt = GameState.shared.missionAttemptId
        DispatchQueue.main.asyncAfter(deadline: .now() + 17.0) { [weak self] in
            guard GameState.shared.missionAttemptId == attempt else { return }
            CombatFlowController.completeExtractionFinalize()
            self?.playerInputLocked = false
            self?.childNode(withName: "extractionHelicopter")?.removeFromParent()
            self?.childNode(withName: "heliPadVFX")?.removeFromParent()
        }
    }

    /// Door extraction: runners walk to the extraction tile and fade out as
    /// they walk through (e.g. M5 mech bay freight elevator). No helicopter.
    /// Rooftop helicopter extraction (M4 "Dead Man's Switch"). The chopper
    /// is already parked on the helipad (placed by
    /// `addStationaryExtractionHelicopter`). This sequence skips the
    /// dramatic flying-in descent the user called "dumb-looking" and just
    /// has the runners walk to the heli + the parked heli take off.
    ///
    /// Flow:
    ///   1. Each runner walks to the extraction tile and fades out (boarding)
    ///   2. Quick rotor SFX kick + dust burst
    ///   3. Stationary heli ascends + drifts off-screen
    ///   4. Finalize extraction
    private func playRooftopHeliExtraction(extractionX: Int, extractionY: Int) {
        playerInputLocked = true
        let center = TileMap.tileCenter(x: extractionX, y: extractionY)
        let mapNode = childNode(withName: "TileMap") ?? self
        let originX = mapNode.position.x + center.x
        let originY = mapNode.position.y + center.y

        // 1. Walk + fade the runners (staggered, like the door pattern).
        var staggerDelay: TimeInterval = 0
        let livingCount = max(1, characterNodes.count)
        let staggerPerChar: TimeInterval = 0.45
        for (_, node) in characterNodes {
            let board = SKAction.sequence([
                SKAction.wait(forDuration: staggerDelay),
                SKAction.move(to: CGPoint(x: originX, y: originY), duration: 0.6),
                SKAction.fadeOut(withDuration: 0.4)
            ])
            node.run(board)
            staggerDelay += staggerPerChar
        }

        // Total board time: stagger * count + final fade.
        let boardEnd = TimeInterval(livingCount) * staggerPerChar + 0.4

        // 2. After everyone's aboard, spin up + take off the parked heli.
        run(SKAction.sequence([
            SKAction.wait(forDuration: boardEnd + 0.2),
            SKAction.run { [weak self] in
                guard let self = self else { return }
                guard let heli = self.childNode(withName: "stationaryHeli") as? SKSpriteNode else {
                    // Heli not placed (e.g. asset missing) — finalize anyway.
                    return
                }
                heli.alpha = 1.0   // un-fade from the 0.92 idle state
                heli.zPosition = 1100   // keep above the character layer (consistent with placement)
                // Rotor spin-up SFX bed.
                SFXManager.shared.playLoop("extraction_chopper", volume: 0.55)
                // Brief dust burst beneath the heli.
                if let burst = VFXManager.shared.makeBurstNode(effect: .dust, totalDuration: 0.7) {
                    burst.position = heli.position
                    burst.zPosition = 6
                    self.addChild(burst)
                }
                // Cycle the heli's idle frames so the rotor reads as spinning
                // while it lifts (the body-texture-cycle animates baked-in
                // rotor blades). If frames are missing, the body just stays
                // on its single texture — still acceptable.
                let frames = (0..<3).compactMap { self.loadHeliTexture("ascending_\($0)") }
                if frames.count >= 2 {
                    heli.run(SKAction.repeatForever(
                        SKAction.animate(with: frames, timePerFrame: 0.10,
                                         resize: false, restore: false)))
                }
                // Liftoff: small bob up first, then ascend + scale down + drift.
                let bob = SKAction.sequence([
                    SKAction.moveBy(x: 0, y: -2, duration: 0.18),
                    SKAction.moveBy(x: 0, y: 2, duration: 0.18)
                ])
                bob.timingMode = .easeInEaseOut
                let skyOffset: CGFloat = self.size.height * 0.65 + 200
                let ascend = SKAction.group([
                    SKAction.moveBy(x: 60, y: skyOffset, duration: 3.5),
                    SKAction.scale(to: 0.55, duration: 3.5),
                    SKAction.fadeAlpha(to: 0.0, duration: 3.5)
                ])
                ascend.timingMode = .easeIn
                heli.run(SKAction.sequence([
                    bob,
                    SKAction.wait(forDuration: 0.4),
                    ascend,
                    SKAction.run {
                        SFXManager.shared.stopLoop("extraction_chopper")
                    },
                    SKAction.removeFromParent()
                ]))
            }
        ]))

        // 3. Finalize once the heli has cleared the screen. Total budget:
        //    boardEnd + 0.2 (spin-up wait) + 0.36 (bob) + 0.4 (pause) + 3.5
        //    (ascend) ≈ boardEnd + 4.5. Add 0.5s buffer.
        let totalDuration = boardEnd + 5.0
        run(SKAction.sequence([
            SKAction.wait(forDuration: totalDuration),
            SKAction.run { [weak self] in
                guard let self = self else { return }
                _ = GameState.shared.requestExtractionSequenceCompleted()
                self.playerInputLocked = false
            }
        ]))
    }

    private func playDoorExtractionAnimation(extractionX: Int, extractionY: Int) {
        playerInputLocked = true
        let center = TileMap.tileCenter(x: extractionX, y: extractionY)
        let mapNode = childNode(withName: "TileMap") ?? self
        let originX = mapNode.position.x + center.x
        let originY = mapNode.position.y + center.y

        var staggerDelay: TimeInterval = 0
        let livingCount = max(1, characterNodes.count)
        let staggerPerChar: TimeInterval = 1.0
        for (_, node) in characterNodes {
            let exit = SKAction.sequence([
                SKAction.wait(forDuration: staggerDelay),
                SKAction.move(to: CGPoint(x: originX, y: originY), duration: 0.7),
                SKAction.fadeOut(withDuration: 0.5)
            ])
            node.run(exit)
            staggerDelay += staggerPerChar
        }

        let totalDuration = TimeInterval(livingCount) * staggerPerChar + 0.5
        run(SKAction.sequence([
            SKAction.wait(forDuration: totalDuration),
            SKAction.run { [weak self] in
                guard let self = self else { return }
                _ = GameState.shared.requestExtractionSequenceCompleted()
                self.playerInputLocked = false
            }
        ]))
    }

    /// Ladder / climb-out extraction: characters climb out of the room
    /// (e.g. M3 ritual chamber's roof access skylight). No helicopter.
    /// Called from playExtractionAnimation when extractionType == "ladder".
    private func playLadderExtractionAnimation(extractionX: Int, extractionY: Int) {
        playerInputLocked = true
        // Each runner moves UP toward the extraction tile, then fades out
        // as if climbing through the ceiling.
        let center = TileMap.tileCenter(x: extractionX, y: extractionY)
        let mapNode = childNode(withName: "TileMap") ?? self
        let originX = mapNode.position.x + center.x
        let originY = mapNode.position.y + center.y

        // Stagger each character so they appear to climb one-by-one
        var staggerDelay: TimeInterval = 0
        let livingCount = max(1, characterNodes.count)
        let staggerPerChar: TimeInterval = 1.6
        for (_, node) in characterNodes {
            let climb = SKAction.sequence([
                SKAction.wait(forDuration: staggerDelay),
                SKAction.group([
                    // drift toward the extraction tile
                    SKAction.move(to: CGPoint(x: originX, y: originY), duration: 0.8),
                    SKAction.fadeAlpha(to: 0.85, duration: 0.8)
                ]),
                // climb upward off-screen as they go through the roof
                SKAction.group([
                    SKAction.moveBy(x: 0, y: 280, duration: 1.4),
                    SKAction.scale(by: 0.5, duration: 1.4),
                    SKAction.fadeOut(withDuration: 1.4)
                ])
            ])
            node.run(climb)
            staggerDelay += staggerPerChar
        }

        // Total duration: (livingCount × stagger) + final climb 1.4
        let totalDuration = TimeInterval(livingCount) * staggerPerChar + 1.4 + 0.5
        let finalize = SKAction.sequence([
            SKAction.wait(forDuration: totalDuration),
            SKAction.run { [weak self] in
                guard let self = self else { return }
                _ = GameState.shared.requestExtractionSequenceCompleted()
                self.playerInputLocked = false
            }
        ])
        run(finalize)
    }

    /// Load the Zero State studio sigil that's overlaid on the room
    /// transition card. The mark lives in the asset catalog (it's used
    /// elsewhere via SwiftUI `Image("zero_state_mark_4")`); SpriteKit
    /// needs a UIImage→SKTexture hop to render it. Returns nil if the
    /// asset isn't shipped — the transition still works without the
    /// seal (the room name + rule remain).
    private func roomTransitionSigilTexture() -> SKTexture? {
        guard let img = UIImage(named: "zero_state_mark_4") else { return nil }
        let tex = SKTexture(image: img)
        tex.filteringMode = .linear
        return tex
    }

    private func loadHeliTexture(_ name: String) -> SKTexture? {
        // Try Sprites/effects/helicopter/<name>.png
        if let resourcePath = Bundle.main.resourcePath {
            let path = resourcePath + "/Sprites/effects/helicopter/" + name + ".png"
            if let img = UIImage(contentsOfFile: path) {
                return SKTexture(image: img)
            }
        }
        // Dev fallback via #file
        let url = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sprites")
            .appendingPathComponent("effects")
            .appendingPathComponent("helicopter")
            .appendingPathComponent("\(name).png")
        if let img = UIImage(contentsOfFile: url.path) {
            return SKTexture(image: img)
        }
        return nil
    }

    /// Visually mark wall tiles that just retracted (barrier-drop on first
    /// kill). The pathfinding side has already mutated `currentMissionTiles`,
    /// so we:
    /// (a) delete the procedural wall SKNode,
    /// (b) clone a chunk of the room's BACKGROUND TEXTURE from a clean-floor
    ///     reference tile and stamp it over the barrier tile so the painted
    ///     barrier art is occluded with matching floor pixels (no flat-color
    ///     "patch" — actual sampled floor), and
    /// (c) fire a brief amber spark to sell the "barrier disengaged" beat.
    /// Redraw for destroyed COVER tiles (detonated barrels, splintered
    /// crates): fade the tile node (kills the ☣ badge/outline), stamp a
    /// scorch scar over the BG-painted prop art. See the .coverTileDestroyed
    /// observer for why this doesn't reuse dropBarrierTiles' BG sampling.
    private func stampScorchedFloor(coords: [[String: Int]]) {
        guard let mapNode = childNode(withName: "TileMap") else { return }
        for c in coords {
            guard let x = c["x"], let y = c["y"] else { continue }
            mapNode.childNode(withName: "tile_\(x)_\(y)")?.run(SKAction.sequence([
                SKAction.fadeOut(withDuration: 0.3),
                SKAction.removeFromParent()
            ]))
            addScorchPatch(to: mapNode, x: x, y: y, animated: true)
        }
    }

    /// Charred-floor overlay for a destroyed cover tile. Hex-shaped so it
    /// clips exactly to the tile — no background sampling, so it can never
    /// grab the wrong pixels. Deterministic debris flecks (hashed off the
    /// coords) sell "rubble" without RNG that would shift between visits.
    private func addScorchPatch(to mapNode: SKNode, x: Int, y: Int, animated: Bool) {
        let nodeName = "scorchPatch_\(x)_\(y)"
        guard mapNode.childNode(withName: nodeName) == nil else { return }
        let group = SKNode()
        group.name = nodeName
        group.position = TileMap.tileCenter(x: x, y: y)
        group.zPosition = -29   // just above the room BG (-30), below tile outlines

        let hex = SKShapeNode(path: TileMap.hexPath(radius: TileMap.hexRadius * 0.94))
        hex.fillColor = UIColor.black.withAlphaComponent(0.55)
        hex.strokeColor = UIColor.black.withAlphaComponent(0.75)
        hex.lineWidth = 1.5
        group.addChild(hex)

        let soot = SKShapeNode(circleOfRadius: TileMap.hexRadius * 0.42)
        soot.fillColor = UIColor.black.withAlphaComponent(0.5)
        soot.strokeColor = .clear
        soot.glowWidth = 5
        group.addChild(soot)

        for i in 0..<4 {
            let h = (x &* 31 &+ y &* 17 &+ i &* 7) % 100
            let angle = CGFloat(h) / 100.0 * 2 * .pi
            let dist = TileMap.hexRadius * (0.25 + 0.35 * CGFloat((h * 13) % 10) / 10.0)
            let fleck = SKShapeNode(circleOfRadius: 1.6)
            fleck.fillColor = UIColor(white: 0.35, alpha: 0.8)
            fleck.strokeColor = .clear
            fleck.position = CGPoint(x: cos(angle) * dist, y: sin(angle) * dist * 0.6)
            group.addChild(fleck)
        }

        if animated {
            group.alpha = 0
            group.run(SKAction.fadeIn(withDuration: 0.35))
        }
        mapNode.addChild(group)
    }

    /// Re-apply the background floor patches for barriers this room already
    /// dropped, so a re-entered room doesn't show its retracted wall again.
    private func replayDroppedBarrierPatches(for room: Room) {
        guard RoomManager.shared.barrierDroppedRoomIds.contains(room.id),
              let drops = room.removeOnFirstKill, !drops.isEmpty else { return }
        dropBarrierTiles(coords: drops.map { ["x": $0.x, "y": $0.y] }, animated: false)
    }

    /// `animated: false` replays the patch silently on room re-entry — the
    /// barrier already dropped in an earlier visit, so it must look gone the
    /// instant the room appears, with no fade or spark to re-sell the moment.
    private func dropBarrierTiles(coords: [[String: Int]], animated: Bool = true) {
        guard let mapNode = childNode(withName: "TileMap") else { return }
        let bg = childNode(withName: "roomBackground") as? SKSpriteNode
        let bgTex = bg?.texture
        let bgSize = bg?.size ?? .zero

        for c in coords {
            guard let x = c["x"], let y = c["y"] else { continue }
            // Fade + remove the wall sprite so pathfinding visualisation matches.
            if animated {
                mapNode.childNode(withName: "tile_\(x)_\(y)")?.run(SKAction.sequence([
                    SKAction.fadeOut(withDuration: 0.35),
                    SKAction.removeFromParent()
                ]))
            } else {
                mapNode.childNode(withName: "tile_\(x)_\(y)")?.removeFromParent()
            }

            let center = TileMap.tileCenter(x: x, y: y)

            // ── Floor patch from real BG pixels ──────────────────────────
            // Sample a tile-sized rectangle from the room background image,
            // taken from a clean-floor offset (3 rows below the barrier; if
            // that's off the map, 3 rows above). The crop is rendered as an
            // SKSpriteNode on top of the barrier tile so the painted-in
            // barrier art is occluded with floor pixels that match the rest
            // of the room. Falls through to a no-op if the BG texture isn't
            // available — the wall sprite is already gone, so worst case
            // the player sees the BG-painted barrier with no overlay.
            if let bgTex = bgTex,
               let bg = bg,
               bgSize.width > 0, bgSize.height > 0 {

                // Pick a clean-floor SOURCE tile. Try +3 rows down first,
                // fall back to -3 rows up. Both are heuristic: M1's barrier
                // is roughly mid-map, so either side has open floor.
                // Source tile to copy clean floor from. KEEP the original +3/-3
                // heuristic — when that lands on real floor (e.g. the M1 barrier,
                // which already works), this is unchanged. ONLY when +3 lands on
                // a non-floor tile (the M5 mech bay, where it hit the extraction
                // pad / wall and produced a garbled patch) do we scan outward for
                // a genuine .floor tile to sample instead.
                let grid = GameState.shared.currentMissionTiles
                func isFloorTile(_ sx: Int, _ sy: Int) -> Bool {
                    guard sy >= 0, sy < grid.count, sx >= 0, sx < grid[sy].count else { return false }
                    return grid[sy][sx] == TileType.floor.rawValue
                }
                var srcX = x
                var srcY = (y + 3 < (tileMap?.mapHeight ?? 0)) ? y + 3 : max(0, y - 3)
                if !isFloorTile(srcX, srcY) {
                    searchFloor: for dist in 2...6 {
                        for (dx, dy) in [(0, dist), (0, -dist), (-1, dist), (1, dist), (-1, -dist), (1, -dist)] {
                            if isFloorTile(x + dx, y + dy) { srcX = x + dx; srcY = y + dy; break searchFloor }
                        }
                    }
                }
                let sourceCenter = TileMap.tileCenter(x: srcX, y: srcY)

                // Convert tile centers to BG-local coordinates. The bg sprite
                // has anchor (0,0), positioned at mapOrigin, so a scene point
                // (sx, sy) maps to bg-local (sx - mapOrigin.x, sy - mapOrigin.y).
                // Tile centers are returned WITHOUT mapOrigin offset (they're
                // local to the tilemap), so we use them directly here.
                let patchSize = CGSize(width: TileMap.hexRadius * 2.3,
                                       height: TileMap.hexRadius * 2.0)

                // Normalised SKTexture rect (origin bottom-left, 0..1).
                // Add a tiny inset so we don't pick up the next tile's edge.
                let cropX = (sourceCenter.x - patchSize.width / 2) / bgSize.width
                let cropYRaw = (sourceCenter.y - patchSize.height / 2) / bgSize.height
                let cropW = patchSize.width  / bgSize.width
                let cropH = patchSize.height / bgSize.height

                // Clamp into [0,1] so we never request out-of-range pixels.
                let cx = max(0, min(1 - cropW, cropX))
                let cy = max(0, min(1 - cropH, cropYRaw))
                let normRect = CGRect(x: cx, y: cy, width: cropW, height: cropH)

                let cropTex = SKTexture(rect: normRect, in: bgTex)
                let patch = SKSpriteNode(texture: cropTex, size: patchSize)
                patch.position = CGPoint(x: center.x, y: center.y)
                patch.alpha = 0
                patch.zPosition = -29   // just above the bg (-30), below tile outlines (>=0)
                patch.name = "barrierPatch_\(x)_\(y)"

                // The patch is added to mapNode so it scrolls with the map.
                mapNode.addChild(patch)
                _ = bg  // keep ref-warm in case future code wants it
                if animated {
                    patch.run(SKAction.fadeIn(withDuration: 0.4))
                } else {
                    patch.alpha = 1
                }
            }

            // The spark sells the drop as it happens; on a silent replay the
            // barrier fell minutes ago, so skip straight past it.
            guard animated else { continue }

            // Brief amber spark at the tile to sell "barrier disengaged".
            let spark = SKShapeNode(circleOfRadius: 4)
            spark.fillColor = UIColor(hex: "#FFAA00")
            spark.strokeColor = .clear
            spark.glowWidth = 6
            spark.position = center
            spark.zPosition = 6
            spark.alpha = 0.85
            mapNode.addChild(spark)
            spark.run(SKAction.sequence([
                SKAction.group([
                    SKAction.scale(to: 2.5, duration: 0.4),
                    SKAction.fadeOut(withDuration: 0.4)
                ]),
                SKAction.removeFromParent()
            ]))
        }
    }

    /// Handle LEFT/RIGHT arrow tap from CombatUI — navigate to adjacent room without a door.
    private func handleRoomNavigationArrow(direction: String) {
        GameState.shared.addLog("Use the marked door tile to move between rooms.")
    }

    private func handleRoomTransitionCompleted() {
        guard let targetRoom = RoomManager.shared.pendingRoomTransition else { return }
        // Defensive guard: if a transition fires for the room we're already
        // in, treat it as a no-op. Without this, a spurious re-fire would
        // wipe `GameState.shared.enemies` (line below sets it from the
        // targetRoom spec) — which is the exact symptom of "no enemies in
        // range" mid-fight even though enemies are visible on screen.
        let currentId = GameState.shared.currentRoomId
        if !currentId.isEmpty,
           currentId == targetRoom.id,
           !GameState.shared.enemies.isEmpty {
            dlog("[BattleScene] ⚠️ duplicate transition to current room \(currentId) — ignoring (would have wiped \(GameState.shared.enemies.count) enemies)")
            GameState.shared.addLog("⚠ stray room transition ignored (room=\(currentId))")
            // Still clear the pending flags so we don't loop forever.
            RoomManager.shared.completeTransition(to: targetRoom)
            return
        }
        // Belt-and-suspenders reset of per-room first-kill state at the
        // earliest point of the transition, in case loadRoom's later reset is
        // shadowed by any state leak through async paths.
        GameState.shared.resetFirstKillTracking()

        // Determine spawn position for this transition. Per playtest spec
        // 2026-05-23: spawn must always reflect which DOOR the party came
        // through — never default back to the room's original spawn just
        // because the room was previously entered.
        //
        // - Any door-driven transition (first OR back nav): use the
        //   connection's targetSpawn — that IS the tile next to the door
        //   you walked through.
        // - Arrow navigation (no connection context): fall back to the
        //   room's playerSpawn.
        //
        // Previous behavior put back-nav at room.playerSpawn, which read
        // as "always re-enter from the top of the room" regardless of
        // which door you used — exactly the bug the playtest flagged.
        let spawnX: Int
        let spawnY: Int
        let isBackNavigation = RoomManager.shared.isRoomEntered(targetRoom.id)
        if let connX = RoomManager.shared.pendingConnectionTargetX,
           let connY = RoomManager.shared.pendingConnectionTargetY {
            let resolved = validatedSpawnX(in: targetRoom, proposedX: connX, proposedY: connY)
            spawnX = resolved.x
            spawnY = resolved.y
            dlog("[BattleScene] room transition (\(isBackNavigation ? "back-nav-via-door" : "first-entry")) target=\(targetRoom.id) requestedSpawn=(\(connX),\(connY)) resolvedSpawn=(\(spawnX),\(spawnY)) tile=\(targetRoom.map[spawnY][spawnX])")
        } else {
            // No connection context — pure arrow nav. Fall back to room's
            // playerSpawn.
            spawnX = targetRoom.playerSpawn.x
            spawnY = targetRoom.playerSpawn.y
            dlog("[BattleScene] room transition (arrow) target=\(targetRoom.id) using room.playerSpawn=(\(spawnX),\(spawnY))")
        }

        // NOTE: player positions are assigned AFTER the enemy list is built
        // (below) so the squad layout can avoid enemy-occupied tiles —
        // otherwise a runner could spawn on an enemy's hex (Raze-on-enemy).

        // Mark room as entered (for future back-navigation)
        RoomManager.shared.markRoomEntered(targetRoom.id)
        // Visit index seeds the backtrack-patrol roll below.
        RoomManager.shared.noteRoomEntry(targetRoom.id)

        // Replace GameState enemies with this room's enemies only.
        // Cleared rooms stay empty on return; uncleared rooms rebuild from
        // JSON. (A prior "snapshot survivors on exit, restore on re-entry"
        // system was removed 2026-06-12 — it kept storing an empty snapshot
        // under the wrong room key and spawning rooms with zero enemies, a
        // hard softlock. The minor re-kill-XP exploit it guarded against —
        // reachable only by deliberately backtracking out of an uncleared
        // room — is not worth a softlock risk.)
        var newEnemies: [Enemy] = []
        var newPendingSpawns: [GameState.PendingSpawn] = []
        if !RoomManager.shared.isRoomCleared(targetRoom.id) {
            // Replay/gauntlet squad reroll — same budget-matched swap the
            // opening room gets in setupMultiRoomMission. Seeded per
            // (attempt, room), so backtracking and re-entering this room
            // rebuilds the identical squad.
            for enemySpawn in MissionSetupService.replaySquad(for: targetRoom, gameState: GameState.shared) {
            let enemy: Enemy
            switch enemySpawn.type {
            case "guard":   enemy = Enemy.corpGuard()
            case "drone":   enemy = Enemy.securityDrone()
            case "elite":   enemy = Enemy.eliteGuard()
            case "mage":    enemy = Enemy.corpMage()
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
            // Boss archetypes — parity with MissionSetupService.makeEnemy so a
            // room-transition spawn list naming a boss doesn't silently fall to
            // a corp guard.
            case "bossmage": enemy = Enemy.bossMage()
            case "corp", "bosscorp", "exec": enemy = Enemy.bossCorp()
            default:        enemy = Enemy.corpGuard()
            }
            NGPlusStore.shared.scaleForTier(enemy)   // New Game+ durability scaling
            enemy.positionX = enemySpawn.x
            enemy.positionY = enemySpawn.y
                if enemySpawn.delay == 0 {
                    newEnemies.append(enemy)
                } else {
                    // BUG FIX 2026-05-10: JSON `delay` is an OFFSET ("N enemy
                    // phases after entering this room"), but
                    // processDelayedSpawns checks against the cumulative
                    // gameState.enemyPhaseCount which keeps ticking up
                    // across rooms. Storing delay raw caused R2's "delay 2"
                    // spawns to be treated as already due when entering R2
                    // late in the mission — they'd fire on the first
                    // enemy phase in R2 (or never appear noticeably,
                    // depending on what the player was doing). Store as
                    // absolute target so the offset semantic is preserved.
                    // (Matches ReinforcementService's pattern at
                    // ReinforcementService.swift:88.)
                    let dueAt = GameState.shared.enemyPhaseCount + enemySpawn.delay
                    newPendingSpawns.append(GameState.PendingSpawn(enemy: enemy, delayRounds: dueAt))
                }
            }
        } else {
            // Cleared room: usually stays empty, but a patrol occasionally
            // wanders in so backtracking carries some risk. Rolls empty most
            // of the time, once per room per attempt — see backtrackPatrol.
            let patrol = MissionSetupService.backtrackPatrol(
                for: targetRoom,
                gameState: GameState.shared,
                entryX: spawnX,
                entryY: spawnY
            )
            if !patrol.isEmpty {
                RoomManager.shared.patrolRespawnedRoomIds.insert(targetRoom.id)
                for spawn in patrol {
                    let enemy = MissionSetupService.makeEnemy(
                        gameState: GameState.shared,
                        for: spawn.type,
                        archetype: .interceptor
                    )
                    NGPlusStore.shared.scaleForTier(enemy)
                    enemy.positionX = spawn.x
                    enemy.positionY = spawn.y
                    newEnemies.append(enemy)
                }
                // Live enemies mean the room is no longer clear — same contract
                // ReinforcementService uses, so doors re-lock until the patrol
                // is put down and onRoomCleared re-marks it.
                _ = RoomManager.shared.unmarkRoomCleared(targetRoom.id)
                GameState.shared.addLog("⚠️ Patrol contact — this room isn't as clear as you left it.")
            }
        }
        // WP4 seam: the scene CONSTRUCTS the room's authored spawn lists
        // above; every gameplay mutation (squad placement, NG+ extras,
        // roster swap, room bookkeeping, extraction objective, live tile
        // map) happens inside authority. Render from GameState after this.
        GameState.shared.applyRoomEntry(
            to: targetRoom,
            enemies: newEnemies,
            pendingSpawns: newPendingSpawns,
            spawnAnchor: spawnX >= 0 ? SpawnPoint(x: spawnX, y: spawnY) : nil)

        // Clear stale door-open state from previous room
        openedDoorKeys.removeAll()

        // Reset combat state for the new room
        CombatFlowController.resetTurnTracking(gameState: GameState.shared)
        CombatFlowController.restorePlayerControlAfterEnemyPhase(gameState: GameState.shared)

        // Reload the room with living characters only; downed runners remain in
        // playerTeam for roster/history but are not active room participants.
        // Render the roster the authority actually installed (includes NG+
        // extras appended inside applyRoomEntry) — not the scene's local list.
        loadRoom(targetRoom, characters: GameState.shared.livingPlayers, enemies: GameState.shared.enemies)

        // Start a fresh round in the new room
        GameState.shared.beginRound()

        // Fade back in
        fadeOutFromTransition()

        GameState.shared.addLog("Arrived at: \(targetRoom.title)")

        // Empty boss-room (e.g. the M5 Reactor Floor): with no regular enemies
        // to kill, onRoomCleared would never fire from a death — so the boss
        // would never deploy. Trigger it on ENTRY. onRoomCleared's BOSS PHASE
        // INTERCEPT does the actual spawn + reveal. Guarded to a genuinely
        // empty, uncleared room that defines a bossSpawn.
        if newEnemies.isEmpty,
           newPendingSpawns.isEmpty,
           targetRoom.bossSpawn != nil,
           !RoomManager.shared.isRoomCleared(targetRoom.id),
           !RoomManager.shared.bossDeployedRoomIds.contains(targetRoom.id) {
            GameState.shared.onRoomCleared()
        }
    }

    private func setupEnemyNotifications() {
        observe(.characterLevelUp) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let idStr = userInfo["characterId"] as? String,
                  let id = UUID(uuidString: idStr) else { return }
            self?.playLevelUpEffect(on: id)
        }

        observe(.enemyHit) { [weak self] notification in
            guard let self = self, let userInfo = notification.userInfo,
                  let idStr = userInfo["enemyId"] as? String,
                  let id = UUID(uuidString: idStr) else { return }
            let dmg = userInfo["damage"] as? Int ?? 0
            let outcome = userInfo["outcome"] as? String ?? ""
            let impactDelay = userInfo["impactDelay"] as? Double ?? 0
            let isCrit = userInfo["critical"] as? Bool ?? false
            // #4: lift the struck enemy (and its above-head HP bar) above the
            // front-row sprites for the hit reaction, so the bar that's actually
            // changing is never occluded at the moment it matters.
            if let node = self.characterNodes[id], node.zPosition < 1000 {
                let baseZ = node.zPosition
                node.zPosition += 1200
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak node] in node?.zPosition = baseZ }
            }
            let renderHit = { [weak self] in
                guard let self = self else { return }
                self.playHitEffect(on: id, damage: dmg, outcome: outcome)
                // #3: micro freeze-frame the instant a player CRIT connects.
                if isCrit && dmg > 0 { self.applyHitStop(0.06) }
            }
            // #2: ranged shots delay the spark/number so the tracer lands first.
            if impactDelay > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + impactDelay, execute: renderHit) }
            else { renderHit() }
        }
        observe(.enemyDied) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let idStr = userInfo["enemyId"] as? String,
                  let id = UUID(uuidString: idStr) else { return }
            let impactDelay = userInfo["impactDelay"] as? Double ?? 0
            let playerKill = userInfo["playerKill"] as? Bool ?? false
            // Death visual waits out the bullet-travel beat for ranged kills,
            // then a micro freeze-frame sells a player-paced kill (#2 + #3).
            let renderDeath = { [weak self] in
                self?.playDeathEffect(on: id)
                if playerKill { self?.applyHitStop(0.06) }
            }
            if impactDelay > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + impactDelay, execute: renderDeath) }
            else { renderDeath() }
            // Belt-and-suspenders: ensure once-per-room kill effects (drop
            // `removeOnFirstKill` barriers etc.) fire on EVERY death path,
            // not just the ones routed through performAttack/blitz/spell.
            // The handler is idempotent via `firstKillProcessedInRoom`, so
            // calling it again is a no-op once the flag is set.
            Task { @MainActor in
                CombatFlowController.handleEnemyKillForRoomEffects(gameState: GameState.shared)
                // M3 boss-phase-2 hook: when the corp mage at the altar dies
                // in the Ritual Chamber, his TRUE form (the boss mage)
                // manifests on the same tile. Service is idempotent — only
                // fires once per mission attempt.
                CombatFlowController.checkMageBossPhase2(gameState: GameState.shared,
                                                         deadEnemyId: id)
                // Boss-death music kill — drop the boss track and let the
                // post-combat moment breathe in silence. Applies to every
                // proper boss kill (M5 mech, M6 AGI, M3 bossmage true form).
                if let dead = GameState.shared.enemies.first(where: { $0.id == id }) {
                    let arch = dead.archetype.lowercased()
                    if arch == "bossmech" || arch == "bossagi" || arch == "bossmage" || arch == "bosscorp" {
                        MusicManager.shared.stop()
                        SFXManager.shared.stopAllLoops()
                        let tag: String = {
                            switch arch {
                            case "bossmech": return "[M5] MEKTON-7 down. Silence."
                            case "bossagi":  return "[M6] AGI-PRIME terminated. Silence."
                            case "bossmage": return "[M3] Sato is dead. The wards collapse."
                            case "bosscorp": return "[M4] Vera Koss is down. The rooftop falls quiet."
                            default:         return ""
                            }
                        }()
                        GameState.shared.addLog(tag)
                    }
                    // M3: reveal the grimoire objective the instant Sato's BOSS
                    // form dies. We can't rely on the .roomCleared notification
                    // for this — it's one-shot (markCurrentRoomCleared) and gets
                    // consumed by the LAST GUARD's death, which fires
                    // onRoomCleared() synchronously at the death site BEFORE this
                    // async Task spawns the boss. After the boss finally falls,
                    // onRoomCleared() early-returns (room already marked cleared)
                    // and never re-posts .roomCleared — so the gold-altar
                    // highlight and the "GRAB THE GRIMOIRE" call-to-action were
                    // silently skipped (the playtest "nothing tells you to grab
                    // it" bug). Reveal them directly here. spawnRoomSpecificProps
                    // is gated to M3R2 + boss-dead and is idempotent; the
                    // announce path is one-shot via grimoirePromptShown.
                    if arch == "bossmage" {
                        self?.spawnRoomSpecificProps(roomId: GameState.shared.currentRoomId, announce: true)
                    }
                }
            }
        }
        observe(.enemyMoved) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let idStr = userInfo["enemyId"] as? String,
                  let id = UUID(uuidString: idStr),
                  let newX = userInfo["x"] as? Int,
                  let newY = userInfo["y"] as? Int else { return }
            dlog("[BattleScene] .enemyMoved received — enemyId=\(idStr), to=(\(newX),\(newY))")
            self?.animateEnemyMove(id: id, toX: newX, toY: newY)
        }
        observe(.playerDied) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let idStr = userInfo["playerId"] as? String,
                  let id = UUID(uuidString: idStr) else { return }
            self?.playDeathEffect(on: id)
        }
        observe(.dataTerminalHacked) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let x = userInfo["x"] as? Int,
                  let y = userInfo["y"] as? Int else { return }
            self?.tileMap?.markTerminalHacked(x: x, y: y)
        }
        observe(.enemySpawned) { [weak self] notification in
            guard let self = self else { return }
            guard let userInfo = notification.userInfo,
                  let idStr = userInfo["enemyId"] as? String,
                  let id = UUID(uuidString: idStr) else { return }
            Task { @MainActor in
                // Find the newly spawned enemy in GameState and place it on the map
                if let enemy = GameState.shared.enemies.first(where: { $0.id == id }) {
                    self.placeEnemy(enemy)
                    self.playRoundStartEffect()
                    // M6 AGI boss MATERIALIZES — start at alpha 0 and fade
                    // in over 2.5s so it reads as an emergence, not a pop-in.
                    // The audio cascade (arrival_glitch → manifestation →
                    // voice) is timed against this same window.
                    if enemy.archetype == "bossagi", let node = self.characterNodes[id] {
                        node.alpha = 0.0
                        let fadeIn = SKAction.fadeAlpha(to: 1.0, duration: 2.5)
                        fadeIn.timingMode = .easeIn
                        node.run(fadeIn)
                    }
                }
            }
        }
        observe(.roundStarted) { [weak self] _ in
            self?.playRoundStartEffect()
        }

        // MARK: spell + skill visual hooks
        // Each observer hops to @MainActor explicitly — the queue is .main
        // so the closure body already runs on the main thread, but Swift's
        // strict concurrency analysis can't prove that without the Task hop.
        observe(.healEffect) { [weak self] notification in
            let amount = (notification.userInfo?["amount"] as? Int) ?? 0
            guard let idStr = notification.userInfo?["targetId"] as? String,
                  let id = UUID(uuidString: idStr) else { return }
            Task { @MainActor [weak self] in
                guard let self = self, let node = self.characterNodes[id] else { return }
                EffectsManager.shared.emitHeal(at: node.position, in: self, amount: amount)
                // Refresh the target's HP bar / label — the heal mutates
                // currentHP on the Character/Enemy in place but the visual
                // wasn't getting an updateHP call (only damage paths did).
                // So the bar stayed at its pre-heal fill until the next
                // hit. Push the new values to the sprite now.
                if let char = GameState.shared.playerTeam.first(where: { $0.id == id && $0.isAlive }) {
                    SpriteManager.shared.updateHP(
                        on: node,
                        currentHP: char.currentHP, maxHP: char.maxHP,
                        currentStun: char.currentStun, maxStun: char.maxStun,
                        level: char.level, isPlayer: true
                    )
                } else if let enemy = GameState.shared.enemies.first(where: { $0.id == id && $0.isAlive }) {
                    SpriteManager.shared.updateHP(
                        on: node,
                        currentHP: enemy.currentHP, maxHP: enemy.maxHP,
                        currentStun: enemy.currentStun, maxStun: enemy.maxStun
                    )
                }
            }
        }
        observe(.fireballEffect) { [weak self] notification in
            guard let x = notification.userInfo?["x"] as? Int,
                  let y = notification.userInfo?["y"] as? Int else { return }
            let fromX = notification.userInfo?["fromX"] as? Int
            let fromY = notification.userInfo?["fromY"] as? Int
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let thrower: CGPoint? = (fromX != nil && fromY != nil)
                    ? self.tileCenter(fromX!, fromY!) : nil
                EffectsManager.shared.emitFireball(at: self.tileCenter(x, y), from: thrower, in: self)
            }
        }
        observe(.boltEffect) { [weak self] notification in
            guard let fx = notification.userInfo?["fromX"] as? Int,
                  let fy = notification.userInfo?["fromY"] as? Int,
                  let tx = notification.userInfo?["toX"] as? Int,
                  let ty = notification.userInfo?["toY"] as? Int else { return }
            let hex = (notification.userInfo?["color"] as? String) ?? "#AA66FF"
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                EffectsManager.shared.emitMagicBolt(
                    from: self.tileCenter(fx, fy),
                    to:   self.tileCenter(tx, ty),
                    color: UIColor(hex: hex),
                    in: self)
            }
        }
        observe(.shockEffect) { [weak self] notification in
            guard let fx = notification.userInfo?["fromX"] as? Int,
                  let fy = notification.userInfo?["fromY"] as? Int,
                  let tx = notification.userInfo?["toX"] as? Int,
                  let ty = notification.userInfo?["toY"] as? Int else { return }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                EffectsManager.shared.emitShockBolt(
                    from: self.tileCenter(fx, fy),
                    to:   self.tileCenter(tx, ty),
                    in: self)
            }
        }
        observe(.blitzEffect) { [weak self] notification in
            guard let x = notification.userInfo?["x"] as? Int,
                  let y = notification.userInfo?["y"] as? Int else { return }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                EffectsManager.shared.emitSlashArc(at: self.tileCenter(x, y), in: self)
            }
        }
        observe(.intimidateEffect) { [weak self] notification in
            guard let x = notification.userInfo?["x"] as? Int,
                  let y = notification.userInfo?["y"] as? Int else { return }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                EffectsManager.shared.emitIntimidateWave(at: self.tileCenter(x, y), in: self)
            }
        }
        observe(.gunfireEffect) { [weak self] notification in
            guard let fx = notification.userInfo?["fromX"] as? Int,
                  let fy = notification.userInfo?["fromY"] as? Int,
                  let tx = notification.userInfo?["toX"] as? Int,
                  let ty = notification.userInfo?["toY"] as? Int else { return }
            let gunAttackerId = notification.userInfo?["attackerId"] as? String
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // Player attacks carry an attackerId — play their attack pose
                // (enemy attacks animate via the .playerHit observer instead).
                if let aid = gunAttackerId, let id = UUID(uuidString: aid),
                   let node = self.characterNodes[id] as? SpriteNode {
                    SpriteManager.shared.animate(state: .attack, target: node)
                }
                EffectsManager.shared.emitGunfire(
                    from: self.tileCenter(fx, fy),
                    to:   self.tileCenter(tx, ty),
                    in: self,
                    archetype: (notification.userInfo?["enemyArchetype"] as? String) ?? "")
                // VFX burst: muzzle spark + impact spark on hit tile.
                if let muzzle = VFXManager.shared.makeBurstNode(effect: .microSpark, totalDuration: 0.25) {
                    muzzle.position = self.tileCenter(fx, fy)
                    muzzle.zPosition = 95
                    self.addChild(muzzle)
                }
                if let impact = VFXManager.shared.makeBurstNode(effect: .microSpark, totalDuration: 0.3) {
                    impact.position = self.tileCenter(tx, ty)
                    impact.zPosition = 95
                    self.addChild(impact)
                }
            }
        }
        observe(.meleeStrikeEffect) { [weak self] notification in
            guard let x = notification.userInfo?["x"] as? Int,
                  let y = notification.userInfo?["y"] as? Int else { return }
            let meleeAttackerId = notification.userInfo?["attackerId"] as? String
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let aid = meleeAttackerId, let id = UUID(uuidString: aid),
                   let node = self.characterNodes[id] as? SpriteNode {
                    SpriteManager.shared.animate(state: .attack, target: node)
                }
                EffectsManager.shared.emitMeleeStrike(at: self.tileCenter(x, y), in: self)
                // VFX burst: spark on impact tile.
                if let burst = VFXManager.shared.makeBurstNode(effect: .microSpark, totalDuration: 0.3) {
                    burst.position = self.tileCenter(x, y)
                    burst.zPosition = 95
                    self.addChild(burst)
                }
            }
        }
        observe(.objectivePulseRequested) { [weak self] notification in
            guard let tx = notification.userInfo?["tileX"] as? Int,
                  let ty = notification.userInfo?["tileY"] as? Int,
                  let kind = notification.userInfo?["kind"] as? Int else { return }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // Cyan for data terminals, green for extraction — reads at a
                // glance which objective the runner just stepped on.
                let color: UIColor = (kind == TileType.extraction.rawValue)
                    ? UIColor(hex: "#00FF88")
                    : UIColor(hex: "#00FFCC")
                EffectsManager.shared.emitObjectivePulse(
                    at: self.tileCenter(tx, ty), in: self, color: color)
            }
        }
        observe(.hackEffect) { [weak self] notification in
            guard let fx = notification.userInfo?["fromX"] as? Int,
                  let fy = notification.userInfo?["fromY"] as? Int,
                  let tx = notification.userInfo?["toX"] as? Int,
                  let ty = notification.userInfo?["toY"] as? Int else { return }
            let targetIdStr = notification.userInfo?["targetId"] as? String
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // Stream of binary glyphs from decker → target.
                EffectsManager.shared.emitHack(
                    from: self.tileCenter(fx, fy),
                    to:   self.tileCenter(tx, ty),
                    in: self)
                // 0.4s cyan glitch flash + scan-line ON the hacked enemy
                // sprite. Layered with the stream so both play together.
                if let idStr = targetIdStr,
                   let id = UUID(uuidString: idStr),
                   let node = self.characterNodes[id] {
                    EffectsManager.shared.emitHackGlitch(on: node)
                }
            }
        }
        observe(.characterDefend) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let idStr = userInfo["characterId"] as? String,
                  let id = UUID(uuidString: idStr) else { return }
            self?.playDefendEffect(on: id)
            // Re-focus camera on the defending character
            self?.focusCamera(on: id)
        }
        observe(.characterOverwatch) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let idStr = userInfo["characterId"] as? String,
                  let id = UUID(uuidString: idStr) else { return }
            self?.showOverwatchMarker(on: id)
            self?.focusCamera(on: id)
        }
        observe(.overwatchExpired) { [weak self] notification in
            // With a characterId this is a single consumed shot; without, the
            // round-start sweep that clears everyone.
            if let idStr = notification.userInfo?["characterId"] as? String,
               let id = UUID(uuidString: idStr) {
                self?.characterNodes[id]?.childNode(withName: "overwatchMarker")?.removeFromParent()
            } else {
                self?.clearOverwatchMarkers()
            }
        }
        observe(.turnChanged) { [weak self] notification in
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
        observe(.characterSelected) { [weak self] notification in
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
        observe(.playerHit) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let idStr = userInfo["playerId"] as? String,
                  let id = UUID(uuidString: idStr) else { return }
            let dmg = userInfo["damage"] as? Int ?? 0
            let enemyIdStr = userInfo["enemyId"] as? String
            dlog("[BattleScene] .playerHit received — playerId=\(idStr), damage=\(dmg)")
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
        observe(.enemyPhaseCompleted) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.playerInputLocked = false
                self.isEnemyPhaseRunning = false
                // Render layer is projection-only; combat flow owns progression state restoration.
                CombatFlowController.restorePlayerControlAfterEnemyPhase(gameState: GameState.shared)
                self.fadeOutEnemyPhaseTint()
                dlog("[BattleScene] .enemyPhaseCompleted received — player input unlocked")
            }
        }
        // Enemy-phase red tint: fade in on enemy phase start
        observe(.enemyPhaseBegan) { [weak self] _ in
            self?.fadeInEnemyPhaseTint()
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Swallow taps during a room transition (the black fade screen) —
        // otherwise a tap selects a runner and the +1000 selection z-bump
        // popped that sprite on top of the fade overlay.
        if RoomManager.shared.isTransitioning {
            return
        }
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
        dlog("[BattleScene] touchesBegan scene=(\(sceneLocation.x),\(sceneLocation.y)) mapOrigin=(\(mapOrigin.x),\(mapOrigin.y)) colOffset=\(colYOffset) → clamped=(\(clampedX),\(clampedY))")

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
        let ring = SKShapeNode(path: TileMap.hexPath(radius: TileMap.hexRadius * 0.74))
        ring.name = "activeTurnRing"
        ring.strokeColor = UIColor(hex: "#00D8FF")
        ring.lineWidth = 3.5
        ring.glowWidth = 8
        ring.fillColor = UIColor(hex: "#00D8FF").withAlphaComponent(0.08)
        ring.position = CGPoint(x: 0, y: -3)
        ring.zPosition = 13
        activeNode.addChild(ring)

        ring.run(SKAction.repeatForever(SKAction.sequence([
            SKAction.fadeAlpha(to: 0.50, duration: 0.45),
            SKAction.fadeAlpha(to: 1.00, duration: 0.45)
        ])), withKey: "activePulse")

    }

    private func showSelectionRing(for characterId: UUID) {
        // Deselect previous and clear highlights
        if let prev = selectedCharacterNode {
            SpriteManager.shared.deselect(target: prev)
            // Restore depth-by-tileY on the formerly-selected sprite so it
            // sinks back into normal layering. Without this, the +1000
            // bump from a previous selection lingered.
            if let prevSprite = prev as? SpriteNode {
                prevSprite.zPosition = playerDepthZ(forSprite: prevSprite)
            }
        }
        clearHighlights()

        // Select new
        if let node = characterNodes[characterId] {
            SpriteManager.shared.animateSelect(target: node)
            selectedCharacterNode = node
            // Z-bump so the active runner ALWAYS renders foreground —
            // this is the path the game actually takes (turn-change /
            // characterSelected notifications), not BattleScene.selectCharacter,
            // so the z-bump must happen here too.
            if let sprite = node as? SpriteNode {
                sprite.zPosition = playerDepthZ(forSprite: sprite) + 1000
            }
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

        // Drive the active-turn hex off the SAME id as the selection ring.
        // It used to re-read GameState.activeCharacter here, but callers
        // (tap → showSelectionRing THEN requestCharacterSelectionFromScene)
        // update that id AFTER this runs — so the hex lagged one selection
        // behind the ring ("select twice to move the hex", and the ring/hex
        // landing on different runners after a room transition).
        refreshActiveUnitHighlight(activeId: characterId)
    }

    private var highlightNodes: [SKNode] = []

    private func clearHighlights() {
        for n in highlightNodes { n.removeFromParent() }
        highlightNodes = []
    }

    private weak var selectedEnemyCueNode: SKNode?
    /// Enemy node currently bumped to +1000 by showTargetRing. Kept so we
    /// can restore its natural depthZ when the target changes — otherwise
    /// the +1000 bump would linger on the previously-targeted enemy and it
    /// would keep occluding the foreground.
    private weak var selectedEnemyNode: SKNode?

    /// Target selection strengthens the enemy's base glow without adding
    /// overhead markers or crosshairs. ALSO bumps the targeted enemy's
    /// zPosition by +1000 so the selected sprite always wins — matches the
    /// player-selection +1000 path. Previous target's z is restored to its
    /// natural depthZ first so we never strand a bump on a stale node.
    func showTargetRing(for enemyId: UUID) {
        selectedEnemyCueNode?.removeFromParent()
        selectedEnemyCueNode = nil

        // Restore previously-targeted enemy to its natural depth before
        // applying the new target's bump.
        if let prev = selectedEnemyNode as? SpriteNode {
            prev.zPosition = depthZ(forTileY: prev.tileY, isEnemy: true)
        }
        selectedEnemyNode = nil

        guard let node = characterNodes[enemyId] else { return }

        let enemy = GameState.shared.enemies.first { $0.id == enemyId }
        let isBoss = enemy.map { $0.archetype == "bossmech" || $0.archetype == "bossagi" || $0.archetype == "bosscorp" || $0.archetype == "bossmage" } ?? false

        let cue = SKShapeNode(path: TileMap.hexPath(radius: isBoss ? 38 : (TileMap.hexRadius - 3)))
        cue.name = "enemySelectedCue"
        cue.fillColor = UIColor(hex: "#FF2438").withAlphaComponent(0.16)
        cue.strokeColor = UIColor(hex: "#FF6A6A").withAlphaComponent(0.95)
        cue.lineWidth = 2.2
        cue.glowWidth = 7.0
        cue.position = CGPoint(x: 0, y: 0)   // tile center — matches enemyBaseGlow (was y:-8, read as offset)
        cue.zPosition = 0.75

        node.addChild(cue)
        cue.run(SKAction.repeatForever(SKAction.sequence([
            SKAction.fadeAlpha(to: 0.45, duration: 0.45),
            SKAction.fadeAlpha(to: 1.0, duration: 0.45)
        ])), withKey: "selectedEnemyPulse")
        selectedEnemyCueNode = cue

        // Z-bump the targeted enemy so it always renders on top of any
        // sprite it visually overlaps — including in-front players. Mirrors
        // the player-selection bump in showSelectionRing(for:).
        if let sprite = node as? SpriteNode {
            sprite.zPosition = depthZ(forTileY: sprite.tileY, isEnemy: true) + 1000
            selectedEnemyNode = sprite
        }
    }

    /// Drop the +1000 z-bump on the currently targeted enemy. Call this
    /// when the player turn ends or selection clears so the enemy sinks
    /// back into normal depth ordering.
    func hideTargetRing() {
        selectedEnemyCueNode?.removeFromParent()
        selectedEnemyCueNode = nil
        if let prev = selectedEnemyNode as? SpriteNode {
            prev.zPosition = depthZ(forTileY: prev.tileY, isEnemy: true)
        }
        selectedEnemyNode = nil
    }

    private func highlightTiles(aroundX cx: Int, y cy: Int) {
        clearHighlights()

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
    private var bottomHUDInset: CGFloat = 180

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
        // Scale to fit the UNOBSCURED play corridor between top banner and bottom
        // combat panel. The map is allowed to bleed UP behind the top
        // objective banner (where only the small info chip lives), filling
        // more of the screen vertically. Bottom kept tight so the lowest hex
        // row stays visible above the combat panel.
        let visibleWidth = max(1, size.width)
        // Treat the top inset as zero for SCALE purposes — the actual
        // visual obscuring at the top is just the floating "i" / banner chip,
        // not the full 96pt safe-area clearance. Per playtest feedback the
        // map should bleed UNDER the status bar / Dynamic Island, so the
        // top reservation was pulled from 32 → 16 → 0pt. The combat HUD's
        // proportional weight drops correspondingly.
        let scaleHeight = max(1, size.height - bottomHUDInset)
        // DEVICE SPLIT (2026-07 iPad pass): the phone numbers are a
        // tall-narrow-screen trick — the map deliberately bleeds 36% past
        // the screen edges to fill the display, and the 0.68 zoom-in floor
        // stops sprites ballooning. On iPad those same numbers marooned the
        // ~396pt-wide map at the 0.68 floor in a huge 4:3 view (~40% of the
        // screen, sea of empty backdrop). iPad instead FITS the map to the
        // play corridor (no bleed — the whole board comfortably visible is
        // the tablet payoff) and allows a much deeper zoom-in floor so the
        // fit actually engages; sprite art (200px source frames) stays clean
        // at that magnification.
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let widthFactor: CGFloat  = isPad ? 0.92 : 1.36
        let heightFactor: CGFloat = isPad ? 0.96 : 1.03
        let zoomInFloor: CGFloat  = isPad ? 0.42 : 0.68
        let targetMapScreenWidth = visibleWidth * widthFactor
        let targetMapScreenHeight = scaleHeight * heightFactor
        let requiredScaleX = mapPixelWidth / targetMapScreenWidth
        let requiredScaleY = mapPixelHeight / targetMapScreenHeight
        let scale = max(zoomInFloor, max(requiredScaleX, requiredScaleY))
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

        // Per-mission/room camera nudge — increase shifts content UP in the
        // viewport (bottom of map becomes more visible). M5 r2 had its
        // bottom row clipping into the HUD, needs an extra ~14pt down.
        // Base nudge of 18pt shifts the entire play area up so the top of
        // the map reaches under the status bar / Dynamic Island, giving
        // the bottom HUD less proportional weight on screen.
        let baseUpNudge: CGFloat = 18
        let extraNudge: CGFloat = {
            let mid = GameState.shared.currentMissionDisplayId ?? ""
            let rid = GameState.shared.currentRoomId
            if mid == "Mission005" && rid == "room_2" { return baseUpNudge + 14 }
            // M3R2 was clipping the bottom of map + background. ~5% scoot up.
            if mid == "Mission003" && rid == "room_2" { return baseUpNudge + 22 }
            return baseUpNudge
        }()
        let nextPosition = CGPoint(
            x: clampedCameraCoordinate(
                desired: mapOrigin.x + mapPixelWidth / 2,
                mapStart: mapOrigin.x,
                mapLength: mapPixelWidth,
                visibleLength: visibleSize.width
            ),
            y: clampedCameraCoordinate(
                desired: mapOrigin.y + mapPixelHeight / 2 - verticalBias - firstTurnCameraYOffset - extraNudge,
                mapStart: mapOrigin.y,
                mapLength: mapPixelHeight,
                visibleLength: visibleSize.height
            )
        )
        cam.position = nextPosition
        dlog("[BattleScene] positionCameraOnMap camera=\(nextPosition) topInset=\(topHUDInset) bottomInset=\(bottomHUDInset) bias=\(verticalBias) extraNudge=\(extraNudge)")
    }

    /// Focus camera on a specific tile, clamped so map edges stay within the unobscured viewport.
    func focusCamera(on tileX: Int, y tileY: Int) {
        positionCameraOnMap()
        dlog("[BattleScene] focusCamera locked to board center; requested tile=(\(tileX),\(tileY))")
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

    // MARK: - Load Map

    private func presentationTileMap(for room: Room) -> TileMap {
        var visibleMap = room.map
        // Already-dropped barriers stay dropped visually on re-entry too.
        RoomManager.shared.applyDroppedBarriers(to: &visibleMap, room: room)
        // Cover destroyed mid-combat (detonated barrels / splintered crates)
        // stays destroyed visually on re-entry as well — the room map is
        // rebuilt from JSON here, which would otherwise resurrect the props.
        // (The LOGIC map gets the same re-apply next to each
        // updateTilesForCurrentRoom call — see applyDestroyedCoverToCurrentTiles.)
        if let destroyed = GameState.shared.destroyedCoverByRoom[room.id] {
            for pair in destroyed where pair.count == 2 {
                let dx = pair[0], dy = pair[1]
                guard dy >= 0, dy < visibleMap.count, dx >= 0, dx < visibleMap[dy].count else { continue }
                visibleMap[dy][dx] = TileType.floor.rawValue
            }
        }
        if GameState.shared.dataAcquired {
            for y in visibleMap.indices {
                for x in visibleMap[y].indices where visibleMap[y][x] == TileType.dataTerminal.rawValue {
                    visibleMap[y][x] = TileType.floor.rawValue
                }
            }
        }
        if !RoomManager.shared.isExtractionActive(in: room) {
            for y in visibleMap.indices {
                for x in visibleMap[y].indices where visibleMap[y][x] == TileType.extraction.rawValue {
                    visibleMap[y][x] = TileType.floor.rawValue
                }
            }
        }
        return TileMap(tiles: visibleMap.map { row in row.map { TileType(rawValue: $0) ?? .floor } })
    }

    /// Re-stamp the scorch scars for cover destroyed in a previous visit —
    /// the prop art is painted into the room BACKGROUND image, so without an
    /// overlay a detonated barrel's crate art would visually resurrect on
    /// re-entry even though the tile is walkable floor. Call after the map
    /// node is built and added for a room.
    private func restampScorchScars(on mapNode: SKNode, room: Room) {
        guard let destroyed = GameState.shared.destroyedCoverByRoom[room.id] else { return }
        for pair in destroyed where pair.count == 2 {
            addScorchPatch(to: mapNode, x: pair[0], y: pair[1], animated: false)
        }
    }

    private func refreshObjectiveMarkers() {
        guard let room = RoomManager.shared.currentRoom,
              let mapNode = childNode(withName: "TileMap") else { return }
        mapNode.childNode(withName: "objectiveMarkers")?.removeFromParent()
        addObjectiveMarkers(to: mapNode, room: room)
    }

    private func addObjectiveMarkers(to mapNode: SKNode, room: Room) {
        let markerLayer = SKNode()
        markerLayer.name = "objectiveMarkers"
        markerLayer.zPosition = 18

        let roomCleared = RoomManager.shared.isRoomCleared(room.id)
        for connection in room.connections {
            // Lock state is PER DOOR, not per room. A door leading back to a
            // room you've already been in is always walkable — attemptTransition
            // waives the cleared-room requirement for backtracking. Painting
            // every door with the room-wide `roomCleared` flag drew the door
            // the player had just walked through as LOCKED while they could
            // freely walk back out of it (playtest 2026-07-25, M5R2).
            let unlocked = roomCleared
                || RoomManager.shared.doorIsBacktrack(inRoom: room.id,
                                                      tileX: connection.triggerTileX,
                                                      y: connection.triggerTileY)
            addDoorMarker(
                to: markerLayer,
                x: connection.triggerTileX,
                y: connection.triggerTileY,
                cleared: unlocked
            )
            // The orange door hex only glows once the door is unlocked — hidden
            // during the fight so the room reads clean.
            mapNode.childNode(withName: "tile_\(connection.triggerTileX)_\(connection.triggerTileY)")?
                .childNode(withName: "doorHexPulse")?.isHidden = !unlocked
        }

        if RoomManager.shared.isExtractionActive(in: room) {
            addExtractionMarker(
                to: markerLayer,
                x: GameState.shared.extractionX,
                y: GameState.shared.extractionY
            )
        }

        mapNode.addChild(markerLayer)
    }

    /// Extraction marker: green pill centered on the helipad tile, same look
    /// as the door's UNLOCKED pill. Tappable via existing extraction-tile logic.
    private func addExtractionMarker(to layer: SKNode, x: Int, y: Int) {
        let center = TileMap.tileCenter(x: x, y: y)
        let nodeName = "extractionMarker_\(x)_\(y)"
        layer.childNode(withName: nodeName)?.removeFromParent()

        let group = SKNode()
        group.name = nodeName
        group.position = center
        group.zPosition = 1

        let accent = UIColor(hex: "#00FF88")
        let pillW: CGFloat = 64
        let pillH: CGFloat = 16
        let pill = SKShapeNode(rectOf: CGSize(width: pillW, height: pillH), cornerRadius: 4)
        pill.fillColor = UIColor.black.withAlphaComponent(0.78)
        pill.strokeColor = accent
        pill.lineWidth = 1.4
        pill.glowWidth = 5.0
        pill.position = .zero
        pill.zPosition = 0
        group.addChild(pill)

        let label = SKLabelNode(fontNamed: "Menlo-Bold")
        label.text = "EXTRACTION"
        label.fontSize = 9
        label.fontColor = accent
        label.horizontalAlignmentMode = .center
        label.verticalAlignmentMode = .center
        label.position = .zero
        label.zPosition = 1
        group.addChild(label)

        // Blink the WHOLE marker (pill + label) once extraction is available
        // so it reads as "go now" rather than ambient decor. A sharp on/off
        // alpha swing plus a slight scale pop draws the eye — much more
        // obvious than the old gentle pill-only 0.55↔1.0 fade.
        group.run(SKAction.repeatForever(SKAction.sequence([
            SKAction.group([
                SKAction.fadeAlpha(to: 0.2, duration: 0.4),
                SKAction.scale(to: 0.92, duration: 0.4)
            ]),
            SKAction.group([
                SKAction.fadeAlpha(to: 1.0, duration: 0.4),
                SKAction.scale(to: 1.08, duration: 0.4)
            ]),
            SKAction.scale(to: 1.0, duration: 0.12)
        ])))

        layer.addChild(group)
    }

    /// Door marker: pill-shaped label centered ON the door tile, with the text
    /// "LOCKED" (red) or "UNLOCKED" (green) depending on whether all enemies in
    /// the current room have been defeated. Tappable — handed off to
    /// handleDoorTileTap by the existing tap handler. The marker has a unique
    /// SKNode name per tile so refreshDoorMarkers() can find and rebuild it
    /// without recreating the whole objective layer.
    private func addDoorMarker(to layer: SKNode, x: Int, y: Int, cleared: Bool) {
        let center = TileMap.tileCenter(x: x, y: y)
        let nodeName = "doorMarker_\(x)_\(y)"
        layer.childNode(withName: nodeName)?.removeFromParent()

        let group = SKNode()
        group.name = nodeName
        group.position = center
        group.zPosition = 1

        let title = cleared ? "UNLOCKED" : "LOCKED"
        let accent = cleared ? UIColor(hex: "#00FF88") : UIColor(hex: "#FF3344")

        // Pill background sized to fit the text, centered on tile.
        let pillW: CGFloat = cleared ? 56 : 48
        let pillH: CGFloat = 16
        let pill = SKShapeNode(rectOf: CGSize(width: pillW, height: pillH), cornerRadius: 4)
        pill.fillColor = UIColor.black.withAlphaComponent(0.78)
        pill.strokeColor = accent
        pill.lineWidth = 1.4
        pill.glowWidth = 4.0
        pill.position = .zero
        pill.zPosition = 0
        group.addChild(pill)

        let label = SKLabelNode(fontNamed: "Menlo-Bold")
        label.text = title
        label.fontSize = 9
        label.fontColor = accent
        label.horizontalAlignmentMode = .center
        label.verticalAlignmentMode = .center
        label.position = .zero
        label.zPosition = 1
        group.addChild(label)

        // Subtle pulse so the player notices state changes (locked → unlocked).
        pill.run(SKAction.repeatForever(SKAction.sequence([
            SKAction.fadeAlpha(to: 0.55, duration: 0.7),
            SKAction.fadeAlpha(to: 1.0, duration: 0.7)
        ])))

        layer.addChild(group)
    }

    private func addObjectiveMarker(to layer: SKNode, x: Int, y: Int, title: String, color: UIColor) {
        let center = TileMap.tileCenter(x: x, y: y)
        let ring = SKShapeNode(path: TileMap.hexPath(radius: TileMap.hexRadius + 5))
        ring.position = center
        ring.fillColor = .clear
        ring.strokeColor = color.withAlphaComponent(0.82)
        ring.lineWidth = 2.4
        ring.glowWidth = 5
        ring.zPosition = 0
        ring.run(SKAction.repeatForever(SKAction.sequence([
            SKAction.fadeAlpha(to: 0.35, duration: 0.55),
            SKAction.fadeAlpha(to: 1.0, duration: 0.55)
        ])))
        layer.addChild(ring)

        let label = SKLabelNode(fontNamed: "Menlo-Bold")
        label.text = title
        label.fontSize = title.count > 5 ? 9 : 10
        label.fontColor = color
        label.horizontalAlignmentMode = .center
        label.verticalAlignmentMode = .center
        label.position = CGPoint(x: center.x, y: center.y + TileMap.hexRowSpacing * 0.72)
        label.zPosition = 1
        layer.addChild(label)
    }

    /// Load a mission's tile map.
    func loadMap(_ tileMap: TileMap) {
        let visibleTileMap: TileMap
        if let room = RoomManager.shared.currentRoom {
            visibleTileMap = presentationTileMap(for: room)
        } else {
            visibleTileMap = tileMap
        }
        self.tileMap = visibleTileMap
        addBoardBackplate(for: visibleTileMap)
        addRoomBackgroundImage(for: visibleTileMap)
        let mapNode = visibleTileMap.buildNode()
        // Center the map node in the scene so all tiles are within the camera's view.
        mapNode.position = mapOrigin
        addChild(mapNode)
        if let room = RoomManager.shared.currentRoom {
            addObjectiveMarkers(to: mapNode, room: room)
            restampScorchScars(on: mapNode, room: room)
        }
        // Helicopter arrives from the sky during the extraction sequence —
        // no parked heli on the pad at room load (player calls it in by
        // touching the extraction tile, which triggers descent → land → takeoff).

        // Add ambient effects
        visibleTileMap.addAmbientEffects(to: mapNode, mapSize: visibleTileMap.size)

        // Mission-specific cyberpunk VFX (code rain, glitch bars, sparks, etc.)
        // — frames live in Sprites/vfx/ and are placed per
        // MissionVFXManifest. Density-capped at 6 ambient nodes per room.
        let vfxMissionId = currentMissionIdForVFX()
        VFXManager.shared.applyAmbientVFX(to: mapNode, missionId: vfxMissionId)

        // Coordinate labels (column/row numbers in cyan along the map's
        // top/left edges) — dev aid, disabled for playtest. Flip the gate
        // back to true if you need to debug a tile-coord issue.
        let showMapCoordinateLabels = false
        if showMapCoordinateLabels {
            addMapCoordinateLabels(tileMap: visibleTileMap)
        }

        // Re-center camera on the now-centered map.
        positionCameraOnMap()
        refreshTraceVisuals(force: true)

        dlog("[BattleScene] loadMap: mapNode at \(mapNode.position), mapSize=\(visibleTileMap.size), scene.size=\(self.size), mapOrigin=\(mapOrigin)")
    }

    /// Loads and displays a per-room background image (if one exists) sized
    /// exactly to the playable hex grid. The hex tiles drawn on top of this
    /// are transparent for floors so the background reads through.
    ///
    /// Filename convention (search order):
    ///   1. Multi-room: Sprites/backgrounds/<MissionId>_<roomId>.png
    ///                  e.g. "Mission001_room_0.png"
    ///   2. Multi-room fallback: Sprites/backgrounds/<MissionId>.png
    ///   3. Single-room: Sprites/backgrounds/<MissionId>.png
    private func addRoomBackgroundImage(for tileMap: TileMap) {
        childNode(withName: "roomBackground")?.removeFromParent()

        let candidates = roomBackgroundCandidates()
        var loaded: SKTexture? = nil
        for name in candidates {
            if let tex = SpriteManager.shared.loadBackgroundTexture(named: name) {
                loaded = tex
                dlog("[BattleScene] Loaded room background: \(name)")
                break
            }
        }
        guard let bgTex = loaded else { return }

        let bg = SKSpriteNode(texture: bgTex)
        bg.size = tileMap.size
        bg.anchorPoint = CGPoint(x: 0, y: 0)
        bg.position = CGPoint(x: mapOrigin.x, y: mapOrigin.y)
        // Above the dark backplate (-40) but below all tiles (0), characters (10+),
        // and HUD overlays.
        bg.zPosition = -30
        bg.name = "roomBackground"
        addChild(bg)
    }

    /// Resolve a stable mission identifier for VFX placement lookups.
    /// Returns "" if no mission is loaded — VFXManager handles empty input
    /// by spawning no ambient nodes.
    private func currentMissionIdForVFX() -> String {
        if let multi = RoomManager.shared.currentMission {
            let raw = multi.id
            let base = raw.replacingOccurrences(of: "_multi", with: "")
            if base.hasPrefix("run"), let n = Int(base.dropFirst("run".count)) {
                return String(format: "Mission%03d", n)
            }
            return base
        }
        return ""
    }

    /// Build the list of background filenames to search in priority order.
    private func roomBackgroundCandidates() -> [String] {
        var names: [String] = []
        // Try to find the active mission ID. Pull from the multi-room mission if
        // present, otherwise from any string we can find in the loaded mission.
        let missionId: String
        if let multi = RoomManager.shared.currentMission {
            // Multi-room mission — use its id (e.g. "run001_multi")
            // Strip "_multi" suffix and translate "runNNN" → "MissionNNN".
            let raw = multi.id
            let base = raw.replacingOccurrences(of: "_multi", with: "")
            if base.hasPrefix("run"), let n = Int(base.dropFirst("run".count)) {
                missionId = String(format: "Mission%03d", n)
            } else {
                missionId = base
            }
        } else {
            missionId = ""
        }
        if let room = RoomManager.shared.currentRoom, !missionId.isEmpty {
            names.append("\(missionId)_\(room.id).png")
        }
        // Arena-pool rooms (gauntlet floors / contracts) carry their own art
        // slot by ROOM id ("arena_01.png"). No story-room fallback: arenas
        // must never borrow a mission-room background.
        if let room = RoomManager.shared.currentRoom {
            names.append("\(room.id).png")
        }
        if !missionId.isEmpty {
            names.append("\(missionId).png")
        }
        return names
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
                node.zPosition = playerDepthZ(for: character)
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
                node.zPosition = depthZ(forTileY: enemy.positionY, isEnemy: true)
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

        dlog("[BattleScene] syncCombatantsFromGameState(\(reason)) players=\(desiredPlayers.count) enemies=\(desiredEnemies.count) nodes=\(characterNodes.count)")
    }

    // MARK: - Coordinate Helpers

    /// Single source of truth for converting a tile coord to scene position.
    /// Delegates to TileMap.tileCenter(x:y:) so hex row stagger is applied consistently
    /// for both tile rendering and character/highlight placement.
    func tileCenter(_ tileX: Int, _ tileY: Int) -> CGPoint {
        let local = TileMap.tileCenter(x: tileX, y: tileY)
        dlog("[BattleScene] tileCenter(\(tileX),\(tileY)) → local=\(local) mapOrigin=\(mapOrigin)")
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
    /// Compute zPosition from tile-Y so southern (lower-on-screen) sprites
    /// render on top of northern sprites — standard 2.5D depth-sort. Without
    /// this, two sprites at adjacent tiles fight for visibility based on
    /// whichever was added to the scene last, which is what caused M3 R0's
    /// mage to render on top of the samurai despite being "behind" him.
    /// Z-order rule (per playtest spec 2026-05-23):
    ///   1. Selection always wins (+1000 bump applied at the call site for
    ///      both player selection and enemy targeting).
    ///   2. Otherwise: higher tileY = "in front" on screen → renders on top.
    ///   3. Same-tileY tiebreak: ENEMY wins. Contested-hex (player + enemy
    ///      on the same tile during e.g. melee swap-frames) should read as
    ///      the threat being closest. Tiebreak delta is 0.1, well under the
    ///      0.5/row depth contribution so any real tileY gap still wins.
    private func depthZ(forTileY y: Int, isEnemy: Bool) -> CGFloat {
        let base: CGFloat = 40 + CGFloat(y) * 0.5
        return isEnemy ? base + 0.1 : base
    }

    /// Z for a player sprite. Standard 2.5D depth-sort by tileY: characters
    /// lower on screen (higher tileY in this game's convention) render in
    /// front. A *tiny* party-order tiebreaker is added so when teammates
    /// stand at the same tileY (e.g. M1 starting horizontal formation),
    /// the leader (Raze, idx 0) wins over teammates added to the scene
    /// later — without that, Sable's sprite covered Raze just because she
    /// was added second.
    ///
    /// Tiebreaker delta is intentionally far below the per-row contribution
    /// (`0.5 / row` vs `0.015 / index`), so any real tileY difference still
    /// wins. If Sable stands one row "in front" of Raze on screen, Sable
    /// correctly occludes him. Selection's +1000 bump still overrides on top.
    private func playerDepthZ(forTileY y: Int, partyIndex: Int) -> CGFloat {
        let base = depthZ(forTileY: y, isEnemy: false)
        let boost = CGFloat(max(0, 4 - partyIndex)) * 0.015
        return base + boost
    }

    private func playerDepthZ(for character: Character) -> CGFloat {
        let idx = GameState.shared.playerTeam.firstIndex(where: { $0.id == character.id }) ?? 0
        return playerDepthZ(forTileY: character.positionY, partyIndex: idx)
    }

    private func playerDepthZ(forSprite sprite: SpriteNode) -> CGFloat {
        let idx = GameState.shared.playerTeam.firstIndex(where: { $0.id.uuidString == sprite.characterId }) ?? 0
        return playerDepthZ(forTileY: sprite.tileY, partyIndex: idx)
    }

    func placeCharacter(_ character: Character) {
        guard character.isAlive else { return }

        // Remove any prior sprite for this id BEFORE adding a new one. If we
        // skip this, two sprites end up at the same screen position and
        // their HP labels stack — that's the "28/18" garbled-HP bug.
        let nameTag = "player_\(character.id.uuidString)"
        if let prior = characterNodes[character.id] { prior.removeFromParent() }
        for child in self.children where child.name == nameTag { child.removeFromParent() }

        // Party-index stagger lifts each runner's HP label/stun-bar group
        // by 5pt per index so the spawn-cluster's four labels form a tiny
        // vertical column instead of stacking on top of each other.
        // (Bug pattern: M1 spawn put all four party members on the same row,
        // labels rendered at identical Y and were illegible.)
        let partyIndex = GameState.shared.playerTeam.firstIndex { $0.id == character.id } ?? 0
        let node = SpriteManager.shared.createCharacter(
            type: character.archetype.rawValue,
            team: "player",
            x: character.positionX,
            y: character.positionY,
            name: character.name,
            level: character.level,
            ownerId: character.id.uuidString,
            labelStaggerIndex: partyIndex
        )
        node.name = "player_\(character.id.uuidString)"
        node.characterId = character.id.uuidString
        node.tileX = character.positionX
        node.tileY = character.positionY
        node.team = "player"
        node.position = tileCenter(character.positionX, character.positionY)
        node.zPosition = playerDepthZ(for: character)
        node.alpha = 1.0
        node.isHidden = false
        addChild(node)
        characterNodes[character.id] = node
        SpriteManager.shared.updateHP(on: node, currentHP: character.currentHP, maxHP: character.maxHP, currentStun: character.currentStun, maxStun: character.maxStun, level: character.level, isPlayer: true)
        dlog("[BattleScene] placeCharacter \(character.name) at tile(\(character.positionX),\(character.positionY)) → pos \(node.position) scene.size=\(self.size) mapOrigin=\(mapOrigin) parent=\(node.parent?.name ?? "nil")")
    }

    /// Place an enemy sprite on the map, accounting for map centering offset.
    func placeEnemy(_ enemy: Enemy) {
        // Remove any prior sprite for this id (same fix as placeCharacter
        // — orphan sprites stack their HP labels and render as garbled
        // values like "28/18" when the live label updates and the orphan's
        // doesn't).
        let nameTag = "enemy_\(enemy.id.uuidString)"
        if let prior = characterNodes[enemy.id] { prior.removeFromParent() }
        for child in self.children where child.name == nameTag { child.removeFromParent() }

        let node = SpriteManager.shared.createCharacter(
            type: enemy.archetype,
            team: "enemy",
            x: enemy.positionX,
            y: enemy.positionY,
            name: enemy.name,
            level: MissionStatsStore.enemyDisplayLevel(
                missionId: GameState.shared.currentMissionDisplayId,
                archetype: enemy.archetype),
            ownerId: enemy.id.uuidString
        )
        node.name = "enemy_\(enemy.id.uuidString)"
        node.enemyId = enemy.id.uuidString
        node.tileX = enemy.positionX
        node.tileY = enemy.positionY
        node.team = "enemy"
        node.position = tileCenter(enemy.positionX, enemy.positionY)
        node.zPosition = depthZ(forTileY: enemy.positionY, isEnemy: true)
        node.alpha = 1.0
        node.isHidden = false

        // HP bar — floats ABOVE the enemy sprite, not on top of its torso.
        // Sprite uses anchor (0.5, 0.0) at position y=-TileMap.hexRowSpacing/2+4
        // ≈ y=-27, with display height ~70pt → sprite top at y=+43.
        // Previously the HP bar sat at y=22 which placed it MID-BODY on every
        // enemy (most visible on corpmage's purple cape). Bumped to y=58 +
        // y=66 so it clears the sprite top with a small gap.
        //
        // Boss sprites (bossmech / bossagi) are 140pt tall instead of 70 —
        // sprite top sits at y≈+113. The default y=58/66 HP bar drew INSIDE
        // the boss torso (hidden behind the larger sprite), so the player
        // saw "HP not draining" even though damage was applying. Push the
        // boss HP UI up to clear the taller body. Also widen the bar so
        // the visual matches the bigger sprite.
        let isBoss = enemy.archetype == "bossmech" || enemy.archetype == "bossagi" || enemy.archetype == "bosscorp" || enemy.archetype == "bossmage"
        // Trimmed ~15% per playtest note — bars were chunky relative to the
        // sprite. Normal 26→22, boss 48→40. Heights stay at their fine values.
        let enemyBarWidth: CGFloat = isBoss ? 40.0 : 22.0
        let hpBarHeight: CGFloat = isBoss ? 3.5 : 3.0
        // Per-enemy stagger: when multiple enemies cluster (M5 mech bay, M6
        // server core ring), their HP bars / labels would otherwise stack at
        // the same Y. Lift each by 5pt per their array index so they form a
        // small vertical fan. Bosses don't stagger — they're alone in the
        // room visually and the bar is already pushed up off-body.
        let enemyIdx = GameState.shared.enemies.firstIndex { $0.id == enemy.id } ?? 0
        let enemyStagger: CGFloat = isBoss ? 0 : CGFloat(enemyIdx % 3) * 4.0  // 6→4: smaller fan keeps staggered bars from slipping behind the front-row sprite
        // Feet anchor was lifted to y=-10 (SpriteManager), so a normal 70pt
        // enemy now has its sprite TOP at y≈+60. The bar/label were still at
        // 50/56 — i.e. drawn across the head (read as the riot guard's helmet
        // being "cut off"). Lift to 66/72 so they clear the head with a small
        // gap. (Boss values unchanged.)
        let hpBarY: CGFloat = (isBoss ? 119.0 : 66.0) + enemyStagger
        let hpLabelY: CGFloat = (isBoss ? 126.0 : 72.0) + enemyStagger
        // HP-bar children are UUID-suffixed by enemy id. `SpriteManager.updateHP`
        // reads `SpriteNode.enemyId` and looks up `"hpBarFill_<uuid>"` — so even
        // if a stale duplicate ever lands in the same subtree, this enemy's
        // own bar is the one that updates. (Defense-in-depth: the duplicate
        // creation that caused the corp-guard "14/14 vs 9/18" bug was removed
        // earlier, but the suffix prevents the pattern from regressing.)
        let hpSuffix = "_\(enemy.id.uuidString)"

        let hpBarBg = SKShapeNode(rectOf: CGSize(width: enemyBarWidth, height: hpBarHeight), cornerRadius: hpBarHeight / 2)
        hpBarBg.fillColor = UIColor.black.withAlphaComponent(0.7)
        hpBarBg.strokeColor = UIColor.clear
        hpBarBg.position = CGPoint(x: 0, y: hpBarY)
        hpBarBg.zPosition = 20
        hpBarBg.name = "hpBarBg\(hpSuffix)"
        hpBarBg.userData = NSMutableDictionary()
        hpBarBg.userData?["barWidth"] = enemyBarWidth
        hpBarBg.userData?["barHeight"] = hpBarHeight
        node.addChild(hpBarBg)

        let hpBarFill = SKShapeNode()
        hpBarFill.fillColor = UIColor(red: 0.2, green: 1.0, blue: 0.3, alpha: 0.9)
        hpBarFill.strokeColor = UIColor.clear
        hpBarFill.position = CGPoint(x: 0, y: hpBarY)
        hpBarFill.zPosition = 21
        hpBarFill.name = "hpBarFill\(hpSuffix)"
        node.addChild(hpBarFill)

        let hpLabel = SKLabelNode(text: "\(enemy.currentHP)/\(enemy.maxHP)")
        hpLabel.fontSize = isBoss ? 6.5 : 5.5
        hpLabel.fontName = "Menlo-Bold"
        hpLabel.fontColor = UIColor(red: 0.2, green: 1.0, blue: 0.3, alpha: 1.0)
        hpLabel.position = CGPoint(x: 0, y: hpLabelY)
        hpLabel.zPosition = 21
        hpLabel.name = "hpLabel\(hpSuffix)"
        node.addChild(hpLabel)

        addChild(node)
        characterNodes[enemy.id] = node
        SpriteManager.shared.updateHP(on: node, currentHP: enemy.currentHP, maxHP: enemy.maxHP, currentStun: enemy.currentStun, maxStun: enemy.maxStun)
        dlog("[BattleScene] placeEnemy \(enemy.name) at tile(\(enemy.positionX),\(enemy.positionY)) → pos \(node.position)")
    }

    /// Update character position.
    func moveCharacter(id: UUID, toX: Int, toY: Int) {
        guard let node = characterNodes[id] else { return }
        SpriteManager.shared.animateMove(target: node, toTileX: toX, toTileY: toY, mapOrigin: mapOrigin)
    }

    /// Remove a character sprite.
    func removeCharacter(id: UUID) {
        guard let node = characterNodes[id] else { return }
        let nodeName = node.name      // capture before async — pattern is "player_<uuid>" or "enemy_<uuid>"
        SpriteManager.shared.animateDeath(target: node)
        characterNodes.removeValue(forKey: id)

        // Belt-and-suspenders: schedule a HARD removal 0.6s out (animateDeath
        // is 0.5s; we add a 0.1s margin). Without this, the mage in M6 R1
        // was occasionally lingering on screen after death — the SKAction
        // chain inside animateDeath sometimes failed to run its trailing
        // removeFromParent step (likely because a competing action with the
        // same key was queued by another path). The hard remove is a no-op
        // if the node is already gone.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak node, weak self] in
            node?.removeFromParent()
            // Also sweep for any orphan node sharing this character's name
            // (e.g. a duplicate sprite created by a stale code path).
            guard let self = self, let nodeName = nodeName else { return }
            for child in self.children where child.name == nodeName {
                child.removeFromParent()
            }
        }
    }

    // MARK: - Selection

    /// Select a character by ID and highlight it.
    func selectCharacter(id: UUID) {
        deselectCurrent()

        guard let node = characterNodes[id] else { return }
        selectedCharacterNode = node
        SpriteManager.shared.animateSelect(target: node)

        // Z-bump: selected character ALWAYS renders in the foreground so
        // they aren't visually obstructed by other sprites at adjacent or
        // northern tiles. Unbumped on deselect (depthZ-by-tileY restored).
        if let sprite = node as? SpriteNode {
            sprite.zPosition = playerDepthZ(forSprite: sprite) + 1000
        }

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
            // Restore depth-by-tileY so the previously-selected sprite
            // sinks back into normal layering. Player team is the only
            // selectable group, so isEnemy: false is safe here.
            if let sprite = node as? SpriteNode {
                sprite.zPosition = playerDepthZ(forSprite: sprite)
            }
            selectedCharacterNode = nil
        }
    }

    /// Get character at a tile position.

    // Removed 2026-07-31: `updateTurnIndicator()` plus the `turnOrder` /
    // `currentTurnIndex` pair it read. Nothing ever called the function and
    // nothing ever populated the array, so its own `!turnOrder.isEmpty` guard
    // would have returned early even if something had. The live `.turnChanged`
    // notification is posted by CombatFlowController, not from here.
    // Vestigial scaffolding like this is what let the extraction blocker hide:
    // `syntheticExtraction` was equally dead but had passing tests, so contracts
    // looked covered while being uncompletable.

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
        // Above EVERYTHING — the old z=500 sat below the selected-runner
        // z-bump (~1046), helicopters (1100) and combat text (1500), so a tap
        // during the fade (which selects + z-bumps a sprite) made that sprite
        // pop on top of the black transition screen. The room-label/sigil are
        // children of this node, so they still render over the fade.
        fade.zPosition = 5000
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

        // Add room title label as child of the overlay (fades with it).
        // Timing — tuned 2026-05-18 per playtest "transitions need to take
        // a moment longer with the next room name displaying longer":
        //   0.0s  black fades in
        //   0.6s  black fully opaque, label starts fading in
        //   1.0s  label fully visible
        //   2.8s  label has held for ~1.8s, starts fading out
        //   3.1s  label gone; new room map already loaded behind black
        //   …then fadeOutFromTransition reveals the new room (0.6s)
        //
        // The label hold landed before the new room loaded, so the player
        // sees the destination name for a beat before the map reveal —
        // matches modern game room-transition pacing.
        let blackFadeInDur: TimeInterval = 0.6
        let labelHoldDur:   TimeInterval = 1.8
        if let targetRoom = RoomManager.shared.pendingRoomTransition {
            // ─── Vertical layout ───────────────────────────────────────────
            // Centering target (per playtest spec 2026-05-23): the player
            // reads the {room name + sigil mark} as ONE unit — that pair
            // needs to land centered on screen, with room name slightly
            // above true center and the mark just below. The ENTERING
            // sub-label + horizontal rule are subordinate framing and live
            // above/between the focal pair.
            //
            // Math: previous +30 offset put the room-name-to-sigil pair
            // mid at y=0 (room name 38pt above, sigil 38pt below). User
            // still saw too much empty space above the room name because
            // the room name was reading as the screen's vertical anchor.
            // Bump to +50 so the pair mid lands at y=+20 (room name reads
            // as visually anchored just above center, sigil sits just below
            // center — exactly the framing the spec calls for).
            // Nudged up (+50 → +92) per playtest: the room-name + sigil pair
            // was reading as bottom-heavy with dead space above the name. Higher
            // value = block sits higher on screen (SpriteKit +y = up).
            let blockYOffset: CGFloat = 92
            let roomLabel = SKLabelNode(text: targetRoom.title.uppercased())
            roomLabel.fontName = "Helvetica-Bold"
            roomLabel.fontSize = 26
            roomLabel.fontColor = UIColor(hex: "#00FF88")
            roomLabel.position = CGPoint(x: 0, y: 8 + blockYOffset)
            roomLabel.zPosition = 1
            roomLabel.alpha = 0
            roomLabel.name = "roomTransitionLabel"
            fade.addChild(roomLabel)

            // "ENTERING" sub-label above the room name for narrative framing.
            let sub = SKLabelNode(text: "ENTERING")
            sub.fontName = "Menlo-Bold"
            sub.fontSize = 11
            sub.fontColor = UIColor(hex: "#00FFCC").withAlphaComponent(0.75)
            sub.position = CGPoint(x: 0, y: 34 + blockYOffset)
            sub.zPosition = 1
            sub.alpha = 0
            sub.name = "roomTransitionSubLabel"
            fade.addChild(sub)

            // Thin horizontal rule under the room name — adds cinematic weight.
            let rule = SKShapeNode(rectOf: CGSize(width: 140, height: 1))
            rule.fillColor = UIColor(hex: "#00FF88").withAlphaComponent(0.55)
            rule.strokeColor = .clear
            rule.position = CGPoint(x: 0, y: -16 + blockYOffset)
            rule.zPosition = 1
            rule.alpha = 0
            fade.addChild(rule)

            // Zero State studio sigil — centered seal below the room name.
            // Sized larger (60pt) and at full opacity to read like a deliberate
            // packet header against the black backdrop. Sits below the
            // horizontal rule and above the "TAP TO CONTINUE" indicator zone.
            var sigilSprite: SKSpriteNode? = nil
            if let sigilTex = roomTransitionSigilTexture() {
                let sigil = SKSpriteNode(texture: sigilTex)
                let targetW: CGFloat = 60
                let scale = targetW / max(1, sigil.size.width)
                sigil.setScale(scale)
                sigil.alpha = 0
                sigil.position = CGPoint(x: 0, y: -68 + blockYOffset)
                sigil.zPosition = 1
                sigil.name = "roomTransitionSigil"
                fade.addChild(sigil)
                sigilSprite = sigil
            }

            let labelFadeIn  = SKAction.fadeAlpha(to: 1.0, duration: 0.4)
            let labelWait    = SKAction.wait(forDuration: labelHoldDur)
            let labelFadeOut = SKAction.fadeOut(withDuration: 0.35)
            let leadIn       = SKAction.wait(forDuration: blackFadeInDur)
            let labelSeq     = SKAction.sequence([leadIn, labelFadeIn, labelWait, labelFadeOut])
            let sigilFadeIn  = SKAction.fadeAlpha(to: 0.85, duration: 0.4)
            let sigilSeq     = SKAction.sequence([leadIn, sigilFadeIn, labelWait, labelFadeOut])
            roomLabel.run(labelSeq)
            sub.run(labelSeq)
            rule.run(labelSeq)
            sigilSprite?.run(sigilSeq)
        }

        // Fade in the black overlay first; THEN hold (with label visible);
        // THEN post the transition-completed notification so the new room
        // loads while the player is still staring at the title card.
        let fadeIn = SKAction.fadeAlpha(to: 1.0, duration: blackFadeInDur)
        let holdOnBlack = SKAction.wait(forDuration: 0.4 + labelHoldDur + 0.35)
        fade.run(SKAction.sequence([fadeIn, holdOnBlack])) { [weak self] in
            guard self != nil else { return }
            NotificationCenter.default.post(name: .roomTransitionCompleted, object: nil)
        }
    }

    /// Reload the scene with a new room's map after a transition fade completes.
    func loadRoom(_ room: Room, characters: [Character], enemies: [Enemy]) {
        clearThreatPreview()
        currentRoomId = room.id
        // Sync authority room state (room id + per-room first-kill tracking
        // so the new room's `removeOnFirstKill` barriers fire on next kill).
        GameState.shared.syncRoomLoaded(roomId: room.id)
        // Re-arm the "Jack in and hack the terminal" warning. Stale
        // confirmations from the previous room shouldn't bypass the warning
        // in a new room that also has a terminal.
        lastTerminalWarningAt = nil
        // Per-room narrative props. Currently only M3 Ritual Chamber needs
        // one — Sato's grimoire on its altar. Skipped if already acquired
        // (player came back to the room after pickup).
        spawnRoomSpecificProps(roomId: room.id)

        // Remove old tilemap
        childNode(withName: "TileMap")?.removeFromParent()
        childNode(withName: "coordinateLabels")?.removeFromParent()

        // Remove all character sprites
        for (_, node) in characterNodes {
            node.removeFromParent()
        }
        characterNodes.removeAll()

        // Build new tilemap
        let newTileMap = presentationTileMap(for: room)
        self.tileMap = newTileMap

        // Sync tiles to GameState for enemy pathfinding
        Task { @MainActor in
            GameState.shared.updateTilesForCurrentRoom(room.map)
            // room.map is fresh from JSON — re-flatten any cover the player
            // already destroyed in this room (barrels/crates), so cover math
            // and walkability keep reading the destroyed state on re-entry.
            GameState.shared.applyDestroyedCoverToCurrentTiles(roomId: room.id)
        }
        let mapNode = newTileMap.buildNode()
        mapNode.position = mapOrigin
        addBoardBackplate(for: newTileMap)
        // Load this room's background AFTER the backplate so the BG sits above
        // the dark plate. Without this, room transitions kept the previous
        // room's BG showing because addRoomBackgroundImage() was only called
        // from loadMap (initial load), not from loadRoom (transitions).
        addRoomBackgroundImage(for: newTileMap)
        addChild(mapNode)
        // Barriers dropped on an earlier visit: the tile grid already reads as
        // floor (applyDroppedBarriers), but the barrier is PAINTED INTO the
        // room background art, which is reloaded pristine above. Without
        // replaying the pixel patch the wall reappears while staying
        // walk-through — visibly there, physically gone.
        replayDroppedBarrierPatches(for: room)
        addObjectiveMarkers(to: mapNode, room: room)
        restampScorchScars(on: mapNode, room: room)
        // Mission-specific ambient VFX — must run on every room load,
        // not just the initial loadMap path. Without this call, transitions
        // into room_1, room_2, etc. would show no VFX.
        let vfxMissionId = currentMissionIdForVFX()
        VFXManager.shared.applyAmbientVFX(to: mapNode, missionId: vfxMissionId)
        // Heli arrives from sky on extraction — see playExtractionHelicopterAnimation.
        // No parked sprite on the pad at room load.

        // Center camera on map first — will be refined to character position below.
        positionCameraOnMap()

        // Place characters — validate every position against the NEW room's tile map.
        // Characters may carry coordinates from a different room (e.g. back-navigation or
        // first load) that land on walls, out-of-bounds tiles, or enemy spawn points here.
        // validatedSpawnX() checks room.map directly, so it's always correct for this room.
        let spawn = room.playerSpawn
        let livingCharacters = characters.filter { $0.isAlive }
        // Track tiles already chosen so siblings don't stack onto the same hex
        // when their proposed positions all fall back to the same nearest-walkable.
        var occupied: Set<String> = []
        // Pre-seed with positions that are already valid (won't be repositioned)
        // so subsequent fallback picks avoid those tiles too.
        for character in livingCharacters {
            let inBounds = character.positionY >= 0
                && character.positionY < room.map.count
                && character.positionX >= 0
                && character.positionX < (room.map.first?.count ?? 0)
            guard inBounds, !(character.positionX == 0 && character.positionY == 0) else { continue }
            let tile = room.map[character.positionY][character.positionX]
            let walkable = tile == TileType.floor.rawValue
                || tile == TileType.cover.rawValue
                || tile == TileType.door.rawValue
                || tile == TileType.extraction.rawValue
            if walkable {
                occupied.insert("\(character.positionX),\(character.positionY)")
            }
        }
        for (i, character) in livingCharacters.enumerated() {
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
            // Check 4: another living runner is already on this exact tile
            // (caused by stale loadRoom resets stacking two runners on the
            // same coords). Treat as needing a re-spawn.
            let isStacked: Bool = {
                guard !isUnset && !outOfBounds && !isBlocked else { return false }
                return occupied.contains("\(character.positionX),\(character.positionY)")
            }()

            if isUnset || outOfBounds || isBlocked || isStacked {
                // Spread the party CENTERED across the spawn row rather than
                // walking off the right edge (spawn.x + i used to push the 4th
                // runner into the wall, where the fallback then bunched them).
                // e.g. 4 runners around centre x=3 → columns 2,3,4,5.
                let n = max(1, livingCharacters.count)
                let spreadOffset = i - (n - 1) / 2
                let candidate = validatedSpawnX(in: room,
                                                proposedX: spawn.x + spreadOffset,
                                                proposedY: spawn.y,
                                                avoiding: occupied)
                character.positionX = candidate.x
                character.positionY = candidate.y
                dlog("[BattleScene] loadRoom: repositioned \(character.name) → (\(candidate.x),\(candidate.y)) reason: unset=\(isUnset) oob=\(outOfBounds) blocked=\(isBlocked) stacked=\(isStacked)")
            }
            occupied.insert("\(character.positionX),\(character.positionY)")
            placeCharacter(character)
        }

        // Place enemies for this room.
        for enemy in enemies {
            placeEnemy(enemy)
        }

        // Clear highlights
        clearHighlights()

        // Select the ACTIVE character (initiative winner, set by
        // restorePlayerControlAfterEnemyPhase before this runs), not just the
        // roster-first runner. Selecting `first` here desynced the scene
        // (ring/hex on Raze) from the game's active char (HUD/movement on
        // Cipher) on every room entry until the player manually reselected.
        let activeId = GameState.shared.activeCharacterId ?? GameState.shared.selectedCharacterId
        let focus = livingCharacters.first(where: { $0.id == activeId }) ?? livingCharacters.first
        if let focus = focus {
            // Keep GameState ids in sync with what the scene is about to ring,
            // so HUD, movement, and the ring/hex all agree on one runner.
            CombatFlowController.requestCharacterSelectionFromScene(gameState: GameState.shared, id: focus.id)
            selectCharacter(id: focus.id)

            // After room load, focus camera on the active character so they're
            // always visible — prevents spawn-at-edge-of-map invisible placement.
            focusCamera(on: focus.positionX, y: focus.positionY)

            // Freeze all player characters except the active one so only
            // the current actor's idle animation runs.
            updatePlayerIdleAnimations(activeId: focus.id)
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
        guard RoomManager.shared.isExtractionActive() else { return false }
        return tileX == GameState.shared.extractionX && tileY == GameState.shared.extractionY
    }

    /// Check if a given tile is walkable (floor, door, extraction, cover, or data terminal — NOT wall).
    func isWalkableTile(_ tileX: Int, _ tileY: Int) -> Bool {
        // Read from the LIVE mutable grid (gameState.currentMissionTiles) so
        // dynamic terrain edits — barrier drops, terminal hacks, etc. — are
        // immediately reflected in movement validation. The tileMap snapshot
        // is built once at room load and can't see runtime mutations.
        let tiles = GameState.shared.currentMissionTiles
        guard tileX >= 0, tileX < TileMap.mapWidth, tileY >= 0, tileY < tiles.count else { return false }
        guard tileX < tiles[tileY].count else { return false }
        let raw = tiles[tileY][tileX]
        guard let t = TileType(rawValue: raw) else { return false }
        return t == .floor || t == .door || t == .extraction || t == .cover || t == .dataTerminal
    }

    private func isUnhackedDataTerminal(_ tileX: Int, _ tileY: Int) -> Bool {
        let tiles = GameState.shared.currentMissionTiles
        guard tileY >= 0, tileY < tiles.count, tileX >= 0, tileX < tiles[tileY].count else { return false }
        return tiles[tileY][tileX] == TileType.dataTerminal.rawValue
    }

    /// True if the current room still has an unhacked required terminal that
    /// the player is about to walk past. Used by `handleDoorTileTap` to warn
    /// the player before they leave the room. The check uses the LIVE tile
    /// grid (`currentMissionTiles`) — once the terminal is hacked,
    /// `MissionSetupService.tilesWithoutDataTerminals` strips it from the
    /// active grid, so a successful hack naturally short-circuits this check.
    /// Whether the "recover the grimoire" prompt has fired this scene lifetime.
    private var grimoirePromptShown = false

    /// Place per-room narrative props. Currently only Sato's grimoire in M3R2.
    /// Hooked from `loadRoom` so it fires on every entry (including replays).
    /// `announce` = true only on the .roomCleared trigger (Sato just died) so
    /// the "RECOVER THE GRIMOIRE" call-to-action fires once, not on re-entry.
    private func spawnRoomSpecificProps(roomId: String, announce: Bool = false) {
        // Strip any prior prop nodes from previous rooms.
        childNode(withName: "grimoireProp")?.removeFromParent()

        // Mission003 / Ritual Chamber — Sato's grimoire on the altar tile.
        guard GameState.shared.currentMissionDisplayId == "Mission003" else { return }
        guard roomId == "room_2" else { return }
        // If the player already grabbed it this run, don't respawn the visual.
        guard !GameState.shared.grimoireAcquired else { return }
        // Keep the ritual scene clean DURING the fight — only reveal the
        // grimoire highlight + label AFTER Sato's BOSS FORM is dead. Gating on
        // `mageBossPhase2Triggered` alone fired this the instant the CORP mage
        // died (before the boss even spawned), so the grimoire + "SATO IS DEAD"
        // appeared during the reforming window. `!mageBossPhase2Pending` blocks
        // that: while the boss is still reforming (pending) OR on the field,
        // the gate stays shut — it only opens once the boss form has spawned
        // (pending cleared) AND no mage/bossmage remains alive (boss killed).
        guard GameState.shared.mageBossPhase2Triggered,
              !GameState.shared.mageBossPhase2Pending,
              !GameState.shared.enemies.contains(where: {
                  let a = $0.archetype.lowercased()
                  return $0.isAlive && (a == "mage" || a == "bossmage")
              }) else { return }

        // The grimoire sits on the central ritual ALTAR painted into the room
        // background (book-on-altar, dead centre on the pentagram). We don't
        // redraw the book — instead we HIGHLIGHT the altar tile with a pulsing
        // gold ring + glow and float a "GRIMOIRE" label above it, so the
        // objective reads unmistakably on the existing art.
        let grimoireTileX = CombatFlowController.grimoireTileX
        let grimoireTileY = CombatFlowController.grimoireTileY
        let tilePos = tileCenter(grimoireTileX, grimoireTileY)
        let mapNode = childNode(withName: "TileMap") ?? self
        let origin = mapNode.position

        let prop = SKNode()
        prop.name = "grimoireProp"
        prop.position = CGPoint(x: origin.x + tilePos.x, y: origin.y + tilePos.y)
        prop.zPosition = 4  // above floor, below characters

        let gold = UIColor(hex: "#FFCC33")

        // Pulsing gold highlight ring on the altar tile — strong + snappy so
        // it's unmistakable against the busy ritual altar art.
        let ring = SKShapeNode(path: TileMap.hexPath(radius: TileMap.hexRadius - 2))
        ring.fillColor = gold.withAlphaComponent(0.16)
        ring.strokeColor = gold
        ring.lineWidth = 3.6
        ring.glowWidth = 9.0
        ring.zPosition = 0
        ring.run(SKAction.repeatForever(SKAction.sequence([
            SKAction.fadeAlpha(to: 0.35, duration: 0.55),
            SKAction.fadeAlpha(to: 1.0, duration: 0.55)
        ])))
        prop.addChild(ring)

        // Expanding "ping" ring that radiates outward to grab the eye.
        let ping = SKShapeNode(path: TileMap.hexPath(radius: TileMap.hexRadius - 2))
        ping.fillColor = .clear
        ping.strokeColor = gold
        ping.lineWidth = 2.0
        ping.zPosition = 0
        ping.run(SKAction.repeatForever(SKAction.sequence([
            SKAction.group([SKAction.scale(to: 2.0, duration: 1.1),
                            SKAction.fadeAlpha(to: 0.0, duration: 1.1)]),
            SKAction.run { ping.setScale(1.0) },
            SKAction.fadeAlpha(to: 0.9, duration: 0.01)
        ])))
        prop.addChild(ping)

        // Soft breathing glow behind the altar to pull the eye.
        let glow = SKShapeNode(circleOfRadius: 20)
        glow.fillColor = gold.withAlphaComponent(0.16)
        glow.strokeColor = .clear
        glow.zPosition = -1
        glow.run(SKAction.repeatForever(SKAction.sequence([
            SKAction.scale(to: 1.18, duration: 1.0),
            SKAction.scale(to: 1.0, duration: 1.0)
        ])))
        prop.addChild(glow)

        // "GRIMOIRE" pill label floating above the altar (door-pill vibe).
        let labelGroup = SKNode()
        labelGroup.position = CGPoint(x: 0, y: 26)
        labelGroup.zPosition = 3
        let pill = SKShapeNode(rectOf: CGSize(width: 62, height: 15), cornerRadius: 4)
        pill.fillColor = UIColor.black.withAlphaComponent(0.78)
        pill.strokeColor = gold
        pill.lineWidth = 1.2
        pill.glowWidth = 3.0
        labelGroup.addChild(pill)
        let tag = SKLabelNode(text: "GRIMOIRE")
        tag.fontName = "Menlo-Bold"
        tag.fontSize = 8
        tag.fontColor = gold
        tag.verticalAlignmentMode = .center
        tag.horizontalAlignmentMode = .center
        labelGroup.addChild(tag)
        labelGroup.run(SKAction.repeatForever(SKAction.sequence([
            SKAction.moveBy(x: 0, y: 2, duration: 1.0),
            SKAction.moveBy(x: 0, y: -2, duration: 1.0)
        ])))
        prop.addChild(labelGroup)

        // Gentle fade-in — the highlight only appears once the boss is down,
        // so it should reveal smoothly rather than pop.
        prop.alpha = 0
        addChild(prop)
        prop.run(SKAction.fadeIn(withDuration: 0.6))

        // Call-to-action — fires once, only when Sato has just died (announce),
        // so the player knows to grab the grimoire before extracting.
        if announce && !grimoirePromptShown {
            grimoirePromptShown = true
            GameState.shared.postTransientWarning("📖 SATO IS DEAD — GRAB THE GRIMOIRE (gold altar) BEFORE YOU EXTRACT", duration: 6.0)
            GameState.shared.addLog("Sato is dead — his grimoire is unguarded. Step onto the glowing altar (centre) to claim it before extracting.")
            HapticsManager.shared.unlock()
        }
    }

    /// Called when the player picks up Sato's grimoire. Plays a brief
    /// "snatched" animation (scale up + fade out) on the prop node, then
    /// removes it. No-op if the prop isn't currently in the scene.
    private func handleGrimoireAcquired() {
        guard let prop = childNode(withName: "grimoireProp") else { return }
        let snatch = SKAction.group([
            SKAction.scale(to: 1.6, duration: 0.35),
            SKAction.fadeOut(withDuration: 0.35),
            SKAction.moveBy(x: 0, y: 22, duration: 0.35)
        ])
        snatch.timingMode = .easeOut
        prop.run(SKAction.sequence([snatch, SKAction.removeFromParent()]))
    }

    private func shouldBlockExitForUnhackedTerminal() -> Bool {
        // Only relevant on missions whose objective requires a terminal hack
        // (i.e. `dataAcquired` contributes to the score / unlocks extraction).
        guard GameState.shared.missionRequiresData else { return false }
        // Already hacked one — no warning needed.
        guard !GameState.shared.dataAcquired else { return false }
        // Scan the current room's live tile grid for any remaining terminal.
        let tiles = GameState.shared.currentMissionTiles
        for row in tiles {
            if row.contains(TileType.dataTerminal.rawValue) { return true }
        }
        return false
    }

    private func validatedSpawnX(in room: Room, proposedX: Int, proposedY: Int,
                                  avoiding: Set<String> = []) -> (x: Int, y: Int) {
        func isWalkable(_ x: Int, _ y: Int) -> Bool {
            guard y >= 0, y < room.map.count, x >= 0, x < room.map[y].count else { return false }
            let tile = room.map[y][x]
            return tile == TileType.floor.rawValue || tile == TileType.cover.rawValue || tile == TileType.door.rawValue || tile == TileType.extraction.rawValue
        }
        func isFree(_ x: Int, _ y: Int) -> Bool {
            isWalkable(x, y) && !avoiding.contains("\(x),\(y)")
        }

        // Try the proposed tile first if it's free.
        if isFree(proposedX, proposedY) {
            return (proposedX, proposedY)
        }

        // Hex-aware ring search around the proposed tile — checks 6 hex
        // neighbors before falling further out. This produces a clean
        // adjacency cluster rather than diagonal stacking.
        let evenColNeighbors  = [(0,-1),(0,1),(-1,-1),(-1,0),(1,-1),(1,0)]
        let oddColNeighbors   = [(0,-1),(0,1),(-1,0),(-1,1),(1,0),(1,1)]
        var ring: [(Int, Int)] = (proposedX % 2 == 0) ? evenColNeighbors : oddColNeighbors
        var visited: Set<String> = ["\(proposedX),\(proposedY)"]
        var queue: [(Int, Int)] = ring.map { (proposedX + $0.0, proposedY + $0.1) }
        for q in queue { visited.insert("\(q.0),\(q.1)") }
        while !queue.isEmpty {
            let (cx, cy) = queue.removeFirst()
            if isFree(cx, cy) { return (cx, cy) }
            ring = (cx % 2 == 0) ? evenColNeighbors : oddColNeighbors
            for (dx, dy) in ring {
                let nx = cx + dx
                let ny = cy + dy
                let key = "\(nx),\(ny)"
                if visited.contains(key) { continue }
                visited.insert(key)
                queue.append((nx, ny))
            }
            // Bound the search to avoid runaway BFS on giant maps.
            if visited.count > 200 { break }
        }

        // Last-ditch fallback to the room's player-spawn anchor (better than
        // off-map). The caller's `avoiding` set will at least keep us off any
        // tile already taken by a sibling runner, but if nothing's reachable
        // we tolerate stacking on the spawn anchor.
        return (room.playerSpawn.x, room.playerSpawn.y)
    }

    /// Fade out after room load. Slightly longer than the fade-in so the
    /// new map reveals gracefully rather than snapping into view.
    func fadeOutFromTransition() {
        // Prefer the stored reference; fall back to child-name search in camera then scene.
        let fade: SKNode? = fadeNode
            ?? camera?.childNode(withName: "fadeOverlay")
            ?? childNode(withName: "fadeOverlay")
        guard let fade = fade else { return }
        let fadeOut = SKAction.fadeAlpha(to: 0.0, duration: 0.7)
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
            dlog("[BattleScene] Input locked — waiting for enemy phase")
            return
        }
        // Any tap clears an open threat preview; remember which enemy owned
        // it so tapping the SAME enemy again reads as dismiss, not re-show.
        let threatWas = threatEnemyId
        clearThreatPreview()
        // Check extraction tile — win immediately if all enemies are cleared and player stands on it
        if isExtractionTile(tileX, tileY) {
            // Extraction resolution is GameState-authoritative.
            if let sprite = selectedCharacterNode as? SpriteNode,
               let charEntry = characterNodes.first(where: { $0.value === sprite }),
               GameState.shared.playerTeam.contains(where: { $0.id == charEntry.key && $0.isAlive }) {
                let charId = charEntry.key
                let alreadyOnExtraction = sprite.tileX == tileX && sprite.tileY == tileY
                // Moving ONTO extraction is the runner's move — gate it on the
                // per-turn budget so a runner who already moved can't get a
                // free extra move to reach the pad. If they're already standing
                // on it, tapping just resolves the extraction (no move needed).
                if !alreadyOnExtraction {
                    guard let char = GameState.shared.playerTeam.first(where: { $0.id == charId && $0.isAlive }),
                          !char.hasActedThisRound,
                          GameState.shared.characterHasMovedThisTurn[charId] != true else {
                        GameState.shared.addLog("\(GameState.shared.playerTeam.first(where: { $0.id == charId })?.name ?? "This runner") already used their move this turn — end turn to continue.")
                        return
                    }
                    let reachable = bfsReachable(fromX: sprite.tileX, fromY: sprite.tileY, maxSteps: movementRange)
                    guard reachable.contains(where: { $0.x == tileX && $0.y == tileY }) else {
                        GameState.shared.addLog("Move closer to extraction first.")
                        return
                    }
                    animateCharacterMove(characterId: charId, toTileX: tileX, toTileY: tileY)
                    sprite.tileX = tileX
                    sprite.tileY = tileY
                    sprite.zPosition = playerDepthZ(forSprite: sprite)
                    GameState.shared.characterHasMovedThisTurn[charId] = true
                }
                _ = GameState.shared.requestExtraction(characterId: charId, tileX: tileX, tileY: tileY)
            } else {
                _ = GameState.shared.requestExtraction(characterId: nil, tileX: tileX, tileY: tileY)
            }
            return
        }

        // Find what's on this tile
        var characterOnTile: (id: UUID, sprite: SpriteNode)?
        var enemyOnTile: (id: UUID, sprite: SpriteNode)?

        for (id, node) in characterNodes {
            guard let sprite = node as? SpriteNode else { continue }
            if sprite.tileX == tileX && sprite.tileY == tileY {
                if sprite.team == "player",
                   GameState.shared.playerTeam.contains(where: { $0.id == id && $0.isAlive }) {
                    characterOnTile = (id, sprite)
                } else if sprite.team == "enemy",
                          GameState.shared.enemies.contains(where: { $0.id == id && $0.isAlive }) {
                    enemyOnTile = (id, sprite)
                }
            }
        }
        // Defensive fallback: if no sprite matched but GameState says an
        // enemy is at this tile (sprite.tileX/Y can briefly desync after a
        // move animation), find that enemy's sprite node by id and route the
        // tap to attack handling instead of falling through to movement.
        if enemyOnTile == nil,
           let liveEnemy = GameState.shared.enemies.first(where: {
               $0.isAlive && $0.positionX == tileX && $0.positionY == tileY
           }),
           let node = characterNodes[liveEnemy.id] as? SpriteNode {
            enemyOnTile = (liveEnemy.id, node)
        }

        // Door tiles with an enemy on them: skip the door transition logic and go straight
        // to attack handling. The movement-into-locked-door check lives in handleDoorTileTap
        // and is not relevant when the player is tapping an enemy.
        // (Previously bound to a `doorTileWithEnemy` local — never read.)
        _ = isDoorTile(tileX, tileY) && enemyOnTile != nil

        if isDoorTile(tileX, tileY) && enemyOnTile == nil {
            if let (id, characterSprite) = characterOnTile,
               characterSprite !== selectedCharacterNode {
                // Update the model ids BEFORE the visuals so anything reading
                // GameState.activeCharacter sees the freshly-selected runner.
                CombatFlowController.requestCharacterSelectionFromScene(gameState: GameState.shared, id: id)
                showSelectionRing(for: id)
                return
            }

            handleDoorTileTap(tileX: tileX, tileY: tileY)
            return
        }

        // 1. Tap on player character -> select it (always allowed)
        if let (id, _) = characterOnTile {
            CombatFlowController.requestCharacterSelectionFromScene(gameState: GameState.shared, id: id)
            showSelectionRing(for: id)
            return
        }

        // 2. Tap on enemy with a character selected -> set as target (no
        // auto-fire). Player picks the target first, then commits via the
        // ATK / SHT / HACK / SPELL HUD button. This gives them control over
        // which enemy gets hit instead of always defaulting to the first
        // option. The attack handlers fall back to nearest-living-enemy if
        // no target was set explicitly (already wired in performAttack).
        if let (_, enemySprite) = enemyOnTile {
            if GameState.shared.activeCharacterId != nil || GameState.shared.selectedCharacterId != nil {
                if let enemyId = UUID(uuidString: enemySprite.enemyId),
                   !enemySprite.enemyId.isEmpty,
                   GameState.shared.requestTargetSelection(enemyId: enemyId).isAccepted {
                    showTargetRing(for: enemyId)
                } else {
                    GameState.shared.addLog("Cannot target this enemy.")
                }
                return
            } else {
                // No runner selected: show this enemy's THREAT RANGE instead
                // of a dead tap (tap the same enemy again to dismiss).
                if let enemyId = UUID(uuidString: enemySprite.enemyId),
                   !enemySprite.enemyId.isEmpty,
                   threatWas != enemyId {
                    showThreatPreview(for: enemyId)
                }
                return
            }
        }

        // 3. Tap empty tile -> move the selected character (FREE action, no turn cost)
        guard let sprite = selectedCharacterNode as? SpriteNode else {
            GameState.shared.addLog("Select a character first.")
            return
        }

        // Block movement onto a door tile that did not route through door handling above.
        if isDoorTile(tileX, tileY) {
            GameState.shared.addLog("Cannot move onto a door tile.")
            return
        }

        guard let charEntry = characterNodes.first(where: { $0.value === sprite }) else { return }
        let charId = charEntry.key
        guard GameState.shared.playerTeam.contains(where: { $0.id == charId && $0.isAlive }) else {
            deselectCurrent()
            _ = GameState.shared.requestSelectionCleared()
            return
        }

        if (tileMap?.tiles[tileY][tileX] ?? .floor) == .dataTerminal,
           isUnhackedDataTerminal(tileX, tileY) {
            let isAdjacent = hexNeighbors(x: sprite.tileX, y: sprite.tileY).contains(where: { neighbor in
                neighbor.0 == tileX && neighbor.1 == tileY
            })
            if isAdjacent,
               let char = GameState.shared.playerTeam.first(where: { $0.id == charId && $0.isAlive }) {
                CombatFlowController.checkDataTerminalPickup(gameState: GameState.shared, atX: tileX, y: tileY, by: char)
                return
            }
        }

        // Grimoire (M3R2): tap to grab when standing ON or ADJACENT to the
        // central altar tile. The grimoire used to ONLY pick up by landing a
        // move exactly on its tile — so a runner parked on it when the boss
        // died, or one who'd already spent their move, could never grab it
        // ("I move onto the tile but it's still there"). This mirrors the
        // data-terminal interact. Gated on actual grabbability so it doesn't
        // hijack movement onto the altar before the boss is down.
        let grimX = CombatFlowController.grimoireTileX
        let grimY = CombatFlowController.grimoireTileY
        if GameState.shared.currentMissionDisplayId == "Mission003",
           GameState.shared.currentRoomId == "room_2",
           tileX == grimX, tileY == grimY,
           !GameState.shared.grimoireAcquired,
           GameState.shared.mageBossPhase2Triggered,
           !GameState.shared.enemies.contains(where: {
               let a = $0.archetype.lowercased()
               return ($0.isAlive) && (a == "mage" || a == "bossmage")
           }) {
            let onTile = sprite.tileX == grimX && sprite.tileY == grimY
            let adjacent = hexNeighbors(x: sprite.tileX, y: sprite.tileY)
                .contains(where: { $0.0 == grimX && $0.1 == grimY })
            if (onTile || adjacent),
               let char = GameState.shared.playerTeam.first(where: { $0.id == charId && $0.isAlive }) {
                CombatFlowController.checkGrimoirePickup(gameState: GameState.shared, atX: grimX, y: grimY, by: char)
                return
            }
        }

        let reachable = bfsReachable(fromX: sprite.tileX, fromY: sprite.tileY, maxSteps: movementRange)
        let isInRange = reachable.contains(where: { $0.x == tileX && $0.y == tileY })

        if isInRange {
            guard let char = GameState.shared.playerTeam.first(where: { $0.id == charId && $0.isAlive }),
                  !char.hasActedThisRound,
                  GameState.shared.characterHasMovedThisTurn[charId] != true else {
                GameState.shared.addLog("This character has already used their turn.")
                return
            }
            guard isWalkableTile(tileX, tileY) else {
                GameState.shared.addLog("Cannot move to wall tile (\(tileX),\(tileY))")
                return
            }
            // Movement consumes the character's player turn. A turn is move OR action.
            animateCharacterMove(characterId: charId, toTileX: tileX, toTileY: tileY)
            _ = GameState.shared.requestMove(unitID: charId, toTileX: tileX, toTileY: tileY)
            sprite.tileX = tileX
            sprite.tileY = tileY
            sprite.zPosition = playerDepthZ(forSprite: sprite)

            if isDoorTile(tileX, tileY) {
                openDoor(tileX: tileX, tileY: tileY)
            }
            clearHighlights()
        } else {
            // SILENT no-op: tap was on a far empty tile (not an enemy, not
            // a player, not a door, not the extraction). The user reported
            // the previous "Out of range (max 2 steps)" message firing
            // during ranged attacks — even though SHT/SPELL never go through
            // this branch. The message was misleading and added noise. Now
            // we just drop the tap silently. Distance attacks happen via
            // the SHT/SPELL buttons + an enemy target, not via tile taps.
            return
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
        let standingOnDoor = sprite.tileX == tileX && sprite.tileY == tileY
        guard standingOnDoor else {
            // A door that leads BACK to an already-entered room is usable even
            // if this room isn't cleared (so the player can return for a missed
            // objective). New rooms still require clearing first.
            let isBacktrackDoor = RoomManager.shared.doorIsBacktrack(inRoom: currentRoomId, tileX: tileX, y: tileY)
            guard RoomManager.shared.isRoomCleared(currentRoomId) || isBacktrackDoor else {
                GameState.shared.addLog("Door locked: clear this room first.")
                return
            }

            // Stepping to the door IS the runner's move — it must respect the
            // normal per-turn budget. Without this guard a runner who already
            // moved (or acted) this turn got a free extra move onto the door,
            // letting them cross rooms after effectively double-moving.
            guard let charEntry = characterNodes.first(where: { $0.value === sprite }) else { return }
            let charId = charEntry.key
            guard let char = GameState.shared.playerTeam.first(where: { $0.id == charId && $0.isAlive }),
                  !char.hasActedThisRound,
                  GameState.shared.characterHasMovedThisTurn[charId] != true else {
                GameState.shared.addLog("\(GameState.shared.playerTeam.first(where: { $0.id == charId })?.name ?? "This runner") already used their move this turn — end turn to continue.")
                return
            }

            let reachable = bfsReachable(fromX: sprite.tileX, fromY: sprite.tileY, maxSteps: movementRange)
            guard reachable.contains(where: { $0.x == tileX && $0.y == tileY }) else {
                GameState.shared.addLog("Move closer to the door first.")
                return
            }
            animateCharacterMove(characterId: charId, toTileX: tileX, toTileY: tileY)
            _ = GameState.shared.requestMove(unitID: charId, toTileX: tileX, toTileY: tileY)
            sprite.tileX = tileX
            sprite.tileY = tileY
            sprite.zPosition = playerDepthZ(forSprite: sprite)
            GameState.shared.addLog("Door ready. Tap it again to enter.")
            clearHighlights()
            return
        }

        // Mission-objective gate: if this mission REQUIRES data, the current
        // room contains a still-unhacked terminal, and the player hasn't
        // hacked one yet, fire a one-time warning before letting them leave.
        // A second tap on the door within `warnConfirmWindow` seconds bypasses
        // the warning (they've been told; if they still want to skip the
        // bonus, that's their call).
        if shouldBlockExitForUnhackedTerminal() {
            let now = Date()
            if let lastWarn = lastTerminalWarningAt,
               now.timeIntervalSince(lastWarn) <= warnConfirmWindow {
                // Second tap within the confirm window — let them pass.
                // Clear the warning timestamp so future doors re-prompt.
                lastTerminalWarningAt = nil
            } else {
                // First tap (or stale) — warn and block.
                lastTerminalWarningAt = now
                GameState.shared.postTransientWarning(
                    "JACK IN AND HACK THE TERMINAL FIRST")
                GameState.shared.addLog(
                    "⚠️  Unhacked terminal in this room. Tap door again to leave anyway.")
                HapticsManager.shared.error()
                return
            }
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

    /// Safety timeout: if isPlayerInputBlocked stays true without
    /// .enemyPhaseCompleted firing (e.g. DispatchGroup leak or silent crash in enemy AI),
    /// force-unblock and restore the player's turn so the game doesn't freeze permanently.
    /// Threshold raised 5 → 16s: with the 0.85s per-enemy beat, a big (NG+) room
    /// can legitimately take ~10s, and this must NOT trip mid-phase (which would
    /// hand control to the player while enemies are still taking their turns).
    override func update(_ currentTime: TimeInterval) {
        refreshTraceVisuals()
        if GameState.shared.isInputBlockedByPhase {
            // Budget scales with living enemies: a packed NG+ room's phase
            // (0.7s/enemy + trailing windows) can legitimately exceed a
            // fixed 16s, and tripping mid-phase hands the player control
            // while enemies are still acting. 16s floor preserved.
            let phaseBudget = max(16.0, Double(GameState.shared.enemies.filter { $0.isAlive }.count) * 0.85 + 8.0)
            if inputBlockedSince == nil {
                inputBlockedSince = currentTime
            } else if currentTime - inputBlockedSince! > phaseBudget {
                dlog("[BattleScene] ⚠️ Safety timeout: isPlayerInputBlocked stuck for >16s — force-unblocking")
                playerInputLocked = false
                isEnemyPhaseRunning = false
                // The missed .enemyPhaseCompleted would also have faded the red
                // tint — without this the overlay sticks on screen permanently.
                fadeOutEnemyPhaseTint()
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
        dlog("[BattleScene] enemyPhase started")
        guard playerInputLocked else {
            dlog("[BattleScene] runEnemyPhase called but input is not locked — ignoring")
            return
        }
        // Bug 3 fix: skip enemy phase if no enemies are alive
        if GameState.shared.enemies.filter({ $0.isAlive }).isEmpty {
            dlog("Forge: enemy doing turn — no enemies alive, skipping")
            // Bug 3 fix: call onRoomCleared so the door marker refreshes to DOOR
            GameState.shared.onRoomCleared()
            NotificationCenter.default.post(name: .enemyPhaseCompleted, object: nil)
            return
        }
        dlog("Forge: enemy doing turn")
        isEnemyPhaseRunning = true

        // Trigger GameState's enemy phase — this runs all enemy AI and will call
        // back via notifications (enemyMoved, enemyDied, etc.) as each enemy acts.
        // When it completes it posts .enemyPhaseCompleted to unblock player input.
        GameState.shared.enemyPhase()
    }

    // MARK: - Enemy Attack Visual

    /// Play a clear enemy attack animation: slash line from enemy to player, player flash.
    /// Called when the .playerHit notification is received (during enemy phase).
    func playEnemyAttackEffect(enemyId: UUID, playerId: UUID, damage: Int) {
        // Readability beat: pulse the victim's tile + name the attack in the
        // HUD ticker, THEN land the slash/flash/SFX together 0.3s later.
        // (Damage is already applied by authority — this shifts visuals only,
        // keeping hit SFX/haptics synced with the on-screen impact.)
        pulseVictimTile(playerId: playerId)
        if let foe = GameState.shared.enemies.first(where: { $0.id == enemyId }),
           let victim = GameState.shared.playerTeam.first(where: { $0.id == playerId }) {
            GameState.shared.postTransientWarning("⚠︎ \(foe.name) → \(victim.name)", duration: 1.6)
        }
        run(SKAction.sequence([
            SKAction.wait(forDuration: 0.30),
            SKAction.run { [weak self] in
                self?.showEnemyAttackSlash(fromEnemy: enemyId, toPlayer: playerId)
                self?.playPlayerHitEffect(on: playerId, damage: damage, enemyIdStr: enemyId.uuidString)
            }
        ]))
    }

    // MARK: - Enemy Threat Preview (tap an enemy with no runner selected)
    //
    // Anti-clutter rules (learned from the earlier jumbled attempt):
    //   • everything draws in TILE space inside the map node, in the tile
    //     z-band (2.35) — under every prop, sprite, and HP bar by construction
    //   • only ONE enemy's zone can exist at a time (toggle semantics)
    //   • auto-clears on any other tap, on enemy phase, and on room load
    //   • RANGE truth only — never a target prediction (the AI's actual pick
    //     varies per archetype and a wrong guess is worse than nothing)

    private var threatNodes: [SKNode] = []
    private var threatEnemyId: UUID?

    func clearThreatPreview() {
        guard !threatNodes.isEmpty || threatEnemyId != nil else { return }
        for n in threatNodes { n.removeFromParent() }
        threatNodes = []
        threatEnemyId = nil
    }

    private func showThreatPreview(for enemyId: UUID) {
        clearThreatPreview()
        guard let enemy = GameState.shared.enemies.first(where: { $0.id == enemyId && $0.isAlive }),
              let mapNode = childNode(withName: "TileMap") else { return }
        let tiles = GameState.shared.currentMissionTiles
        guard !tiles.isEmpty else { return }

        // Weapon reach (same table as the dice engine) + a ~2-tile
        // repositioning allowance. Inner band = in reach right now.
        let reach: Int
        switch enemy.equippedWeapon?.type {
        case .pistol:                  reach = 3
        case .smg:                     reach = 5
        case .rifle:                   reach = 8
        case .blade, .unarmed, .none:  reach = 1
        }
        let radius = reach + 2

        for y in tiles.indices {
            for x in tiles[y].indices where tiles[y][x] != TileType.wall.rawValue {
                let d = CombatMechanics.hexDistance(x1: enemy.positionX, y1: enemy.positionY, x2: x, y2: y)
                guard d <= radius else { continue }
                let hex = SKShapeNode(path: TileMap.hexPath(radius: TileMap.hexRadius * 0.92))
                hex.position = TileMap.tileCenter(x: x, y: y)
                hex.zPosition = 2.35
                hex.fillColor = UIColor(red: 1.0, green: 0.18, blue: 0.25,
                                        alpha: d <= reach ? 0.17 : 0.08)
                hex.strokeColor = UIColor(red: 1.0, green: 0.2, blue: 0.27, alpha: 0.30)
                hex.lineWidth = 0.8
                hex.alpha = 0
                mapNode.addChild(hex)
                hex.run(SKAction.fadeIn(withDuration: 0.15))
                threatNodes.append(hex)
            }
        }
        // Pulsing hex ring on the enemy's own tile marks WHOSE zone this is.
        let ring = SKShapeNode(path: TileMap.hexPath(radius: TileMap.hexRadius))
        ring.position = TileMap.tileCenter(x: enemy.positionX, y: enemy.positionY)
        ring.zPosition = 2.36
        ring.fillColor = .clear
        ring.strokeColor = UIColor(red: 1.0, green: 0.25, blue: 0.3, alpha: 0.95)
        ring.lineWidth = 2.5
        ring.glowWidth = 3
        ring.run(SKAction.repeatForever(SKAction.sequence([
            SKAction.scale(to: 1.08, duration: 0.45),
            SKAction.scale(to: 1.0, duration: 0.45),
        ])))
        mapNode.addChild(ring)
        threatNodes.append(ring)
        threatEnemyId = enemyId

        let reachLabel = reach == 1 ? "melee" : "range \(reach)"
        GameState.shared.addLog("⚠️ \(enemy.name) — \(reachLabel) + movement. Red = can be hit next turn. Tap again to dismiss.")
        HapticsManager.shared.buttonTap()
    }

    /// Pre-strike beat: pulse the victim's tile just before the slash lands,
    /// so incoming enemy hits are readable. Tile-space + transient.
    private func pulseVictimTile(playerId: UUID) {
        guard let victim = GameState.shared.playerTeam.first(where: { $0.id == playerId }),
              let mapNode = childNode(withName: "TileMap") else { return }
        let ring = SKShapeNode(path: TileMap.hexPath(radius: TileMap.hexRadius * 0.95))
        ring.position = TileMap.tileCenter(x: victim.positionX, y: victim.positionY)
        ring.zPosition = 2.37
        ring.fillColor = UIColor(red: 1, green: 0.15, blue: 0.2, alpha: 0.22)
        ring.strokeColor = UIColor(red: 1, green: 0.2, blue: 0.25, alpha: 0.9)
        ring.lineWidth = 2.5
        ring.setScale(0.6)
        mapNode.addChild(ring)
        ring.run(SKAction.sequence([
            SKAction.scale(to: 1.05, duration: 0.28),
            SKAction.fadeOut(withDuration: 0.25),
            SKAction.removeFromParent()
        ]))
    }

    // MARK: - Enemy Phase Tint

    /// Subtle red overlay that tints the scene during enemy phase — provides clear
    /// visual feedback that it's not the player's turn.
    private var enemyPhaseTint: SKShapeNode?


    private func fadeInEnemyPhaseTint() {
        clearThreatPreview()
        // Dedupe: a second .enemyPhaseBegan would overwrite the pointer and
        // orphan the first tint node, which could then never be removed.
        childNode(withName: "enemyPhaseTint")?.removeFromParent()
        let tint = SKShapeNode(rectOf: CGSize(width: size.width * 2, height: size.height * 2))
        tint.fillColor = UIColor(red: 0.8, green: 0.0, blue: 0.0, alpha: 0.12)
        tint.strokeColor = .clear
        tint.position = .zero
        tint.zPosition = 80
        tint.alpha = 0
        tint.name = "enemyPhaseTint"
        addChild(tint)
        enemyPhaseTint = tint
        tint.run(SKAction.fadeAlpha(to: 1.0, duration: 0.25))
    }

    private func fadeOutEnemyPhaseTint() {
        guard let tint = enemyPhaseTint else { return }
        tint.run(SKAction.sequence([
            SKAction.fadeAlpha(to: 0.0, duration: 0.3),
            SKAction.removeFromParent()
        ]))
        enemyPhaseTint = nil
    }

    // MARK: - Animations

    /// Brief scene-wide freeze-frame for impact weight (crits/kills). Restored
    /// on a wall-clock timer (DispatchQueue is unaffected by `scene.speed`), so
    /// it always un-freezes. Only invoked for player-paced moments on the
    /// player's turn — never mid enemy-phase, where it would stutter the
    /// staggered turns. The `speed > 0.5` guard stops overlapping freezes from
    /// stacking into a long pause.
    func applyHitStop(_ duration: TimeInterval) {
        guard duration > 0, self.speed > 0.5 else { return }
        self.speed = 0.0
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in self?.speed = 1.0 }
    }

    func playHitEffect(on id: UUID, damage: Int = 0, outcome: String = "") {
        guard let node = characterNodes[id] else { return }
        SpriteManager.shared.animateHit(target: node)
        // Emit spark particles at hit location
        EffectsManager.shared.emitSparks(at: node.position, in: self, count: 14)
        // Floating feedback. A landed hit shows the red damage number; a
        // fully-soaked hit or a miss otherwise plays only a sound (the
        // armor_block / miss_whoosh clip) with nothing on screen, so the
        // player can't tell the shot connected. Show a text cue in those
        // cases too. Spawn offset matches showDamageNumber (+32 above head).
        if damage > 0 {
            EffectsManager.shared.showDamageNumber(damage, at: node.position, in: self)
        } else {
            let spawnAt = CGPoint(x: node.position.x, y: node.position.y + 32)
            switch outcome {
            case "soak":
                EffectsManager.shared.showCombatText("SOAK", at: spawnAt, in: self,
                                                     color: UIColor(hex: "#9DB2C8"), fontSize: 20)
            case "miss":
                EffectsManager.shared.showCombatText("MISS", at: spawnAt, in: self,
                                                     color: UIColor(hex: "#9DB2C8"), fontSize: 20)
            default:
                break
            }
        }
        // Screen shake for enemy hits
        EffectsManager.shared.screenShake(on: self, intensity: 5, duration: 0.2)
        // Update HP label if it's an enemy. `SpriteManager.updateHP` is the
        // single source of truth — it reads the UUID off the SpriteNode and
        // looks up `"hpBarFill_<uuid>"` / `"hpLabel_<uuid>"` directly. The
        // supplementary visual-rebuild block that used to live here was
        // never executing (it looked for the suffixed name before the
        // suffix was applied at creation) and was removed 2026-05-19.
        if let sprite = node as? SpriteNode,
           let enemyId = UUID(uuidString: sprite.enemyId),
           let enemy = GameState.shared.enemies.first(where: { $0.id == enemyId }) {
            SpriteManager.shared.updateHP(on: node, currentHP: enemy.currentHP, maxHP: enemy.maxHP, currentStun: enemy.currentStun, maxStun: enemy.maxStun)
        }
    }

    func playPlayerHitEffect(on id: UUID, damage: Int, enemyIdStr: String? = nil) {
        guard let node = characterNodes[id] else { return }

        // Show attack indicator: slash line from enemy to player + a knockback
        // recoil so the struck unit physically reacts to the blow.
        if let eIdStr = enemyIdStr, let enemyId = UUID(uuidString: eIdStr),
           let enemyNode = characterNodes[enemyId] {
            showAttackSlash(from: enemyNode.position, to: node.position)
            let dx = node.position.x - enemyNode.position.x
            let dy = node.position.y - enemyNode.position.y
            let mag = max(1, hypot(dx, dy))
            let kick = CGVector(dx: dx / mag * 12, dy: dy / mag * 12)
            node.run(SKAction.sequence([
                SKAction.move(by: kick, duration: 0.06),
                SKAction.move(by: CGVector(dx: -kick.dx, dy: -kick.dy), duration: 0.12)
            ]))
        }

        SpriteManager.shared.animateHit(target: node)

        // Impact burst — sparks + a spray of blood + a bright flash pop at the
        // hit so the blow reads with weight, not just a number ticking off.
        EffectsManager.shared.emitSparks(at: node.position, in: self, count: 18)
        EffectsManager.shared.emitBlood(at: node.position, in: self, count: 10)
        let pop = SKShapeNode(circleOfRadius: 10)
        pop.fillColor = .white
        pop.strokeColor = UIColor(hex: "#FFDD66")
        pop.lineWidth = 2
        pop.glowWidth = 8
        pop.position = node.position
        pop.zPosition = 96
        addChild(pop)
        pop.run(SKAction.sequence([
            SKAction.group([SKAction.scale(to: 2.6, duration: 0.18),
                            SKAction.fadeOut(withDuration: 0.20)]),
            SKAction.removeFromParent()
        ]))
        // Show orange floating damage text. Spawn 32pt above the unit so
        // it pops off their head, mirroring showDamageNumber's offset.
        if damage > 0 {
            let spawnAt = CGPoint(x: node.position.x, y: node.position.y + 32)
            EffectsManager.shared.showCombatText("-\(damage)", at: spawnAt, in: self,
                                                 color: UIColor(hex: "#FF8800"), fontSize: 24)
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
        // Shake scales with the hit — a chip feels different from a haymaker.
        EffectsManager.shared.screenShake(on: self,
                                          intensity: CGFloat(min(22, 8 + damage)),
                                          duration: 0.3)
        // Update player HP bar
        if let sprite = node as? SpriteNode,
           !sprite.characterId.isEmpty,
           let charId = UUID(uuidString: sprite.characterId),
           let char = GameState.shared.playerTeam.first(where: { $0.id == charId }) {
            SpriteManager.shared.updateHP(on: node, currentHP: char.currentHP, maxHP: char.maxHP, currentStun: char.currentStun, maxStun: char.maxStun, level: char.level, isPlayer: true)
        }
    }

    /// Play a shield pulse effect on a defending character.
    /// Persistent OVERWATCH indicator — an amber "eye" that floats above the
    /// runner while they're holding fire. Distinct from the DEF shield ring so
    /// the player can tell at a glance who's on overwatch. Removed when
    /// overwatch expires (.overwatchExpired at the start of the next round).
    func showOverwatchMarker(on id: UUID) {
        guard let node = characterNodes[id] else { return }
        node.childNode(withName: "overwatchMarker")?.removeFromParent()   // dedupe

        let marker = SKNode()
        marker.name = "overwatchMarker"
        marker.position = CGPoint(x: 0, y: 32)
        marker.zPosition = 30   // above HP bars (z=20-21), below floating text

        let amber = UIColor(hex: "#FFB000")
        // Eye outline (almond ≈ ellipse) with a dark fill for contrast.
        let eye = SKShapeNode(ellipseOf: CGSize(width: 22, height: 12))
        eye.strokeColor = amber
        eye.lineWidth = 1.6
        eye.glowWidth = 2.0
        eye.fillColor = UIColor.black.withAlphaComponent(0.55)
        marker.addChild(eye)
        // Pupil — scans side to side so it reads as "watching".
        let pupil = SKShapeNode(circleOfRadius: 3.2)
        pupil.fillColor = amber
        pupil.strokeColor = .clear
        pupil.glowWidth = 1.5
        marker.addChild(pupil)

        node.addChild(marker)

        eye.run(SKAction.repeatForever(SKAction.sequence([
            SKAction.fadeAlpha(to: 0.5, duration: 0.8),
            SKAction.fadeAlpha(to: 1.0, duration: 0.8)
        ])))
        pupil.run(SKAction.repeatForever(SKAction.sequence([
            SKAction.moveBy(x: 5, y: 0, duration: 0.7),
            SKAction.moveBy(x: -10, y: 0, duration: 1.4),
            SKAction.moveBy(x: 5, y: 0, duration: 0.7)
        ])))
        // Quick pop-in so the marker reads as "just engaged".
        marker.setScale(0.1)
        marker.run(SKAction.sequence([
            SKAction.scale(to: 1.15, duration: 0.14),
            SKAction.scale(to: 1.0, duration: 0.08)
        ]))
        HapticsManager.shared.selectionChanged()
    }

    /// Remove every overwatch eye marker — called when overwatch expires.
    func clearOverwatchMarkers() {
        for node in characterNodes.values {
            node.childNode(withName: "overwatchMarker")?.removeFromParent()
        }
    }

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
            dlog("[BattleScene] animateEnemyMove: no node found for id=\(id)")
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
        // Refresh depth-z for the new row — players do this after every move
        // but enemies kept their spawn-row z, rendering in front of / behind
        // sprites they'd actually moved past until the node was rebuilt.
        node.zPosition = depthZ(forTileY: toY, isEnemy: true)
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
                // Allow door tiles in BFS so stepping onto connection triggers remains possible.
                let tile = tileMap?.tiles[ny][nx] ?? .floor
                guard isWalkableTile(nx, ny) || tile == .door || tile == .dataTerminal else { continue }
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

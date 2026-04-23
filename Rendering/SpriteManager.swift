import SpriteKit
import UIKit

// MARK: - SpriteState

enum SpriteState {
    case idle
    case walk
    case attack
}

// MARK: - SpriteNode (KVC-compliant wrapper)

/// A SpriteKit node that is key-value coding compliant for tile coordinates and team.
class SpriteNode: SKNode {
    @objc dynamic var tileX: Int = 0
    @objc dynamic var tileY: Int = 0
    @objc dynamic var team: String = ""
    @objc dynamic var characterId: String = ""
    @objc dynamic var enemyId: String = ""
    /// Current animation state for sprite effects.
    var currentState: SpriteState = .idle
    /// Resolved sprite texture key (e.g. "guard", "elite", "samurai") set at creation time.
    /// Used by animateIdle/animateWalk to look up the correct texture cache without
    /// re-parsing the node name or coupling to GameState.
    var spriteTypeKey: String = ""
}

/// Factory for creating sprite nodes and animations.
final class SpriteManager {

    static let shared = SpriteManager()

    // MARK: - Sprite Sheet Texture Cache

    /// Pre-loaded idle textures for each player archetype.
    private var playerIdleTextures: [String: [SKTexture]] = [:]

    /// Pre-loaded walk textures for each player archetype.
    private var playerWalkTextures: [String: [SKTexture]] = [:]

    // MARK: - Enemy Texture Cache

    /// Idle frames for each enemy type (guard, elite, drone, corpmage, medic, boss, mech).
    private var enemyIdleTextures:   [String: [SKTexture]] = [:]
    /// Walk frames for each enemy type.
    private var enemyWalkTextures:   [String: [SKTexture]] = [:]
    /// Attack frames for each enemy type.
    private var enemyAttackTextures: [String: [SKTexture]] = [:]

    /// Maps raw enemy type strings from GameState to the PNG filename prefix.
    private func enemySpriteKey(for type: String) -> String {
        switch type.lowercased() {
        case "guard":                    return "guard"
        case "drone":                    return "drone"
        case "elite":                    return "elite"
        case "mage", "corpmage":         return "corpmage"
        case "medic", "healer":          return "medic"
        case "boss":                     return "boss"
        case "mech":                     return "mech"
        default:                         return "guard"
        }
    }

    /// Accent colour used for the enemy hex ring / shadow when sprite frames exist.
    private func enemyAccentColor(for key: String) -> UIColor {
        switch key {
        case "guard":    return UIColor(hex: "#FF2222")
        case "elite":    return UIColor(hex: "#9955FF")
        case "drone":    return UIColor(hex: "#FF8800")
        case "corpmage": return UIColor(hex: "#00CCFF")
        case "medic":    return UIColor(hex: "#FF44AA")
        case "boss":     return UIColor(hex: "#FF6600")
        case "mech":     return UIColor(hex: "#FFCC00")
        default:         return UIColor(hex: "#FF2222")
        }
    }

    private let playerEmojiMap: [String: String] = [
        "street samurai": "⚔️",
        "samurai": "⚔️",
        "mage": "🧙",
        "decker": "🏹",
        "face": "🛡️"
    ]

    private let playerEmojiFontSize: CGFloat = 32

    private init() {
        loadPlayerSpriteSheet()
        loadEnemySpriteFrames()
    }

    // MARK: - Enemy Sprite Loading

    /// Load individually-named PNG frames for each enemy type from Sprites/frames/.
    /// Files follow the naming convention: {type}_{anim}_{frame}.png
    /// e.g. guard_idle_0.png, boss_attack_1.png
    private func loadEnemySpriteFrames() {
        let enemyTypes = ["guard", "elite", "drone", "corpmage", "medic", "boss", "mech"]
        for eType in enemyTypes {
            var idle:   [SKTexture] = []
            var walk:   [SKTexture] = []
            var attack: [SKTexture] = []
            for i in 0..<4 {
                if let t = loadTexture(named: "\(eType)_idle_\(i).png")   { idle.append(t) }
                if let t = loadTexture(named: "\(eType)_walk_\(i).png")   { walk.append(t) }
            }
            for i in 0..<2 {
                if let t = loadTexture(named: "\(eType)_attack_\(i).png") { attack.append(t) }
            }
            if !idle.isEmpty   { enemyIdleTextures[eType]   = idle   }
            if !walk.isEmpty   { enemyWalkTextures[eType]   = walk   }
            if !attack.isEmpty { enemyAttackTextures[eType] = attack }
        }
        let summary = enemyTypes.map { "\($0): \(enemyIdleTextures[$0]?.count ?? 0)i" }.joined(separator: ", ")
        print("[SpriteManager] Enemy frames loaded — \(summary)")
    }

    /// Load the character spritesheet JPEG from the Sprites/ directory.
    /// SKTexture(imageNamed:) only searches Assets.xcassets, not subdirectories,
    /// so we use path-based loading instead.
    /// Sheet layout: 1200×800, 8 columns × 4 rows.
    /// Columns: Samurai(0-1), Mage(2-3), Decker(4-5), Face(6-7)
    /// Rows (image top→bottom): attack(0), idle(1), walk(2), walk2(3)
    private func loadSpritesheetTexture() -> SKTexture? {
        let filename = "character_spritesheet.jpg"
        // Path 1: Bundle resource URL + Sprites/
        if let resourceURL = Bundle.main.resourceURL {
            let url = resourceURL.appendingPathComponent("Sprites").appendingPathComponent(filename)
            if let image = UIImage(contentsOfFile: url.path) {
                let tex = SKTexture(image: image); tex.filteringMode = .linear; return tex
            }
        }
        // Path 2: resourcePath + /Sprites/
        if let resourcePath = Bundle.main.resourcePath {
            let path = resourcePath + "/Sprites/" + filename
            if let image = UIImage(contentsOfFile: path) {
                let tex = SKTexture(image: image); tex.filteringMode = .linear; return tex
            }
        }
        // Path 3: #file relative — walks up from Rendering/ to ShadowrunGame/Sprites/
        let sourceURL = URL(fileURLWithPath: #file)
        let url = sourceURL
            .deletingLastPathComponent()  // Rendering/
            .deletingLastPathComponent()  // ShadowrunGame/
            .appendingPathComponent("Sprites")
            .appendingPathComponent(filename)
        if let image = UIImage(contentsOfFile: url.path) {
            let tex = SKTexture(image: image); tex.filteringMode = .linear; return tex
        }
        return nil
    }

    /// Load character frames by slicing the spritesheet from Sprites/ directory.
    /// Sheet layout: 1200×800, 8 columns × 4 rows.
    /// Columns: Samurai(0-1), Mage(2-3), Decker(4-5), Face(6-7)
    /// Rows (image top→bottom): header(0), idle(1), walk(2), walk2(3)
    ///
    /// BLEED-IN FIX: Each row's cells contain overflow content from the row above.
    /// The row-above characters are taller than the 200px cell height and their lower
    /// bodies spill into the next row's top pixels. We skip those contaminated pixels
    /// and sample only the clean character content in the lower portion of each cell.
    ///   Row 1 (IDLE):  top 88px is bleed  → sample rows 88-200  (112px clean)
    ///   Row 2 (WALK):  top 61px is bleed  → sample rows 61-200  (139px clean)
    ///   Row 3 (WALK2): top 40px is bleed  → sample rows 40-200  (160px clean)
    private func loadPlayerSpriteSheet() {
        // Prefer individual PNG frames: they are tight-cropped (feet at bottom, no wasted black)
        // which works perfectly with the bottom-anchor sprite positioning system.
        loadPlayerSpriteSheetFromFiles()
        let allLoaded = ["samurai", "mage", "decker", "face"].allSatisfy {
            playerIdleTextures[$0] != nil && playerWalkTextures[$0] != nil
        }
        if allLoaded {
            print("[SpriteManager] Using pre-cropped frame PNGs (preferred path)")
            return
        }

        // Fall back to slicing the spritesheet when individual PNGs aren't available
        // (production builds where #file-relative path doesn't work).
        guard let sheet = loadSpritesheetTexture() else {
            print("[SpriteManager] ERROR: neither frame PNGs nor spritesheet found")
            return
        }

        let cols: CGFloat = 8
        let rows: CGFloat = 4
        let fw: CGFloat = 1.0 / cols      // 0.125 per column
        let sheetH: CGFloat = 800         // spritesheet pixel height

        // Bleed-corrected UV rect: skip contaminated top pixels in each row cell.
        // SK UV: y=0 at image bottom, y=1 at image top (opposite of pixel coords).
        func cleanRect(imageRow r: Int, col: CGFloat) -> CGRect {
            let bleedPx: [Int: CGFloat] = [1: 88, 2: 61, 3: 40]
            let bleed = bleedPx[r] ?? 0
            let cellH = sheetH / rows                           // 200px per row
            let rowBotPx  = CGFloat(r + 1) * cellH              // pixel y of row bottom
            let contentTopPx = CGFloat(r) * cellH + bleed       // first clean pixel
            let contentH  = rowBotPx - contentTopPx             // clean pixel height
            let uvBottom  = 1.0 - rowBotPx / sheetH             // UV y of row bottom
            let uvHeight  = contentH / sheetH                   // UV height of clean region
            return CGRect(x: col * fw, y: uvBottom, width: fw, height: uvHeight)
        }

        // Character column start (0-indexed): each character spans 2 columns
        let charCols: [(String, Int)] = [("samurai", 0), ("mage", 2), ("decker", 4), ("face", 6)]

        for (archetype, startCol) in charCols {
            var idleFrames: [SKTexture] = []
            var walkFrames: [SKTexture] = []

            for frameIdx in 0..<2 {
                // Samurai col 0 has row-label text ("IDLE", "WALK") in the left margin.
                // Use col 1 instead for samurai frame 0 to get a clean sprite.
                let col = (archetype == "samurai" && frameIdx == 0) ? startCol + 1 : startCol + frameIdx
                let colF = CGFloat(col)

                // Idle = image row 1 (bleed-corrected)
                let idleTex = SKTexture(rect: cleanRect(imageRow: 1, col: colF), in: sheet)
                idleTex.filteringMode = .linear
                idleFrames.append(idleTex)

                // Walk = image rows 2 and 3 (bleed-corrected, 2 walk frames per column variant)
                for walkRow in [2, 3] {
                    let walkTex = SKTexture(rect: cleanRect(imageRow: walkRow, col: colF), in: sheet)
                    walkTex.filteringMode = .linear
                    walkFrames.append(walkTex)
                }
            }

            playerIdleTextures[archetype] = idleFrames
            playerWalkTextures[archetype] = walkFrames
        }

        let loaded = playerIdleTextures.map { "\($0.key): \($0.value.count)i/\(playerWalkTextures[$0.key]?.count ?? 0)w" }.joined(separator: ", ")
        print("[SpriteManager] Spritesheet loaded (bleed-corrected) — \(loaded)")
    }

    /// Fallback: load individual PNG files from Sprites/frames/ bundle directory.
    private func loadPlayerSpriteSheetFromFiles() {
        let archetypes = ["samurai", "mage", "decker", "face"]
        for archetype in archetypes {
            var idleTextures: [SKTexture] = []
            var walkTextures: [SKTexture] = []
            for frame in 0..<2 {
                if let t = loadTexture(named: "\(archetype)_idle_\(frame).png") { idleTextures.append(t) }
            }
            for frame in 0..<4 {
                if let t = loadTexture(named: "\(archetype)_walk_\(frame).png") { walkTextures.append(t) }
            }
            if !idleTextures.isEmpty { playerIdleTextures[archetype] = idleTextures }
            if !walkTextures.isEmpty { playerWalkTextures[archetype] = walkTextures }
        }
        let loaded = playerIdleTextures.map { "\($0.key): \($0.value.count)" }.joined(separator: ", ")
        print("[SpriteManager] File fallback loaded: \(loaded.isEmpty ? "NONE" : loaded)")
    }

    private func loadTexture(named: String) -> SKTexture? {
        // ── Path 1: Bundle.main subdirectory Sprites/frames/ (production app bundle) ─────
        if let resourceURL = Bundle.main.resourceURL {
            let framesURL = resourceURL
                .appendingPathComponent("Sprites")
                .appendingPathComponent("frames")
                .appendingPathComponent(named)
            if let image = UIImage(contentsOfFile: framesURL.path) {
               let tex = SKTexture(image: image)
                tex.filteringMode = .nearest
                return tex
            }
        }

        // ── Path 2: root of bundle (some Xcode configurations) ────────────────────────
        if let url = Bundle.main.url(forResource: named, withExtension: nil),
           let image = UIImage(contentsOfFile: url.path) {
           let tex = SKTexture(image: image)
            tex.filteringMode = .nearest
            return tex
        }

        // ── Path 3: resourcePath/Sprites/frames/ ─────────────────────────────────────
        if let resourcePath = Bundle.main.resourcePath {
            let fullPath = resourcePath + "/Sprites/frames/" + named
            if let image = UIImage(contentsOfFile: fullPath) {
               let tex = SKTexture(image: image)
                tex.filteringMode = .nearest
                return tex
            }
        }

        // ── Path 4: Project directory via #file (Xcode Simulator dev workflow) ────────
        // SpriteManager.swift is at ShadowrunGame/Rendering/SpriteManager.swift
        // Go up two directories: Rendering/ → ShadowrunGame/ → Sprites/frames/
        let sourceURL = URL(fileURLWithPath: #file)
        let projectFramesURL = sourceURL
            .deletingLastPathComponent()  // Rendering/
            .deletingLastPathComponent()  // ShadowrunGame/
            .appendingPathComponent("Sprites")
            .appendingPathComponent("frames")
            .appendingPathComponent(named)
        if let image = UIImage(contentsOfFile: projectFramesURL.path) {
           let tex = SKTexture(image: image)
            tex.filteringMode = .nearest
            return tex
        }

        print("[SpriteManager] WARNING: Could not load texture '\(named)' from any path")
        return nil
    }

    /// Load a tile sprite texture from Sprites/tiles/ directory.
    /// Tries bundle paths first, then project directory via #file.
    func loadTileTexture(named: String) -> SKTexture? {
        let subdir = "tiles"
        // ── Bundle paths ─────────────────────────────────────────────────────────────
        if let resourceURL = Bundle.main.resourceURL {
            let url = resourceURL.appendingPathComponent("Sprites").appendingPathComponent(subdir).appendingPathComponent(named)
            if let image = UIImage(contentsOfFile: url.path) {
                let tex = SKTexture(image: image); tex.filteringMode = .linear; return tex
            }
        }
        if let resourcePath = Bundle.main.resourcePath {
            let path = resourcePath + "/Sprites/\(subdir)/" + named
            if let image = UIImage(contentsOfFile: path) {
                let tex = SKTexture(image: image); tex.filteringMode = .linear; return tex
            }
        }
        // ── Project directory (#file) ────────────────────────────────────────────────
        let sourceURL = URL(fileURLWithPath: #file)
        let projectURL = sourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sprites")
            .appendingPathComponent(subdir)
            .appendingPathComponent(named)
        if let image = UIImage(contentsOfFile: projectURL.path) {
            let tex = SKTexture(image: image); tex.filteringMode = .linear; return tex
        }
        return nil
    }

    /// Get the archetype key used in our frame filenames.
    private func archetypeKey(for type: String) -> String {
        switch type.lowercased() {
        case "street samurai", "samurai": return "samurai"
        case "mage":                       return "mage"
        case "decker":                     return "decker"
        case "face":                       return "face"
        default:                            return "samurai"
        }
    }

    // MARK: - Tile Sprites

    /// Create a tile sprite for the given tile type and grid position.
    func createTile(type: Int, x: Int, y: Int) -> SKNode {
        let tileType = TileType(rawValue: type) ?? .floor

        let node: SKNode

        switch tileType {
        case .wall:
            let rect = SKShapeNode(rectOf: CGSize(width: TileMap.tileSize - 1, height: TileMap.tileSize - 1))
            rect.fillColor = UIColor(hex: "#080812")
            rect.strokeColor = UIColor(hex: "#2222AA").withAlphaComponent(0.4)
            rect.lineWidth = 1
            rect.zPosition = 0
            node = rect

        case .extraction:
            let rect = SKShapeNode(rectOf: CGSize(width: TileMap.tileSize - 2, height: TileMap.tileSize - 2))
            rect.fillColor = UIColor(hex: "#003311").withAlphaComponent(0.5)
            rect.strokeColor = UIColor(hex: "#00FF88")
            rect.lineWidth = 2
            rect.zPosition = 0
            node = rect

            let pulse = SKAction.sequence([
                SKAction.fadeAlpha(to: 0.5, duration: 0.6),
                SKAction.fadeAlpha(to: 1.0, duration: 0.6)
            ])
            rect.run(SKAction.repeatForever(pulse))

        case .door:
            let rect = SKShapeNode(rectOf: CGSize(width: TileMap.tileSize - 1, height: TileMap.tileSize - 1))
            rect.fillColor = UIColor(hex: "#1A0E00")
            rect.strokeColor = UIColor(hex: "#FF6600").withAlphaComponent(0.8)
            rect.lineWidth = 2
            rect.zPosition = 0
            node = rect

        case .cover:
            let rect = SKShapeNode(rectOf: CGSize(width: TileMap.tileSize - 1, height: TileMap.tileSize - 1))
            rect.fillColor = UIColor(hex: "#111122")
            rect.strokeColor = UIColor(hex: "#444466").withAlphaComponent(0.5)
            rect.lineWidth = 1
            rect.zPosition = 0
            node = rect

        default:
            let rect = SKShapeNode(rectOf: CGSize(width: TileMap.tileSize - 1, height: TileMap.tileSize - 1))
            rect.fillColor = UIColor(hex: "#0A0A14")
            rect.strokeColor = UIColor(hex: "#18182A").withAlphaComponent(0.8)
            rect.lineWidth = 0.5
            rect.zPosition = 0
            node = rect
        }

        node.name = "tile_\(x)_\(y)"
        node.position = TileMap.tileCenter(x: x, y: y)
        return node
    }

    // MARK: - Texture Cropping

    /// Crop a texture to its actual character bounding box using alpha sampling.
    /// Returns a new texture cropped to the non-transparent region, or the original
    /// if the bounding box can't be determined.
    /// The crop window is configured for the SKCropNode coordinate system where
    /// (0,0)=bottom-left, (1,1)=top-right of the UNROTATED texture.
    func cropToCharacterBounds(_ texture: SKTexture) -> (texture: SKTexture, cropRect: CGRect) {
        let cgImage = texture.cgImage()
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)

        guard w > 0, h > 0 else { return (texture, CGRect(x: 0, y: 0, width: 1, height: 1)) }

        // Sample alpha channel to find non-transparent bounds.
        // For performance, sample every 4th pixel on each axis.
        let step = 4
        var minX = Int(w), minY = Int(h), maxX = 0, maxY = 0

        guard let dataProvider = cgImage.dataProvider,
              let data = dataProvider.data,
              let ptr = CFDataGetBytePtr(data) else {
            // Fallback: crop the 75×400 frame by trimming top/bottom ~8% each using
            // CGImage.cropping(to:) so the returned texture is already cropped and
            // will display at correct proportions (not squashed).
            let safeCropY = Int(h * 0.08)
            let safeCropHeight = Int(h * 0.84)
            let safeCropRect = CGRect(x: 0, y: safeCropY, width: Int(w), height: safeCropHeight)
            if let croppedCG = cgImage.cropping(to: safeCropRect) {
                let fallbackTex = SKTexture(cgImage: croppedCG)
                fallbackTex.filteringMode = .nearest
                return (fallbackTex, CGRect(x: 0, y: 0.08, width: 1, height: 0.84))
            }
            return (texture, CGRect(x: 0, y: 0, width: 1, height: 1))
        }

        let bytesPerPixel = cgImage.bitsPerPixel / 8
        let bytesPerRow = cgImage.bytesPerRow

        for y in stride(from: 0, to: Int(h), by: step) {
            for x in stride(from: 0, to: Int(w), by: step) {
                let byteOffset = y * bytesPerRow + x * bytesPerPixel
                let alpha = ptr[byteOffset + 3]  // RGBA: R=0, G=1, B=2, A=3
                if alpha > 10 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }

        // Expand slightly to avoid cutting off anti-aliased edge pixels.
        let pad = 2
        minX = max(0, minX - pad); minY = max(0, minY - pad)
        maxX = min(Int(w), maxX + pad); maxY = min(Int(h), maxY + pad)

        guard maxX > minX && maxY > minY else {
            // No alpha found — use full frame.
            return (texture, CGRect(x: 0, y: 0, width: 1, height: 1))
        }

        // Convert to normalized SKCropNode coordinates: (0,0)=bottom-left, (1,1)=top-right.
        // texture.y = 1.0 - maxY/h gives the bottom of the crop in SK coordinates.
        let cropRect = CGRect(
            x: CGFloat(minX) / w,
            y: 1.0 - CGFloat(maxY) / h,
            width:  CGFloat(maxX - minX) / w,
            height: CGFloat(maxY - minY) / h
        )

        // Create the cropped texture.
        let croppedImage = cgImage.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
        guard let finalCGImage = croppedImage else { return (texture, CGRect(x: 0, y: 0, width: 1, height: 1)) }
        let croppedTex = SKTexture(cgImage: finalCGImage)
        croppedTex.filteringMode = .nearest

        return (croppedTex, cropRect)
    }

    // MARK: - Character Sprites

    /// Create a character sprite. type: archetype string; team: "player" or "enemy"
    /// level: pass for player sprites to display correctly; defaults to 1 for enemies
    func createCharacter(type: String, team: String, x: Int, y: Int, name: String = "", level: Int = 1) -> SpriteNode {
        let container = SpriteNode()
        container.tileX = x
        container.tileY = y
        container.team = team
        container.name = "character_\(type)"
        // Position sprite at the center of its tile in scene space.
        // The TileMap node is centered at mapOrigin in the scene; tiles are at
        // mapOrigin + (tileX*tileSize + tileSize/2, tileY*tileSize + tileSize/2).
        // We pass raw tile coords and the caller (BattleScene) adds mapOrigin.
        // Since SpriteManager doesn't know mapOrigin, we store tileX/tileY and
        // let BattleScene update position after centering, OR we position
        // relative to the map origin. The safest approach: store tileX/tileY
        // and let animateMove (which IS called for movement) set position.
        // For initial placement, we use raw tile coords — BattleScene.placeCharacter
        // will override position after centering is applied.
        // Actually: animateMove is what sets final position. For now, just store
        // the tile coords; the sprite will appear at (0,0) until animateMove is called.
        // Initial position using correct hex grid math. BattleScene.placeCharacter/placeEnemy
        // will override this with tileCenter(x,y) + mapOrigin for final scene placement.
        container.position = TileMap.tileCenter(x: x, y: y)
        container.alpha = 1.0
        container.isHidden = false

        // ── Guaranteed-visible colored base hex ───────────────────────────────
        // A FILLED, OPAQUE hex under the character ensures SOMETHING is always
        // visible on this tile, even if texture loading silently fails. Player
        // hexes are cyan/archetype-tinted; enemy hexes are red-tinted. zPosition
        // places this just above the floor (0.1) but below sprite art (z=10).
        // Uses hexRadius*0.7 so the base overlaps clearly with the tile outline
        // while leaving the tile's neon border visible at the edge.
        let teamHex = SKShapeNode(path: TileMap.hexPath(radius: TileMap.hexRadius * 0.82))
        teamHex.fillColor = team == "player"
            ? UIColor(hex: "#00FF9D").withAlphaComponent(0.92)
            : UIColor(hex: "#FF4A4A").withAlphaComponent(0.92)
        teamHex.strokeColor = team == "player"
            ? UIColor(hex: "#D7FFF0")
            : UIColor(hex: "#FFE0E0")
        teamHex.lineWidth = 2.6
        teamHex.glowWidth = 6.0
        teamHex.position = .zero
        teamHex.zPosition = 0.25
        teamHex.name = "characterTeamHex"
        container.addChild(teamHex)

        // ── Guaranteed-visible identity label ───────────────────────────────
        // Large high-contrast letter/initial floats above the tile. Even if the
        // sprite PNG fails to load AND the team hex is somehow hidden, the user
        // will still see a single-letter marker on each character's tile.
        let initial: String = {
            if team == "enemy" { return String(type.prefix(1).uppercased()) }
            let archKey = archetypeKey(for: type)
            switch archKey {
            case "samurai": return "S"
            case "mage":    return "M"
            case "decker":  return "D"
            case "face":    return "F"
            default:         return String(type.prefix(1).uppercased())
            }
        }()
        let idLabel = SKLabelNode(text: initial)
        idLabel.fontName = "Helvetica-Bold"
        idLabel.fontSize = 22
        idLabel.fontColor = team == "player"
            ? UIColor(hex: "#04150F")
            : UIColor(hex: "#240404")
        idLabel.verticalAlignmentMode = .center
        idLabel.horizontalAlignmentMode = .center
        idLabel.position = .zero
        idLabel.zPosition = 0.35
        idLabel.name = "characterInitial"
        container.addChild(idLabel)

        // Player = cyan/green, enemy color varies by archetype
        let baseColor: UIColor
        if team == "player" {
            baseColor = UIColor(hex: "#00FF88")
        } else {
            switch type.lowercased() {
            case "guard":   baseColor = UIColor(hex: "#FF4444")
            case "drone":   baseColor = UIColor(hex: "#FF8800")
            case "elite":   baseColor = UIColor(hex: "#CC00FF")
            case "mage":    baseColor = UIColor(hex: "#00CCFF")
            default:        baseColor = UIColor(hex: "#FF3333")
            }
        }

        let presenceMarker = SKShapeNode(circleOfRadius: team == "player" ? 10 : 9)
        presenceMarker.fillColor = baseColor.withAlphaComponent(0.95)
        presenceMarker.strokeColor = UIColor.white.withAlphaComponent(0.85)
        presenceMarker.lineWidth = 1.6
        presenceMarker.glowWidth = 4.0
        presenceMarker.position = CGPoint(x: 0, y: 4)
        presenceMarker.zPosition = 1.4
        presenceMarker.name = "presenceMarker"
        container.addChild(presenceMarker)

        if team == "player" {
            let playerColor: UIColor
            switch type.lowercased() {
            case "street samurai": playerColor = UIColor(hex: "#FF6633")
            case "mage":          playerColor = UIColor(hex: "#6699FF")
            case "decker":        playerColor = UIColor(hex: "#00DDFF")
            case "face":          playerColor = UIColor(hex: "#FFCC00")
            default:               playerColor = UIColor(hex: "#00FF88")
            }

            // Player floor accent — a thin colored hex OUTLINE at tile center (no fill)
            // that sits BELOW the sprite (z=0.5). Marks the occupied tile with the
            // character's accent color without obscuring the sprite.
            // Attached to the container (not the sprite) so character x-flips
            // (samurai mirror) don't translate this outline.
            let floorRing = SKShapeNode(path: TileMap.hexPath(radius: TileMap.hexRadius - 3))
            floorRing.fillColor = .clear
            floorRing.strokeColor = playerColor.withAlphaComponent(0.70)
            floorRing.lineWidth = 1.5
            floorRing.glowWidth = 3.0
            floorRing.position = CGPoint(x: 0, y: 0)
            floorRing.zPosition = 0.5                  // below sprite (sprite at z=2)
            floorRing.name = "playerFloorGlow"
            container.addChild(floorRing)
            floorRing.run(SKAction.repeatForever(SKAction.sequence([
                SKAction.fadeAlpha(to: 0.40, duration: 1.2),
                SKAction.fadeAlpha(to: 0.80, duration: 1.2)
            ])))

            // Player sprite — use spritesheet texture if available, else procedural fallback
            let archKey = archetypeKey(for: type)
            container.spriteTypeKey = archKey  // stored for animate() lookups
            if let idleFrames = playerIdleTextures[archKey], let tex = idleFrames.first {
                // Per-archetype target display height (pt). Chosen so the character's
                // torso/head sits comfortably inside the hex tile (hex height ≈ 56pt).
                // Slightly taller so the full sprite spans from tile-bottom up past
                // tile-top (heroic scale), but not so tall it clips into adjacent tiles.
                let targetH: CGFloat
                switch archKey {
                case "samurai": targetH = 70
                case "mage":    targetH = 78
                case "decker":  targetH = 70
                case "face":    targetH = 78
                default:        targetH = 70
                }
                let spriteNode = SKSpriteNode(texture: tex)
                let scale = targetH / spriteNode.size.height
                spriteNode.setScale(scale)
                // Bottom-anchor: sprite's feet sit exactly at anchor position (0, -20),
                // which is the lower portion of the hex tile. Body then rises straight up,
                // which is the correct grounded look for a tactical combatant.
                spriteNode.anchorPoint = CGPoint(x: 0.5, y: 0.0)
                // Samurai art is rear-facing; flip horizontally so they face forward.
                if archKey == "samurai" {
                    spriteNode.xScale = -scale
                }
                // Position feet just below tile center so the character stands ON the hex.
                spriteNode.position = CGPoint(x: 0, y: -18)
                spriteNode.zPosition = 10   // well above floor ring (0.5) and all tile art
                spriteNode.name = "characterSprite"
                container.addChild(spriteNode)

                // Animate idle: swap between the 2 idle frames.
                if idleFrames.count >= 2 {
                    let idleAnim = SKAction.animate(with: idleFrames, timePerFrame: 0.5,
                                                    resize: true, restore: false)
                    spriteNode.run(SKAction.repeatForever(idleAnim), withKey: "idle")
                }
            } else {

            // ── FALLBACK procedural sprites (used when spritesheet fails to load) ──
            switch archKey {

            case "samurai":
                // ── STREET SAMURAI ─────────────────────────────────────
                // Isometric 3/4 dark battle-armor, massive red energy katana, glowing visor
                // Wide armored boots
                let boots = SKShapeNode(rectOf: CGSize(width: 16, height: 8), cornerRadius: 2)
                boots.fillColor = UIColor(hex: "#1a1a2e")
                boots.strokeColor = UIColor(hex: "#FF4422")
                boots.lineWidth = 1.0
                boots.position = CGPoint(x: 0, y: -14)
                boots.zPosition = 1
                container.addChild(boots)

                // Armored body — hexagonal torso silhouette
                let samBody = SKShapeNode()
                let sbPath = CGMutablePath()
                sbPath.move(to: CGPoint(x: -9, y: -8))
                sbPath.addLine(to: CGPoint(x: 9, y: -8))
                sbPath.addLine(to: CGPoint(x: 11, y: 2))
                sbPath.addLine(to: CGPoint(x: 8, y: 8))
                sbPath.addLine(to: CGPoint(x: -8, y: 8))
                sbPath.addLine(to: CGPoint(x: -11, y: 2))
                sbPath.closeSubpath()
                samBody.path = sbPath
                samBody.fillColor = UIColor(hex: "#0a0e1a")
                samBody.strokeColor = UIColor(hex: "#FF5533")
                samBody.lineWidth = 1.8
                samBody.glowWidth = 2.5
                samBody.zPosition = 2
                container.addChild(samBody)

                // Chest armor plate — central diamond
                let chestPlate = SKShapeNode()
                let cpPath = CGMutablePath()
                cpPath.move(to: CGPoint(x: 0, y: 6))
                cpPath.addLine(to: CGPoint(x: 6, y: 0))
                cpPath.addLine(to: CGPoint(x: 0, y: -4))
                cpPath.addLine(to: CGPoint(x: -6, y: 0))
                cpPath.closeSubpath()
                chestPlate.path = cpPath
                chestPlate.fillColor = UIColor(hex: "#1a0808")
                chestPlate.strokeColor = UIColor(hex: "#FF3300").withAlphaComponent(0.8)
                chestPlate.lineWidth = 1.2
                chestPlate.zPosition = 2.5
                container.addChild(chestPlate)

                // Shoulder armor pads — wider, angular
                for xOff: CGFloat in [-12, 12] {
                    let sp = SKShapeNode()
                    let spPath = CGMutablePath()
                    let sx: CGFloat = xOff > 0 ? 1 : -1
                    spPath.move(to: CGPoint(x: 0, y: -3))
                    spPath.addLine(to: CGPoint(x: sx * 5, y: -5))
                    spPath.addLine(to: CGPoint(x: sx * 6, y: 2))
                    spPath.addLine(to: CGPoint(x: 0, y: 4))
                    spPath.closeSubpath()
                    sp.path = spPath
                    sp.fillColor = UIColor(hex: "#0d1020")
                    sp.strokeColor = UIColor(hex: "#FF5533")
                    sp.lineWidth = 1.2
                    sp.position = CGPoint(x: xOff * 0.4, y: 2)
                    sp.zPosition = 2
                    container.addChild(sp)
                }

                // Helmet — angular, battle-worn
                let helmet = SKShapeNode()
                let hPath2 = CGMutablePath()
                hPath2.move(to: CGPoint(x: -7, y: 0))
                hPath2.addLine(to: CGPoint(x: 7, y: 0))
                hPath2.addLine(to: CGPoint(x: 6, y: 8))
                hPath2.addLine(to: CGPoint(x: 0, y: 10))
                hPath2.addLine(to: CGPoint(x: -6, y: 8))
                hPath2.closeSubpath()
                helmet.path = hPath2
                helmet.fillColor = UIColor(hex: "#0a0e1a")
                helmet.strokeColor = UIColor(hex: "#FF5533")
                helmet.lineWidth = 1.5
                helmet.position = CGPoint(x: 0, y: 10)
                helmet.zPosition = 3
                container.addChild(helmet)

                // Visor — glowing red-orange slit
                let samVisor = SKShapeNode(rectOf: CGSize(width: 12, height: 2.5), cornerRadius: 0.5)
                samVisor.fillColor = UIColor(hex: "#FF2200")
                samVisor.strokeColor = UIColor(hex: "#FF6600")
                samVisor.lineWidth = 0.8
                samVisor.glowWidth = 6.0
                samVisor.position = CGPoint(x: 0, y: 14)
                samVisor.zPosition = 4
                container.addChild(samVisor)

                // Energy Katana — large diagonal blade crossing body (ref image signature element)
                // Blade body — wide, diagonal, bright red energy
                let blade = SKShapeNode()
                let bladePath = CGMutablePath()
                bladePath.move(to: CGPoint(x: -4, y: -18))   // blade tip bottom-left
                bladePath.addLine(to: CGPoint(x: 0, y: -20))
                bladePath.addLine(to: CGPoint(x: 22, y: 14))  // blade tip top-right
                bladePath.addLine(to: CGPoint(x: 18, y: 16))
                bladePath.closeSubpath()
                blade.path = bladePath
                blade.fillColor = UIColor(hex: "#FF2200").withAlphaComponent(0.85)
                blade.strokeColor = UIColor(hex: "#FF6600")
                blade.lineWidth = 1.0
                blade.glowWidth = 8.0
                blade.zPosition = 5
                container.addChild(blade)

                // Blade core highlight — brighter center
                let bladeCore = SKShapeNode()
                let bcPath = CGMutablePath()
                bcPath.move(to: CGPoint(x: -1, y: -18))
                bcPath.addLine(to: CGPoint(x: 20, y: 15))
                bladeCore.path = bcPath
                bladeCore.strokeColor = UIColor(hex: "#FFCC00")
                bladeCore.lineWidth = 1.5
                bladeCore.glowWidth = 4.0
                bladeCore.zPosition = 5.5
                container.addChild(bladeCore)

                // Blade pulse animation
                let bladePulse = SKAction.sequence([
                    SKAction.run { blade.glowWidth = 8.0 },
                    SKAction.wait(forDuration: 0.4),
                    SKAction.run { blade.glowWidth = 12.0 },
                    SKAction.wait(forDuration: 0.4)
                ])
                blade.run(SKAction.repeatForever(bladePulse))

            case "mage":
                // ── PLAYER MAGE ────────────────────────────────────────
                // Deep purple robe, huge orbital ring on ground, floating orbs
                // Wide robe base — flows to ground
                let robeFull = SKShapeNode()
                let rfPath = CGMutablePath()
                rfPath.move(to: CGPoint(x: -4, y: -16))
                rfPath.addLine(to: CGPoint(x: 4, y: -16))
                rfPath.addLine(to: CGPoint(x: 11, y: -4))
                rfPath.addLine(to: CGPoint(x: 10, y: 4))
                rfPath.addLine(to: CGPoint(x: 6, y: 8))
                rfPath.addLine(to: CGPoint(x: -6, y: 8))
                rfPath.addLine(to: CGPoint(x: -10, y: 4))
                rfPath.addLine(to: CGPoint(x: -11, y: -4))
                rfPath.closeSubpath()
                robeFull.path = rfPath
                robeFull.fillColor = UIColor(hex: "#1a0535")
                robeFull.strokeColor = UIColor(hex: "#8833FF")
                robeFull.lineWidth = 1.8
                robeFull.zPosition = 1
                container.addChild(robeFull)

                // Robe inner folds — purple cloth lines
                for xOff: CGFloat in [-4, 0, 4] {
                    let fold = SKShapeNode()
                    let foldP = CGMutablePath()
                    foldP.move(to: CGPoint(x: xOff, y: -14))
                    foldP.addLine(to: CGPoint(x: xOff * 0.6, y: 4))
                    fold.path = foldP
                    fold.strokeColor = UIColor(hex: "#6600CC").withAlphaComponent(0.5)
                    fold.lineWidth = 0.7
                    fold.zPosition = 1.5
                    container.addChild(fold)
                }

                // Hood — deep pointed
                let hood2 = SKShapeNode()
                let hoodP = CGMutablePath()
                hoodP.move(to: CGPoint(x: -8, y: 8))
                hoodP.addLine(to: CGPoint(x: 8, y: 8))
                hoodP.addLine(to: CGPoint(x: 6, y: 14))
                hoodP.addLine(to: CGPoint(x: 0, y: 20))
                hoodP.addLine(to: CGPoint(x: -6, y: 14))
                hoodP.closeSubpath()
                hood2.path = hoodP
                hood2.fillColor = UIColor(hex: "#0d0220")
                hood2.strokeColor = UIColor(hex: "#9944FF")
                hood2.lineWidth = 1.5
                hood2.zPosition = 3
                container.addChild(hood2)

                // Glowing purple eyes deep in hood shadow
                for xOff: CGFloat in [-2.5, 2.5] {
                    let mageEye = SKShapeNode(circleOfRadius: 2.2)
                    mageEye.fillColor = UIColor(hex: "#CC44FF")
                    mageEye.strokeColor = UIColor(hex: "#FF00FF")
                    mageEye.lineWidth = 0.5
                    mageEye.glowWidth = 5.0
                    mageEye.position = CGPoint(x: xOff, y: 13)
                    mageEye.zPosition = 5
                    container.addChild(mageEye)
                }

                // Large orbital ring on ground (ref image dominant element)
                let orbitalRing = SKShapeNode(circleOfRadius: 18)
                orbitalRing.fillColor = UIColor(hex: "#6600CC").withAlphaComponent(0.12)
                orbitalRing.strokeColor = UIColor(hex: "#AA44FF")
                orbitalRing.lineWidth = 2.5
                orbitalRing.glowWidth = 6.0
                orbitalRing.position = CGPoint(x: 0, y: -10)
                orbitalRing.zPosition = 0.5
                container.addChild(orbitalRing)

                let orbitPulse = SKAction.sequence([
                    SKAction.group([
                        SKAction.scale(to: 1.08, duration: 1.0),
                        SKAction.run { orbitalRing.glowWidth = 8.0 }
                    ]),
                    SKAction.group([
                        SKAction.scale(to: 1.0, duration: 1.0),
                        SKAction.run { orbitalRing.glowWidth = 6.0 }
                    ])
                ])
                orbitalRing.run(SKAction.repeatForever(orbitPulse))

                // Inner orbital ring — rotating
                let innerOrbit = SKShapeNode(circleOfRadius: 12)
                innerOrbit.fillColor = .clear
                innerOrbit.strokeColor = UIColor(hex: "#DD88FF").withAlphaComponent(0.6)
                innerOrbit.lineWidth = 1.5
                innerOrbit.position = CGPoint(x: 0, y: -10)
                innerOrbit.zPosition = 0.6
                container.addChild(innerOrbit)
                innerOrbit.run(SKAction.repeatForever(SKAction.rotate(byAngle: .pi * 2, duration: 3.0)))

                // 3 orbiting energy orbs
                let mageOrbitR: CGFloat = 14
                for i in 0..<3 {
                    let startAngle = CGFloat(i) * (.pi * 2 / 3)
                    let orb = SKShapeNode(circleOfRadius: 3)
                    orb.fillColor = UIColor(hex: "#CC44FF").withAlphaComponent(0.9)
                    orb.strokeColor = UIColor(hex: "#FF00FF")
                    orb.lineWidth = 0.8
                    orb.glowWidth = 5.0
                    orb.position = CGPoint(x: cos(startAngle) * mageOrbitR, y: -10 + sin(startAngle) * mageOrbitR)
                    orb.zPosition = 2.5
                    container.addChild(orb)
                    let orbPath2 = CGMutablePath()
                    orbPath2.addEllipse(in: CGRect(x: -mageOrbitR, y: -10 - mageOrbitR, width: mageOrbitR * 2, height: mageOrbitR * 2))
                    let orbitAction = SKAction.follow(orbPath2, asOffset: false, orientToPath: false, duration: 2.5 + Double(i) * 0.3)
                    orb.run(SKAction.repeatForever(orbitAction))
                }

            case "decker":
                // ── DECKER ─────────────────────────────────────────────
                // Dark tactical vest, glowing cyan cyberdeck, crackling energy
                // Lower body / legs in tactical gear
                let tackleLegs = SKShapeNode(rectOf: CGSize(width: 12, height: 10), cornerRadius: 2)
                tackleLegs.fillColor = UIColor(hex: "#0d1520")
                tackleLegs.strokeColor = UIColor(hex: "#006688")
                tackleLegs.lineWidth = 0.8
                tackleLegs.position = CGPoint(x: 0, y: -13)
                tackleLegs.zPosition = 1
                container.addChild(tackleLegs)

                // Tactical vest body
                let vest = SKShapeNode()
                let vPath = CGMutablePath()
                vPath.move(to: CGPoint(x: -8, y: -7))
                vPath.addLine(to: CGPoint(x: 8, y: -7))
                vPath.addLine(to: CGPoint(x: 9, y: 4))
                vPath.addLine(to: CGPoint(x: 7, y: 8))
                vPath.addLine(to: CGPoint(x: -7, y: 8))
                vPath.addLine(to: CGPoint(x: -9, y: 4))
                vPath.closeSubpath()
                vest.path = vPath
                vest.fillColor = UIColor(hex: "#0a1525")
                vest.strokeColor = UIColor(hex: "#00BBDD")
                vest.lineWidth = 1.5
                vest.zPosition = 2
                container.addChild(vest)

                // Vest circuit traces
                for yOff: CGFloat in [-4, 0, 4] {
                    let trace = SKShapeNode()
                    let tp = CGMutablePath()
                    tp.move(to: CGPoint(x: -6, y: yOff))
                    tp.addLine(to: CGPoint(x: -2, y: yOff))
                    tp.addLine(to: CGPoint(x: -2, y: yOff + 2))
                    tp.move(to: CGPoint(x: 2, y: yOff))
                    tp.addLine(to: CGPoint(x: 6, y: yOff))
                    trace.path = tp
                    trace.strokeColor = UIColor(hex: "#00DDFF").withAlphaComponent(0.6)
                    trace.lineWidth = 0.6
                    trace.zPosition = 2.5
                    container.addChild(trace)
                }

                // Tactical helmet / hood
                let deckerHelm = SKShapeNode()
                let dhPath = CGMutablePath()
                dhPath.move(to: CGPoint(x: -7, y: 8))
                dhPath.addLine(to: CGPoint(x: 7, y: 8))
                dhPath.addLine(to: CGPoint(x: 6, y: 14))
                dhPath.addLine(to: CGPoint(x: 0, y: 16))
                dhPath.addLine(to: CGPoint(x: -6, y: 14))
                dhPath.closeSubpath()
                deckerHelm.path = dhPath
                deckerHelm.fillColor = UIColor(hex: "#0a1020")
                deckerHelm.strokeColor = UIColor(hex: "#00CCDD")
                deckerHelm.lineWidth = 1.2
                deckerHelm.zPosition = 3
                container.addChild(deckerHelm)

                // Cyber-visor — full-width cyan bar
                let deckerVisor = SKShapeNode(rectOf: CGSize(width: 13, height: 3), cornerRadius: 1)
                deckerVisor.fillColor = UIColor(hex: "#00DDFF")
                deckerVisor.strokeColor = UIColor(hex: "#00FFFF")
                deckerVisor.lineWidth = 0.8
                deckerVisor.glowWidth = 6.0
                deckerVisor.position = CGPoint(x: 0, y: 11)
                deckerVisor.zPosition = 4
                container.addChild(deckerVisor)

                // Cyberdeck — held in front, glowing cyan screen (ref image key element)
                let deck = SKShapeNode(rectOf: CGSize(width: 14, height: 10), cornerRadius: 2)
                deck.fillColor = UIColor(hex: "#001a22")
                deck.strokeColor = UIColor(hex: "#00DDFF")
                deck.lineWidth = 1.5
                deck.glowWidth = 4.0
                deck.position = CGPoint(x: 0, y: -4)
                deck.zPosition = 3
                container.addChild(deck)

                // Deck screen glow
                let deckScreen = SKShapeNode(rectOf: CGSize(width: 10, height: 6), cornerRadius: 1)
                deckScreen.fillColor = UIColor(hex: "#00DDFF").withAlphaComponent(0.35)
                deckScreen.strokeColor = .clear
                deckScreen.position = CGPoint(x: 0, y: -4)
                deckScreen.zPosition = 3.5
                container.addChild(deckScreen)

                // Data stream lines on deck screen
                for i in 0..<4 {
                    let dline = SKShapeNode()
                    let dlp = CGMutablePath()
                    let dy = CGFloat(i) * 1.5 - 2.5
                    dlp.move(to: CGPoint(x: -4, y: dy - 4))
                    dlp.addLine(to: CGPoint(x: 4, y: dy - 4))
                    dline.path = dlp
                    dline.strokeColor = UIColor(hex: "#00FFFF").withAlphaComponent(0.7)
                    dline.lineWidth = 0.6
                    dline.zPosition = 4
                    container.addChild(dline)
                }

                // Cyan energy crackling from deck (3 lightning bolts)
                for angle: CGFloat in [-0.6, 0.0, 0.6] {
                    let bolt = SKShapeNode()
                    let bp2 = CGMutablePath()
                    let bx: CGFloat = cos(angle) * 8
                    let by: CGFloat = sin(angle) * 8
                    bp2.move(to: CGPoint(x: 0, y: -4))
                    bp2.addLine(to: CGPoint(x: bx * 0.5, y: -4 + by * 0.5))
                    bp2.addLine(to: CGPoint(x: bx, y: -4 + by))
                    bolt.path = bp2
                    bolt.strokeColor = UIColor(hex: "#00FFFF").withAlphaComponent(0.6)
                    bolt.lineWidth = 0.8
                    bolt.glowWidth = 2.0
                    bolt.zPosition = 4
                    container.addChild(bolt)
                }

                // Pulsing deck glow
                let deckPulse = SKAction.sequence([
                    SKAction.run { deck.glowWidth = 4.0 },
                    SKAction.wait(forDuration: 0.5),
                    SKAction.run { deck.glowWidth = 7.0 },
                    SKAction.wait(forDuration: 0.5)
                ])
                deck.run(SKAction.repeatForever(deckPulse))

            case "face":
                // ── FACE ───────────────────────────────────────────────
                // Formal blue-grey suit, golden head, charismatic presence
                // Legs / trousers — dark blue
                let trousers = SKShapeNode(rectOf: CGSize(width: 12, height: 10), cornerRadius: 2)
                trousers.fillColor = UIColor(hex: "#1a1f35")
                trousers.strokeColor = UIColor(hex: "#334488")
                trousers.lineWidth = 0.8
                trousers.position = CGPoint(x: 0, y: -13)
                trousers.zPosition = 1
                container.addChild(trousers)

                // Suit jacket — formal, wide shoulders
                let jacket = SKShapeNode()
                let jpPath = CGMutablePath()
                jpPath.move(to: CGPoint(x: -9, y: -7))
                jpPath.addLine(to: CGPoint(x: 9, y: -7))
                jpPath.addLine(to: CGPoint(x: 12, y: 0))
                jpPath.addLine(to: CGPoint(x: 10, y: 8))
                jpPath.addLine(to: CGPoint(x: -10, y: 8))
                jpPath.addLine(to: CGPoint(x: -12, y: 0))
                jpPath.closeSubpath()
                jacket.path = jpPath
                jacket.fillColor = UIColor(hex: "#1a2040")
                jacket.strokeColor = UIColor(hex: "#4455AA")
                jacket.lineWidth = 1.5
                jacket.zPosition = 2
                container.addChild(jacket)

                // Jacket lapels — V-shape
                let lapel2 = SKShapeNode()
                let lp2 = CGMutablePath()
                lp2.move(to: CGPoint(x: 0, y: 6))
                lp2.addLine(to: CGPoint(x: -5, y: -2))
                lp2.move(to: CGPoint(x: 0, y: 6))
                lp2.addLine(to: CGPoint(x: 5, y: -2))
                lapel2.path = lp2
                lapel2.strokeColor = UIColor(hex: "#3355BB")
                lapel2.lineWidth = 1.2
                lapel2.zPosition = 2.5
                container.addChild(lapel2)

                // Gold tie / pin
                let tie = SKShapeNode(rectOf: CGSize(width: 3, height: 8), cornerRadius: 1)
                tie.fillColor = UIColor(hex: "#FFD700")
                tie.strokeColor = UIColor(hex: "#FFAA00")
                tie.lineWidth = 0.5
                tie.glowWidth = 2.0
                tie.position = CGPoint(x: 0, y: 0)
                tie.zPosition = 3
                container.addChild(tie)

                // Gold jacket buttons
                for yOff: CGFloat in [-4, 0, 4] {
                    let btn = SKShapeNode(circleOfRadius: 1.2)
                    btn.fillColor = UIColor(hex: "#FFD700")
                    btn.strokeColor = .clear
                    btn.position = CGPoint(x: 0, y: yOff)
                    btn.zPosition = 3
                    container.addChild(btn)
                }

                // Head — golden helmet / face
                let faceHead = SKShapeNode(ellipseOf: CGSize(width: 12, height: 14))
                faceHead.fillColor = UIColor(hex: "#C89020")
                faceHead.strokeColor = UIColor(hex: "#FFD700")
                faceHead.lineWidth = 1.5
                faceHead.glowWidth = 3.0
                faceHead.position = CGPoint(x: 0, y: 14)
                faceHead.zPosition = 3
                container.addChild(faceHead)

                // Shades — mirror-gold horizontal bar
                let faceShades = SKShapeNode(rectOf: CGSize(width: 9, height: 2.5), cornerRadius: 1)
                faceShades.fillColor = UIColor(hex: "#FFD700").withAlphaComponent(0.8)
                faceShades.strokeColor = UIColor(hex: "#FFFFFF").withAlphaComponent(0.5)
                faceShades.lineWidth = 0.5
                faceShades.glowWidth = 2.0
                faceShades.position = CGPoint(x: 0, y: 14)
                faceShades.zPosition = 5
                container.addChild(faceShades)

                // Subtle gold aura around head — charisma field
                let charismaAura = SKShapeNode(circleOfRadius: 10)
                charismaAura.fillColor = UIColor(hex: "#FFD700").withAlphaComponent(0.06)
                charismaAura.strokeColor = UIColor(hex: "#FFD700").withAlphaComponent(0.3)
                charismaAura.lineWidth = 1.0
                charismaAura.position = CGPoint(x: 0, y: 14)
                charismaAura.zPosition = 2.5
                container.addChild(charismaAura)

                let auraPulse3 = SKAction.sequence([
                    SKAction.fadeAlpha(to: 0.4, duration: 1.2),
                    SKAction.fadeAlpha(to: 0.8, duration: 1.2)
                ])
                charismaAura.run(SKAction.repeatForever(auraPulse3))

            default:
                // Fallback — generic runner
                let fbody = SKShapeNode(rectOf: CGSize(width: 14, height: 20), cornerRadius: 2)
                fbody.fillColor = UIColor(hex: "#001a3d")
                fbody.strokeColor = playerColor
                fbody.lineWidth = 1.5
                fbody.zPosition = 1
                container.addChild(fbody)
            }
            } // end spritesheet else-fallback

            // HP bar background + fill (wider: 32 points)
            let hpBg = SKShapeNode(rectOf: CGSize(width: 32, height: 4), cornerRadius: 2)
            hpBg.fillColor = UIColor(hex: "#1A0000")
            hpBg.strokeColor = UIColor(hex: "#330000")
            hpBg.lineWidth = 0.5
            hpBg.position = CGPoint(x: 0, y: -26)
            hpBg.zPosition = 20
            hpBg.name = "hpBarBg"
            hpBg.userData = NSMutableDictionary()
            hpBg.userData?["barWidth"] = CGFloat(32.0)
            container.addChild(hpBg)

            // Add thin glow line around HP bar
            let hpGlow = SKShapeNode(rectOf: CGSize(width: 32, height: 4), cornerRadius: 2)
            hpGlow.fillColor = .clear
            hpGlow.strokeColor = UIColor(hex: "#00FF88").withAlphaComponent(0.3)
            hpGlow.lineWidth = 1
            hpGlow.position = CGPoint(x: 0, y: -26)
            hpGlow.zPosition = 19
            hpGlow.name = "hpGlowLine"
            container.addChild(hpGlow)

            let hpBarFill = SKShapeNode()
            hpBarFill.fillColor = UIColor(hex: "#00FF88")
            hpBarFill.strokeColor = .clear
            hpBarFill.position = CGPoint(x: 0, y: -26)
            hpBarFill.zPosition = 21
            hpBarFill.name = "hpBarFill"
            container.addChild(hpBarFill)

            // Stun bar (yellow-orange, SR5 stun track) — just below HP bar
            let stunBg = SKShapeNode(rectOf: CGSize(width: 32, height: 2.5), cornerRadius: 1)
            stunBg.fillColor = UIColor(hex: "#1A1000")
            stunBg.strokeColor = .clear
            stunBg.position = CGPoint(x: 0, y: -31)
            stunBg.zPosition = 20
            stunBg.name = "stunBarBg"
            stunBg.userData = NSMutableDictionary()
            stunBg.userData?["barWidth"] = CGFloat(32.0)
            container.addChild(stunBg)

            let stunBarFill = SKShapeNode()
            stunBarFill.fillColor = UIColor(hex: "#FFAA00")
            stunBarFill.strokeColor = .clear
            stunBarFill.position = CGPoint(x: 0, y: -31)
            stunBarFill.zPosition = 21
            stunBarFill.name = "stunBarFill"
            container.addChild(stunBarFill)

            // HP numeric label below bar (placeholder - updated via updateHP after placement)
            let hpLabel = SKLabelNode(text: "-/-")
            hpLabel.fontName = "Menlo-Bold"
            hpLabel.fontSize = 8
            hpLabel.fontColor = UIColor(hex: "#00FF88")
            hpLabel.position = CGPoint(x: 0, y: -38)
            hpLabel.zPosition = 21
            hpLabel.name = "hpLabel"
            container.addChild(hpLabel)

            // Level badge (golden circle top-right) — positioned above the sprite top.
            // Sprite now uses bottom anchor (0.5, 0.0): top = position.y + displayH.
            let badge = SKShapeNode(circleOfRadius: 9)
            badge.fillColor = UIColor(hex: "#FFD700")
            badge.strokeColor = UIColor(hex: "#886600")
            badge.lineWidth = 1
            // Compute badge Y: sprite centre + half display height + clearance.
            let badgeY: CGFloat
            if let spr = container.childNode(withName: "characterSprite") as? SKSpriteNode {
                let dispH = spr.size.height * abs(spr.yScale)   // abs: yScale positive (xScale may be negative for flipped samurai)
                // Centre anchor: top of sprite is at position.y + dispH/2
                badgeY = spr.position.y + (dispH / 2) + 14
            } else {
                badgeY = 38   // procedural fallback: characters are ~24px tall
            }
            badge.position = CGPoint(x: 12, y: badgeY)
            badge.zPosition = 5
            badge.name = "levelBadge"
            container.addChild(badge)

            // Fetch actual level from GameState if available
            let actualLevel = level
            let levelLabel = SKLabelNode(text: "\(actualLevel)")
            levelLabel.fontName = "Helvetica-Bold"
            levelLabel.fontSize = 9
            levelLabel.fontColor = UIColor(hex: "#1A0A00")
            levelLabel.position = CGPoint(x: 12, y: badgeY - 2)
            levelLabel.zPosition = 6
            levelLabel.name = "levelLabel"
            container.addChild(levelLabel)

            // Also animate the badge to pulse slightly for visual polish
            let badgePulse = SKAction.sequence([
                SKAction.scale(to: 1.08, duration: 1.2),
                SKAction.scale(to: 1.0, duration: 1.2)
            ])
            badge.run(SKAction.repeatForever(badgePulse))

        } else {
            // ── Enemy sprites: use dedicated PNG frames generated for each enemy type ─────
            let eKey = enemySpriteKey(for: type)
            let accentColor = enemyAccentColor(for: eKey)
            let isBoss = (eKey == "boss" || eKey == "mech")

            container.spriteTypeKey = eKey   // stored so animate() can find correct frames

            // ── GUARANTEED BASE INDICATOR (always rendered, never invisible) ──────────────
            // This hex base ensures enemies are ALWAYS visible on the board even when all
            // texture loading paths fail. Sprite textures draw on top of it.
            let baseRadius: CGFloat = isBoss ? 34 : 28
            let baseFill = SKShapeNode(path: TileMap.hexPath(radius: baseRadius))
            baseFill.fillColor = accentColor.withAlphaComponent(0.22)
            baseFill.strokeColor = .clear
            baseFill.position = CGPoint(x: 0, y: -8)
            baseFill.zPosition = 0.1
            baseFill.name = "enemyBaseFill"
            container.addChild(baseFill)

            let baseRing = SKShapeNode(path: TileMap.hexPath(radius: baseRadius + 3))
            baseRing.fillColor = .clear
            baseRing.strokeColor = accentColor.withAlphaComponent(0.85)
            baseRing.lineWidth = 2.2
            baseRing.glowWidth = 4.0
            baseRing.position = CGPoint(x: 0, y: -8)
            baseRing.zPosition = 0.3
            baseRing.name = "enemyBaseRing"
            container.addChild(baseRing)
            baseRing.run(SKAction.repeatForever(SKAction.sequence([
                SKAction.fadeAlpha(to: 0.3, duration: 0.7),
                SKAction.fadeAlpha(to: 1.0, duration: 0.7)
            ])))

            if let idleFrames = enemyIdleTextures[eKey], let firstTex = idleFrames.first {
                // Hex shadow pool beneath enemy
                let hexShadow = SKShapeNode(path: TileMap.hexPath(radius: isBoss ? 34 : 28))
                hexShadow.fillColor = accentColor.withAlphaComponent(0.12)
                hexShadow.strokeColor = .clear
                hexShadow.position = CGPoint(x: 0, y: -10)
                hexShadow.zPosition = 0.2
                hexShadow.name = "hexShadow"
                container.addChild(hexShadow)

                // Pulsing hex ring in enemy accent colour
                let hexRing = SKShapeNode(path: TileMap.hexPath(radius: isBoss ? 34 : 28))
                hexRing.fillColor = .clear
                hexRing.strokeColor = accentColor.withAlphaComponent(0.70)
                hexRing.lineWidth = 1.8
                hexRing.position = CGPoint(x: 0, y: -10)
                hexRing.zPosition = 0.4
                hexRing.name = "hexRing"
                container.addChild(hexRing)
                hexRing.run(SKAction.repeatForever(SKAction.sequence([
                    SKAction.fadeAlpha(to: 0.25, duration: 0.8),
                    SKAction.fadeAlpha(to: 0.85, duration: 0.8)
                ])))

                // Main sprite node — NO color tint; sprites carry their own palette
                // Bottom-anchored + height-based scaling so the enemy stands on the
                // tile regardless of the source frame's aspect ratio.
                let targetH: CGFloat = isBoss ? 90 : 72
                let spriteNode = SKSpriteNode(texture: firstTex)
                let scale = targetH / max(spriteNode.size.height, 1.0)
                spriteNode.setScale(scale)
                spriteNode.anchorPoint = CGPoint(x: 0.5, y: 0.0)
                spriteNode.position = CGPoint(x: 0, y: -18)
                spriteNode.zPosition = 10
                spriteNode.name = "characterSprite"
                spriteNode.colorBlendFactor = 0.0  // full original palette — no tint overlay
                spriteNode.alpha = 1.0
                spriteNode.isHidden = false
                container.addChild(spriteNode)

                // Idle animation (cycle all idle frames at 0.35s/frame for smooth breathing)
                if idleFrames.count >= 2 {
                    let idleAnim = SKAction.animate(with: idleFrames, timePerFrame: 0.35)
                    spriteNode.run(SKAction.repeatForever(idleAnim), withKey: "idle")
                }

                // Ambient glow particle under boss sprites for extra visual weight
                if isBoss {
                    let bossGlow = SKShapeNode(circleOfRadius: 18)
                    bossGlow.fillColor = accentColor.withAlphaComponent(0.15)
                    bossGlow.strokeColor = accentColor.withAlphaComponent(0.4)
                    bossGlow.lineWidth = 1.5
                    bossGlow.position = CGPoint(x: 0, y: -8)
                    bossGlow.zPosition = 0.1
                    bossGlow.name = "bossGlow"
                    container.addChild(bossGlow)
                    bossGlow.run(SKAction.repeatForever(SKAction.sequence([
                        SKAction.scale(to: 1.15, duration: 1.0),
                        SKAction.scale(to: 0.9,  duration: 1.0)
                    ])))
                }

            } else {
                // No dedicated frames found — fall back to tinted player sprite
                let fallbackKey: String
                let fallbackTint: UIColor
                switch eKey {
                case "guard":    fallbackKey = "samurai"; fallbackTint = UIColor(hex: "#FF2222")
                case "elite":    fallbackKey = "samurai"; fallbackTint = UIColor(hex: "#9955FF")
                case "drone":    fallbackKey = "decker";  fallbackTint = UIColor(hex: "#FF8800")
                case "corpmage": fallbackKey = "mage";    fallbackTint = UIColor(hex: "#0088FF")
                case "medic":    fallbackKey = "face";    fallbackTint = UIColor(hex: "#FF44AA")
                default:         fallbackKey = "samurai"; fallbackTint = accentColor
                }
                if let fbFrames = playerIdleTextures[fallbackKey], let fbTex = fbFrames.first {
                    let fbRing = SKShapeNode(path: TileMap.hexPath(radius: 28))
                    fbRing.fillColor = .clear
                    fbRing.strokeColor = fallbackTint.withAlphaComponent(0.65)
                    fbRing.lineWidth = 1.8
                    fbRing.position = CGPoint(x: 0, y: -8)
                    fbRing.zPosition = 0.4
                    container.addChild(fbRing)
                    fbRing.run(SKAction.repeatForever(SKAction.sequence([
                        SKAction.fadeAlpha(to: 0.3, duration: 0.9),
                        SKAction.fadeAlpha(to: 0.8, duration: 0.9)
                    ])))
                    let fbSprite = SKSpriteNode(texture: fbTex)
                    let fbTargetH: CGFloat = 72
                    let fbScale = fbTargetH / max(fbSprite.size.height, 1.0)
                    fbSprite.setScale(fbScale)
                    fbSprite.anchorPoint = CGPoint(x: 0.5, y: 0.0)
                    fbSprite.position = CGPoint(x: 0, y: -18)
                    fbSprite.zPosition = 10
                    fbSprite.name = "characterSprite"
                    fbSprite.color = fallbackTint
                    fbSprite.colorBlendFactor = 0.55
                    fbSprite.alpha = 1.0
                    fbSprite.isHidden = false
                    container.addChild(fbSprite)
                    if fbFrames.count >= 2 {
                        fbSprite.run(SKAction.repeatForever(
                            SKAction.animate(with: fbFrames, timePerFrame: 0.5)), withKey: "idle")
                    }
                }
            }

            // Procedural fallback shapes (only reached if ALL texture loading failed):
            if container.children.filter({ $0.name == "characterSprite" }).isEmpty {

            // ── Fallback procedural enemy sprites ─────────────────────────────
            switch type.lowercased() {

            case "guard":
                // CORP SECURITY GUARD: Heavy riot armor, red threat visor, stocky 3-layer build
                // All layers wide: feet(y=-13,-7), torso(y=-7,y=7), helmet(y=7,y=14)

                // Feet/ankle layer
                let feet = SKShapeNode(rectOf: CGSize(width: 16, height: 6), cornerRadius: 2)
                feet.fillColor = UIColor(hex: "#1a0000")
                feet.strokeColor = baseColor
                feet.lineWidth = 1.0
                feet.position = CGPoint(x: 0, y: -10)
                feet.zPosition = 1
                container.addChild(feet)

                // Torso/chest layer - widest
                let torso = SKShapeNode(rectOf: CGSize(width: 16, height: 14), cornerRadius: 2)
                torso.fillColor = UIColor(hex: "#220000")
                torso.strokeColor = baseColor
                torso.lineWidth = 1.5
                torso.zPosition = 2
                container.addChild(torso)

                // Corp "C" logo on chest (outline only)
                let logoC = SKShapeNode(circleOfRadius: 4)
                logoC.fillColor = .clear
                logoC.strokeColor = baseColor.withAlphaComponent(0.6)
                logoC.lineWidth = 1.0
                logoC.position = CGPoint(x: 0, y: 0)
                logoC.zPosition = 3
                container.addChild(logoC)

                // Helmet layer
                let helmet = SKShapeNode(rectOf: CGSize(width: 12, height: 7), cornerRadius: 2)
                helmet.fillColor = UIColor(hex: "#1a0000")
                helmet.strokeColor = baseColor
                helmet.lineWidth = 1.2
                helmet.position = CGPoint(x: 0, y: 10)
                helmet.zPosition = 3
                container.addChild(helmet)

                // BRIGHT RED threat visor: full-width, glowing
                let visor = SKShapeNode(rectOf: CGSize(width: 14, height: 2.5), cornerRadius: 1)
                visor.fillColor = UIColor(hex: "#FF0000")
                visor.strokeColor = UIColor(hex: "#FF0000")
                visor.lineWidth = 1.0
                visor.glowWidth = 5.0
                visor.position = CGPoint(x: 0, y: 10)
                visor.zPosition = 5
                container.addChild(visor)

                // Scan-flicker animation on visor (fast alpha flicker)
                let scan = SKAction.sequence([
                    SKAction.fadeAlpha(to: 0.2, duration: 0.1),
                    SKAction.fadeAlpha(to: 1.0, duration: 0.08),
                    SKAction.wait(forDuration: Double.random(in: 1.0...3.0))
                ])
                visor.run(SKAction.repeatForever(scan))

            case "drone":
                // SECURITY DRONE: Hovering disc with rotor arms, orange camera, blinking beacon
                // Four rotor arms extending diagonally to corners

                let armAngles: [CGFloat] = [45, -45, 135, -135]
                for deg in armAngles {
                    // Arm line (structure)
                    let arm = SKShapeNode()
                    let armPath = CGMutablePath()
                    armPath.move(to: .zero)
                    armPath.addLine(to: CGPoint(x: 0, y: 13))
                    arm.path = armPath
                    arm.strokeColor = baseColor.withAlphaComponent(0.8)
                    arm.lineWidth = 1.5
                    arm.zRotation = deg * .pi / 180
                    arm.zPosition = 1
                    container.addChild(arm)

                    // Spinning rotor tip at end of arm (small rectangle)
                    let tip = SKShapeNode(rectOf: CGSize(width: 7, height: 2), cornerRadius: 1)
                    tip.fillColor = baseColor
                    tip.strokeColor = baseColor
                    tip.lineWidth = 0.5
                    let tipX = sin(deg * .pi / 180) * 13
                    let tipY = cos(deg * .pi / 180) * 13
                    tip.position = CGPoint(x: tipX, y: tipY)
                    tip.zPosition = 2
                    container.addChild(tip)
                }

                // Flat disc body: ellipse 14×8
                let disc = SKShapeNode(ellipseOf: CGSize(width: 14, height: 8))
                disc.fillColor = UIColor(hex: "#0d1a2e")
                disc.strokeColor = baseColor
                disc.lineWidth = 1.8
                disc.zPosition = 3
                disc.name = "droneDisk"
                container.addChild(disc)

                // Camera lens: circle with orange-red glow at center
                let lens = SKShapeNode(circleOfRadius: 4)
                lens.fillColor = UIColor(hex: "#FF6600")
                lens.strokeColor = UIColor(hex: "#FF8800")
                lens.lineWidth = 1.2
                lens.glowWidth = 4.0
                lens.zPosition = 4
                lens.name = "droneEye"
                container.addChild(lens)

                // Panning eye animation (side to side)
                let panLeft = SKAction.move(to: CGPoint(x: -2, y: 0), duration: 0.7)
                let panRight = SKAction.move(to: CGPoint(x: 2, y: 0), duration: 0.7)
                let panCenter = SKAction.move(to: .zero, duration: 0.4)
                let panCycle = SKAction.sequence([panLeft, panCenter, panRight, panCenter])
                lens.run(SKAction.repeatForever(panCycle))

                // Warning beacon on top: blinking red dot
                let beacon = SKShapeNode(circleOfRadius: 1.5)
                beacon.fillColor = UIColor(hex: "#FF2200")
                beacon.strokeColor = UIColor(hex: "#FF4400")
                beacon.lineWidth = 0.5
                beacon.glowWidth = 3.0
                beacon.position = CGPoint(x: 0, y: 10)
                beacon.zPosition = 5
                container.addChild(beacon)

                let beaconBlink = SKAction.sequence([
                    SKAction.fadeOut(withDuration: 0.3),
                    SKAction.fadeIn(withDuration: 0.2),
                    SKAction.wait(forDuration: 0.7)
                ])
                beacon.run(SKAction.repeatForever(beaconBlink))

                // Hover bob: the disc body bobs up-down ±2pt slowly
                let hover = SKAction.sequence([
                    SKAction.moveBy(x: 0, y: 2, duration: 1.0),
                    SKAction.moveBy(x: 0, y: -2, duration: 1.0)
                ])
                disc.run(SKAction.repeatForever(hover))

            case "elite":
                // ELITE HEAVY UNIT: Massive power armor, purple energy core, dual shoulder cannons
                // Much wider (width 20), tall (y=-14 to y=14)

                // Massive armored boots
                let boots = SKShapeNode(rectOf: CGSize(width: 18, height: 6), cornerRadius: 2)
                boots.fillColor = UIColor(hex: "#0d0022")
                boots.strokeColor = baseColor
                boots.lineWidth = 1.2
                boots.position = CGPoint(x: 0, y: -11)
                boots.zPosition = 1
                container.addChild(boots)

                // Heavy leg armor plates
                for xOff: CGFloat in [-6, 6] {
                    let legPlate = SKShapeNode(rectOf: CGSize(width: 6, height: 10), cornerRadius: 1)
                    legPlate.fillColor = UIColor(hex: "#1a0033")
                    legPlate.strokeColor = baseColor.withAlphaComponent(0.6)
                    legPlate.lineWidth = 1.0
                    legPlate.position = CGPoint(x: xOff, y: -3)
                    legPlate.zPosition = 1
                    container.addChild(legPlate)
                }

                // Main torso: very wide, heavily armored
                let torso = SKShapeNode()
                let torsoPath = CGMutablePath()
                torsoPath.move(to: CGPoint(x: -13, y: -6))
                torsoPath.addLine(to: CGPoint(x: 13, y: -6))
                torsoPath.addLine(to: CGPoint(x: 14, y: 2))
                torsoPath.addLine(to: CGPoint(x: 13, y: 10))
                torsoPath.addLine(to: CGPoint(x: -13, y: 10))
                torsoPath.addLine(to: CGPoint(x: -14, y: 2))
                torsoPath.closeSubpath()
                torso.path = torsoPath
                torso.fillColor = UIColor(hex: "#0d0022")
                torso.strokeColor = baseColor
                torso.lineWidth = 2.0
                torso.zPosition = 2
                container.addChild(torso)

                // PURPLE glowing energy core (diamond shape) at chest
                let corePath = CGMutablePath()
                corePath.move(to: CGPoint(x: 0, y: 5))
                corePath.addLine(to: CGPoint(x: 5, y: 0))
                corePath.addLine(to: CGPoint(x: 0, y: -5))
                corePath.addLine(to: CGPoint(x: -5, y: 0))
                corePath.closeSubpath()
                let core = SKShapeNode()
                core.path = corePath
                core.fillColor = baseColor.withAlphaComponent(0.8)
                core.strokeColor = baseColor
                core.lineWidth = 1.2
                core.glowWidth = 5.0
                core.zPosition = 4
                container.addChild(core)

                // Dual shoulder weapon cannons (rectangles extending up-out)
                for xPos: CGFloat in [-16, 16] {
                    let cannon = SKShapeNode(rectOf: CGSize(width: 6, height: 10), cornerRadius: 1)
                    cannon.fillColor = UIColor(hex: "#1a0033")
                    cannon.strokeColor = baseColor
                    cannon.lineWidth = 1.2
                    cannon.position = CGPoint(x: xPos, y: 6)
                    cannon.zPosition = 3
                    container.addChild(cannon)

                    // Barrel tip glowing
                    let barrel = SKShapeNode(circleOfRadius: 2)
                    barrel.fillColor = baseColor.withAlphaComponent(0.8)
                    barrel.strokeColor = baseColor
                    barrel.lineWidth = 1.0
                    barrel.glowWidth = 2.5
                    barrel.position = CGPoint(x: xPos, y: 14)
                    barrel.zPosition = 4
                    container.addChild(barrel)
                }

                // Helmet: wide, flat-topped
                let head = SKShapeNode(rectOf: CGSize(width: 14, height: 7), cornerRadius: 2)
                head.fillColor = UIColor(hex: "#0d0022")
                head.strokeColor = baseColor
                head.lineWidth = 1.5
                head.position = CGPoint(x: 0, y: 12)
                head.zPosition = 3
                container.addChild(head)

                // Skull-like faceplate: horizontal grille slits
                for row: CGFloat in [10.5, 12, 13.5] {
                    let slit = SKShapeNode(rectOf: CGSize(width: 13, height: 0.8), cornerRadius: 0)
                    slit.fillColor = baseColor.withAlphaComponent(0.7)
                    slit.strokeColor = .clear
                    slit.position = CGPoint(x: 0, y: row)
                    slit.zPosition = 5
                    container.addChild(slit)
                }

                // Purple aura ring pulsing around entire body
                let aura = SKShapeNode(circleOfRadius: 18)
                aura.fillColor = .clear
                aura.strokeColor = baseColor.withAlphaComponent(0.25)
                aura.lineWidth = 2.5
                aura.glowWidth = 4.0
                aura.zPosition = 0
                container.addChild(aura)

                let auraPulse = SKAction.sequence([
                    SKAction.scale(to: 1.0, duration: 0.8),
                    SKAction.scale(to: 1.12, duration: 0.8)
                ])
                aura.run(SKAction.repeatForever(auraPulse))

                // Core pulse with glowWidth animation
                let corePulse = SKAction.sequence([
                    SKAction.run { core.glowWidth = 5.0 },
                    SKAction.wait(forDuration: 0.6),
                    SKAction.run { core.glowWidth = 8.0 },
                    SKAction.wait(forDuration: 0.6)
                ])
                core.run(SKAction.repeatForever(corePulse))

            case "mage":
                // ENEMY COMBAT MAGE: Dark sorcerer, green highlights (not purple), orbiting orbs, staff
                // Dark flowing robes, very wide at bottom

                // Robe: dark black with GREEN highlights, tapers from wide bottom
                let robe = SKShapeNode()
                let robePath = CGMutablePath()
                robePath.move(to: CGPoint(x: -13, y: -13))
                robePath.addLine(to: CGPoint(x: 13, y: -13))
                robePath.addLine(to: CGPoint(x: 9, y: 2))
                robePath.addLine(to: CGPoint(x: 8, y: 9))
                robePath.addLine(to: CGPoint(x: -8, y: 9))
                robePath.addLine(to: CGPoint(x: -9, y: 2))
                robePath.closeSubpath()
                robe.path = robePath
                robe.fillColor = UIColor.black.withAlphaComponent(0.85)
                robe.strokeColor = baseColor
                robe.lineWidth = 1.5
                robe.zPosition = 1
                container.addChild(robe)

                // Robe edge folds: diagonal lines for texture
                for xOff: CGFloat in [-6, 6] {
                    let fold = SKShapeNode()
                    let foldPath = CGMutablePath()
                    foldPath.move(to: CGPoint(x: xOff, y: -13))
                    foldPath.addLine(to: CGPoint(x: xOff * 0.5, y: 3))
                    fold.path = foldPath
                    fold.strokeColor = baseColor.withAlphaComponent(0.35)
                    fold.lineWidth = 0.7
                    fold.zPosition = 2
                    container.addChild(fold)
                }

                // Hood: deep and dark
                let hood = SKShapeNode()
                let hoodPath = CGMutablePath()
                hoodPath.move(to: CGPoint(x: -7, y: 9))
                hoodPath.addLine(to: CGPoint(x: 7, y: 9))
                hoodPath.addLine(to: CGPoint(x: 6, y: 14))
                hoodPath.addLine(to: CGPoint(x: -6, y: 14))
                hoodPath.closeSubpath()
                hood.path = hoodPath
                hood.fillColor = UIColor.black.withAlphaComponent(0.9)
                hood.strokeColor = baseColor.withAlphaComponent(0.7)
                hood.lineWidth = 1.2
                hood.zPosition = 3
                container.addChild(hood)

                // Glowing GREEN eyes: two vivid dots under hood
                for xOff: CGFloat in [-2.5, 2.5] {
                    let eye = SKShapeNode(circleOfRadius: 1.8)
                    eye.fillColor = baseColor
                    eye.strokeColor = baseColor
                    eye.lineWidth = 0.8
                    eye.glowWidth = 4.5
                    eye.position = CGPoint(x: xOff, y: 11)
                    eye.zPosition = 5
                    container.addChild(eye)
                }

                // Staff at side: vertical line, dark with green glow
                let staff = SKShapeNode()
                let staffPath = CGMutablePath()
                staffPath.move(to: CGPoint(x: 0, y: -13))
                staffPath.addLine(to: CGPoint(x: 0, y: 9))
                staff.path = staffPath
                staff.position = CGPoint(x: 11, y: 0)
                staff.strokeColor = UIColor(hex: "#004400").withAlphaComponent(0.9)
                staff.lineWidth = 2.0
                staff.glowWidth = 1.5
                staff.zPosition = 1.5
                container.addChild(staff)

                // Staff gem: glowing at top with pulsing glow
                let staffGem = SKShapeNode(circleOfRadius: 3.5)
                staffGem.fillColor = baseColor.withAlphaComponent(0.85)
                staffGem.strokeColor = baseColor
                staffGem.lineWidth = 1.2
                staffGem.glowWidth = 6.0
                staffGem.position = CGPoint(x: 11, y: 13)
                staffGem.zPosition = 2
                container.addChild(staffGem)

                let gemPulse = SKAction.sequence([
                    SKAction.run { staffGem.glowWidth = 6.0 },
                    SKAction.wait(forDuration: 0.7),
                    SKAction.run { staffGem.glowWidth = 9.0 },
                    SKAction.wait(forDuration: 0.7)
                ])
                staffGem.run(SKAction.repeatForever(gemPulse))

                // Three orbiting energy orbs: smooth continuous circular motion
                let orbitRadius: CGFloat = 13.0
                for i in 0..<3 {
                    let startAngle = CGFloat(i) * (2 * .pi / 3)
                    let orb = SKShapeNode(circleOfRadius: 2.2)
                    orb.fillColor = baseColor.withAlphaComponent(0.85)
                    orb.strokeColor = baseColor
                    orb.lineWidth = 0.8
                    orb.glowWidth = 3.5
                    orb.position = CGPoint(x: cos(startAngle) * orbitRadius, y: sin(startAngle) * orbitRadius)
                    orb.zPosition = 2.5
                    container.addChild(orb)

                    // Smooth orbit using SKAction.follow with circular path
                    let circlePath = CGMutablePath()
                    circlePath.addEllipse(in: CGRect(x: -orbitRadius, y: -orbitRadius, width: orbitRadius * 2, height: orbitRadius * 2))
                    let duration = 3.0 + Double(i) * 0.4
                    let orbit = SKAction.follow(circlePath, asOffset: false, orientToPath: false, duration: duration)
                    orb.run(SKAction.repeatForever(orbit))
                }

            case "healer":
                // COMBAT MEDIC: Medical suit, bright GREEN cross, floating heal particles, pulsing aura
                // Lighter and less bulky than guard, with iconic medical aesthetic

                // Lower body: light medical suit
                let legs = SKShapeNode(rectOf: CGSize(width: 10, height: 7), cornerRadius: 2)
                legs.fillColor = UIColor(hex: "#001a00")
                legs.strokeColor = baseColor
                legs.lineWidth = 1.0
                legs.position = CGPoint(x: 0, y: -9)
                legs.zPosition = 1
                container.addChild(legs)

                // Torso: medical suit, lighter than guard
                let torso = SKShapeNode()
                let torsoPath = CGMutablePath()
                torsoPath.move(to: CGPoint(x: -7, y: -5))
                torsoPath.addLine(to: CGPoint(x: 7, y: -5))
                torsoPath.addLine(to: CGPoint(x: 8, y: 3))
                torsoPath.addLine(to: CGPoint(x: 6, y: 8))
                torsoPath.addLine(to: CGPoint(x: -6, y: 8))
                torsoPath.addLine(to: CGPoint(x: -8, y: 3))
                torsoPath.closeSubpath()
                torso.path = torsoPath
                torso.fillColor = UIColor(hex: "#001a00")
                torso.strokeColor = baseColor
                torso.lineWidth = 1.5
                torso.zPosition = 2
                container.addChild(torso)

                // Bright GREEN medical cross on torso (two intersecting rectangles)
                let crossV = SKShapeNode(rectOf: CGSize(width: 3, height: 9), cornerRadius: 0.5)
                crossV.fillColor = baseColor
                crossV.strokeColor = .clear
                crossV.glowWidth = 2.0
                crossV.position = CGPoint(x: 0, y: 1)
                crossV.zPosition = 4
                container.addChild(crossV)

                let crossH = SKShapeNode(rectOf: CGSize(width: 9, height: 3), cornerRadius: 0.5)
                crossH.fillColor = baseColor
                crossH.strokeColor = .clear
                crossH.glowWidth = 2.0
                crossH.position = CGPoint(x: 0, y: 1)
                crossH.zPosition = 4
                container.addChild(crossH)

                // Cross pulsing glow animation
                let crossPulse = SKAction.sequence([
                    SKAction.fadeAlpha(to: 0.5, duration: 0.5),
                    SKAction.fadeAlpha(to: 1.0, duration: 0.5)
                ])
                crossV.run(SKAction.repeatForever(crossPulse))
                crossH.run(SKAction.repeatForever(crossPulse))

                // Head: round with medical visor
                let head = SKShapeNode(ellipseOf: CGSize(width: 10, height: 11))
                head.fillColor = UIColor(hex: "#001a00")
                head.strokeColor = baseColor
                head.lineWidth = 1.2
                head.position = CGPoint(x: 0, y: 12)
                head.zPosition = 3
                container.addChild(head)

                // Medical visor stripe: horizontal bar across head
                let visor = SKShapeNode(rectOf: CGSize(width: 9, height: 2.5), cornerRadius: 0.5)
                visor.fillColor = baseColor
                visor.strokeColor = baseColor
                visor.lineWidth = 0.8
                visor.glowWidth = 3.0
                visor.position = CGPoint(x: 0, y: 12)
                visor.zPosition = 5
                container.addChild(visor)

                // Pulsing soft GREEN aura around body
                let healAura = SKShapeNode(circleOfRadius: 17)
                healAura.fillColor = baseColor.withAlphaComponent(0.08)
                healAura.strokeColor = baseColor.withAlphaComponent(0.4)
                healAura.lineWidth = 1.5
                healAura.glowWidth = 2.5
                healAura.zPosition = 0
                container.addChild(healAura)

                let auraPulse = SKAction.sequence([
                    SKAction.group([
                        SKAction.scale(to: 1.0, duration: 1.0),
                        SKAction.fadeAlpha(to: 0.7, duration: 1.0)
                    ]),
                    SKAction.group([
                        SKAction.scale(to: 1.3, duration: 1.0),
                        SKAction.fadeAlpha(to: 0.2, duration: 1.0)
                    ])
                ])
                healAura.run(SKAction.repeatForever(auraPulse))

                // Floating "+" heal symbols that rise and fade
                for i in 0..<3 {
                    let delay = Double(i) * 0.8
                    let startX = CGFloat([-7, 0, 7][i])
                    let plusNode = SKLabelNode(text: "+")
                    plusNode.fontName = "Helvetica-Bold"
                    plusNode.fontSize = 7
                    plusNode.fontColor = baseColor
                    plusNode.position = CGPoint(x: startX, y: -6)
                    plusNode.zPosition = 6
                    container.addChild(plusNode)

                    let rise = SKAction.sequence([
                        SKAction.wait(forDuration: delay),
                        SKAction.group([
                            SKAction.moveBy(x: 0, y: 18, duration: 1.0),
                            SKAction.fadeOut(withDuration: 1.0)
                        ]),
                        SKAction.run {
                            plusNode.position = CGPoint(x: startX, y: -6)
                            plusNode.alpha = 1.0
                        }
                    ])
                    plusNode.run(SKAction.repeatForever(rise))
                }

            default:
                // Fallback: simple square with subtle glow
                let body = SKShapeNode(rectOf: CGSize(width: 22, height: 22), cornerRadius: 3)
                body.fillColor = baseColor
                body.strokeColor = baseColor.withAlphaComponent(0.8)
                body.lineWidth = 1
                body.zPosition = 1
                container.addChild(body)
            }

            // Hex ground ring for enemy sprites — hostile red/orange tint
            let enemyHexShadow = SKShapeNode(path: TileMap.hexPath(radius: 20))
            enemyHexShadow.fillColor = baseColor.withAlphaComponent(0.08)
            enemyHexShadow.strokeColor = .clear
            enemyHexShadow.position = CGPoint(x: 0, y: -10)
            enemyHexShadow.zPosition = 0.2
            container.addChild(enemyHexShadow)

            let enemyHexRing = SKShapeNode(path: TileMap.hexPath(radius: 20))
            enemyHexRing.fillColor = .clear
            enemyHexRing.strokeColor = baseColor.withAlphaComponent(0.45)
            enemyHexRing.lineWidth = 1.5
            enemyHexRing.position = CGPoint(x: 0, y: -10)
            enemyHexRing.zPosition = 0.4
            container.addChild(enemyHexRing)

            let enemyRingPulse = SKAction.sequence([
                SKAction.fadeAlpha(to: 0.2, duration: 1.0),
                SKAction.fadeAlpha(to: 0.5, duration: 1.0)
            ])
            enemyHexRing.run(SKAction.repeatForever(enemyRingPulse))

            // Enemy HP bar (consistent with player sprites) - only for non-player sprites
            if team == "enemy" {
                let enemyBarWidth: CGFloat = 28.0
                let hpBg = SKShapeNode(rectOf: CGSize(width: enemyBarWidth, height: 4), cornerRadius: 2)
                hpBg.fillColor = UIColor(hex: "#1A0000")
                hpBg.strokeColor = UIColor(hex: "#330000")
                hpBg.lineWidth = 0.5
                hpBg.position = CGPoint(x: 0, y: -20)
                hpBg.zPosition = 20  // ABOVE container (z=10) + enemy body (z=1) — FIX Issue 3
                hpBg.name = "hpBarBg"
                hpBg.userData = NSMutableDictionary()
                hpBg.userData?["barWidth"] = enemyBarWidth
                container.addChild(hpBg)

                // Add thin glow line around HP bar
                let hpGlow = SKShapeNode(rectOf: CGSize(width: enemyBarWidth, height: 4), cornerRadius: 2)
                hpGlow.fillColor = .clear
                hpGlow.strokeColor = baseColor.withAlphaComponent(0.3)
                hpGlow.lineWidth = 1
                hpGlow.position = CGPoint(x: 0, y: -20)
                hpGlow.zPosition = 19
                hpGlow.name = "hpGlowLine"
                container.addChild(hpGlow)

                let hpBarFill = SKShapeNode()
                hpBarFill.fillColor = baseColor
                hpBarFill.strokeColor = .clear
                hpBarFill.position = CGPoint(x: 0, y: -20)
                hpBarFill.zPosition = 21  // above hpBg (z=20)
                hpBarFill.name = "hpBarFill"
                container.addChild(hpBarFill)

                // HP label below bar - shows current/max HP (placeholder, updated via updateHP)
                let hpLabel = SKLabelNode(text: "-/-")
                hpLabel.fontName = "Menlo-Bold"
                hpLabel.fontSize = 8
                hpLabel.fontColor = baseColor
                hpLabel.position = CGPoint(x: 0, y: -28)
                hpLabel.zPosition = 21
                hpLabel.name = "hpLabel"
                container.addChild(hpLabel)
            }
            } // end fallback procedural enemy sprites
        }

        // Container zPosition must be ABOVE tile z (z=10) so characters are always visible above the grid.
        // With ignoresSiblingOrder=true, zPosition is the ONLY render-order determinant.
        container.zPosition = 11
        // Initial position using correct hex grid math. BattleScene.placeCharacter/placeEnemy
        // will override with tileCenter + mapOrigin for final scene placement.
        container.position = TileMap.tileCenter(x: x, y: y)

        return container
    }

    // MARK: - Animations

    /// White flash hit animation (0.1s).
    func animateHit(target: SKNode) {
        if let sprite = target as? SpriteNode {
            animate(state: .attack, target: sprite)
        }
        for child in target.children {
            if let shape = child as? SKShapeNode {
                let origColor = shape.fillColor
                let flash = SKAction.sequence([
                    SKAction.run { shape.fillColor = .white },
                    SKAction.wait(forDuration: 0.05),
                    SKAction.run { shape.fillColor = origColor },
                    SKAction.wait(forDuration: 0.05),
                    SKAction.run { shape.fillColor = .white },
                    SKAction.wait(forDuration: 0.05),
                    SKAction.run { shape.fillColor = origColor }
                ])
                shape.run(flash)
            } else if let label = child as? SKLabelNode {
                let originalAlpha = label.alpha
                let flash = SKAction.sequence([
                    SKAction.fadeAlpha(to: 0.35, duration: 0.05),
                    SKAction.fadeAlpha(to: originalAlpha, duration: 0.05),
                    SKAction.fadeAlpha(to: 0.35, duration: 0.05),
                    SKAction.fadeAlpha(to: originalAlpha, duration: 0.05)
                ])
                label.run(flash)
            }
        }
    }

    /// Apply sprite state animation: idle (subtle pulse), walk (scale bounce), attack (red flash).
    func animate(state: SpriteState, target: SpriteNode) {
        target.currentState = state
        switch state {
        case .idle:
            animateIdle(target: target)
        case .walk:
            animateWalk(target: target)
        case .attack:
            animateAttack(target: target)
        }
    }

    /// Idle: flip between idle texture frames on the characterSprite child node.
    /// Uses spriteTypeKey set at creation time — no name-parsing needed.
    private func animateIdle(target: SpriteNode) {
        target.removeAction(forKey: "walkAnimation")
        if let spriteNode = target.childNode(withName: "characterSprite") as? SKSpriteNode {
            if target.team == "enemy" {
                let eKey = target.spriteTypeKey.isEmpty ? "guard" : target.spriteTypeKey
                if let frames = enemyIdleTextures[eKey], frames.count >= 2 {
                    spriteNode.removeAction(forKey: "walk")
                    spriteNode.run(SKAction.repeatForever(
                        SKAction.animate(with: frames, timePerFrame: 0.35)), withKey: "idle")
                    return
                }
            }
            // Player: use archetype key from spriteTypeKey or derive from node name
            let archKey = target.spriteTypeKey.isEmpty
                ? archetypeKey(for: target.name ?? "samurai")
                : target.spriteTypeKey
            if let frames = playerIdleTextures[archKey], frames.count >= 2 {
                spriteNode.removeAction(forKey: "walk")
                let idleAnim = SKAction.animate(with: frames, timePerFrame: 0.5,
                                                resize: true, restore: false)
                spriteNode.run(SKAction.repeatForever(idleAnim), withKey: "idle")
                return
            }
        }
        // Fallback breathe animation (procedural sprites)
        let breathe = SKAction.sequence([
            SKAction.scale(to: 1.02, duration: 0.15),
            SKAction.scale(to: 1.0, duration: 0.15)
        ])
        target.run(SKAction.repeatForever(breathe), withKey: "idleAnimation")
    }

    /// Stop idle animation and freeze the sprite on its first idle frame.
    /// Used to keep inactive player characters stationary during other characters' turns.
    func stopIdle(target: SpriteNode) {
        // Stop texture animation on the characterSprite child
        if let spriteNode = target.childNode(withName: "characterSprite") as? SKSpriteNode {
            spriteNode.removeAction(forKey: "idle")
            // Snap to first idle frame so the character looks natural (not frozen mid-cycle)
            let archKey = target.spriteTypeKey.isEmpty
                ? archetypeKey(for: target.name ?? "samurai")
                : target.spriteTypeKey
            if let firstFrame = playerIdleTextures[archKey]?.first {
                spriteNode.run(SKAction.setTexture(firstFrame, resize: true))
            }
        }
        // Also stop the procedural breathe fallback
        target.removeAction(forKey: "idleAnimation")
    }

    /// Walk: flip between walk texture frames on the characterSprite child node.
    /// Uses spriteTypeKey set at creation time.
    private func animateWalk(target: SpriteNode) {
        target.removeAction(forKey: "idleAnimation")
        if let spriteNode = target.childNode(withName: "characterSprite") as? SKSpriteNode {
            if target.team == "enemy" {
                let eKey = target.spriteTypeKey.isEmpty ? "guard" : target.spriteTypeKey
                if let frames = enemyWalkTextures[eKey], !frames.isEmpty {
                    spriteNode.removeAction(forKey: "idle")
                    let walkAnim = SKAction.animate(with: frames, timePerFrame: 0.14)
                    spriteNode.run(SKAction.repeatForever(walkAnim), withKey: "walk")
                    return
                }
            }
            let archKey = target.spriteTypeKey.isEmpty
                ? archetypeKey(for: target.name ?? "samurai")
                : target.spriteTypeKey
            if let frames = playerWalkTextures[archKey], !frames.isEmpty {
                spriteNode.removeAction(forKey: "idle")
                let walkAnim = SKAction.animate(with: frames, timePerFrame: 0.12,
                                                resize: true, restore: false)
                spriteNode.run(SKAction.repeatForever(walkAnim), withKey: "walk")
                return
            }
        }
        // Fallback bounce animation
        let bounce = SKAction.sequence([
            SKAction.scale(to: 1.05, duration: 0.1),
            SKAction.scale(to: 1.0, duration: 0.1)
        ])
        target.run(SKAction.repeatForever(bounce), withKey: "walkAnimation")
    }

    /// Attack: play attack texture frames then return to idle, with flash overlay.
    private func animateAttack(target: SpriteNode) {
        target.removeAction(forKey: "walkAnimation")
        target.removeAction(forKey: "idleAnimation")
        target.run(SKAction.scale(to: 1.0, duration: 0.05))

        if let spriteNode = target.childNode(withName: "characterSprite") as? SKSpriteNode {
            // Try dedicated attack frames first (enemy or player)
            var attackFrames: [SKTexture]?
            if target.team == "enemy" {
                let eKey = target.spriteTypeKey.isEmpty ? "guard" : target.spriteTypeKey
                attackFrames = enemyAttackTextures[eKey]
            }
            if attackFrames == nil {
                let archKey = target.spriteTypeKey.isEmpty
                    ? archetypeKey(for: target.name ?? "samurai")
                    : target.spriteTypeKey
                attackFrames = playerWalkTextures[archKey]  // use walk as attack fallback
            }
            if let frames = attackFrames, frames.count >= 2 {
                spriteNode.removeAction(forKey: "idle")
                spriteNode.removeAction(forKey: "walk")
                // Play attack sequence once, then resume idle
                let attackAnim = SKAction.animate(with: frames, timePerFrame: 0.12,
                                                  resize: true, restore: false)
                let resumeIdle: SKAction
                if let idleFrames = (target.team == "enemy"
                    ? enemyIdleTextures[target.spriteTypeKey]
                    : playerIdleTextures[target.spriteTypeKey]),
                   idleFrames.count >= 2 {
                    resumeIdle = SKAction.repeatForever(
                        SKAction.animate(with: idleFrames, timePerFrame: 0.35,
                                         resize: true, restore: false))
                } else {
                    resumeIdle = SKAction.repeatForever(
                        SKAction.sequence([SKAction.scale(to: 1.02, duration: 0.3),
                                           SKAction.scale(to: 1.0, duration: 0.3)]))
                }
                spriteNode.run(SKAction.sequence([attackAnim,
                    SKAction.run { spriteNode.run(resumeIdle, withKey: "idle") }]), withKey: "attack")
                return
            }
        }

        // Fallback: colour flash on shape children
        for child in target.children {
            if let shape = child as? SKShapeNode {
                let origColor = shape.fillColor
                shape.run(SKAction.sequence([
                    SKAction.run { shape.fillColor = UIColor.red.withAlphaComponent(0.6) },
                    SKAction.wait(forDuration: 0.15),
                    SKAction.run { shape.fillColor = origColor }
                ]))
            } else if let spriteChild = child as? SKSpriteNode {
                let origColor = spriteChild.color
                spriteChild.run(SKAction.sequence([
                    SKAction.run { spriteChild.color = UIColor.red.withAlphaComponent(0.6) },
                    SKAction.wait(forDuration: 0.15),
                    SKAction.run { spriteChild.color = origColor }
                ]))
            }
        }
    }

    /// Death animation - white flash + expanding red ring + fade out + shrink.
    func animateDeath(target: SKNode) {
        // Brief white flash (0.1s)
        for child in target.children {
            if let shape = child as? SKShapeNode, !(child.name?.contains("selection") ?? false) {
                let origColor = shape.fillColor
                let flash = SKAction.sequence([
                    SKAction.run { shape.fillColor = .white },
                    SKAction.wait(forDuration: 0.05),
                    SKAction.run { shape.fillColor = origColor },
                    SKAction.wait(forDuration: 0.05)
                ])
                shape.run(flash)
            }
        }

        // Expanding red ring at death position
        let deathRing = SKShapeNode(circleOfRadius: 1)
        deathRing.fillColor = .clear
        deathRing.strokeColor = UIColor(hex: "#FF3333")
        deathRing.lineWidth = 1.5
        deathRing.zPosition = 10
        target.addChild(deathRing)

        let expandRing = SKAction.sequence([
            SKAction.group([
                SKAction.scale(to: 30, duration: 0.3),
                SKAction.fadeOut(withDuration: 0.3)
            ]),
            SKAction.removeFromParent()
        ])
        deathRing.run(expandRing)

        // Fade out + shrink to 0.01
        let fadeOut = SKAction.fadeOut(withDuration: 0.4)
        let shrink = SKAction.scale(to: 0.01, duration: 0.4)
        let group = SKAction.group([fadeOut, shrink])
        let remove = SKAction.removeFromParent()
        target.run(SKAction.sequence([
            SKAction.wait(forDuration: 0.1),  // Let flash complete
            group,
            remove
        ]))
    }

    /// Move a character node to a new tile position, accounting for mapOrigin.
    /// Triggers walk animation during move, returns to idle on completion.
    func animateMove(target: SKNode, toTileX x: Int, toTileY y: Int, duration: TimeInterval = 0.25, mapOrigin: CGPoint = .zero) {
        // Use TileMap.tileCenter so odd-row hex stagger is applied to movement animations.
        let local = TileMap.tileCenter(x: x, y: y)
        let newPos = CGPoint(x: mapOrigin.x + local.x, y: mapOrigin.y + local.y)
        let move = SKAction.move(to: newPos, duration: duration)
        move.timingMode = .easeInEaseOut

        // Walk animation during move, then return to idle on completion.
        // Only restart idle for this character if it is still the selected player
        // when the move finishes — avoids re-animating a character whose turn ended
        // while they were walking (race condition between move duration and endTurn).
        if let sprite = target as? SpriteNode {
            animate(state: .walk, target: sprite)
            let charId = sprite.characterId   // capture before async
            let onComplete = SKAction.run { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Re-animate only if this character is still the active player.
                    // Enemies (characterId is empty, enemyId is set) always get idle back.
                    let isEnemy = sprite.team == "enemy"
                    let isStillActive = isEnemy
                        || GameState.shared.selectedCharacterId?.uuidString == charId
                    if isStillActive {
                        self.animate(state: .idle, target: sprite)
                    }
                }
            }
            target.run(SKAction.sequence([move, onComplete]))
            sprite.tileX = x
            sprite.tileY = y
        } else {
            target.run(move)
        }
    }

    /// Pulse selection ring around a character.
    func animateSelect(target: SKNode) {
        // Determine color: CYAN for players, gold for enemies
        let isPlayer = (target as? SpriteNode)?.team == "player"
        let ringColor = isPlayer ? UIColor(hex: "#00FFFF") : UIColor(hex: "#FFD700")

        let ring = SKShapeNode(circleOfRadius: 18)
        ring.strokeColor = ringColor
        ring.lineWidth = 2.5
        ring.fillColor = .clear
        ring.name = "selectionRing"
        ring.zPosition = 10
        target.addChild(ring)

        // Add inner counter-rotating ring
        let innerRing = SKShapeNode(circleOfRadius: 14)
        innerRing.strokeColor = ringColor.withAlphaComponent(0.6)
        innerRing.lineWidth = 1.5
        innerRing.fillColor = .clear
        innerRing.name = "selectionRingInner"
        innerRing.zPosition = 10
        target.addChild(innerRing)

        // Dramatic pulse animation (1.0 to 1.3 scale)
        let pulse = SKAction.sequence([
            SKAction.scale(to: 1.3, duration: 0.35),
            SKAction.scale(to: 1.0, duration: 0.35)
        ])
        ring.run(SKAction.repeatForever(pulse))

        // Inner ring counter-rotates
        let counterRotate = SKAction.rotate(byAngle: .pi * 2, duration: 2.0)
        innerRing.run(SKAction.repeatForever(counterRotate))
    }

    /// Remove selection ring.
    func deselect(target: SKNode) {
        target.childNode(withName: "selectionRing")?.removeFromParent()
        target.childNode(withName: "selectionRingInner")?.removeFromParent()
    }

    /// Update HP, Stun label and level badge on a sprite.
    func updateHP(on node: SKNode, currentHP: Int, maxHP: Int, currentStun: Int = 0, maxStun: Int = 0, level: Int = 1, isPlayer: Bool = false) {
        // Update HP bar fill - left-anchored (drains from right like classic HP bars)
        guard let barFill = node.childNode(withName: "hpBarFill") as? SKShapeNode,
              let bgNode = node.childNode(withName: "hpBarBg"),
              let barWidth = bgNode.userData?["barWidth"] as? CGFloat else { return }

        let pct = max(0.0, min(1.0, Double(currentHP) / Double(maxHP)))
        let fillWidth = barWidth * CGFloat(pct)

        let barColor: UIColor = currentHP > maxHP / 2 ? UIColor(hex: "#00FF88")
            : currentHP > maxHP / 4 ? UIColor.yellow
            : UIColor(hex: "#FF3333")

        let newPath = CGPath(roundedRect: CGRect(x: 0, y: -2, width: fillWidth, height: 4),
                              cornerWidth: 2, cornerHeight: 2, transform: nil)
        barFill.path = newPath
        barFill.fillColor = barColor

        if let glowLine = node.childNode(withName: "hpGlowLine") as? SKShapeNode {
            glowLine.strokeColor = barColor.withAlphaComponent(0.3)
        }

        if let hpLabel = node.childNode(withName: "hpLabel") as? SKLabelNode {
            hpLabel.text = "\(currentHP)/\(maxHP)"
            hpLabel.fontColor = barColor
        }

        // Update stun bar fill (yellow-orange, left-anchored)
        if let stunFill = node.childNode(withName: "stunBarFill") as? SKShapeNode,
           let stunBg = node.childNode(withName: "stunBarBg"),
           let stunBarWidth = stunBg.userData?["barWidth"] as? CGFloat,
           maxStun > 0 {
            let stunPct = max(0.0, min(1.0, Double(currentStun) / Double(maxStun)))
            let stunFillWidth = stunBarWidth * CGFloat(stunPct)
            let stunColor: UIColor = stunPct > 0.7 ? UIColor(hex: "#FF4400") : UIColor(hex: "#FFAA00")
            let stunPath = CGPath(roundedRect: CGRect(x: 0, y: -1.25, width: max(0, stunFillWidth), height: 2.5),
                                   cornerWidth: 1, cornerHeight: 1, transform: nil)
            stunFill.path = stunPath
            stunFill.fillColor = stunColor
        }
    }
}

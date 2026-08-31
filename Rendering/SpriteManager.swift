import SpriteKit
import UIKit

// MARK: - SpriteState

enum SpriteState {
    case idle
    case walk
    case attack
    case hit
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

    /// Pre-loaded attack textures for each player archetype.
    /// These were always present on disk (samurai_attack_*, mage_attack_*,
    /// etc.) but the original loader never pulled them in — `animateAttack`
    /// would silently fall back to using `playerWalkTextures` as the attack
    /// cycle, which is why the dedicated attack poses never appeared on
    /// screen. Wired 2026-05.
    private var playerAttackTextures: [String: [SKTexture]] = [:]

    // MARK: - Enemy Texture Cache

    // MARK: - Background Texture Cache (bounded)

    /// Room background textures are large (multi-MB PNGs) and were re-decoded
    /// from disk on EVERY room entry — including backtracking through cleared
    /// rooms (common in the multi-room missions). Memoize the decoded texture
    /// per background name so a revisited room reuses it instead of hitting
    /// disk + decoding again.
    ///
    /// Bounded on purpose: when the cache exceeds `bgCacheCap` distinct
    /// backgrounds it flushes wholesale (costing a single cache miss on the
    /// next load) so memory can't grow without limit across a long session.
    /// A mission has only a handful of rooms, so in practice it never flushes
    /// mid-mission. Behaviour is identical — same texture object, just fewer
    /// disk decodes.
    private var backgroundTextureCache: [String: SKTexture] = [:]
    private let bgCacheCap = 8

    /// Idle frames for each enemy type (guard, elite, drone, corpmage, medic, boss, mech).
    private var enemyIdleTextures:   [String: [SKTexture]] = [:]
    /// Walk frames for each enemy type.
    private var enemyWalkTextures:   [String: [SKTexture]] = [:]
    /// Attack frames for each enemy type.
    private var enemyAttackTextures: [String: [SKTexture]] = [:]
    /// Hit/flinch frames for each enemy type (optional — enemies without them
    /// just use the spark/recoil VFX on damage).
    private var enemyHitTextures: [String: [SKTexture]] = [:]

    /// Maps raw enemy type strings from GameState to the PNG filename prefix.
    private func enemySpriteKey(for type: String) -> String {
        switch type.lowercased() {
        case "guard":                    return "guard"
        case "drone":                    return "drone"
        case "elite":                    return "elite"
        case "mage", "corpmage":         return "corpmage"
        // Boss mage (M3 phase-2). Prefer dedicated bossmage_*.png frames
        // when shipped; fall back to the corpmage set at boss scale until
        // the new art is dropped in.
        case "bossmage":
            return (enemyIdleTextures["bossmage"]?.isEmpty == false) ? "bossmage" : "corpmage"
        case "medic", "healer":          return "medic"
        case "boss":                     return "boss"
        case "mech":                     return "mech"
        case "bossmech":                 return "bossmech"   // M5 boss — uses bossmech_*.png frames
        case "bossagi":                  return "bossagi"    // M6 boss — uses bossagi_*.png frames
        // M4 boss (Vera Koss). Prefer dedicated bosscorp_*.png frames when
        // shipped; until then fall back to the humanoid elite set at boss scale.
        case "bosscorp":
            return (enemyIdleTextures["bosscorp"]?.isEmpty == false) ? "bosscorp" : "elite"
        // 2026-05 specialist sprites: dedicated PNG sets shipped to
        // Sprites/frames/. Falls back to fallbackKey below if frames are
        // missing (e.g. older builds before art ships).
        case "sniper":                   return "sniper"
        case "bruiser":                  return "bruiser"
        case "spider":                   return "spider"
        case "riot":                     return "riot"
        case "turret":                   return "turret"
        case "rigger":                   return "rigger"
        case "netrunner":                return "netrunner"
        case "grenadier":                return "grenadier"
        case "juggernaut":               return "juggernaut"
        case "infiltrator":              return "infiltrator"
        case "repairdrone":              return "repairdrone"
        case "sprayer":                  return "sprayer"
        default:
            // A typo'd / new archetype silently rendering as a guard is a
            // common art-wiring miss — log it once per unknown string so it's
            // visible in the console instead of shipping a wrong sprite.
            if SpriteManager.loggedUnknownArchetypes.insert(type.lowercased()).inserted {
                dlog("[SpriteManager] ⚠️ unknown archetype '\(type)' → rendering as guard")
            }
            return "guard"
        }
    }
    private static var loggedUnknownArchetypes = Set<String>()

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
        case "bossmech": return UIColor(hex: "#FF7700")   // hazard orange — boss-class mech
        case "bossagi":  return UIColor(hex: "#00E5FF")   // electric cyan — projected AGI
        // New archetypes — sprite key still maps to elite/drone/mech above,
        // but the accent here keys off raw archetype string (looked up via the
        // enemy's `archetype` property in callers passing it directly).
        case "sniper":   return UIColor(hex: "#22FF66")
        case "bruiser":  return UIColor(hex: "#FF3333")
        case "spider":   return UIColor(hex: "#00FFCC")
        case "riot":     return UIColor(hex: "#3366FF")
        case "turret":   return UIColor(hex: "#FF2222")   // red sentry eye
        case "rigger":   return UIColor(hex: "#22CCAA")   // teal — drone-master tech
        case "netrunner": return UIColor(hex: "#00E5FF")  // electric cyan — matrix intruder
        case "grenadier": return UIColor(hex: "#FFAA22")  // hazard amber
        case "juggernaut": return UIColor(hex: "#CC3322")  // dried-blood red
        case "infiltrator": return UIColor(hex: "#8844FF")  // violet camo glow
        case "repairdrone": return UIColor(hex: "#FFCC33")  // industrial yellow
        case "sprayer":   return UIColor(hex: "#88DD22")  // toxic green
        default:         return UIColor(hex: "#FF2222")
        }
    }


    private init() {
        loadPlayerSpriteSheet()
        loadEnemySpriteFrames()
    }

    /// Called from the launch splash on a BACKGROUND thread. Merely referencing
    /// `SpriteManager.shared` already runs `init()` — which synchronously
    /// decodes + flood-fills every player/enemy frame (the expensive first-load
    /// work that used to stall the first Accept Contract). This method exists so
    /// that work is triggered behind the "INITIALIZING…" splash, then pushes the
    /// decoded textures to the GPU so the first combat render doesn't hitch.
    /// Safe off-main: UIImage decode, flood-fill (CGContext) and SKTexture are
    /// all thread-safe.
    func preloadAll() {
        let textures = enemyIdleTextures.values.flatMap { $0 }
            + playerIdleTextures.values.flatMap { $0 }
            + enemyAttackTextures.values.flatMap { $0 }
        if !textures.isEmpty { SKTexture.preload(textures) { } }
        dlog("[SpriteManager] preloadAll warmed \(textures.count) textures")
    }

    // MARK: - Enemy Sprite Loading

    /// Load individually-named PNG frames for each enemy type from Sprites/frames/.
    /// Files follow the naming convention: {type}_{anim}_{frame}.png
    /// e.g. guard_idle_0.png, boss_attack_1.png
    private func loadEnemySpriteFrames() {
        let enemyTypes = ["guard", "elite", "drone", "corpmage", "medic", "boss", "mech",
                          "sniper", "bruiser", "spider", "riot", "turret", "rigger", "netrunner", "grenadier", "juggernaut", "infiltrator", "repairdrone", "sprayer",
                          "bossmech", "bossagi", "bossmage", "bosscorp"]
        for eType in enemyTypes {
            var idle:   [SKTexture] = []
            var walk:   [SKTexture] = []
            var attack: [SKTexture] = []
            var hit:    [SKTexture] = []
            // PROBE loads (warnIfMissing: false): the naming convention allows
            // up to 4 idle/walk and 2 attack/hit frames, but most art sets
            // ship a subset (many types have 2 idles and no hit frames at
            // all). A miss here is expected — the animation code handles any
            // frame count ≥1 — so don't warn per miss; warn once below only
            // if a type has NO idle art (that one IS a visible bug: the enemy
            // would render as a blank/fallback).
            for i in 0..<4 {
                if let t = loadTexture(named: "\(eType)_idle_\(i).png", warnIfMissing: false)   { idle.append(t) }
                if let t = loadTexture(named: "\(eType)_walk_\(i).png", warnIfMissing: false)   { walk.append(t) }
            }
            for i in 0..<2 {
                if let t = loadTexture(named: "\(eType)_attack_\(i).png", warnIfMissing: false) { attack.append(t) }
                if let t = loadTexture(named: "\(eType)_hit_\(i).png", warnIfMissing: false)    { hit.append(t) }
            }
            // Some art ships a single UN-numbered hit pose (bossmech_hit.png,
            // bosscorp_hit.png) — those files sat in the bundle unused
            // because the probe only tried the _hit_N convention.
            if hit.isEmpty, let t = loadTexture(named: "\(eType)_hit.png", warnIfMissing: false) {
                hit.append(t)
            }
            if idle.isEmpty {
                dlog("[SpriteManager] WARNING: no idle frames found for enemy type '\(eType)' — it will render with the fallback sprite")
            }
            // Per-archetype frame filtering — some sprites have poses that at
            // our small render size + fast frame cycle read as a visual
            // glitch (split body, missing limbs, etc). Trim them down to the
            // tight-pose frames only so the loops stay clean.
            //
            // CORPMAGE — programmatic frame-content analysis (center-of-mass
            // and split-region detection) found TWO bad idle frames:
            //   • idle_2: SPLIT body — content in cols 3-17 + 50-76 with
            //             empty space between (cape parted, back-view)
            //   • idle_3: OFFSET LEFT by ~22px — character drawn at canvas
            //             center=18 instead of ~40, so cycling to this frame
            //             made the character appear to "jump left" then snap
            //             back, reading as a teleport glitch
            // Walk frames 0-3 are all centered (COM ≈ 40), so they're fine
            // to use — but the wide-cape pose in walk_2 still reads visually
            // glitchy at small render size. Filter conservatively:
            //   idle  → only idle_0 + idle_1 (both centered, single body)
            //   walk  → only walk_0 + walk_1 (both centered, tight pose)
            if eType == "corpmage" {
                if idle.count >= 2 {
                    idle = [idle[0], idle[1]]
                }
                if walk.count >= 2 {
                    walk = [walk[0], walk[1]]
                }
            }

            // BRUISER — visual inspection of all generated frames found a
            // similar duplicate-figure bug:
            //   • idle_2 / idle_3: TWO bruisers in frame (a SMALLER ghost
            //                      on the left + the normal one on the right).
            //                      Cycling to these frames made the player see
            //                      a second small bruiser flicker in/out and
            //                      the main figure appear to shift left.
            //   • walk_0 / walk_1 / walk_2: same double-figure bug
            //   • walk_3: clean single figure, but a totally different palette
            //             (blue-armor variant) and overhead-bat pose — would
            //             look like the sprite morphs mid-walk
            // Filter idle to the two clean frames. For walk, every frame is
            // broken (or wrong-palette), so re-use the clean idle frames as
            // the walk cycle — the bruiser will still animate while moving,
            // just using its idle breath, which is far better than the
            // glitched walk frames.
            // RIOT — idle_2 / idle_3 are split multi-figure frames (extra riot
            // troopers spill into the frame, reading as a glitch + spilling
            // outside the hex). Keep only the two clean single-figure frames.
            if eType == "riot", idle.count >= 2 {
                idle = [idle[0], idle[1]]
            }
            if eType == "bruiser" {
                if idle.count >= 2 {
                    idle = [idle[0], idle[1]]
                }
                // Override walk entirely — every bruiser_walk_*.png is bad.
                walk = idle
                // Attack frames are also broken:
                //   • attack_0: double-figure ghost on the left
                //   • attack_1: cropped torso-and-weapon close-up only
                // Empty out — the animateAttack() fallback flashes the
                // sprite colour instead, which reads fine on a melee unit.
                attack = []
            }

            if !idle.isEmpty   { enemyIdleTextures[eType]   = idle   }
            if !walk.isEmpty   { enemyWalkTextures[eType]   = walk   }
            if !attack.isEmpty { enemyAttackTextures[eType] = attack }
            if !hit.isEmpty    { enemyHitTextures[eType]    = hit    }
        }
        let summary = enemyTypes.map { "\($0): \(enemyIdleTextures[$0]?.count ?? 0)i" }.joined(separator: ", ")
        dlog("[SpriteManager] Enemy frames loaded — \(summary)")
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
        // Path 3: #file relative — walks up from Rendering/ to HexWire/Sprites/
        let sourceURL = URL(fileURLWithPath: #file)
        let url = sourceURL
            .deletingLastPathComponent()  // Rendering/
            .deletingLastPathComponent()  // HexWire/
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
            dlog("[SpriteManager] Using pre-cropped frame PNGs (preferred path)")
            return
        }

        // Fall back to slicing the spritesheet when individual PNGs aren't available
        // (production builds where #file-relative path doesn't work).
        guard let sheet = loadSpritesheetTexture() else {
            dlog("[SpriteManager] ERROR: neither frame PNGs nor spritesheet found")
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
        dlog("[SpriteManager] Spritesheet loaded (bleed-corrected) — \(loaded)")
    }

    /// Fallback: load individual PNG files from Sprites/frames/ bundle directory.
    private func loadPlayerSpriteSheetFromFiles() {
        let archetypes = ["samurai", "mage", "decker", "face"]
        for archetype in archetypes {
            var idleTextures:   [SKTexture] = []
            var walkTextures:   [SKTexture] = []
            var attackTextures: [SKTexture] = []
            for frame in 0..<2 {
                if let t = loadTexture(named: "\(archetype)_idle_\(frame).png", linear: true)   { idleTextures.append(t)   }
                // Attack pose PNGs ship at frames 0-1 for every player archetype.
                // (Face's frames are a back-view pose — clean single figure
                // but different camera angle from idle; acceptable for a
                // brief one-shot attack flash.)
                if let t = loadTexture(named: "\(archetype)_attack_\(frame).png", linear: true) { attackTextures.append(t) }
            }
            for frame in 0..<4 {
                if let t = loadTexture(named: "\(archetype)_walk_\(frame).png", linear: true)   { walkTextures.append(t)   }
            }
            if !idleTextures.isEmpty   { playerIdleTextures[archetype]   = idleTextures   }
            if !walkTextures.isEmpty   { playerWalkTextures[archetype]   = walkTextures   }
            if !attackTextures.isEmpty { playerAttackTextures[archetype] = attackTextures }
        }
        let loaded = playerIdleTextures.map { "\($0.key): \($0.value.count)i/\(playerWalkTextures[$0.key]?.count ?? 0)w/\(playerAttackTextures[$0.key]?.count ?? 0)a" }.joined(separator: ", ")
        dlog("[SpriteManager] File fallback loaded: \(loaded.isEmpty ? "NONE" : loaded)")
    }

    /// Build a nearest-filtered SKTexture, flood-filling the baked background
    /// out of `bosscorp_*` frames (Vera Koss shipped opaque — every other
    /// enemy frame set is pre-cut transparent, so this is a no-op for them).
    /// Enemy types whose source art shipped with an opaque (white) background
    /// instead of alpha — border flood-fill strips it so they don't render in
    /// a white box.
    private static let floodFillPrefixes = ["bosscorp", "turret",
        "rigger", "netrunner", "grenadier", "juggernaut", "infiltrator", "repairdrone", "sprayer"]

    private func makeEnemyTexture(from image: UIImage, named: String, linear: Bool = false) -> SKTexture {
        var img = image
        if SpriteManager.floodFillPrefixes.contains(where: { named.hasPrefix($0) }),
           let cut = BasementBrawlSpriteCache.removeBackground(image) {
            img = cut
        }
        let tex = SKTexture(image: img)
        // Player frames are smooth high-res art downscaled to ~68pt — nearest
        // sampling shimmered their edges between animation frames. Linear for
        // those; nearest preserved for the intentionally pixel-art enemies.
        tex.filteringMode = linear ? .linear : .nearest
        return tex
    }

    // MARK: - Background preload (ACCEPT CONTRACT freeze fix)

    /// Images pre-decoded off the main thread by `preloadMissionSprites`,
    /// consumed (and removed) by `loadTexture`. Keyed by frame filename.
    private var predecodedImages: [String: UIImage] = [:]

    /// Pre-decode the sprite frames a mission will need, on a background
    /// queue. Call when the briefing screen appears: PNG decode of dozens of
    /// ~1MB frames used to happen synchronously inside scene setup, freezing
    /// ACCEPT CONTRACT for ~30s on a cold launch. By the time the player has
    /// read the briefing and taps ACCEPT, the frames are decoded and scene
    /// setup just wraps them in SKTextures.
    func preloadMissionSprites(enemyTypes: [String]) {
        // Resolve keys + directory on the calling (main) thread — cheap.
        var keys: Set<String> = ["samurai", "mage", "decker", "face"]
        for t in enemyTypes { keys.insert(enemySpriteKey(for: t)) }
        guard let resourceURL = Bundle.main.resourceURL else { return }
        let framesDir = resourceURL.appendingPathComponent("Sprites/frames")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: framesDir.path)) ?? []
            var decoded: [String: UIImage] = [:]
            for name in names where name.hasSuffix(".png") {
                guard keys.contains(where: { name.hasPrefix($0 + "_") }) else { continue }
                let path = framesDir.appendingPathComponent(name).path
                guard let raw = UIImage(contentsOfFile: path) else { continue }
                var img = SpriteManager.forceDecoded(raw)
                // Pre-run the border flood fill for archetypes that need it
                // so the main thread skips that too. (makeEnemyTexture's
                // re-check early-returns on the already-transparent result.)
                if SpriteManager.floodFillPrefixes.contains(where: { name.hasPrefix($0) }),
                   let cut = BasementBrawlSpriteCache.removeBackground(img) {
                    img = cut
                }
                decoded[name] = img
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.predecodedImages.merge(decoded) { _, new in new }
                dlog("[SpriteManager] preloaded \(decoded.count) frames (\(keys.sorted().joined(separator: ", ")))")
            }
        }
    }

    /// Redraw to force PNG decompression NOW — UIImage defers decode to
    /// first render, which would put the cost right back on the main thread.
    private static func forceDecoded(_ image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(at: .zero)
        }
    }

    private func loadTexture(named: String, linear: Bool = false, warnIfMissing: Bool = true) -> SKTexture? {
        // ── Path 0: pre-decoded by preloadMissionSprites — skip disk + decode ──
        if let img = predecodedImages.removeValue(forKey: named) {
            return makeEnemyTexture(from: img, named: named, linear: linear)
        }
        // ── Path 1: Bundle.main subdirectory Sprites/frames/ (production app bundle) ─────
        if let resourceURL = Bundle.main.resourceURL {
            let framesURL = resourceURL
                .appendingPathComponent("Sprites")
                .appendingPathComponent("frames")
                .appendingPathComponent(named)
            if let image = UIImage(contentsOfFile: framesURL.path) {
                return makeEnemyTexture(from: image, named: named, linear: linear)
            }
        }

        // ── Path 2: root of bundle (some Xcode configurations) ────────────────────────
        if let url = Bundle.main.url(forResource: named, withExtension: nil),
           let image = UIImage(contentsOfFile: url.path) {
            return makeEnemyTexture(from: image, named: named, linear: linear)
        }

        // ── Path 3: resourcePath/Sprites/frames/ ─────────────────────────────────────
        if let resourcePath = Bundle.main.resourcePath {
            let fullPath = resourcePath + "/Sprites/frames/" + named
            if let image = UIImage(contentsOfFile: fullPath) {
                return makeEnemyTexture(from: image, named: named, linear: linear)
            }
        }

        // ── Path 4: Project directory via #file (Xcode Simulator dev workflow) ────────
        // SpriteManager.swift is at HexWire/Rendering/SpriteManager.swift
        // Go up two directories: Rendering/ → HexWire/ → Sprites/frames/
        let sourceURL = URL(fileURLWithPath: #file)
        let projectFramesURL = sourceURL
            .deletingLastPathComponent()  // Rendering/
            .deletingLastPathComponent()  // HexWire/
            .appendingPathComponent("Sprites")
            .appendingPathComponent("frames")
            .appendingPathComponent(named)
        if let image = UIImage(contentsOfFile: projectFramesURL.path) {
            return makeEnemyTexture(from: image, named: named, linear: linear)
        }

        // Probing callers (the frame loader tries idle_0..3 / walk_0..3 /
        // attack_0..1 / hit_0..1 for EVERY type, and most art sets ship a
        // subset) pass warnIfMissing: false — a miss there is expected, not
        // an error, and used to spray ~90 warnings on every launch.
        if warnIfMissing {
            dlog("[SpriteManager] WARNING: Could not load texture '\(named)' from any path")
        }
        return nil
    }

    /// Load a tile sprite texture from Sprites/tiles/ directory.
    /// Tries bundle paths first, then project directory via #file.
    /// Load a per-room background image. Same lookup paths as tile textures
    /// but searches `Sprites/backgrounds/`.
    func loadBackgroundTexture(named: String) -> SKTexture? {
        if let cached = backgroundTextureCache[named] { return cached }
        guard let tex = loadFromSpritesSubdir("backgrounds", filename: named) else { return nil }
        // Bounded flush — keep memory from growing across many rooms/missions.
        if backgroundTextureCache.count >= bgCacheCap {
            backgroundTextureCache.removeAll(keepingCapacity: true)
        }
        backgroundTextureCache[named] = tex
        return tex
    }

    /// Generic Sprites/<subdir>/<file> texture loader (bundle → resource path → #file fallback).
    private func loadFromSpritesSubdir(_ subdir: String, filename: String) -> SKTexture? {
        let baseName = filename.replacingOccurrences(of: ".png", with: "")
            .replacingOccurrences(of: ".jpg", with: "")
            .replacingOccurrences(of: ".jpeg", with: "")
        let ext = filename.contains(".jpg") ? "jpg" : (filename.contains(".jpeg") ? "jpeg" : "png")

        // === Path attempt #0: UIImage(named:) — iOS-canonical, works on
        // device for folder references and asset catalogs. This is the
        // most reliable path for sideloaded iOS apps.
        if let image = UIImage(named: baseName) {
            let tex = SKTexture(image: image); tex.filteringMode = .linear; return tex
        }
        // Also try the bare filename (some folder references end up with it
        // registered as the leafname).
        if let image = UIImage(named: filename) {
            let tex = SKTexture(image: image); tex.filteringMode = .linear; return tex
        }
        // === Path attempt #1: Bundle.url with subdirectory ===
        if let url = Bundle.main.url(forResource: baseName, withExtension: ext, subdirectory: "Sprites/\(subdir)") {
            if let image = UIImage(contentsOfFile: url.path) {
                let tex = SKTexture(image: image); tex.filteringMode = .linear; return tex
            }
            dlog("[SpriteManager] BG.1 found URL but UIImage failed: \(url.path)")
        }
        // === Path attempt #2: Bundle.url FLAT (files at bundle root) ===
        if let url = Bundle.main.url(forResource: baseName, withExtension: ext) {
            if let image = UIImage(contentsOfFile: url.path) {
                let tex = SKTexture(image: image); tex.filteringMode = .linear; return tex
            }
            dlog("[SpriteManager] BG.2 found URL (flat) but UIImage failed: \(url.path)")
        }
        // === Path attempt #3: resourceURL + appended path ===
        if let resourceURL = Bundle.main.resourceURL {
            let url = resourceURL.appendingPathComponent("Sprites").appendingPathComponent(subdir).appendingPathComponent(filename)
            if let image = UIImage(contentsOfFile: url.path) {
                let tex = SKTexture(image: image); tex.filteringMode = .linear; return tex
            }
        }
        // === Path attempt #4: resourcePath + string concat ===
        if let resourcePath = Bundle.main.resourcePath {
            let path = resourcePath + "/Sprites/\(subdir)/" + filename
            if let image = UIImage(contentsOfFile: path) {
                let tex = SKTexture(image: image); tex.filteringMode = .linear; return tex
            }
        }
        // === Path attempt #5: source-relative (dev only) ===
        let sourceURL = URL(fileURLWithPath: #file)
        let projectURL = sourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sprites")
            .appendingPathComponent(subdir)
            .appendingPathComponent(filename)
        if let image = UIImage(contentsOfFile: projectURL.path) {
            let tex = SKTexture(image: image); tex.filteringMode = .linear; return tex
        }

        // VERBOSE DIAGNOSTIC — dump what we know about the bundle so we can
        // see exactly what's wrong on device.
        let rp = Bundle.main.resourcePath ?? "<nil>"
        let ru = Bundle.main.resourceURL?.path ?? "<nil>"
        let triedSubdir = ru + "/Sprites/\(subdir)/\(filename)"
        let subdirFiles = (try? FileManager.default.contentsOfDirectory(atPath: ru + "/Sprites/\(subdir)")) ?? []
        let rootFiles = (try? FileManager.default.contentsOfDirectory(atPath: ru)) ?? []
        let spritesFiles = (try? FileManager.default.contentsOfDirectory(atPath: ru + "/Sprites")) ?? []
        dlog("""
        [SpriteManager] ⚠️ FAILED to load Sprites/\(subdir)/\(filename)
          resourcePath: \(rp)
          resourceURL:  \(ru)
          triedFullPath: \(triedSubdir)
          file exists at triedFullPath: \(FileManager.default.fileExists(atPath: triedSubdir))
          Sprites/\(subdir)/ listing (\(subdirFiles.count) items): \(subdirFiles.prefix(8))
          Sprites/ listing (\(spritesFiles.count) items): \(spritesFiles.prefix(8))
          bundle root listing first 10 of \(rootFiles.count): \(rootFiles.prefix(10))
        """)
        return nil
    }

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

    private func addSpriteOutline(
        texture: SKTexture,
        to container: SKNode,
        scale: CGFloat,
        position: CGPoint,
        anchorPoint: CGPoint,
        color: UIColor,
        flippedX: Bool = false,
        enabled: Bool = false
    ) {
        guard enabled else { return }

        let offsets: [CGPoint] = [
            CGPoint(x: -1.4, y: 0), CGPoint(x: 1.4, y: 0),
            CGPoint(x: 0, y: -1.4), CGPoint(x: 0, y: 1.4)
        ]

        for offset in offsets {
            let outline = SKSpriteNode(texture: texture)
            outline.setScale(scale)
            if flippedX { outline.xScale = -scale }
            outline.anchorPoint = anchorPoint
            outline.position = CGPoint(x: position.x + offset.x, y: position.y + offset.y)
            outline.color = color
            outline.colorBlendFactor = 1.0
            outline.alpha = 0.62
            outline.zPosition = 9.2
            outline.name = "spriteOutline"
            container.addChild(outline)
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

    // MARK: - Character Sprites

    /// Create a character sprite. type: archetype string; team: "player" or "enemy"
    /// level: pass for player sprites to display correctly; defaults to 1 for enemies
    /// Creates a character sprite container. `ownerId` (when supplied) is
    /// used to UUID-suffix every HP-bar / stun-bar / level-badge child node
    /// name (e.g. `"hpBarFill_<uuid>"`). This is defense-in-depth against
    /// the DFS-collision bug pattern where `childNode(withName: "hpBarFill")`
    /// returns the FIRST matching descendant — if any future code path adds
    /// a stale HP bar to the same container, updates would silently land on
    /// the wrong node. Suffixing ensures lookups are unique per character.
    /// Backward compatible: `updateHP` falls back to the unsuffixed name if
    /// no suffixed match is found.
    func createCharacter(type: String, team: String, x: Int, y: Int, name: String = "", level: Int = 1, ownerId: String = "", labelStaggerIndex: Int = 0) -> SpriteNode {
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

        if team == "player" {
            let teamHex = SKShapeNode(path: TileMap.hexPath(radius: TileMap.hexRadius * 0.82))
            teamHex.fillColor = UIColor(hex: "#00FF9D").withAlphaComponent(0.30)
            teamHex.strokeColor = UIColor(hex: "#D7FFF0").withAlphaComponent(0.50)
            teamHex.lineWidth = 2.6
            teamHex.glowWidth = 6.0
            teamHex.position = .zero
            teamHex.zPosition = 0.25
            teamHex.name = "characterTeamHex"
            container.addChild(teamHex)
        }

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
            case "healer":  baseColor = UIColor(hex: "#FF44AA")
            case "mech":    baseColor = UIColor(hex: "#FFCC00")
            case "sniper":  baseColor = UIColor(hex: "#22FF66")
            case "bruiser": baseColor = UIColor(hex: "#FF3333")
            case "spider":  baseColor = UIColor(hex: "#00FFCC")
            case "riot":    baseColor = UIColor(hex: "#3366FF")
            case "rigger":  baseColor = UIColor(hex: "#22CCAA")
            case "netrunner": baseColor = UIColor(hex: "#00E5FF")
            case "grenadier": baseColor = UIColor(hex: "#FFAA22")
            case "juggernaut": baseColor = UIColor(hex: "#CC3322")
            case "infiltrator": baseColor = UIColor(hex: "#8844FF")
            case "repairdrone": baseColor = UIColor(hex: "#FFCC33")
            case "sprayer":   baseColor = UIColor(hex: "#88DD22")
            default:        baseColor = UIColor(hex: "#FF3333")
            }
        }

        // (Identity letter labels removed 2026-05 — runners are identified by
        // their sprite art now, not by an "S/M/D/F" overlay.)

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
                // Reduced again 2026-05 (76/80 → 68/72) — playtest showed
                // players slightly oversized vs enemies on the resized map.
                // 2026-05: per playtest, Sable's mage sprite was reading as
                // oversized vs the team and her HUD/HP bar was blocking part
                // of the map. Normalized mage down to 68 to match the rest of
                // the roster. Face left at 72 (Lyra is intentionally taller).
                let targetH: CGFloat
                switch archKey {
                case "samurai": targetH = 68
                case "mage":    targetH = 68
                case "decker":  targetH = 68
                case "face":    targetH = 72
                default:        targetH = 68
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
                // Feet lifted to -10 (was -18) so the runner stands CENTERED on
                // the hex rather than down at its bottom edge. Enemies use the
                // same -10 so both sit at matching height on their tiles.
                spriteNode.position = CGPoint(x: 0, y: -10)
                addSpriteOutline(
                    texture: tex,
                    to: container,
                    scale: scale,
                    position: spriteNode.position,
                    anchorPoint: spriteNode.anchorPoint,
                    color: playerColor,
                    flippedX: archKey == "samurai"
                )
                spriteNode.zPosition = 10   // well above floor ring (0.5) and all tile art
                spriteNode.name = "characterSprite"
                container.addChild(spriteNode)

                // Animate idle: swap between the 2 idle frames.
                // resize:false — keeps spriteNode.size locked to the size we set at
                // creation, so the displayed sprite doesn't pulse/jitter between
                // frames even if SK reports the texture's intrinsic size differently
                // (the visual "splitting in half" the player saw was caused by
                // resize:true reapplying texture dims every tick).
                if idleFrames.count >= 2 {
                    let idleAnim = SKAction.animate(with: idleFrames, timePerFrame: 0.5,
                                                    resize: false, restore: false)
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

            // HP / stun bar nodes — UUID-suffixed when an ownerId was supplied
            // so DFS lookups in updateHP can never alias to a stale duplicate
            // child. See `createCharacter` doc comment.
            let nameSuffix = ownerId.isEmpty ? "" : "_\(ownerId)"

            // Per-character vertical stagger: at spawn, 4 runners cluster in
            // adjacent hexes on the same row, and their HP labels would all
            // render at the same Y → completely overlap → unreadable. Stagger
            // each owner's label group by `labelStaggerIndex * 5pt` so they
            // form a small vertical stack when crowded but stay glued to
            // each character once they spread out. Pattern: 0, -5, -10, -15.
            // Negative shifts the bars FURTHER below the sprite (away from
            // the head), keeping the head/intent area uncluttered.
            // Bars sit just under each runner. The per-character stagger only
            // exists to stop 4 spawn-clustered runners' labels from perfectly
            // overlapping — kept SMALL (−2.5pt each) so every bar stays glued
            // close to its owner instead of floating far below (which read as
            // "whose bar is that?"). Pulled the whole group up (−26 → −18) so
            // the bar hugs the unit.
            // Bars sit ABOVE the runner's head — consistent with the enemy HP
            // bars (BattleScene places those at y≈50) so EVERY unit's health
            // reads in the same place, above the sprite, clear of the busy tile
            // floor (hex markers / selection rings). Was below the feet (-18),
            // which clashed with enemies-above and sat in the tile clutter.
            // Feet anchor sits at y=-10; tallest runner (face, 72pt) has its
            // sprite TOP at y≈+62, the rest at +58. Bars were at 47-62, drawn
            // across the head/torso. Lift the whole group +19 so the lowest
            // element (stun bar) clears even the tallest sprite's head.
            // 2026-06-12 playtest: 71/66/81 floated too far above the head —
            // pulled the group down 6-9pt so it hugs the sprite top (~58-62)
            // with just a sliver of gap.
            let stagger: CGFloat = CGFloat(labelStaggerIndex) * 2.5
            let hpBarY: CGFloat   = 65 + stagger
            let stunBarY: CGFloat = 61 + stagger
            let hpLabelY: CGFloat = 72 + stagger

            // HP bar background + fill — reduced 32 → 26 wide per playtest
            // note (bars overall too chunky relative to the sprite). Center-
            // anchored fill drains symmetrically (see updateHP).
            let playerBarWidth: CGFloat = 26
            let hpBg = SKShapeNode(rectOf: CGSize(width: playerBarWidth, height: 4), cornerRadius: 2)
            hpBg.fillColor = UIColor(hex: "#1A0000")
            hpBg.strokeColor = UIColor(hex: "#330000")
            hpBg.lineWidth = 0.5
            hpBg.position = CGPoint(x: 0, y: hpBarY)
            hpBg.zPosition = 20
            hpBg.name = "hpBarBg\(nameSuffix)"
            hpBg.userData = NSMutableDictionary()
            hpBg.userData?["barWidth"] = playerBarWidth
            container.addChild(hpBg)

            // Add thin glow line around HP bar
            let hpGlow = SKShapeNode(rectOf: CGSize(width: playerBarWidth, height: 4), cornerRadius: 2)
            hpGlow.fillColor = .clear
            hpGlow.strokeColor = UIColor(hex: "#00FF88").withAlphaComponent(0.3)
            hpGlow.lineWidth = 1
            hpGlow.position = CGPoint(x: 0, y: hpBarY)
            hpGlow.zPosition = 19
            hpGlow.name = "hpGlowLine\(nameSuffix)"
            container.addChild(hpGlow)

            let hpBarFill = SKShapeNode()
            hpBarFill.fillColor = UIColor(hex: "#00FF88")
            hpBarFill.strokeColor = .clear
            hpBarFill.position = CGPoint(x: 0, y: hpBarY)
            hpBarFill.zPosition = 21
            hpBarFill.name = "hpBarFill\(nameSuffix)"
            container.addChild(hpBarFill)

            // Stun bar (yellow-orange, SR5 stun track) — tracks HP bar width.
            let stunBg = SKShapeNode(rectOf: CGSize(width: playerBarWidth, height: 2.5), cornerRadius: 1)
            stunBg.fillColor = UIColor(hex: "#1A1000")
            stunBg.strokeColor = .clear
            stunBg.position = CGPoint(x: 0, y: stunBarY)
            stunBg.zPosition = 20
            stunBg.name = "stunBarBg\(nameSuffix)"
            stunBg.userData = NSMutableDictionary()
            stunBg.userData?["barWidth"] = playerBarWidth
            container.addChild(stunBg)

            let stunBarFill = SKShapeNode()
            stunBarFill.fillColor = UIColor(hex: "#FFAA00")
            stunBarFill.strokeColor = .clear
            stunBarFill.position = CGPoint(x: 0, y: stunBarY)
            stunBarFill.zPosition = 21
            stunBarFill.name = "stunBarFill\(nameSuffix)"
            container.addChild(stunBarFill)

            // HP numeric label below bar (placeholder - updated via updateHP after placement)
            let hpLabel = SKLabelNode(text: "-/-")
            hpLabel.fontName = "Menlo-Bold"
            hpLabel.fontSize = 8
            hpLabel.fontColor = UIColor(hex: "#00FF88")
            hpLabel.position = CGPoint(x: 0, y: hpLabelY)
            hpLabel.zPosition = 21
            hpLabel.name = "hpLabel\(nameSuffix)"
            container.addChild(hpLabel)

        } else {
            // ── Enemy sprites: use dedicated PNG frames generated for each enemy type ─────
            let eKey = enemySpriteKey(for: type)
            // Accent uses the RAW archetype string so reinforcement specialists
            // (sniper/bruiser/spider/riot) get distinct hex-ring tints even when
            // they share an underlying sprite key with an existing enemy.
            let accentColor = enemyAccentColor(for: type.lowercased())
            // Boss-scale check. `bossmage` (M3) maps eKey → "corpmage" (it
            // reuses those frames), so it wouldn't be caught by eKey alone —
            // also check the raw archetype string to flag it as a boss.
            let rawType = type.lowercased()
            let isBoss = (eKey == "boss" || eKey == "mech" || eKey == "bossmech" || eKey == "bossagi"
                          || eKey == "bossmage" || eKey == "bosscorp" || rawType == "bossmage")

            container.spriteTypeKey = eKey   // stored so animate() can find correct frames

            // Enemy tile marker. Sized + positioned to match the PLAYER floor
            // accent (radius hexRadius-3, centered at the container origin =
            // tile center) so the red hex lines up exactly with the grid the
            // players move on. Was radius 28 @ y:-8, which read as ~8px low and
            // a touch small — a slight but noticeable misalignment vs the grid.
            let enemyBaseRadius: CGFloat = isBoss ? 34 : (TileMap.hexRadius - 3)
            let enemyBaseGlow = SKShapeNode(path: TileMap.hexPath(radius: enemyBaseRadius))
            enemyBaseGlow.name = "enemyBaseGlow"
            enemyBaseGlow.fillColor = UIColor(hex: "#FF2438").withAlphaComponent(0.14)
            enemyBaseGlow.strokeColor = UIColor(hex: "#FF4A4A").withAlphaComponent(0.62)
            enemyBaseGlow.lineWidth = 1.6
            enemyBaseGlow.glowWidth = 4.0
            enemyBaseGlow.position = CGPoint(x: 0, y: 0)   // tile center — on the grid
            enemyBaseGlow.zPosition = 0.35
            container.addChild(enemyBaseGlow)

            if let idleFrames = enemyIdleTextures[eKey], let firstTex = idleFrames.first {
                // Main sprite node — NO color tint; sprites carry their own palette.
                // Bottom-anchored + height-based scaling so the enemy stands on the
                // tile. Height tuned so the sprite's vertical center sits roughly
                // at the hex tile center, which is what the player perceives as
                // "centered on the tile" in this top-ish-down hex view.
                // Bumped 2026-05 (was 62/76 → 70/84) so enemy sprites match
                // the visual weight of player sprites (now 68/72).
                // Boss-class scale — same 140pt size for both finale bosses
                // (M5 mech and M6 AGI). Other "boss" archetype enemies
                // use the legacy 84pt boss size.
                let targetH: CGFloat
                switch eKey {
                case "bossmech", "bossagi": targetH = 140
                case "bossmage":            targetH = 130  // dedicated frames — final-boss tier
                case "bosscorp":            targetH = 120  // Vera Koss — playtest "too diminutive"; was falling through to the generic 84pt boss size
                // The rigger figure sits small within its canvas, so scaling
                // by canvas height left it noticeably shorter than the other
                // grunts (playtest 2026-06-12). Bump its target height to
                // bring the figure up to peer size.
                case "rigger":              targetH = 82
                // Cyber-Zombie. `targetH` scales the CANVAS, and the juggernaut
                // art only fills 86% of its canvas vertically — so at the
                // default 70 it rendered a ~60pt figure, the SMALLEST enemy on
                // the board, for a unit the codex calls "a walking wall of
                // bolted chrome" (playtest 2026-07-25: "should be bigger").
                // 99 × 0.86 ≈ 85pt: clearly the biggest non-boss, still well
                // under the 120–140 boss tier.
                case "juggernaut":          targetH = 99
                // Riot art re-extracted 2026-07 from the enemy sheet with a
                // FULL helmet (the old frames had the crown cropped flat).
                // 264x200 canvas, figure ~0.85 of height → 79 renders it
                // peer-sized (~67pt, matching the guards).
                case "riot":                targetH = 79
                default:
                    // Bossmage with no dedicated frames yet (placeholder path,
                    // reuses corpmage). Still oversized so it reads as a boss.
                    if rawType == "bossmage" { targetH = 120 }
                    else if isBoss            { targetH = 84  }
                    else                       { targetH = 70  }
                }
                let spriteNode = SKSpriteNode(texture: firstTex)
                let scale = targetH / max(spriteNode.size.height, 1.0)
                spriteNode.setScale(scale)
                spriteNode.anchorPoint = CGPoint(x: 0.5, y: 0.0)
                // Per-archetype X nudge to compensate for sprites whose
                // character isn't perfectly centered in their canvas.
                // Corpmage idle frames have COM around col 41.5 (canvas
                // center is 40), so the sprite reads slightly RIGHT of
                // center. Shift LEFT a couple of points to bring it back.
                // Per-archetype X nudge — the sprite is bottom-anchored to the
                // FULL canvas, so any left/right bias of the figure within its
                // canvas shifts the unit off the centre of its hex. Values are
                // measured from the idle-frame alpha bbox:
                // xNudge ≈ -(figureCentroidX - canvasCentreX) × displayScale.
                let xNudge: CGFloat
                switch eKey {
                case "corpmage": xNudge = -3
                case "bruiser":  xNudge = -14  // -6 → -10 → -14: sprite kept drifting right, walking through the right edge of its hex
                case "riot":     xNudge = 0    // 2026-07 re-extracted art is feet-centered, no offset needed
                case "sniper":   xNudge = -9   // rifle/firing stance biases the figure ~23px right of centre (×0.39)
                case "spider":   xNudge = -2
                default:         xNudge = 0
                }
                // Per-archetype Y nudge — some canvases carry transparent
                // padding BELOW the feet, so bottom-anchoring floats the figure
                // above its hex. Drop it back to the ground by (bottomPad ×
                // displayScale).
                let yNudge: CGFloat
                switch eKey {
                case "spider":   yNudge = -20  // ~52px bottom padding (×0.39) left the spider hovering above its tile
                default:         yNudge = 0    // riot/most frames are trimmed to the figure bbox → already grounded
                }
                // Feet anchor lifted to -10 (was -hexRowSpacing/2 ≈ -18) so the
                // figure stands centered ON the hex rather than at its bottom
                // edge. Matches the player sprite's lifted feet exactly so
                // enemies and runners sit at the same height on their tiles.
                spriteNode.position = CGPoint(x: xNudge, y: -10 + yNudge)
                // Sprite outline (4 offset color-blended copies) — fine for
                // tight 154×178 enemy canvases where it reads as a thin halo,
                // but for the bossmage's high-res 1024×1536 PNG (character in
                // the centre of a mostly-transparent canvas) the offset
                // copies render as a giant blue-grey rectangle around the
                // canvas edge. Disabled for bossmage; the character art is
                // already cinematic enough to stand alone.
                // The outline is 4 STATIC copies of idle-frame-0; it never
                // animates. For enemies whose idle frames shift position
                // (the bruiser drifts side-to-side), that static halo lingers
                // at the old pose and reads as a ghost/afterimage. Disable it
                // for the bruiser (as for bossmage) to kill the double-image.
                // The static idle_0 outline desyncs (ghosts) the moment the
                // body swaps to an attack/hit/walk frame, so only keep it for
                // enemies with NO pose frames — a pure-idle enemy never
                // desyncs. (bossmage/bruiser were the originally-flagged cases;
                // this generalizes the rule to every animated archetype.)
                let hasPoseFrames = !(enemyAttackTextures[eKey]?.isEmpty ?? true)
                    || !(enemyHitTextures[eKey]?.isEmpty ?? true)
                    || !(enemyWalkTextures[eKey]?.isEmpty ?? true)
                addSpriteOutline(
                    texture: firstTex,
                    to: container,
                    scale: scale,
                    position: spriteNode.position,
                    anchorPoint: spriteNode.anchorPoint,
                    color: UIColor(hex: "#B8C7D9"),
                    enabled: rawType != "bossmage" && eKey != "bruiser" && !hasPoseFrames
                )
                spriteNode.zPosition = 10
                spriteNode.name = "characterSprite"
                spriteNode.colorBlendFactor = 0.0  // full original palette — no tint overlay
                spriteNode.alpha = 1.0
                spriteNode.isHidden = false
                // Bossmage: art is already painted blood-red — no tint or
                // outline. The earlier red overlay was only meant to
                // distinguish the placeholder (tinted corpmage); the real
                // dedicated frames don't need it.
                container.addChild(spriteNode)

                // Idle animation (cycle all idle frames at 0.35s/frame for smooth breathing).
                // resize:false / restore:false — without these, SpriteKit's default
                // resize:true would re-set sprite.size to texture.size each frame,
                // wiping the setScale() above and causing visible jitter / clip
                // glitching (most obvious on corpmage). Matches the rest of the
                // animation pipeline.
                if idleFrames.count >= 2 {
                    let idleAnim = SKAction.animate(with: idleFrames, timePerFrame: 0.35,
                                                    resize: false, restore: false)
                    spriteNode.run(SKAction.repeatForever(idleAnim), withKey: "idle")
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
                case "sniper":   fallbackKey = "samurai"; fallbackTint = UIColor(hex: "#22FF66")
                case "bruiser":  fallbackKey = "samurai"; fallbackTint = UIColor(hex: "#FF3333")
                case "spider":   fallbackKey = "decker";  fallbackTint = UIColor(hex: "#00FFCC")
                case "riot":     fallbackKey = "samurai"; fallbackTint = UIColor(hex: "#3366FF")
                case "rigger":   fallbackKey = "decker";  fallbackTint = UIColor(hex: "#22CCAA")
                case "netrunner": fallbackKey = "decker"; fallbackTint = UIColor(hex: "#00E5FF")
                case "grenadier": fallbackKey = "samurai"; fallbackTint = UIColor(hex: "#FFAA22")
                case "juggernaut": fallbackKey = "samurai"; fallbackTint = UIColor(hex: "#CC3322")
                case "infiltrator": fallbackKey = "decker"; fallbackTint = UIColor(hex: "#8844FF")
                case "repairdrone": fallbackKey = "decker"; fallbackTint = UIColor(hex: "#FFCC33")
                case "sprayer":   fallbackKey = "samurai"; fallbackTint = UIColor(hex: "#88DD22")
                default:         fallbackKey = "samurai"; fallbackTint = accentColor
                }
                if let fbFrames = playerIdleTextures[fallbackKey], let fbTex = fbFrames.first {
                    let fbSprite = SKSpriteNode(texture: fbTex)
                    let fbTargetH: CGFloat = 88
                    let fbScale = fbTargetH / max(fbSprite.size.height, 1.0)
                    fbSprite.setScale(fbScale)
                    fbSprite.anchorPoint = CGPoint(x: 0.5, y: 0.0)
                    fbSprite.position = CGPoint(x: 0, y: -18)
                    addSpriteOutline(
                        texture: fbTex,
                        to: container,
                        scale: fbScale,
                        position: fbSprite.position,
                        anchorPoint: fbSprite.anchorPoint,
                        color: UIColor(hex: "#B8C7D9"),
                        enabled: true
                    )
                    fbSprite.zPosition = 10
                    fbSprite.name = "characterSprite"
                    fbSprite.color = fallbackTint
                    fbSprite.colorBlendFactor = 0.55
                    fbSprite.alpha = 1.0
                    fbSprite.isHidden = false
                    container.addChild(fbSprite)
                    if fbFrames.count >= 2 {
                        let fbIdle = SKAction.animate(with: fbFrames, timePerFrame: 0.5,
                                                      resize: false, restore: false)
                        fbSprite.run(SKAction.repeatForever(fbIdle), withKey: "idle")
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

            // Enemy HP bar intentionally NOT added here — `BattleScene.placeEnemy`
            // builds the canonical HP bar/label above each enemy (y≈58/66) so it
            // floats over the sprite's head, not at its feet. Earlier this block
            // also added a "feet" HP UI inside the container; that created two
            // SKLabelNodes named "hpLabel" on the same node, and updateHP() only
            // refreshed whichever DFS found first — leaving the visible above-
            // sprite label frozen at its spawn-time value (the "14/14 vs 9/18"
            // corp-guard bug). Single source of truth lives in placeEnemy now.
            } // end fallback procedural enemy sprites
        }

        // Container zPosition must be ABOVE tile art so characters are always visible above the grid.
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
            // Play the dedicated flinch pose if the enemy has hit frames;
            // otherwise this no-ops and the spark/shake VFX carries the hit.
            animate(state: .hit, target: sprite)
        }
        for child in target.children {
            // HP/stun bars own their colors (updateHP's band thresholds) —
            // flashing them captured the PRE-hit color and wrote it back
            // 0.15s after updateHP set the new band, so the bar lied about
            // health until the next damage event.
            if let name = child.name, name.hasPrefix("hpBar") || name.hasPrefix("stunBar") { continue }
            if let shape = child as? SKShapeNode {
                let origColor = SpriteManager.baseFillColor(of: shape)
                let flash = SKAction.sequence([
                    SKAction.run { shape.fillColor = .white },
                    SKAction.wait(forDuration: 0.05),
                    SKAction.run { shape.fillColor = origColor },
                    SKAction.wait(forDuration: 0.05),
                    SKAction.run { shape.fillColor = .white },
                    SKAction.wait(forDuration: 0.05),
                    SKAction.run { shape.fillColor = origColor }
                ])
                // Keyed: a second hit mid-flash replaces this one instead of
                // stacking with it (a stacked flash captured WHITE as the
                // "original" color and stuck it permanently).
                shape.removeAction(forKey: "hitFlash")
                shape.run(flash, withKey: "hitFlash")
            } else if let label = child as? SKLabelNode {
                let originalAlpha = label.alpha
                let flash = SKAction.sequence([
                    SKAction.fadeAlpha(to: 0.35, duration: 0.05),
                    SKAction.fadeAlpha(to: originalAlpha, duration: 0.05),
                    SKAction.fadeAlpha(to: 0.35, duration: 0.05),
                    SKAction.fadeAlpha(to: originalAlpha, duration: 0.05)
                ])
                label.removeAction(forKey: "hitFlash")
                label.run(flash, withKey: "hitFlash")
            }
        }
    }

    /// True base fill color of a shape, stashed in userData the first time a
    /// flash touches it. Re-capturing `fillColor` while a previous flash is
    /// mid-white recorded white as the "original".
    private static func baseFillColor(of shape: SKShapeNode) -> UIColor {
        if let stored = shape.userData?["baseFillColor"] as? UIColor {
            return stored
        }
        let base = shape.fillColor
        let ud = shape.userData ?? NSMutableDictionary()
        ud["baseFillColor"] = base
        shape.userData = ud
        return base
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
        case .hit:
            animateHitPose(target: target)
        }
    }

    /// Flinch: snap to the enemy's `_hit_0` pose for a beat, then resume idle.
    /// No-op for enemies without dedicated hit frames (they rely on the spark /
    /// screen-shake VFX in playHitEffect instead).
    private func animateHitPose(target: SpriteNode) {
        guard target.team == "enemy" else { return }
        let eKey = target.spriteTypeKey.isEmpty ? "guard" : target.spriteTypeKey
        guard let hitTex = enemyHitTextures[eKey]?.first,
              let spriteNode = target.childNode(withName: "characterSprite") as? SKSpriteNode else { return }
        // Clear ALL pose loops, not just attack/idle — a lingering "walk"
        // texture loop would fight the hit pose frame-by-frame.
        for key in ["attack", "idle", "walk", "hit"] { spriteNode.removeAction(forKey: key) }
        let resumeIdle: SKAction
        if let idleFrames = enemyIdleTextures[eKey], idleFrames.count >= 2 {
            resumeIdle = SKAction.repeatForever(
                SKAction.animate(with: idleFrames, timePerFrame: 0.35, resize: false, restore: false))
        } else {
            resumeIdle = SKAction.repeatForever(SKAction.sequence([
                SKAction.scale(to: 1.02, duration: 0.3), SKAction.scale(to: 1.0, duration: 0.3)]))
        }
        spriteNode.run(SKAction.sequence([
            SKAction.setTexture(hitTex, resize: false),
            SKAction.wait(forDuration: 0.35),
            SKAction.run { spriteNode.run(resumeIdle, withKey: "idle") }
        ]), withKey: "hit")
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
                    // resize:false — THIS IS THE FIX FOR THE CORPMAGE GLITCH.
                    // Default resize:true was re-setting sprite.size to each
                    // frame texture's native size every 0.35s, wiping the
                    // initial setScale and causing the half-body / split
                    // glitch the user has reported repeatedly. Matches the
                    // player-idle path 12 lines down.
                    let idleAnim = SKAction.animate(with: frames, timePerFrame: 0.35,
                                                    resize: false, restore: false)
                    spriteNode.run(SKAction.repeatForever(idleAnim), withKey: "idle")
                    return
                }
            }
            // Player: use archetype key from spriteTypeKey or derive from node name
            let archKey = target.spriteTypeKey.isEmpty
                ? archetypeKey(for: target.name ?? "samurai")
                : target.spriteTypeKey
            if let frames = playerIdleTextures[archKey], frames.count >= 2 {
                spriteNode.removeAction(forKey: "walk")
                // resize:false — keep spriteNode.size locked. Frame textures
                // for an archetype are uniform-canvas, so resize is a no-op
                // at best and a per-tick hidden glitch source at worst.
                let idleAnim = SKAction.animate(with: frames, timePerFrame: 0.5,
                                                resize: false, restore: false)
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
                // resize:false — match the rest of the animation pipeline so
                // pausing on the first idle frame doesn't briefly resize the
                // sprite to a different canvas dimension.
                spriteNode.run(SKAction.setTexture(firstFrame, resize: false))
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
                    // resize:false — sprite size stays locked to the dimensions set
                    // at sprite creation. All enemy walk frames are uniform-canvas
                    // PNGs (e.g. corpmage_walk_*.png are all 80×120), so resize
                    // is unnecessary and was causing per-frame jitter / split
                    // artifacts in the displayed sprite.
                    let walkAnim = SKAction.animate(with: frames, timePerFrame: 0.14, resize: false, restore: false)
                    spriteNode.run(SKAction.repeatForever(walkAnim), withKey: "walk")
                    return
                }
            }
            let archKey = target.spriteTypeKey.isEmpty
                ? archetypeKey(for: target.name ?? "samurai")
                : target.spriteTypeKey
            if let frames = playerWalkTextures[archKey], !frames.isEmpty {
                spriteNode.removeAction(forKey: "idle")
                // resize:false — keep spriteNode.size locked to its creation-time
                // dimensions so frame-to-frame texture swap can't cause vertical
                // jitter / sprite-splitting artifacts.
                let walkAnim = SKAction.animate(with: frames, timePerFrame: 0.12,
                                                resize: false, restore: false)
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
                // Try the dedicated player attack textures first. These ship as
                // `samurai_attack_*`, `mage_attack_*`, etc., and were silently
                // dropped on the floor by the old loader — leaving every player
                // attack falling through to walk frames. Wired up 2026-05.
                if let attack = playerAttackTextures[archKey], !attack.isEmpty {
                    attackFrames = attack
                } else {
                    attackFrames = playerWalkTextures[archKey]  // legacy fallback
                }
            }
            if let frames = attackFrames, !frames.isEmpty {
                // Clear the pending hit-pose resume too — a hit ≤0.35s before
                // this attack would otherwise fire its deferred idle restart
                // mid-attack, running two texture loops at once (flicker).
                spriteNode.removeAction(forKey: "idle")
                spriteNode.removeAction(forKey: "walk")
                spriteNode.removeAction(forKey: "hit")
                // Play attack sequence once, HOLD the final strike pose briefly
                // so the attack is clearly visible (players were only hearing the
                // SFX + seeing damage), then resume idle. Single-frame attack
                // sets (the 2026-05 specialists ship one `_attack_0`) still
                // swap to the strike pose + hold — was `>= 2`, which dropped
                // them to the color-flash fallback so they never animated.
                let attackAnim = SKAction.animate(with: frames, timePerFrame: 0.16,
                                                  resize: false, restore: false)
                let resumeIdle: SKAction
                if let idleFrames = (target.team == "enemy"
                    ? enemyIdleTextures[target.spriteTypeKey]
                    : playerIdleTextures[target.spriteTypeKey]),
                   idleFrames.count >= 2 {
                    resumeIdle = SKAction.repeatForever(
                        SKAction.animate(with: idleFrames, timePerFrame: 0.35,
                                         resize: false, restore: false))
                } else {
                    resumeIdle = SKAction.repeatForever(
                        SKAction.sequence([SKAction.scale(to: 1.02, duration: 0.3),
                                           SKAction.scale(to: 1.0, duration: 0.3)]))
                }
                // restore:false leaves the sprite on the last attack frame, so
                // a wait here holds that strike pose on screen before idling.
                spriteNode.run(SKAction.sequence([attackAnim,
                    SKAction.wait(forDuration: 0.4),
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
        // Cancel in-flight movement and pose loops FIRST. An overwatch kill
        // mid-move otherwise kept sliding the corpse to its destination, and
        // animateMove's completion restarted the idle loop on the dead body.
        target.removeAction(forKey: "move")
        if let body = target.childNode(withName: "characterSprite") {
            for key in ["idle", "walk", "attack", "hit"] {
                body.removeAction(forKey: key)
            }
        }
        // Brief white flash (0.1s)
        for child in target.children {
            if let name = child.name, name.hasPrefix("hpBar") || name.hasPrefix("stunBar") { continue }
            if let shape = child as? SKShapeNode, !(child.name?.contains("selection") ?? false) {
                let origColor = SpriteManager.baseFillColor(of: shape)
                let flash = SKAction.sequence([
                    SKAction.run { shape.fillColor = .white },
                    SKAction.wait(forDuration: 0.05),
                    SKAction.run { shape.fillColor = origColor },
                    SKAction.wait(forDuration: 0.05)
                ])
                shape.removeAction(forKey: "hitFlash")
                shape.run(flash, withKey: "hitFlash")
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

        // Cancel any in-flight move on this node so a second move call doesn't
        // sequence onto the first (which produced the "mage walks right, cuts
        // mid-step, snaps back to a different x" visual). The new move starts
        // from the node's CURRENT position — wherever the prior move was when
        // it got cancelled — so there's no teleport.
        target.removeAction(forKey: "move")

        // Walk animation during move, then return to idle on completion.
        // Only restart idle for this character if it is still the selected player
        // when the move finishes — avoids re-animating a character whose turn ended
        // while they were walking (race condition between move duration and endTurn).
        if let sprite = target as? SpriteNode {
            animate(state: .walk, target: sprite)
            let onComplete = SKAction.run { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // ALWAYS settle to idle when the move ends. The old guard
                    // only reset idle if the character was still selected, so a
                    // character you moved then deselected (or whose turn ended
                    // mid-walk) got stuck looping its walk frames in place —
                    // the "tweaking out" bug. Idle is the right resting pose
                    // regardless of selection.
                    self.animate(state: .idle, target: sprite)
                }
            }
            target.run(SKAction.sequence([move, onComplete]), withKey: "move")
            sprite.tileX = x
            sprite.tileY = y
        } else {
            target.run(move, withKey: "move")
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

        // Dramatic pulse animation (1.0 to 1.3 scale)
        let pulse = SKAction.sequence([
            SKAction.scale(to: 1.3, duration: 0.35),
            SKAction.scale(to: 1.0, duration: 0.35)
        ])
        ring.run(SKAction.repeatForever(pulse))
    }

    /// Remove selection ring.
    func deselect(target: SKNode) {
        target.childNode(withName: "selectionRing")?.removeFromParent()
        target.childNode(withName: "selectionRingInner")?.removeFromParent()
    }

    /// Resolve the owner-id suffix used when looking up HP-bar / stun-bar
    /// child nodes. Returns `"_<uuid>"` when the container is a `SpriteNode`
    /// with a non-empty characterId or enemyId — otherwise `""`. This is the
    /// counterpart to the suffix written at creation time so DFS lookups
    /// can address exactly the owner's nodes (no DFS-collision risk if a
    /// stale duplicate ever ends up in the same subtree).
    private func ownerSuffix(for node: SKNode) -> String {
        guard let sn = node as? SpriteNode else { return "" }
        if !sn.characterId.isEmpty { return "_\(sn.characterId)" }
        if !sn.enemyId.isEmpty     { return "_\(sn.enemyId)"     }
        return ""
    }

    /// DFS for a child by name, with backward-compatibility fallback to the
    /// unsuffixed legacy name. Used by updateHP so creation paths that haven't
    /// yet been updated to pass `ownerId` (or callers that still place
    /// nodes by the old generic name) keep working.
    private func childOwned<T: SKNode>(_ node: SKNode, _ baseName: String, _ suffix: String, as _: T.Type = T.self) -> T? {
        if let n = node.childNode(withName: "\(baseName)\(suffix)") as? T { return n }
        return node.childNode(withName: baseName) as? T
    }

    /// Update HP, Stun label and level badge on a sprite.
    func updateHP(on node: SKNode, currentHP: Int, maxHP: Int, currentStun: Int = 0, maxStun: Int = 0, level: Int = 1, isPlayer: Bool = false) {
        let suffix = ownerSuffix(for: node)

        // HP bar fill — CENTER-anchored so the fill stays aligned with the
        // background bar (which is created via SKShapeNode(rectOf:) and is
        // therefore also center-anchored). Drains symmetrically from both
        // sides as HP depletes. The previous left-anchored impl (x:0,...)
        // caused the fill to start at the bg's center and extend RIGHT
        // past the bg's right edge — at full HP players saw a black gap
        // on the left and green spilling past on the right.
        guard let barFill = childOwned(node, "hpBarFill", suffix, as: SKShapeNode.self),
              let bgNode  = childOwned(node, "hpBarBg",   suffix, as: SKNode.self),
              let barWidth = bgNode.userData?["barWidth"] as? CGFloat else { return }
        let barHeight = bgNode.userData?["barHeight"] as? CGFloat ?? 4

        let pct = max(0.0, min(1.0, Double(currentHP) / Double(maxHP)))
        let fillWidth = barWidth * CGFloat(pct)

        // Health-band colors: green from full down to 3/4, yellow from 3/4
        // down to 1/3, red below 1/3. Uses the ratio (not integer division)
        // so the thresholds are exact regardless of maxHP.
        let barColor: UIColor = pct >= 0.75 ? UIColor(hex: "#00FF88")
            : pct >= (1.0 / 3.0) ? UIColor.yellow
            : UIColor(hex: "#FF3333")

        let newPath = CGPath(roundedRect: CGRect(x: -fillWidth / 2, y: -barHeight / 2,
                                                 width: fillWidth, height: barHeight),
                              cornerWidth: barHeight / 2, cornerHeight: barHeight / 2, transform: nil)
        barFill.path = newPath
        barFill.fillColor = barColor

        if let glowLine = childOwned(node, "hpGlowLine", suffix, as: SKShapeNode.self) {
            glowLine.strokeColor = barColor.withAlphaComponent(0.3)
        }

        if let hpLabel = childOwned(node, "hpLabel", suffix, as: SKLabelNode.self) {
            hpLabel.text = "\(currentHP)/\(maxHP)"
            hpLabel.fontColor = barColor
        }

        // Stun bar fill — same center-anchor fix as HP. Drains symmetrically.
        if let stunFill = childOwned(node, "stunBarFill", suffix, as: SKShapeNode.self),
           let stunBg   = childOwned(node, "stunBarBg",   suffix, as: SKNode.self),
           let stunBarWidth = stunBg.userData?["barWidth"] as? CGFloat,
           maxStun > 0 {
            let stunPct = max(0.0, min(1.0, Double(currentStun) / Double(maxStun)))
            let stunFillWidth = stunBarWidth * CGFloat(stunPct)
            let stunColor: UIColor = stunPct > 0.7 ? UIColor(hex: "#FF4400") : UIColor(hex: "#FFAA00")
            let stunPath = CGPath(roundedRect: CGRect(x: -stunFillWidth / 2, y: -1.25,
                                                     width: max(0, stunFillWidth), height: 2.5),
                                   cornerWidth: 1, cornerHeight: 1, transform: nil)
            stunFill.path = stunPath
            stunFill.fillColor = stunColor
        }
    }
}

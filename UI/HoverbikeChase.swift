import SwiftUI
import Combine

// MARK: - Hoverbike Chase Mission (M3.5 "The Drop")
//
// Side-scrolling chase set between M3 and M4 narratively. The runners just
// climbed out of the Ritual Chamber and the corp tagged them on the way
// out — now they're fleeing down the elevated highway on a hoverbike with
// drones in pursuit and a gunship inbound for the finale.
//
// Played in a rotated LANDSCAPE canvas (the app is portrait-locked; the
// briefing card prompts the turn).
//
// Gameplay:
//   • Continuous 2D play zone (no lanes) — drag anywhere to reposition the
//     bike; tap to fire Lyra's SMG at pursuers.
//   • Threats: civilian hovercars + energy barriers (ahead traffic), mines,
//     ramps (hop hazards), and five drone archetypes (chaser / rammer /
//     sniper / gunner / miner). A one-time ELITE "enforcer" mini-boss
//     appears deep in the run.
//   • Set-pieces: the run is split into three ~40s themed SECTORS, and
//     periodic ONCOMING-TRAFFIC gauntlets send wrong-way cars racing in
//     from the right.
//   • Offense systems: combo meter, NITRO boost dash, EMP, near-miss
//     bonuses, and pickups (health / shield / weapon over-charge).
//   • After 120s the corp gunship arrives as the 3-phase boss (30 hits).
//   • Win = down the gunship. Lose = HP depleted. BAIL = manual exit.
//
// Visual layering (back to front):
//   1. Far skyline (slowest scroll)
//   2. Mid layer overpass
//   3. Bike + drones + obstacles (action plane)
//   4. Road foreground (fastest scroll)
//   5. HUD overlay

struct HoverbikeChaseScene: View {
    @ObservedObject var manager: PhaseManager

    // MARK: - Tuning
    /// Per-mission SFX mix multiplier — applied to every play() call in
    /// this scene. Cumulative -40% (was -30% then trimmed another -15%)
    /// so the chase audio sits cleaner against the music. 0.7 × 0.85 ≈ 0.595.
    private let chaseSfxMix: Float = 0.595

    /// Wraps SFXManager.play with the per-mission mix scaling so we don't
    /// repeat the multiplier at every call site.
    private func playSfx(_ name: String, volume: Float? = nil) {
        let base = volume ?? SFXManager.shared.targetVolume
        SFXManager.shared.play(name, volume: base * chaseSfxMix)
    }

    private let maxHp: Int = 3
    /// Boss HP — bumped 16 → 24 so the gunship fight lasts longer.
    /// At ~3 bullets per tap, ~8 successful taps needed to down it (most
    /// will miss given boss movement + dodging incoming).
    private let bossHp: Int = 30
    /// Seconds before the boss gunship appears. Pushed 35 → 55 so the
    /// dodging-traffic phase before the boss feels substantial. Total
    /// mission ~90-120s of active play depending on player skill.
    private let bossArrivalSeconds: Double = 120  // longer chase before the gunship
    /// REMOVED — auto-win-by-survival used to fire at 95s and end the run
    /// without a real boss kill. Now the boss is the ONLY win condition.
    /// (Player can still BAIL out at any time for a manual end.)

    // MARK: - State
    @State private var hp: Int = 3
    @State private var bossHpRemaining: Int = 5
    // 2026-05-12 redesign: bike has continuous 2D position within a play
    // zone (was 3-lane). User can drag in any direction.
    @State private var bikePos: CGPoint = CGPoint(x: 0.5, y: 0.78)
    @State private var bikeTargetPos: CGPoint = CGPoint(x: 0.5, y: 0.78)
    @State private var elapsed: Double = 0
    @State private var pulseTime: Double = 0
    @State private var distance: CGFloat = 0
    @State private var speed: CGFloat = 1.0              // scroll speed multiplier
    @State private var isFiring: Bool = false
    @State private var firingPulseEnd: Double = 0        // pulseTime when fire flash ends
    @State private var iframeUntil: Double = 0           // invuln countdown after hit
    @State private var bossActive: Bool = false
    @State private var bossX: CGFloat = 1.15             // 0..1 of screen width (offscreen right)
    @State private var bossY: CGFloat = 0.78             // y target (continuous, no lanes)
    @State private var bossYVisual: CGFloat = 0.5
    @State private var bossYSwapAt: Double = 0
    @State private var obstacles: [Obstacle] = []
    @State private var drones: [Drone] = []
    @State private var bullets: [Bullet] = []
    @State private var enemyBullets: [EnemyBullet] = []
    @State private var pickups: [Pickup] = []
    // Offense systems
    @State private var combo: Int = 0
    @State private var comboExpiry: Double = 0       // pulseTime when combo resets
    @State private var score: Int = 0
    @State private var boost: Double = 0             // 0..1 nitro gauge
    @State private var boostUntil: Double = 0        // active dash end (pulseTime)
    @State private var empReadyAt: Double = 0        // EMP cooldown (pulseTime)
    @State private var shieldUntil: Double = 0       // shield pickup invuln end
    @State private var empFlashUntil: Double = 0     // EMP shockwave VFX end
    // Ramp jump (vertical hop over ground hazards)
    @State private var bikeJumpY: CGFloat = 0        // visual offset, negative = airborne
    @State private var bikeJumpVel: CGFloat = 0
    @State private var bgOffsetFar: CGFloat = 0
    @State private var bgOffsetMid: CGFloat = 0
    @State private var bgOffsetRoad: CGFloat = 0
    @State private var gameOver: Bool = false
    @State private var didWin: Bool = false
    @State private var showBriefing: Bool = true
    @State private var dragStartBikePos: CGPoint = CGPoint(x: 0.5, y: 0.78)
    @State private var dragActive: Bool = false
    /// Last pulseTime at which the bike-swerve SFX fired. Cooldown gates
    /// the SFX so a single sustained drag doesn't spam it.
    @State private var lastSwerveAt: Double = 0
    /// Bike position when the last swerve SFX fired — used to detect
    /// "significant new movement" before re-triggering.
    @State private var lastSwerveBikePos: CGPoint = CGPoint(x: 0.5, y: 0.78)
    @State private var tickTimer: AnyCancellable?
    @State private var spawnTimer: AnyCancellable?

    // MARK: - State (feature batch: sectors / elite / gauntlet / weapon / near-miss)
    /// Current sector index. Starts -1 so the first tick announces sector 0.
    @State private var currentSector: Int = -1
    /// pulseTime until which the sector/event banner is shown.
    @State private var bannerUntil: Double = 0
    @State private var bannerTitle: String = ""
    @State private var bannerSubtitle: String = ""
    @State private var bannerAccent: String = "FF00AA"
    /// Mid-run elite mini-boss — spawns once.
    @State private var eliteSpawned: Bool = false
    /// Oncoming-traffic gauntlet windows (pulseTime).
    @State private var nextGauntletAt: Double = 22       // first wrong-way wave
    @State private var gauntletWarnUntil: Double = 0     // banner up, no spawns yet
    @State private var gauntletUntil: Double = 0         // active wrong-way spawns until
    @State private var lastOncomingAt: Double = 0
    /// Weapon-upgrade duration (pulseTime). While active the gun fires a wider,
    /// faster fan.
    @State private var weaponUpgradeUntil: Double = 0
    /// Near-miss floating-text feedback.
    @State private var nearMissText: String = ""
    @State private var nearMissUntil: Double = 0
    @State private var nearMissCount: Int = 0

    // MARK: - Campaign tie-ins (roster loadout, faction heat) + scorecard

    /// What Lyra's ACTUAL roster build contributes to the chase — loaded once
    /// per run from the persisted roster so black-market weapons and chrome
    /// carry into the interstitial instead of it being a stat island.
    private struct ChaseLoadout {
        var bulletDamage: Int = 1          // heavy purchased gun = piercing rounds
        var extraBullet: Bool = false      // smartlink-class targeting cyber
        var boostBonus: Double = 0         // wired-reflex nitro stretch (seconds)
        var bonusHP: Int = 0               // subdermal soak chrome
        var briefingLines: [(String, String)] = []
    }
    @State private var loadout = ChaseLoadout()
    /// Persisted corp attention at launch — drives drone pressure + pay.
    @State private var corpHeat: Int = 0
    private var heatRewardMultiplier: Double { 1.0 + 0.15 * Double(min(3, corpHeat)) }
    /// Next extra heat-pressure chaser (pulseTime); 0 = disabled (no heat).
    @State private var nextHeatDroneAt: Double = 0
    /// Boss weak-point windows: vents open until / next window at (pulseTime).
    @State private var bossVentUntil: Double = 0
    @State private var nextVentAt: Double = 0
    /// Run stats feeding the end-of-run scorecard.
    @State private var killCount: Int = 0
    @State private var hitsTaken: Int = 0
    @State private var scorecard: [(String, String)] = []
    @State private var walletLine: String = ""

    private static func buildLoadout() -> ChaseLoadout {
        var l = ChaseLoadout()
        guard let lyra = RosterStore.shared.loadCanonical().first(where: { $0.name == "Lyra" }) else { return l }
        if let w = lyra.equippedWeapon, w.damage >= 7 {
            l.bulletDamage = 2
            l.briefingLines.append((w.name.uppercased(), "Heavy rounds — every hit counts double"))
        }
        if lyra.cyberAccuracyDice >= 2 {
            l.extraBullet = true
            l.briefingLines.append(("SMARTLINK", "Targeting overlay — 4-round fan"))
        }
        if lyra.cyberInitiative >= 1 {
            l.boostBonus = 0.5
            l.briefingLines.append(("WIRED REFLEXES", "NITRO window stretched"))
        }
        if lyra.cyberSoak >= 2 {
            l.bonusHP = 1
            l.briefingLines.append(("SUBDERMAL PLATE", "+1 bike integrity"))
        }
        return l
    }

    // MARK: - Models

    enum ObstacleKind: String {
        case carA, carB, barrier, mine, ramp
    }

    struct Obstacle: Identifiable {
        let id: UUID = UUID()
        var x: CGFloat           // 0..1 of screen width
        var y: CGFloat           // 0..1 of screen height (continuous, no lanes)
        let kind: ObstacleKind
        var consumed: Bool = false
        /// Horizontal velocity in screen-fractions per second. POSITIVE for
        /// stationary/ahead obstacles (the bike is "approaching" them — they
        /// appear to slide rightward as the world scrolls past). NEGATIVE for
        /// oncoming-gauntlet traffic that races leftward toward the bike.
        var vx: CGFloat
        /// Wrong-way gauntlet hauler — enters from ahead (left), races right
        /// past the bike head-on, faces right, rendered with hazard dressing.
        var oncoming: Bool = false
        /// Hauler sprite variant (0..2) so the gauntlet isn't a wall of clones.
        var variant: Int = 0
        /// Set once this hazard has already paid out a near-miss bonus, so a
        /// single close pass scores only one time.
        var scoredNearMiss: Bool = false
    }

    /// Drone behaviour archetype. `chaser` is the vanilla pursuer; the others
    /// add variety the player has to read and respond to differently.
    enum DroneKind: String {
        case chaser     // drifts in, fires periodically (original)
        case rammer     // winds up (flashes), then dashes at the bike's lane
        case sniper     // paints a laser sight, then fires a fast aimed bolt
        case gunner     // pulls alongside and strafes a short burst
        case miner      // drops mines behind it as it passes
        case enforcer   // mid-run ELITE mini-boss: tanky, strafes AND charges
    }

    struct Drone: Identifiable {
        let id: UUID = UUID()
        var x: CGFloat           // 0..1 of screen width
        var y: CGFloat           // 0..1 of screen height
        var hp: Int = 2
        var consumed: Bool = false
        var nextFireAt: Double   // pulseTime
        var kind: DroneKind = .chaser
        var windUntil: Double = 0    // rammer/sniper telegraph end (pulseTime)
        var charging: Bool = false   // rammer mid-dash
        var stunUntil: Double = 0    // disabled by EMP until this pulseTime
    }

    /// Good pickup floating in a lane — grab it by touching it.
    struct Pickup: Identifiable {
        let id: UUID = UUID()
        var x: CGFloat
        var y: CGFloat
        var vx: CGFloat
        var kind: Kind
        var consumed: Bool = false
        enum Kind { case health, shield, weapon }
    }

    /// Player bullet — fired from the bike toward the right.
    /// Each tap spawns three bullets fanning out (straight back, diagonal
    /// up, diagonal down) so a single shot can catch a pursuer regardless
    /// of which lane they're in.
    struct Bullet: Identifiable {
        let id: UUID = UUID()
        var x: CGFloat
        var y: CGFloat   // 0..1 of screen height (no fixed lane — lets us angle shots)
        var vx: CGFloat  // horizontal velocity (positive = rightward toward pursuers)
        var vy: CGFloat  // vertical velocity (positive = downward, negative = upward)
    }

    /// Enemy bullet — fired from a drone or gunship, travels toward the bike.
    struct EnemyBullet: Identifiable {
        let id: UUID = UUID()
        var x: CGFloat
        var y: CGFloat           // 0..1 of screen height (uses absolute Y since fired from variable spots)
        var vx: CGFloat
        var vy: CGFloat
        /// Near-miss already scored for this tracer (see Obstacle.scoredNearMiss).
        var scoredNearMiss: Bool = false
    }

    // MARK: - Sectors
    /// The run is split into themed stretches that escalate the threat mix.
    /// Three 40s sectors lead into the 120s gunship arrival.
    private struct ChaseSector { let name: String; let start: Double; let accent: String }
    private let sectors: [ChaseSector] = [
        ChaseSector(name: "DOWNTOWN CORE",      start: 0,  accent: "FF00AA"),
        ChaseSector(name: "INDUSTRIAL SPRAWL",  start: 40, accent: "FFCC00"),
        ChaseSector(name: "ARCOLOGY OUTSKIRTS", start: 80, accent: "00DDFF"),
    ]

    /// Player's best recorded chase score, shown on the briefing card.
    private var chaseBestScore: Int {
        MissionStatsStore.shared.record(for: "Mission003_5").bestScore
    }

    // MARK: - Layout helpers
    // 2026-05-12 redesign: bike + threats live in a continuous 2D play
    // zone (lower portion of screen, over the road foreground layer).
    // No lane snapping — drag in any direction to position the bike.
    private let playMinX: CGFloat = 0.12
    private let playMaxX: CGFloat = 0.88
    private let playMinY: CGFloat = 0.62
    private let playMaxY: CGFloat = 0.92

    /// Loads new chase art dropped into Sprites/frames/<name>.png (same
    /// workflow as the brawl). Returns nil if the file isn't there yet so the
    /// caller falls back to the existing placeholder. Cached per process.
    private static var chaseImgCache: [String: UIImage?] = [:]
    private func chaseImage(_ name: String) -> UIImage? {
        if let cached = HoverbikeChaseScene.chaseImgCache[name] { return cached }
        var img: UIImage? = nil
        if let base = Bundle.main.resourceURL,
           let raw = UIImage(contentsOfFile: base.appendingPathComponent("Sprites/frames").appendingPathComponent("\(name).png").path) {
            // Generated art often ships with an opaque white background —
            // flood-fill it transparent (reuses the brawl's remover).
            img = BasementBrawlSpriteCache.removeBackground(raw) ?? raw
        }
        HoverbikeChaseScene.chaseImgCache[name] = img
        return img
    }

    private func clampBike(_ p: CGPoint) -> CGPoint {
        CGPoint(
            x: max(playMinX, min(playMaxX, p.x)),
            y: max(playMinY, min(playMaxY, p.y))
        )
    }

    /// Random y within the play zone (used for spawning obstacles + drones).
    private func randomPlayY() -> CGFloat {
        CGFloat.random(in: (playMinY + 0.03) ... (playMaxY - 0.03))
    }

    // MARK: - Body

    var body: some View {
        // Landscape: the app is portrait-locked, so render the chase in a
        // rotated landscape canvas (the briefing card prompts the turn). Using
        // the swapped dimensions means all the existing geo.size math lays out
        // correctly in landscape.
        GeometryReader { outer in
            let W = outer.size.height   // landscape width (long axis — the road)
            let H = outer.size.width    // landscape height (short axis — the lanes)
            chaseContent
                .frame(width: W, height: H)
                .rotationEffect(.degrees(90))
                .position(x: outer.size.width / 2, y: outer.size.height / 2)
        }
        .ignoresSafeArea()
    }

    private var chaseContent: some View {
        GeometryReader { geo in
            ZStack {
                // ── Parallax backgrounds (back to front) ──────────────────
                // Layered so:
                //   • far skyline occupies the top ~40% (clearly distant)
                //   • mid layer fills middle ~25% (overpass + city texture)
                //   • road fills lower ~40% (where the gameplay happens)
                // The mid layer is dimmed because its art has its own
                // hovercars + signs that would compete visually with the
                // actual gameplay obstacles.
                // Each layer is keyed by the resolved sector name so swapping
                // sectors crossfades the art (masked further by the sector
                // banner that fires on the same frame).
                Group {
                    parallaxLayer(bgName("chase_bg_far"),
                                  offset: bgOffsetFar,
                                  y: 0.10, height: 0.38, in: geo,
                                  fallbackTint: Color(hex: "1A0030"),
                                  tint: 1.0)
                    parallaxLayer(bgName("chase_bg_mid"),
                                  offset: bgOffsetMid,
                                  y: 0.42, height: 0.22, in: geo,
                                  fallbackTint: Color(hex: "120024"),
                                  tint: 0.55)
                    parallaxLayer(bgName("chase_bg_road"),
                                  offset: bgOffsetRoad,
                                  y: 0.60, height: 0.40, in: geo,
                                  fallbackTint: Color(hex: "0A0014"),
                                  tint: 1.0)
                }
                .id(max(0, currentSector))
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.6), value: currentSector)

                // ── Obstacles (between road and bike, but visually overlap)
                ForEach(obstacles.filter { !$0.consumed }) { ob in
                    obstacleView(ob, in: geo)
                }

                // ── Drones (small fast enemies) ───────────────────────────
                ForEach(drones.filter { !$0.consumed }) { d in
                    droneView(d, in: geo)
                }

                // ── Pickups (health / shield) ─────────────────────────────
                ForEach(pickups.filter { !$0.consumed }) { p in
                    pickupView(p, in: geo)
                }

                // ── Enemy bullets (red tracers) ───────────────────────────
                // Larger + glowing so the player can actually SEE incoming
                // shots in time to dodge (was 8pt, easy to miss).
                ForEach(enemyBullets) { b in
                    ZStack {
                        Circle()
                            .fill(Color(hex: "FF3344").opacity(0.35))
                            .frame(width: 24, height: 24)
                            .blur(radius: 4)
                        Circle()
                            .fill(Color(hex: "FF3344"))
                            .frame(width: 12, height: 12)
                            .shadow(color: Color(hex: "FF3344"), radius: 8)
                    }
                    .position(x: b.x * geo.size.width, y: b.y * geo.size.height)
                }

                // ── Player bullets (cyan tracers) ─────────────────────────
                // Three bullets per tap fan out: straight, diagonal up, down.
                // Render rotated to match velocity angle. Bigger + more glow
                // so they read clearly as the player's shots.
                ForEach(bullets) { b in
                    ZStack {
                        Capsule()
                            .fill(Color(hex: "00FFCC").opacity(0.35))
                            .frame(width: 44, height: 10)
                            .blur(radius: 4)
                        Capsule()
                            .fill(Color(hex: "00FFCC"))
                            .frame(width: 30, height: 5)
                            .shadow(color: Color(hex: "00FFCC"), radius: 8)
                    }
                    .rotationEffect(.radians(atan2(Double(b.vy), Double(b.vx))))
                    .position(x: b.x * geo.size.width, y: b.y * geo.size.height)
                }

                // ── Player bike ───────────────────────────────────────────
                bikeView(in: geo)

                // ── Boss gunship ──────────────────────────────────────────
                if bossActive {
                    gunshipView(in: geo)
                }

                // ── HUD ───────────────────────────────────────────────────
                hudView
                    .padding(.top, 36)
                    .padding(.horizontal, 16)

                // ── Sector / event announce banner ────────────────────────
                if pulseTime < bannerUntil {
                    announceBanner.zIndex(900)
                }

                // ── Near-miss floating text ───────────────────────────────
                if pulseTime < nearMissUntil {
                    Text(nearMissText)
                        .font(.system(size: 13, weight: .black, design: .monospaced)).tracking(1)
                        .foregroundColor(Color(hex: "FFE044"))
                        .shadow(color: .black, radius: 3)
                        .position(x: bikePos.x * geo.size.width,
                                  y: bikePos.y * geo.size.height - geo.size.height * 0.13)
                        .zIndex(850)
                }

                // ── Briefing card ─────────────────────────────────────────
                if showBriefing {
                    briefingCard
                        .zIndex(1000)
                }

                // ── Game-over overlay ─────────────────────────────────────
                if gameOver {
                    gameOverOverlay
                        .zIndex(1100)
                }
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .gesture(dragGesture)
        }
        .onAppear {
            initialise()
            startTimers()
        }
        .onDisappear {
            tickTimer?.cancel()
            spawnTimer?.cancel()
        }
    }

    // MARK: - Backgrounds (parallax)

    /// Resolves a parallax base asset name to the current sector's variant.
    /// Sector 0 (Downtown Core) uses the original art; sectors 1/2 look for
    /// suffixed art ("..._industrial" / "..._arcology") and fall back to the
    /// base if it hasn't been imported yet — so the game runs fine before the
    /// extra backgrounds exist, then picks them up automatically once dropped
    /// into the asset catalog.
    private func bgName(_ base: String) -> String {
        let suffix: String
        switch max(0, currentSector) {
        case 1:  suffix = "industrial"
        case 2:  suffix = "arcology"
        default: suffix = ""
        }
        guard !suffix.isEmpty else { return base }
        let candidate = "\(base)_\(suffix)"
        return UIImage(named: candidate) != nil ? candidate : base
    }

    @ViewBuilder
    private func parallaxLayer(_ name: String,
                                offset: CGFloat,
                                y: CGFloat, height: CGFloat,
                                in geo: GeometryProxy,
                                fallbackTint: Color,
                                tint: Double = 1.0) -> some View {
        let layerW = geo.size.width
        let layerH = geo.size.height * height
        let yCenter = geo.size.height * (y + height / 2)
        // Wrap the offset so we have a positive value in [0, layerW] that
        // determines where image 1 sits. Image 2 is placed one layerW to
        // the right, so as offset grows the pair scrolls leftward
        // seamlessly (each image cycles into and out of the clipping window).
        let wrapped = offset.truncatingRemainder(dividingBy: layerW)

        ZStack(alignment: .leading) {
            if let img = UIImage(named: name) {
                // Scroll RIGHTWARD: as `wrapped` grows, image 1 slides right
                // off the screen and image 2 comes in from the left.
                // Matches the bike's facing direction — bike faces+moves
                // LEFT in world space, so the world should appear to flow
                // RIGHTWARD across the camera (left-to-right).
                Image(uiImage: img)
                    .resizable()
                    .frame(width: layerW, height: layerH)
                    .offset(x: wrapped)
                Image(uiImage: img)
                    .resizable()
                    .frame(width: layerW, height: layerH)
                    .offset(x: wrapped - layerW)
            } else {
                LinearGradient(
                    colors: [fallbackTint.opacity(0.85), fallbackTint],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(width: layerW, height: layerH)
            }
        }
        .frame(width: layerW, height: layerH)
        .clipped()
        .opacity(tint)
        .position(x: layerW / 2, y: yCenter)
    }

    // MARK: - Sprite views

    @ViewBuilder
    private func bikeView(in geo: GeometryProxy) -> some View {
        let assetName = isFiring ? "chase_bike_firing" : "chase_bike_idle"
        // Scale hierarchy (everything shares one ground plane — no depth
        // scaling): car (0.30) > bike (0.27) > drone (0.23). The bike was
        // 0.58 — nearly 2× the cars — which read as wrong; a hoverbike should
        // be a touch smaller than a hovercar, not dwarf it.
        let bikeSize = geo.size.height * 0.27   // sized to the lane band (landscape)
        let alpha: Double = iframeUntil > pulseTime
            ? (Int(pulseTime * 14) % 2 == 0 ? 0.45 : 1.0)
            : 1.0
        ZStack {
            if let img = UIImage(named: assetName) {
                // Tried .blendMode(.plusLighter) to suppress the source PNG's
                // grey gradient halo — but it washed out the dark bike body
                // and riders. Reverted. The soft halo reads as ambient bike
                // glow against the road and isn't actually distracting.
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(width: bikeSize)
                    .opacity(alpha)
                    .shadow(color: Color(hex: "FF00AA").opacity(0.35), radius: 12)
            } else {
                Capsule()
                    .fill(LinearGradient(colors: [Color(hex: "FF00AA"), Color(hex: "00DDFF")],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: bikeSize, height: bikeSize * 0.35)
                    .opacity(alpha)
            }
        }
        .position(x: bikePos.x * geo.size.width,
                  y: bikePos.y * geo.size.height + sin(pulseTime * 4) * 2 + bikeJumpY)
    }

    @ViewBuilder
    private func droneView(_ d: Drone, in geo: GeometryProxy) -> some View {
        // Bumped 0.18 → 0.23 so chaser drones read as real threats (they were
        // too small to spot). Still the smallest thing on the road: drone
        // (0.23) < bike (0.27) < car (0.30).
        // Enforcer (elite) is the biggest non-boss threat — clearly dwarfs the
        // regular drones (and edges out the cars), just under the gunship.
        let size = geo.size.height * (d.kind == .enforcer ? 0.46 : 0.20)
        let yBob = sin(pulseTime * 5 + Double(d.x)) * 3
        let stunned = pulseTime < d.stunUntil
        let winding = d.windUntil > pulseTime || d.charging   // telegraph flash
        ZStack {
            Group {
                if let img = chaseImage("chase_drone_\(d.kind.rawValue)") ?? UIImage(named: "chase_drone") {
                    Image(uiImage: img).resizable().scaledToFit().frame(width: size)
                } else {
                    Circle().fill(Color(hex: "881100")).frame(width: size, height: size)
                }
            }
            // Elite enforcer keeps a floating HP bar so it still reads as a
            // mini-boss that takes sustained fire.
            if d.kind == .enforcer {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.6)).frame(width: size * 0.8, height: 5)
                    Capsule().fill(Color(hex: "FF3344"))
                        .frame(width: size * 0.8 * CGFloat(max(0, d.hp)) / 14.0, height: 5)
                }
                .offset(y: -size * 0.55)
            }
        }
        .brightness(winding ? 0.4 : 0)
        .opacity(stunned ? 0.55 : 1)
        .position(x: d.x * geo.size.width, y: d.y * geo.size.height + yBob)
    }

    @ViewBuilder
    private func pickupView(_ p: Pickup, in geo: GeometryProxy) -> some View {
        let c: Color = {
            switch p.kind {
            case .health: return Color(hex: "00FF88")
            case .shield: return Color(hex: "00DDFF")
            case .weapon: return Color(hex: "FFE044")
            }
        }()
        let assetName: String? = {
            switch p.kind {
            case .health: return "chase_pickup_health"
            case .shield: return "chase_pickup_shield"
            case .weapon: return "chase_pickup_weapon"
            }
        }()
        let symbol: String = {
            switch p.kind {
            case .health: return "cross.fill"
            case .shield: return "shield.fill"
            case .weapon: return "bolt.shield.fill"
            }
        }()
        if let name = assetName, let img = chaseImage(name) {
            Image(uiImage: img).resizable().scaledToFit().frame(width: 34)
                .shadow(color: c, radius: 8)
                .position(x: p.x * geo.size.width, y: p.y * geo.size.height)
        } else {
            ZStack {
                Circle().fill(c.opacity(0.25)).frame(width: 42, height: 42).blur(radius: 5)
                Circle().stroke(c.opacity(0.8), lineWidth: 1.5).frame(width: 34, height: 34)
                Image(systemName: symbol)
                    .resizable().scaledToFit().frame(width: 18)
                    .foregroundColor(c)
            }
            .position(x: p.x * geo.size.width, y: p.y * geo.size.height)
        }
    }

    @ViewBuilder
    private func obstacleView(_ ob: Obstacle, in geo: GeometryProxy) -> some View {
        let xPos = ob.x * geo.size.width
        let yPos = ob.y * geo.size.height
        switch ob.kind {
        case .carA, .carB:
            if ob.oncoming {
                // Wrong-way FREIGHT HAULER — distinct, big, lane-filling. The
                // bespoke art (headlights + neon underglow) carries the "threat"
                // read on its own, so no extra ring/headlight dressing. Loaded
                // via chaseImage so the generated art's baked background gets
                // flood-filled out. Variant fallback: chase_hauler_b/_c →
                // chase_hauler → a mirrored civilian car → a plain block.
                let w = geo.size.height * 0.40
                let variantName = ob.variant == 0 ? "chase_hauler" : "chase_hauler_\(["b","c"][min(1, ob.variant - 1)])"
                let haulerImg = chaseImage(variantName) ?? chaseImage("chase_hauler")
                Group {
                    if let img = haulerImg {
                        Image(uiImage: img).resizable().scaledToFit().frame(width: w)
                    } else if let img = UIImage(named: (ob.kind == .carA) ? "chase_car_a" : "chase_car_b") {
                        // Civilian cars face LEFT; mirror so the fallback faces
                        // RIGHT (the hauler's head-on travel direction).
                        Image(uiImage: img).resizable().scaledToFit().frame(width: w)
                            .scaleEffect(x: -1, y: 1)
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(hex: "662222"))
                            .frame(width: w, height: w * 0.5)
                    }
                }
                .position(x: xPos, y: yPos)
            } else {
                let assetName = (ob.kind == .carA) ? "chase_car_a" : "chase_car_b"
                let w = geo.size.height * 0.33
                if let img = UIImage(named: assetName) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(width: w)
                        .position(x: xPos, y: yPos)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(hex: "224466"))
                        .frame(width: w, height: w * 0.45)
                        .position(x: xPos, y: yPos)
                }
            }
        case .barrier:
            // Barrier height roughly matches a single lane band (~12% of
            // screen height). Was 0.32 — that's bigger than the entire
            // 3-lane play area and dominated the screen.
            let h = geo.size.height * 0.12
            if let img = UIImage(named: "chase_barrier") {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(height: h)
                    .position(x: xPos, y: yPos)
            } else {
                Rectangle()
                    .fill(LinearGradient(colors: [Color(hex: "FF00AA"), Color(hex: "00DDFF")],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 24, height: h)
                    .shadow(color: Color(hex: "FF00AA"), radius: 8)
                    .position(x: xPos, y: yPos)
            }
        case .mine:
            if let img = chaseImage("chase_mine") {
                Image(uiImage: img).resizable().scaledToFit().frame(width: geo.size.height * 0.16)
                    .position(x: xPos, y: yPos)
            } else {
                // Pulsing spiked proximity mine (placeholder).
                ZStack {
                    Circle().fill(Color(hex: "FF3344").opacity(0.22)).frame(width: 38, height: 38).blur(radius: 5)
                    Circle().fill(Color(hex: "330000")).frame(width: 22, height: 22)
                        .overlay(Circle().stroke(Color(hex: "FF3344"), lineWidth: 2))
                    Circle().fill(Color(hex: "FF3344")).frame(width: 7, height: 7)
                        .opacity(0.4 + 0.6 * (0.5 + 0.5 * sin(pulseTime * 8)))
                }
                .position(x: xPos, y: yPos)
            }
        case .ramp:
            let rw = geo.size.height * 0.22
            if let img = chaseImage("chase_ramp") {
                // Art ramps up toward the right; the bike rides + launches LEFT,
                // so mirror it (high/launch end on the left, entry on the right).
                Image(uiImage: img).resizable().scaledToFit().frame(width: rw)
                    .scaleEffect(x: -1, y: 1)
                    .position(x: xPos, y: yPos)
            } else {
                Image(systemName: "triangle.fill")
                    .resizable().scaledToFit().frame(width: rw)
                    .foregroundColor(Color(hex: "00FFCC").opacity(0.9))
                    .shadow(color: Color(hex: "00FFCC"), radius: 8)
                    .position(x: xPos, y: yPos)
            }
        }
    }

    @ViewBuilder
    private func gunshipView(in geo: GeometryProxy) -> some View {
        let size = geo.size.height * 0.55   // boss presence, sized for landscape
        ZStack {
            if let img = UIImage(named: "chase_gunship") {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size)
                    .shadow(color: Color(hex: pulseTime < bossVentUntil ? "FFA500" : "FF3344")
                        .opacity(pulseTime < bossVentUntil ? 0.9 : 0.55),
                            radius: pulseTime < bossVentUntil ? 24 : 14)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(hex: "554433"))
                    .frame(width: size, height: size * 0.55)
            }
        }
        .position(x: bossX * geo.size.width,
                  y: bossYVisual * geo.size.height + sin(pulseTime * 2) * 4)
    }

    // MARK: - HUD

    private var hudView: some View {
        VStack {
            HStack(alignment: .top) {
                // HP pips on the left
                VStack(alignment: .leading, spacing: 4) {
                    Text("HP")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(Color(hex: "FF3344"))
                    HStack(spacing: 4) {
                        ForEach(0..<(maxHp + loadout.bonusHP), id: \.self) { i in
                            Image(systemName: i < hp ? "heart.fill" : "heart")
                                .font(.system(size: 18))
                                .foregroundColor(i < hp ? Color(hex: "FF3344") : .white.opacity(0.25))
                        }
                    }
                }
                Spacer()
                // Title + distance
                VStack(alignment: .trailing, spacing: 2) {
                    Text("// THE DROP")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .tracking(3)
                        .foregroundColor(Color(hex: "FF00AA"))
                    Text(String(format: "DIST %.0fm", distance))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(hex: "00FFCC"))
                    if combo >= 2 {
                        Text("COMBO ×\(combo)")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .foregroundColor(Color(hex: "FFE044"))
                    }
                    if pulseTime < weaponUpgradeUntil {
                        Text("WPN+ \(Int(ceil(weaponUpgradeUntil - pulseTime)))s")
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .foregroundColor(Color(hex: "FFE044"))
                    }
                    if bossActive {
                        bossHpBar
                    }
                }
            }
            Spacer()
            HStack(alignment: .bottom, spacing: 10) {
                chaseActionButton(label: "BOOST", color: "FFE044", ready: boost >= 1.0, action: tryBoost)
                chaseActionButton(label: "EMP", color: "00DDFF", ready: pulseTime >= empReadyAt, action: tryEMP)
                VStack(alignment: .leading, spacing: 2) {
                    Text("NITRO")
                        .font(.system(size: 7, weight: .black, design: .monospaced))
                        .foregroundColor(Color(hex: "FFE044").opacity(0.85))
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.black.opacity(0.6)).frame(width: 90, height: 6)
                        Capsule().fill(Color(hex: "FFE044")).frame(width: 90 * CGFloat(min(1, boost)), height: 6)
                    }
                }
                Spacer()
                // (Removed the in-HUD "BAIL" button — it was a second, un-
                // confirmed quit that skipped the debrief. The universal top-
                // left EXIT button now handles bailing, with a confirm dialog.)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 30)
        }
    }

    private func chaseActionButton(label: String, color: String, ready: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .black, design: .monospaced)).tracking(1)
                .foregroundColor(ready ? .black : .white.opacity(0.5))
                .frame(width: 64, height: 38)
                .background(Capsule().fill(Color(hex: color).opacity(ready ? 1 : 0.28)))
                .overlay(Capsule().stroke(Color(hex: color).opacity(ready ? 1 : 0.5), lineWidth: 1.5))
                .shadow(color: ready ? Color(hex: color) : .clear, radius: 6)
        }
        .buttonStyle(.plain)
    }

    private var bossHpBar: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("CORP GUNSHIP")
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .foregroundColor(Color(hex: "FF3344"))
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.black.opacity(0.6))
                    .frame(width: 120, height: 8)
                    .overlay(Rectangle().stroke(Color(hex: "FF3344"), lineWidth: 1))
                Rectangle()
                    .fill(Color(hex: "FF3344"))
                    .frame(width: 120 * CGFloat(bossHpRemaining) / CGFloat(bossHp), height: 8)
            }
        }
    }

    /// Centered top banner for sector entries / gauntlet warnings / the elite.
    private var announceBanner: some View {
        VStack(spacing: 2) {
            Text(bannerTitle)
                .font(.system(size: 20, weight: .black, design: .monospaced)).tracking(3)
                .foregroundColor(Color(hex: bannerAccent))
            Text(bannerSubtitle)
                .font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(2)
                .foregroundColor(.white.opacity(0.85))
        }
        .padding(.horizontal, 24).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.62))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(hex: bannerAccent).opacity(0.85), lineWidth: 1.5))
        )
        .shadow(color: Color(hex: bannerAccent).opacity(0.5), radius: 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 72)
        .allowsHitTesting(false)
    }

    // MARK: - Briefing + Game-over UI

    private var briefingCard: some View {
        ZStack {
            Color.black.opacity(0.86).ignoresSafeArea()
            // The card is rendered ROTATED (the scene fakes landscape while the
            // device is portrait), so this VStack's height is bounded by the
            // screen's WIDTH — ~402pt on an iPhone. The rules list is variable:
            // up to 4 gear-gated loadout lines, plus BEST RUN, plus CORP HEAT.
            // Unscrolled, a geared-up player pushed RIDE clean off the edge and
            // the mission became unstartable (playtest 2026-07-25). Scroll the
            // body, and keep RIDE OUTSIDE the scroll so it is always reachable
            // no matter how long the list grows.
            VStack(spacing: 9) {
                ScrollView(showsIndicators: true) {
                    briefingBody
                }
                rideButton
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.black.opacity(0.92))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color(hex: "FF00AA").opacity(0.55), lineWidth: 1.5)
                    )
            )
            .padding(.horizontal, 22)
        }
    }

    private var briefingBody: some View {
        VStack(spacing: 9) {
                Text("↻  TURN YOUR PHONE SIDEWAYS")
                    .font(.system(size: 11, weight: .black, design: .monospaced)).tracking(1)
                    .foregroundColor(Color(hex: "00FFCC"))
                Text("MISSION 3.5  //  THE DROP")
                    .font(.system(size: 18, weight: .black, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(Color(hex: "FF00AA"))
                Text("Highway exfil — corp's whole pursuit fleet is on you. Run three sectors of city, survive the gunship, and take it down.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.78))
                    .multilineTextAlignment(.center)
                if chaseBestScore > 0 {
                    Text("BEST RUN  ·  \(chaseBestScore)")
                        .font(.system(size: 11, weight: .black, design: .monospaced)).tracking(2)
                        .foregroundColor(Color(hex: "FFE044"))
                }
                VStack(alignment: .leading, spacing: 6) {
                    briefingRule(icon: "arrow.up.and.down.and.arrow.left.and.right", color: Color(hex: "00FFCC"),
                                 title: "DRAG / TAP", detail: "Steer anywhere to dodge · tap to fire at pursuers")
                    briefingRule(icon: "bolt.fill", color: Color(hex: "FFE044"),
                                 title: "BOOST", detail: "Full NITRO dash — invincible, rams through anything")
                    briefingRule(icon: "burst.fill", color: Color(hex: "00DDFF"),
                                 title: "EMP", detail: "Stuns every drone + wipes incoming fire (cooldown)")
                    briefingRule(icon: "cross.case.fill", color: Color(hex: "00FF88"),
                                 title: "GRAB / RAMP", detail: "Green heals · cyan shields · yellow over-charges your gun · ride ramps over hazards")
                    briefingRule(icon: "scope", color: Color(hex: "FFE044"),
                                 title: "NEAR MISS", detail: "Skim a hazard to bank bonus score + NITRO — ride dirty")
                    briefingRule(icon: "exclamationmark.triangle.fill", color: Color(hex: "FFCC00"),
                                 title: "THREATS", detail: "Rammers charge · snipers paint you · gunners strafe · miners drop mines · wrong-way traffic · an ELITE enforcer mid-run")
                    // Roster tie-ins: Lyra's actual gear/chrome, so shop
                    // purchases visibly matter here too.
                    ForEach(loadout.briefingLines.indices, id: \.self) { i in
                        briefingRule(icon: "cpu.fill", color: Color(hex: "B080FF"),
                                     title: loadout.briefingLines[i].0,
                                     detail: loadout.briefingLines[i].1)
                    }
                    if corpHeat > 0 {
                        briefingRule(icon: "flame.fill", color: Color(hex: "FF6600"),
                                     title: "CORP HEAT \(min(3, corpHeat))",
                                     detail: String(format: "Extra drone pressure · contract pays ×%.2f", heatRewardMultiplier))
                    }
                }
                .padding(.top, 4)
        }
    }

    /// Pinned outside the briefing's ScrollView — a variable-length rules list
    /// must never be able to push the only way into the mission off-screen.
    private var rideButton: some View {
        Button(action: {
            HapticsManager.shared.buttonTap()
            withAnimation(.easeIn(duration: 0.25)) { showBriefing = false }
        }) {
            Text("RIDE")
                .font(.system(size: 13, weight: .black, design: .monospaced))
                .tracking(3)
                .foregroundColor(.black)
                .frame(width: 200, height: 44)
                .background(Color(hex: "00FF88"))
                .cornerRadius(6)
        }
        .padding(.top, 10)
    }

    private func briefingRule(icon: String, color: Color,
                              title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundColor(color)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(color)
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
    }

    private var gameOverOverlay: some View {
        ZStack {
            Color.black.opacity(0.86).ignoresSafeArea()
            VStack(spacing: 14) {
                Text(didWin ? "ESCAPED" : "TAGGED")
                    .font(.system(size: 30, weight: .black, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(didWin ? Color(hex: "00FF88") : Color(hex: "FF3344"))
                Text(didWin
                     ? "Data drive delivered.\nThe heat will cool — give it a few days."
                     : "Corp got the drive back.\nThe contract is busted. Lay low.")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                // End-of-run scorecard — the payout is explainable, not a
                // bare number (mirrors the tactical debrief factor lines).
                if !scorecard.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(scorecard.indices, id: \.self) { i in
                            HStack {
                                Text(scorecard[i].0)
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.65))
                                Spacer()
                                Text(scorecard[i].1)
                                    .font(.system(size: 10, weight: .black, design: .monospaced))
                                    .foregroundColor(Color(hex: "FFE044"))
                            }
                        }
                        Text(walletLine)
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .tracking(1)
                            .foregroundColor(didWin ? Color(hex: "00FF88") : Color(hex: "FF3344"))
                            .padding(.top, 6)
                    }
                    .frame(width: 290)
                    .padding(.top, 6)
                }
                Button(action: {
                    HapticsManager.shared.buttonTap()
                    // Win → outro VN → debrief. Loss → straight to debrief.
                    // Mirrors the M4.5 / M5.5 endBrawl/endColdTrace pattern.
                    // PhaseManager.transition() captures the won bool and
                    // sets combatWon internally (see endChase handler).
                    _ = manager.transition(to: .endChase(won: didWin))
                }) {
                    Text("RETURN")
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .tracking(3)
                        .foregroundColor(.black)
                        .frame(width: 200, height: 44)
                        .background(didWin ? Color(hex: "00FF88") : Color(hex: "FF3344"))
                        .cornerRadius(6)
                }
                .padding(.top, 8)
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.9))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke((didWin ? Color(hex: "00FF88") : Color(hex: "FF3344")).opacity(0.7),
                                    lineWidth: 1.5)
                    )
            )
        }
    }

    // MARK: - Gesture

    private var dragGesture: some Gesture {
        // 2D continuous drag. The bike's target position tracks the drag
        // delta in real time — drag right, bike slides right. Drag up,
        // bike slides up. Sub-pixel-precise movement within the play zone.
        //
        // Tap detection: if release happens with no drag movement
        // (total < 12pt), treat as a tap → fire weapon. Otherwise it was
        // a movement drag.
        //
        // Drag distance is mapped to screen-fraction movement: 1pt drag →
        // ~0.0025 screen units (so a 200pt drag = ~half the screen).
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                guard !showBriefing, !gameOver else { return }
                if !dragActive {
                    dragActive = true
                    dragStartBikePos = bikePos
                }
                // 1:1 drag — 1pt of drag = 1pt of bike movement on screen.
                // Mapping to screen-fraction by dividing by typical iPhone
                // screen width (~400pt for the play area).
                let dxFraction = drag.translation.width / 400.0
                let dyFraction = drag.translation.height / 400.0
                let prevBike = bikePos
                bikePos = clampBike(CGPoint(
                    x: dragStartBikePos.x + dxFraction,
                    y: dragStartBikePos.y + dyFraction
                ))

                // Swerve SFX trigger — tightened so sustained drags don't
                // re-trigger it. Three gates:
                //   • moved >0.12 of screen since last fire (significant
                //     repositioning, not a small adjust)
                //   • >0.8s cooldown (longer pause between swerves)
                //   • current-frame drag velocity is meaningful (>0.004),
                //     so a paused drag doesn't keep firing while held
                let moveDelta = hypot(bikePos.x - lastSwerveBikePos.x,
                                      bikePos.y - lastSwerveBikePos.y)
                let prevDelta = hypot(bikePos.x - prevBike.x,
                                      bikePos.y - prevBike.y)
                if moveDelta > 0.12,
                   pulseTime > lastSwerveAt + 0.8,
                   prevDelta > 0.004 {
                    playSfx("bike_swerve")
                    lastSwerveAt = pulseTime
                    lastSwerveBikePos = bikePos
                }
            }
            .onEnded { drag in
                defer { dragActive = false }
                guard !showBriefing, !gameOver else { return }
                let totalMag = max(abs(drag.translation.height), abs(drag.translation.width))
                // Stationary release → fire. Drag release → just leave bike
                // where it ended.
                if totalMag < 12 {
                    fireWeapon()
                }
            }
    }

    // MARK: - Firing

    private func fireWeapon() {
        guard !gameOver, !showBriefing else { return }
        // Spawn THREE bullets fanning out from the bike: one straight back
        // (vy=0), one diagonal up (negative vy), one diagonal down. Lets a
        // single shot catch pursuers regardless of their vertical offset.
        let originX = bikePos.x + 0.04   // slight offset right of bike (Lyra's gun is at back)
        let originY = bikePos.y
        let upgraded = pulseTime < weaponUpgradeUntil
        if upgraded {
            // Overcharged: a faster 5-round fan. Still tighter than before so
            // it rewards aim — it's a stronger volume of fire, not an autohit.
            let vx: CGFloat = 1.85
            let spread: [CGFloat] = [-0.20, -0.10, 0, 0.10, 0.20]
            for s in spread {
                bullets.append(Bullet(x: originX, y: originY, vx: vx, vy: vx * s))
            }
        } else {
            // Tighter 3-round burst — the fan was wide enough to hit almost
            // anything without aiming. Narrowed the cone (~0.18 → 0.09 of vx)
            // so you have to roughly line up your Y with the target.
            let vxStraight: CGFloat = 1.6
            let vxAngled: CGFloat   = 1.58
            let vyAngled: CGFloat   = vxAngled * 0.09
            bullets.append(Bullet(x: originX, y: originY, vx: vxStraight, vy: 0))
            bullets.append(Bullet(x: originX, y: originY, vx: vxAngled,   vy: -vyAngled))
            bullets.append(Bullet(x: originX, y: originY, vx: vxAngled,   vy:  vyAngled))
            // Smartlink chrome: a 4th round splitting the lower gap.
            if loadout.extraBullet {
                bullets.append(Bullet(x: originX, y: originY, vx: vxAngled, vy: vxAngled * 0.045))
            }
        }
        isFiring = true
        firingPulseEnd = pulseTime + 0.28   // longer flash so the firing
                                            // sprite is actually visible
        // SMG fires every tap — kept 20% lower than the rest of the chase
        // SFX so a rapid-fire player doesn't drown the music + ambient mix.
        playSfx("gunshot_smg", volume: SFXManager.shared.targetVolume * 0.8)
        HapticsManager.shared.buttonTap()
    }

    // MARK: - Lifecycle

    private func initialise() {
        // Campaign tie-ins: Lyra's real build + persisted corp attention.
        loadout = HoverbikeChaseScene.buildLoadout()
        corpHeat = MissionStatsStore.shared.loadFactionAttention()[.corp] ?? 0
        hp = maxHp + loadout.bonusHP
        nextHeatDroneAt = corpHeat > 0 ? 12.0 : 0
        killCount = 0; hitsTaken = 0
        scorecard = []; walletLine = ""
        bossVentUntil = 0; nextVentAt = 0
        bossHpRemaining = bossHp
        // Bike starts at center-bottom of play zone (visually anchored
        // over the road, with room to move in all 4 directions).
        bikePos = CGPoint(x: 0.5, y: 0.78)
        bikeTargetPos = bikePos
        elapsed = 0
        pulseTime = 0
        distance = 0
        speed = 1.0
        bossActive = false
        bossX = 1.15
        bossY = 0.78
        bossYVisual = 0.78
        obstacles = []
        drones = []
        bullets = []
        enemyBullets = []
        pickups = []
        combo = 0; comboExpiry = 0; score = 0
        boost = 0; boostUntil = 0; empReadyAt = 0; shieldUntil = 0; empFlashUntil = 0
        bikeJumpY = 0; bikeJumpVel = 0
        currentSector = -1
        bannerUntil = 0; bannerTitle = ""; bannerSubtitle = ""; bannerAccent = "FF00AA"
        eliteSpawned = false
        nextGauntletAt = 22; gauntletWarnUntil = 0; gauntletUntil = 0; lastOncomingAt = 0
        weaponUpgradeUntil = 0
        nearMissText = ""; nearMissUntil = 0; nearMissCount = 0
        bgOffsetFar = 0
        bgOffsetMid = 0
        bgOffsetRoad = 0
        gameOver = false
        didWin = false
        // Initial iframe ~3s so the player has time to read the scene + try
        // a drag without immediate damage. Combined with the 3.5s spawn
        // grace this means roughly: scene visible → 0.5s try-drag window
        // → first obstacle starts approaching from far left.
        iframeUntil = 3.0
    }

    private func startTimers() {
        let dt: TimeInterval = 1.0 / 60.0
        tickTimer = Timer.publish(every: dt, on: .main, in: .common)
            .autoconnect()
            .sink { _ in tick(dt: CGFloat(dt)) }
        // Spawn cadence — 1.4s between spawns (was 0.9s). Keeps the screen
        // less cluttered and gives the player time to react to each threat.
        spawnTimer = Timer.publish(every: 0.80, on: .main, in: .common)
            .autoconnect()
            .sink { _ in spawnEntity() }
    }

    // MARK: - Tick (per-frame update)

    private func tick(dt: CGFloat) {
        guard !showBriefing, !gameOver else { return }

        pulseTime += Double(dt)
        elapsed += Double(dt)
        distance += speed * dt * 30   // arbitrary unit

        // Corp-heat pressure: persisted faction attention sends extra
        // chasers on a cadence that tightens with heat. The contract pays
        // proportionally more (heatRewardMultiplier at finish).
        if nextHeatDroneAt > 0 && pulseTime >= nextHeatDroneAt && !bossActive {
            var d = Drone(x: 1.08, y: randomPlayY(), nextFireAt: pulseTime + 1.2)
            d.kind = .chaser
            drones.append(d)
            nextHeatDroneAt = pulseTime + max(6.0, 14.0 - 3.0 * Double(min(3, corpHeat)))
        }

        // Ramp speed slowly up to 1.6× over the mission duration.
        speed = min(2.0, speed + dt * 0.009)

        // ── Sector progression ────────────────────────────────────────────
        // The run is split into themed stretches; entering one flashes a
        // banner. The existing density ramp already escalates the threat
        // count, so sectors mainly add narrative pacing + a readable arc.
        if !bossActive {
            var idx = 0
            for (i, s) in sectors.enumerated() where elapsed >= s.start { idx = i }
            if idx != currentSector {
                currentSector = idx
                showBanner(title: "SECTOR \(idx + 1)", subtitle: sectors[idx].name, accent: sectors[idx].accent)
                if idx > 0 { playSfx("agi_arrival_glitch", volume: 0.4) }
            }
        }

        // ── Mid-run ELITE enforcer (once, deep in the run) ──────────────────
        // Hold off while a gauntlet is running so the two set-pieces don't
        // stack into an unreadable wall.
        if !eliteSpawned && !bossActive && elapsed >= 62 && gauntletUntil == 0 {
            eliteSpawned = true
            spawnElite()
        }

        // ── Oncoming-traffic gauntlet ───────────────────────────────────────
        updateGauntlet(dt: dt)

        // Parallax scrolling — far is slowest, road is fastest.
        bgOffsetFar  = (bgOffsetFar  + speed * dt * 14).truncatingRemainder(dividingBy: 4000)
        bgOffsetMid  = (bgOffsetMid  + speed * dt * 38).truncatingRemainder(dividingBy: 4000)
        bgOffsetRoad = (bgOffsetRoad + speed * dt * 95).truncatingRemainder(dividingBy: 4000)

        // Move obstacles (ahead-of-bike traffic + barriers). vx is positive
        // — they move RIGHTWARD across the screen as the bike "passes" them.
        // Spawned at the LEFT edge, exit on the right.
        for i in obstacles.indices {
            obstacles[i].x += dt * obstacles[i].vx * speed
        }
        // Right-travelling hazards exit at x>1.2; oncoming-gauntlet cars (vx<0)
        // exit off the left at x<-0.2.
        obstacles.removeAll { $0.x > 1.2 || $0.x < -0.2 || $0.consumed }

        // Per-kind drone behaviour. EMP-stunned drones freeze entirely.
        for i in drones.indices {
            if pulseTime < drones[i].stunUntil { continue }
            switch drones[i].kind {
            case .chaser:
                drones[i].x -= dt * 0.18 * speed
                if drones[i].x > 0.20 && drones[i].x < 1.0 && pulseTime >= drones[i].nextFireAt {
                    spawnEnemyBulletFromDrone(drones[i])
                    drones[i].nextFireAt = pulseTime + Double.random(in: 3.2 ... 4.6)
                }
            case .rammer:
                if drones[i].charging {
                    drones[i].x -= dt * 0.85 * speed                       // fast dash left
                    drones[i].y += (bikePos.y - drones[i].y) * dt * 3.0    // home on the bike's lane
                    if drones[i].x < 0.08 { drones[i].charging = false; drones[i].windUntil = 0; drones[i].nextFireAt = pulseTime + 2.6 }
                } else if drones[i].windUntil > 0 {
                    if pulseTime >= drones[i].windUntil { drones[i].charging = true }   // telegraph done → dash
                } else {
                    drones[i].x -= dt * 0.14 * speed
                    if drones[i].x < 0.86 && pulseTime >= drones[i].nextFireAt {
                        drones[i].windUntil = pulseTime + 0.55             // red wind-up flash
                        playSfx("agi_arrival_glitch", volume: 0.35)
                    }
                }
            case .sniper:
                drones[i].x -= dt * 0.10 * speed
                if drones[i].windUntil > 0 {
                    if pulseTime >= drones[i].windUntil {                  // fire fast aimed bolt
                        let dx = bikePos.x - drones[i].x, dy = bikePos.y - drones[i].y
                        let mag = max(0.01, sqrt(dx * dx + dy * dy)); let v: CGFloat = 0.9
                        enemyBullets.append(EnemyBullet(x: drones[i].x, y: drones[i].y, vx: dx / mag * v, vy: dy / mag * v))
                        playSfx("gunshot_pistol", volume: 0.75)
                        drones[i].windUntil = 0
                        drones[i].nextFireAt = pulseTime + Double.random(in: 2.6 ... 4.0)
                    }
                } else if drones[i].x > 0.30 && drones[i].x < 1.0 && pulseTime >= drones[i].nextFireAt {
                    drones[i].windUntil = pulseTime + 0.9                  // laser-sight telegraph
                }
            case .gunner:
                let holdX: CGFloat = 0.82
                if drones[i].x > holdX { drones[i].x -= dt * 0.30 * speed }
                drones[i].y += (bikePos.y - drones[i].y) * dt * 0.8        // slowly track the bike's lane
                if drones[i].x <= holdX + 0.02 && pulseTime >= drones[i].nextFireAt {
                    spawnEnemyBulletFromDrone(drones[i])
                    drones[i].nextFireAt = (Int.random(in: 0..<3) == 0)
                        ? pulseTime + Double.random(in: 2.2 ... 3.4)       // pause between bursts
                        : pulseTime + 0.34                                 // burst cadence
                }
            case .miner:
                drones[i].x -= dt * 0.16 * speed
                if drones[i].x > 0.15 && drones[i].x < 0.95 && pulseTime >= drones[i].nextFireAt {
                    obstacles.append(Obstacle(x: drones[i].x, y: drones[i].y, kind: .mine, vx: 0.30))
                    drones[i].nextFireAt = pulseTime + Double.random(in: 1.2 ... 2.0)
                }
            case .enforcer:
                // ELITE mini-boss: holds alongside and strafes aimed bolts,
                // and periodically winds up a fast homing charge.
                let holdX: CGFloat = 0.80
                if drones[i].charging {
                    drones[i].x -= dt * 0.72 * speed
                    drones[i].y += (bikePos.y - drones[i].y) * dt * 2.4
                    if drones[i].x < 0.12 {
                        drones[i].charging = false
                        drones[i].x = 0.92
                        drones[i].windUntil = 0
                        drones[i].nextFireAt = pulseTime + 1.0
                    }
                } else if drones[i].windUntil > 0 {
                    if pulseTime >= drones[i].windUntil { drones[i].charging = true }
                } else {
                    if drones[i].x > holdX { drones[i].x -= dt * 0.26 * speed }
                    drones[i].y += (bikePos.y - drones[i].y) * dt * 0.7
                    if drones[i].x <= holdX + 0.02 && pulseTime >= drones[i].nextFireAt {
                        spawnEnemyBulletFromDrone(drones[i])
                        if Int.random(in: 0..<5) == 0 {
                            drones[i].windUntil = pulseTime + 0.7      // telegraph the charge
                            playSfx("agi_arrival_glitch", volume: 0.4)
                        }
                        drones[i].nextFireAt = pulseTime + Double.random(in: 0.5 ... 1.1)
                    }
                }
            }
        }
        drones.removeAll { $0.x < -0.2 || $0.consumed }

        // Pickups scroll rightward like ahead-of-bike traffic.
        for i in pickups.indices { pickups[i].x += dt * pickups[i].vx * speed }
        pickups.removeAll { $0.x > 1.2 || $0.consumed }

        // Ramp jump arc (visual hop; grants ground-hazard immunity while airborne).
        if bikeJumpVel != 0 || bikeJumpY < 0 {
            bikeJumpVel += 900 * dt
            bikeJumpY += bikeJumpVel * dt
            if bikeJumpY >= 0 { bikeJumpY = 0; bikeJumpVel = 0 }
        }

        // Combo decay + passive boost trickle.
        if combo > 0 && pulseTime > comboExpiry { combo = 0 }

        // Move bullets along their (vx, vy) velocity.
        for i in bullets.indices {
            bullets[i].x += dt * bullets[i].vx
            bullets[i].y += dt * bullets[i].vy
        }
        bullets.removeAll { $0.x > 1.2 || $0.y < -0.05 || $0.y > 1.1 }

        // Move enemy bullets toward bike (continuous velocity set at spawn).
        for i in enemyBullets.indices {
            enemyBullets[i].x += dt * enemyBullets[i].vx
            enemyBullets[i].y += dt * enemyBullets[i].vy
        }
        enemyBullets.removeAll { $0.x < -0.05 || $0.x > 1.2 || $0.y < -0.05 || $0.y > 1.1 }

        // Firing pulse expiry
        if isFiring && pulseTime > firingPulseEnd {
            isFiring = false
        }

        // Boss arrival
        if !bossActive && elapsed >= bossArrivalSeconds {
            spawnBoss()
        }
        if bossActive {
            tickBoss(dt: dt)
        }

        // Removed auto-win-by-time-survival. Boss kill is now the only
        // win path (or manual BAIL for end-without-victory).

        // Collisions
        resolveCollisions()
    }

    // MARK: - Spawning

    private func spawnEntity() {
        guard !showBriefing, !gameOver, !bossActive else { return }
        // Grace period — no spawns for the first 3.5s so the player can
        // orient + try the drag controls before the first hazard lands.
        guard elapsed > 3.5 else { return }
        // During an oncoming gauntlet, the wave IS the content — pause normal
        // traffic/drones so the screen stays readable.
        if gauntletUntil > 0 && pulseTime >= gauntletWarnUntil && pulseTime < gauntletUntil { return }
        // Intensity ramp: sparse early, builds to a constant onslaught by the
        // back half of the (longer) run — paces the new enemy variety.
        let density = min(1.0, 0.60 + elapsed * 0.016)
        guard Double.random(in: 0..<1) < density else { return }

        // Don't stack threats too tightly:
        //   • Obstacles enter from LEFT (x=-0.1) and travel RIGHT.
        //   • Drones enter from RIGHT (x=1.1) and travel LEFT.
        let recentObstacle = obstacles.contains(where: { $0.x < 0.18 })
        let recentDrone    = drones.contains(where: { $0.x > 0.85 })

        // Random Y within the play zone. For the first 8 seconds, bias the
        // spawn away from the bike's current Y so the opener isn't brutal.
        var spawnY = randomPlayY()
        if elapsed < 8.0 && abs(spawnY - bikePos.y) < 0.08 {
            // Re-roll once to a safer Y far from the bike.
            spawnY = bikePos.y > (playMinY + playMaxY) / 2
                ? CGFloat.random(in: playMinY ... (bikePos.y - 0.08))
                : CGFloat.random(in: (bikePos.y + 0.08) ... playMaxY)
        }

        let roll = Int.random(in: 0..<100)
        if roll < 40 {
            // Drone — variety unlocks as the chase escalates.
            guard !recentDrone else { return }
            let r2 = Int.random(in: 0..<100)
            let kind: DroneKind
            if elapsed > 18 && r2 < 16      { kind = .sniper }
            else if elapsed > 12 && r2 < 38 { kind = .rammer }
            else if elapsed > 24 && r2 < 52 { kind = .gunner }
            else if elapsed > 28 && r2 < 66 { kind = .miner }
            else                            { kind = .chaser }
            var d = Drone(x: 1.1, y: spawnY, nextFireAt: pulseTime + Double.random(in: 1.5 ... 3.0))
            d.kind = kind
            switch kind {
            case .chaser: d.hp = 2
            case .rammer: d.hp = 2
            case .sniper: d.hp = 1
            case .gunner: d.hp = 3
            case .miner:  d.hp = 2
            case .enforcer: d.hp = 14   // never random-spawned (see spawnElite)
            }
            drones.append(d)
        } else if roll < 70 {
            // Civilian hovercar — scrolls right as the bike overtakes it.
            guard !recentObstacle else { return }
            let kind: ObstacleKind = Bool.random() ? .carA : .carB
            obstacles.append(Obstacle(x: -0.1, y: spawnY, kind: kind, vx: 0.18))
        } else if roll < 86 {
            // Energy barrier — highway hazard.
            guard !recentObstacle else { return }
            obstacles.append(Obstacle(x: -0.1, y: spawnY, kind: .barrier, vx: 0.32))
        } else if roll < 93 {
            // Ramp — hop over it to leap incoming ground hazards.
            guard !recentObstacle else { return }
            obstacles.append(Obstacle(x: -0.1, y: spawnY, kind: .ramp, vx: 0.30))
        } else {
            // Pickup — health when hurt; otherwise alternate weapon-upgrade
            // and shield so a healthy player still has something to chase.
            let pk: Pickup.Kind
            if hp < maxHp { pk = .health }
            else { pk = (Int.random(in: 0..<2) == 0) ? .weapon : .shield }
            pickups.append(Pickup(x: -0.1, y: spawnY, vx: 0.22, kind: pk))
        }
    }

    private func spawnEnemyBulletFromDrone(_ d: Drone) {
        // Bullet originates at the drone's position and aims toward the
        // bike's CURRENT position (not predictive — player can dodge by
        // moving anywhere in the 2D play zone).
        let dx = bikePos.x - d.x
        let dy = bikePos.y - d.y
        let mag = max(0.01, sqrt(dx * dx + dy * dy))
        let v: CGFloat = 0.46
        enemyBullets.append(EnemyBullet(
            x: d.x, y: d.y,
            vx: dx / mag * v, vy: dy / mag * v
        ))
        playSfx("gunshot_pistol", volume: 0.6)
    }

    // MARK: - Sector / event helpers

    /// Flash a centered announce banner (sector entry, gauntlet warning,
    /// elite arrival). Auto-dismisses ~2.6s later (see chaseContent overlay).
    private func showBanner(title: String, subtitle: String, accent: String) {
        bannerTitle = title
        bannerSubtitle = subtitle
        bannerAccent = accent
        bannerUntil = pulseTime + 2.6
    }

    /// Spawn the one-time ELITE enforcer mini-boss.
    private func spawnElite() {
        var d = Drone(x: 1.15, y: (playMinY + playMaxY) / 2, nextFireAt: pulseTime + 1.2)
        d.kind = .enforcer
        d.hp = 14
        drones.append(d)
        showBanner(title: "⚠ ELITE THREAT", subtitle: "CORP ENFORCER INBOUND", accent: "FFFFFF")
        playSfx("agi_arrival_glitch", volume: 0.7)
        HapticsManager.shared.playerKilled()
    }

    /// Schedule + drive the oncoming-traffic gauntlet: a warned ~6s burst of
    /// wrong-way cars racing in from the right. Repeats on a randomized cadence.
    private func updateGauntlet(dt: CGFloat) {
        guard !bossActive else { return }
        // Kick off a new warned wave.
        if gauntletUntil == 0 && gauntletWarnUntil == 0 && pulseTime >= nextGauntletAt {
            gauntletWarnUntil = pulseTime + 1.6
            gauntletUntil = gauntletWarnUntil + 6.0
            showBanner(title: "⚠ ONCOMING TRAFFIC", subtitle: "WRONG-WAY HAULERS — WEAVE!", accent: "FF3344")
            playSfx("agi_arrival_glitch", volume: 0.55)
            HapticsManager.shared.buttonTap()
        }
        let active = gauntletUntil > 0 && pulseTime >= gauntletWarnUntil && pulseTime < gauntletUntil
        if active && pulseTime - lastOncomingAt > 1.05 {
            lastOncomingAt = pulseTime
            // True HEAD-ON oncoming: the bike travels LEFT, so "ahead" is the
            // left edge. Wrong-way haulers appear from ahead (left) and race
            // RIGHTWARD (vx>0) toward + past the bike, facing right — the
            // opposite way to the bike, which sells the "wrong way" read.
            // Bias spawn Y away from the bike so there's always a weave gap.
            var y = randomPlayY()
            if abs(y - bikePos.y) < 0.1 {
                y = bikePos.y > (playMinY + playMaxY) / 2
                    ? CGFloat.random(in: playMinY ... max(playMinY, bikePos.y - 0.1))
                    : CGFloat.random(in: min(playMaxY, bikePos.y + 0.1) ... playMaxY)
            }
            let kind: ObstacleKind = Bool.random() ? .carA : .carB
            obstacles.append(Obstacle(x: -0.15, y: y, kind: kind, vx: 0.85,
                                      oncoming: true, variant: Int.random(in: 0..<3)))
        }
        // Wave finished — schedule the next.
        if gauntletUntil > 0 && pulseTime >= gauntletUntil {
            gauntletUntil = 0
            gauntletWarnUntil = 0
            nextGauntletAt = pulseTime + Double.random(in: 24 ... 34)
        }
    }

    /// ELITE enforcer destroyed — big score + a supply drop at the kill site.
    private func onEliteDown(at d: Drone) {
        score += 500
        showBanner(title: "ENFORCER DOWN", subtitle: "+500 · SUPPLY DROP", accent: "00FF88")
        let dropX = max(0.22, d.x)
        pickups.append(Pickup(x: dropX, y: d.y, vx: 0.14, kind: .weapon))
        pickups.append(Pickup(x: dropX - 0.07, y: min(playMaxY, d.y + 0.06),
                              vx: 0.14, kind: hp < maxHp ? .health : .shield))
        playSfx("agi_death", volume: 0.75)
        HapticsManager.shared.victory()
    }

    /// A hazard slipped past within a whisker — reward the risk.
    private func registerNearMiss() {
        nearMissCount += 1
        score += 35
        boost = min(1.0, boost + 0.05)
        nearMissText = "NEAR MISS +35"
        nearMissUntil = pulseTime + 0.7
        playSfx("bike_swerve", volume: 0.35)
    }

    private func spawnBoss() {
        bossActive = true
        bossX = 1.15
        bossYVisual = (playMinY + playMaxY) / 2
        bossY = bossYVisual
        bossYSwapAt = pulseTime + 3.0
        // Clear smaller threats — boss is the focal challenge.
        drones.removeAll()
        obstacles.removeAll()
        nextVentAt = pulseTime + 6.0   // first weak-point window
        playSfx("agi_arrival_glitch", volume: 0.7)
    }

    private func tickBoss(dt: CGFloat) {
        let targetX: CGFloat = 0.78
        if bossX > targetX { bossX -= dt * 0.18 }

        // Three phases by remaining HP — it gets faster and dirtier as it dies.
        let frac = Double(bossHpRemaining) / Double(bossHp)
        let phase = frac > 0.66 ? 1 : (frac > 0.33 ? 2 : 3)
        let wanderSpeed: CGFloat = phase == 1 ? 2.0 : (phase == 2 ? 2.8 : 3.6)
        let swapGap: ClosedRange<Double> = phase == 1 ? 2.0...3.5 : (phase == 2 ? 1.4...2.4 : 0.9...1.7)

        bossYVisual += (bossY - bossYVisual) * dt * wanderSpeed
        if pulseTime >= bossYSwapAt {
            bossY = CGFloat.random(in: playMinY ... playMaxY)
            bossYSwapAt = pulseTime + Double.random(in: swapGap)
        }
        guard bossX < targetX + 0.05 else { return }

        // Weak-point windows: vents cycle open between barrages — the boss
        // holds fire while exposed, so the window is both DPS and breather.
        if nextVentAt > 0 && pulseTime >= nextVentAt {
            bossVentUntil = pulseTime + 2.6
            nextVentAt = pulseTime + (phase == 3 ? 6.5 : 8.5)
            showBanner(title: "VENTS OPEN", subtitle: "Hull exposed — pour it on!", accent: "FFA500")
            playSfx("hit_metal", volume: 0.9)
        }
        let ventsOpen = pulseTime < bossVentUntil

        // Spread barrage — cadence + count escalate by phase.
        let fireGap: Double = phase == 1 ? 1.4 : (phase == 2 ? 1.0 : 0.7)
        if !ventsOpen, pulseTime.truncatingRemainder(dividingBy: fireGap) < Double(dt) {
            let offs: [CGFloat] = phase == 3
                ? [-0.10, -0.06, -0.02, 0.02, 0.06, 0.10]
                : [-0.08, -0.04, 0, 0.04, 0.08]
            for yOffset in offs {
                let dx = bikePos.x - bossX
                let dy = bikePos.y + yOffset - bossYVisual
                let mag = max(0.01, sqrt(dx * dx + dy * dy))
                let v: CGFloat = 0.65
                enemyBullets.append(EnemyBullet(x: bossX, y: bossYVisual, vx: dx / mag * v, vy: dy / mag * v))
            }
            playSfx("mech_autocannon", volume: 0.55)
        }
        // Phase 2+: deploy escort drones.
        if phase >= 2 && pulseTime.truncatingRemainder(dividingBy: 6.0) < Double(dt) {
            var d = Drone(x: 1.1, y: randomPlayY(), nextFireAt: pulseTime + 1.0)
            d.kind = .chaser
            drones.append(d)
        }
        // Phase 3: scatter mines too.
        if phase == 3 && pulseTime.truncatingRemainder(dividingBy: 2.5) < Double(dt) {
            obstacles.append(Obstacle(x: -0.1, y: randomPlayY(), kind: .mine, vx: 0.30))
        }
    }

    // MARK: - Collisions

    private func resolveCollisions() {
        let boosting = pulseTime < boostUntil
        let airborne = bikeJumpY < -8
        let invuln = pulseTime <= iframeUntil || pulseTime < shieldUntil || boosting

        // Player bullets vs drones.
        for bi in bullets.indices.reversed() where bi < bullets.count {
            let b = bullets[bi]
            for di in drones.indices where !drones[di].consumed {
                if abs(drones[di].x - b.x) < 0.07 && abs(drones[di].y - b.y) < 0.06 {
                    drones[di].hp -= loadout.bulletDamage
                    bullets.remove(at: bi)
                    playSfx("hit_metal", volume: 0.7)
                    if drones[di].hp <= 0 {
                        let wasElite = drones[di].kind == .enforcer
                        drones[di].consumed = true
                        registerKill()
                        if wasElite { onEliteDown(at: drones[di]) }
                    }
                    break
                }
            }
        }
        // Player bullets vs boss.
        if bossActive {
            for bi in bullets.indices.reversed() where bi < bullets.count {
                let b = bullets[bi]
                if abs(bossX - b.x) < 0.10 && abs(bossYVisual - b.y) < 0.10 {
                    // Weak-point windows: hull shots chip, vent shots CHUNK.
                    let ventOpen = pulseTime < bossVentUntil
                    bossHpRemaining -= (ventOpen ? 3 : 1) + (loadout.bulletDamage - 1)
                    bullets.remove(at: bi)
                    playSfx("hit_metal", volume: ventOpen ? SFXManager.shared.targetVolume * 1.25 : nil)
                    if ventOpen { HapticsManager.shared.attackHit() }
                    if bossHpRemaining <= 0 {
                        bossActive = false; playSfx("agi_death"); finishGame(win: true); return
                    }
                }
            }
        }
        // Bike vs drones — ram (destroy) while boosting; a charging rammer that
        // body-checks the bike otherwise hurts.
        for di in drones.indices where !drones[di].consumed {
            guard abs(drones[di].x - bikePos.x) < 0.07 && abs(drones[di].y - bikePos.y) < 0.06 else { continue }
            if boosting {
                if drones[di].kind == .enforcer {
                    // The elite is too tough to ram-kill outright — boost
                    // chunks it instead.
                    drones[di].hp -= 4
                    playSfx("hit_metal", volume: 0.9)
                    if drones[di].hp <= 0 { drones[di].consumed = true; registerKill(); onEliteDown(at: drones[di]) }
                } else {
                    drones[di].consumed = true; registerKill(); playSfx("hit_metal", volume: 0.8)
                }
            } else if drones[di].kind == .rammer && drones[di].charging && !invuln {
                takeHit(); drones[di].consumed = true
            }
        }
        // Bike vs obstacles.
        for i in obstacles.indices where !obstacles[i].consumed {
            let ob = obstacles[i]
            // Oncoming haulers are bigger on screen, so give them a slightly
            // wider hitbox to match what the player sees.
            let hbX: CGFloat = ob.oncoming ? 0.09 : 0.08
            let hbY: CGFloat = ob.oncoming ? 0.075 : 0.06
            guard abs(ob.x - bikePos.x) < hbX && abs(ob.y - bikePos.y) < hbY else { continue }
            switch ob.kind {
            case .ramp:
                if bikeJumpVel == 0 && bikeJumpY == 0 {
                    bikeJumpVel = -340
                    playSfx("agi_arrival_glitch", volume: 0.4)
                    HapticsManager.shared.buttonTap()
                }
                obstacles[i].consumed = true
            case .mine:
                if boosting { obstacles[i].consumed = true; registerKill() }    // ram through
                else if airborne || invuln { /* hopped / shielded over it */ }
                else { takeHit(); obstacles[i].consumed = true }
            default:   // car / barrier
                if boosting { obstacles[i].consumed = true }
                else if invuln { /* shielded — phase through */ }
                else { takeHit(); obstacles[i].consumed = true }
            }
        }
        // Bike vs enemy bullets.
        if invuln {
            enemyBullets.removeAll { abs($0.x - bikePos.x) < 0.045 && abs($0.y - bikePos.y) < 0.045 }
        } else {
            for bi in enemyBullets.indices.reversed() {
                let b = enemyBullets[bi]
                if abs(b.x - bikePos.x) < 0.04 && abs(b.y - bikePos.y) < 0.04 {
                    takeHit(); enemyBullets.remove(at: bi); break
                }
            }
        }
        // Bike vs pickups.
        for i in pickups.indices where !pickups[i].consumed {
            if abs(pickups[i].x - bikePos.x) < 0.06 && abs(pickups[i].y - bikePos.y) < 0.06 {
                switch pickups[i].kind {
                case .health: hp = min(maxHp, hp + 1)
                case .shield: shieldUntil = pulseTime + 5.0
                case .weapon: weaponUpgradeUntil = pulseTime + 12.0
                }
                pickups[i].consumed = true
                playSfx("hack_success", volume: 0.95)
                HapticsManager.shared.victory()
            }
        }

        // ── Near-miss bonuses ──────────────────────────────────────────────
        // A hazard/tracer that slips past on the FAR side within a whisker
        // (but didn't actually collide — those are already consumed above)
        // pays a small score + boost trickle, rewarding tight dodges.
        let nmX: CGFloat = 0.115, nmY: CGFloat = 0.085
        for i in obstacles.indices where !obstacles[i].consumed && !obstacles[i].scoredNearMiss {
            let ob = obstacles[i]
            guard ob.kind != .ramp else { continue }   // ramps are good — no bonus
            let passed = ob.vx >= 0 ? ob.x > bikePos.x : ob.x < bikePos.x
            if passed && abs(ob.x - bikePos.x) < nmX && abs(ob.y - bikePos.y) < nmY {
                obstacles[i].scoredNearMiss = true
                registerNearMiss()
            }
        }
        for i in enemyBullets.indices where !enemyBullets[i].scoredNearMiss {
            let b = enemyBullets[i]
            let passed = b.vx >= 0 ? b.x > bikePos.x : b.x < bikePos.x
            if passed && abs(b.x - bikePos.x) < nmX && abs(b.y - bikePos.y) < nmY {
                enemyBullets[i].scoredNearMiss = true
                registerNearMiss()
            }
        }
    }

    /// Drone/obstacle destroyed — combo, score, boost gain + a small
    /// explosion pop so kills read audibly (playtest: kills felt silent).
    private func registerKill() {
        killCount += 1
        combo += 1
        comboExpiry = pulseTime + 3.0
        score += 50 * max(1, combo)
        boost = min(1.0, boost + 0.16 + Double(min(combo, 6)) * 0.01)
        playSfx("enemy_death_drone", volume: 0.75)
        HapticsManager.shared.attackHit()
    }

    private func takeHit() {
        // Re-check i-frames HERE: resolveCollisions computes its `invuln`
        // once per pass, so a rammer + mine + tracer overlapping the bike in
        // a single frame dealt 3 stacked hits — instant death from full HP.
        guard pulseTime > iframeUntil && pulseTime >= shieldUntil else { return }
        hp -= 1
        hitsTaken += 1
        iframeUntil = pulseTime + 1.2
        combo = 0
        playSfx("player_hit")
        HapticsManager.shared.playerKilled()
        if hp <= 0 {
            finishGame(win: false)
        }
    }

    // MARK: - Boost / EMP

    private func tryBoost() {
        guard boost >= 1.0, !gameOver, !showBriefing, pulseTime > boostUntil else { return }
        boost = 0
        boostUntil = pulseTime + 1.0 + loadout.boostBonus
        iframeUntil = max(iframeUntil, pulseTime + 1.0)
        playSfx("agi_arrival_glitch", volume: 0.8)
        HapticsManager.shared.victory()
        // Make the dash legible: a banner so the player understands the
        // window of invincibility + ram-kill they just triggered.
        showBanner(title: "⚡ NITRO", subtitle: "INVINCIBLE — RAM THROUGH", accent: "FFE044")
    }

    private func tryEMP() {
        guard pulseTime >= empReadyAt, !gameOver, !showBriefing else { return }
        empReadyAt = pulseTime + 8.0
        empFlashUntil = pulseTime + 0.4
        for i in drones.indices {
            drones[i].stunUntil = pulseTime + 2.5
            drones[i].windUntil = 0
            drones[i].charging = false
        }
        enemyBullets.removeAll()
        playSfx("agi_death", volume: 0.55)
        HapticsManager.shared.buttonTap()
    }

    // MARK: - End / bail

    private func finishGame(win: Bool) {
        guard !gameOver else { return }
        gameOver = true
        didWin = win
        tickTimer?.cancel()
        spawnTimer?.cancel()
        if win {
            HapticsManager.shared.victory()
            playSfx("mission_victory")
            // Record the chase as a completed mission so the mission-select
            // card flips to "completed" + the base payout credits the wallet.
            // Score blends time-survived + boss-down bonus so a slow win still
            // banks something and a clean win banks more.
            // Faster win = higher score (1500 floor at long fights, up to
            // ~1500 if the gunship drops fast). Caps so a slow win still pays.
            let speedBonus = max(0, 1000 - Int(elapsed * 4))
            let integrityBonus = hp * 100
            let styleBonus = score / 3
            let chaseScore = 500 + speedBonus + integrityBonus + styleBonus
            MissionStatsStore.shared.recordVictory(
                missionId: "Mission003_5",
                score: chaseScore,
                dataAcquired: false,
                grimoireAcquired: false,
                rewardMultiplier: heatRewardMultiplier
            )
            scorecard = [
                ("RUN CLEARED", "500"),
                ("SPEED BONUS", "\(speedBonus)"),
                ("BIKE INTEGRITY ×\(hp)", "\(integrityBonus)"),
                ("STYLE · \(killCount) KILLS · \(nearMissCount) NEAR MISS", "\(styleBonus)"),
                ("SCORE — RANK \(MissionStatsStore.rank(forScore: chaseScore))", "\(chaseScore)"),
            ]
            if corpHeat > 0 {
                scorecard.append(("CORP HEAT ×\(min(3, corpHeat))",
                                  String(format: "PAY ×%.2f", heatRewardMultiplier)))
            }
            walletLine = "¥\(MissionStatsStore.shared.lastWalletCredit) CREDITED"
        } else {
            HapticsManager.shared.defeat()
            playSfx("mission_defeat")
            scorecard = [
                ("SURVIVED", String(format: "%.0fs", elapsed)),
                ("DRONES DOWNED", "\(killCount)"),
                ("HITS TAKEN", "\(hitsTaken)"),
            ]
            walletLine = "NO PAYOUT — DRIVE LOST"
        }
    }

    private func bailOut() {
        HapticsManager.shared.buttonTap()
        _ = manager.transition(to: .finishHoverbikeChase)
    }
}

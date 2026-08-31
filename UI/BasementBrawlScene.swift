import SwiftUI
import Combine

// MARK: - M4.5 "Basement Brawl" — SF/MK-style 2D fighter (Phase 1 engine)
//
// LANDSCAPE: the app is portrait-locked, so the whole scene renders in a
// logical landscape canvas rotated 90° with a "turn your phone" prompt. All
// gameplay coordinates are in that landscape space.
//
// CONTROLS (two thumbs):
//   LEFT  — virtual stick: hold forward = walk in, hold BACK = walk out + BLOCK
//           (hold-back-to-block, SF style), hold down = crouch, flick up = jump.
//           Crouch-block guards lows; stand-block guards mids & overheads.
//   RIGHT — LIGHT / HEAVY buttons. Attack height is contextual:
//           grounded = mid, crouching = LOW, airborne = OVERHEAD.
//
// Gauntlet of 5 fighters (brawler → vargas), Vargas is a 3-phase boss.

// MARK: - Attack model

private enum PlayerAttack {
    case light, heavy
    var damage: Int      { self == .light ? 1 : 3 }
    var windup: Double   { self == .light ? 0.10 : 0.26 }
    var active: Double   { self == .light ? 0.10 : 0.12 }
    var recover: Double  { self == .light ? 0.13 : 0.30 }
    /// Reach as a fraction of the landscape canvas width.
    var reach: CGFloat   { self == .light ? 0.16 : 0.22 }
    var pushback: CGFloat { self == .light ? 10 : 22 }
}

private enum AtkPhase { case none, windup, active, recover }
private enum AttackHeight { case mid, low, overhead }

// MARK: - Enemy data (reused tuning)

private enum BrawlArchetype { case standard, armored, combo, ranged, boss }

private struct EnemyProfile {
    let maxHP: Int
    let approachSpeed: CGFloat
    let windupTime: Double
    let strikeTime: Double
    let recoverTime: Double
    let attackDamage: Int
    let label: String
    let archetype: BrawlArchetype
    /// 0 = no armor; 1 = only HEAVY pierces (chrome slugger / Vargas overload).
    let armorBreakLevel: Int
    /// How often (0..1) the enemy chooses to block when the player attacks.
    let blockChance: Double
}

private func enemyProfile(for enemy: BasementBrawlScene.WaveEnemy, vargasPhase: Int = 1) -> EnemyProfile {
    switch enemy {
    case .brawler:
        return EnemyProfile(maxHP: 7, approachSpeed: 130, windupTime: 0.65, strikeTime: 0.14,
                            recoverTime: 0.55, attackDamage: 2, label: "PIT BRAWLER",
                            archetype: .standard, armorBreakLevel: 0, blockChance: 0.10)
    case .slugger:
        return EnemyProfile(maxHP: 11, approachSpeed: 95, windupTime: 0.80, strikeTime: 0.18,
                            recoverTime: 0.70, attackDamage: 3, label: "CHROME SLUGGER",
                            archetype: .armored, armorBreakLevel: 1, blockChance: 0.25)
    case .razorgirl:
        return EnemyProfile(maxHP: 8, approachSpeed: 180, windupTime: 0.40, strikeTime: 0.10,
                            recoverTime: 0.34, attackDamage: 2, label: "RAZORGIRL",
                            archetype: .combo, armorBreakLevel: 0, blockChance: 0.20)
    case .bodyguard:
        return EnemyProfile(maxHP: 9, approachSpeed: 110, windupTime: 0.55, strikeTime: 0.12,
                            recoverTime: 0.55, attackDamage: 3, label: "SUIT + PISTOL",
                            archetype: .ranged, armorBreakLevel: 0, blockChance: 0.15)
    case .vargas:
        switch vargasPhase {
        case 1:
            return EnemyProfile(maxHP: 12, approachSpeed: 120, windupTime: 0.60, strikeTime: 0.14,
                                recoverTime: 0.55, attackDamage: 3, label: "VARGAS — PHASE 1",
                                archetype: .boss, armorBreakLevel: 0, blockChance: 0.30)
        case 2:
            return EnemyProfile(maxHP: 12, approachSpeed: 150, windupTime: 0.48, strikeTime: 0.12,
                                recoverTime: 0.42, attackDamage: 3, label: "VARGAS — PHASE 2",
                                archetype: .boss, armorBreakLevel: 0, blockChance: 0.35)
        default:
            return EnemyProfile(maxHP: 12, approachSpeed: 190, windupTime: 0.34, strikeTime: 0.10,
                                recoverTime: 0.30, attackDamage: 4, label: "VARGAS — OVERLOAD",
                                archetype: .boss, armorBreakLevel: 1, blockChance: 0.40)
        }
    }
}

// MARK: - Fighter state

private struct FighterState {
    var x: CGFloat                 // ground-plane X (landscape points)
    var jumpY: CGFloat = 0         // negative = airborne
    var jumpVel: CGFloat = 0
    var airVelX: CGFloat = 0       // horizontal momentum while airborne (jump arc)
    var crouching = false
    var blocking = false
    var hp: Int
    var maxHP: Int
    var facing: CGFloat = 1        // +1 faces right, -1 faces left

    var attack: PlayerAttack? = nil
    var phase: AtkPhase = .none
    var phaseTimer: Double = 0
    var height: AttackHeight = .mid
    var hasHit = false
    var special = false            // special / super-flavored attack

    var hitstun: Double = 0
    var blockstun: Double = 0
    var hitFlash: Double = 0
    var hitSplat: Double = 0        // blood-splatter VFX timer (set on flesh hits)
    var splatDir: CGFloat = 1       // +1 = blood flies right (struck from the left)
    var moving = false
    var walkClock: Double = 0

    // Parry: a tight-timed deflect. `parryTimer` > 0 = active deflect window;
    // a hit landing during it is negated and the attacker is counter-stunned.
    // `parryCD` locks out spamming; `parryFlash` drives the deflect VFX.
    var parryTimer: Double = 0
    var parryCD: Double = 0
    var parryFlash: Double = 0

    // Dash/dodge: a quick burst of horizontal movement with brief invuln
    // (`dashTimer` > 0 = i-frames + dash pose). `dashCD` gates spam,
    // `dashDir` is the locked direction for the burst.
    var dashTimer: Double = 0
    var dashCD: Double = 0
    var dashDir: CGFloat = 1

    var busy: Bool { phase != .none || hitstun > 0 || blockstun > 0 || parryTimer > 0 }
}

// MARK: - Scene

struct BasementBrawlScene: View {
    @ObservedObject var manager: PhaseManager

    enum WaveEnemy: String, CaseIterable {
        case brawler, slugger, razorgirl, bodyguard, vargas
        var label: String { enemyProfile(for: self).label }
    }

    // MARK: Tuning
    private let playerMaxHP = 14
    private let groundYFrac: CGFloat = 0.84      // ground line (fraction of H) — lowered for portrait headroom
    private let walkSpeed: CGFloat = 250         // pts/sec — snappier footsies
    private let jumpVel0: CGFloat = -660
    private let gravity: CGFloat = 1850          // less floaty
    private let minSeparationFrac: CGFloat = 0.13
    private let edgePadFrac: CGFloat = 0.07
    private let blockChip = 1
    private let comboGrace: Double = 0.5

    // MARK: State
    @State private var player = FighterState(x: 0, hp: 14, maxHP: 14)
    @State private var enemy  = FighterState(x: 0, hp: 7, maxHP: 7, facing: 1)
    @State private var waveIndex = 0
    @State private var vargasPhase = 1

    @State private var gameOver = false
    @State private var didWin = false
    @State private var roundIntro: Double = 0     // counts down at wave start (lock input)
    /// True while the VS card is parked waiting for the player to tap in.
    @State private var awaitingFightTap = false
    /// How long the card has been parked — drives the auto-advance safety net.
    @State private var fightCardHold: Double = 0
    /// Backstop so a missed tap can't strand the brawl on the VS card.
    private static let fightCardAutoAdvance: Double = 12.0

    /// Leave the VS card and roll into the FIGHT! beat.
    private func beginFightFromCard() {
        awaitingFightTap = false
        fightCardHold = 0
        // Drop straight to the "FIGHT!" portion of the intro (the card is drawn
        // while roundIntro > 0.7) so tapping in feels immediate.
        roundIntro = min(roundIntro, 0.7)
        HapticsManager.shared.buttonTap()
    }
    @State private var bannerText = ""
    @State private var bannerHold: Double = 0

    @State private var comboCount = 0
    @State private var comboTimer: Double = 0

    @State private var hitStop: Double = 0
    @State private var slowMo: Double = 0     // >0 = bullet-time on the finisher
    @State private var shake: CGFloat = 0
    @State private var koActive = false       // enemy down — holding on the fall
    @State private var koTimer: Double = 0
    @State private var clock: Double = 0
    @State private var turnHintHold: Double = 4.0  // "turn your phone" fades after 4s
    @State private var canvasW: CGFloat = 800       // landscape canvas width (set on appear)
    // Phase 2 — super meter / special / finisher
    @State private var meter: Double = 0            // 0...1 super gauge
    @State private var specialCD: Double = 0
    @State private var superActive: Double = 0      // >0 during the finisher freeze
    @State private var superHitDone = false
    @State private var flashAlpha: Double = 0
    @State private var fxColor: String = "FFE044"
    @State private var showTurnPrompt = true        // "turn your phone + how to fight" intro gate

    // Left-stick gesture intent
    @State private var stickActive = false
    @State private var stickDX: CGFloat = 0
    @State private var stickDY: CGFloat = 0
    @State private var jumpArmed = true

    @State private var razeImg: UIImage?
    @State private var enemyImg: UIImage?

    // MARK: Campaign tie-ins + run stats (playtest bundle 2026-07-19)

    /// Raze's ACTUAL roster build carried into the pit — chrome and blades
    /// bought at the black market matter here too.
    private struct BrawlLoadout {
        var bonusHP: Int = 0            // BOD + subdermal soak chrome
        var heavyBonus: Int = 0         // purchased heavy blade sharpens HEAVY
        var briefingLines: [(String, String)] = []
    }
    @State private var loadout = BrawlLoadout()
    /// Persisted corp attention: tougher pit fighters, richer purse.
    @State private var corpHeat = 0
    private var heatRewardMultiplier: Double { 1.0 + 0.15 * Double(min(3, corpHeat)) }
    /// Scorecard stats.
    @State private var perfectRounds = 0
    @State private var hpAtWaveStart = 14
    @State private var maxComboRun = 0
    @State private var scorecard: [(String, String)] = []
    @State private var walletLine = ""
    /// GRAB — beats block, loses to active attacks. Cooldown-gated.
    @State private var throwCD: Double = 0
    /// HP patched up during the last round break (shown on the VS card).
    @State private var healedLastBreak = 0

    private static func buildLoadout() -> BrawlLoadout {
        var l = BrawlLoadout()
        guard let raze = RosterStore.shared.loadCanonical().first(where: { $0.name == "Raze" }) else { return l }
        let hpBonus = min(4, raze.cyberSoak + max(0, raze.attributes.bod - 5))
        if hpBonus > 0 {
            l.bonusHP = hpBonus
            l.briefingLines.append(("CHROME + MUSCLE", "+\(hpBonus) HP — BOD \(raze.attributes.bod), soak \(raze.cyberSoak)"))
        }
        if let w = raze.equippedWeapon, w.type == .blade, w.damage >= 8 {
            l.heavyBonus = 1
            l.briefingLines.append((w.name.uppercased(), "HEAVY strikes hit +1 harder"))
        }
        return l
    }

    private let ticker = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    private var currentEnemy: WaveEnemy { WaveEnemy.allCases[min(waveIndex, 4)] }
    private var profile: EnemyProfile { enemyProfile(for: currentEnemy, vargasPhase: vargasPhase) }
    private var enemyBase: String { currentEnemy.rawValue }

    // MARK: Body (landscape wrapper)

    var body: some View {
        GeometryReader { geo in
            // Logical landscape canvas: swap the portrait dimensions.
            let W = geo.size.height
            let H = geo.size.width
            game(W: W, H: H)
                .frame(width: W, height: H)
                .rotationEffect(.degrees(90))
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                .onAppear {
                    canvasW = W
                    showTurnPrompt = true
                    setupWave(initial: true)
                }
        }
        .ignoresSafeArea()
        .onReceive(ticker) { _ in tick() }
        .onChange(of: razeFrameName) { _, n in razeImg = BasementBrawlSpriteCache.shared.image(named: n) }
        .onChange(of: enemyFrameName) { _, n in enemyImg = BasementBrawlSpriteCache.shared.image(named: n) }
    }

    @ViewBuilder
    private func game(W: CGFloat, H: CGFloat) -> some View {
        ZStack {
            ZStack {
                // Oversized so the background can be panned without exposing
                // edges. Pit: shift the ring right. Office: shift right + up so
                // the fighters stand on the floor, not above it.
                (currentEnemy == .vargas ? Image("m4_5_office") : Image("m4_5_pit"))
                    .resizable().scaledToFill()
                    .frame(width: W * 1.34, height: H * 1.34)
                    .offset(x: W * 0.14 + shake,
                            y: (currentEnemy == .vargas ? -H * 0.13 : 0) + shake * 0.4)
            }
            .frame(width: W, height: H)
            .clipped()
            .overlay(Color.black.opacity(0.34))

            fightersLayer(W: W, H: H)
            hudLayer(W: W, H: H)
            controlsLayer(W: W, H: H)
            overlayLayer(W: W, H: H)
        }
        .frame(width: W, height: H)
    }

    // MARK: Fighters

    /// Per-fighter render height relative to Raze (1.0). Nobody is smaller
    /// than Raze; the Slugger is the biggest fighter in the game.
    private var enemyHeightScale: CGFloat {
        switch currentEnemy {
        case .slugger:   return 1.28   // THE big one — largest fighter
        case .brawler:   return 1.10   // beefy pit fighter, bigger than Raze
        case .vargas:    return 1.08   // boss — a touch bigger than Raze, NOT the biggest
        case .razorgirl: return 1.0    // lithe, but never smaller than Raze
        case .bodyguard: return 1.0
        }
    }

    @ViewBuilder
    private func fightersLayer(W: CGFloat, H: CGFloat) -> some View {
        let groundY = H * groundYFrac
        let baseH = H * 0.54                 // Raze's height (~10% smaller for portrait fit)
        let enemyH = baseH * enemyHeightScale
        ZStack {
            fighterSprite(img: razeImg, f: player, base: "raze_right", groundY: groundY, figH: baseH, W: W)
            fighterSprite(img: enemyImg, f: enemy, base: enemyBase, groundY: groundY, figH: enemyH, W: W)
            // Attack TELEGRAPH — during the enemy's wind-up, float a tell above
            // its head showing the incoming attack HEIGHT, so blocking / ducking
            // / parrying is a read rather than a guess.
            if enemy.phase == .windup, enemy.attack != nil, enemy.hp > 0 {
                telegraphBadge(height: enemy.height, heavy: enemy.attack == .heavy || enemy.special)
                    .scaleEffect(1 + CGFloat(sin(clock * 14)) * 0.10)
                    .position(x: enemy.x, y: groundY - enemyH * 1.02 + enemy.jumpY)
            }
            // Blood-splatter impact bursts at the struck fighter's torso —
            // drawn outside the sprite's facing-mirror so direction is correct.
            if player.hitSplat > 0 {
                hitSplatView(player, figH: baseH)
                    .position(x: player.x, y: groundY - baseH * 0.55 + player.jumpY)
            }
            if enemy.hitSplat > 0 {
                hitSplatView(enemy, figH: enemyH)
                    .position(x: enemy.x, y: groundY - enemyH * 0.55 + enemy.jumpY)
            }
        }
        .offset(x: shake, y: 0)
    }

    /// A quick red impact burst — central flash + droplets flung in the
    /// direction the blow landed. Fades over the fighter's hitSplat timer.
    @ViewBuilder
    private func hitSplatView(_ f: FighterState, figH: CGFloat) -> some View {
        let p = min(1.0, max(0, f.hitSplat / 0.4))   // 1 at impact → 0
        let grow = 1.0 - p
        ZStack {
            Circle().fill(Color(hex: "FF2A2A").opacity(0.55 * p))
                .frame(width: figH * 0.24, height: figH * 0.24)
                .blur(radius: 3)
            ForEach(0..<8, id: \.self) { i in
                let ang = Double(i) / 8.0 * 2 * .pi + Double(i) * 0.6
                let dist = figH * (0.08 + 0.26 * grow)
                Circle()
                    .fill(Color(hex: i % 2 == 0 ? "C20E1C" : "FF3A3A").opacity(0.9 * p))
                    .frame(width: figH * 0.055, height: figH * 0.055)
                    .offset(x: CGFloat(cos(ang)) * dist + figH * 0.10 * f.splatDir,
                            y: CGFloat(sin(ang)) * dist)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func fighterSprite(img: UIImage?, f: FighterState, base: String, groundY: CGFloat, figH: CGFloat, W: CGFloat) -> some View {
        let crouchDrop = f.crouching && f.phase == .none ? figH * 0.16 : 0
        // The defeated "_down_0" art fills its canvas larger than the idle pose,
        // so at full figH it visibly POPS bigger the instant the fighter drops.
        // Render the down pose a touch smaller; height drives the ground anchor
        // below so it rests on the floor rather than floating at full height.
        // The defeated "_down_0" art is a wide KNEELING pose that fills far more
        // of its canvas (~90% width vs the standing idle's ~55%), so at the same
        // fitted height it reads much bulkier. Shrink it to ~0.65 so the downed
        // figure matches the live sprite's footprint instead of ballooning.
        let isDown = f.hp <= 0
        let h = isDown ? figH * 0.65 : figH
        Group {
            if let img {
                Image(uiImage: img).resizable().scaledToFit().frame(height: h)
            } else {
                Image(currentEnemy == .vargas && base == enemyBase ? "m4_5_office" : "m4_5_pit")
                    .resizable().scaledToFit().frame(height: h).opacity(0.001)
            }
        }
        .scaleEffect(x: f.facing, y: 1)
        .rotationEffect(.degrees(Self.swingTilt(f) * Double(f.facing)),
                        anchor: .bottom)
        .modifier(EnemyHitFlash(active: f.hitFlash > 0))
        .position(x: f.x + Self.swingLunge(f, figH: h) * f.facing,
                  y: groundY - h / 2 + (isDown ? 0 : f.jumpY + crouchDrop))
    }

    /// Forward/back displacement across an attack. Swapping poses alone read as
    /// a flicker rather than a strike (playtest 2026-07-25: "some of the attacks
    /// don't really show a definitive swing"), because the ACTIVE beat is only
    /// 0.10–0.12s. Coiling BACK on the wind-up and driving THROUGH on the strike
    /// gives the eye the travel it needs to register a swing, without touching
    /// the hit windows that drive the fight's timing.
    private static func swingLunge(_ f: FighterState, figH: CGFloat) -> CGFloat {
        guard f.hp > 0, let atk = f.attack else { return 0 }
        let heavy = atk == .heavy || f.special
        switch f.phase {
        case .windup:  return figH * (heavy ? -0.085 : -0.035)   // coil back
        case .active:  return figH * (heavy ?  0.150 :  0.080)   // drive through
        case .recover: return figH * (heavy ?  0.055 :  0.028)   // settle
        default:       return 0
        }
    }

    /// Body tilt that sells the weight of the blow — a heavy leans hard into it,
    /// a jab barely rocks. Degrees, applied in the direction the fighter faces.
    private static func swingTilt(_ f: FighterState) -> Double {
        guard f.hp > 0, let atk = f.attack else { return 0 }
        let heavy = atk == .heavy || f.special
        switch f.phase {
        case .windup:  return heavy ? -7.0 : -2.5
        case .active:  return heavy ? 10.0 :  4.5
        case .recover: return heavy ?  3.5 :  1.5
        default:       return 0
        }
    }

    /// Incoming-attack tell shown above the enemy during wind-up. Colour + arrow
    /// encode how to defend: ▲ HIGH = duck/crouch, ▼ LOW = stand-block (don't
    /// crouch), ● MID = block. Heavy attacks render bigger/brighter.
    @ViewBuilder
    private func telegraphBadge(height: AttackHeight, heavy: Bool) -> some View {
        let info: (icon: String, label: String, hex: String) = {
            switch height {
            case .overhead: return ("▲", "HIGH", "FF3344")
            case .low:      return ("▼", "LOW",  "FFCC00")
            case .mid:      return ("●", "MID",  "FF8800")
            }
        }()
        HStack(spacing: 3) {
            Text(info.icon)
            Text(info.label)
        }
        .font(.system(size: heavy ? 13 : 11, weight: .black, design: .monospaced))
        .foregroundColor(Color(hex: info.hex))
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(Color.black.opacity(0.72)))
        .overlay(Capsule().stroke(Color(hex: info.hex), lineWidth: 1.5))
        .scaleEffect(heavy ? 1.12 : 1.0)
        .shadow(color: Color(hex: info.hex), radius: 5)
        .allowsHitTesting(false)
    }

    // MARK: HUD

    @ViewBuilder
    private func hudLayer(W: CGFloat, H: CGFloat) -> some View {
        VStack {
            HStack(alignment: .top, spacing: 12) {
                healthBar(name: "RAZE", hp: player.hp, maxHP: player.maxHP, tint: "00FF88", align: .leading)
                VStack(spacing: 2) {
                    Text("\(waveIndex + 1)/5").font(.system(size: 13, weight: .black, design: .monospaced))
                        .foregroundColor(.white.opacity(0.8))
                    if comboCount >= 2 {
                        Text("\(comboCount) HIT").font(.system(size: 12, weight: .black, design: .monospaced))
                            .foregroundColor(Color(hex: "FFE044"))
                    }
                }
                healthBar(name: profile.label, hp: enemy.hp, maxHP: enemy.maxHP, tint: "FF3344", align: .trailing)
            }
            .padding(.horizontal, 18).padding(.top, 14)
            HStack(spacing: 6) {
                Text("SUPER").font(.system(size: 8, weight: .black, design: .monospaced))
                    .foregroundColor(Color(hex: "FFE044").opacity(0.85))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.6)).frame(width: 170, height: 7)
                    Capsule().fill(Color(hex: meter >= 1 ? "FFFFFF" : "FFE044"))
                        .frame(width: 170 * CGFloat(min(1, meter)), height: 7)
                }
                .overlay(Capsule().stroke(Color(hex: "FFE044").opacity(0.7), lineWidth: 1))
                Spacer()
            }
            .padding(.horizontal, 18).padding(.top, 6)
            Spacer()
        }
    }

    @ViewBuilder
    private func healthBar(name: String, hp: Int, maxHP: Int, tint: String, align: HorizontalAlignment) -> some View {
        let pct = maxHP > 0 ? max(0, min(1, CGFloat(hp) / CGFloat(maxHP))) : 0
        VStack(alignment: align, spacing: 3) {
            Text(name).font(.system(size: 9, weight: .black, design: .monospaced)).tracking(1)
                .foregroundColor(.white.opacity(0.75))
            ZStack(alignment: align == .leading ? .leading : .trailing) {
                RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.7)).frame(height: 12)
                RoundedRectangle(cornerRadius: 3).fill(Color(hex: tint)).frame(height: 12)
                    .scaleEffect(x: pct, anchor: align == .leading ? .leading : .trailing)
            }
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color(hex: tint).opacity(0.8), lineWidth: 1))
        }
        .frame(maxWidth: .infinity, alignment: align == .leading ? .leading : .trailing)
    }

    // MARK: Controls

    @ViewBuilder
    private func controlsLayer(W: CGFloat, H: CGFloat) -> some View {
        HStack(spacing: 0) {
            // LEFT: movement stick zone
            Color.white.opacity(0.001)
                .frame(width: W * 0.5)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            stickActive = true
                            stickDX = v.translation.width
                            stickDY = v.translation.height
                        }
                        .onEnded { _ in
                            stickActive = false; stickDX = 0; stickDY = 0; jumpArmed = true
                        }
                )
                .overlay(alignment: .bottomLeading) {
                    Text("◄ BACK = BLOCK   ▼ DUCK HIGH   ▲ JUMP")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.35))
                        .padding(14)
                }
            // RIGHT: attack buttons
            ZStack {
                Color.clear
                VStack(alignment: .trailing, spacing: 12) {
                    if meter >= 1.0 {
                        Button(action: trySuper) {
                            Text("SUPER")
                                .font(.system(size: 13, weight: .black, design: .monospaced)).tracking(2)
                                .foregroundColor(.black)
                                .frame(width: 124, height: 40)
                                .background(Capsule().fill(Color(hex: "FFE044")))
                                .overlay(Capsule().stroke(.white, lineWidth: 2))
                                .shadow(color: Color(hex: "FFE044"), radius: 10)
                        }.buttonStyle(.plain)
                    }
                    HStack(spacing: 9) {
                        attackButton("DASH", player.dashCD > 0 ? "555555" : "FFE044") { tryDash() }
                        attackButton("PARRY", player.parryCD > 0 ? "555555" : "00FF88") { tryParry() }
                        attackButton("GRAB", throwCD > 0 ? "555555" : "FF00AA") { tryThrow() }
                        attackButton("LIGHT", "00DDFF") { tryAttack(.light) }
                        attackButton("HEAVY", "FF6633") { tryAttack(.heavy) }
                        attackButton("SP", specialCD > 0 ? "555555" : "AA66FF") { trySpecial() }
                    }
                }
                .padding(.trailing, 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            .frame(width: W * 0.5)
        }
    }

    @ViewBuilder
    private func attackButton(_ label: String, _ hex: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .black, design: .monospaced)).tracking(0.5)
                .foregroundColor(.white)
                .frame(width: 62, height: 62)
                .background(Circle().fill(Color(hex: hex).opacity(0.28)))
                .overlay(Circle().stroke(Color(hex: hex), lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    // MARK: Overlays

    @ViewBuilder
    private func overlayLayer(W: CGFloat, H: CGFloat) -> some View {
        if flashAlpha > 0.01 {
            Rectangle().fill(Color(hex: fxColor)).opacity(flashAlpha * 0.55)
                .blendMode(.plusLighter).allowsHitTesting(false)
        }
        if roundIntro > 0 {
            // Full-screen catcher while the card waits, so a tap anywhere rolls
            // into the bout and no stray tap leaks to the fight controls behind.
            if awaitingFightTap {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { beginFightFromCard() }
            }
            if roundIntro > 0.7 {
                // Fight-night VS card — names the bout, shows the patch-up.
                VStack(spacing: 4) {
                    Text("RAZE")
                        .font(.system(size: 22, weight: .black, design: .monospaced)).tracking(4)
                        .foregroundColor(Color(hex: "00DDFF"))
                    Text("— VS —")
                        .font(.system(size: 11, weight: .black, design: .monospaced)).tracking(3)
                        .foregroundColor(.white.opacity(0.6))
                    Text(currentEnemy == .vargas ? "★ \(profile.label) ★" : profile.label)
                        .font(.system(size: 26, weight: .black, design: .monospaced)).tracking(3)
                        .foregroundColor(Color(hex: "FFC844"))
                    if waveIndex > 0 {
                        Text("ROUND \(waveIndex + 1) OF 5")
                            .font(.system(size: 10, weight: .black, design: .monospaced)).tracking(2)
                            .foregroundColor(.white.opacity(0.5))
                    }
                    if healedLastBreak > 0 {
                        Text("PATCHED UP  +\(healedLastBreak) HP")
                            .font(.system(size: 11, weight: .black, design: .monospaced)).tracking(1)
                            .foregroundColor(Color(hex: "00FF88"))
                    }
                    if awaitingFightTap {
                        Text("TAP TO FIGHT")
                            .font(.system(size: 11, weight: .black, design: .monospaced)).tracking(3)
                            .foregroundColor(Color(hex: "00FF88"))
                            .padding(.top, 6)
                            .opacity(0.55 + 0.45 * abs(sin(clock * 3)))
                    }
                }
                .padding(.horizontal, 26).padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.72))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: "FFC844").opacity(0.6), lineWidth: 1.5)))
                .shadow(color: .black, radius: 8)
            } else {
                Text("FIGHT!")
                    .font(.system(size: 46, weight: .black, design: .monospaced)).tracking(3)
                    .foregroundColor(Color(hex: "00FF88"))
                    .shadow(color: .black, radius: 8)
            }
        }
        if bannerHold > 0 {
            VStack {
                Spacer().frame(height: H * 0.30)
                Text(bannerText)
                    .font(.system(size: 22, weight: .black, design: .monospaced)).tracking(2)
                    .foregroundColor(Color(hex: "FFE044")).shadow(color: .black, radius: 6)
                    .opacity(min(1, bannerHold * 1.5))
                Spacer()
            }
        }
        if gameOver {
            VStack(spacing: 14) {
                Text(didWin ? "FLAWLESS — FILE SECURED" : "YOU'RE DOWN")
                    .font(.system(size: 26, weight: .black, design: .monospaced)).tracking(2)
                    .foregroundColor(didWin ? Color(hex: "00FF88") : Color(hex: "FF3344"))
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
                            .font(.system(size: 12, weight: .black, design: .monospaced)).tracking(1)
                            .foregroundColor(didWin ? Color(hex: "00FF88") : Color(hex: "FF3344"))
                            .padding(.top, 5)
                    }
                    .frame(width: 280)
                }
                Button(action: exit) {
                    Text("CONTINUE").font(.system(size: 14, weight: .black, design: .monospaced)).tracking(2)
                        .foregroundColor(.white).padding(.horizontal, 26).padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 6).stroke(Color.white, lineWidth: 1.5))
                }.buttonStyle(.plain)
            }
            .padding(28)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.85)))
        }
        if showTurnPrompt { turnPromptCard }
    }

    private var turnPromptCard: some View {
        ZStack {
            Color.black.opacity(0.94).ignoresSafeArea().contentShape(Rectangle())
            VStack(spacing: 11) {
                Text("↻  TURN YOUR PHONE SIDEWAYS")
                    .font(.system(size: 15, weight: .black, design: .monospaced)).tracking(2)
                    .foregroundColor(Color(hex: "00FFCC")).multilineTextAlignment(.center)
                Text("HOW TO FIGHT")
                    .font(.system(size: 11, weight: .black, design: .monospaced)).tracking(3)
                    .foregroundColor(.white.opacity(0.7))
                VStack(alignment: .leading, spacing: 6) {
                    howToRow("LEFT", "► move in   ◄ hold back = BLOCK   ▼ crouch = DUCK   ▲ jump")
                    howToRow("RIGHT", "LIGHT = MID jab   HEAVY = HIGH swing   SP   PARRY")
                    howToRow("PARRY", "tap PARRY the instant a hit lands → deflect + free COUNTER")
                    howToRow("TELLS", "▲ HIGH = duck   ▼ LOW = stand-block   ● MID = block")
                    howToRow("GRAB", "beats BLOCK · loses to attacks · short range")
                    howToRow("SUPER", "gold gauge fills as you fight (parries fill it fast)")
                    howToRow("GOAL", "beat all 5 — Vargas is the boss")
                    ForEach(loadout.briefingLines.indices, id: \.self) { i in
                        howToRow(loadout.briefingLines[i].0, loadout.briefingLines[i].1)
                    }
                    if corpHeat > 0 {
                        howToRow("HEAT \(min(3, corpHeat))", String(format: "tougher fighters · purse pays ×%.2f", heatRewardMultiplier))
                    }
                }
                .padding(13)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.5))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: "00FFCC").opacity(0.4), lineWidth: 1)))
                Button(action: { showTurnPrompt = false; HapticsManager.shared.buttonTap() }) {
                    Text("TAP TO BEGIN")
                        .font(.system(size: 15, weight: .black, design: .monospaced)).tracking(2)
                        .foregroundColor(.black).padding(.horizontal, 34).padding(.vertical, 11)
                        .background(Capsule().fill(Color(hex: "00FFCC")))
                }.buttonStyle(.plain)
            }.padding(20)
        }
    }

    private func howToRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(k).font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundColor(Color(hex: "FFC844")).frame(width: 70, alignment: .leading)
            Text(v).font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))
        }
    }

    // MARK: - Wave setup

    private func setupWave(initial: Bool) {
        let W = canvasW
        let p = enemyProfile(for: currentEnemy, vargasPhase: vargasPhase)
        if initial {
            loadout = BasementBrawlScene.buildLoadout()
            corpHeat = MissionStatsStore.shared.loadFactionAttention()[.corp] ?? 0
            perfectRounds = 0; maxComboRun = 0
            scorecard = []; walletLine = ""; healedLastBreak = 0
            let hp = playerMaxHP + loadout.bonusHP
            player = FighterState(x: W * 0.40, hp: hp, maxHP: hp)
        }
        else { player.x = W * 0.40; player.jumpY = 0; player.jumpVel = 0; player.phase = .none
               player.hitstun = 0; player.blockstun = 0; player.crouching = false }
        // Corp heat toughens every non-boss fighter (+1 HP per point, cap 3) —
        // the purse pays proportionally more (heatRewardMultiplier at the end).
        let heatHP = currentEnemy == .vargas ? 0 : min(3, corpHeat)
        enemy = FighterState(x: W * 0.74, hp: p.maxHP + heatHP, maxHP: p.maxHP + heatHP, facing: 1)
        hpAtWaveStart = player.hp
        roundIntro = initial ? 1.0 : 1.4
        // Park on the VS card until the player taps in.
        awaitingFightTap = true
        fightCardHold = 0
        comboCount = 0
        enemySuperCD = 5.0
        koActive = false
        koTimer = 0
        // Dramatic round break — name the challenger so the gauntlet reads as
        // escalating bouts, with a FINAL ROUND callout for Vargas. (Skipped on
        // the very first wave, which has its own intro card.)
        if !initial {
            if currentEnemy == .vargas {
                showBanner("★ FINAL ROUND ★  \(currentEnemy.label)")
            } else {
                showBanner("ROUND \(waveIndex + 1)  ·  \(currentEnemy.label)")
            }
            SFXManager.shared.play("intimidate", volume: 0.6)
        }
    }

    // MARK: - Input

    private func tryAttack(_ atk: PlayerAttack) {
        guard !gameOver, roundIntro <= 0, player.hitstun <= 0, player.blockstun <= 0 else { return }
        // Allow cancel during recovery (light → heavy), else require neutral.
        if player.phase == .windup || player.phase == .active { return }
        if player.phase == .recover && atk == .light { return }   // can't cancel into light
        player.attack = atk
        player.phase = .windup
        player.phaseTimer = atk.windup
        player.hasHit = false
        player.height = player.jumpY < -4 ? .overhead : (player.crouching ? .low : .mid)
        HapticsManager.shared.combatInput()
    }

    /// PARRY — opens a tight ~0.2s deflect window. If an enemy attack lands
    /// during it, `resolveHits` negates the hit and counter-stuns them. Whiffing
    /// costs a short cooldown, so it's a read, not a spammable shield.
    private func tryParry() {
        guard !gameOver, roundIntro <= 0, superActive <= 0,
              player.hitstun <= 0, player.blockstun <= 0,
              player.phase == .none, player.parryCD <= 0 else { return }
        player.parryTimer = 0.20
        player.parryCD = 0.55
        SFXManager.shared.play("blitz", volume: 0.4)   // brief "ready" cue
        HapticsManager.shared.combatInput()
    }

    /// DASH — a quick step toward the enemy with ~0.2s of i-frames + the
    /// `dash_0` lunge pose. The footsies tool: read an enemy's `windup_0` tell,
    /// dash through the strike, and punish the recovery. Cooldown-gated.
    /// GRAB — the anti-turtle option: beats BLOCK outright, loses to an
    /// enemy's ACTIVE attack frames, and whiffs (punishably) at range.
    private func tryThrow() {
        guard !gameOver, !showTurnPrompt, roundIntro <= 0, !koActive,
              throwCD <= 0, !player.busy, player.jumpY >= -4 else { return }
        throwCD = 1.1
        HapticsManager.shared.combatInput()
        let dx = abs(player.x - enemy.x)
        let range = PlayerAttack.light.reach * canvasW * 0.85
        if dx <= range, enemy.jumpY >= -4, enemy.hp > 0, enemy.phase != .active {
            enemy.blocking = false
            enemyBlockHold = 0
            var dmg = 2 + loadout.heavyBonus
            if profile.armorBreakLevel >= 1 { dmg = max(1, dmg - 1) }  // chrome resists grapples a bit
            enemy.hp = max(0, enemy.hp - dmg)
            enemy.hitstun = 0.55
            enemy.hitFlash = 0.2
            enemy.hitSplat = 0.35
            enemy.splatDir = player.facing
            enemy.x += 46 * player.facing
            meter = min(1.0, meter + 0.10)
            hitStop = 0.08; shake = 9
            SFXManager.shared.play("melee_hit", volume: 0.8)
            HapticsManager.shared.attackHit()
            showBanner("THROWN!")
        } else {
            // Whiffed grab — locked into recovery, punishable.
            player.attack = .light
            player.phase = .recover
            player.phaseTimer = 0.45
            SFXManager.shared.play("miss_whoosh", volume: 0.5)
        }
    }

    private func tryDash() {
        guard !gameOver, roundIntro <= 0, superActive <= 0,
              player.hitstun <= 0, player.blockstun <= 0,
              player.phase == .none, player.dashCD <= 0 else { return }
        player.dashTimer = 0.20
        player.dashCD = 0.65
        player.dashDir = player.facing      // dash in to close + punish
        SFXManager.shared.play("bike_swerve", volume: 0.5)
        HapticsManager.shared.combatInput()
    }

    private func trySpecial() {
        guard !gameOver, roundIntro <= 0, superActive <= 0, !player.busy, specialCD <= 0 else { return }
        player.attack = .heavy
        player.special = true
        player.phase = .windup
        player.phaseTimer = PlayerAttack.heavy.windup * 0.85
        player.hasHit = false
        player.height = player.jumpY < -4 ? .overhead : (player.crouching ? .low : .mid)
        // Small forward lunge into the special.
        let toward: CGFloat = player.x <= enemy.x ? 1 : -1
        player.x += canvasW * 0.05 * toward
        specialCD = 1.8
        flashAlpha = 0.5; fxColor = "AA66FF"
        HapticsManager.shared.combatInput()
    }

    private func trySuper() {
        guard !gameOver, roundIntro <= 0, superActive <= 0, meter >= 1.0, !player.busy else { return }
        meter = 0
        superActive = 1.5
        superHitDone = false
        flashAlpha = 1.0; fxColor = "FFE044"
        hitStop = 0.22
        // Dash into the target for the finisher.
        let toward: CGFloat = player.x <= enemy.x ? 1 : -1
        player.x = enemy.x - toward * canvasW * minSeparationFrac
        player.facing = toward
        player.attack = .heavy; player.special = true
        player.phase = .active; player.phaseTimer = 1.5
        showBanner("FINISHER!")
        HapticsManager.shared.victory()
    }

    // MARK: - Tick

    private func tick() {
        let dt = 1.0 / 60.0
        // Bullet-time: while `slowMo` is active, gameplay motion advances at a
        // fraction of real time for a dramatic finisher. Cosmetic timers
        // (clock/shake/flash/banner) + the slowMo countdown stay on real dt.
        if slowMo > 0 { slowMo -= dt }
        let gdt = slowMo > 0 ? dt * 0.30 : dt
        clock += dt
        if turnHintHold > 0 { turnHintHold -= dt }
        if bannerHold > 0 { bannerHold -= dt }
        if shake > 0 { shake = max(0, shake - dt * 60) }
        if flashAlpha > 0 { flashAlpha = max(0, flashAlpha - dt * 3.0) }
        if specialCD > 0 { specialCD -= dt }
        if throwCD > 0 { throwCD -= dt }
        if enemySuperCD > 0 { enemySuperCD -= dt }
        if hitStop > 0 { hitStop -= dt; return }   // freeze frame
        guard !gameOver else { return }
        guard !showTurnPrompt else { return }      // intro card up — freeze the fight
        // Super finisher — cinematic freeze + one scripted heavy hit.
        if superActive > 0 {
            superActive -= dt
            if !superHitDone && superActive <= 0.9 {
                superHitDone = true
                let dmg = max(6, enemy.maxHP / 2)
                enemy.hp = max(0, enemy.hp - dmg)
                enemy.hitFlash = 0.5; enemy.hitstun = 0.7
                enemy.hitSplat = 0.5; enemy.splatDir = player.facing
                enemy.x += canvasW * 0.04 * player.facing
                shake = 18; flashAlpha = max(flashAlpha, 0.5)
                SFXManager.shared.play("melee_hit", volume: 0.9)
                HapticsManager.shared.attackHit()
            }
            if superActive <= 0 { player.phase = .none; player.attack = nil; player.special = false }
            return
        }
        if roundIntro > 0 {
            // The VS card WAITS for the player. It used to be on screen for
            // 0.3–0.7s, which was not long enough to read who you were about to
            // fight or that you had been patched up (playtest 2026-07-25:
            // "fight cards only pop up too quick"). Holding here parks the
            // countdown on the card until they tap in.
            if awaitingFightTap {
                fightCardHold += dt
                // Safety net, same reasoning as the boss-intro card: a missed
                // tap must never strand the brawl on a static screen.
                if fightCardHold > Self.fightCardAutoAdvance { beginFightFromCard() }
                return
            }
            roundIntro -= dt
            return
        }

        // KO beat — when an enemy is downed, hold on the fall before the next
        // challenger walks in, instead of cutting instantly to the next fight.
        if koActive {
            koTimer -= dt
            advanceFighter(&player, dt: gdt)   // let the fall / victory idle animate (slo-mo)
            advanceFighter(&enemy, dt: gdt)
            if koTimer <= 0 { koActive = false; performAdvance() }
            return
        }

        let W = canvasW
        applyPlayerIntent(dt: gdt, W: W)
        advanceFighter(&player, dt: gdt)
        runEnemyAI(dt: gdt, W: W)
        advanceFighter(&enemy, dt: gdt)

        // Face each other. Raze's art faces RIGHT (no flip when the enemy is to
        // her right); the enemy art faces LEFT (no flip when the player is to
        // its left — the normal case). Only mirror when they cross over.
        player.facing = player.x <= enemy.x ? 1 : -1
        enemy.facing  = enemy.x  >= player.x ? 1 : -1

        // Hit resolution.
        resolveHits(attacker: &player, defender: &enemy, W: W, playerIsAttacker: true)
        resolveHits(attacker: &enemy, defender: &player, W: W, playerIsAttacker: false)

        if comboTimer > 0 { comboTimer -= dt; if comboTimer <= 0 { comboCount = 0 } }

        // Separation + bounds.
        keepApart(W: W)
        clampBounds(W: W)

        checkOutcomes()
    }

    private func applyPlayerIntent(dt: Double, W: CGFloat) {
        let dead: CGFloat = 14
        let grounded = player.jumpY >= -0.1
        // Reset transient intents.
        player.moving = false
        player.blocking = false
        if player.busy || player.phase != .none {
            player.crouching = player.crouching && grounded && stickActive && stickDY > dead
            return
        }
        guard stickActive, grounded else { player.crouching = false; return }
        // Jump.
        if stickDY < -34 && jumpArmed {
            player.jumpVel = jumpVel0
            // Jump ARC: carry the stick's horizontal direction into the air so
            // you can leap forward (toward the enemy / "up and to the right")
            // or back. Neutral stick = straight up.
            if stickDX > dead       { player.airVelX =  walkSpeed * 0.95 }   // forward
            else if stickDX < -dead { player.airVelX = -walkSpeed * 0.95 }   // back
            else                    { player.airVelX = 0 }
            jumpArmed = false
            player.crouching = false
            HapticsManager.shared.selectionChanged()
            return
        }
        // Crouch.
        player.crouching = stickDY > dead
        // Horizontal: toward enemy = forward; away = back (+block).
        let towardEnemy: CGFloat = player.x <= enemy.x ? 1 : -1
        if abs(stickDX) > dead && !player.crouching {
            let dir: CGFloat = stickDX > 0 ? 1 : -1
            if dir == towardEnemy {
                player.x += walkSpeed * CGFloat(dt) * dir
                player.moving = true
                player.walkClock += dt
            } else {
                // holding back → walk out + block
                player.x += walkSpeed * 0.8 * CGFloat(dt) * dir
                player.moving = true
                player.walkClock += dt
                player.blocking = true
            }
        } else if abs(stickDX) > dead && player.crouching {
            // crouch-block if holding back while crouching
            let dir: CGFloat = stickDX > 0 ? 1 : -1
            if dir != towardEnemy { player.blocking = true }
        }
    }

    private func advanceFighter(_ f: inout FighterState, dt: Double) {
        if f.hitFlash > 0 { f.hitFlash -= dt }
        if f.hitSplat > 0 { f.hitSplat -= dt }
        if f.hitstun > 0 { f.hitstun -= dt }
        if f.blockstun > 0 { f.blockstun -= dt }
        if f.parryTimer > 0 { f.parryTimer -= dt }
        if f.parryCD > 0 { f.parryCD -= dt }
        if f.parryFlash > 0 { f.parryFlash -= dt }
        if f.dashCD > 0 { f.dashCD -= dt }
        if f.dashTimer > 0 {
            f.dashTimer -= dt
            f.x += f.dashDir * 460 * CGFloat(dt)   // fast i-frame burst step
        }
        // Jump physics.
        if f.jumpVel != 0 || f.jumpY < 0 {
            f.jumpVel += gravity * CGFloat(dt)
            f.jumpY += f.jumpVel * CGFloat(dt)
            f.x += f.airVelX * CGFloat(dt)          // horizontal jump arc
            if f.jumpY >= 0 { f.jumpY = 0; f.jumpVel = 0; f.airVelX = 0 }
        }
        // Attack phase machine.
        if f.phase != .none {
            f.phaseTimer -= dt
            if f.phaseTimer <= 0 {
                switch f.phase {
                case .windup: f.phase = .active;  f.phaseTimer = (f.attack ?? .light).active
                case .active: f.phase = .recover; f.phaseTimer = (f.attack ?? .light).recover
                case .recover: f.phase = .none; f.attack = nil; f.special = false
                case .none: break
                }
            }
        }
    }

    // MARK: - Enemy AI

    @State private var enemyDecisionCD: Double = 0
    @State private var enemyBlockHold: Double = 0
    @State private var enemySuperCD: Double = 0   // Vargas OVERLOAD cooldown

    private func runEnemyAI(dt: Double, W: CGFloat) {
        enemy.moving = false
        if enemyBlockHold > 0 { enemyBlockHold -= dt }
        enemy.blocking = enemyBlockHold > 0
        if enemy.busy { return }
        if enemyDecisionCD > 0 { enemyDecisionCD -= dt }

        let dx = abs(enemy.x - player.x)
        let reach = PlayerAttack.heavy.reach * W * 0.9
        let towardPlayer: CGFloat = enemy.x > player.x ? -1 : 1

        // Defensive react: if the player is winding/active and close, sometimes block.
        if (player.phase == .windup || player.phase == .active) && dx < reach * 1.2 {
            if enemyBlockHold <= 0 && Double.random(in: 0...1) < profile.blockChance {
                enemyBlockHold = 0.45
                enemy.blocking = true
                return
            }
        }

        if dx > reach {
            // Approach.
            enemy.x += profile.approachSpeed * CGFloat(dt) * towardPlayer
            enemy.moving = true
            enemy.walkClock += dt
        } else if enemyDecisionCD <= 0 {
            // Boss super — Vargas (phase 2+) occasionally charges an OVERLOAD:
            // a big, heavily-telegraphed hit using his super_0/1/2 frames.
            if currentEnemy == .vargas, vargasPhase >= 2, enemySuperCD <= 0, Double.random(in: 0...1) < 0.4 {
                enemy.attack = .heavy
                enemy.special = true
                enemy.phase = .windup
                enemy.phaseTimer = profile.windupTime * 1.7   // long, readable tell
                enemy.hasHit = false
                enemy.height = .overhead   // big telegraphed overhead — duckable
                enemySuperCD = 6.5
                enemyDecisionCD = profile.windupTime * 1.7 + profile.strikeTime + profile.recoverTime + 0.6
                flashAlpha = 0.4; fxColor = "FF3344"
                showBanner("VARGAS — OVERLOAD!")
                SFXManager.shared.play("mainframe_breach", volume: 0.6)
                return
            }
            // In range — attack, with a distinct pattern per archetype so each
            // fight reads differently and demands a different defensive read:
            //   • armored/slugger → slow, heavily-telegraphed HEAVY OVERHEADS
            //     (duck them). Big windup = parry/punish bait.
            //   • combo/razorgirl → fast LIGHT jabs, often LOW (crouch-block).
            //   • ranged/bodyguard → pokes at max range, mostly MID.
            //   • standard/brawler → an even mix.
            let atk: PlayerAttack
            let height: AttackHeight
            var windupMult = 1.0
            switch profile.archetype {
            case .armored:
                atk = .heavy; height = .overhead; windupMult = 1.45   // telegraphed
            case .combo:
                atk = .light; height = Double.random(in: 0...1) < 0.6 ? .low : .mid
                windupMult = 0.8                                       // snappy
            case .ranged:
                atk = Double.random(in: 0...1) < 0.7 ? .light : .heavy
                height = atk == .heavy ? .overhead : .mid
            default:
                atk = Double.random(in: 0...1) < 0.55 ? .light : .heavy
                height = atk == .heavy ? .overhead : (Double.random(in: 0...1) < 0.3 ? .low : .mid)
            }
            enemy.attack = atk
            enemy.phase = .windup
            enemy.phaseTimer = profile.windupTime * windupMult
            enemy.hasHit = false
            enemy.height = height
            enemyDecisionCD = profile.windupTime * windupMult + profile.strikeTime + profile.recoverTime + Double.random(in: 0.1...0.5)
        }
    }

    // MARK: - Hit resolution

    private func resolveHits(attacker: inout FighterState, defender: inout FighterState, W: CGFloat, playerIsAttacker: Bool) {
        guard attacker.phase == .active, !attacker.hasHit, let atk = attacker.attack else { return }
        let dx = abs(attacker.x - defender.x)
        let reach = atk.reach * W
        guard dx <= reach else { return }
        attacker.hasHit = true

        // DASH i-frames — the defender evaded entirely; no damage, no chip.
        if defender.dashTimer > 0 {
            if playerIsAttacker { comboCount = 0 }
            showBanner(playerIsAttacker ? "ENEMY EVADES!" : "DODGE!")
            return
        }

        // PARRY (player only) — a tight-timed deflect beats the block: NO damage,
        // NO chip, and the attacker is frozen in a counter window for a free hit.
        // The skill-reward defensive option.
        if !playerIsAttacker && defender.parryTimer > 0 {
            defender.parryTimer = 0
            defender.parryFlash = 0.35
            attacker.hitstun = 0.75               // counter window — punish it
            attacker.x += atk.pushback * 0.4 * attacker.facing
            meter = min(1.0, meter + 0.30)        // parries charge the SUPER fast
            hitStop = 0.13
            shake = 7
            SFXManager.shared.play("melee_critical", volume: 0.85)
            HapticsManager.shared.attackHit()
            showBanner("PARRY!  COUNTER!")
            return
        }

        // Block check by height.
        let blockOK: Bool = {
            guard defender.blocking else { return false }
            switch attacker.height {
            case .mid:      return true
            case .low:      return defender.crouching
            case .overhead: return !defender.crouching
            }
        }()

        // Crouch ducks HIGH / overhead swings entirely — they whiff overhead,
        // no chip. (Standing block also stops overheads; crouch is the no-chip
        // read against the big telegraphed heavy.)
        if attacker.height == .overhead && defender.crouching {
            showBanner(playerIsAttacker ? "ENEMY DUCKED!" : "DUCKED!")
            if playerIsAttacker { comboCount = 0 }
            return
        }

        // Armor (slugger / vargas overload): only HEAVY damages.
        let enemyIsDefender = playerIsAttacker
        let armored = enemyIsDefender && profile.armorBreakLevel >= 1 && atk == .light

        if blockOK {
            defender.hp = max(0, defender.hp - blockChip)
            defender.blockstun = 0.18
            defender.x += atk.pushback * 0.5 * (attacker.facing)
            SFXManager.shared.play("armor_block", volume: 0.5)
            HapticsManager.shared.combatInput()
            if playerIsAttacker { comboCount = 0 }
        } else if armored {
            defender.hitFlash = 0.12
            SFXManager.shared.play("armor_block", volume: 0.6)
            showBanner("TINK! — HEAVY ONLY")
            if playerIsAttacker { comboCount = 0 }
        } else {
            var dmg = atk.damage
            if playerIsAttacker && atk == .heavy { dmg += loadout.heavyBonus }
            if attacker.special { dmg += 2 }
            defender.hp = max(0, defender.hp - dmg)
            defender.hitstun = atk == .heavy ? 0.42 : 0.24
            defender.hitFlash = 0.20
            defender.hitSplat = atk == .heavy ? 0.4 : 0.3
            defender.splatDir = attacker.facing   // blood flies the way the blow lands
            defender.x += atk.pushback * (attacker.facing)
            hitStop = atk == .heavy ? 0.09 : 0.05
            shake = atk == .heavy ? 10 : 5
            SFXManager.shared.play("melee_hit", volume: 0.7)
            if playerIsAttacker {
                HapticsManager.shared.attackHit()
                comboCount += 1; comboTimer = comboGrace
                meter = min(1.0, meter + 0.14)
                if attacker.special { shake += 4; flashAlpha = max(flashAlpha, 0.4) }
                // Combo callout — escalating juice the longer the string runs.
                maxComboRun = max(maxComboRun, comboCount)
                if comboCount >= 2 {
                    showBanner("\(comboCount)× COMBO!")
                    flashAlpha = max(flashAlpha, Double(min(comboCount, 6)) * 0.06)
                    shake += CGFloat(min(comboCount, 5))
                }
            } else {
                HapticsManager.shared.playerDamaged()
                comboCount = 0
                meter = min(1.0, meter + 0.07)
            }
        }
    }

    // MARK: - Positioning

    private func keepApart(W: CGFloat) {
        let minSep = W * minSeparationFrac
        let dx = enemy.x - player.x
        if abs(dx) < minSep {
            let push = (minSep - abs(dx)) / 2
            let sign: CGFloat = dx >= 0 ? 1 : -1
            player.x -= push * sign
            enemy.x  += push * sign
        }
    }

    private func clampBounds(W: CGFloat) {
        let lo = W * edgePadFrac, hi = W * (1 - edgePadFrac)
        player.x = min(hi, max(lo, player.x))
        enemy.x  = min(hi, max(lo, enemy.x))
    }

    // MARK: - Outcomes

    private func checkOutcomes() {
        if player.hp <= 0 { endGame(win: false); return }
        if enemy.hp <= 0 {
            // Vargas inter-phase: NOT a real defeat — pop straight into the
            // next phase (no KO fall beat).
            if currentEnemy == .vargas && vargasPhase < 3 {
                vargasPhase += 1
                showBanner("VARGAS — PHASE \(vargasPhase)!")
                let p = enemyProfile(for: .vargas, vargasPhase: vargasPhase)
                enemy = FighterState(x: enemy.x, hp: p.maxHP, maxHP: p.maxHP, facing: -1)
                roundIntro = 1.0
                enemyDecisionCD = 0.6
                enemySuperCD = 3.5
                return
            }
            // Real defeat — start the KO fall beat (advance happens when it ends).
            if !koActive { startKO() }
        }
    }

    /// Begin the downed-enemy beat: freeze the fight, let the loser drop, hold
    /// for ~1.7s before the next challenger walks in.
    private func startKO() {
        if player.hp == hpAtWaveStart {
            perfectRounds += 1
            showBanner("PERFECT!")
        }
        koActive = true
        koTimer = 1.7
        enemy.phase = .none
        enemy.attack = nil
        enemy.hitstun = 1.7      // keep it pinned in the down/hit pose
        player.phase = .none
        player.attack = nil
        hitStop = 0.20           // beefier freeze-frame on the finishing blow…
        slowMo = 0.55            // …then a bullet-time beat as the loser drops
        shake = 18
        flashAlpha = max(flashAlpha, 0.5)
        showBanner("DOWN!")
        SFXManager.shared.play("melee_hit", volume: 1.0)
        HapticsManager.shared.enemyKilled()
    }

    /// Fired when the KO beat ends — advance to the next challenger or win.
    private func performAdvance() {
        if waveIndex >= 4 { endGame(win: true); return }
        waveIndex += 1
        // Round-break patch-up: corner crew tapes you up between bouts.
        healedLastBreak = min(3, player.maxHP - player.hp)
        if healedLastBreak > 0 { player.hp += healedLastBreak }
        setupWave(initial: false)
    }

    private func showBanner(_ t: String) { bannerText = t; bannerHold = 1.4 }

    private func endGame(win: Bool) {
        guard !gameOver else { return }
        gameOver = true; didWin = win
        if win {
            HapticsManager.shared.victory()
            SFXManager.shared.play("mission_victory")
            let standingBonus = player.hp * 60
            let perfectBonus = perfectRounds * 150
            let comboBonus = maxComboRun * 20
            let score = 400 + 500 + standingBonus + perfectBonus + comboBonus
            MissionStatsStore.shared.recordVictory(missionId: "Mission004_5", score: score,
                                                   dataAcquired: true, grimoireAcquired: false,
                                                   rewardMultiplier: heatRewardMultiplier)
            scorecard = [
                ("GAUNTLET CLEARED", "900"),
                ("LEFT STANDING ×\(player.hp) HP", "\(standingBonus)"),
                ("PERFECT ROUNDS ×\(perfectRounds)", "\(perfectBonus)"),
                ("BEST COMBO ×\(maxComboRun)", "\(comboBonus)"),
                ("SCORE — RANK \(MissionStatsStore.rank(forScore: score))", "\(score)"),
            ]
            if corpHeat > 0 {
                scorecard.append(("CORP HEAT ×\(min(3, corpHeat))",
                                  String(format: "PAY ×%.2f", heatRewardMultiplier)))
            }
            walletLine = "¥\(MissionStatsStore.shared.lastWalletCredit) CREDITED"
        } else {
            HapticsManager.shared.defeat()
            SFXManager.shared.play("mission_defeat")
            scorecard = [
                ("ROUNDS CLEARED", "\(waveIndex)"),
                ("BEST COMBO", "\(maxComboRun)"),
            ]
            walletLine = "NO PURSE — CARRIED OUT"
        }
    }

    private func exit() {
        HapticsManager.shared.buttonTap()
        _ = manager.transition(to: .endBrawl(won: didWin))
    }

    // MARK: - Sprite frame selection

    private var razeFrameName: String { frameName(base: "raze_right", f: player) }
    private var enemyFrameName: String { frameName(base: enemyBase, f: enemy) }

    private func frameName(base: String, f: FighterState) -> String {
        func fa(_ c: [String]) -> String {
            for n in c where BasementBrawlSpriteCache.shared.image(named: n) != nil { return n }
            return c.last ?? "\(base)_idle_0"
        }
        if f.hp <= 0 { return fa(["\(base)_down_0", "\(base)_hit_1", "\(base)_idle_0"]) }
        if f.hitstun > 0 || f.hitFlash > 0 { return fa(["\(base)_hit_1", "\(base)_hit_0", "\(base)_idle_0"]) }
        // Dash lunge pose during the i-frame burst.
        if f.dashTimer > 0 { return fa(["\(base)_dash_0", "\(base)_walk_1", "\(base)_idle_0"]) }
        // Parry stance (falls back to the block pose until parry art ships).
        if f.parryTimer > 0 || f.parryFlash > 0 {
            return fa(["\(base)_parry_0", "\(base)_block_0", "\(base)_idle_0"])
        }
        if f.jumpY < -4 {
            // Air attack — show the strike pose, not the neutral jump frame.
            if f.attack != nil, f.phase != .none {
                return fa(["\(base)_jump_1", "\(base)_heavy_1", "\(base)_idle_0"])
            }
            return f.jumpVel < 0 ? fa(["\(base)_jump_0", "\(base)_idle_0"])
                                 : fa(["\(base)_jump_1", "\(base)_jump_0", "\(base)_idle_0"])
        }
        if let atk = f.attack, f.phase != .none {
            let windup = f.phase == .windup
            // Vargas has bespoke frames (phaseN_attack / phase3_charge / super_*)
            // instead of generic light/heavy — map to those so he never goes
            // invisible during an attack.
            if base == "vargas" {
                if f.special {
                    if windup { return fa(["vargas_super_0", "vargas_phase3_charge", "vargas_idle_0"]) }
                    if f.phase == .recover { return fa(["vargas_super_2", "vargas_super_1", "vargas_idle_0"]) }
                    return fa(["vargas_super_1", "vargas_idle_0"])
                }
                if windup { return fa(["vargas_phase\(vargasPhase)_charge", "vargas_phase3_charge", "vargas_phase\(vargasPhase)_attack", "vargas_idle_0"]) }
                return fa(["vargas_phase\(vargasPhase)_attack", "vargas_phase1_attack", "vargas_idle_0"])
            }
            if f.special {
                if windup { return fa(["\(base)_super_0", "\(base)_heavy_0", "\(base)_idle_0"]) }
                if f.phase == .recover {
                    return fa(["\(base)_super_2", "\(base)_super_1", "\(base)_heavy_1", "\(base)_idle_0"])
                }
                return fa(["\(base)_super_1", "\(base)_heavy_1", "\(base)_idle_0"])
            }
            // HEAVY: a dedicated `windup_0` coiled-tell pose during the windup
            // (the big readable telegraph), then the committed `heavy_2` strike
            // on the active/recover beats. Falls back to the old heavy_0/1 art
            // for any fighter without the new frames.
            if atk == .heavy {
                if windup { return fa(["\(base)_windup_0", "\(base)_heavy_0", "\(base)_light_0", "\(base)_idle_0"]) }
                return fa(["\(base)_heavy_2", "\(base)_heavy_1", "\(base)_light_1", "\(base)_idle_0"])
            }
            // LIGHT: fast jab — keep the snappy light_0 tell, land on light_2
            // follow-through (Raze) / light_1.
            if windup { return fa(["\(base)_light_0", "\(base)_windup_0", "\(base)_idle_0"]) }
            return fa(["\(base)_light_2", "\(base)_light_1", "\(base)_idle_0"])
        }
        if f.blocking {
            return f.crouching ? fa(["\(base)_blocklow_0", "\(base)_block_0", "\(base)_idle_0"])
                               : fa(["\(base)_block_0", "\(base)_idle_0"])
        }
        if f.crouching { return fa(["\(base)_crouch_0", "\(base)_idle_0"]) }
        if f.moving {
            // 4-frame walk cycle (was 2) for a smoother stride now that
            // walk_2/walk_3 exist. fa() falls back to the 2-frame set, then
            // idle, for any fighter missing the extra frames (e.g. Vargas).
            let p = Int(f.walkClock * 8) % 4
            return fa(["\(base)_walk_\(p)", "\(base)_walk_\(p % 2)", p % 2 == 0 ? "\(base)_idle_0" : "\(base)_idle_1"])
        }
        let p = Int(clock * 2) % 2
        return fa(["\(base)_idle_\(p)", "\(base)_idle_0"])
    }
}

// MARK: - Sprite cache

final class BasementBrawlSpriteCache {
    static let shared = BasementBrawlSpriteCache()
    private var cache: [String: UIImage] = [:]
    private init() {}
    /// Frames whose art faces the opposite way from the rest of that fighter's
    /// set — mirrored at load so the whole fighter faces one consistent way.
    /// (The bodyguard's pistol-fire frames were drawn facing right; everything
    /// else of his faces left.)
    private static let mirrorFrames: Set<String> = ["bodyguard_heavy_0", "bodyguard_heavy_1"]

    func image(named name: String) -> UIImage? {
        if let cached = cache[name] { return cached }
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let url = resourceURL.appendingPathComponent("Sprites/frames").appendingPathComponent("\(name).png")
        guard let raw = UIImage(contentsOfFile: url.path) else { return nil }
        var img = BasementBrawlSpriteCache.removeBackground(raw) ?? raw
        if BasementBrawlSpriteCache.mirrorFrames.contains(name), let cg = img.cgImage {
            img = UIImage(cgImage: cg, scale: img.scale, orientation: .upMirrored)
        }
        cache[name] = img
        return img
    }

    /// Many generated frames ship with an opaque (white) background — a "white
    /// box" on screen. Flood-fill transparency in from the borders so the box
    /// disappears while preserving interior whites (tank tops, blade glints),
    /// since those aren't connected to the edge. Frames that are already
    /// transparent at the corner are returned unchanged.
    static func removeBackground(_ image: UIImage) -> UIImage? {
        guard let srcCG = image.cgImage else { return nil }
        // Work at a sane resolution (display is ~250pt → ~750px @3x).
        let maxDim = 768
        let ow = srcCG.width, oh = srcCG.height
        let s = min(1.0, Double(maxDim) / Double(max(ow, oh, 1)))
        let w = max(1, Int(Double(ow) * s)), h = max(1, Int(Double(oh) * s))

        var data = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(srcCG, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Already transparent? Leave it alone.
        if data[3] < 16 { return image }

        // Detect background colour(s) by sampling the border. Some art ships
        // with a baked two-tone "transparency" CHECKERBOARD (no real alpha) —
        // the two checker shades can sit >48 apart, so keying on a single
        // corner pixel leaves every other square behind as a boxy halo. We
        // bucket all border pixels and treat the up-to-two most common shades
        // as background, which cleanly strips both solid and checker backings.
        var freq: [Int: (r: Int, g: Int, b: Int, n: Int)] = [:]
        func sample(_ i: Int) {
            let r = Int(data[i]), g = Int(data[i + 1]), b = Int(data[i + 2])
            let key = (r / 24) * 10000 + (g / 24) * 100 + (b / 24)
            if var e = freq[key] { e.n += 1; freq[key] = e }
            else { freq[key] = (r, g, b, 1) }
        }
        for x in 0..<w { sample((x) * 4); sample(((h - 1) * w + x) * 4) }
        for y in 0..<h { sample((y * w) * 4); sample((y * w + (w - 1)) * 4) }
        // Up-to-two dominant border colours that are actually common (a real
        // background fills most of the border; a stray edge pixel won't).
        let borderCount = max(1, 2 * (w + h))
        let bgColors = freq.values
            .filter { $0.n * 6 >= borderCount }          // ≥ ~16% of the border
            .sorted { $0.n > $1.n }
            .prefix(2)
            .map { (r: $0.r, g: $0.g, b: $0.b) }
        // Fallback to the corner pixel if nothing dominated (unusual art).
        let bgList: [(r: Int, g: Int, b: Int)] = bgColors.isEmpty
            ? [(Int(data[0]), Int(data[1]), Int(data[2]))] : Array(bgColors)
        // Hoist the up-to-two background colours into plain Int locals. The hot
        // loops below run per-pixel across ~0.6M pixels × dozens of frames, so
        // they MUST avoid closures / array iteration — in a Debug build that
        // overhead turned a sub-second strip into a ~20s first-load stall.
        let bg0r = bgList[0].r, bg0g = bgList[0].g, bg0b = bgList[0].b
        let has1 = bgList.count > 1
        let bg1r = has1 ? bgList[1].r : 0, bg1g = has1 ? bgList[1].g : 0, bg1b = has1 ? bgList[1].b : 0
        let tol = 48, tol2 = 30
        // Local, non-escaping, capture-only-Ints → compiles to tight inline math.
        func matches(_ i: Int, _ t: Int) -> Bool {
            if data[i + 3] <= 8 { return false }
            let r = Int(data[i]), g = Int(data[i + 1]), b = Int(data[i + 2])
            if abs(r - bg0r) < t && abs(g - bg0g) < t && abs(b - bg0b) < t { return true }
            if has1 && abs(r - bg1r) < t && abs(g - bg1g) < t && abs(b - bg1b) < t { return true }
            return false
        }
        var visited = [Bool](repeating: false, count: w * h)
        var stack = [Int]()
        stack.reserveCapacity(w * h / 3)
        for x in 0..<w { stack.append(x); stack.append((h - 1) * w + x) }
        for y in 0..<h { stack.append(y * w); stack.append(y * w + (w - 1)) }
        while let p = stack.popLast() {
            if visited[p] { continue }
            visited[p] = true
            let i = p * 4
            if !matches(i, tol) { continue }
            data[i] = 0; data[i + 1] = 0; data[i + 2] = 0; data[i + 3] = 0
            let x = p % w, y = p / w
            if x > 0 { stack.append(p - 1) }
            if x < w - 1 { stack.append(p + 1) }
            if y > 0 { stack.append(p - w) }
            if y < h - 1 { stack.append(p + w) }
        }
        // NOTE: a global "clear every near-bg pixel" second pass used to live
        // here to catch enclosed pockets — but it punched HOLES in light-
        // coloured characters (sprayer/turret/juggernaut have large pale armor
        // regions within tolerance of the near-white backing). The border
        // flood-fill above already removes the real background (it's all
        // border-connected); rare fully-enclosed pockets are a far smaller
        // cosmetic cost than transparent holes in the sprite, so the global
        // pass is intentionally removed. `tol2` is retained for reference.
        _ = tol2
        guard let outCG = ctx.makeImage() else { return image }
        return UIImage(cgImage: outCG, scale: 1, orientation: .up)
    }
}

private struct EnemyHitFlash: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        active ? AnyView(content.colorMultiply(Color(red: 1.0, green: 0.6, blue: 0.6))) : AnyView(content)
    }
}

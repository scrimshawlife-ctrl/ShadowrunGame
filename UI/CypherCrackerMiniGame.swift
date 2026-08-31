import SwiftUI
import Combine

/// CYPHER CRACKER — Mission 4's data-extraction mini-game.
///
/// Premise: three concentric rings of glyphs spin at different speeds.
/// A "lock arrow" points down from 12 o'clock. Each ring has one or two
/// **key glyphs** (the highlighted ones). Tap the ring when one of its
/// keys is aligned with the lock arrow to lock it in. Lock all three
/// rings to crack the cypher and extract the data.
///
/// Wrong taps cost trace; let the trace bar fill and you're burned.
///
/// Inputs (touch-only):
///   • Tap an outer ring band  → attempt lock on that ring
///
/// Win:  All 3 rings locked.
/// Lose: Trace bar fills (5 wrong attempts).
struct CypherCrackerMiniGame: View {
    @ObservedObject var gameState: GameState
    let onComplete: (Bool) -> Void

    // MARK: - Level progression
    //
    // The mini-game runs THREE escalating levels in a single play session.
    // L1 is a ~5-second intro (slow rings, generous tolerance, multiple
    // key glyphs). Lock all three rings to advance to L2 (faster + tighter).
    // L2 → L3 (the timing test). Lock all three rings on L3 to win.
    // Misses reset per level so the player can recover from a rough start,
    // but the miss budget tightens with each escalation.

    private static let totalLevels = 3

    struct LevelTuning {
        let spinSpeeds: [Double]              // per-ring base spin (rad/sec)
        let lockTolerance: Double             // fraction-of-slot tap window
        let postLockSpeedMultiplier: Double   // ramp after each lock within the level
        let maxMisses: Int                    // miss budget for this level
        let keyCounts: [Int]                  // # of key glyphs per ring
    }

    static func tuning(forLevel level: Int) -> LevelTuning {
        switch level {
        case 1:
            // Warm-up. Very slow rings + huge tap window + 3-2-2 key glyphs
            // means a focused player can finish in ~5 seconds.
            return LevelTuning(
                spinSpeeds: [0.40, 0.70, 1.00],
                lockTolerance: 0.55,
                postLockSpeedMultiplier: 1.15,
                maxMisses: 6,
                keyCounts: [3, 2, 2]
            )
        case 2:
            // Mid-game. Standard challenge: faster rings, tighter window,
            // fewer keys.
            return LevelTuning(
                spinSpeeds: [0.65, 1.10, 1.55],
                lockTolerance: 0.35,
                postLockSpeedMultiplier: 1.35,
                maxMisses: 5,
                keyCounts: [2, 1, 1]
            )
        default:
            // Final. Fast spin + narrow window + 1 key glyph each + aggressive
            // post-lock ramp. Has to be pre-read to clear cleanly.
            return LevelTuning(
                spinSpeeds: [0.90, 1.55, 2.20],
                lockTolerance: 0.24,
                postLockSpeedMultiplier: 1.55,
                maxMisses: 3,
                keyCounts: [1, 1, 1]
            )
        }
    }

    /// Per-level identity. The three levels already escalate mechanically, but
    /// they were visually identical, so clearing one and starting the next read
    /// as the same screen repeating rather than progress (playtest 2026-07-25:
    /// "should have more than just 1 screen, maybe 3"). Naming and colouring
    /// each tier makes the progression legible.
    static func levelName(_ level: Int) -> String {
        switch level {
        case 1:  return "OUTER SHELL"
        case 2:  return "CIPHER LAYER"
        default: return "BLACK ICE CORE"
        }
    }

    static func levelAccentHex(_ level: Int) -> String {
        switch level {
        case 1:  return "00FF88"   // green — safe warm-up
        case 2:  return "FFC844"   // amber — pressure
        default: return "FF3355"   // red — black ice
        }
    }

    // MARK: - Tuning

    /// Number of glyphs around each ring's circumference.
    private let glyphsPerRing = 12
    /// Tuning resolved from the current level. Updated when the level advances.
    @State private var tuningCfg: LevelTuning = CypherCrackerMiniGame.tuning(forLevel: 1)
    @State private var currentLevel: Int = 1

    // MARK: - Ring model

    struct CypherRing: Identifiable {
        let id = UUID()
        var glyphs: [String]
        /// Indices into `glyphs` that are the "key" glyphs to align.
        var keyIndices: [Int]
        /// Current rotation in radians. Increases with time.
        var rotation: Double = 0
        var spinSpeed: Double
        /// True once the player aligns + taps a key glyph at the lock arrow.
        var isLocked: Bool = false
        var color: Color
    }

    // MARK: - State

    @State private var rings: [CypherRing] = []
    @State private var misses: Int = 0
    /// Lifetime miss tally for SCORING — `misses` is the per-level budget and
    /// resets each level, so scoring off it only ever counted final-level
    /// misses despite the "LIFETIME" intent.
    @State private var totalMisses: Int = 0
    @State private var gameOver: Bool = false
    @State private var didWin: Bool = false
    @State private var pulseTime: Double = 0
    @State private var elapsedSeconds: Double = 0

    @State private var spinTimer: AnyCancellable?
    @State private var pulseTimer: AnyCancellable?
    @State private var rainTimer: AnyCancellable?
    @State private var codeRain: [RainColumn] = []
    @State private var chiptune: ChiptunePlayer? = nil
    @State private var showBriefing: Bool = true

    /// Brief flash overlay around the lock arrow when player locks/misses.
    @State private var flashKind: FlashKind? = nil
    @State private var flashSeconds: Double = 0
    /// Name of the tier just entered, shown briefly so each level announces itself.
    @State private var stageBanner: String? = nil
    @State private var stageBannerSeconds: Double = 0
    enum FlashKind { case success, fail }

    struct RainColumn: Identifiable {
        let id = UUID()
        var x: CGFloat
        var headY: CGFloat
        var glyphs: [String]
        var speed: CGFloat
    }

    private static let glyphPool: [String] = [
        "0", "1", "F", "7", "A", "C", "E", "9",
        "B", "D", "3", "5", "8", "6",
        "Σ", "Φ", "Ω", "Δ", "λ", "π",
    ]

    private static let rainPool: [String] = [
        "0", "1", "0", "1", "F", "7", "A", "C", "E", "9",
        "0xF", "0x7", "B3", "FF", "C0", "DE",
    ]

    // MARK: - Body

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "01040A"), Color(hex: "02060E"), Color(hex: "01040A")],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                cypherArea
                hud
                touchHint
            }
            .padding(.bottom, 28)

            if showBriefing {
                MiniGameBriefing(
                    title: "CYPHER CRACK",
                    subtitle: "RING ALIGNMENT PROTOCOL",
                    accent: Color(hex: "FF00AA"),
                    rules: [
                        BriefingRule(
                            iconName: "circle.dotted",
                            color: Color(hex: "00FFCC"),
                            title: "THREE RINGS, ONE LOCK",
                            detail: "Three glyph rings spin at different speeds. The white arrow at 12 o'clock is the LOCK position."
                        ),
                        BriefingRule(
                            iconName: "hand.point.up.fill",
                            color: Color(hex: "FFCC00"),
                            title: "TAP A RING WHEN ITS KEY ALIGNS",
                            detail: "Highlighted Greek/symbol glyphs (Σ Φ Ω Δ λ π) are KEYS. Tap a ring when one of its keys is under the lock arrow."
                        ),
                        BriefingRule(
                            iconName: "arrow.triangle.2.circlepath",
                            color: Color(hex: "FF00AA"),
                            title: "THREE LEVELS, ESCALATING",
                            detail: "Crack all 3 rings to advance. Each new level spins faster, drops your miss budget, and tightens the lock window."
                        ),
                        BriefingRule(
                            iconName: "exclamationmark.triangle.fill",
                            color: Color(hex: "FF3344"),
                            title: "TOO MANY WRONG TAPS = LOCKED OUT",
                            detail: "Misses reset between levels — but blow this level's budget and the trace burns you."
                        ),
                    ],
                    onStart: { showBriefing = false }
                )
                .zIndex(1000)
            }
        }
        .onAppear {
            initialise()
            startTimers()
            startAudio()
        }
        .onDisappear {
            cancelTimers()
            chiptune?.stop()
            chiptune = nil
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(Color(hex: "FF00AA"))
                    .frame(width: 6, height: 6)
                    .opacity(0.5 + 0.5 * sin(pulseTime * 6))
                Text("// CYPHER CRACK")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(Color(hex: "FF00AA"))
                Circle().fill(Color(hex: "00FFCC"))
                    .frame(width: 6, height: 6)
                    .opacity(0.5 + 0.5 * sin(pulseTime * 6 + .pi))
            }
            Text("ALIGN EACH RING'S KEY GLYPH UNDER THE LOCK")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(1)
                .foregroundColor(.white.opacity(0.65))
        }
        .padding(.top, 28)
        .padding(.bottom, 12)
    }

    // MARK: - Cypher area

    private var cypherArea: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle()
                    .fill(Color(hex: "020812"))
                    .overlay(Rectangle().stroke(Color(hex: "00FFCC").opacity(0.30), lineWidth: 1))
                    .overlay(Rectangle().stroke(Color(hex: "FF00AA").opacity(0.10), lineWidth: 3))

                Canvas { ctx, size in
                    drawCodeRain(ctx: ctx, size: size)
                    drawScanlines(ctx: ctx, size: size)
                    drawRings(ctx: ctx, size: size)
                    drawLockArrow(ctx: ctx, size: size)
                    drawFlash(ctx: ctx, size: size)
                }

                if gameOver {
                    Color.black.opacity(0.78)
                    VStack(spacing: 6) {
                        Text(didWin ? "CYPHER CRACKED" : "TRACE BURNED YOU")
                            .font(.system(size: 20, weight: .black, design: .monospaced))
                            .tracking(2)
                            .foregroundColor(didWin ? Color(hex: "00FFCC") : Color(hex: "FF3344"))
                        Text(didWin ? "// DATA EXTRACTED" : "// LOCKED OUT")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .background(Color.black.opacity(0.8))
                    .overlay(
                        Rectangle().stroke(didWin ? Color(hex: "00FFCC") : Color(hex: "FF3344"), lineWidth: 1.5)
                    )
                }
                // Tier callout — each level announces itself by name so the
                // three stages read as progress, not the same board again.
                if let banner = stageBanner, stageBannerSeconds > 0 {
                    VStack(spacing: 2) {
                        Text("LEVEL \(currentLevel)")
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .tracking(3)
                            .foregroundColor(.white.opacity(0.65))
                        Text(banner)
                            .font(.system(size: 20, weight: .black, design: .monospaced))
                            .tracking(2)
                            .foregroundColor(Color(hex: CypherCrackerMiniGame.levelAccentHex(currentLevel)))
                    }
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(Color.black.opacity(0.78))
                    .overlay(Rectangle().stroke(
                        Color(hex: CypherCrackerMiniGame.levelAccentHex(currentLevel)).opacity(0.7),
                        lineWidth: 1.5))
                    .opacity(min(1.0, stageBannerSeconds * 2.0))
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                handleTap(at: location, in: geo.size)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 400)
        .padding(.horizontal, 8)
    }

    // MARK: - HUD

    private var hud: some View {
        HStack(spacing: 8) {
            statusBlock(label: CypherCrackerMiniGame.levelName(currentLevel),
                        value: "\(currentLevel) / \(CypherCrackerMiniGame.totalLevels)",
                        color: Color(hex: CypherCrackerMiniGame.levelAccentHex(currentLevel)))
            statusBlock(label: "RINGS",
                        value: "\(rings.filter(\.isLocked).count) / \(rings.count)",
                        color: Color(hex: "00FFCC"))
            statusBlock(label: "MISSES",
                        value: "\(misses) / \(tuningCfg.maxMisses)",
                        color: Color(hex: "FF3344"))
            statusBlock(label: "TIME",
                        value: String(format: "%.1fs", elapsedSeconds),
                        color: Color(hex: "FFCC00"))
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var touchHint: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("TAP A RING")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(1)
                    .foregroundColor(.white.opacity(0.55))
                Text("Tap the ring's band when its KEY glyph is under the lock.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(hex: "00FFCC").opacity(0.75))
            }
            Spacer()
            Button(action: {
                HapticsManager.shared.buttonTap()
                chiptune?.sfxBail()
                finishGame(success: false)
            }) {
                Text("BAIL")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(Color(hex: "FF3344"))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(
                        Rectangle()
                            .fill(Color.black.opacity(0.65))
                            .overlay(Rectangle().stroke(Color(hex: "FF3344").opacity(0.7), lineWidth: 1))
                    )
            }
            .frame(minHeight: 44)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
    }

    private func statusBlock(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .tracking(1)
                .foregroundColor(.white.opacity(0.55))
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            Rectangle()
                .fill(Color.black.opacity(0.4))
                .overlay(Rectangle().stroke(color.opacity(0.4), lineWidth: 1))
        )
    }

    // MARK: - Ring geometry

    /// Center of the ring stack — middle of the cypher area.
    private func center(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2, y: size.height / 2)
    }

    /// Radius for ring index (0 = outermost, 2 = innermost).
    private func radius(forRingIndex i: Int, in size: CGSize) -> CGFloat {
        let maxR = min(size.width, size.height) * 0.42
        let minR: CGFloat = 50
        let t = CGFloat(i) / CGFloat(max(1, rings.count - 1))
        return maxR - (maxR - minR) * t
    }

    /// Half-width of a ring's glyph band (used for hit-testing taps).
    private func bandHalfWidth(in size: CGSize) -> CGFloat {
        let maxR = min(size.width, size.height) * 0.42
        let minR: CGFloat = 50
        return (maxR - minR) / CGFloat(max(1, rings.count - 1)) / 2
    }

    // MARK: - Drawing

    private func drawCodeRain(ctx: GraphicsContext, size: CGSize) {
        for col in codeRain {
            for (i, g) in col.glyphs.enumerated() {
                let y = col.headY - CGFloat(i) * 14
                guard y >= -14, y <= size.height + 14 else { continue }
                let alpha = max(0, 1.0 - Double(i) * 0.08)
                let color = i == 0
                    ? Color.white.opacity(alpha * 0.7)
                    : Color(hex: "00FF88").opacity(alpha * 0.45)
                ctx.draw(
                    Text(g).font(.system(size: 11, weight: .regular, design: .monospaced))
                          .foregroundColor(color),
                    at: CGPoint(x: col.x, y: y)
                )
            }
        }
    }

    private func drawScanlines(ctx: GraphicsContext, size: CGSize) {
        let alpha = 0.04 + sin(pulseTime * 2.5) * 0.02
        var y: CGFloat = 0
        while y < size.height {
            ctx.fill(
                Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                with: .color(Color(hex: "00FFCC").opacity(alpha))
            )
            y += 3
        }
    }

    private func drawRings(ctx: GraphicsContext, size: CGSize) {
        let cnt = center(in: size)
        for (i, ring) in rings.enumerated() {
            let r = radius(forRingIndex: i, in: size)
            let bandHalf = bandHalfWidth(in: size)
            // Ring band
            let outerR = r + bandHalf
            let innerR = r - bandHalf
            let outerRect = CGRect(x: cnt.x - outerR, y: cnt.y - outerR, width: outerR*2, height: outerR*2)
            let innerRect = CGRect(x: cnt.x - innerR, y: cnt.y - innerR, width: innerR*2, height: innerR*2)
            // Faint backplate band
            ctx.stroke(
                Path(ellipseIn: outerRect.insetBy(dx: -bandHalf, dy: -bandHalf)),
                with: .color(ring.color.opacity(0.05)),
                lineWidth: bandHalf * 2
            )
            // Outer / inner edges
            let edgeAlpha = ring.isLocked ? 0.8 : 0.55
            ctx.stroke(Path(ellipseIn: outerRect),
                       with: .color((ring.isLocked ? Color(hex: "00FF88") : ring.color).opacity(edgeAlpha)),
                       lineWidth: 1.2)
            ctx.stroke(Path(ellipseIn: innerRect),
                       with: .color((ring.isLocked ? Color(hex: "00FF88") : ring.color).opacity(edgeAlpha)),
                       lineWidth: 1.2)

            // Glyphs around the ring
            for slot in 0..<glyphsPerRing {
                let theta = ring.rotation + Double(slot) * (2.0 * .pi / Double(glyphsPerRing)) - .pi/2
                let gx = cnt.x + CGFloat(cos(theta)) * r
                let gy = cnt.y + CGFloat(sin(theta)) * r
                let g = ring.glyphs[slot]
                let isKey = ring.keyIndices.contains(slot)
                let glyphColor: Color
                if ring.isLocked {
                    glyphColor = Color(hex: "00FF88")
                } else if isKey {
                    glyphColor = ring.color
                } else {
                    glyphColor = Color.white.opacity(0.35)
                }
                let weight: Font.Weight = isKey ? .black : .medium
                let fontSize: CGFloat = isKey ? 16 : 13
                if isKey {
                    // Glow plate behind key glyph
                    let halo = CGRect(x: gx - 11, y: gy - 11, width: 22, height: 22)
                    ctx.fill(Path(ellipseIn: halo), with: .color(ring.color.opacity(0.20)))
                }
                ctx.draw(
                    Text(g).font(.system(size: fontSize, weight: weight, design: .monospaced))
                          .foregroundColor(glyphColor),
                    at: CGPoint(x: gx, y: gy)
                )
            }
        }

        // Center "DATA" disc
        let r: CGFloat = 28 + 4 * sin(pulseTime * 4)
        let pulse = CGRect(x: cnt.x - r, y: cnt.y - r, width: r*2, height: r*2)
        ctx.fill(Path(ellipseIn: pulse), with: .color(Color(hex: "FF00AA").opacity(0.15)))
        let inner = CGRect(x: cnt.x - 18, y: cnt.y - 18, width: 36, height: 36)
        ctx.fill(Path(ellipseIn: inner), with: .color(Color(hex: "FF00AA").opacity(0.55)))
        ctx.stroke(Path(ellipseIn: inner), with: .color(.white), lineWidth: 1.5)
        ctx.draw(
            Text("DATA").font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundColor(.white),
            at: cnt
        )
    }

    /// Lock arrow at 12 o'clock pointing inward toward the center.
    private func drawLockArrow(ctx: GraphicsContext, size: CGSize) {
        let cnt = center(in: size)
        let outerR = radius(forRingIndex: 0, in: size) + bandHalfWidth(in: size) + 12
        let tipY = cnt.y - outerR + 18
        let baseY = cnt.y - outerR + 2
        var arrow = Path()
        arrow.move(to: CGPoint(x: cnt.x, y: tipY))
        arrow.addLine(to: CGPoint(x: cnt.x - 7, y: baseY))
        arrow.addLine(to: CGPoint(x: cnt.x + 7, y: baseY))
        arrow.closeSubpath()
        ctx.fill(arrow, with: .color(Color(hex: "FFFFFF")))
        ctx.stroke(arrow, with: .color(Color(hex: "FF00AA")), lineWidth: 1.5)
        // "LOCK" tag above
        ctx.draw(
            Text("LOCK").font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundColor(Color(hex: "FF00AA")),
            at: CGPoint(x: cnt.x, y: baseY - 9)
        )
    }

    private func drawFlash(ctx: GraphicsContext, size: CGSize) {
        guard let kind = flashKind, flashSeconds > 0 else { return }
        let cnt = center(in: size)
        let alpha = min(1.0, flashSeconds * 2.5)
        let color: Color = kind == .success ? Color(hex: "00FF88") : Color(hex: "FF3344")
        let r: CGFloat = (1.0 - flashSeconds) * 90 + 40
        let pulse = CGRect(x: cnt.x - r, y: cnt.y - r, width: r*2, height: r*2)
        ctx.stroke(Path(ellipseIn: pulse), with: .color(color.opacity(alpha)), lineWidth: 2)
    }

    // MARK: - Input

    private func handleTap(at point: CGPoint, in size: CGSize) {
        guard !gameOver, !showBriefing else { return }
        let cnt = center(in: size)
        let dx = point.x - cnt.x
        let dy = point.y - cnt.y
        let dist = hypot(dx, dy)
        // Find which ring (if any) the tap landed in
        let bandHalf = bandHalfWidth(in: size)
        for (i, _) in rings.enumerated() where !rings[i].isLocked {
            let r = radius(forRingIndex: i, in: size)
            if dist >= r - bandHalf && dist <= r + bandHalf {
                attemptLock(ringIndex: i)
                return
            }
        }
    }

    /// True if the lock arrow is over a key glyph (within tolerance).
    private func isAlignedAtLock(ring: CypherRing) -> Bool {
        let slotAngle = 2.0 * .pi / Double(glyphsPerRing)
        // Lock is at top (-pi/2). Each slot's actual angle is rotation + slot*slotAngle - pi/2.
        // We want slot's offset from -pi/2 → so we need slot*slotAngle + rotation ≡ 0 (mod 2pi).
        // For each key index, compute the residual.
        for keyIdx in ring.keyIndices {
            let raw = ring.rotation + Double(keyIdx) * slotAngle
            // Reduce to [-pi, pi]
            var residual = raw.truncatingRemainder(dividingBy: 2 * .pi)
            if residual > .pi { residual -= 2 * .pi }
            if residual < -.pi { residual += 2 * .pi }
            if abs(residual) < slotAngle * tuningCfg.lockTolerance {
                return true
            }
        }
        return false
    }

    private func attemptLock(ringIndex: Int) {
        guard ringIndex < rings.count, !rings[ringIndex].isLocked else { return }
        if isAlignedAtLock(ring: rings[ringIndex]) {
            rings[ringIndex].isLocked = true
            // Ramp difficulty: speed up every still-unlocked ring so the
            // remaining locks get progressively harder. The final ring spins
            // ~1.35² ≈ 1.82× faster than its baseline.
            for i in rings.indices where !rings[i].isLocked {
                rings[i].spinSpeed *= tuningCfg.postLockSpeedMultiplier
            }
            chiptune?.sfxRingLock()
            HapticsManager.shared.attackHit()
            flashKind = .success
            flashSeconds = 0.45
            if rings.allSatisfy(\.isLocked) {
                // Level cleared — advance OR win on the final level.
                if currentLevel < CypherCrackerMiniGame.totalLevels {
                    advanceToNextLevel()
                } else {
                    chiptune?.sfxWin()
                    finishGame(success: true)
                }
            }
        } else {
            misses += 1
            totalMisses += 1
            chiptune?.sfxRingMiss()
            HapticsManager.shared.playerKilled()
            flashKind = .fail
            flashSeconds = 0.45
            if misses >= tuningCfg.maxMisses {
                chiptune?.sfxLose()
                finishGame(success: false)
            }
        }
    }

    // MARK: - Tick / lifecycle

    private func startTimers() {
        let dt: TimeInterval = 1.0 / 60.0
        spinTimer = Timer.publish(every: dt, on: .main, in: .common)
            .autoconnect()
            .sink { _ in tick(dt: dt) }
        pulseTimer = Timer.publish(every: 0.05, on: .main, in: .common)
            .autoconnect()
            .sink { _ in pulseTime += 0.05 }
        var cols: [RainColumn] = []
        for _ in 0..<14 { cols.append(makeRainColumn()) }
        codeRain = cols
        rainTimer = Timer.publish(every: 0.07, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                for i in codeRain.indices {
                    codeRain[i].headY += codeRain[i].speed
                    if codeRain[i].headY > 420 {
                        codeRain[i] = makeRainColumn(resetTop: true)
                    }
                }
            }
    }

    private func cancelTimers() {
        spinTimer?.cancel()
        pulseTimer?.cancel()
        rainTimer?.cancel()
    }

    private func tick(dt: TimeInterval) {
        guard !gameOver, !showBriefing else { return }
        elapsedSeconds += dt
        for i in rings.indices where !rings[i].isLocked {
            // Direction alternates: outer CW, middle CCW, inner CW — visually
            // distinct, and prevents the player from exploiting a single rhythm.
            let dir: Double = (i % 2 == 0) ? 1 : -1
            rings[i].rotation += rings[i].spinSpeed * dir * dt
        }
        if flashSeconds > 0 {
            flashSeconds = max(0, flashSeconds - dt)
            if flashSeconds == 0 { flashKind = nil }
        }
        if stageBannerSeconds > 0 {
            stageBannerSeconds = max(0, stageBannerSeconds - dt)
            if stageBannerSeconds == 0 { stageBanner = nil }
        }
    }

    private func initialise() {
        currentLevel = 1
        tuningCfg = CypherCrackerMiniGame.tuning(forLevel: 1)
        rebuildRings()
        misses = 0
        gameOver = false
        didWin = false
        elapsedSeconds = 0
        flashKind = nil
        flashSeconds = 0
    }

    /// Promote to next level: refresh tuning, rebuild a fresh set of rings,
    /// reset misses (so the player isn't punished by carrying-over budget
    /// from the easier level), keep the elapsed timer running.
    private func advanceToNextLevel() {
        currentLevel += 1
        tuningCfg = CypherCrackerMiniGame.tuning(forLevel: currentLevel)
        rebuildRings()
        misses = 0
        flashKind = .success
        flashSeconds = 0.55
        // Announce the new tier by name. Without this the next level started
        // silently on an identical-looking board and the three stages read as
        // one repeating screen.
        stageBanner = CypherCrackerMiniGame.levelName(currentLevel)
        stageBannerSeconds = 1.6
        chiptune?.sfxRingLock()
        HapticsManager.shared.selectAffirm()
    }

    /// Build a fresh trio of rings using the current tuning. Key-glyph
    /// counts now come from `tuningCfg.keyCounts` so each level has a
    /// distinct read.
    private func rebuildRings() {
        rings = []
        let palettes: [Color] = [
            Color(hex: "00FFCC"),
            Color(hex: "FF00AA"),
            Color(hex: "FFCC00"),
        ]
        let keyGlyphs = ["Σ", "Φ", "Ω", "Δ", "λ", "π"]
        for i in 0..<3 {
            var glyphs: [String] = []
            for _ in 0..<glyphsPerRing {
                glyphs.append(CypherCrackerMiniGame.glyphPool.randomElement() ?? "1")
            }
            let keyCount = max(1, tuningCfg.keyCounts.indices.contains(i) ? tuningCfg.keyCounts[i] : 1)
            var keys: Set<Int> = []
            while keys.count < keyCount {
                keys.insert(Int.random(in: 0..<glyphsPerRing))
            }
            for k in keys {
                glyphs[k] = keyGlyphs.randomElement() ?? "Σ"
            }
            rings.append(CypherRing(
                glyphs: glyphs,
                keyIndices: Array(keys),
                rotation: Double.random(in: 0..<(2 * .pi)),
                spinSpeed: tuningCfg.spinSpeeds[i],
                color: palettes[i]
            ))
        }
    }

    private func startAudio() {
        let player = ChiptunePlayer()
        player?.startMelody()
        chiptune = player
    }

    private func finishGame(success: Bool) {
        guard !gameOver else { return }
        gameOver = true
        didWin = success
        // Score = base 1500 - 80 per miss (LIFETIME — not reset per level) -
        // 3 per second elapsed. Three levels stretch the run to ~20-40 seconds
        // so the time penalty is softer than the old single-level formula.
        // A flawless ~25s run on all three levels still nets ~1425.
        if success, let id = gameState.currentMissionDisplayId {
            let score = max(0, 1500 - totalMisses * 80 - Int(elapsedSeconds * 3))
            MissionStatsStore.shared.recordMiniGameScore(missionId: id, score: score)
        }
        cancelTimers()
        // Linger on a WIN, snap back fast on a loss/bail.
        DispatchQueue.main.asyncAfter(deadline: .now() + (success ? 1.5 : 0.9)) {
            chiptune?.stop()
            chiptune = nil
            onComplete(success)
        }
    }

    private func makeRainColumn(resetTop: Bool = false) -> RainColumn {
        let pool = CypherCrackerMiniGame.rainPool
        let len = Int.random(in: 6...12)
        var glyphs: [String] = []
        for _ in 0..<len { glyphs.append(pool.randomElement() ?? "0") }
        return RainColumn(
            x: CGFloat.random(in: 8...380),
            headY: resetTop ? CGFloat.random(in: -120 ... -10) : CGFloat.random(in: -80...420),
            glyphs: glyphs,
            speed: CGFloat.random(in: 1.2...3.2)
        )
    }
}

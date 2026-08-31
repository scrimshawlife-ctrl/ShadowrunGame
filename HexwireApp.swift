import SwiftUI
import SpriteKit
import QuartzCore

// MARK: - Mission Objective Banner

struct MissionObjectiveBanner: View {
    let missionTitle: String
    let missionId: String
    let extractionX: Int
    let extractionY: Int
    @State private var pulse: Bool = false
    @State private var isVisible: Bool = true
    @State private var hideTimer: Timer?

    /// Per-mission objective string. Each mission ships as a 3-room
    /// multi-room JSON (loaded via MissionLoader's _multi-first path),
    /// so the wording calls out the rooms / required actions in order
    /// instead of the old "Reach the ★ EXIT at north end" boilerplate.
    /// Terminal breach is explicitly named where the mission requires it.
    private var objectiveText: String {
        switch missionId {
        case "Mission001":
            // 3 rooms, no terminal — just push through to the rooftop.
            return "OBJECTIVE: Push through Courtyard → Security Wing → Rooftop ★ EXIT."
        case "Mission002":
            // 3 rooms, terminal in room_1 (AI Core Chamber).
            return "OBJECTIVE: Hack the AI Core terminal, then reach the rooftop ★ EXIT."
        case "Mission003":
            // 3 rooms, terminal in room_1 (Warded Corridor).
            return "OBJECTIVE: Hack the warded terminal, then reach the Ritual Chamber ★ EXIT."
        case "Mission004":
            // 3 rooms, terminal in room_1 (Executive Suite).
            return "OBJECTIVE: Hack the Executive Suite terminal, then reach the rooftop ★ EXIT."
        case "Mission005":
            // 3 rooms, terminal in room_1 (Factory Floor).
            return "OBJECTIVE: Hack the Factory Floor terminal, then reach the Mech Bay ★ EXIT."
        case "Mission006":
            // 3 rooms, terminal in room_1 (AI Core Vault).
            return "OBJECTIVE: Hack the AI Core Vault terminal, then escape via the Extraction Tunnel ★ EXIT."
        default:
            return "OBJECTIVE: Reach the ★ EXIT (green glow)."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isVisible {
                HStack(spacing: 10) {
                    // Mission icon
                    ZStack {
                        Circle()
                            .fill(Color(hex: "00FF88").opacity(0.15))
                            .frame(width: 28, height: 28)
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "00FF88"))
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("MISSION: \(missionTitle)")
                                .font(.system(size: 10, weight: .black, design: .monospaced))
                                .foregroundColor(Color(hex: "00FF88"))
                                .tracking(0.5)
                            // New Game+ badge — only shows on replays.
                            if NGPlusStore.shared.tier > 0 {
                                Text("NG+\(NGPlusStore.shared.tier)")
                                    .font(.system(size: 9, weight: .black, design: .monospaced))
                                    .foregroundColor(Color(hex: "FF4A4A"))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .overlay(RoundedRectangle(cornerRadius: 3)
                                        .stroke(Color(hex: "FF4A4A").opacity(0.8), lineWidth: 1))
                            }
                        }
                        Text(objectiveText)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.white.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    // Toggle button
                    Button(action: {
                        withAnimation { isVisible = false }
                        hideTimer?.invalidate()
                    }) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 14))
                            .foregroundColor(Color(hex: "00FF88").opacity(0.6))
                            // 44pt invisible hit area for thumb-friendly taps.
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    // Extraction target badge — pulsing
                    VStack(alignment: .center, spacing: 2) {
                        Text("TARGET")
                            .font(.system(size: 7, weight: .black))
                            .foregroundColor(Color(hex: "00FF88").opacity(0.7))
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 7))
                                .foregroundColor(Color(hex: "00FF88"))
                            Text("EXIT (\(extractionX),\(extractionY))")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundColor(Color(hex: "00FF88"))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(hex: "00FF88").opacity(pulse ? 0.25 : 0.12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color(hex: "00FF88").opacity(pulse ? 0.8 : 0.4), lineWidth: 1)
                                )
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(hex: "0A0A14").opacity(0.90))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(hex: "00FF88").opacity(0.3), lineWidth: 1)
                        )
                )
                .transition(.opacity)
            }
            // Collapsed-state "info" dot removed per playtest — the
            // INTEL button in the utility row provides the same info
            // on demand, so the floating green ⓘ at the top of the map
            // was redundant clutter once the banner auto-hid.
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulse = true
            }
            startAutoHideTimer()
        }
        .onDisappear {
            hideTimer?.invalidate()
        }
    }

    private func startAutoHideTimer() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in
            withAnimation { isVisible = false }
        }
    }
}

/// Transient red-edged warning banner used for objective-gate prompts
/// ("JACK IN AND HACK THE TERMINAL FIRST", etc.). Visibility is owned by
/// `GameState.transientWarning` — this view just renders the current value
/// and styles it. Auto-clear timer lives in `GameState.postTransientWarning`.
struct TerminalWarningBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .black))
                .foregroundColor(Color(hex: "FFCC00"))
            Text(text)
                .font(.system(size: 12, weight: .black, design: .monospaced))
                .tracking(1.2)
                .foregroundColor(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(hex: "1A0A0A").opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(hex: "FFCC00").opacity(0.85), lineWidth: 1.2)
                )
                .shadow(color: Color(hex: "FFCC00").opacity(0.35), radius: 8)
        )
    }
}

/// Loads a full-bleed boss splash image from `Sprites/backgrounds/` (folder
/// reference). Mirrors SpriteManager's multi-path lookup but returns a UIImage
/// for SwiftUI. Returns nil if the art hasn't been dropped in yet — the
/// overlay then renders a tinted-gradient fallback so it still looks intentional.
func loadBossSplashImage(_ name: String) -> UIImage? {
    if let img = UIImage(named: name) { return img }
    let candidates: [URL?] = [
        Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Sprites/backgrounds"),
        Bundle.main.resourceURL?.appendingPathComponent("Sprites/backgrounds/\(name).png")
    ]
    for case let url? in candidates {
        if let img = UIImage(contentsOfFile: url.path) { return img }
    }
    return nil
}

/// Loads a shop/item icon PNG from `Sprites/frames/` (e.g. "shopicon_smartlink").
/// Returns nil if absent so the caller can fall back to an SF Symbol.
func loadShopIcon(_ name: String) -> UIImage? {
    if let img = UIImage(named: name) { return img }
    let candidates: [URL?] = [
        Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Sprites/frames"),
        Bundle.main.resourceURL?.appendingPathComponent("Sprites/frames/\(name).png")
    ]
    for case let url? in candidates {
        if let img = UIImage(contentsOfFile: url.path) { return img }
    }
    return nil
}

/// Full-screen cinematic boss reveal. Dims the board, slams in a big rendered
/// splash of the boss (or a tinted fallback), and stamps the name/role/threat
/// line over hazard bars. Visibility owned by `GameState.bossIntro`; this view
/// just animates the current value in and reports a tap for early-skip.
struct BossIntroOverlay: View {
    let intro: GameState.BossIntro
    var onDismiss: () -> Void = {}

    /// How long the reveal ignores taps. Must outlast the 0.9s fade-up, or the
    /// card can be dismissed before it is fully visible.
    static let tapGraceSeconds: TimeInterval = 1.2

    @State private var appear = false
    @State private var pulse = false
    @State private var canDismiss = false
    @State private var splash: UIImage? = nil

    private var accent: Color { Color(hex: intro.accentHex) }

    var body: some View {
        ZStack {
            Color.black.opacity(appear ? 0.84 : 0.0).ignoresSafeArea()

            // Big rendered splash (or tinted radial fallback) + legibility wash.
            GeometryReader { geo in
                ZStack {
                    if let img = splash {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                            .scaleEffect(appear ? 1.0 : 1.16)
                            .opacity(appear ? 1 : 0)
                    } else {
                        RadialGradient(
                            colors: [accent.opacity(0.5), .black],
                            center: .center, startRadius: 24,
                            endRadius: max(geo.size.width, geo.size.height) * 0.7
                        )
                        .opacity(appear ? 1 : 0)
                    }
                    LinearGradient(
                        colors: [.black.opacity(0.55), .clear, .black.opacity(0.92)],
                        startPoint: .top, endPoint: .bottom
                    )
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: 54)
                Spacer()
                VStack(spacing: 12) {
                    Text("⚠  HOSTILE COMMANDER DETECTED")
                        .font(.system(size: 13, weight: .black, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(accent)
                        .opacity(pulse ? 1.0 : 0.45)
                    Text(intro.name)
                        .font(.system(size: 44, weight: .black, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(.white)
                        .shadow(color: accent.opacity(0.9), radius: 14)
                        .scaleEffect(appear ? 1.0 : 1.28)
                        .opacity(appear ? 1 : 0)
                        .multilineTextAlignment(.center)
                    Text(intro.title)
                        .font(.system(size: 15, weight: .heavy, design: .monospaced))
                        .tracking(4)
                        .foregroundColor(.white.opacity(0.92))
                    Rectangle().fill(accent)
                        .frame(width: appear ? 180 : 0, height: 2)
                        .shadow(color: accent, radius: 6)
                    Text(intro.tagline)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .italic()
                        .foregroundColor(.white.opacity(0.72))
                        .opacity(appear ? 1 : 0)
                    // Tap-to-engage prompt — the card holds until the player
                    // dismisses it, so the reveal isn't gone in a blink.
                    Text("▶  TAP TO ENGAGE")
                        .font(.system(size: 14, weight: .black, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(
                            Capsule()
                                .stroke(accent, lineWidth: 1.5)
                                .background(Capsule().fill(Color.black.opacity(0.45)))
                        )
                        .padding(.top, 14)
                        .opacity(pulse ? 1.0 : 0.5)
                }
                .padding(.horizontal, 24)
                Spacer().frame(height: 64)
                Spacer().frame(height: 40)
            }
        }
        .contentShape(Rectangle())
        // Tap-to-skip is DEADENED for the first beat. The reveal fires the
        // instant the player's killing blow lands, and combat is played by
        // tapping — an inherited tap (or the second half of an eager
        // double-tap) dismissed the card inside a frame, so the boss simply
        // appeared with no splash at all (playtest 2026-07-25: "boss appeared
        // without the boss splash screen"). The card also fades up over 0.9s,
        // so anything shorter than that was dismissing a card the player had
        // not even seen yet.
        .onTapGesture { if canDismiss { onDismiss() } }
        .onAppear {
            splash = loadBossSplashImage(intro.splashKey)
            // Slow ease-in (was a fast 0.45 spring that read as a hard "pop"):
            // the dim + splash + card all fade up together over ~0.9s so the
            // reveal builds instead of jumping onto the screen with no warning.
            withAnimation(.easeIn(duration: 0.9)) { appear = true }
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { pulse = true }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Self.tapGraceSeconds * 1_000_000_000))
                canDismiss = true
            }
        }
    }

    /// Diagonal-stripe hazard bar (accent over black) that sweeps to full width.
    private var hazardBar: some View {
        ZStack {
            Color.black.opacity(0.6)
            LinearGradient(
                colors: [accent, .black, accent, .black, accent],
                startPoint: .leading, endPoint: .trailing
            )
            .opacity(0.85)
        }
        .frame(height: 6)
        .frame(maxWidth: appear ? .infinity : 0)
        .opacity(appear ? 1 : 0)
    }
}

/// Clear "picked up X" pill shown when loot drops, distinct from the small
/// trace/objective warning banner.
struct LootToastCard: View {
    let info: GameState.LootInfo
    private var accent: Color { Color(hex: info.colorHex) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: info.icon)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("LOOT  ·  \(info.name.uppercased())")
                    .font(.system(size: 13, weight: .black, design: .monospaced))
                    .foregroundColor(.white)
                Text(info.detail)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(accent.opacity(0.95))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.9))
                .overlay(Capsule().stroke(accent.opacity(0.8), lineWidth: 1.4))
                .shadow(color: accent.opacity(0.4), radius: 8)
        )
        .padding(.horizontal, 24)
    }
}

/// Payload for the level-up card — the runner, their new level, and a
/// human-readable summary of what improved.
struct LevelUpInfo: Equatable {
    let name: String
    let level: Int
    let summary: String
}

/// Compact, non-blocking card that announces a level-up and lists the gains.
struct LevelUpCard: View {
    let info: LevelUpInfo
    private let gold = Color(hex: "FFCC33")

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.up.circle.fill")
                    .font(.system(size: 15, weight: .black))
                    .foregroundColor(gold)
                Text("LEVEL UP — \(info.name.uppercased())  ▸  Lv \(info.level)")
                    .font(.system(size: 13, weight: .black, design: .monospaced))
                    .tracking(1.5)
                    .foregroundColor(.white)
            }
            if !info.summary.isEmpty {
                Text(info.summary)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(gold.opacity(0.95))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(hex: "1A1505").opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(gold.opacity(0.85), lineWidth: 1.3)
                )
                .shadow(color: gold.opacity(0.4), radius: 10)
        )
        .padding(.horizontal, 28)
    }
}

/// One runner's row on the end-of-mission scorecard: level, key stats, and the
/// "+gains this mission" line.
struct RunnerScorecardRow: View {
    @ObservedObject var runner: Character

    private var roleLabel: String {
        switch runner.archetype {
        case .streetSam: return "Street Sam"
        case .mage:      return "Mage"
        case .decker:    return "Decker"
        case .face:      return "Face"
        }
    }

    private var statsLine: String {
        let a = runner.attributes, s = runner.skills
        switch runner.archetype {
        case .streetSam: return "HP \(runner.maxHP) · BOD \(a.bod) · AGI \(a.agi) · Blades \(s.blades)"
        case .mage:      return "HP \(runner.maxHP) · LOG \(a.log) · WIL \(a.wil) · Spell \(s.spellcasting) · Mana \(runner.maxMana)"
        case .decker:    return "HP \(runner.maxHP) · INT \(a.int) · LOG \(a.log) · Percep \(s.perception)"
        case .face:      return "HP \(runner.maxHP) · AGI \(a.agi) · CHA \(a.cha) · Firearms \(s.firearms)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(runner.name.uppercased())
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundColor(.white)
                Text(roleLabel)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.45))
                Spacer()
                Text("Lv \(runner.level)")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundColor(Color(hex: "00FF88"))
            }
            Text(statsLine)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
            if !runner.missionGainSummary.isEmpty {
                Text("▲ \(runner.missionGainSummary)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "FFCC33"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(hex: "00FF88").opacity(0.25), lineWidth: 1))
        )
    }
}

// MARK: - Black Market Shop

enum ShopTab: String, CaseIterable { case cyberware = "CYBER", weapons = "WEAPONS", armor = "ARMOR", stims = "STIMS", spells = "SPELLS", fixer = "FIXER" }

/// Between-missions black market. Loads the canonical (persisted) roster, lets
/// the player spend banked nuyen on gear/cyberware/spells, and saves back so
/// purchases carry into the next mission. Presented as a full-screen cover from
/// mission select. Icons are SF Symbols (no art dependency).
struct ShopView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var stats = MissionStatsStore.shared
    @State private var roster: [Character] = RosterStore.shared.loadCanonical()
    @State private var runnerIdx = 0
    @State private var tab: ShopTab = .cyberware
    @State private var bump = 0           // forces body recompute after a purchase
    @State private var flash: String? = nil
    @State private var bg: UIImage? = nil
    @State private var fixer: UIImage? = nil

    private let gold = Color(hex: "FFCC00")
    private var runner: Character { roster[min(runnerIdx, roster.count - 1)] }

    var body: some View {
        ZStack {
            // Black-market den backdrop (falls back to flat dark if art absent),
            // under a scrim so the menu panels stay readable.
            Color(hex: "0A0A0F").ignoresSafeArea()
            if let bg {
                GeometryReader { geo in
                    Image(uiImage: bg)
                        .resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .overlay(Color.black.opacity(0.58))
                        .overlay(LinearGradient(colors: [.black.opacity(0.35), .clear, .black.opacity(0.75)],
                                                startPoint: .top, endPoint: .bottom))
                }
                .ignoresSafeArea()
            }
            VStack(spacing: 12) {
                header
                runnerSelector
                tabBar
                ScrollView {
                    VStack(spacing: 8) {
                        let _ = bump   // tie body refresh to purchases
                        switch tab {
                        case .cyberware: cyberwareList
                        case .weapons:   weaponsList
                        case .armor:     armorList
                        case .stims:     stimsList
                        case .spells:    spellsList
                        case .fixer:     fixerList
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 24)
                }
            }
            .padding(.top, 8)

            if let f = flash {
                VStack { Spacer()
                    Text(f)
                        .font(.system(size: 13, weight: .black, design: .monospaced))
                        .foregroundColor(.black).padding(.horizontal, 16).padding(.vertical, 9)
                        .background(Capsule().fill(gold))
                        .padding(.bottom, 30)
                }
                .allowsHitTesting(false)
            }
        }
        .overlay(TutorialCoachOverlay())
        .onAppear {
            if bg == nil { bg = loadBossSplashImage("shop_blackmarket") }
            if fixer == nil { fixer = loadBossSplashImage("shop_fixer") }
            MusicManager.shared.playShopMusic()
            // First visit explains the shop / cyberware / spells economy.
            TutorialCoach.shared.enqueue(.blackMarket)
        }
        .onDisappear {
            // Back to the menu theme when leaving the shop.
            MusicManager.shared.playLoop(filename: "title", startOffset: 5)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            // Fixer portrait (transparent bust). Shows only if the art is present.
            if let fixer {
                Image(uiImage: fixer)
                    .resizable().scaledToFill()
                    .frame(width: 54, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(gold.opacity(0.7), lineWidth: 1.5))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("BLACK MARKET")
                    .font(.system(size: 18, weight: .black, design: .monospaced)).tracking(2)
                    .foregroundColor(gold)
                Text("\u{201C}What're you buying, chummer?\u{201D}")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .italic()
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1).minimumScaleFactor(0.8)
                Text("¥\(stats.playerNuyen.formatted())")
                    .font(.system(size: 14, weight: .black, design: .monospaced))
                    .foregroundColor(.white)
            }
            Spacer()
            Button(action: { HapticsManager.shared.back(); dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 26)).foregroundColor(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: Runner selector

    private var runnerSelector: some View {
        HStack(spacing: 6) {
            ForEach(Array(roster.enumerated()), id: \.offset) { i, r in
                Button(action: { HapticsManager.shared.buttonTap(); runnerIdx = i }) {
                    VStack(spacing: 1) {
                        Text(r.name).font(.system(size: 10, weight: .black, design: .monospaced)).lineLimit(1)
                        Text("Lv \(r.level)").font(.system(size: 9, design: .monospaced)).opacity(0.7)
                    }
                    .foregroundColor(i == runnerIdx ? .black : .white.opacity(0.8))
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(i == runnerIdx ? Color(hex: "00FF88") : Color.white.opacity(0.07)))
                }
            }
        }
        .padding(.horizontal, 14)
    }

    // MARK: Tab bar

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(ShopTab.allCases, id: \.self) { t in
                Button(action: { HapticsManager.shared.buttonTap(); tab = t }) {
                    Text(t.rawValue)
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundColor(t == tab ? gold : .white.opacity(0.55))
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(t == tab ? gold.opacity(0.15) : Color.clear))
                }
            }
        }
        .padding(.horizontal, 14)
    }

    // MARK: Item lists

    private var cyberwareList: some View {
        ForEach(CyberwareCatalog.all) { cw in
            let owned = runner.cyberware.contains(cw.id)
            ShopRow(icon: cw.icon, iconKey: "shopicon_\(cw.id)", name: cw.name, blurb: cw.blurb, effect: cyberEffect(cw),
                    cost: cw.cost, state: owned ? .owned("INSTALLED") : .buyable,
                    affordable: stats.playerNuyen >= cw.cost) {
                guard stats.spend(cw.cost) else { return }
                runner.installCyberware(cw)
                commit("INSTALLED \(cw.name.uppercased())")
            }
        }
    }

    private var weaponsList: some View {
        ForEach(ShopCatalog.weapons.indices, id: \.self) { idx in
            let entry = ShopCatalog.weapons[idx]
            let equipped = runner.equippedWeapon?.name == entry.weapon.name
            let owned = equipped || runner.ownedWeaponNames.contains(entry.weapon.name)
            let w = entry.weapon
            ShopRow(icon: entry.icon, iconKey: entry.iconKey, name: w.name, blurb: entry.blurb,
                    effect: "DMG \(w.damage) · ACC \(w.accuracy) · AP \(w.armorPiercing)" + (owned && !equipped ? " · OWNED" : ""),
                    cost: entry.cost,
                    state: equipped ? .owned("EQUIPPED") : (owned ? .equip : .buyable),
                    affordable: stats.playerNuyen >= entry.cost) {
                // Pay once; after that, switching is free. The displaced gun
                // stays owned too (it used to be destroyed — re-buying cost
                // full price).
                if !owned {
                    guard stats.spend(entry.cost) else { return }
                }
                if let current = runner.equippedWeapon, !runner.ownedWeaponNames.contains(current.name) {
                    runner.ownedWeaponNames.append(current.name)
                }
                if !runner.ownedWeaponNames.contains(w.name) {
                    runner.ownedWeaponNames.append(w.name)
                }
                runner.equippedWeapon = w
                commit(owned ? "EQUIPPED \(w.name.uppercased())" : "BOUGHT \(w.name.uppercased())")
            }
        }
    }

    private var armorList: some View {
        ForEach(ShopCatalog.armor.indices, id: \.self) { idx in
            let entry = ShopCatalog.armor[idx]
            let equipped = runner.equippedArmor?.name == entry.armor.name
            let owned = equipped || runner.ownedArmorNames.contains(entry.armor.name)
            let a = entry.armor
            ShopRow(icon: entry.icon, iconKey: entry.iconKey, name: a.name, blurb: entry.blurb,
                    effect: "ARMOR +\(a.armorValue)\(a.spellPenalty != 0 ? " · SPELL \(a.spellPenalty)" : "")" + (owned && !equipped ? " · OWNED" : ""),
                    cost: entry.cost,
                    state: equipped ? .owned("EQUIPPED") : (owned ? .equip : .buyable),
                    affordable: stats.playerNuyen >= entry.cost) {
                // Pay once; after that, switching is free (see weaponsList).
                if !owned {
                    guard stats.spend(entry.cost) else { return }
                }
                if let current = runner.equippedArmor, !runner.ownedArmorNames.contains(current.name) {
                    runner.ownedArmorNames.append(current.name)
                }
                if !runner.ownedArmorNames.contains(a.name) {
                    runner.ownedArmorNames.append(a.name)
                }
                runner.equippedArmor = a
                commit(owned ? "EQUIPPED \(a.name.uppercased())" : "BOUGHT \(a.name.uppercased())")
            }
        }
    }

    private var stimsList: some View {
        ForEach(ShopCatalog.stims.indices, id: \.self) { idx in
            let entry = ShopCatalog.stims[idx]
            // One of each consumable per runner: they now deplete on use
            // (consumeRosterItem), so "carrying one" disables the buy until
            // it's spent — no stacking.
            let carrying = runner.inventory.contains { $0.name == entry.item.name }
            ShopRow(icon: entry.icon, iconKey: entry.iconKey, name: entry.item.name,
                    blurb: entry.item.description,
                    effect: carrying ? "Carrying 1 — use it first" : "Consumable · max 1",
                    cost: entry.cost, state: carrying ? .owned("CARRYING") : .buyable,
                    affordable: stats.playerNuyen >= entry.cost) {
                guard !runner.inventory.contains(where: { $0.name == entry.item.name }) else { return }
                guard stats.spend(entry.cost) else { return }
                runner.inventory.append(entry.item)
                commit("BOUGHT \(entry.item.name.uppercased())")
            }
        }
    }

    @ViewBuilder private var spellsList: some View {
        if runner.archetype != .mage {
            Text("Only the Mage can learn spells.\nSelect \(roster.first(where: { $0.archetype == .mage })?.name ?? "the mage").")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).padding(.top, 30)
        } else {
            ForEach(ShopCatalog.spells.indices, id: \.self) { idx in
                let entry = ShopCatalog.spells[idx]
                let known = runner.purchasedSpells.contains(entry.spell.rawValue)
                ShopRow(icon: entry.spell.icon, iconKey: entry.iconKey, name: entry.spell.displayName, blurb: entry.spell.description,
                        effect: "MANA \(entry.spell.manaCost)", cost: entry.cost,
                        state: known ? .owned("LEARNED") : .buyable,
                        affordable: stats.playerNuyen >= entry.cost) {
                    guard stats.spend(entry.cost) else { return }
                    runner.purchasedSpells.append(entry.spell.rawValue)
                    commit("LEARNED \(entry.spell.displayName.uppercased())")
                }
            }
        }
    }

    /// Fixer services — the RECURRING spend side of the economy. The gear
    /// tabs are a finite buyout (once the roster is kitted the wallet had
    /// nothing left to want); these repeat forever:
    ///  • Heat payoffs close the faction-attention loop surfaced on mission
    ///    select — ¥ buys down the corp/gang heat that drives extra patrols.
    ///  • Combat sim training converts late-game nuyen into runner XP, so a
    ///    fat wallet keeps mattering after the shop is cleaned out.
    @ViewBuilder private var fixerList: some View {
        let _ = bump   // re-read heat after each payoff
        let attention = stats.loadFactionAttention()
        let corp = attention[.corp, default: 0]
        let gang = attention[.gang, default: 0]

        ShopRow(icon: "flame.fill", name: "Corp Payoff",
                blurb: "The fixer greases corporate channels. Patrol postings quietly vanish.",
                effect: corp > 0 ? "CORP HEAT \(corp) → \(corp - 1)" : "CORP HEAT 0 — nothing to bury",
                cost: 6_000, state: corp > 0 ? .buyable : .owned("COLD"),
                affordable: stats.playerNuyen >= 6_000) {
            guard corp > 0, stats.spend(6_000) else { return }
            stats.reduceFactionAttention(.corp)
            commit("CORP HEAT REDUCED")
        }
        ShopRow(icon: "person.3.fill", name: "Gang Payoff",
                blurb: "Street tax. The gangs look the other way on your next run.",
                effect: gang > 0 ? "GANG HEAT \(gang) → \(gang - 1)" : "GANG HEAT 0 — nothing to bury",
                cost: 4_500, state: gang > 0 ? .buyable : .owned("COLD"),
                affordable: stats.playerNuyen >= 4_500) {
            guard gang > 0, stats.spend(4_500) else { return }
            stats.reduceFactionAttention(.gang)
            commit("GANG HEAT REDUCED")
        }
        ShopRow(icon: "figure.martial.arts", name: "Combat Sim Training",
                blurb: "Full-immersion sim time for \(runner.name). Experience, minus the scar tissue.",
                effect: "+40 XP · \(runner.name.uppercased()) LVL \(runner.level)",
                cost: 8_000, state: .buyable,
                affordable: stats.playerNuyen >= 8_000) {
            guard stats.spend(8_000) else { return }
            let leveled = runner.gainXP(40)
            commit(leveled ? "\(runner.name.uppercased()) LEVELED UP!" : "+40 XP · \(runner.name.uppercased())")
        }
    }

    private func cyberEffect(_ cw: Cyberware) -> String {
        var p: [String] = []
        if cw.accuracyDice > 0 { p.append("+\(cw.accuracyDice) ACC") }
        if cw.defenseDice > 0  { p.append("+\(cw.defenseDice) DEF") }
        if cw.soak > 0         { p.append("+\(cw.soak) soak") }
        if cw.initiative > 0   { p.append("+\(cw.initiative) init") }
        if cw.maxHP > 0        { p.append("+\(cw.maxHP) HP") }
        return p.joined(separator: " · ")
    }

    /// Apply a purchase: persist the roster, flash feedback, refresh the body.
    private func commit(_ message: String) {
        RosterStore.shared.save(roster)
        HapticsManager.shared.levelUp()
        // Audible "transaction went through" cue — pairs with the haptic so a
        // purchase (gear / cyberware / learned spell) reads as confirmed.
        SFXManager.shared.play("ui_unlock", volume: 0.6)
        bump += 1
        flash = message
        let snap = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if flash == snap { flash = nil }
        }
    }
}

/// Grouped-thousands formatting for nuyen amounts (briefing / victory / debrief).
private func srYen(_ n: Int) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    return f.string(from: NSNumber(value: n)) ?? "\(n)"
}

/// One purchasable row in the shop.
private struct ShopRow: View {
    enum State { case buyable, owned(String), equip }
    let icon: String
    var iconKey: String? = nil   // custom art key (Sprites/frames/<key>.png); falls back to SF Symbol
    let name: String
    let blurb: String
    let effect: String
    let cost: Int
    let state: State
    let affordable: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let key = iconKey, let img = loadShopIcon(key) {
                    Image(uiImage: img).resizable().scaledToFit()
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 20))
                        .foregroundColor(Color(hex: "00FFCC"))
                }
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .black, design: .monospaced)).foregroundColor(.white)
                Text(blurb).font(.system(size: 9, design: .monospaced)).foregroundColor(.white.opacity(0.55)).lineLimit(2)
                if !effect.isEmpty {
                    Text(effect).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(Color(hex: "00FF88"))
                }
            }
            Spacer()
            buyButton
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.04))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.08), lineWidth: 1)))
    }

    @ViewBuilder private var buyButton: some View {
        switch state {
        case .owned(let label):
            Text(label)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundColor(Color(hex: "00FF88"))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Capsule().stroke(Color(hex: "00FF88").opacity(0.5), lineWidth: 1))
        case .buyable:
            Button(action: action) {
                Text("¥\(cost.formatted())")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundColor(affordable ? .black : .white.opacity(0.4))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Capsule().fill(affordable ? Color(hex: "FFCC00") : Color.white.opacity(0.08)))
            }
            .disabled(!affordable)
        case .equip:
            // Already paid for — switching gear is free.
            Button(action: action) {
                Text("EQUIP")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundColor(.black)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Capsule().fill(Color(hex: "00FF88")))
            }
        }
    }
}

@main
struct HexwireApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Content View

struct ContentView: View {
    @StateObject private var phaseManager = PhaseManager()
    @ObservedObject private var gameState = GameState.shared
    @State private var showLaunchSplash = true
    @State private var showMinigameExitConfirm = false
    // Asset-preload gating for the launch splash. We warm the entire sprite
    // cache (all enemy/player frames + background flood-fill) on a background
    // thread DURING the splash, so the one-time texture cost is paid up front
    // behind "INITIALIZING…" instead of stalling the first Accept Contract.
    @State private var assetsReady = false
    @State private var minSplashElapsed = false

    private func dismissSplashIfReady() {
        guard assetsReady && minSplashElapsed else { return }
        withAnimation(.easeOut(duration: 0.6)) { showLaunchSplash = false }
    }

    /// The 4 solo interstitial mini-games (M2.5/M3.5/M4.5/M5.5). Each has a
    /// `.returnToTitle → .missionSelect` abort path, so a single top-level
    /// EXIT button can bail the player out of any of them.
    private var isMinigamePhase: Bool {
        switch phaseManager.currentPhase {
        case .hoverbikeChase, .basementBrawl, .mirrorline, .coldTrace: return true
        default: return false
        }
    }

    var body: some View {
        ZStack {
            Color(hex: "0D0D0D").ignoresSafeArea()

            // Launch splash — Netrunner full-screen image + Zero State studio
            // logo overlaid on top for first ~3 seconds. Logo sits low on the
            // screen so it doesn't fight the splash composition.
            if showLaunchSplash {
                ZStack {
                    Image("launch_screen")
                        .resizable()
                        .scaledToFill()
                        .ignoresSafeArea()
                    VStack {
                        Spacer()
                        Image("zero_state_logo")
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 240)
                            .opacity(0.92)
                        Text(assetsReady ? "READY" : "INITIALIZING…")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .tracking(3)
                            .foregroundColor(Color(hex: "00FF88").opacity(0.85))
                            .padding(.top, 14)
                            .padding(.bottom, 46)
                    }
                    .ignoresSafeArea(edges: .top)
                }
                .transition(.opacity)
                .zIndex(100)
                .onAppear {
                    // Warm the sprite cache off the main thread so the heavy
                    // first-load texture work (decode + flood-fill of every
                    // enemy/player frame) happens here, behind the splash —
                    // not as a silent ~freeze on the first mission load.
                    DispatchQueue.global(qos: .userInitiated).async {
                        SpriteManager.shared.preloadAll()
                        DispatchQueue.main.async {
                            assetsReady = true
                            dismissSplashIfReady()
                        }
                    }
                    // Minimum branding time so the splash never just blinks past.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        minSplashElapsed = true
                        dismissSplashIfReady()
                    }
                }
            }

            switch phaseManager.currentPhase {
            case .title:
                TitleView(manager: phaseManager)
            case .prologue:
                NeonLotusScene(manager: phaseManager)
            case .missionSelect:
                MissionSelectView(manager: phaseManager)
            case .briefing:
                BriefingView(manager: phaseManager)
            case .combat:
                CombatView(manager: phaseManager, gameState: gameState)
            case .missionIntro:
                MissionIntroScene(manager: phaseManager)
            case .missionOutro:
                MissionOutroScene(manager: phaseManager)
            case .dropIntro:
                DropIntroScene(manager: phaseManager)
            case .hoverbikeChase:
                HoverbikeChaseScene(manager: phaseManager)
            case .basementBrawl:
                BasementBrawlScene(manager: phaseManager)
            case .mirrorline:
                MirrorlineScene(manager: phaseManager)
            case .coldTrace:
                ColdTraceScene(manager: phaseManager)
            case .debrief:
                DebriefView(manager: phaseManager)
            case .gameEnding:
                EndingScene(manager: phaseManager)
            }

            // Universal EXIT for the solo mini-games — players were getting
            // stuck with no way back to the menu mid-run.
            if isMinigamePhase {
                VStack {
                    HStack {
                        Button(action: {
                            HapticsManager.shared.back()
                            showMinigameExitConfirm = true
                        }) {
                            HStack(spacing: 5) {
                                Image(systemName: "xmark")
                                Text("EXIT")
                            }
                            .font(.system(size: 13, weight: .heavy, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Capsule().fill(Color.black.opacity(0.55)))
                            .overlay(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 1))
                        }
                        Spacer()
                    }
                    Spacer()
                }
                .padding(.top, 8).padding(.leading, 12)
                .zIndex(200)
                .confirmationDialog("Quit to mission select? Progress in this run will be lost.",
                                    isPresented: $showMinigameExitConfirm, titleVisibility: .visible) {
                    Button("Quit to Menu", role: .destructive) {
                        _ = phaseManager.transition(to: .returnToTitle)
                    }
                    Button("Keep Playing", role: .cancel) {}
                }
            }
        }
        .onAppear(perform: applyDebugLaunchOverrideIfNeeded)
        .onChange(of: phaseManager.currentPhase) { _, newPhase in
            // Music + phase-stinger SFX routing per game phase.
            switch newPhase {
            case .title, .missionSelect:
                MusicManager.shared.playLoop(filename: "title", startOffset: 5)
                // Clear any ambient loop from the previous phase (chase
                // engine hum, M1 rain, etc.) so it doesn't bleed into menus.
                SFXManager.shared.stopAllLoops()
            case .prologue:
                // Prologue gets its own moody club track. Falls back to the
                // title music if the file hasn't shipped yet — no silence.
                MusicManager.shared.playLoop(filename: "prologue_lotus", startOffset: 0)
            case .missionIntro:
                // Per-mission cutscene music. Each mission can have its own
                // intro track named `intro_<missionId>_music.mp3`. Some
                // missions explicitly use a different track instead — see
                // the trackName switch.
                if let mid = phaseManager.selectedMissionId {
                    // Track name — defaults to convention, but per-mission
                    // overrides are allowed for missions that intentionally
                    // share a track with another phase (M6 reuses the
                    // title-screen track for thematic weight).
                    let trackName: String = {
                        switch mid {
                        case "Mission006":
                            // M6 finale uses the title-screen music for
                            // narrative gravitas — closing the loop.
                            return "title"
                        default:
                            // e.g. Mission001 → "intro_m1_music"
                            let suffix = mid.replacingOccurrences(of: "Mission00", with: "m")
                            return "intro_\(suffix)_music"
                        }
                    }()
                    // Per-mission startOffset — some tracks have slow
                    // intros we want to skip past for instant impact.
                    let startOffset: TimeInterval = {
                        switch mid {
                        case "Mission002":    return 10   // Neon Dystopia — skip intro
                        case "Mission002_5":  return 5    // Witch's Heartbeat — skip slow ramp
                        case "Mission004":    return 21   // Neon Dystopia (v2) — skip intro
                        case "Mission005":    return 12   // Grind State — skip slow intro
                        case "Mission005_5":  return 12   // Detachment Protocol — skip slow ambient ramp
                        case "Mission006":    return 5    // Title — skip into the meat of the track
                        default:              return 0
                        }
                    }()
                    // M1 intro loops the first 52s of the new track (skips its
                    // outro) and keeps looping for the whole intro.
                    let loopEnd: TimeInterval? = (mid == "Mission001") ? 52 : nil
                    MusicManager.shared.playLoop(filename: trackName, startOffset: startOffset, loopEnd: loopEnd)
                } else {
                    MusicManager.shared.playLoop(filename: "briefing", startOffset: 3)
                }
            case .dropIntro:
                // M3.5 cutscene — moodier pre-action track. Skip past the
                // slow intro 20s so the energy hits when the cutscene loads.
                MusicManager.shared.playLoop(filename: "drop_intro", startOffset: 20)
            case .hoverbikeChase:
                // M3.5 chase mission. Action darksynth track. Falls back if
                // the file isn't shipped — engine SFX in code will still play.
                MusicManager.shared.playLoop(filename: "chase_drop", startOffset: 0)
                // Engine hum ambient — sits at low volume under the music
                // and chase SFX. High-passed at 150Hz at the source so its
                // sub-bass doesn't clash with the music's bass line.
                // Cumulative -40% with chase SFX → 0.18 × 0.595 ≈ 0.107.
                SFXManager.shared.stopAllLoops()
                SFXManager.shared.playLoop("chase_engine_loop", volume: 0.107)
            case .basementBrawl:
                // M4.5 brawl gameplay track — industrial darksynth fight music.
                SFXManager.shared.stopAllLoops()
                MusicManager.shared.playLoop(filename: "m4_5_brawl", startOffset: 0)
            case .mirrorline:
                // M2.5 mirrorline — meditation-under-threat track. Start 5s in
                // to skip the slow drone-only ramp and land on the heartbeat.
                SFXManager.shared.stopAllLoops()
                MusicManager.shared.playLoop(filename: "m2_5_mirrorline", startOffset: 5)
            case .coldTrace:
                // M5.5 cold trace — "Cipher's Mandate" gameplay track.
                // No intro ramp, kicks in immediately — start at 0 per user direction.
                SFXManager.shared.stopAllLoops()
                MusicManager.shared.playLoop(filename: "m5_5_coldtrace", startOffset: 0)
            case .briefing:
                MusicManager.shared.playLoop(filename: "briefing", startOffset: 3)
            case .combat:
                if let mid = phaseManager.selectedMissionId {
                    MusicManager.shared.playMissionMusic(missionId: mid)
                    // Per-mission ambient bed. Volume is tiny (~0.20) so it
                    // sits well under the music — just texture, never
                    // foreground. M1 = urban rain, M3 / M6 = corp server hum.
                    SFXManager.shared.stopAllLoops()
                    switch mid {
                    case "Mission001":
                        SFXManager.shared.playLoop("ambient_rain", volume: 0.153)
                    case "Mission003":
                        SFXManager.shared.playLoop("ambient_server_hum", volume: 0.18)
                    // M6 ambient hum was persisting past the mission and into
                    // home/menu screens — yanked entirely (was hard to fully
                    // tear down on the bug-laden defeat path anyway).
                    default:
                        break
                    }
                }
                // Mission-start sting layered above the mission soundtrack.
                SFXManager.shared.play("mission_start", volume: 0.85)
            case .missionOutro:
                // Post-combat VN scene. Stop mission combat music + ambient
                // beds, then bring the mission's INTRO track back in. Reusing
                // the intro music as the outro music is intentional narrative
                // bookending — the player hears the same theme that opened
                // the run as it closes, giving each mission a sonic arc.
                // Track resolution mirrors `.missionIntro` exactly.
                SFXManager.shared.stopAllLoops()
                if let mid = phaseManager.selectedMissionId {
                    let trackName: String = {
                        switch mid {
                        case "Mission003_5":
                            // M3.5 chase outro reuses the SAME track as its
                            // intro (drop_intro). Per-design — the chase has
                            // no separate intro_m3_5_music file; the cutscene
                            // music and the outro music are the same cue.
                            return "drop_intro"
                        case "Mission006":
                            // M6 finale reuses the title track for closure
                            // (intentional thematic loop — same track that
                            // played over the prologue and M6 intro).
                            return "title"
                        default:
                            // e.g. Mission001 → "intro_m1_music"
                            let suffix = mid.replacingOccurrences(of: "Mission00", with: "m")
                            return "intro_\(suffix)_music"
                        }
                    }()
                    // Per-mission startOffset — same offsets as intro so the
                    // outro hits the same beat of the track. The outro is the
                    // intro's emotional echo, not a different cut.
                    let startOffset: TimeInterval = {
                        switch mid {
                        case "Mission002":    return 10   // Neon Dystopia — skip intro
                        case "Mission002_5":  return 5    // Witch's Heartbeat — skip slow ramp
                        case "Mission003_5":  return 20   // drop_intro — same offset as the dropIntro cutscene
                        case "Mission004":    return 21   // Neon Dystopia v2 — skip intro
                        case "Mission005":    return 12   // Grind State — skip slow intro
                        case "Mission005_5":  return 12   // Detachment Protocol — skip slow ambient ramp
                        case "Mission006":    return 5    // Title — skip into the meat
                        default:              return 0
                        }
                    }()
                    MusicManager.shared.playLoop(filename: trackName, startOffset: startOffset)
                } else {
                    // Fallback if mission ID went missing (shouldn't happen,
                    // but never let an outro scene play in dead silence).
                    MusicManager.shared.playLoop(filename: "briefing", startOffset: 3)
                }
                // Victory sting plays HERE (moved from .debrief) so the
                // emotional beat lands at the moment of resolution, not
                // after the dialog has been read.
                SFXManager.shared.play("mission_victory")
            case .debrief:
                MusicManager.shared.stop()
                SFXManager.shared.stopAllLoops()
                // Defeat sting on debrief — victory sting now plays earlier
                // on .missionOutro so it lands at the resolution moment.
                //
                // IMPORTANT: use `manager.combatWon` (PhaseManager's own
                // copy, set from the `.endCombat(won:)` payload and held
                // through subsequent transitions) — NOT `gameState.combatWon`.
                // The CombatEndOverlay's `viewDebrief()` nils out the
                // gameState copy BEFORE firing the transition, so reading
                // it here always sees `nil` and `nil != true` evaluates to
                // true. Result: the defeat sound was firing on EVERY
                // debrief — including the CONTRACT FULFILLED victory screen.
                // Check positively for `== false` so `nil` is not "defeat."
                if phaseManager.combatWon == false {
                    SFXManager.shared.play("mission_defeat")
                }
            case .gameEnding:
                // Game-end epilogue. Bespoke ending theme — full song built
                // for this scene. Plays once over the three-beat VN closer
                // and the FIN card. Loops in case the player lingers; in
                // practice the scene is shorter than the track.
                SFXManager.shared.stopAllLoops()
                MusicManager.shared.playLoop(filename: "ending_theme", startOffset: 0)
            }
        }
        .onChange(of: gameState.showMatrixMiniGame) { _, showing in
            // Silence the level audio bed (mission music + ambient loops like
            // rain / server hum / mech alarms) while a terminal mini-game is
            // open so its chiptune layer plays alone. Restored on close.
            if showing {
                MusicManager.shared.duck()
                SFXManager.shared.pauseAllLoops()
            } else {
                MusicManager.shared.unduck()
                SFXManager.shared.resumeAllLoops()
            }
        }
        .onAppear {
            // Touch the SFX singleton so its notification observers wire up
            // before the first gunfire / hit / spell event fires.
            _ = SFXManager.shared
            // Start title music IMMEDIATELY so it plays under the launch
            // splash. Skip the song's slow pre-roll by jumping 5s in.
            if phaseManager.currentPhase == .title {
                MusicManager.shared.playLoop(filename: "title", startOffset: 5)
            }
        }
    }

    private func applyDebugLaunchOverrideIfNeeded() {
        #if DEBUG
        guard phaseManager.currentPhase == .title else { return }
        guard let missionId = ProcessInfo.processInfo.environment["SR_AUTOSTART_MISSION_ID"] else { return }

        _ = phaseManager.transition(to: .startGame)
        _ = phaseManager.transition(to: .selectMission(missionId))
        // selectMission now routes through the mission-intro VN; the debug
        // autostart predates that phase and stalled on the cutscene waiting
        // for a tap. Skip the intro (and the briefing) explicitly.
        _ = phaseManager.transition(to: .finishMissionIntro)
        _ = GameState.shared.prepareMissionForCombat(named: missionId)
        _ = phaseManager.transition(to: .beginMission)
        #endif
    }
}

// MARK: - Matrix Rain Effect

struct MatrixRainView: View {
    @State private var characters: [MatrixChar] = []
    @State private var timer: Timer?

    let columns: Int = 8

    struct MatrixChar {
        var x: CGFloat
        var y: CGFloat
        var char: String
        var opacity: Double
    }

    var body: some View {
        Canvas { context, _ in
            for char in characters {
                let text = Text(char.char)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "00FF88").opacity(char.opacity))

                context.draw(text, at: CGPoint(x: char.x, y: char.y))
            }
        }
        .ignoresSafeArea()
        .onAppear {
            initializeCharacters()
            startAnimation()
        }
        .onDisappear {
            timer?.invalidate()
        }
    }

    private func initializeCharacters() {
        let hexChars = ["0", "1", "A", "F", "3", "9", "C", "E"]
        let katakana = ["ヲ", "ァ", "ィ", "ウ", "ェ", "オ", "カ", "キ"]
        let allChars = hexChars + katakana

        characters = (0..<columns).map { i in
            MatrixChar(
                x: CGFloat(i) * (UIScreen.main.bounds.width / CGFloat(columns)),
                y: CGFloat.random(in: -100...0),
                char: allChars.randomElement() ?? "0",
                opacity: Double.random(in: 0.3...0.8)
            )
        }
    }

    private func startAnimation() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            for i in 0..<characters.count {
                characters[i].y += 2
                if characters[i].y > UIScreen.main.bounds.height {
                    characters[i].y = -20
                    characters[i].char = ["0", "1", "A", "F", "3", "9", "C", "E", "ヲ", "ァ", "ィ", "ウ"].randomElement() ?? "0"
                }
                characters[i].opacity = Double.random(in: 0.2...0.8)
            }
        }
    }
}

// MARK: - Title View

/// Menu-button frame that keeps the iPhone size on compact width and scales
/// up on iPad (regular width). Drop-in for fixed `.frame(width:height:)` on
/// menu/overlay buttons so phone-first layouts read right on iPad.
private struct MenuButtonSize: ViewModifier {
    @Environment(\.horizontalSizeClass) private var h
    let phone: CGSize
    let pad: CGSize
    func body(content: Content) -> some View {
        let s = (h == .regular) ? pad : phone
        return content.frame(width: s.width, height: s.height)
    }
}
extension View {
    func menuButtonSize(phone: CGSize, pad: CGSize) -> some View {
        modifier(MenuButtonSize(phone: phone, pad: pad))
    }
}

struct TitleView: View {
    @ObservedObject var manager: PhaseManager
    // Portrait app → iPhone reads as compact width, iPad as regular. Scale up
    // menu elements on iPad only so they don't float tiny in the wide 4:3
    // screen; iPhone layout is untouched.
    @Environment(\.horizontalSizeClass) private var hSize
    private var isPad: Bool { hSize == .regular }
    private var btnW: CGFloat { isPad ? 340 : 220 }
    private var btnH: CGFloat { isPad ? 60 : 50 }
    @State private var showResetConfirm = false
    @State private var showRoster = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Image("title_splash")
                .resizable()
                // iPhone (tall) fills+crops as designed. iPad is squarer, so
                // filling would crop the HEXWIRE wordmark off the top by an
                // amount that varies per iPad model — instead FIT the whole
                // poster (never cropped) and nudge it below the status bar.
                // The dark night art blends into the letterbox edges.
                .aspectRatio(contentMode: isPad ? .fit : .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, isPad ? 50 : 0)
                .clipped()
                .offset(y: isPad ? 0 : 36)

            LinearGradient(
                colors: [
                    Color.black.opacity(0.35),
                    Color.black.opacity(0.08),
                    Color.black.opacity(0.55)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .offset(y: 36)
            .ignoresSafeArea()

            // Extra bright text layer — clear path so text pops
            Color.black.opacity(0.15)
                .offset(y: 36)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer().frame(minHeight: 60)

                VStack(spacing: 16) {
                    Button(action: {
                        HapticsManager.shared.selectAffirm()
                        _ = manager.transition(to: .startGame)
                    }) {
                        Text("NEW RUN")
                            .font(.headline)
                            .foregroundColor(.black)
                            .frame(width: btnW, height: btnH)
                            .background(Color(hex: "00FF88"))
                            .cornerRadius(8)
                            .shadow(color: Color(hex: "00FF88").opacity(0.5), radius: 8)
                    }
                    Button(action: {
                        HapticsManager.shared.selectAffirm()
                        _ = manager.transition(to: .viewPrologue)
                    }) {
                        Text("PROLOGUE")
                            .font(.headline)
                            .foregroundColor(Color(hex: "FF00AA"))
                            .frame(width: btnW, height: btnH)
                            .background(Color.black.opacity(0.35))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color(hex: "FF00AA").opacity(0.8), lineWidth: 2)
                            )
                            .shadow(color: Color(hex: "FF00AA").opacity(0.35), radius: 6)
                    }
                    // TEAM lives on the SELECT RUN bar instead — it's the screen
                    // where roster state actually matters, and having it in both
                    // places just doubled up the same `showRoster` action.
                    Button(action: { HapticsManager.shared.buttonTap(); showSettings = true }) {
                        Text("SETTINGS")
                            .font(.headline)
                            .foregroundColor(Color(hex: "B080FF"))
                            .frame(width: btnW, height: btnH)
                            .background(Color.black.opacity(0.35))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(hex: "B080FF").opacity(0.8), lineWidth: 2))
                            .shadow(color: Color(hex: "B080FF").opacity(0.35), radius: 6)
                    }
                    // Fresh start — wipe all saved progression and begin anew.
                    Button(action: { HapticsManager.shared.back(); showResetConfirm = true }) {
                        Text("FRESH START")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .tracking(1)
                            .foregroundColor(Color(hex: "FF4A4A").opacity(0.85))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(hex: "FF4A4A").opacity(0.5), lineWidth: 1))
                    }
                    .padding(.top, 2)
                }
                .padding(.bottom, 12)
                .confirmationDialog("Wipe all progress?", isPresented: $showResetConfirm, titleVisibility: .visible) {
                    Button("Erase Everything", role: .destructive) {
                        RosterStore.shared.reset()        // runners → Level 1 defaults
                        NGPlusStore.shared.reset()         // New Game+ → 0
                        MissionStatsStore.shared.resetAll() // ranks + ¥0
                        MissionStatsStore.shared.resetFactionAttention()
                        // Clear the LIVE in-memory campaign state too — the
                        // stores reset on disk, but the TEAM/briefing screens
                        // read GameState.shared.playerTeam directly, so a
                        // leveled team from earlier THIS session survived
                        // Fresh Start until relaunch (the "not working" bug).
                        GameState.shared.playerTeam = Character.allRunners
                        GameState.shared.factionAttention = [.corp: 0, .gang: 0, .unknown: 0]
                        TutorialCoach.shared.resetAll()     // tutorials replay
                        HapticsManager.shared.selectAffirm()
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("Resets all runners to Level 1, nuyen to ¥0, mission ranks, gear, and New Game+. This can't be undone.")
                }
                .sheet(isPresented: $showSettings) { SettingsSheet() }
                .onAppear { PlayerSettings.applyAll() }
                .fullScreenCover(isPresented: $showRoster) {
                    RosterView(onDismiss: { showRoster = false })
                }

                VStack(spacing: 8) {
                    // (Tagline "FOUR RUNNERS · ONE WIRE · NO WITNESSES" lives
                    // in the title_splash hero art directly under the HEXWIRE
                    // wordmark — duplicating it here as a Text shipped two
                    // copies stacked vertically on the screen. Removed
                    // 2026-05-19. If the splash art ever loses the tagline,
                    // reinstate the Text version below the buttons.)
                    Text("v0.1 // HEXWIRE PROTOTYPE")
                        .font(.system(size: 10, weight: .light, design: .monospaced))
                        .foregroundColor(Color(hex: "00FF88").opacity(0.85))
                        .tracking(1)
                        .shadow(color: Color(hex: "00FF88").opacity(0.4), radius: 3)
                    Text("AN ORIGINAL CYBERPUNK TACTICS GAME · NOT AFFILIATED WITH ANY TABLETOP PROPERTY")
                        .font(.system(size: 8, weight: .light, design: .monospaced))
                        .foregroundColor(Color(hex: "00FF88").opacity(0.55))
                        .tracking(1)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)

                    // Zero State studio credit — small logo + tagline at the
                    // bottom of the title menu so the studio mark is present
                    // but doesn't fight the game's hero art / buttons.
                    Image("zero_state_logo")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 140)
                        .opacity(0.78)
                        .padding(.top, 6)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.black.opacity(0.28))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color(hex: "00FF88").opacity(0.25), lineWidth: 1)
                        )
                )
            }
            .padding(24)
        }
    }
}

// MARK: - Mission Select View

struct MissionSelectView: View {
    #if DEBUG
    /// Unlocks every mission for direct testing. DEBUG-only by construction —
    /// Release compiles the whole check out, so progression is always correct
    /// in a shipped build no matter what this is set to.
    static let devUnlockAllMissions = true
    #endif

    @ObservedObject var manager: PhaseManager
    @ObservedObject private var stats = MissionStatsStore.shared
    @ObservedObject private var contracts = ContractStore.shared
    @State private var showShop = false
    @State private var showRoster = false
    @State private var showRecords = false

    /// Mission roster. `isChase=true` denotes a side-scrolling chase mission
    /// (M3.5 "The Drop") that routes through a different phase than the
    /// standard tactical missions. All other entries use the normal
    /// selectMission → briefing → combat flow.
    private let missions: [(id: String, title: String, desc: String, risk: String, badge: String?, isChase: Bool)] = [
        ("Mission001",   "The Extraction",    "Corp facility east side. Guards on patrol, drone incoming. Reach the north exit.", "EASY",     "INTRO",  false),
        ("Mission002",   "Ghost Protocol",    "Server farm locked by rogue AI. Drone swarms on every floor. Bring firepower.",        "HIGH",     nil,      false),
        ("Mission002_5", "Mirrorline",        "Whatever was inside the AGI didn't fully die. Sable projects astrally to chase the echo. Trace sigils to banish spirits. Bring back the Akashic Fragment.", "HARD", "ASTRAL", true),
        ("Mission003",   "The Mage's Lair",   "Blood mage Sato + his hired guns. Kill the mage and his true form rises — drop the boss to claim the grimoire.",   "HARD",     "BOSS",   false),
        ("Mission003_5", "The Drop",          "Hoverbike chase down the elevated highway. Corp drones in pursuit. Ditch the heat — survive to the safehouse.", "HIGH", "CHASE", true),
        ("Mission004",   "Dead Man's Switch", "Aztechnology HQ. Grab the whistleblower's data, then put down corp enforcer Vera Koss before the rooftop locks down.", "EXTREME",  "BOSS",   false),
        ("Mission004_5", "Basement Brawl",    "Drachenwerk middleman runs a fight club under his nightclub. Raze goes in solo. Parry, dodge, execute. Bring back the MEKTON file.", "HARD", "DUEL", true),
        ("Mission005",   "Mekton Blues",      "Drachenwerk industrial complex. Two elites, drone corridor, and a field medic.",      "EXTREME",  "BOSS",   false),
        ("Mission005_5", "Cold Trace",        "The Akashic Fragment isn't static data — it's a live Drachenwerk matrix entity. Cipher jacks in solo to read it from the inside. Triage ICE before the trace tags her deck.", "HARD", "DECK", true),
        ("Mission006",   "Ghost Signal",      "Caelum AI black-budget lab. Six floors deep. Hack the core, beat the countertrace.",  "EXTREME",  "FINALE", false)
    ]

    var body: some View {
        ZStack {
            // (Zero State studio sigil now renders INLINE to the left of
            // the SELECT RUN title — see HStack below. Placing the mark
            // beside the title makes it part of the title chrome instead
            // of a faint ornament floating above. Larger + higher opacity
            // than the previous header-crest treatment so it actually
            // reads at glance.)

        VStack(spacing: 24) {
            HStack(spacing: 10) {
                // EXIT back to the main title screen.
                Button(action: { HapticsManager.shared.back(); _ = manager.transition(to: .returnToTitle) }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundColor(Color(hex: "00FF88"))
                        .padding(8)
                        .background(Circle().stroke(Color(hex: "00FF88").opacity(0.4), lineWidth: 1))
                }
                .accessibilityIdentifier("exit_to_title_button")
                Image("zero_state_mark_2")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .opacity(0.95)
                Text("SELECT RUN")
                    .font(.system(size: 20, weight: .black))
                    .foregroundColor(Color(hex: "00FF88"))
                    .tracking(3)
                Spacer()
                // ROSTER — view runner levels / stats / equipment.
                Button(action: { HapticsManager.shared.buttonTap(); showRoster = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "person.2.fill").font(.system(size: 12, weight: .bold))
                        Text("TEAM").font(.system(size: 12, weight: .black, design: .monospaced)).tracking(1)
                    }
                    .foregroundColor(Color(hex: "00D4FF"))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Capsule().stroke(Color(hex: "00D4FF").opacity(0.5), lineWidth: 1))
                }
                .accessibilityIdentifier("view_roster_button")
            }

            // New Game+ banner — players had no idea the campaign escalated.
            if NGPlusStore.shared.tier > 0 {
                let t = NGPlusStore.shared.tier
                Text("◆ NEW GAME+\(t) — enemies +\(Int(NGPlusStore.shared.hpMultiplier * 100 - 100))% HP · +\(t) dmg · +\(t)/room")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundColor(Color(hex: "FF4466"))
                    .tracking(1)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color(hex: "FF4466").opacity(0.14))
                        .overlay(Capsule().stroke(Color(hex: "FF4466").opacity(0.5), lineWidth: 1)))
            }

            // Cumulative progress header — total best score across completed missions.
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("WALLET")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(hex: "FFCC00").opacity(0.75))
                        .tracking(2)
                    Text("¥\(stats.playerNuyen.formatted())")
                        .font(.system(size: 17, weight: .black, design: .monospaced))
                        .foregroundColor(Color(hex: "FFCC00"))
                }
                Spacer()
                VStack(alignment: .center, spacing: 2) {
                    Text("SCORE")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(hex: "00FFCC").opacity(0.7))
                        .tracking(2)
                    Text("\(stats.totalScore)")
                        .font(.system(size: 17, weight: .black, design: .monospaced))
                        .foregroundColor(Color(hex: "00FFCC"))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("RUNS")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(hex: "00FF88").opacity(0.7))
                        .tracking(2)
                    Text("\(stats.missionsCompleted) / \(missions.count)")
                        .font(.system(size: 17, weight: .black, design: .monospaced))
                        .foregroundColor(Color(hex: "00FF88"))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.35))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(hex: "00FFCC").opacity(0.3), lineWidth: 1)
                    )
            )

            // Faction heat — corp/gang attention has driven spawns since the
            // consequence layer shipped (extra patrols at corp 1+, tighter
            // ambushes from gangs) but the only readout was buried in the
            // combat log, so the extra enemies read as random difficulty.
            // Surfacing it here closes the loop: play clean (trace 0) to cool
            // off, or lean into a hot run for the risk-pay multiplier.
            factionHeatRow

            // Black-market shop + records board, side by side.
            HStack(spacing: 8) {
                Button(action: { HapticsManager.shared.buttonTap(); showShop = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: "cart.fill")
                        Text("BLACK MARKET")
                            .font(.system(size: 14, weight: .black, design: .monospaced))
                            .tracking(2)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .foregroundColor(Color(hex: "FFCC00"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Color(hex: "FFCC00").opacity(0.10))
                            .overlay(RoundedRectangle(cornerRadius: 9)
                                .stroke(Color(hex: "FFCC00").opacity(0.6), lineWidth: 1.2))
                    )
                }
                // Achievements/records board — evaluated live from persisted
                // stats, so it needs no unlock plumbing of its own.
                Button(action: { HapticsManager.shared.buttonTap(); showRecords = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: "rosette")
                        Text("RECORDS")
                            .font(.system(size: 14, weight: .black, design: .monospaced))
                            .tracking(2)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .foregroundColor(Color(hex: "00FFCC"))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Color(hex: "00FFCC").opacity(0.10))
                            .overlay(RoundedRectangle(cornerRadius: 9)
                                .stroke(Color(hex: "00FFCC").opacity(0.6), lineWidth: 1.2))
                    )
                }
            }
            .padding(.horizontal, 2)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(Array(missions.enumerated()), id: \.element.id) { index, mission in
                        let record = stats.record(for: mission.id)
                        // Number cards by their narrative slot, not their
                        // array index. Tactical missions use sequential
                        // numbering (counting only non-chase entries before
                        // them); the chase mission gets a fractional label
                        // (e.g. "3.5") so its placement reads correctly.
                        let cardNumber: String = {
                            if mission.isChase {
                                let priorTactical = missions.prefix(index).filter { !$0.isChase }.count
                                return "\(priorTactical).5"
                            } else {
                                let priorTactical = missions.prefix(index).filter { !$0.isChase }.count
                                return String(format: "%02d", priorTactical + 1)
                            }
                        }()
                        // Mission unlock progression:
                        //   • M1 always unlocked.
                        //   • Any mission already completed stays unlocked
                        //     (grandfathered access so replays work + so
                        //     existing player progress isn't gated by a
                        //     newly-added lock rule).
                        //   • Otherwise: tactical missions unlock when the
                        //     PREVIOUS tactical mission has been completed
                        //     (the chase mission is optional and does NOT
                        //     gate M4). Chase unlocks when M3 is completed.
                        let isLocked: Bool = {
                            // DEV TEST TOGGLE: unlock every mission for direct
                            // testing. Compiled out of Release entirely, so a
                            // release candidate CANNOT ship with progression
                            // disabled — this used to be a plain `let ... = true`
                            // that a human had to remember to flip before
                            // cutting a build (a standing WP10 ship blocker).
                            // Debug builds stay unlocked for playtesting.
                            #if DEBUG
                            if Self.devUnlockAllMissions { return false }
                            #endif
                            guard index > 0 else { return false }
                            if record.completed { return false }   // already beaten = always replayable
                            let prevTactical = missions.prefix(index).reversed().first { !$0.isChase }
                            guard let prev = prevTactical else { return false }
                            return !stats.record(for: prev.id).completed
                        }()
                        MissionCard(
                            id: mission.id,
                            number: cardNumber,
                            title: mission.title,
                            description: mission.desc,
                            risk: mission.risk,
                            badge: mission.badge,
                            isLocked: isLocked,
                            isCompleted: record.completed,
                            bestScore: record.bestScore,
                            bestMiniGameScore: record.bestMiniGameScore,
                            onSelect: {
                                guard !isLocked else {
                                    HapticsManager.shared.error()
                                    return
                                }
                                HapticsManager.shared.selectAffirm()
                                // M3.5 The Drop has its own dedicated pre-chase
                                // VN (`.dropIntro`) — fired explicitly here.
                                // M4.5 Basement Brawl reuses the standard
                                // mission-intro VN infrastructure, so it
                                // routes through `.selectMission` like the
                                // tactical missions and the matrix re-routes
                                // its `.finishMissionIntro` to `.basementBrawl`.
                                if mission.id == "Mission003_5" {
                                    _ = manager.transition(to: .viewDropIntro)
                                } else {
                                    _ = manager.transition(to: .selectMission(mission.id))
                                }
                            }
                        )
                    }

                    // Endless Gauntlet — floor-based replay mode recombining
                    // the shipped missions with per-floor enemy scaling.
                    // Unlocks once M1 is cleared (a brand-new player should
                    // meet the campaign first; everyone else dives freely).
                    if stats.record(for: "Mission001").completed {
                        gauntletCard
                        contractBoardSection
                    }
                }
                .padding(.bottom, 16)
            }
            .frame(maxHeight: .infinity)

            Spacer()
        }
        .padding(24)
        }   // close outer ZStack (Zero State watermark wrapper)
        .fullScreenCover(isPresented: $showShop) {
            ShopView()
        }
        .fullScreenCover(isPresented: $showRoster) {
            RosterView(onDismiss: { showRoster = false })
        }
        .fullScreenCover(isPresented: $showRecords) {
            AchievementsView(onDismiss: { showRecords = false })
        }
    }

    /// Side-contract board: three procedural one-room jobs (one per tier),
    /// recombining shipped rooms with seeded signature squads. Victory
    /// consumes the offer and rolls a fresh one; defeat keeps it for a
    /// retry. Launching routes through the normal mission-select flow via
    /// the synthetic contract id (MissionLoader resolves it).
    private var contractBoardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "briefcase.fill")
                    .font(.system(size: 12, weight: .black))
                    .foregroundColor(Color(hex: "FFB020"))
                Text("SIDE CONTRACTS")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .tracking(3)
                    .foregroundColor(Color(hex: "FFB020"))
                Spacer()
                if contracts.completedCount > 0 {
                    Text("\(contracts.completedCount) FILLED")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.45))
                }
            }
            ForEach(contracts.offers) { offer in
                contractCard(offer)
            }
        }
        .padding(.top, 12)
    }

    private func contractCard(_ offer: ContractOffer) -> some View {
        let tierColor = Color(hex: offer.tier >= 3 ? "FF5500" : (offer.tier == 2 ? "FF8800" : "00FF88"))
        let heat = min(3, MissionStatsStore.shared.loadFactionAttention()[.corp] ?? 0)
        return Button(action: {
            HapticsManager.shared.selectAffirm()
            _ = manager.transition(to: .selectMission(offer.id))
        }) {
            HStack(spacing: 0) {
                Rectangle().fill(tierColor).frame(width: 4)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(offer.title)
                            .font(.system(size: 14, weight: .black, design: .monospaced))
                            .foregroundColor(.white)
                        HStack(spacing: 2) {
                            ForEach(0..<offer.tier, id: \.self) { _ in
                                Image(systemName: "skull.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(tierColor)
                            }
                        }
                        Spacer()
                        Text("¥\(offer.basePay.formatted())")
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .foregroundColor(Color(hex: "FFE044"))
                    }
                    HStack(spacing: 8) {
                        Text(offer.employer)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(1)
                            .foregroundColor(tierColor.opacity(0.9))
                        if heat > 0 {
                            Text(String(format: "HEAT ×%.2f", 1.0 + 0.15 * Double(heat)))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(Color(hex: "FF6600"))
                        }
                    }
                    Text(offer.blurb)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .foregroundColor(tierColor)
                    .padding(.horizontal, 12)
            }
            .background(Color(hex: "12100A"))
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(tierColor.opacity(0.35), lineWidth: 1))
        }
    }

    /// Endless Gauntlet entry card. Arming is lazy at LOAD time (inside
    /// MissionLoader's "Gauntlet" id intercept), so tapping just routes
    /// through the normal mission-select flow — backing out of the briefing
    /// is harmless and the floor/pick survive for a re-dive.
    private var gauntletCard: some View {
        let gauntlet = GauntletStore.shared
        let record = stats.record(for: GauntletStore.gauntletMissionId)
        return Button(action: {
            HapticsManager.shared.selectAffirm()
            _ = manager.transition(to: .selectMission(GauntletStore.gauntletMissionId))
        }) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.to.line.compact")
                    .font(.system(size: 22, weight: .black))
                    .foregroundColor(Color(hex: "FF66CC"))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color(hex: "FF66CC").opacity(0.12))
                        .overlay(Circle().stroke(Color(hex: "FF66CC").opacity(0.5), lineWidth: 1)))
                VStack(alignment: .leading, spacing: 3) {
                    Text("ENDLESS GAUNTLET")
                        .font(.system(size: 15, weight: .black, design: .monospaced))
                        .foregroundColor(Color(hex: "FF66CC")).tracking(1.5)
                    Text("Randomized contracts, escalating floors. How deep can the team go?")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(2)
                    HStack(spacing: 10) {
                        Text("NEXT: FLOOR \(gauntlet.currentFloor)")
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .foregroundColor(Color(hex: "00FFCC"))
                        if gauntlet.bestFloor > 0 {
                            Text("BEST: FLOOR \(gauntlet.bestFloor)")
                                .font(.system(size: 10, weight: .black, design: .monospaced))
                                .foregroundColor(Color(hex: "FFCC00"))
                        }
                        if record.bestScore > 0 {
                            Text("BEST SCORE \(record.bestScore)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.5))
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Color(hex: "FF66CC").opacity(0.7))
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(hex: "FF66CC").opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(hex: "FF66CC").opacity(0.45), lineWidth: 1.2))
            )
        }
    }

    /// Compact corp/gang heat readout + pre-mission risk-pay estimate.
    /// Attention only changes at mission boundaries and this view re-renders
    /// on every `stats` publish (wallet/score move on each victory), so a
    /// direct persisted read stays current without its own publisher.
    /// The pay estimate uses heatTier 0 (this mission's trace heat isn't
    /// known yet), so it can only UNDER-promise — the debrief may pay more.
    private var factionHeatRow: some View {
        let attention = stats.loadFactionAttention()
        let corp = attention[.corp, default: 0]
        let gang = attention[.gang, default: 0]
        let tier = ConsequenceEngine.rewardTier(heatTier: 0, corpAttention: corp, gangAttention: gang)
        let payMult = ConsequenceEngine.rewardMultiplier(for: tier)
        // Mirrors ConsequenceEngine.corpEnemyModifier (1-3 → +1, 4+ → +2) so
        // the warning matches what setup will actually spawn.
        let extraPatrols = ConsequenceEngine.corpEnemyModifier(corpAttention: corp)
        func heatColor(_ v: Int) -> Color {
            switch v {
            case 0:      return Color.gray.opacity(0.55)
            case 1...3:  return Color(hex: "FFB020")
            default:     return Color(hex: "FF4466")
            }
        }
        return HStack(spacing: 10) {
            Text("HEAT")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(Color(hex: "FF4466").opacity(0.75))
                .tracking(2)
            Text("CORP \(corp)")
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .foregroundColor(heatColor(corp))
            Text("GANG \(gang)")
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .foregroundColor(heatColor(gang))
            if extraPatrols > 0 {
                Text("+\(extraPatrols) PATROL\(extraPatrols > 1 ? "S" : "")")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "FFB020").opacity(0.85))
            }
            Spacer()
            Text(payMult > 1.0 ? "RISK PAY ×\(String(format: "%.2f", payMult))" : "COLD — LOW PROFILE")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundColor(payMult > 1.0 ? Color(hex: "FFCC00") : Color.gray.opacity(0.6))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.3))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke((corp + gang > 0 ? Color(hex: "FF4466") : Color.gray).opacity(0.25), lineWidth: 1)
                )
        )
    }
}

/// Roster overview reachable from the run-select screen — lists each runner
/// with level + vitals; tap one to open their full CharacterInfoSheet (stats,
/// loadout, cyberware/buffs). Reads the canonical (un-freshened) saved roster.
struct RosterView: View {
    let onDismiss: () -> Void
    @State private var roster: [Character] = RosterStore.shared.loadCanonical()
    @State private var selected: Character? = nil

    var body: some View {
        ZStack {
            Color(hex: "05070D").ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("RUNNER ROSTER")
                        .font(.system(size: 20, weight: .black, design: .monospaced))
                        .foregroundColor(Color(hex: "00FF88")).tracking(2)
                    Spacer()
                    if NGPlusStore.shared.tier > 0 {
                        Text("NG+\(NGPlusStore.shared.tier)")
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .foregroundColor(Color(hex: "FF4466"))
                    }
                }
                .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 12)

                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(roster) { c in
                            Button(action: { HapticsManager.shared.buttonTap(); selected = c }) {
                                rosterRow(c)
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 20)
                }

                Button(action: { HapticsManager.shared.back(); onDismiss() }) {
                    Text("CLOSE")
                        .font(.system(size: 14, weight: .heavy, design: .monospaced))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Color(hex: "00FF88"))
                }
            }
            // Tap a runner → full info sheet (stats / loadout / cyberware).
            if let c = selected {
                CharacterInfoSheet(payload: .player(c), onDismiss: { selected = nil })
            }
        }
    }

    private func rosterRow(_ c: Character) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(c.name.uppercased())
                        .font(.system(size: 15, weight: .black, design: .monospaced))
                        .foregroundColor(.white)
                    Text("LVL \(c.level)")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundColor(.black)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color(hex: "FFCC00")))
                }
                Text(c.equippedWeapon?.name ?? "Unarmed")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(hex: "8A94A6"))
                Text("HP \(c.maxHP) · BOD \(c.attributes.bod) AGI \(c.attributes.agi) · \(c.installedCyberware.count) implant\(c.installedCyberware.count == 1 ? "" : "s")")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(hex: "00D4FF").opacity(0.8))
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundColor(Color(hex: "00FF88").opacity(0.5))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: "0E1320"))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: "00FF88").opacity(0.2), lineWidth: 1)))
    }
}

struct MissionCard: View {
    /// Colour for a mission letter rank (S gold → C grey).
    static func rankColor(_ rank: String) -> Color {
        switch rank {
        case "S": return Color(hex: "FFD23F")
        case "A": return Color(hex: "00FF88")
        case "B": return Color(hex: "00C8FF")
        case "C": return Color(hex: "B8BCC8")
        default:  return Color(hex: "888888")
        }
    }

    let id: String
    let number: String
    let title: String
    let description: String
    let risk: String
    let badge: String?
    let isLocked: Bool
    var isCompleted: Bool = false
    var bestScore: Int = 0
    var bestMiniGameScore: Int = 0
    let onSelect: () -> Void

    private var riskColor: Color {
        switch risk {
        case "EASY":     return Color(hex: "00FFCC")
        case "MODERATE": return Color(hex: "00FF88")
        case "HIGH":     return Color(hex: "FF8800")
        case "HARD":     return Color(hex: "FF5500")
        case "EXTREME":  return Color(hex: "FF1133")
        default:         return Color.gray
        }
    }

    private var skullCount: Int {
        switch risk {
        case "EASY":     return 0
        case "MODERATE": return 1
        case "HIGH":     return 2
        case "HARD":     return 3
        case "EXTREME":  return 3
        default:         return 0
        }
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 0) {
                // Colored left accent bar
                Rectangle()
                    .fill(riskColor)
                    .frame(width: 4)

                // Mission number badge
                VStack {
                    Text(number)
                        .font(.system(size: 14, weight: .black, design: .monospaced))
                        .foregroundColor(riskColor)
                }
                .frame(width: 40)
                .padding(.vertical, 12)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.headline)
                            .foregroundColor(.white)

                        // Skull icons for risk level
                        HStack(spacing: 2) {
                            ForEach(0..<skullCount, id: \.self) { _ in
                                Image(systemName: "skull.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(riskColor)
                            }
                        }

                        Text(risk)
                            .font(.caption2)
                            .fontWeight(.bold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(riskColor.opacity(0.2))
                            .foregroundColor(riskColor)
                            .cornerRadius(4)
                        if let badge = badge {
                            Text(badge)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.purple.opacity(0.3))
                                .foregroundColor(.purple)
                                .cornerRadius(4)
                        }
                        if isCompleted {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 12))
                                .foregroundColor(Color(hex: "00FFCC"))
                        }
                    }
                    if isCompleted && bestScore > 0 {
                        HStack(spacing: 8) {
                            let rank = MissionStatsStore.rank(forScore: bestScore)
                            Text("RANK \(rank)")
                                .font(.system(size: 11, weight: .black, design: .monospaced))
                                .foregroundColor(Self.rankColor(rank))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .overlay(RoundedRectangle(cornerRadius: 4)
                                    .stroke(Self.rankColor(rank).opacity(0.7), lineWidth: 1))
                            Text("BEST: \(bestScore)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(Color(hex: "00FFCC"))
                                .tracking(1)
                            if bestMiniGameScore > 0 {
                                Text("HACK: \(bestMiniGameScore)")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(Color(hex: "AA66FF"))
                                    .tracking(1)
                            }
                        }
                    }
                    // Contract payout preview — base pay, the heat bonus when corp
                    // attention is up, and the residual note once paid this run.
                    if !isLocked {
                        HStack(spacing: 6) {
                            let base = MissionStatsStore.basePayout(missionId: id)
                            let heat = min(3, MissionStatsStore.shared.loadFactionAttention()[.corp] ?? 0)
                            let paid = MissionStatsStore.shared.paidThisRun.contains(id)
                            Text("PAY ¥\(base.formatted())")
                                .font(.system(size: 10, weight: .black, design: .monospaced))
                                .foregroundColor(Color(hex: "FFE044"))
                            if heat > 0 && !paid {
                                Text(String(format: "HEAT ×%.2f", 1.0 + 0.15 * Double(heat)))
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(Color(hex: "FF6600"))
                            }
                            if paid {
                                Text("PAID — REPLAYS ¥25%")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.45))
                            }
                        }
                    }
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if isLocked {
                    Image(systemName: "lock.fill")
                        .foregroundColor(riskColor.opacity(0.8))
                        .padding(.horizontal, 12)
                } else {
                    Image(systemName: "chevron.right")
                        .foregroundColor(riskColor)
                        .padding(.horizontal, 12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(hex: "0F0F1E"))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(riskColor.opacity(0.3), lineWidth: 1)
            )
        }
        .disabled(isLocked)
    }
}

// MARK: - Briefing View

struct BriefingView: View {
    @ObservedObject var manager: PhaseManager

    @State private var loadedMission: Mission?
    // Some missions ship a multi-room JSON (Mission001_multi.json, etc.) that
    // MissionSetupService prefers over the single-room file. The briefing has
    // to load the same way or it shows mismatched HOSTILES counts (e.g. 4 from
    // the single-room JSON when the multi-room actually has 6 across rooms).
    @State private var loadedMultiRoom: MultiRoomMission?

    /// Cinematic full-screen briefing overlay shown on top of the team-roster
    /// screen. Tap-to-dismiss reveals the ACCEPT CONTRACT button. Restored
    /// 2026-05 — the redundancy with the screen below is intentional, the
    /// overlay carries flavor + at-a-glance intel and the screen below has
    /// the team roster + commit button.
    @State private var showCinematicBriefing: Bool = true

    private var missionTitle: String {
        loadedMultiRoom?.title ?? loadedMission?.title ?? manager.selectedMissionId ?? "Unknown"
    }

    private var missionDesc: String {
        loadedMultiRoom?.description ?? loadedMission?.description ?? "No description available."
    }

    /// Total hostiles across the whole mission. For multi-room missions this is
    /// the sum across every room (matches what the player will fight end-to-end);
    /// for single-room missions it's just `mission.enemies.count`.
    private var totalEnemyCount: Int {
        if let multi = loadedMultiRoom {
            return multi.rooms.reduce(0) { $0 + $1.enemies.count }
        }
        return loadedMission?.enemies.count ?? 0
    }

    private var teamRoster: [Character] {
        let team = GameState.shared.playerTeam
        return team.isEmpty ? Character.allRunners : team
    }

    private var reward: String {
        // Quote the contract from MissionStatsStore (what the wallet actually
        // pays) — the old hardcoded figures were pre-rebalance, up to ~6x high.
        let mid = manager.selectedMissionId ?? ""
        let base = MissionStatsStore.basePayout(missionId: mid)
        let dataB = MissionStatsStore.dataBonus(missionId: mid)
        let grimB = MissionStatsStore.grimoireBonus(missionId: mid)
        var text = "¥\(srYen(base))"
        if dataB > 0 { text += " + ¥\(srYen(dataB)) objective bonus" }
        if grimB > 0 { text += " + ¥\(srYen(grimB)) grimoire bonus" }
        // The quote is the C-rank base — rank and faction heat multiply the
        // actual credit (see recordVictory), and an already-paid replay drops
        // to the 25% residual rate. Flag both so the debrief number never
        // reads as a broken promise.
        if MissionStatsStore.shared.paidThisRun.contains(mid) {
            text += "  ·  REPLAY 25% RATE"
        }
        text += "  ·  RANK & HEAT SCALE PAY"
        return text
    }

    // Keep these aligned with MissionSelectView.missions risk strings — the player
    // sees the risk on the select screen and again on the briefing, and the two
    // were drifting (Mission003 said HARD on select, EXTREME on briefing; Mission005
    // said EXTREME on select, HIGH on briefing).
    private var riskLevel: String {
        switch manager.selectedMissionId ?? "" {
        case "Mission001": return "EASY"
        case "Mission002": return "HIGH"
        case "Mission003": return "HARD"
        case "Mission004": return "EXTREME"
        case "Mission005": return "EXTREME"
        case "Mission006": return "EXTREME"
        default:            return "UNKNOWN"
        }
    }

    /// True if the current mission has a recoverable data terminal as a
    /// secondary objective (M2-M6 all do; M1 doesn't). Used to surface the
    /// "HACK TERMINAL" chip on the briefing so the player knows the
    /// secondary-objective payout exists before they walk in.
    private var missionHasTerminal: Bool {
        switch manager.selectedMissionId ?? "" {
        case "Mission002", "Mission003", "Mission004", "Mission005", "Mission006":
            return true
        default:
            return false
        }
    }

    var body: some View {
        ZStack {
            // (Zero State studio sigil is rendered INLINE below the
            // ACCEPT CONTRACT button — see the button block further
            // down. Footer-style placement keeps it away from the title
            // chrome and gives it breathing room as a deliberate page
            // seal.)

            // Wrapped in a GeometryReader + ScrollView so a long briefing
            // (e.g. M6) can't overflow the fixed screen. A non-scrolling VStack
            // taller than the device centers its overflow — clipping BOTH the
            // "BRIEFING" title under the notch AND the footer Zero State mark.
            // ScrollView insets for the safe area and scrolls when tall; the
            // minHeight pins the button near the bottom when content is short.
            GeometryReader { geo in
             ScrollView(showsIndicators: false) {
              VStack(spacing: 20) {
                Text("BRIEFING")
                    .font(.system(size: 22, weight: .black))
                    .foregroundColor(Color(hex: "00FF88"))
                    .tracking(4)

                // Team roster with portraits
                VStack(spacing: 12) {
                    Text("TEAM ROSTER")
                        .font(.system(size: 11, weight: .black))
                        .foregroundColor(Color(hex: "00FF88").opacity(0.7))
                        .tracking(2)

                    HStack(spacing: 12) {
                        ForEach(0..<min(4, teamRoster.count), id: \.self) { i in
                            VStack(spacing: 4) {
                                ZStack {
                                    Circle()
                                        .fill(getTeamColor(i))
                                        .frame(width: 48, height: 48)
                                    Text(String(teamRoster[i].name.prefix(1)))
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(.black)
                                }
                                Text(teamRoster[i].name.prefix(6).lowercased())
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white)
                            }
                        }
                        Spacer()
                    }
                }
                .padding(16)
                .background(Color(hex: "0F0F1E"))
                .cornerRadius(12)

                VStack(alignment: .leading, spacing: 16) {
                    briefingRow("Mission:", missionTitle)
                    briefingRow("Risk:", riskLevel)
                    briefingRow("Pay:", reward)
                    briefingRow("Briefing:", missionDesc)
                }
                .padding(20)
                .background(Color(hex: "0F0F1E"))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(hex: "1E1E3E"), lineWidth: 1)
                )

                // Intel badges — pulled in from the old MissionBriefingOverlay
                // so this single screen carries all the at-a-glance numbers
                // (hostiles count, objective, exfil) the player previously
                // got from the redundant overlay.
                HStack(spacing: 12) {
                    IntelBadge(label: "HOSTILES", value: "\(totalEnemyCount)")
                    IntelBadge(label: "OBJECTIVE", value: "REACH EXIT")
                    if missionHasTerminal {
                        // Surface the secondary-objective chip so the player
                        // sees the bonus exists BEFORE the run — previously
                        // they'd only learn about it via the in-mission HUD
                        // "DATA: PENDING" chip, which is easy to miss.
                        IntelBadge(label: "DATA", value: "HACK TERMINAL")
                    }
                    IntelBadge(label: "EXFIL", value: "EXTRACTION PT.")
                }

                Spacer(minLength: 16)

                Button(action: {
                    beginMission()
                }) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(hex: "00FF88"))
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(hex: "00FF88"), lineWidth: 2)
                            .opacity(0.5)

                        Text("ACCEPT CONTRACT")
                            .font(.system(size: 16, weight: .black))
                            .foregroundColor(.black)
                    }
                    .menuButtonSize(phone: CGSize(width: 240, height: 50),
                                    pad: CGSize(width: 360, height: 60))
                }

                // Decline / back — the briefing had no exit; once you reached
                // it you were committed to starting the mission.
                Button(action: {
                    HapticsManager.shared.back()
                    _ = manager.transition(to: .returnToTitle)
                }) {
                    Text("◀ DECLINE")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.top, 4)
                }

                // Zero State studio sigil — footer mark below the ACCEPT
                // CONTRACT button. Centered, sized to read at glance against
                // the dark page background. Placed here (rather than as a
                // header crest above the BRIEFING title) so it doesn't
                // compete with the page chrome at the top.
                Image("zero_state_mark_1")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                    .opacity(0.75)
                    .padding(.top, 8)
              }
              .padding(24)
              .frame(maxWidth: .infinity, minHeight: geo.size.height)
             }
            }
            .onAppear { loadMission() }

            // Cinematic mission-briefing overlay. Player taps anywhere to
            // dismiss, then the team-roster + ACCEPT CONTRACT screen
            // underneath becomes interactive. Restored 2026-05 by request.
            if showCinematicBriefing {
                MissionBriefingOverlay(
                    mission: loadedMission,
                    enemyCountOverride: loadedMultiRoom != nil ? totalEnemyCount : nil,
                    titleOverride: loadedMultiRoom?.title,
                    descriptionOverride: loadedMultiRoom?.description,
                    difficultyOverride: loadedMultiRoom?.difficulty,
                    missionId: manager.selectedMissionId,
                    onDismissed: { showCinematicBriefing = false }
                )
                .transition(.opacity)
                .zIndex(10)
            }
        }
    }

    private func briefingRow(_ label: String, _ value: String) -> some View {
        // Label column is 96pt and pinned to a single line — "Briefing:" in
        // callout-monospaced font is wider than the old 80pt column and
        // was wrapping its colon onto its own line. The value text uses
        // `.fixedSize(horizontal: false, vertical: true)` so multi-line
        // body text wraps cleanly inside its remaining width instead of
        // truncating or pushing the column.
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .foregroundColor(Color(hex: "00FF88").opacity(0.7))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .foregroundColor(.white)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.callout, design: .monospaced))
    }

    private func loadMission() {
        guard let id = manager.selectedMissionId else { return }
        // Match MissionSetupService: try multi-room first, fall back to single-room.
        // Loading both lets us prefer multi-room data for hostile counts while still
        // having the single-room Mission available as a fallback for description, etc.
        loadedMultiRoom = MissionLoader.shared.loadMultiRoomMission(named: id)
        loadedMission = MissionLoader.shared.loadMission(named: id)

        // Pre-decode this mission's sprite frames in the background while the
        // player reads the briefing — scene setup then finds them ready
        // instead of freezing ACCEPT CONTRACT for ~30s of synchronous PNG
        // decoding on a cold launch.
        var enemyTypes = Set(loadedMultiRoom?.rooms.flatMap { $0.enemies.map(\.type) } ?? [])
        enemyTypes.formUnion(loadedMission?.enemies.map(\.type) ?? [])
        if let bosses = loadedMultiRoom?.rooms.compactMap(\.bossSpawn?.type) {
            enemyTypes.formUnion(bosses)
        }
        SpriteManager.shared.preloadMissionSprites(enemyTypes: Array(enemyTypes))
    }

    private func beginMission() {
        HapticsManager.shared.selectAffirm()
        HapticsManager.shared.combatStart()
        _ = GameState.shared.prepareMissionForCombat(named: manager.selectedMissionId)
        _ = manager.transition(to: .beginMission)
    }

    private func getTeamColor(_ index: Int) -> Color {
        let colors = [
            Color(hex: "00FF88"),
            Color(hex: "00D4FF"),
            Color(hex: "FF8800"),
            Color(hex: "FF3366")
        ]
        return colors[index % colors.count]
    }
}

// MARK: - Combat View

struct CombatView: View {
    @ObservedObject var manager: PhaseManager
    @ObservedObject var gameState: GameState
    @State private var showDiagnostics = false
    @State private var showAbortConfirm = false
    @State private var objectiveBannerHeight: CGFloat = 96
    @State private var combatUIHeight: CGFloat = 180
    @State private var infoSheetPayload: CharacterInfoSheet.InfoPayload? = nil
    @State private var levelUpInfo: LevelUpInfo? = nil

    /// Outcome line shown on the "RUN COMPLETE" overlay. Reports the nuyen
    /// payout for the mission plus a per-mission objective-bonus line that
    /// reflects what the player ACTUALLY recovered (terminal data, grimoire,
    /// etc.) — driven by `gameState.dataAcquired` / `gameState.grimoireAcquired`.
    private var victoryText: String {
        // Derived from MissionStatsStore — the single source the wallet credit
        // actually uses — instead of hardcoded pre-rebalance figures that
        // overstated payouts up to ~6x and printed "(+¥ bonus)" on MISSED
        // objectives. Mirrors DebriefView.rewardText.
        let missionId = manager.selectedMissionId ?? ""
        let dataB = MissionStatsStore.dataBonus(missionId: missionId)
        let grimB = MissionStatsStore.grimoireBonus(missionId: missionId)
        let stats = MissionStatsStore.shared
        // What recordVictory ACTUALLY banked this victory (replays pay the
        // 25% residual contract rate since the 2026-07 economy pass).
        let credited = stats.lastWalletCredit

        var lines: [String] = []
        if dataB > 0 {
            lines.append(gameState.dataAcquired ? "✓ DATA RECOVERED  (+¥\(srYen(dataB)))" : "✗ DATA MISSED")
        }
        if grimB > 0 {
            lines.append(gameState.grimoireAcquired ? "✓ GRIMOIRE ACQUIRED  (+¥\(srYen(grimB)))" : "✗ GRIMOIRE LEFT BEHIND")
        }
        // Payout factors — only the ones that actually moved the number.
        if stats.lastRankMultiplier > 1.0 {
            lines.append("✓ RANK BONUS ×\(String(format: "%.2f", stats.lastRankMultiplier))")
        }
        if stats.lastRiskMultiplier > 1.0 {
            lines.append("✓ HEAT PAY ×\(String(format: "%.2f", stats.lastRiskMultiplier))")
        }
        if stats.lastRunFactor < 1.0 {
            lines.append("◦ REPLAY CONTRACT — \(Int(stats.lastRunFactor * 100))% RATE")
        }
        var result = "¥\(srYen(credited)) earned"
        if !lines.isEmpty { result += "\n" + lines.joined(separator: "\n") }
        return result
    }

    private var missionTitle: String {
        switch manager.selectedMissionId ?? "" {
        case "Mission001": return "The Extraction"
        case "Mission002": return "Ghost Protocol"
        case "Mission003": return "The Mage's Lair"
        case "Mission004": return "Dead Man's Switch"
        case "Mission005": return "Mekton Blues"
        case "Mission006": return "Ghost Signal"
        // Replay modes (gauntlet floors, contracts) build their own mission
        // objects and carry a real title — use it instead of a stub.
        default:            return RoomManager.shared.currentMission?.title ?? "Unknown Mission"
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Full-screen SpriteKit board — GeometryReader gives us the real available size
            GeometryReader { geometry in
                BattleSceneView(
                    gameState: gameState,
                    missionId: manager.selectedMissionId,
                    parentSize: geometry.size,
                    topHUDInset: objectiveBannerHeight,
                    bottomHUDInset: combatUIHeight
                )
            }
            .ignoresSafeArea()

            // Overlays — shown only during active combat
            if !gameState.combatEnded {
                // CENTER: Mission objective banner — sits in the middle of
                // the screen on mission start so the character sprites at
                // the top of the map remain visible behind/around it. The
                // banner auto-hides after a few seconds (handled inside
                // MissionObjectiveBanner), at which point the play area is
                // unobstructed.
                VStack {
                    Spacer()
                    MissionObjectiveBanner(
                        missionTitle: missionTitle,
                        missionId: manager.selectedMissionId ?? "",
                        extractionX: gameState.extractionX,
                        extractionY: gameState.extractionY
                    )
                    // Same iPad width cap as the combat panel — the banner
                    // stretched across the full tablet width read as a wall.
                    // No-op on phones (≤620pt wide).
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 12)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: CombatTopOverlayHeightPreferenceKey.self, value: proxy.size.height)
                        }
                    )
                    Spacer()
                }

                // TOP CENTER: transient warning banner. Renders whenever
                // GameState.transientWarning is non-nil and auto-clears via
                // the timer in postTransientWarning. Currently fires when
                // the player tries to leave a room with an unhacked required
                // terminal.
                if let warning = gameState.transientWarning {
                    VStack {
                        TerminalWarningBanner(text: warning)
                            .padding(.top, 80)
                            .padding(.horizontal, 24)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        Spacer()
                    }
                    .allowsHitTesting(false)
                    .animation(.easeInOut(duration: 0.25), value: gameState.transientWarning)
                }

                // TOP RIGHT: abort-to-menu button + lightweight diagnostics.
                //
                // Layout note: the underlying SpriteKit map ignores safe area
                // and bleeds up under the Dynamic Island / status bar area
                // (per the camera scaling), so a safe-area-respecting button
                // landed visually ON TOP OF the map background. Here we
                // ignore the top safe area for this overlay and use an
                // explicit padding that parks the button just below the
                // Dynamic Island — clear of the status icons but high enough
                // that the play area below is unobstructed.
                VStack {
                    HStack {
                        Spacer()
                        VStack(alignment: .trailing, spacing: 6) {
                            // Abort button — opens confirmation overlay so a
                            // misstap doesn't kill an in-progress mission.
                            Button(action: {
                                HapticsManager.shared.back()
                                showAbortConfirm = true
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "xmark.circle.fill")
                                    Text("MENU")
                                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                                }
                                .foregroundColor(Color(hex: "FF4A4A"))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Color.black.opacity(0.65)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color(hex: "FF4A4A").opacity(0.7), lineWidth: 1.2)
                                        )
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }

                            if showDiagnostics {
                                CombatDiagnosticsPanel(
                                    phase: manager.currentPhase,
                                    round: gameState.roundNumber,
                                    activeActorId: (gameState.activeCharacter ?? gameState.currentCharacter)?.id.uuidString,
                                    fpsText: FPSMonitor.shared.currentFPSLabel,
                                    authoritySummary: gameState.turnAuthoritySummary,
                                    traceLevel: gameState.traceLevel,
                                    traceThreshold: gameState.traceThreshold,
                                    traceTriggered: gameState.isTraceTriggered,
                                    traceEscalationLevel: gameState.traceEscalationLevel,
                                    traceGainPerSignal: gameState.traceGainPerSignal,
                                    traceRecoveryPerLayLow: gameState.traceRecoveryPerLayLow,
                                    traceTelemetrySummary: gameState.traceTelemetrySummary(),
                                    playerRole: gameState.playerRoleLabel
                                )
                            }
                        }
                        .padding(.top, 56)   // Clear Dynamic Island / status bar.
                        .padding(.trailing, 12)
                    }
                    Spacer()
                }
                .ignoresSafeArea(edges: .top)
            }

            // Matrix hacking mini-game overlay — fires when a runner steps
            // onto a data terminal. The router picks one of three distinct
            // mini-games based on the active mission:
            //   M2 → LaneRunner   M4 → CypherCracker   M5 → PacketRouter
            if gameState.showMatrixMiniGame {
                MatrixMiniGameRouter(gameState: gameState) { success in
                    CombatFlowController.resolveMatrixMiniGame(gameState: gameState, success: success)
                }
                .transition(.opacity)
                .zIndex(900)
            }

            // Abort-mission confirmation overlay — full-screen so taps can't
            // leak through. Tap "ABORT" → return to mission select. Tap
            // outside or "CANCEL" → dismiss and resume.
            if showAbortConfirm {
                AbortMissionOverlay(
                    onCancel: { showAbortConfirm = false },
                    onConfirm: {
                        showAbortConfirm = false
                        HapticsManager.shared.back()
                        // Kill every deferred timer from this attempt
                        // (extraction finalize, enemy stagger, boss spawns)
                        // so none of them fire into the next mission.
                        gameState.missionAttemptId += 1
                        gameState.combatEnded = false
                        gameState.combatWon = nil
                        _ = manager.transition(to: .returnToTitle)
                    }
                )
                .zIndex(940)
            }

            // Long-press info sheet — surfaces character/enemy dossier (stats
            // + archetype + lore from HEXWIRE-LORE.md). Triggered by a
            // 0.45s press on a character or enemy tile in BattleScene.
            if let payload = infoSheetPayload {
                CharacterInfoSheet(payload: payload, onDismiss: {
                    infoSheetPayload = nil
                })
                .zIndex(945)
                .transition(.opacity)
            }

            // Cinematic boss reveal — slams in over the board when a boss
            // deploys, holds, then auto-clears (timer in GameState). Tap to
            // skip. Sits above the HUD but below end/abort overlays.
            if let intro = gameState.bossIntro {
                BossIntroOverlay(intro: intro) {
                    withAnimation(.easeOut(duration: 0.25)) { gameState.bossIntro = nil }
                }
                .transition(.opacity)
                .zIndex(935)
            }

            // Level-up card — non-blocking banner near the top.
            if let lvl = levelUpInfo {
                VStack {
                    LevelUpCard(info: lvl)
                        .padding(.top, 110)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Spacer()
                }
                .allowsHitTesting(false)
                .zIndex(930)
            }

            // Loot pickup toast — bottom-anchored (above the HUD) so it never
            // collides with the top banners. Clear icon + name + what it does.
            if let loot = gameState.lootToast {
                VStack {
                    Spacer()
                    LootToastCard(info: loot)
                        .padding(.bottom, combatUIHeight + 14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .allowsHitTesting(false)
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: gameState.lootToast)
                .zIndex(931)
            }

            if gameState.combatEnded {
                // Combat ended overlay — full-screen so taps can never leak to
                // the combat scene behind. Both success and failure show the
                // same control: tap to advance. Failures additionally have an
                // explicit "HOME SCREEN" button + an auto-return safety net.
                CombatEndOverlay(
                    gameState: gameState,
                    manager: manager,
                    victoryText: victoryText
                )
                .zIndex(950)
            } else {
                // SwiftUI combat UI — bottom-aligned, content-sized
                CombatUI(
                    gameState: gameState,
                    diagnosticsVisible: showDiagnostics,
                    onToggleDiagnostics: { showDiagnostics.toggle() },
                    onAttack: { _ = gameState.requestAttack() },
                    onShoot: { gameState.performShoot() },
                    onOverwatch: { gameState.performOverwatch() },
                    onDefend: { gameState.performDefend() },
                    onSpell: { /* handled by SpellPickerSheet inside CombatUI */ },
                    onBlitz: { gameState.performBlitz() },
                    onHack: { gameState.performHack() },
                    onIntimidate: { gameState.performIntimidate() },
                    onItems: { gameState.performUseItem() },
                    onRecover: { gameState.performLayLow() },
                    onEndTurn: { gameState.endTurn() }
                )
                // iPad: cap the panel at a phone-ish column and center it —
                // stretched across a full 834+pt tablet width the phone-sized
                // buttons/fonts floated in empty chrome. ≤620pt devices
                // (every iPhone) render exactly as before. The rounded top
                // corners only ever show on iPad, where the panel edges sit
                // inboard of the screen edges.
                .frame(maxWidth: 620)
                .background(
                    CombatTheme.background.opacity(0.92)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14))
                )
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: CombatBottomOverlayHeightPreferenceKey.self, value: proxy.size.height)
                    }
                )
                .frame(maxWidth: .infinity)
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .onPreferenceChange(CombatTopOverlayHeightPreferenceKey.self) { height in
            objectiveBannerHeight = max(96, height)
            dlog("[CombatView] objectiveBannerHeight=\(objectiveBannerHeight)")
        }
        .onPreferenceChange(CombatBottomOverlayHeightPreferenceKey.self) { height in
            combatUIHeight = max(150, height)
            dlog("[CombatView] combatUIHeight=\(combatUIHeight)")
        }
        // FPS counter only drives the diagnostics panel — don't run its
        // display link (a per-frame timer) all of combat when that panel is
        // hidden (its default).
        .onAppear { if showDiagnostics { FPSMonitor.shared.start() } }
        .onDisappear { FPSMonitor.shared.stop() }
        .onChange(of: showDiagnostics) { visible in
            if visible { FPSMonitor.shared.start() } else { FPSMonitor.shared.stop() }
        }
        // Long-press info-sheet bridge — BattleScene posts when the player
        // long-presses a character/enemy tile, this resolves the entity from
        // Level-up card — when a runner levels, surface exactly what improved
        // (read from the character's lastLevelUpSummary). Auto-clears.
        .onReceive(NotificationCenter.default.publisher(for: .characterLevelUp)) { note in
            guard let idStr = note.userInfo?["characterId"] as? String,
                  let id = UUID(uuidString: idStr),
                  let char = gameState.playerTeam.first(where: { $0.id == id }) else { return }
            let info = LevelUpInfo(name: char.name, level: char.level, summary: char.lastLevelUpSummary)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { levelUpInfo = info }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                if levelUpInfo == info { withAnimation(.easeOut(duration: 0.3)) { levelUpInfo = nil } }
            }
        }
        // GameState and shows the modal sheet.
        .onReceive(NotificationCenter.default.publisher(for: .entityInfoRequested)) { note in
            guard let kind = note.userInfo?["kind"] as? String else { return }
            switch kind {
            case "player":
                guard let idStr = note.userInfo?["characterId"] as? String,
                      let id = UUID(uuidString: idStr),
                      let char = gameState.playerTeam.first(where: { $0.id == id }) else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    infoSheetPayload = .player(char)
                }
            case "enemy":
                guard let idStr = note.userInfo?["enemyId"] as? String,
                      let id = UUID(uuidString: idStr),
                      let enemy = gameState.enemies.first(where: { $0.id == id }) else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    infoSheetPayload = .enemy(enemy)
                }
            default: break
            }
        }
    }
}

// MARK: - Abort Mission Overlay
//
// Tapped from the top-right "MENU" button during a live mission. Confirms
// before leaving so a misstap doesn't kill an in-progress run. Both buttons
// haptic-tap on press.
private struct AbortMissionOverlay: View {
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.82).ignoresSafeArea()
                .onTapGesture { onCancel() }

            VStack(spacing: 18) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(Color(hex: "FF4A4A"))
                Text("ABORT MISSION?")
                    .font(.system(size: 22, weight: .heavy, design: .monospaced))
                    .foregroundColor(Color(hex: "FF4A4A"))
                Text("All progress in this mission will be lost.\nReturn to the mission select screen?")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(Color(hex: "C8D6FF"))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                HStack(spacing: 14) {
                    Button(action: onCancel) {
                        Text("CANCEL")
                            .font(.system(size: 14, weight: .heavy, design: .monospaced))
                            .foregroundColor(Color(hex: "C8D6FF"))
                            .frame(minWidth: 110)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color(hex: "C8D6FF").opacity(0.5), lineWidth: 1.2)
                            )
                    }
                    Button(action: onConfirm) {
                        Text("ABORT")
                            .font(.system(size: 14, weight: .heavy, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(minWidth: 110)
                            .padding(.vertical, 12)
                            .background(Color(hex: "AA1133"))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(hex: "0A0E18"))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(hex: "FF4A4A").opacity(0.6), lineWidth: 1.5)
                    )
            )
            .padding(.horizontal, 32)
        }
    }
}

private struct CombatTopOverlayHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 96

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct CombatBottomOverlayHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 280

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct CombatDiagnosticsPanel: View {
    let phase: GamePhase
    let round: Int
    let activeActorId: String?
    let fpsText: String
    let authoritySummary: String
    let traceLevel: Int
    let traceThreshold: Int
    let traceTriggered: Bool
    let traceEscalationLevel: Int
    let traceGainPerSignal: Int
    let traceRecoveryPerLayLow: Int
    let traceTelemetrySummary: String
    let playerRole: String

    private var actorLabel: String {
        guard let activeActorId, !activeActorId.isEmpty else { return "n/a" }
        return String(activeActorId.prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("diag")
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .foregroundColor(Color(hex: "00FF88").opacity(0.75))
            Text("phase: \(phase.displayName.lowercased())")
            Text("round: \(round)")
            Text("actor: \(actorLabel)")
            Text("fps: \(fpsText)")
            Text("trace: \(traceLevel)/\(traceThreshold) trig=\(traceTriggered ? "yes" : "no")")
            Text("traceEsc: \(traceEscalationLevel)")
            Text("role: \(playerRole)")
            Text("cadence: th\(traceThreshold) +\(traceGainPerSignal) / -\(traceRecoveryPerLayLow)")
            Text(traceTelemetrySummary)
            Text(authoritySummary)
                .lineLimit(2)
                .foregroundColor(.white.opacity(0.65))
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .foregroundColor(.white.opacity(0.9))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(hex: "00FF88").opacity(0.3), lineWidth: 1)
                )
        )
        .accessibilityIdentifier("combat_diagnostics_panel")
    }
}

@MainActor
private final class FPSMonitor: ObservableObject {
    static let shared = FPSMonitor()

    @Published private(set) var currentFPSLabel: String = "n/a"

    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var frameCount: Int = 0

    private init() {}

    func start() {
        guard displayLink == nil else { return }
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.start() }
            return
        }
        lastTimestamp = 0
        frameCount = 0
        currentFPSLabel = "n/a"

        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        currentFPSLabel = "n/a"
    }

    @objc private func step(_ link: CADisplayLink) {
        if lastTimestamp == 0 {
            lastTimestamp = link.timestamp
            return
        }
        frameCount += 1
        let delta = link.timestamp - lastTimestamp
        guard delta >= 1 else { return }
        let fps = Int((Double(frameCount) / delta).rounded())
        currentFPSLabel = fps > 0 ? "\(fps)" : "n/a"
        frameCount = 0
        lastTimestamp = link.timestamp
    }
}

// MARK: - Battle Scene Wrapper

/// Plain SKView wrapper used by BattleSceneView.
/// BattleScene already receives touches through SpriteKit; claiming every touch here
/// breaks the SwiftUI combat HUD above it.
class ForwardingSKView: SKView {}

struct BattleSceneView: UIViewRepresentable {
    @ObservedObject var gameState: GameState
    var missionId: String?
    var parentSize: CGSize = .zero
    var topHUDInset: CGFloat = 96
    var bottomHUDInset: CGFloat = 180

    // Fixed tile map size — 10 tiles × 56pt = 560pt wide, 18 tiles × 56pt = 1008pt tall
    static let tileMapSize = CGSize(width: 560, height: 1008)

    func makeUIView(context: Context) -> SKView {
        let skView = ForwardingSKView()
        skView.ignoresSiblingOrder = true
        skView.showsFPS = false
        skView.showsNodeCount = false
        skView.preferredFramesPerSecond = 60
        skView.backgroundColor = .black
        // Use autoresizing mask so the view fills its superview naturally.
        // SwiftUI's GeometryReader -> ZStack -> ForwardingSKView hierarchy gives
        // us the correct bounds via the ZStack's layout pass.
        skView.translatesAutoresizingMaskIntoConstraints = true
        skView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Give SKView an initial frame at screen size — actual bounds come from layout.
        skView.frame = UIScreen.main.bounds
        context.coordinator.skView = skView
        dlog("[BattleSceneView] makeUIView frame: \(skView.frame.size)")
        return skView
    }

    func updateUIView(_ skView: SKView, context: Context) {
        // Get the actual available size directly from the SKView's superview bounds.
        // This is always correct because it comes from the current layout pass.
        // parentSize (SwiftUI @State) lags behind on first render, so never use it.
        let availableSize: CGSize
        if let superviewBounds = skView.superview?.bounds, superviewBounds.width > 0, superviewBounds.height > 0 {
            availableSize = superviewBounds.size
        } else {
            availableSize = UIScreen.main.bounds.size
        }

        // Resize SKView frame to match available space. With
        // translatesAutoresizingMaskIntoConstraints=true and
        // autoresizingMask=.flexibleWidth/.flexibleHeight this should already
        // be correct from the layout pass, but this ensures it.
        if skView.frame.size != availableSize {
            skView.frame = CGRect(origin: .zero, size: availableSize)
            dlog("[BattleSceneView] Resized SKView to: \(availableSize)")
        }

        let missionToLoad = missionId ?? "Mission001"
        let resolvedTopInset = max(96, topHUDInset)
        let resolvedBottomInset = max(150, bottomHUDInset)

        if let existingScene = context.coordinator.scene {
            existingScene.updateViewportInsets(top: resolvedTopInset, bottom: resolvedBottomInset)
        }

        let hasStrictPreparedMatch =
            (context.coordinator.preparedMissionId == missionToLoad)
            && (context.coordinator.scene != nil)
            && (skView.scene === context.coordinator.scene)

        // Scene already presented for this mission — nothing to do.
        if hasStrictPreparedMatch { return }

        guard availableSize.width > 0, availableSize.height > 0 else {
            dlog("[BattleSceneView] No available size, skipping scene creation")
            return
        }

        // CRITICAL FIX: Scene size must match the SKView's available bounds (via fitSceneToView),
        // and mapOrigin is computed from (scene.size - mapPixelSize)/2.
        // This ensures the tile map is centered and the top/bottom rows are reachable.
        // fitSceneToView() is called BEFORE loadMap() so BattleScene.mapOrigin is correct.
        // With scaleMode = .aspectFit the full scene (map + letterboxing) fills the SKView.
        let missionTileMap = resolvePreparedTileMap(for: missionToLoad)
        let initialRoomId = resolveInitialRoomId(for: missionToLoad)

        guard let missionTileMap, !gameState.playerTeam.isEmpty else {
            dlog("[BattleSceneView] Missing prepared combat state for \(missionToLoad); skipping scene creation")
            return
        }

        // Scene size = map pixel dimensions. With .aspectFit, SpriteKit scales to fit the view,
        // centering the map. mapOrigin = (scene.size - mapPixelDims) / 2 is always (.zero)
        // when scene.size == mapPixelDims, keeping all coordinate math simple.
        let mapPixelW  = CGFloat(TileMap.mapWidth - 1) * TileMap.hexColSpacing + TileMap.hexRadius * 2
        let mapHeight: Int
        mapHeight = missionTileMap.mapHeight
        let mapPixelH  = (CGFloat(mapHeight) + 0.5) * TileMap.hexRowSpacing
        let sceneSize  = CGSize(width: mapPixelW, height: mapPixelH)

        // Create scene at map pixel dimensions; fitSceneToView() called below
        // (before loadMap) will override self.size to match SKView bounds.
        let scene = BattleScene(size: sceneSize)
        scene.scaleMode = .aspectFit
        // CRITICAL: anchorPoint (0,0) = bottom-left. All coordinate math (mapOrigin,
        // tileCenter, focusCamera) assumes origin at bottom-left. Default (0.5, 0.5)
        // puts origin at screen center and shifts the map off to the right.
        scene.anchorPoint = CGPoint(x: 0, y: 0)
        scene.backgroundColor = UIColor(hex: "#0D0D0D")
        scene.isUserInteractionEnabled = true
        scene.updateViewportInsets(top: resolvedTopInset, bottom: resolvedBottomInset)

        // Schedule initial load on the scene. BattleScene.didMove will call loadMap +
        // placeCharacter/placeEnemy once the view is attached and scene.size is final.
        // This is the single source of truth for the first frame — doing placement
        // before presentScene was racey (view nil → fitSceneToView was a no-op →
        // wrong scene.size → wrong mapOrigin → characters off-camera).
        scene.scheduleInitialLoad(
            tileMap: missionTileMap,
            roomId: initialRoomId,
            characters: gameState.playerTeam,
            enemies: GameState.shared.enemies
        )

        dlog("[BattleSceneView] Presenting scene size: \(scene.size), view.bounds: \(skView.bounds.size), playerTeam=\(gameState.playerTeam.count), enemies=\(GameState.shared.enemies.count)")
        skView.presentScene(scene)
        context.coordinator.scene = scene
        context.coordinator.preparedMissionId = missionToLoad
    }

    private func resolvePreparedTileMap(for missionId: String) -> TileMap? {
        let rawTiles = gameState.currentMissionTilesSnapshot
        if !rawTiles.isEmpty {
            let typedTiles = rawTiles.map { row in
                row.map { TileType(rawValue: $0) ?? .floor }
            }
            return TileMap(tiles: typedTiles)
        }

        if let multiMission = MissionLoader.shared.loadMultiRoomMission(named: missionId),
           let firstRoom = multiMission.rooms.first {
            return TileMap(tiles: firstRoom.tileMap)
        }

        if let mission = MissionLoader.shared.loadMission(named: missionId) {
            return MissionLoader.shared.buildTileMap(from: mission)
        }

        // Ultimate fallback: every shipped mission has a multi-room variant.
        if let fallbackMulti = MissionLoader.shared.loadMultiRoomMission(named: "Mission001"),
           let firstRoom = fallbackMulti.rooms.first {
            return TileMap(tiles: firstRoom.tileMap)
        }

        return nil
    }

    private func resolveInitialRoomId(for missionId: String) -> String {
        if !gameState.currentRoomId.isEmpty {
            return gameState.currentRoomId
        }

        if let currentRoomId = RoomManager.shared.currentRoom?.id, !currentRoomId.isEmpty {
            return currentRoomId
        }

        if let multiMission = MissionLoader.shared.loadMultiRoomMission(named: missionId) {
            return multiMission.rooms.first?.id ?? "room_0"
        }

        return "room_0"
    }

    func makeCoordinator() -> Coordinator { Coordinator(gameState: gameState) }

    class Coordinator {
        var scene: BattleScene?
        weak var skView: SKView?
        var preparedMissionId: String?
        var gameState: GameState

        init(gameState: GameState) {
            self.gameState = gameState
            setupCombatEndObserver()
        }

        private func setupCombatEndObserver() {
            NotificationCenter.default.addObserver(
                forName: .combatAction,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let userInfo = notification.userInfo,
                      let result = userInfo["result"] as? String else { return }
                if result == "victory" || result == "defeat" {
                    let won = result == "victory"
                    DispatchQueue.main.async {
                        self?.gameState.addLog(won ? "Mission complete!" : "Mission failed.")
                    }
                }
            }
        }
    }
}

// MARK: - Combat End Overlay

/// Full-screen overlay shown the moment combat ends (victory or defeat).
/// Owns its own auto-dismiss timer so the player is never stuck if the
/// buttons fail to tap or the user just sets the device down.
///   • Victory  → tap "VIEW DEBRIEF" → debrief screen → "RETURN TO TITLE".
///   • Defeat   → tap "VIEW DEBRIEF" or "HOME SCREEN" — and after 6s with
///                no input we auto-route home so failures can't strand the
///                player on the combat scene.
struct CombatEndOverlay: View {
    @ObservedObject var gameState: GameState
    @ObservedObject var manager: PhaseManager
    let victoryText: String

    @State private var autoReturnTimer: Timer? = nil
    @State private var secondsRemaining: Int = 6

    var body: some View {
        ZStack {
            Color.black.opacity(0.88).ignoresSafeArea()
            VStack(spacing: 16) {
                // Zero State studio sigil — sits ABOVE the RUN COMPLETE / RUN
                // FAILED headline. Large (72pt) and at full opacity so it
                // reads like a mission-end seal stamped on top of the result.
                // Uses mark_3 (target glyph — distinct from the briefing and
                // mission-select corner sigils so each major screen has its
                // own).
                Image("zero_state_mark_3")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .opacity(0.95)
                    .padding(.bottom, -8)

                Text(gameState.combatWon == true ? "RUN COMPLETE" : "RUN FAILED")
                    .font(.system(size: 36, weight: .black))
                    .foregroundColor(gameState.combatWon == true ? Color(hex: "00FF88") : Color(hex: "FF3333"))
                if gameState.combatWon != nil {
                    Text(gameState.combatWon == true ? victoryText : "Mission failed — all runners down")
                        .font(.headline)
                        .foregroundColor(.gray)
                }

                // Mission RANK earned — THIS run's score, not the historical
                // best (a C-grade replay used to flash the old S-rank because
                // bestScore was already merged via max() by recordVictory).
                if gameState.combatWon == true, manager.selectedMissionId != nil {
                    let score = MissionStatsStore.shared.lastRunScore
                    let rank = MissionStatsStore.rank(forScore: score)
                    HStack(spacing: 8) {
                        Text("RANK")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.6))
                        Text(rank)
                            .font(.system(size: 30, weight: .black, design: .monospaced))
                            .foregroundColor(MissionCard.rankColor(rank))
                        Text("· \(score) pts")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }

                // Runner scorecard — each runner's level, key stats, and what
                // they gained this mission. Scroll-capped so it never pushes the
                // buttons off small screens.
                if gameState.combatWon == true {
                    VStack(spacing: 5) {
                        Text("RUNNERS")
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .tracking(3)
                            .foregroundColor(Color(hex: "00FF88").opacity(0.8))
                        ScrollView {
                            VStack(spacing: 6) {
                                ForEach(gameState.playerTeam) { runner in
                                    RunnerScorecardRow(runner: runner)
                                }
                            }
                        }
                        .frame(maxHeight: 240)
                    }
                    .padding(.horizontal, 18)
                }

                // Primary: VIEW DEBRIEF
                Button(action: viewDebrief) {
                    Text("VIEW DEBRIEF")
                        .font(.headline)
                        .foregroundColor(.black)
                        .menuButtonSize(phone: CGSize(width: 240, height: 52),
                                        pad: CGSize(width: 360, height: 60))
                        .background(gameState.combatWon == true ? Color(hex: "00FF88") : Color(hex: "FF3333"))
                        .cornerRadius(8)
                }

                // Always-present HOME SCREEN — gives the player an immediate
                // escape hatch on either outcome. Coloured to match outcome.
                Button(action: returnHome) {
                    Text("HOME SCREEN")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(gameState.combatWon == true ? Color(hex: "00FF88") : Color(hex: "FF3333"))
                        .menuButtonSize(phone: CGSize(width: 200, height: 40),
                                        pad: CGSize(width: 300, height: 50))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(
                                    (gameState.combatWon == true ? Color(hex: "00FF88") : Color(hex: "FF3333")).opacity(0.6),
                                    lineWidth: 1
                                )
                        )
                }

                // Auto-return countdown only on failure — so the player is
                // never left stranded on a "RUN FAILED" screen.
                if gameState.combatWon == false {
                    Text("Auto-returning to title in \(secondsRemaining)s …")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(Color(hex: "FF3333").opacity(0.7))
                        .padding(.top, 12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            // Start auto-return safety timer on failure only
            if gameState.combatWon == false {
                secondsRemaining = 6
                autoReturnTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { t in
                    Task { @MainActor in
                        secondsRemaining -= 1
                        if secondsRemaining <= 0 {
                            t.invalidate()
                            returnHome()
                        }
                    }
                }
            }
        }
        .onDisappear {
            autoReturnTimer?.invalidate()
            autoReturnTimer = nil
        }
    }

    private func viewDebrief() {
        HapticsManager.shared.buttonTap()
        autoReturnTimer?.invalidate()
        let won = gameState.combatWon ?? false
        gameState.combatEnded = false
        gameState.combatWon = nil
        _ = manager.transition(to: .endCombat(won: won))
    }

    private func returnHome() {
        HapticsManager.shared.buttonTap()
        autoReturnTimer?.invalidate()
        gameState.combatEnded = false
        gameState.combatWon = nil
        _ = manager.transition(to: .returnToTitle)
    }
}

// MARK: - Debrief View

struct DebriefView: View {
    @ObservedObject var manager: PhaseManager

    /// Per-mission reward summary on the CONTRACT FULFILLED screen.
    /// Reads live mission-objective state (`GameState.shared.dataAcquired`,
    /// `grimoireAcquired`) so the line reflects what the player ACTUALLY
    /// recovered, not just what the mission could pay out.
    /// Format an integer with thousands separators (e.g. 57500 → "57,500").
    private func yen(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// Per-mission reward summary. Mirrors `MissionStatsStore.recordVictory`
    /// EXACTLY: the credited total is (base + earned bonuses) × rank × heat
    /// risk × run factor, so alongside the objective lines we show the payout
    /// FACTORS — otherwise the total wouldn't match the base+bonus arithmetic
    /// a player would do in their head. Replays pay a 25% residual contract
    /// rate (was ¥0 before the 2026-07 economy pass).
    private var rewardText: String {
        guard manager.combatWon == true else { return "No payout — mission failed" }
        let missionId = manager.selectedMissionId ?? ""
        let data = GameState.shared.dataAcquired
        let grimoire = GameState.shared.grimoireAcquired

        let dataB = MissionStatsStore.dataBonus(missionId: missionId)
        let grimB = MissionStatsStore.grimoireBonus(missionId: missionId)
        let stats = MissionStatsStore.shared
        // What recordVictory ACTUALLY banked this victory.
        let credited = stats.lastWalletCredit

        var lines: [String] = []

        if dataB > 0 {
            lines.append(data ? "✓ DATA RECOVERED  (+¥\(yen(dataB)))" : "✗ DATA MISSED")
        }
        if grimB > 0 {
            lines.append(grimoire ? "✓ GRIMOIRE ACQUIRED  (+¥\(yen(grimB)))" : "✗ GRIMOIRE LEFT BEHIND")
        }
        // Payout factors — only the ones that actually moved the number.
        if stats.lastRankMultiplier > 1.0 {
            lines.append("✓ RANK BONUS ×\(String(format: "%.2f", stats.lastRankMultiplier))")
        }
        if stats.lastRiskMultiplier > 1.0 {
            lines.append("✓ HEAT PAY ×\(String(format: "%.2f", stats.lastRiskMultiplier))")
        }
        if stats.lastRunFactor < 1.0 {
            lines.append("◦ REPLAY CONTRACT — \(Int(stats.lastRunFactor * 100))% RATE")
        }

        var result = "¥\(yen(credited)) earned"
        if !lines.isEmpty { result += "\n" + lines.joined(separator: "\n") }
        return result
    }

    var body: some View {
        ZStack {
            // Zero State studio sigil — centered crest above the
            // CONTRACT FULFILLED / FAILED title. Matches mission select
            // and briefing.
            VStack {
                Image("zero_state_mark_3")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                    .opacity(0.55)
                    .padding(.top, 6)
                Spacer()
            }
            .allowsHitTesting(false)

            VStack(spacing: 32) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                manager.combatWon == true ? Color(hex: "00FF88") : Color(hex: "FF3333"),
                                lineWidth: 2
                            )
                    )

                Text(manager.combatWon == true ? "RUN COMPLETE" : "RUN FAILED")
                    .font(.system(size: 28, weight: .black))
                    .foregroundColor(manager.combatWon == true ? Color(hex: "00FF88") : Color(hex: "FF3333"))
            }
            .frame(height: 80)

            VStack(spacing: 16) {
                Text(rewardText)
                    .foregroundColor(manager.combatWon == true ? Color(hex: "00FF88") : Color(hex: "FF3333"))
                    .font(.headline)
                    .multilineTextAlignment(.center)

                // Wallet balance — shows the running total nuyen after this
                // mission's payout has been credited. Only on victory (failed
                // runs don't pay out so the balance line would be misleading).
                if manager.combatWon == true {
                    HStack(spacing: 8) {
                        Text("WALLET")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(hex: "FFCC00").opacity(0.75))
                            .tracking(2)
                        Text("¥\(MissionStatsStore.shared.playerNuyen.formatted())")
                            .font(.system(size: 14, weight: .black, design: .monospaced))
                            .foregroundColor(Color(hex: "FFCC00"))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.black.opacity(0.4))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color(hex: "FFCC00").opacity(0.45), lineWidth: 1)
                            )
                    )
                }

                // Stats display — ROUNDS / ENEMIES are tactical-combat stats;
                // the solo mini-games (M*.5) never populate them, so they'd show
                // stale counts from the last tactical mission. Hide for those.
                if !(manager.selectedMissionId ?? "").hasSuffix("_5") {
                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ROUNDS")
                            .font(.system(size: 9, weight: .black))
                            .foregroundColor(Color(hex: "00FF88").opacity(0.7))
                        Text("\(GameState.shared.roundNumber)")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("ENEMIES DEFEATED")
                            .font(.system(size: 9, weight: .black))
                            .foregroundColor(Color(hex: "00FF88").opacity(0.7))
                        // Running tally across ALL rooms — `gameState.enemies` only
                        // holds the current room's roster, so it would under-count
                        // by one (or more) rooms in multi-room missions.
                        Text("\(GameState.shared.missionEnemiesDefeated)")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color(hex: "0F0F1E"))
                .cornerRadius(8)
                }

                // Secondary-objective status chips. Surface the data /
                // grimoire recovery outcome as visible chips so the player
                // immediately sees whether they got the bonus haul without
                // having to parse the multi-line reward text above. Only
                // show on victory and only for missions where the
                // objective is actually applicable.
                if manager.combatWon == true {
                    let mid = manager.selectedMissionId ?? ""
                    let hasTerminal = ["Mission002","Mission003","Mission004","Mission005","Mission006"].contains(mid)
                    let hasGrimoire = (mid == "Mission003")
                    if hasTerminal || hasGrimoire {
                        HStack(spacing: 8) {
                            if hasTerminal {
                                DebriefStatusChip(
                                    label: "DATA",
                                    acquired: GameState.shared.dataAcquired
                                )
                            }
                            if hasGrimoire {
                                DebriefStatusChip(
                                    label: "GRIMOIRE",
                                    acquired: GameState.shared.grimoireAcquired
                                )
                            }
                        }
                    }
                }
            }
            .padding(20)
            .background(Color(hex: "0A0A14"))
            .cornerRadius(12)

            Spacer()

            Button(action: {
                HapticsManager.shared.buttonTap()
                // After a successful M6 (the final mission), this button leads
                // into the game-ending epilogue instead of the menu. All other
                // debriefs (M1–M5 wins + any loss) go straight back to the
                // mission select screen.
                let isFinaleVictory = (manager.selectedMissionId == "Mission006"
                                       && manager.combatWon == true)
                if isFinaleVictory {
                    _ = manager.transition(to: .viewGameEnding)
                } else {
                    _ = manager.transition(to: .returnToTitle)
                }
            }) {
                // Button label changes for the finale-victory case so the
                // player isn't surprised by a cutscene instead of the menu.
                let isFinaleVictory = (manager.selectedMissionId == "Mission006"
                                       && manager.combatWon == true)
                Text(isFinaleVictory ? "VIEW EPILOGUE" : "RETURN TO MENU")
                    .font(.headline)
                    .foregroundColor(.black)
                    .menuButtonSize(phone: CGSize(width: 220, height: 50),
                                    pad: CGSize(width: 340, height: 60))
                    // Match the debrief outcome colour so failure debrief reads
                    // as failure instead of celebrating in green.
                    .background(manager.combatWon == true ? Color(hex: "00FF88") : Color(hex: "FF3333"))
                    .cornerRadius(8)
            }
        }
        .padding(24)
        }   // close outer ZStack (Zero State mark watermark wrapper)
        .overlay(TutorialCoachOverlay())
        .onAppear {
            // First victory debrief explains the S/A/B/C rank. New Game+ card
            // (enqueued at campaign completion) also surfaces here if pending.
            if manager.combatWon == true { TutorialCoach.shared.enqueue(.missionRanks) }
        }
    }
}

// MARK: - Debrief Status Chip

/// Visual chip for the debrief screen showing a secondary-objective
/// outcome — DATA / GRIMOIRE acquired vs missed. Green ✓ on success,
/// dim red ✗ on miss. Designed to read at a glance so the player
/// doesn't have to parse the multi-line reward text.
private struct DebriefStatusChip: View {
    let label: String
    let acquired: Bool

    var body: some View {
        let tint: Color = acquired ? Color(hex: "00FF88") : Color(hex: "FF3344")
        HStack(spacing: 6) {
            Image(systemName: acquired ? "checkmark.seal.fill" : "xmark.octagon.fill")
                .font(.system(size: 10))
                .foregroundColor(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .tracking(1.5)
                    .foregroundColor(tint.opacity(0.75))
                Text(acquired ? "ACQUIRED" : "MISSED")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(tint)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.45))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(tint.opacity(0.5), lineWidth: 1)
                )
        )
    }
}

// MARK: - Phase Manager

/// Renamed to avoid collision with combat runtime GameState class
/// Canonical active phase-flow authority for UI/runtime screen routing.
/// Transition rule edits must be specified in
/// `docs/architecture/PhaseFlowAuthorityMatrix.md` first.
@MainActor
final class PhaseManager: ObservableObject {

    @Published private(set) var currentPhase: GamePhase = .title
    @Published private(set) var selectedMissionId: String?
    @Published private(set) var combatWon: Bool?

    private var stateHistory: [GamePhase] = [.title]

    func transition(to event: StateTransition) -> Bool {
        let nextState = computeNext(from: currentPhase, event: event)
        if nextState == currentPhase { return false }

        if case .selectMission(let id) = event { selectedMissionId = id }
        // The chase (M3.5) launches via .viewDropIntro, NOT .selectMission, so
        // selectedMissionId would otherwise stay stale on "Mission003" and the
        // chase debrief would inherit M3's data + grimoire objective lines.
        if case .viewDropIntro = event { selectedMissionId = "Mission003_5" }
        if case .endCombat(let won) = event { combatWon = won }
        if case .endBrawl(let won) = event { combatWon = won }
        if case .endMirrorline(let won) = event { combatWon = won }
        if case .endColdTrace(let won) = event { combatWon = won }
        if case .endChase(let won) = event { combatWon = won }

        stateHistory.append(nextState)
        currentPhase = nextState
        return true
    }

    var stateStack: [GamePhase] { stateHistory }

    /// Replay modes: the Endless Gauntlet floors and the procedural side
    /// contracts. They recombine shipped rooms and carry no authored story,
    /// so the campaign intro/outro VNs are skipped for them.
    static func isReplayMissionId(_ id: String) -> Bool {
        id == GauntletStore.gauntletMissionId || ContractStore.isContractId(id)
    }

    /// Canonical transition matrix implementation (active authority).
    /// Keep in lockstep with `PhaseFlowAuthorityMatrix.md`.
    private func computeNext(from state: GamePhase, event: StateTransition) -> GamePhase {
        switch (state, event) {
        case (.title, .startGame):                          return .missionSelect
        case (.title, .viewPrologue):                       return .prologue
        case (.prologue, .finishPrologue):                  return .title           // loop back, don't auto-start
        case (.prologue, .returnToTitle):                   return .title           // skip mid-scene
        case (.missionSelect, .selectMission(let id)):
            // Replay modes (gauntlet floors, side contracts) have no story to
            // tell — they recombine shipped rooms, and the contract board has
            // already briefed the job. Running the campaign VN in front of them
            // just gates the fight behind beats about a mission you aren't on.
            // Straight to briefing (loadout still matters); campaign missions
            // keep the cutscene.
            return Self.isReplayMissionId(id) ? .briefing : .missionIntro
        // Standard tactical missions (M1–M6) go intro → briefing → combat.
        // M4.5 "Basement Brawl" uses the same intro VN infrastructure but
        // routes straight from the intro into its bespoke gameplay scene —
        // no briefing screen, no hex-grid combat.
        case (.missionIntro, .finishMissionIntro):
            // Half-missions route from MissionIntro straight into their bespoke
            // gameplay scene instead of through Briefing → Combat.
            switch selectedMissionId {
            case "Mission004_5": return .basementBrawl
            case "Mission002_5": return .mirrorline
            case "Mission005_5": return .coldTrace
            default:             return .briefing
            }
        case (.missionIntro, .returnToTitle):               return .missionSelect    // skip mid-cutscene
        case (.missionSelect, .viewDropIntro):              return .dropIntro
        case (.dropIntro, .finishDropIntro):                return .hoverbikeChase
        case (.dropIntro, .returnToTitle):                  return .missionSelect    // skip mid-cutscene
        case (.missionSelect, .viewHoverbikeChase):         return .hoverbikeChase
        case (.hoverbikeChase, .finishHoverbikeChase):      return .missionSelect    // legacy/abort path
        case (.hoverbikeChase, .endChase(let won)):         return won ? .missionOutro : .debrief
        case (.hoverbikeChase, .returnToTitle):             return .missionSelect   // abort mid-chase
        // M4.5 BasementBrawl — Raze's solo melee duel. On win runs through
        // the standard mission-outro VN; on loss skips outro and goes
        // straight to the debrief (same pattern as tactical missions).
        case (.basementBrawl, .endBrawl(let won)):          return won ? .missionOutro : .debrief
        case (.basementBrawl, .returnToTitle):              return .missionSelect   // abort mid-brawl
        // M2.5 Mirrorline — Sable's solo astral sigil-tracing duel. Same
        // win→outro / loss→debrief pattern as the brawl.
        case (.mirrorline, .endMirrorline(let won)):        return won ? .missionOutro : .debrief
        case (.mirrorline, .returnToTitle):                 return .missionSelect   // abort mid-trance
        // M5.5 Cold Trace — Cipher's solo matrix-dive process-triage. Same
        // win→outro / loss→debrief pattern as the brawl + mirrorline.
        case (.coldTrace, .endColdTrace(let won)):          return won ? .missionOutro : .debrief
        case (.coldTrace, .returnToTitle):                  return .missionSelect   // abort mid-dive
        case (.briefing, .beginMission):                    return .combat
        // Victory → mission outro VN scene before scoring; defeat → straight to debrief.
        case (.combat, .endCombat(let won)):
            // Same reasoning as the intro skip above — a won contract/gauntlet
            // floor goes straight to debrief rather than playing campaign
            // closing beats for a mission the player never started.
            guard won else { return .debrief }
            // Unknown id falls back to the campaign path — a missing outro is a
            // worse regression than an extra one.
            let isReplay = selectedMissionId.map(Self.isReplayMissionId) ?? false
            return isReplay ? .debrief : .missionOutro
        case (.combat, .returnToTitle):                     return .missionSelect  // abort from combat → menu
        case (.missionOutro, .finishMissionOutro):          return .debrief
        case (.missionOutro, .viewDebrief):                 return .debrief        // safety: caller-driven skip
        case (.missionOutro, .returnToTitle):               return .missionSelect  // skip mid-outro
        case (.debrief, .viewGameEnding):                   return .gameEnding     // M6 victory only — caller gates
        case (.gameEnding, .finishGameEnding):              return .title          // epilogue done → title
        case (.gameEnding, .returnToTitle):                 return .title          // skip mid-ending → title
        case (.debrief, .returnToTitle):                    return .missionSelect  // post-mission → menu (was .title)
        case (.missionSelect, .returnToTitle):              return .title          // EXIT the run select → main title
        case (_, .returnToTitle):                           return .missionSelect  // safety catch-all → menu
        default:                                             return state
        }
    }
}

// MARK: - Mission Briefing Overlay

struct MissionBriefingOverlay: View {
    let mission: Mission?
    /// When the briefing is for a multi-room mission, the caller passes the total
    /// hostiles across all rooms so the badge isn't capped at the single-room count.
    var enemyCountOverride: Int? = nil
    var titleOverride: String? = nil
    var descriptionOverride: String? = nil
    var difficultyOverride: String? = nil
    /// Mission ID — used to decide whether to surface the "HACK TERMINAL"
    /// secondary-objective chip. Optional so legacy callers without an id
    /// still work (chip simply hides).
    var missionId: String? = nil
    /// Called after the dismiss animation finishes so the parent can hide the overlay.
    var onDismissed: (() -> Void)? = nil

    /// True if this mission has a recoverable data terminal as a secondary
    /// objective. Same rule as BriefingView.missionHasTerminal — M2-M6 do,
    /// M1 doesn't. Mirror kept here so the overlay doesn't need to read
    /// from GameState (which may not be set yet at briefing time).
    private var hasTerminal: Bool {
        switch missionId ?? "" {
        case "Mission002", "Mission003", "Mission004", "Mission005", "Mission006":
            return true
        default:
            return false
        }
    }

    @State private var opacity: Double = 0
    @State private var showContent = false
    @State private var contentOffset: CGFloat = 40

    private var missionTitle: String {
        titleOverride ?? mission?.title ?? "THE EXTRACTION"
    }

    private var missionDesc: String {
        descriptionOverride ?? mission?.description ?? "Infiltrate the corporate facility. Neutralize all hostiles. Extract at the marked point."
    }

    private var enemyCount: Int {
        if let override = enemyCountOverride { return override }
        return mission?.enemies.count ?? 4
    }

    private var dangerColor: Color {
        switch (difficultyOverride ?? mission?.difficulty ?? "MODERATE").lowercased() {
        case "very hard", "extreme": return Color(hex: "FF3333")
        case "hard", "high":         return Color(hex: "FF8800")
        case "normal", "moderate":   return Color(hex: "FFCC00")
        default:                     return Color(hex: "00FF88")  // Easy / unknown
        }
    }

    var body: some View {
        ZStack {
            // Dark backdrop
            Color.black.opacity(opacity)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            // (Zero State studio sigil is rendered INLINE below the
            // mission title — see the title VStack below. Placing it as
            // a centered crest directly under the mission name reads as
            // a "mission seal" / official packet header instead of as
            // a stray corner glyph or a too-far-away footer.)

            if showContent {
                VStack(spacing: 0) {
                    // Danger level bar
                    Rectangle()
                        .fill(dangerColor)
                        .frame(height: 3)

                    // Top section: mission name + decorative lines
                    VStack(spacing: 12) {
                        HStack {
                            ThinLine()
                            Text("MISSION BRIEFING")
                                .font(.system(size: 11, weight: .black))
                                .foregroundColor(Color(hex: "00FF88").opacity(0.8))
                                .tracking(3)
                            ThinLine()
                        }

                        Text(missionTitle.uppercased())
                            .font(.system(size: 36, weight: .black))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)

                        // Zero State studio sigil — centered directly
                        // below the mission name. Acts as an "official
                        // mission packet seal" between the title and
                        // the operational summary, where it has open
                        // vertical breathing room and aligns visually
                        // with the centered title chrome above.
                        Image("zero_state_mark_4")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 44, height: 44)
                            .opacity(0.85)
                            .padding(.top, 4)
                    }
                    .padding(.top, 40)

                    Spacer()

                    // Middle: story text + intel
                    VStack(spacing: 24) {
                        // Story text box
                        VStack(alignment: .leading, spacing: 10) {
                            Text("OPERATIONAL SUMMARY")
                                .font(.system(size: 9, weight: .black))
                                .foregroundColor(Color(hex: "00FF88").opacity(0.7))
                                .tracking(2)

                            Text(missionDesc)
                                .font(.system(size: 15, design: .monospaced))
                                .foregroundColor(Color.white.opacity(0.9))
                                .lineSpacing(4)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(hex: "0A0A18"))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color(hex: "00FF88").opacity(0.3), lineWidth: 1)
                                )
                        )

                        // Intel grid
                        // OBJECTIVE was hardcoded to "NEUTRALIZE ALL", but the in-game
                        // objective banner and the actual mission win condition are
                        // "Reach the extraction point". Showing three different
                        // objectives (briefing says NEUTRALIZE, banner says REACH EXIT,
                        // operational summary says EXTRACT + GET OUT) confused playtest.
                        HStack(spacing: 12) {
                            IntelBadge(label: "HOSTILES", value: "\(enemyCount)")
                            IntelBadge(label: "OBJECTIVE", value: "REACH EXIT")
                            if hasTerminal {
                                IntelBadge(label: "DATA", value: "HACK TERMINAL")
                            }
                            IntelBadge(label: "EXFIL", value: "EXTRACTION PT.")
                        }
                    }
                    .padding(.horizontal, 24)

                    Spacer()

                    // Bottom: dismiss prompt
                    VStack(spacing: 12) {
                        // Animated pulse indicator
                        Circle()
                            .fill(Color(hex: "00FF88"))
                            .frame(width: 8, height: 8)
                            .opacity(0.6)

                        Text("TAP ANYWHERE TO BEGIN")
                            .font(.system(size: 11, weight: .black))
                            .foregroundColor(Color.white.opacity(0.4))
                            .tracking(2)
                    }
                    .padding(.bottom, 40)
                    .offset(y: contentOffset)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) { opacity = 1.0 }
            withDelay(0.3) {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                    showContent = true
                    contentOffset = 0
                }
            }
        }
    }

    private func dismiss() {
        withAnimation(.easeIn(duration: 0.3)) {
            showContent = false
            contentOffset = 40
            opacity = 0
        }
        // Let the fade-out finish before the parent unmounts the overlay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            onDismissed?()
        }
    }
}

struct ThinLine: View {
    var body: some View {
        Rectangle()
            .fill(Color(hex: "00FF88").opacity(0.3))
            .frame(height: 1)
    }
}

struct IntelBadge: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.system(size: 8, weight: .black))
                .foregroundColor(Color(hex: "00FF88").opacity(0.7))
                .tracking(1)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(hex: "0F0F1E"))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(hex: "1E1E3E"), lineWidth: 1)
                )
        )
    }
}

private func withDelay(_ delay: Double, animation: @escaping () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: animation)
}

import SwiftUI
import SpriteKit
import QuartzCore

// MARK: - Mission Objective Banner

struct MissionObjectiveBanner: View {
    let missionTitle: String
    let extractionX: Int
    let extractionY: Int
    @State private var pulse: Bool = false
    @State private var isVisible: Bool = true
    @State private var hideTimer: Timer?

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
                        Text("MISSION: \(missionTitle)")
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .foregroundColor(Color(hex: "00FF88"))
                            .tracking(0.5)
                        Text("OBJECTIVE: Reach the ★ EXIT (green glow) at north end")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.white.opacity(0.7))
                    }

                    Spacer()

                    // Toggle button
                    Button(action: {
                        withAnimation { isVisible = false }
                        hideTimer?.invalidate()
                    }) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "00FF88").opacity(0.6))
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
            } else {
                Button(action: {
                    withAnimation { isVisible = true }
                    startAutoHideTimer()
                }) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "00FF88").opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding(8)
            }
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

@main
struct ShadowrunGameApp: App {
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

    var body: some View {
        ZStack {
            Color(hex: "0D0D0D").ignoresSafeArea()

            switch phaseManager.currentPhase {
            case .title:
                TitleView(manager: phaseManager)
            case .missionSelect:
                MissionSelectView(manager: phaseManager)
            case .briefing:
                BriefingView(manager: phaseManager)
            case .combat:
                CombatView(manager: phaseManager, gameState: gameState)
            case .debrief:
                DebriefView(manager: phaseManager)
            }
        }
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

struct TitleView: View {
    @ObservedObject var manager: PhaseManager

    var body: some View {
        ZStack {
            // Matrix rain background
            MatrixRainView()
                .opacity(0.1)

            VStack(spacing: 32) {
                VStack(spacing: 8) {
                    Text("SHADOWRUN")
                        .font(.system(size: 36, weight: .black)).minimumScaleFactor(0.8)
                        .foregroundColor(Color(hex: "00FF88"))
                        .tracking(2)
                        .shadow(color: Color(hex: "00FF88").opacity(0.6), radius: 12)
                    Text("TACTICAL")
                        .font(.system(size: 24, weight: .light))
                        .foregroundColor(.gray)
                        .tracking(8)

                    // Horizontal divider
                    Rectangle()
                        .fill(Color(hex: "00FF88").opacity(0.3))
                        .frame(height: 1)
                        .frame(width: 200)
                }

                VStack(spacing: 16) {
                    Button(action: {
                        HapticsManager.shared.buttonTap()
                        _ = manager.transition(to: .startGame)
                    }) {
                        Text("NEW RUN")
                            .font(.headline)
                            .foregroundColor(.black)
                            .frame(width: 220, height: 50)
                            .background(Color(hex: "00FF88"))
                            .cornerRadius(8)
                    }
                    Button(action: {
                        HapticsManager.shared.buttonTap()
                    }) {
                        Text("CONTINUE (COMING SOON)")
                            .font(.headline)
                            .foregroundColor(Color(hex: "00FF88").opacity(0.4))
                            .frame(width: 220, height: 50)
                            .background(Color.clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color(hex: "00FF88").opacity(0.3), lineWidth: 2)
                            )
                    }
                    .disabled(true)
                }

                Spacer()

                // Version text
                Text("v0.1 // TACTICAL COMBAT SYSTEM")
                    .font(.system(size: 10, weight: .light, design: .monospaced))
                    .foregroundColor(Color(hex: "00FF88").opacity(0.5))
                    .tracking(1)
            }
            .padding(24)
        }
    }
}

// MARK: - Mission Select View

struct MissionSelectView: View {
    @ObservedObject var manager: PhaseManager

    private let missions: [(id: String, title: String, desc: String, risk: String, badge: String?)] = [
        ("Mission001", "The Extraction",    "Corp facility east side. Guards on patrol, drone incoming. Reach the north exit.", "MODERATE", "INTRO"),
        ("Mission002", "Ghost Protocol",    "Server farm locked by rogue AI. Drone swarms on every floor. Bring firepower.", "HIGH", nil),
        ("Mission003", "The Mage's Lair",  "Blood mage with guards and a healer. Eliminate the mage before his squad heals up.", "HARD", nil),
        ("Mission004", "Dead Man's Switch", "Aztechnology HQ. Elite on station, mage at top floor. Beat the lockdown clock.", "EXTREME", nil),
        ("Mission005", "Mekton Blues",      "Saeder-Krupp industrial complex. Two elites, drone corridor, and a field medic.", "EXTREME", "BOSS")
    ]

    var body: some View {
        VStack(spacing: 24) {
            Text("SELECT RUN")
                .font(.system(size: 22, weight: .black))
                .foregroundColor(Color(hex: "00FF88"))
                .tracking(4)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(Array(missions.enumerated()), id: \.element.id) { index, mission in
                        MissionCard(
                            id: mission.id,
                            number: String(format: "%02d", index + 1),
                            title: mission.title,
                            description: mission.desc,
                            risk: mission.risk,
                            badge: mission.badge,
                            isLocked: false,
                            onSelect: {
                                HapticsManager.shared.buttonTap()
                                _ = manager.transition(to: .selectMission(mission.id))
                            }
                        )
                    }
                }
                .padding(.bottom, 16)
            }
            .frame(maxHeight: .infinity)

            Spacer()
        }
        .padding(24)
    }
}

struct MissionCard: View {
    let id: String
    let number: String
    let title: String
    let description: String
    let risk: String
    let badge: String?
    let isLocked: Bool
    let onSelect: () -> Void

    private var riskColor: Color {
        switch risk {
        case "MODERATE": return Color(hex: "00FF88")
        case "HIGH":     return Color(hex: "FF8800")
        case "HARD":     return Color(hex: "FF5500")
        case "EXTREME":  return Color(hex: "FF1133")
        default:         return Color.gray
        }
    }

    private var skullCount: Int {
        switch risk {
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

    private var missionTitle: String {
        loadedMission?.title ?? manager.selectedMissionId ?? "Unknown"
    }

    private var missionDesc: String {
        loadedMission?.description ?? "No description available."
    }

    private var teamRoster: [Character] {
        let team = GameState.shared.playerTeam
        return team.isEmpty ? Character.allRunners : team
    }

    private var reward: String {
        switch manager.selectedMissionId ?? "" {
        case "Mission001": return "¥15,000 + expenses"
        case "Mission002": return "¥28,000 + AI core (if recovered)"
        case "Mission003": return "¥40,000 + mage's grimoire"
        case "Mission004": return "¥50,000 + security override codes"
        case "Mission005": return "¥60,000 + Mekton prototype (if recovered)"
        default:            return "¥15,000"
        }
    }

    private var riskLevel: String {
        switch manager.selectedMissionId ?? "" {
        case "Mission001": return "MODERATE"
        case "Mission002": return "HIGH"
        case "Mission003": return "EXTREME"
        case "Mission004": return "EXTREME"
        case "Mission005": return "HIGH"
        default:            return "UNKNOWN"
        }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 24) {
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

                Spacer()

                Button(action: {
                    HapticsManager.shared.combatStart()
                    _ = manager.transition(to: .beginMission)
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
                    .frame(width: 240, height: 50)
                }
            }
            .padding(24)
            .onAppear { loadMission() }

            // Full-screen mission briefing overlay — tap to dismiss
            MissionBriefingOverlay(mission: loadedMission)
        }
    }

    private func briefingRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundColor(Color(hex: "00FF88").opacity(0.7))
                .frame(width: 80, alignment: .leading)
            Text(value)
                .foregroundColor(.white)
        }
        .font(.system(.callout, design: .monospaced))
    }

    private func loadMission() {
        guard let id = manager.selectedMissionId else { return }
        loadedMission = MissionLoader.shared.loadMission(named: id)
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

    private var victoryText: String {
        switch manager.selectedMissionId ?? "" {
        case "Mission001": return "¥15,000 earned"
        case "Mission002": return "¥28,000 earned + AI core (if recovered)"
        case "Mission003": return "¥40,000 earned + mage's grimoire"
        case "Mission004": return "¥50,000 earned + security override codes"
        case "Mission005": return "¥60,000 earned + Mekton prototype (if recovered)"
        default:            return "¥15,000 earned"
        }
    }

    private var missionTitle: String {
        switch manager.selectedMissionId ?? "" {
        case "Mission001": return "The Extraction"
        case "Mission002": return "Ghost in the Shell"
        case "Mission003": return "The Mage's Lair"
        case "Mission004": return "Dead Man's Switch"
        case "Mission005": return "Mekton Blues"
        default:            return "Unknown Mission"
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Full-screen SpriteKit board — GeometryReader gives us the real available size
            GeometryReader { geometry in
                BattleSceneView(
                    gameState: gameState,
                    missionId: manager.selectedMissionId,
                    parentSize: geometry.size
                )
            }
            .ignoresSafeArea()

            // Overlays — shown only during active combat
            if !gameState.combatEnded {
                // TOP LEFT: Mission objective banner
                VStack {
                    MissionObjectiveBanner(
                        missionTitle: missionTitle,
                        extractionX: gameState.extractionX,
                        extractionY: gameState.extractionY
                    )
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    Spacer()
                }

                // TOP RIGHT: lightweight diagnostics
                VStack {
                    HStack {
                        Spacer()
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
                            .padding(.top, 8)
                            .padding(.trailing, 12)
                        }
                    }
                    Spacer()
                }
            }

            if gameState.combatEnded {
                // Combat ended overlay
                VStack(spacing: 24) {
                    Text(gameState.combatWon == true ? "RUN COMPLETE" : "RUN FAILED")
                        .font(.system(size: 36, weight: .black))
                        .foregroundColor(gameState.combatWon == true ? Color(hex: "00FF88") : Color(hex: "FF3333"))
                    if gameState.combatWon != nil {
                        Text(gameState.combatWon == true ? victoryText : "Mission failed — all runners down")
                            .font(.headline)
                            .foregroundColor(.gray)
                    }
                    Button(action: {
                        HapticsManager.shared.buttonTap()
                        let won = gameState.combatWon ?? false
                        gameState.combatEnded = false
                        gameState.combatWon = nil
                        // endCombat → debrief → then user taps return. Or go straight to title.
                        _ = manager.transition(to: .endCombat(won: won))
                    }) {
                        Text(gameState.combatWon == true ? "VIEW DEBRIEF" : "RETURN TO TITLE")
                            .font(.headline)
                            .foregroundColor(.black)
                            .frame(width: 220, height: 50)
                            .background(gameState.combatWon == true ? Color(hex: "00FF88") : Color(hex: "FF3333"))
                            .cornerRadius(8)
                    }
                }
                .padding(32)
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.88))
            } else {
                // SwiftUI combat UI — bottom-aligned, content-sized
                CombatUI(
                    gameState: gameState,
                    diagnosticsVisible: showDiagnostics,
                    onToggleDiagnostics: { showDiagnostics.toggle() },
                    onAttack: { gameState.performAttack() },
                    onDefend: { gameState.performDefend() },
                    onSpell: { /* handled by SpellPickerSheet inside CombatUI */ },
                    onBlitz: { gameState.performBlitz() },
                    onHack: { gameState.performHack() },
                    onIntimidate: { gameState.performIntimidate() },
                    onItems: { gameState.performUseItem() },
                    onRecover: { gameState.performLayLow() },
                    onEndTurn: { gameState.endTurn() }
                )
                .background(
                    CombatTheme.background.opacity(0.92)
                )
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .onAppear { FPSMonitor.shared.start() }
        .onDisappear { FPSMonitor.shared.stop() }
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

/// SKView that forces all touches to the scene, bypassing SwiftUI overlay hit-testing
class ForwardingSKView: SKView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        return self  // claim every touch in our bounds
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        (scene as? BattleScene)?.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        (scene as? BattleScene)?.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        (scene as? BattleScene)?.touchesEnded(touches, with: event)
    }
}

struct BattleSceneView: UIViewRepresentable {
    @ObservedObject var gameState: GameState
    var missionId: String?
    var parentSize: CGSize = .zero

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
        print("[BattleSceneView] makeUIView frame: \(skView.frame.size)")
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
            print("[BattleSceneView] Resized SKView to: \(availableSize)")
        }

        // Scene already presented — nothing to do.
        if skView.scene is BattleScene { return }

        guard availableSize.width > 0, availableSize.height > 0 else {
            print("[BattleSceneView] No available size, skipping scene creation")
            return
        }

        // CRITICAL FIX: Scene size must match the SKView's available bounds (via fitSceneToView),
        // and mapOrigin is computed from (scene.size - mapPixelSize)/2.
        // This ensures the tile map is centered and the top/bottom rows are reachable.
        // fitSceneToView() is called BEFORE loadMap() so BattleScene.mapOrigin is correct.
        // With scaleMode = .aspectFit the full scene (map + letterboxing) fills the SKView.
        let missionToLoad = missionId ?? "Mission001"
        let missionTileMap: TileMap?
        if let multiMission = MissionLoader.shared.loadMultiRoomMission(named: missionToLoad) {
            RoomManager.shared.loadMission(named: missionToLoad)
            let room = multiMission.rooms.first!
            missionTileMap = TileMap(tiles: room.tileMap)
            gameState.setupMultiRoomMission(multiMission)
        } else if let mission = MissionLoader.shared.loadMission(named: missionToLoad) {
            missionTileMap = MissionLoader.shared.buildTileMap(from: mission)
            gameState.setupMission(mission)
        } else if let mission = MissionLoader.shared.loadMission(named: "Mission001") {
            missionTileMap = MissionLoader.shared.buildTileMap(from: mission)
            gameState.setupMission(mission)
        } else {
            missionTileMap = nil
        }

        // Scene size = map pixel dimensions. With .aspectFit, SpriteKit scales to fit the view,
        // centering the map. mapOrigin = (scene.size - mapPixelDims) / 2 is always (.zero)
        // when scene.size == mapPixelDims, keeping all coordinate math simple.
        let mapPixelW  = CGFloat(TileMap.mapWidth - 1) * TileMap.hexColSpacing + TileMap.hexRadius * 2
        let mapHeight: Int
        if let tmap = missionTileMap {
            mapHeight = tmap.mapHeight
        } else {
            mapHeight = 9
        }
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

        // Schedule initial load on the scene. BattleScene.didMove will call loadMap +
        // placeCharacter/placeEnemy once the view is attached and scene.size is final.
        // This is the single source of truth for the first frame — doing placement
        // before presentScene was racey (view nil → fitSceneToView was a no-op →
        // wrong scene.size → wrong mapOrigin → characters off-camera).
        if let multiMission = MissionLoader.shared.loadMultiRoomMission(named: missionToLoad) {
            let room = multiMission.rooms.first!
            scene.scheduleInitialLoad(
                tileMap: TileMap(tiles: room.tileMap),
                roomId: room.id,
                characters: gameState.playerTeam,
                enemies: GameState.shared.enemies
            )
        } else if let mission = MissionLoader.shared.loadMission(named: missionToLoad) {
            let tileMap = MissionLoader.shared.buildTileMap(from: mission)
            scene.scheduleInitialLoad(
                tileMap: tileMap,
                roomId: "room_0",
                characters: gameState.playerTeam,
                enemies: GameState.shared.enemies
            )
        } else if let mission = MissionLoader.shared.loadMission(named: "Mission001") {
            let tileMap = MissionLoader.shared.buildTileMap(from: mission)
            scene.scheduleInitialLoad(
                tileMap: tileMap,
                roomId: "room_0",
                characters: gameState.playerTeam,
                enemies: GameState.shared.enemies
            )
        }

        print("[BattleSceneView] Presenting scene size: \(scene.size), view.bounds: \(skView.bounds.size), playerTeam=\(gameState.playerTeam.count), enemies=\(GameState.shared.enemies.count)")
        skView.presentScene(scene)
        context.coordinator.scene = scene
    }

    func makeCoordinator() -> Coordinator { Coordinator(gameState: gameState) }

    class Coordinator {
        var scene: BattleScene?
        weak var skView: SKView?
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

// MARK: - Debrief View

struct DebriefView: View {
    @ObservedObject var manager: PhaseManager

    private var rewardText: String {
        guard manager.combatWon == true else { return "No payout — mission failed" }
        switch manager.selectedMissionId ?? "" {
        case "Mission001": return "¥15,000 earned"
        case "Mission002": return "¥28,000 earned + AI core (if recovered)"
        case "Mission003": return "¥40,000 earned + mage's grimoire"
        case "Mission004": return "¥50,000 earned + security override codes"
        case "Mission005": return "¥60,000 earned + Mekton prototype (if recovered)"
        default:            return "¥15,000 earned"
        }
    }

    var body: some View {
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

                Text(manager.combatWon == true ? "CONTRACT FULFILLED" : "CONTRACT FAILED")
                    .font(.system(size: 28, weight: .black))
                    .foregroundColor(manager.combatWon == true ? Color(hex: "00FF88") : Color(hex: "FF3333"))
            }
            .frame(height: 80)

            VStack(spacing: 16) {
                Text(rewardText)
                    .foregroundColor(manager.combatWon == true ? Color(hex: "00FF88") : Color(hex: "FF3333"))
                    .font(.headline)

                // Stats display
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
                        Text("\(GameState.shared.enemies.filter { !$0.isAlive }.count)")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color(hex: "0F0F1E"))
                .cornerRadius(8)
            }
            .padding(20)
            .background(Color(hex: "0A0A14"))
            .cornerRadius(12)

            Spacer()

            Button(action: {
                HapticsManager.shared.buttonTap()
                _ = manager.transition(to: .returnToTitle)
            }) {
                Text("RETURN TO TITLE")
                    .font(.headline)
                    .foregroundColor(.black)
                    .frame(width: 220, height: 50)
                    .background(Color(hex: "00FF88"))
                    .cornerRadius(8)
            }
        }
        .padding(24)
    }
}

// MARK: - Phase Manager

/// Renamed to avoid collision with combat runtime GameState class
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
        if case .endCombat(let won) = event { combatWon = won }

        stateHistory.append(nextState)
        currentPhase = nextState
        return true
    }

    var stateStack: [GamePhase] { stateHistory }

    private func computeNext(from state: GamePhase, event: StateTransition) -> GamePhase {
        switch (state, event) {
        case (.title, .startGame):              return .missionSelect
        case (.missionSelect, .selectMission):  return .briefing
        case (.briefing, .beginMission):        return .combat
        case (.combat, .endCombat):             return .debrief
        case (.combat, .returnToTitle):         return .title   // direct bail-out from combat overlay
        case (.debrief, .returnToTitle):        return .title
        case (_, .returnToTitle):               return .title   // safety catch-all
        default:                                 return state
        }
    }
}

// MARK: - Mission Briefing Overlay

struct MissionBriefingOverlay: View {
    let mission: Mission?

    @State private var opacity: Double = 0
    @State private var showContent = false
    @State private var contentOffset: CGFloat = 40

    private var missionTitle: String {
        mission?.title ?? "THE EXTRACTION"
    }

    private var missionDesc: String {
        mission?.description ?? "Infiltrate the corporate facility. Neutralize all hostiles. Extract at the marked point."
    }

    private var enemyCount: Int {
        mission?.enemies.count ?? 4
    }

    private var dangerColor: Color {
        switch mission?.difficulty ?? "MODERATE" {
        case "EXTREME": return Color(hex: "FF3333")
        case "HIGH": return Color(hex: "FF8800")
        default: return Color(hex: "00FF88")
        }
    }

    var body: some View {
        ZStack {
            // Dark backdrop
            Color.black.opacity(opacity)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

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
                        HStack(spacing: 12) {
                            IntelBadge(label: "HOSTILES", value: "\(enemyCount)")
                            IntelBadge(label: "OBJECTIVE", value: "NEUTRALIZE ALL")
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
            withAnimation(.easeOut(duration: 0.5)) { opacity = 0.85 }
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

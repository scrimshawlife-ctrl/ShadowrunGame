import SwiftUI

// MARK: - Theme Colors

struct CombatTheme {
    static let background  = Color(hex: "000000")
    static let panelBG     = Color(hex: "0A0A14")
    static let panelEdge   = Color(hex: "00FF88").opacity(0.4)
    static let accent      = Color(hex: "00FF88")
    static let damage      = Color(hex: "FF6600")
    static let enemyColor  = Color(hex: "FF3333")
    static let secondary   = Color(hex: "444466")
    static let textWhite   = Color.white
    static let textMuted   = Color(hex: "888899")
    static let gold       = Color(hex: "FFD700")
    // New neon colors
    static let neonPink    = Color(hex: "FF0080")
    static let neonBlue    = Color(hex: "00D4FF")
    static let neonPurple  = Color(hex: "8B00FF")
    static let darkPanel   = Color(hex: "06060E")
}

extension Color {
    init(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        h = h.replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        let r = Double((rgb & 0xFF0000)>>16)/255.0
        let g = Double((rgb & 0x00FF00)>>8)/255.0
        let b = Double(rgb & 0x0000FF)/255.0
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - HP Bar

struct HPBar: View {
    let current: Int
    let max: Int

    private var pct: Double {
        guard max > 0 else { return 0 }
        return min(1.0, Swift.max(0, Double(current) / Double(max)))
    }

    private var barColor: Color {
        pct > 0.6 ? CombatTheme.accent
        : pct > 0.3 ? Color.yellow
        : CombatTheme.enemyColor
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(0.6))
                Capsule()
                    .fill(barColor)
                    .frame(width: geo.size.width * pct)
                    .animation(.easeInOut(duration: 0.3), value: pct)
            }
        }
        .frame(height: 8)
    }
}

// MARK: - XP Bar

struct XPBar: View {
    let xp: Int
    let level: Int

    private var pct: Double {
        let threshold = level * 100
        return min(1.0, Swift.max(0, Double(xp) / Double(threshold)))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(0.4))
                Capsule()
                    .fill(CombatTheme.gold)
                    .frame(width: geo.size.width * pct)
                    .animation(.easeInOut(duration: 0.4), value: pct)
            }
        }
        .frame(height: 5)
    }
}

// MARK: - Stun Bar (SR5 stun damage track — yellow/orange)

struct StunBar: View {
    let current: Int
    let max: Int

    private var pct: Double {
        guard max > 0 else { return 0 }
        return min(1.0, Swift.max(0, Double(current) / Double(max)))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(0.6))
                Capsule()
                    .fill(pct > 0.7 ? Color(hex: "FF4400") : Color(hex: "FFAA00"))
                    .frame(width: geo.size.width * pct)
                    .animation(.easeInOut(duration: 0.3), value: pct)
            }
        }
        .frame(height: 5)
    }
}

// MARK: - Mana Bar

struct ManaBar: View {
    let current: Int
    let max: Int

    private var pct: Double {
        guard max > 0 else { return 0 }
        return min(1.0, Swift.max(0, Double(current) / Double(max)))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(0.6))
                Capsule()
                    .fill(Color(hex: "6699FF"))
                    .frame(width: geo.size.width * pct)
                    .animation(.easeInOut(duration: 0.3), value: pct)
            }
        }
        .frame(height: 5)
    }
}

// MARK: - Character Portrait Badge

struct PortraitBadge: View {
    let name: String
    let archetype: CharacterArchetype
    let color: Color
    let isDefending: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(isDefending ? 0.1 : 0.2))
                .frame(width: 28, height: 28)
            Circle()
                .stroke(color.opacity(isDefending ? 0.15 : 1.0), lineWidth: isDefending ? 1.0 : 1.5)
                .frame(width: 28, height: 28)
            VStack(spacing: 0) {
                Text(String(name.prefix(1)))
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .foregroundColor(color)
                if isDefending {
                    Image(systemName: "shield.fill")
                        .font(.system(size: 5))
                        .foregroundColor(Color(hex: "4488FF"))
                        .offset(y: -1)
                }
            }
        }
    }
}

// MARK: - Team Roster Bar

struct TeamRosterBar: View {
    @ObservedObject var gameState: GameState

    private func archetypeColor(_ archetype: CharacterArchetype) -> Color {
        switch archetype {
        case .streetSam: return Color(hex: "FF6633")
        case .mage:    return Color(hex: "6699FF")
        case .decker:  return Color(hex: "00DDFF")
        case .face:    return Color(hex: "FFCC00")
        }
    }

    private func archetypeIcon(_ archetype: CharacterArchetype) -> String {
        switch archetype {
        case .streetSam: return "flame.fill"
        case .mage:    return "sparkles"
        case .decker:  return "cpu"
        case .face:    return "person.fill"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(gameState.playerTeam, id: \.id) { char in
                VStack(spacing: 3) {
                    ZStack {
                        Circle()
                            .fill(archetypeColor(char.archetype).opacity(0.2))
                            .frame(width: 36, height: 36)

                        // Gold border glow if selected
                        if gameState.activeCharacter?.id == char.id {
                            Circle()
                                .stroke(CombatTheme.gold, lineWidth: 2)
                                .frame(width: 36, height: 36)
                                .shadow(color: CombatTheme.gold.opacity(0.6), radius: 4)
                        } else {
                            Circle()
                                .stroke(archetypeColor(char.archetype).opacity(0.7), lineWidth: 1.5)
                                .frame(width: 36, height: 36)
                        }

                        // Character state
                        if char.currentHP <= 0 {
                            VStack(spacing: 0) {
                                Image(systemName: "skull.fill")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(CombatTheme.enemyColor)
                            }
                            .opacity(0.6)
                        } else {
                            VStack(spacing: 0) {
                                Text(String(char.name.prefix(1)).uppercased())
                                    .font(.system(size: 11, weight: .black, design: .rounded))
                                    .foregroundColor(archetypeColor(char.archetype))
                            }
                        }

                        // "Acted" indicator dot — archetype color if can still act, gray if done
                        Circle()
                            .fill(char.hasActedThisRound
                                  ? Color.gray.opacity(0.35)
                                  : archetypeColor(char.archetype).opacity(0.9))
                            .frame(width: 7, height: 7)
                            .overlay(
                                Circle()
                                    .stroke(Color.black.opacity(0.5), lineWidth: 0.5)
                            )
                            .offset(x: 13, y: -13)
                    }

                    // Physical HP bar
                    GeometryReader { geo in
                        let hpPct = Swift.max(0, Double(char.currentHP) / Double(char.maxHP))
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.black.opacity(0.5))
                            Capsule()
                                .fill(hpPct > 0.3 ? Color.green : CombatTheme.enemyColor)
                                .frame(width: geo.size.width * hpPct)
                        }
                    }
                    .frame(height: 3)

                    // Stun track (yellow-orange, SR5 stun damage)
                    GeometryReader { geo in
                        let stunPct = Swift.max(0, Double(char.currentStun) / Double(char.maxStun))
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.black.opacity(0.4))
                            Capsule()
                                .fill(Color(hex: "FFAA00").opacity(0.85))
                                .frame(width: geo.size.width * stunPct)
                        }
                    }
                    .frame(height: 2)

                    // Character name
                    Text(char.name.prefix(4).lowercased())
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundColor(CombatTheme.textMuted)
                }
                .frame(width: 50)
                .contentShape(Rectangle())
                .onTapGesture {
                    HapticsManager.shared.buttonTap()
                    gameState.selectCharacter(id: char.id)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(CombatTheme.darkPanel)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(CombatTheme.panelEdge, lineWidth: 1)
                )
        )
    }
}

// MARK: - Status Display

struct StatusDisplay: View {
    @ObservedObject var gameState: GameState

    private var char: Character? {
        gameState.activeCharacter ?? gameState.currentCharacter
    }

    private func archetypeIcon(_ archetype: CharacterArchetype) -> String {
        switch archetype {
        case .streetSam: return "flame.fill"
        case .mage:    return "sparkles"
        case .decker:  return "cpu"
        case .face:    return "person.fill"
        }
    }

    private func archetypeColor(_ archetype: CharacterArchetype) -> Color {
        switch archetype {
        case .streetSam: return Color(hex: "FF6633")
        case .mage:    return Color(hex: "6699FF")
        case .decker:  return Color(hex: "00DDFF")
        case .face:    return Color(hex: "FFCC00")
        }
    }

    var body: some View {
        if let c = char {
            HStack(spacing: 8) {
                // Compact avatar
                PortraitBadge(
                    name: c.name,
                    archetype: c.archetype,
                    color: CombatTheme.accent,
                    isDefending: gameState.isDefending
                )

                // Name + level inline with archetype icon
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: archetypeIcon(c.archetype))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(archetypeColor(c.archetype))
                        Text(c.name)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(gameState.isDefending ? .gray : .white)
                        Text("LV\(c.level)")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(CombatTheme.gold)
                            .cornerRadius(3)
                    }

                    // Weapon name in small muted text
                    if let weapon = gameState.loot.first(where: { $0.type == .weapon }) {
                        Text(weapon.name)
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundColor(CombatTheme.textMuted)
                    }

                    HPBar(current: c.currentHP, max: c.maxHP)
                        .frame(height: 6)

                    // Stun track (SR5 stun damage — yellow bar)
                    if c.currentStun > 0 || c.maxStun > 0 {
                        HStack(spacing: 3) {
                            Text("S")
                                .font(.system(size: 7, weight: .bold, design: .monospaced))
                                .foregroundColor(Color(hex: "FFAA00"))
                            StunBar(current: c.currentStun, max: c.maxStun)
                            Text("\(c.currentStun)/\(c.maxStun)")
                                .font(.system(size: 7, design: .monospaced))
                                .foregroundColor(Color(hex: "FFAA00").opacity(0.7))
                        }
                        .frame(height: 5)
                    }

                    // Mana bar for mages
                    if c.maxMana > 0 {
                        ManaBar(current: c.currentMana, max: c.maxMana)
                    }
                }

                Spacer()

                // Mana display (mages only) in compact form
                if c.maxMana > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 8))
                            .foregroundColor(Color(hex: "6699FF"))
                        Text("\(c.currentMana)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(Color(hex: "6699FF"))
                    }
                }

                // Turn indicator
                if gameState.isPlayerInputPhase {
                    if gameState.isDefending {
                        Text("DEF")
                            .font(.system(size: 8, weight: .black))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color(hex: "4488FF"))
                            .cornerRadius(3)
                    } else {
                        Text("TURN")
                            .font(.system(size: 8, weight: .black))
                            .foregroundColor(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(CombatTheme.accent)
                            .cornerRadius(3)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                CombatTheme.panelBG,
                                CombatTheme.panelBG.opacity(0.7)
                            ]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(gameState.isDefending ? CombatTheme.secondary.opacity(0.6) : CombatTheme.panelEdge, lineWidth: 1)
                    )
            )
        }
    }
}

// MARK: - Action Buttons

struct ActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let width: CGFloat
    let height: CGFloat
    let action: () -> Void
    var disabled: Bool = false

    @State private var pressed = false

    var body: some View {
        Button(action: {
            guard !disabled else { return }
            HapticsManager.shared.buttonTap()
            action()
        }) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(disabled
                          ? Color.black.opacity(0.3)
                          : color.opacity(pressed ? 0.4 : 0.2))
                RoundedRectangle(cornerRadius: 6)
                    .stroke(disabled
                            ? color.opacity(0.2)
                            : color.opacity(pressed ? 1.0 : 0.7), lineWidth: pressed ? 1.5 : 1)

                // Diagonal stripe pattern overlay when disabled
                if disabled {
                    Canvas { context, size in
                        var path = Path()
                        let spacing: CGFloat = 4
                        for i in stride(from: -size.height, through: size.width, by: spacing) {
                            path.move(to: CGPoint(x: i, y: 0))
                            path.addLine(to: CGPoint(x: i + size.height, y: size.height))
                        }
                        context.stroke(
                            path,
                            with: .color(color.opacity(0.15)),
                            lineWidth: 1
                        )
                    }
                }

                VStack(spacing: 1) {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                    Text(title.uppercased())
                        .font(.system(size: 7, weight: .black))
                        .tracking(0.2)
                }
                .foregroundColor(disabled ? Color.white.opacity(0.3) : (pressed ? .white : Color.white.opacity(0.9)))
            }
            .frame(width: width, height: height)
            .shadow(color: disabled ? .clear : color.opacity(pressed ? 0.4 : 0.15), radius: pressed ? 4 : 2, x: 0, y: 0)
            // Colored bottom border
            .overlay(
                VStack {
                    Spacer()
                    Rectangle()
                        .fill(disabled ? color.opacity(0.3) : color)
                        .frame(height: 2)
                }
            )
        }
        .scaleEffect(pressed && !disabled ? 0.95 : 1.0)
        .animation(.easeInOut(duration: 0.08), value: pressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !disabled { pressed = true } }
                .onEnded { _ in pressed = false }
        )
    }
}

struct ActionBar: View {
    let onAttack: () -> Void
    let onDefend: () -> Void
    let onItems: () -> Void
    let onSpecial: (() -> Void)?
    let specialTitle: String
    let specialIcon: String
    let specialColor: Color
    let onEndTurn: () -> Void
    var disabled: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            ActionButton(title: "ATK", icon: "flame.fill", color: CombatTheme.damage, width: 50, height: 38, action: onAttack, disabled: disabled)
            ActionButton(title: "DEF", icon: "shield.fill", color: CombatTheme.secondary, width: 50, height: 38, action: onDefend, disabled: disabled)
            if let onSpecial {
                ActionButton(title: specialTitle, icon: specialIcon, color: specialColor, width: 50, height: 38, action: onSpecial, disabled: disabled)
            }
            ActionButton(title: "ITM", icon: "cross.case.fill", color: Color(hex: "8866FF"), width: 50, height: 38, action: onItems, disabled: disabled)
            ActionButton(title: "END", icon: "arrow.right.circle.fill", color: CombatTheme.accent, width: 50, height: 38, action: onEndTurn, disabled: disabled)
        }
    }
}

// MARK: - Combat Log

struct CombatLogView: View {
    @ObservedObject var gameState: GameState

    private var recentEntries: [String] {
        Array(gameState.combatLog.suffix(3))
    }

    private func hasMoreEntries() -> Bool {
        gameState.combatLog.count > 3
    }

    private func entryColor(_ text: String) -> Color {
        if text.contains("VICTORY") || text.contains("LEVEL UP") || text.contains("LOOT") { return CombatTheme.gold }
        if text.contains("DOWN") || text.contains("DEFEAT") { return CombatTheme.enemyColor }
        if text.contains("attacks") || gameState.playerTeam.contains(where: { text.contains($0.name) }) { return CombatTheme.neonBlue }
        if gameState.livingEnemies.contains(where: { text.contains($0.name) }) || text.contains("damage") { return CombatTheme.damage }
        return CombatTheme.textMuted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if hasMoreEntries() {
                Text("...")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(CombatTheme.textMuted)
                    .padding(.horizontal, 10)
            }
            ForEach(Array(recentEntries.enumerated()), id: \.offset) { _, entry in
                HStack(spacing: 4) {
                    Text("›")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(CombatTheme.accent)
                    Text(entry)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(entryColor(entry))
                        .lineLimit(1)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(CombatTheme.panelBG)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(CombatTheme.panelEdge, lineWidth: 1)
                )
        )
    }
}

struct CombatLogEntry: View {
    let text: String
    let index: Int
    let total: Int

    private var isRecent: Bool { index >= total - 5 }
    private var isVictory: Bool { text.contains("VICTORY") || text.contains("LEVEL UP") }

    private var textColor: Color {
        if isVictory { return CombatTheme.gold }
        if text.contains("⚠️") { return CombatTheme.damage }
        if text.contains("💀") { return CombatTheme.enemyColor }
        if text.contains("→") || text.contains("attacks") { return CombatTheme.textMuted }
        return index % 2 == 0 ? Color(hex: "555566") : Color(hex: "888899")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            if isRecent {
                Text("›")
                    .foregroundColor(CombatTheme.accent)
                    .font(.system(size: 10, weight: .bold))
            } else {
                Text(" ")
                    .font(.system(size: 10))
            }
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(textColor)
                .lineLimit(2)
        }
    }
}

// MARK: - Loot Badge

struct LootBadge: View {
    let items: [GameState.Item]

    var body: some View {
        if !items.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "gift.fill")
                    .foregroundColor(CombatTheme.gold)
                    .font(.caption)
                Text("\(items.count) loot")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(CombatTheme.gold)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(hex: "1A1A00"))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(CombatTheme.gold.opacity(0.4), lineWidth: 1)
                    )
            )
        }
    }
}

struct IntelMetricBadge: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 7, weight: .black, design: .monospaced))
                .foregroundColor(tint.opacity(0.78))
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.92))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(tint.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(tint.opacity(0.35), lineWidth: 1)
                )
        )
    }
}

struct CombatUtilityButton: View {
    let title: String
    let value: String
    let tint: Color
    let action: () -> Void
    var disabled: Bool = false

    var body: some View {
        Button(action: {
            guard !disabled else { return }
            HapticsManager.shared.buttonTap()
            action()
        }) {
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .foregroundColor(.white.opacity(disabled ? 0.35 : 0.88))
                Text(value)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(disabled ? CombatTheme.textMuted.opacity(0.55) : tint)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(disabled ? Color.black.opacity(0.2) : tint.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(disabled ? tint.opacity(0.18) : tint.opacity(0.38), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1.0)
    }
}

struct MissionIntelCard: View {
    @ObservedObject var gameState: GameState
    let onClose: () -> Void

    private var roomTitle: String {
        RoomManager.shared.currentRoom?.title ?? "Mission Intel"
    }

    private var objectiveSummary: String {
        switch gameState.currentMissionType {
        case .stealth:
            return "Stay low for \(gameState.missionTargetTurns) turns."
        case .assault:
            return "Eliminate the hostile force."
        case .extraction:
            return "Reach extraction at (\(gameState.extractionX),\(gameState.extractionY))."
        }
    }

    private var progressSummary: String? {
        switch gameState.currentMissionType {
        case .stealth:
            return "Progress \(gameState.currentTurnCount)/\(gameState.missionTargetTurns)"
        case .assault:
            return nil
        case .extraction:
            return "Exit tile is marked with a green glow."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(roomTitle.uppercased())
                        .font(.system(size: 14, weight: .black, design: .monospaced))
                        .foregroundColor(.white.opacity(0.96))
                        .lineLimit(1)
                    Text("MISSION INTEL")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .foregroundColor(CombatTheme.accent.opacity(0.82))
                }
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(CombatTheme.textMuted.opacity(0.9))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 6) {
                IntelMetricBadge(label: "ROUND", value: "R\(gameState.roundNumber)", tint: CombatTheme.secondary)
                IntelMetricBadge(label: "ENEMIES", value: "\(gameState.livingEnemies.count)/\(gameState.enemies.count)", tint: CombatTheme.enemyColor)
                IntelMetricBadge(label: "TRACE", value: "\(gameState.traceLevel)/\(gameState.traceThreshold)", tint: gameState.traceTier >= 2 ? CombatTheme.enemyColor : CombatTheme.accent)
            }

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    intelSection("OBJECTIVE", text: objectiveSummary)

                    if let progressSummary {
                        intelSection("PROGRESS", text: progressSummary)
                    }

                    intelSection("MISSION TYPE", text: "\(gameState.missionTypeLabel)\n\(gameState.missionTypeHint)")
                    intelSection("PRESSURE", text: gameState.generateCombinedPressurePreview())
                    intelSection("REACTION", text: "Corp: \(gameState.generateWorldReactionMessage())\nGang: \(gameState.generateGangReactionMessage())")
                    intelSection(
                        "PAYOUT",
                        text: """
                        Base \(gameState.baseMissionPayout)  Risk +\(gameState.riskBonus)
                        Total \(gameState.finalMissionPayout)
                        \(gameState.generateRewardPreview())
                        """
                    )
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(14)
        .frame(maxWidth: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(CombatTheme.panelBG.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(CombatTheme.panelEdge.opacity(0.52), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.28), radius: 16, x: 0, y: 8)
    }

    @ViewBuilder
    private func intelSection(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .foregroundColor(CombatTheme.textWhite.opacity(0.8))
            Text(text)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(CombatTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Corner Bracket Helper

struct CornerBracket: View {
    let size: CGFloat = 12
    let lineWidth: CGFloat = 2
    let color: Color

    var body: some View {
        Canvas { context, size in
            var path = Path()
            let inset: CGFloat = 4

            // Top-left bracket
            path.move(to: CGPoint(x: inset, y: 0))
            path.addLine(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 0, y: inset))

            context.stroke(path, with: .color(color), lineWidth: lineWidth)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Spell Picker Sheet

struct SpellPickerSheet: View {
    @ObservedObject var gameState: GameState
    @Binding var showingPicker: Bool

    private var mage: Character? {
        (gameState.activeCharacter ?? gameState.currentCharacter).flatMap {
            $0.archetype == .mage ? $0 : nil
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            // Header
            ZStack {
                HStack {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            CornerBracket(color: Color(hex: "6699FF"))
                            Spacer()
                        }
                        Spacer()
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 0) {
                        HStack(spacing: 0) {
                            Spacer()
                            CornerBracket(color: Color(hex: "AA44FF"))
                                .scaleEffect(x: -1)
                        }
                        Spacer()
                    }
                }
                .frame(height: 20)

                HStack {
                    Text("SPELLBOOK")
                        .font(.system(size: 14, weight: .black))
                        .foregroundColor(Color(hex: "6699FF"))
                        .tracking(2)
                    Spacer()
                    if let m = mage {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11))
                                .foregroundColor(Color(hex: "6699FF"))
                            Text("\(m.currentMana)/\(m.maxMana)")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(Color(hex: "6699FF"))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(hex: "6699FF").opacity(0.15))
                        .cornerRadius(6)
                    }
                    Button(action: { showingPicker = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(CombatTheme.textMuted)
                            .font(.title2)
                    }
                }
            }

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(SpellType.allCases, id: \.self) { spell in
                        let canCast = (mage?.currentMana ?? 0) >= spell.manaCost
                        Button(action: {
                            guard canCast else { return }
                            HapticsManager.shared.buttonTap()
                            showingPicker = false
                            gameState.performSpell(type: spell)
                        }) {
                            HStack(spacing: 12) {
                                // Spell icon
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(hex: spell.colorHex).opacity(0.18))
                                        .frame(width: 44, height: 44)
                                    Image(systemName: spell.icon)
                                        .font(.system(size: 20))
                                        .foregroundColor(Color(hex: spell.colorHex))
                                }

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(spell.displayName.uppercased())
                                            .font(.system(size: 13, weight: .black))
                                            .foregroundColor(canCast ? .white : CombatTheme.textMuted)
                                            .tracking(1)
                                        if spell.isAreaOfEffect {
                                            Text("AoE")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundColor(Color(hex: "FF4422"))
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(Color(hex: "FF4422").opacity(0.18))
                                                .cornerRadius(3)
                                        }
                                    }
                                    Text(spell.description)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(CombatTheme.textMuted)
                                        .lineLimit(2)
                                }

                                Spacer()

                                // Mana cost badge
                                VStack(spacing: 2) {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 9))
                                        .foregroundColor(canCast ? Color(hex: "6699FF") : CombatTheme.textMuted)
                                    Text("\(spell.manaCost)")
                                        .font(.system(size: 14, weight: .black, design: .monospaced))
                                        .foregroundColor(canCast ? Color(hex: "6699FF") : CombatTheme.textMuted)
                                }
                                .frame(width: 28)
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(canCast ? CombatTheme.panelBG : CombatTheme.panelBG.opacity(0.5))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(
                                                canCast ? Color(hex: spell.colorHex).opacity(0.4) : CombatTheme.panelEdge,
                                                lineWidth: canCast ? 1.5 : 1
                                            )
                                    )
                            )
                            .opacity(canCast ? 1.0 : 0.5)
                        }
                        .disabled(!canCast)
                    }
                }
            }
        }
        .padding(16)
        .background(CombatTheme.panelBG)
        .cornerRadius(16)
        .padding(20)
    }
}

// MARK: - Item Picker Sheet

struct ItemPickerSheet: View {
    @ObservedObject var gameState: GameState
    @Binding var showingPicker: Bool
    let onUseItem: () -> Void

    private var usableItems: [GameState.Item] {
        gameState.loot.filter { $0.type == .consumable }
    }

    var body: some View {
        VStack(spacing: 16) {
            // Header with corner brackets
            ZStack {
                HStack {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            CornerBracket(color: CombatTheme.neonPink)
                            Spacer()
                        }
                        Spacer()
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 0) {
                        HStack(spacing: 0) {
                            Spacer()
                            CornerBracket(color: CombatTheme.neonBlue)
                                .scaleEffect(x: -1)
                        }
                        Spacer()
                    }
                }
                .frame(height: 20)

                HStack {
                    Text("ITEMS")
                        .font(.system(size: 14, weight: .black))
                        .foregroundColor(CombatTheme.accent)
                        .tracking(2)
                    Spacer()
                    Button(action: { showingPicker = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(CombatTheme.textMuted)
                            .font(.title2)
                    }
                }
            }

            if usableItems.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "cross.case")
                        .font(.largeTitle)
                        .foregroundColor(CombatTheme.textMuted)
                    Text("No medkits available")
                        .font(.subheadline)
                        .foregroundColor(CombatTheme.textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(usableItems) { item in
                            Button(action: {
                                HapticsManager.shared.buttonTap()
                                if let idx = gameState.loot.firstIndex(where: { $0.id == item.id }) {
                                    let removed = gameState.loot.remove(at: idx)
                                    if let char = gameState.activeCharacter ?? gameState.currentCharacter {
                                        let healed = min(char.maxHP, char.currentHP + removed.bonus)
                                        let actualHeal = healed - char.currentHP
                                        char.currentHP = healed
                                        gameState.addLog("\(char.name) uses \(removed.name)! +\(actualHeal) HP. (\(char.currentHP)/\(char.maxHP))")
                                        HapticsManager.shared.attackHit()
                                        // Use completeAction to properly end turn and advance to next player
                                        gameState.completeAction(for: char)
                                    }
                                }
                                showingPicker = false
                                onUseItem()
                            }) {
                                HStack {
                                    Image(systemName: itemIcon(for: item))
                                        .foregroundColor(itemColor(for: item))
                                        .font(.system(size: 22))
                                        .frame(width: 40)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.name)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.white)
                                        Text("+\(item.bonus) HP")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(CombatTheme.accent)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundColor(CombatTheme.textMuted)
                                        .font(.caption)
                                }
                                .padding(14)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(CombatTheme.panelBG)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(CombatTheme.panelEdge, lineWidth: 1)
                                        )
                                )
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(CombatTheme.panelBG)
        .cornerRadius(16)
        .padding(20)
    }

    private func itemIcon(for item: GameState.Item) -> String {
        switch item.type {
        case .consumable: return "cross.case.fill"
        case .weapon:    return "flame.fill"
        case .armor:     return "shield.fill"
        }
    }

    private func itemColor(for item: GameState.Item) -> Color {
        switch item.type {
        case .consumable: return CombatTheme.accent
        case .weapon:    return CombatTheme.damage
        case .armor:     return Color(hex: "8866FF")
        }
    }
}

// MARK: - Turn Indicator Banner

struct TurnIndicatorBanner: View {
    let isEnemyTurn: Bool
    let roundNumber: Int
    @ObservedObject var gameState: GameState

    @State private var pulseScale: CGFloat = 1.0

    private var currentCharName: String {
        gameState.activeCharacter?.name ?? gameState.currentCharacter?.name ?? "UNKNOWN"
    }

    var body: some View {
        HStack(spacing: 8) {
            // Turn state pill
            HStack(spacing: 5) {
                if isEnemyTurn {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 9))
                    Text("ENEMY TURN")
                        .font(.system(size: 10, weight: .black))
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                    VStack(spacing: 0) {
                        Text("YOUR TURN")
                            .font(.system(size: 10, weight: .black))
                        Text(currentCharName)
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    }
                }
            }
            .foregroundColor(isEnemyTurn ? Color(hex: "FF3333") : CombatTheme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isEnemyTurn
                          ? Color(hex: "FF3333").opacity(0.15)
                          : CombatTheme.accent.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isEnemyTurn
                                    ? Color(hex: "FF3333").opacity(0.5)
                                    : CombatTheme.accent.opacity(0.4), lineWidth: 1)
                    )
            )
            .scaleEffect(pulseScale)
            .onAppear {
                if !isEnemyTurn {
                    withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                        pulseScale = 1.05
                    }
                }
            }

            // Round indicator
            Text("R\(roundNumber)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(CombatTheme.textMuted)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.black.opacity(0.3))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(CombatTheme.secondary.opacity(0.4), lineWidth: 1)
                        )
                )

            // Enemy count with skull
            HStack(spacing: 3) {
                Text("💀")
                    .font(.system(size: 10))
                Text("x\(gameState.livingEnemies.count)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(CombatTheme.enemyColor)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(CombatTheme.enemyColor.opacity(0.15))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(CombatTheme.enemyColor.opacity(0.4), lineWidth: 1)
                    )
            )

            Spacer()

            // Mini mission objective hint
            if !isEnemyTurn {
                Text("Reach ★ EXIT to extract")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(CombatTheme.accent.opacity(0.7))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(CombatTheme.panelBG.opacity(0.8))
        )
    }
}

// MARK: - Main Combat UI

// MARK: - Hit Preview Card

struct HitPreviewCard: View {
    let preview: CombatMechanics.HitPreview

    private var hitChancePct: Int { Int((preview.estimatedHitChance * 100).rounded()) }

    private var hitColor: Color {
        if preview.blocked               { return CombatTheme.textMuted }
        if preview.estimatedHitChance > 0.60 { return CombatTheme.accent }
        if preview.estimatedHitChance > 0.35 { return Color.yellow }
        return CombatTheme.enemyColor
    }

    var body: some View {
        Group {
            if preview.blocked {
                // LOS blocked state
                HStack(spacing: 6) {
                    Image(systemName: "xmark.shield.fill")
                        .foregroundColor(CombatTheme.enemyColor)
                        .font(.system(size: 11))
                    Text("NO LOS — \(preview.reason ?? "blocked")")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(CombatTheme.enemyColor)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(CombatTheme.panelBG)
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(CombatTheme.enemyColor.opacity(0.4), lineWidth: 1))
                )
            } else {
                // Normal preview state
                HStack(spacing: 10) {
                    // Hit chance %
                    VStack(spacing: 1) {
                        Text("HIT")
                            .font(.system(size: 7, weight: .black, design: .monospaced))
                            .foregroundColor(CombatTheme.textMuted)
                        Text("\(hitChancePct)%")
                            .font(.system(size: 15, weight: .black, design: .monospaced))
                            .foregroundColor(hitColor)
                    }

                    Rectangle()
                        .fill(CombatTheme.secondary.opacity(0.5))
                        .frame(width: 1, height: 28)

                    // Dice pools
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text("ATK")
                                .font(.system(size: 7, weight: .bold, design: .monospaced))
                                .foregroundColor(CombatTheme.textMuted)
                            Text("\(preview.attackPool)d6")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white)
                        }
                        HStack(spacing: 4) {
                            Text("DEF")
                                .font(.system(size: 7, weight: .bold, design: .monospaced))
                                .foregroundColor(CombatTheme.textMuted)
                            Text("\(preview.defensePool)d6")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white)
                            if preview.coverBonus > 0 {
                                Text("+\(preview.coverBonus)cov")
                                    .font(.system(size: 8, weight: .black, design: .monospaced))
                                    .foregroundColor(CombatTheme.gold)
                            }
                        }
                    }

                    Rectangle()
                        .fill(CombatTheme.secondary.opacity(0.5))
                        .frame(width: 1, height: 28)

                    // Estimated damage
                    VStack(spacing: 1) {
                        Text("DMG")
                            .font(.system(size: 7, weight: .black, design: .monospaced))
                            .foregroundColor(CombatTheme.textMuted)
                        Text("~\(Int(preview.estimatedDamage.rounded()))")
                            .font(.system(size: 15, weight: .black, design: .monospaced))
                            .foregroundColor(CombatTheme.damage)
                    }

                    Spacer()

                    // LOS checkmark
                    VStack(spacing: 1) {
                        Text("LOS")
                            .font(.system(size: 7, weight: .black, design: .monospaced))
                            .foregroundColor(CombatTheme.textMuted)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(CombatTheme.accent)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(CombatTheme.panelBG)
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(hitColor.opacity(0.45), lineWidth: 1))
                )
            }
        }
        .animation(.easeInOut(duration: 0.15), value: hitChancePct)
    }
}

// MARK: - CombatUI

struct CombatUI: View {
    @ObservedObject var gameState: GameState
    let diagnosticsVisible: Bool
    let onToggleDiagnostics: () -> Void
    let onAttack: () -> Void
    let onDefend: () -> Void
    let onSpell: () -> Void
    let onBlitz: () -> Void
    let onHack: () -> Void
    let onIntimidate: () -> Void
    let onItems: () -> Void
    let onRecover: () -> Void
    let onEndTurn: () -> Void
    @State private var showingItemPicker = false
    @State private var showingSpellPicker = false
    @State private var isEnemyTurnDisplay: Bool = false
    @State private var showingMissionIntel = false

    private var specialAbilityTitle: String {
        switch (gameState.activeCharacter ?? gameState.currentCharacter)?.archetype {
        case .streetSam: return "BLITZ"
        case .mage:      return "SPELL"
        case .decker:    return "HACK"
        case .face:      return "SCHMZ"
        default:         return "SPL"
        }
    }

    private var specialAbilityIcon: String {
        switch (gameState.activeCharacter ?? gameState.currentCharacter)?.archetype {
        case .streetSam: return "bolt.fill"
        case .mage:      return "sparkles"
        case .decker:    return "cpu.fill"
        case .face:      return "person.wave.2.fill"
        default:         return "sparkles"
        }
    }

    private var specialAbilityColor: Color {
        switch (gameState.activeCharacter ?? gameState.currentCharacter)?.archetype {
        case .streetSam: return Color(hex: "FF6633")
        case .mage:      return Color(hex: "6699FF")
        case .decker:    return Color(hex: "00DDFF")
        case .face:      return Color(hex: "FFCC00")
        default:         return Color(hex: "6699FF")
        }
    }

    private var specialAbilityAction: () -> Void {
        switch (gameState.activeCharacter ?? gameState.currentCharacter)?.archetype {
        case .streetSam: return onBlitz
        case .mage:      return { showingSpellPicker = true }
        case .decker:    return onHack
        case .face:      return onIntimidate
        default:         return onSpell
        }
    }

    private var isEnemyTurn: Bool {
        !gameState.isPlayerInputPhase || gameState.isInputBlockedByPhase
    }

    private var hasActedThisRound: Bool {
        guard let char = gameState.activeCharacter ?? gameState.currentCharacter else { return false }
        return char.hasActedThisRound
    }

    private var hasMultipleRooms: Bool {
        (RoomManager.shared.currentMission?.rooms.count ?? 0) > 1
    }

    private var currentRoomIndex: Int {
        RoomManager.shared.currentRoomIndex
    }

    private func navigateRoomLeft() {
        HapticsManager.shared.buttonTap()
        NotificationCenter.default.post(name: .roomNavigationRequested, object: nil, userInfo: ["direction": "left"])
    }

    private func navigateRoomRight() {
        HapticsManager.shared.buttonTap()
        NotificationCenter.default.post(name: .roomNavigationRequested, object: nil, userInfo: ["direction": "right"])
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 4) {
                // Turn indicator banner
                TurnIndicatorBanner(
                    isEnemyTurn: isEnemyTurn || isEnemyTurnDisplay,
                    roundNumber: gameState.roundNumber,
                    gameState: gameState
                )

                // Team Roster Bar - NEW component
                TeamRosterBar(gameState: gameState)

                // Room navigation arrows
                if hasMultipleRooms {
                    HStack(spacing: 8) {
                        // LEFT arrow
                        Button(action: navigateRoomLeft) {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 11, weight: .black))
                                Text("ROOM")
                                    .font(.system(size: 8, weight: .black))
                            }
                            .foregroundColor(currentRoomIndex > 0 ? CombatTheme.accent : CombatTheme.textMuted)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(currentRoomIndex > 0
                                          ? CombatTheme.accent.opacity(0.12)
                                          : Color.clear)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(currentRoomIndex > 0
                                                    ? CombatTheme.accent.opacity(0.4)
                                                    : CombatTheme.secondary.opacity(0.3), lineWidth: 1)
                                    )
                            )
                        }
                        .disabled(currentRoomIndex <= 0 || isEnemyTurn)
                        .opacity(currentRoomIndex <= 0 ? 0.4 : 1.0)

                        Spacer()

                        // Room indicator
                        Text(RoomManager.shared.currentRoom?.title ?? "")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(CombatTheme.textMuted)
                            .lineLimit(1)

                        Spacer()

                        // RIGHT arrow
                        Button(action: navigateRoomRight) {
                            HStack(spacing: 4) {
                                Text("ROOM")
                                    .font(.system(size: 8, weight: .black))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .black))
                            }
                            .foregroundColor(currentRoomIndex < (RoomManager.shared.currentMission?.rooms.count ?? 1) - 1 ? CombatTheme.accent : CombatTheme.textMuted)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(currentRoomIndex < (RoomManager.shared.currentMission?.rooms.count ?? 1) - 1
                                          ? CombatTheme.accent.opacity(0.12)
                                          : Color.clear)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(currentRoomIndex < (RoomManager.shared.currentMission?.rooms.count ?? 1) - 1
                                                    ? CombatTheme.accent.opacity(0.4)
                                                    : CombatTheme.secondary.opacity(0.3), lineWidth: 1)
                                    )
                            )
                        }
                        .disabled(isEnemyTurn || currentRoomIndex >= (RoomManager.shared.currentMission?.rooms.count ?? 1) - 1)
                        .opacity(currentRoomIndex >= (RoomManager.shared.currentMission?.rooms.count ?? 1) - 1 ? 0.4 : 1.0)
                    }
                    .padding(.horizontal, 6)
                    .animation(.easeInOut(duration: 0.2), value: currentRoomIndex)
                }

                // Compact status bar
                HStack(alignment: .top, spacing: 10) {
                    StatusDisplay(gameState: gameState)
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack(spacing: 6) {
                            IntelMetricBadge(label: "ROUND", value: "R\(gameState.roundNumber)", tint: CombatTheme.secondary)
                            IntelMetricBadge(label: "ENEMY", value: "\(gameState.livingEnemies.count)", tint: CombatTheme.enemyColor)
                            IntelMetricBadge(
                                label: "TRACE",
                                value: "\(gameState.traceLevel)/\(gameState.traceThreshold)",
                                tint: gameState.traceTier >= 2 ? CombatTheme.enemyColor : CombatTheme.accent
                            )
                        }

                        if gameState.currentMissionType == .stealth {
                            Text("PROGRESS \(gameState.currentTurnCount)/\(gameState.missionTargetTurns)")
                                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                .foregroundColor(gameState.isMissionCompleteCompat ? CombatTheme.accent : CombatTheme.textMuted)
                        }

                        if gameState.traceEscalationLevel >= 1 && gameState.playerRole == .street {
                            Text("RESISTING ESCALATION")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundColor(CombatTheme.accent.opacity(0.9))
                        }

                        if gameState.isCombatResolvedOrBeyond {
                            Text(gameState.isCombatVictoryLike ? "MISSION COMPLETE" : "MISSION FAILED")
                                .font(.system(size: 9, weight: .black, design: .monospaced))
                                .foregroundColor(gameState.isCombatVictoryLike ? CombatTheme.accent : CombatTheme.enemyColor)
                        }

                        LootBadge(items: gameState.loot)
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        CombatUtilityButton(
                            title: "ROLE",
                            value: gameState.playerRoleLabel,
                            tint: Color(hex: "8C7BFF"),
                            action: { gameState.cyclePlayerRole() }
                        )
                        .accessibilityIdentifier("cycle_role_button")

                        CombatUtilityButton(
                            title: "PRESET",
                            value: gameState.missionPresetLabel,
                            tint: Color(hex: "00D4FF"),
                            action: { gameState.cycleMissionPreset() }
                        )
                        .accessibilityIdentifier("cycle_preset_button")

                        CombatUtilityButton(
                            title: "TYPE",
                            value: gameState.missionTypeLabel,
                            tint: Color(hex: "FFC857"),
                            action: { gameState.cycleMissionType() }
                        )
                        .accessibilityIdentifier("cycle_type_button")

                        CombatUtilityButton(
                            title: "MODE",
                            value: gameState.actionMode == .street ? "STREET" : "SIGNAL",
                            tint: gameState.actionMode == .street ? CombatTheme.accent : Color(hex: "FF8800"),
                            action: { gameState.actionMode = (gameState.actionMode == .street) ? .signal : .street }
                        )
                        .accessibilityIdentifier("action_mode_toggle_button")

                        CombatUtilityButton(
                            title: "LAY LOW",
                            value: hasActedThisRound ? "USED" : "READY",
                            tint: Color(hex: "B8BCC8"),
                            action: onRecover,
                            disabled: gameState.isCombatResolvedOrBeyond || isEnemyTurn || isEnemyTurnDisplay || hasActedThisRound
                        )
                        .accessibilityIdentifier("trace_recover_button")

                        CombatUtilityButton(
                            title: "INTEL",
                            value: showingMissionIntel ? "HIDE" : "SHOW",
                            tint: CombatTheme.accent,
                            action: { showingMissionIntel.toggle() }
                        )
                        .accessibilityIdentifier("toggle_intel_button")

                        CombatUtilityButton(
                            title: "DIAG",
                            value: diagnosticsVisible ? "ON" : "OFF",
                            tint: diagnosticsVisible ? CombatTheme.accent : CombatTheme.textMuted,
                            action: onToggleDiagnostics
                        )
                        .accessibilityIdentifier("toggle_diagnostics_button")
                    }
                    .padding(.horizontal, 2)
                }

                // Action buttons
                ActionBar(
                    onAttack: onAttack,
                    onDefend: onDefend,
                    onItems: { showingItemPicker = true },
                    onSpecial: specialAbilityAction,
                    specialTitle: specialAbilityTitle,
                    specialIcon: specialAbilityIcon,
                    specialColor: specialAbilityColor,
                    onEndTurn: onEndTurn,
                    disabled: gameState.isCombatResolvedOrBeyond || isEnemyTurn || isEnemyTurnDisplay || hasActedThisRound
                )

                // Hit preview — shown when a target is selected
                if let preview = gameState.hitPreview {
                    HitPreviewCard(preview: preview)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Combat log
                CombatLogView(gameState: gameState)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                Rectangle()
                    .fill(CombatTheme.background.opacity(0.90))
            )

            if showingMissionIntel {
                MissionIntelCard(
                    gameState: gameState,
                    onClose: {
                        HapticsManager.shared.buttonTap()
                        showingMissionIntel = false
                    }
                )
                .padding(.trailing, 10)
                .padding(.bottom, 288)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            // Item picker sheet overlay
            if showingItemPicker {
                Color.black.opacity(0.6)
                    .ignoresSafeArea()
                    .onTapGesture { showingItemPicker = false }
                ItemPickerSheet(
                    gameState: gameState,
                    showingPicker: $showingItemPicker,
                    onUseItem: onEndTurn
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Spell picker sheet overlay (mage only)
            if showingSpellPicker {
                Color.black.opacity(0.6)
                    .ignoresSafeArea()
                    .onTapGesture { showingSpellPicker = false }
                SpellPickerSheet(
                    gameState: gameState,
                    showingPicker: $showingSpellPicker
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showingItemPicker)
        .animation(.easeInOut(duration: 0.2), value: showingSpellPicker)
        .animation(.easeInOut(duration: 0.22), value: showingMissionIntel)
        .animation(.easeInOut(duration: 0.25), value: isEnemyTurnDisplay)
        .onReceive(NotificationCenter.default.publisher(for: .enemyPhaseBegan)) { _ in
            withAnimation { isEnemyTurnDisplay = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .playerTurnResumed)) { _ in
            withAnimation { isEnemyTurnDisplay = false }
        }
    }
}

#if DEBUG
struct CombatUI_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CombatUI(
                gameState: GameState.shared,
                diagnosticsVisible: false,
                onToggleDiagnostics: {},
                onAttack: {},
                onDefend: {},
                onSpell: {},
                onBlitz: {},
                onHack: {},
                onIntimidate: {},
                onItems: {},
                onRecover: {},
                onEndTurn: {}
            )
        }
    }
}
#endif

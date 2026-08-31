import Foundation

// MARK: - Endless Gauntlet
//
// Floor-based endless replay mode that recombines EXISTING content — no new
// maps or art. Each FLOOR is one full randomly-chosen story mission (pool
// below), with enemies scaled up per floor. Clear the mission → the floor
// counter increments and the player dives again from mission select. Party
// wipe → the run ends, the floor resets to 1, best depth is persisted.
//
// How the pieces connect:
// • MissionLoader resolves the synthetic mission id "Gauntlet" to the
//   current floor's underlying mission JSON, overriding the returned
//   MultiRoomMission's id/title (see loadGauntletFloorMission there). That
//   means MissionSetupService sets currentMissionDisplayId = "Gauntlet", so
//   victories record under the "Gauntlet" stats record — campaign
//   completion and paidThisRun stay clean.
// • GauntletStore (below) persists floor progress, owns the per-floor
//   mission pick, and applies the per-enemy floor scaling (stacked on top
//   of NG+ scaling, mirroring NGPlusStore.scaleForTier's shape).
// • GauntletService (bottom of file) observes the `.combatAction`
//   mission-end notification posted by OutcomePipeline and advances /
//   resets the run — no edits to OutcomePipeline or GameState needed.

// MARK: - Gauntlet Store

/// Persistent state of the Endless Gauntlet. Backed by UserDefaults so floor
/// progress and best depth survive app relaunches. Singleton — mirrors the
/// MissionStatsStore / NGPlusStore storage patterns (versioned "HexWire.*"
/// keys, load in init). ObservableObject with @Published members so the
/// mission-select card can observe floor / best-depth changes live.
final class GauntletStore: ObservableObject {
    static let shared = GauntletStore()

    /// The synthetic mission id the mission-select card launches. Never
    /// matches a JSON on disk — MissionLoader intercepts it and loads the
    /// current floor's underlying mission instead.
    static let gauntletMissionId = "Gauntlet"

    /// Missions eligible to be a gauntlet floor. Deliberately EXCLUDES:
    /// • Mission003 — the scripted Sato phase-2 boss code keys off
    ///   currentMissionDisplayId == "Mission003", which is never set in a
    ///   gauntlet run (the display id is "Gauntlet"), so its boss would
    ///   soft-break mid-fight.
    /// • Mission006 — the finale's completion triggers the NG+ advance +
    ///   paidThisRun reset in OutcomePipeline; an endless mode must never
    ///   fire campaign-terminal side effects.
    static let missionPool = ["Mission001", "Mission002", "Mission004", "Mission005"]

    /// Nuyen bonus credited per COMPLETED floor (× the floor number), on top
    /// of the standard recordVictory contract payout for the "Gauntlet"
    /// stats record. Deeper floors pay more — that's the carrot.
    static let floorBonusPerFloor = 1_500

    /// Scaling stops growing past this floor. The party's stats cap out
    /// (level/gear ceilings), so past floor 10 the +15%/floor HP curve would
    /// outrun anything the runners can field — floors 11+ stay at floor-10
    /// numbers and the challenge becomes attrition, not arithmetic.
    static let scalingFloorCap = 10

    // ── Run state ──

    /// The floor the player is currently on (≥ 1). Advances on a gauntlet
    /// victory, resets to 1 on a gauntlet defeat. Persisted.
    @Published private(set) var currentFloor: Int

    /// Deepest floor ever CLEARED (0 = never cleared a floor). Survives
    /// party wipes and app relaunches. Persisted.
    @Published private(set) var bestFloor: Int

    /// True while an in-flight gauntlet mission is loaded — armed by the
    /// MissionLoader "Gauntlet" resolution path, disarmed when any REAL
    /// mission loads (player backed out of the briefing and picked a story
    /// mission) or when the gauntlet mission ends. Deliberately NOT
    /// persisted: a force-quit mid-mission simply drops the attempt without
    /// penalty (session-only, matching the spec).
    @Published private(set) var isActive: Bool = false

    /// The arena rooms chosen for the CURRENT floor (ArenaPool ids).
    /// Persisted alongside the floor so the pick is stable within a floor
    /// attempt — re-entering the briefing (or relaunching the app) doesn't
    /// reroll the maps. Cleared (→ reroll) whenever the floor changes.
    private var floorArenaIds: [String]?

    /// Enemies already scaled for this attempt, by UUID. scaleForFloor is
    /// called from several sweep points that can see the same enemy more
    /// than once (makeEnemy, room-transition sweep, per-enemy-phase sweep) —
    /// this set makes the scaling idempotent so nothing compounds. Session-
    /// only; cleared whenever the run disarms or the floor changes.
    private var scaledEnemyIds: Set<UUID> = []

    // ── Storage keys (versioned, "HexWire.Gauntlet.*" namespace) ──
    private let currentFloorKey = "HexWire.Gauntlet.CurrentFloor.v1"
    private let bestFloorKey    = "HexWire.Gauntlet.BestFloor.v1"
    private let floorMissionKey = "HexWire.Gauntlet.FloorMission.v1"   // legacy story pick (unused)
    private let floorArenasKey  = "HexWire.Gauntlet.FloorArenas.v1"

    private init() {
        let d = UserDefaults.standard
        // integer(forKey:) returns 0 when unset — floor is 1-based.
        currentFloor = max(1, d.integer(forKey: currentFloorKey))
        bestFloor = max(0, d.integer(forKey: bestFloorKey))
        // Only honor persisted arena picks that still exist in the pool —
        // a stale pick silently rerolls instead of loading a room the pool
        // no longer ships.
        if let saved = d.stringArray(forKey: floorArenasKey), !saved.isEmpty {
            floorArenaIds = saved
        }
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(currentFloor, forKey: currentFloorKey)
        d.set(bestFloor, forKey: bestFloorKey)
        if let floorArenaIds {
            d.set(floorArenaIds, forKey: floorArenasKey)
        } else {
            d.removeObject(forKey: floorArenasKey)
        }
        d.removeObject(forKey: floorMissionKey)   // retire the legacy story pick
    }

    // MARK: - Floor arena picks

    /// The arena rooms for the current floor: 2 rooms on floors 1–3, 3 from
    /// floor 4 on. Reuses the persisted picks if they exist (stable within a
    /// floor attempt); otherwise rolls fresh distinct arenas and persists.
    func arenaIdsForCurrentFloor() -> [String] {
        #if DEBUG
        // Art/QA pass: force an exact arena line-up, e.g.
        // SIMCTL_CHILD_SR_FORCE_ARENA_IDS=arena_08,arena_09
        // Wins over the persisted picks so each launch is reproducible.
        if let forced = ProcessInfo.processInfo.environment["SR_FORCE_ARENA_IDS"] {
            let ids = forced.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { ArenaPool.entry(id: $0) != nil }
            if !ids.isEmpty {
                dlog("[Gauntlet] SR_FORCE_ARENA_IDS → \(ids)")
                return ids
            }
        }
        #endif
        if let picked = floorArenaIds, !picked.isEmpty { return picked }
        let count = currentFloor >= 4 ? 3 : 2
        let picked = ArenaPool.randomArenaIds(count: count)
        floorArenaIds = picked
        persist()
        return picked
    }

    // MARK: - Arming / disarming

    /// Called by MissionLoader every time the "Gauntlet" id resolves to a
    /// floor mission load. Arming is idempotent — the load path runs several
    /// times per attempt (briefing preview, ACCEPT CONTRACT, scene
    /// presentation) and re-arming must not disturb an attempt in progress
    /// (notably: it must NOT clear scaledEnemyIds, or a late re-load after
    /// setup would let the per-enemy-phase sweep double-scale the room).
    /// Also wakes GauntletService so the mission-end observer is registered
    /// before any gauntlet mission can possibly finish.
    func armForGauntletLoad() {
        _ = GauntletService.shared   // ensure the .combatAction observer exists
        guard !isActive else { return }
        isActive = true
    }

    /// Called by MissionLoader whenever a REAL (non-gauntlet) multi-room
    /// mission loads. If a gauntlet attempt was armed but the player backed
    /// out of the briefing and picked a story mission instead, this cleanly
    /// stands the gauntlet down: no scaling leaks onto the story mission and
    /// the story victory won't advance the floor. Floor progress + pick are
    /// untouched — the player can come back and dive the same floor.
    func disarmForNonGauntletLoad() {
        guard isActive else { return }
        isActive = false
        scaledEnemyIds.removeAll()
    }

    // MARK: - Run lifecycle (driven by GauntletService)

    /// A gauntlet floor was cleared. Advances the floor (rerolling the next
    /// floor's mission), records best depth, persists, and returns the
    /// COMPLETED floor number so the caller can credit the floor bonus.
    func recordFloorVictory() -> Int {
        let completed = currentFloor
        currentFloor += 1
        bestFloor = max(bestFloor, completed)
        floorArenaIds = nil           // next floor rerolls its arenas
        isActive = false
        scaledEnemyIds.removeAll()
        persist()
        return completed
    }

    /// Party wipe on a gauntlet floor — the run ends. Floor resets to 1 and
    /// the next run rerolls floor 1's mission. bestFloor survives (that's
    /// the whole point of the leaderboard stat).
    func recordFloorDefeat() {
        currentFloor = 1
        floorArenaIds = nil
        isActive = false
        scaledEnemyIds.removeAll()
        persist()
    }

    // MARK: - Floor scaling

    /// Enemy max-HP multiplier for a given (capped) floor: +15% per floor
    /// above 1. Floor 1 is baseline (×1.0) — the ramp starts on floor 2.
    private func hpMultiplier(forFloor floor: Int) -> Double {
        1.0 + 0.15 * Double(floor - 1)
    }

    /// Flat weapon-damage bonus for a given (capped) floor: +1 per 2 floors
    /// above 1 (floor 3 → +1, floor 5 → +2, … floor 10 → +4). Applied to the
    /// enemy's equipped weapon (the same lever the Enforcer archetype and
    /// NG+ use) rather than a global damage hook, so it needs no GameState
    /// edits and stacks naturally with NG+'s central damage bonus.
    private func damageBonus(forFloor floor: Int) -> Int {
        (floor - 1) / 2
    }

    /// Scale one enemy for the current gauntlet floor (mutates in place).
    /// Mirrors NGPlusStore.scaleForTier's shape and stacks ON TOP of it —
    /// callers apply NG+ first, then this. Idempotent per enemy (see
    /// scaledEnemyIds), so it's safe to call from every spawn sweep. No-op
    /// when the gauntlet isn't active or on floor 1 (baseline).
    func scaleForFloor(_ enemy: Enemy) {
        guard isActive else { return }
        // Cap the curve at floor-10 values — past that the capped-stat party
        // can't keep up with the multiplier, so deeper floors hold steady.
        let floor = min(currentFloor, GauntletStore.scalingFloorCap)
        guard floor >= 2 else { return }
        guard scaledEnemyIds.insert(enemy.id).inserted else { return }

        // HP: multiply maxHP, and add the DELTA to currentHP (rather than
        // snapping to full) so a boss that gets swept one enemy phase after
        // deploying keeps any damage it has already taken.
        let scaledMax = Int((Double(enemy.maxHP) * hpMultiplier(forFloor: floor)).rounded())
        enemy.currentHP += scaledMax - enemy.maxHP
        enemy.maxHP = scaledMax

        // Damage: sharpen the equipped weapon (unarmed archetypes — none
        // currently — would simply skip).
        let bonus = damageBonus(forFloor: floor)
        if bonus > 0, var weapon = enemy.equippedWeapon {
            weapon.damage += bonus
            enemy.equippedWeapon = weapon
        }
    }
}

// MARK: - Gauntlet Service

/// Run-lifecycle observer. Listens for OutcomePipeline's mission-end
/// `.combatAction` notification (userInfo["result"] == "victory"/"defeat")
/// and advances / resets the gauntlet run — deliberately notification-driven
/// so OutcomePipeline and GameState need no edits. Instantiated lazily from
/// GauntletStore.armForGauntletLoad(), which every gauntlet mission load
/// passes through, so the observer is guaranteed live before any gauntlet
/// mission can end.
final class GauntletService {
    static let shared = GauntletService()

    private var observer: NSObjectProtocol?

    private init() {
        // OutcomePipeline posts from the main actor; queue .main keeps the
        // handler on the main thread so the store's @Published mutations are
        // UI-safe.
        observer = NotificationCenter.default.addObserver(
            forName: .combatAction, object: nil, queue: .main
        ) { note in
            GauntletService.handleCombatOutcome(note)
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Mission ended. Only reacts while a gauntlet attempt is armed —
    /// isActive is disarmed by any non-gauntlet mission load (see
    /// GauntletStore.disarmForNonGauntletLoad), so a story-mission victory
    /// after backing out of a gauntlet briefing can never advance the floor.
    private static func handleCombatOutcome(_ note: Notification) {
        let store = GauntletStore.shared
        guard store.isActive,
              let result = note.userInfo?["result"] as? String else { return }

        switch result {
        case "victory":
            let completedFloor = store.recordFloorVictory()
            // Floor-completion bonus: ¥1,500 × the floor just cleared,
            // credited straight to the persistent wallet. This stacks ON TOP
            // of the standard recordVictory contract payout for the
            // "Gauntlet" stats record (full base on the run's first clear,
            // 25% residual on repeats) — the bonus is what makes depth pay.
            MissionStatsStore.shared.credit(GauntletStore.floorBonusPerFloor * completedFloor)
        case "defeat":
            store.recordFloorDefeat()
        default:
            break
        }
    }
}

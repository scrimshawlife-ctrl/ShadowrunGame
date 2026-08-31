import Foundation
import Combine

/// One-time migration of persisted save data from the legacy "ShadowrunGame.*"
/// UserDefaults keys to the "HexWire.*" keys used after the 2026 rebrand.
/// Copies each old value to its new key (only if the new key is empty), so a
/// player's roster / nuyen / ranks / NG+ carry across the rename instead of
/// resetting. Flag-guarded — runs at most once, then no-ops forever.
enum StorageMigration {
    private static let flagKey = "HexWire.Migration.KeyRename.v1"
    // (old legacy key, new key). The old column MUST stay "ShadowrunGame.*"
    // literals — that's what existing installs actually wrote to disk.
    private static let keyPairs: [(old: String, new: String)] = [
        ("ShadowrunGame.MissionStats.v1",           "HexWire.MissionStats.v1"),
        ("ShadowrunGame.PlayerNuyen.v1",            "HexWire.PlayerNuyen.v1"),
        ("ShadowrunGame.PaidThisRun.v1",            "HexWire.PaidThisRun.v1"),
        ("ShadowrunGame.Migration.ChaseBackfill.v1","HexWire.Migration.ChaseBackfill.v1"),
        ("ShadowrunGame.FactionAttention.v1",       "HexWire.FactionAttention.v1"),
        ("ShadowrunGame.Roster.v1",                 "HexWire.Roster.v1"),
        ("ShadowrunGame.Roster.v1.lastGood",        "HexWire.Roster.v1.lastGood"),
        ("ShadowrunGame.NGPlusTier.v1",             "HexWire.NGPlusTier.v1"),
    ]

    /// Idempotent — safe to call from every store's init; the first caller
    /// migrates, the rest see the flag and return immediately.
    static func migrateLegacyKeysIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: flagKey) else { return }
        for pair in keyPairs {
            if d.object(forKey: pair.new) == nil, let value = d.object(forKey: pair.old) {
                d.set(value, forKey: pair.new)
            }
        }
        d.set(true, forKey: flagKey)
    }
}

/// Per-mission completion + best-score record for display on the mission menu.
struct MissionRecord: Codable, Equatable {
    var bestScore: Int
    var attempts: Int
    var lastCompletedAt: Date?
    /// Best score achieved on the mission's data-terminal mini-game (lane
    /// runner / cypher crack / packet route / glyph ward / agi face-off).
    /// 0 if the player has never won the mini-game on this mission.
    var bestMiniGameScore: Int = 0

    static let empty = MissionRecord(bestScore: 0, attempts: 0, lastCompletedAt: nil, bestMiniGameScore: 0)
    var completed: Bool { lastCompletedAt != nil }

    init(bestScore: Int, attempts: Int, lastCompletedAt: Date?, bestMiniGameScore: Int = 0) {
        self.bestScore = bestScore
        self.attempts = attempts
        self.lastCompletedAt = lastCompletedAt
        self.bestMiniGameScore = bestMiniGameScore
    }

    /// Tolerant decoder: every field falls back to its default when absent,
    /// so blobs written BEFORE a field existed (e.g. pre-bestMiniGameScore
    /// saves) keep decoding instead of wiping the player's records on
    /// upgrade. Synthesized decoding treats a missing key as a hard failure,
    /// which the WP7 certification proved loses veteran progress.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bestScore = try c.decodeIfPresent(Int.self, forKey: .bestScore) ?? 0
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        lastCompletedAt = try c.decodeIfPresent(Date.self, forKey: .lastCompletedAt)
        bestMiniGameScore = try c.decodeIfPresent(Int.self, forKey: .bestMiniGameScore) ?? 0
    }
}

/// Persistent store of per-mission stats. Backed by UserDefaults so completion
/// + best scores survive app relaunches. Singleton — read by MissionCard for
/// the badge, written by OutcomePipeline / finalizeCombat on a successful run.
final class MissionStatsStore: ObservableObject {
    static let shared = MissionStatsStore()

    @Published private(set) var records: [String: MissionRecord] = [:]

    /// Persistent runner-nuyen balance. Accumulates across mission victories,
    /// survives app relaunches. Reflects the same payout figures shown on the
    /// debrief screen so the wallet matches what the runner believes they've
    /// banked. v0.1: spend-side is purely cosmetic (no shop) — it's an
    /// achievement-tracking total. Spent in future updates.
    @Published private(set) var playerNuyen: Int = 0

    /// Missions whose payout has already been collected THIS campaign run-
    /// through. A mission pays its reward only on first clear of the current
    /// run; replaying it pays nothing. Cleared when the finale (M6) is beaten,
    /// so the next run-through can earn the full economy again.
    @Published private(set) var paidThisRun: Set<String> = []

    private let storageKey = "HexWire.MissionStats.v1"
    private let nuyenStorageKey = "HexWire.PlayerNuyen.v1"
    private let paidThisRunKey = "HexWire.PaidThisRun.v1"

    /// Per-mission base payout (matches the debrief screens). Bonus amounts
    /// (data / grimoire) live in `bonusFor(...)` below. Kept here as the
    /// single source of truth so the debrief text, wallet credit, and the
    /// mission select reward preview all read the same numbers.
    // 2026-06 economy rebalance: old payouts let you buy the ENTIRE shop +
    // best cyberware on all four runners before M6 (which alone paid 500k).
    // Cut ~45% across the board and crushed the M6 placeholder so gear is a
    // real choice — you can kit out a couple of runners per run, not everyone.
    static func basePayout(missionId: String) -> Int {
        // Procedural side contracts price by the tier encoded in the id
        // ("Contract_t<tier>_<seed>") — see ContractStore.
        if missionId.hasPrefix("Contract_t3") { return ContractStore.basePay(tier: 3) }
        if missionId.hasPrefix("Contract_t2") { return ContractStore.basePay(tier: 2) }
        if missionId.hasPrefix(ContractStore.contractIdPrefix) { return ContractStore.basePay(tier: 1) }
        // 2026-07 pass: trimmed ~25% on top of the 2026-06 cut. Measured against
        // the catalogue — one of every item is ¥111,000, and kitting all four
        // runners is ~¥444,000. The old table totalled ¥228,000 base, which with
        // the (then multiplicative) bonus stack and kill bounties banked ~¥570k
        // across a campaign: enough to buy everything for everyone. These
        // numbers plus the additive stack land a strong run near ~¥245,000 —
        // about half the full-kit cost, so gear stays a real choice and you
        // outfit a couple of runners properly rather than the whole team.
        switch missionId {
        case "Mission001":   return 7_000
        case "Mission002":   return 12_000
        case "Mission002_5": return 6_000    // mirrorline = solo astral bonus
        case "Mission003":   return 16_000
        case "Mission003_5": return 4_500    // chase = clean exfil bonus
        case "Mission004":   return 21_000
        case "Mission004_5": return 5_500    // basement brawl = solo melee bonus
        case "Mission005":   return 25_000
        case "Mission005_5": return 13_000   // cold trace = solo decker run + Neural Imprint
        case "Mission006":   return 55_000   // finale payout (was a 500k placeholder)
        default:             return 7_000
        }
    }

    /// Data-acquisition bonus (terminal hack) per mission.
    static func dataBonus(missionId: String) -> Int {
        switch missionId {
        case "Mission002":   return 4_000
        case "Mission002_5": return 3_000   // Akashic Fragment recovered
        case "Mission003":   return 4_000
        case "Mission004":   return 5_500
        case "Mission005":   return 5_500
        case "Mission005_5": return 4_000   // Neural Imprint extracted
        case "Mission006":   return 12_000
        default:             return 0
        }
    }

    /// Grimoire bonus (M3 only).
    static func grimoireBonus(missionId: String) -> Int {
        missionId == "Mission003" ? 6_000 : 0
    }

    /// Displayed "level" for an enemy. Enemies have no XP, so their level is a
    /// readout of how dangerous they are: a gentle base ramp across the
    /// campaign (M1/M2 grunts L1 → M3/M4 L2 → M5/M6 L3), +1 if they're a boss,
    /// plus the current NG+ tier. Single source of truth so the in-combat
    /// HP-bar badge and the profile card always agree.
    static func enemyDisplayLevel(missionId: String?, archetype: String) -> Int {
        let base: Int
        if let id = missionId, id.hasPrefix("Contract_t"),
           let tier = Int(String(id.dropFirst("Contract_t".count).prefix(1))) {
            let bossBump = archetype.lowercased().hasPrefix("boss") ? 1 : 0
            return max(1, tier) + bossBump + NGPlusStore.shared.tier
        }
        switch missionId ?? "" {
        case "Mission003", "Mission004":           base = 2
        case "Mission005", "Mission006":           base = 3
        default:                                    base = 1   // M1/M2 + mini-games/fallback
        }
        let bossBump = archetype.lowercased().hasPrefix("boss") ? 1 : 0
        return base + bossBump + NGPlusStore.shared.tier
    }

    private init() {
        StorageMigration.migrateLegacyKeysIfNeeded()   // before load() reads the new keys
        load()
        runMigrations()
    }

    // MARK: - Migrations

    /// Idempotent one-shot migrations run once per app install on the first
    /// access of the shared store. Each migration is gated by its own
    /// UserDefaults flag so it never replays after running successfully.
    private func runMigrations() {
        migrateBackfillChaseCompletion()
    }

    /// Players who beat M3.5 "The Drop" BEFORE the chase's victory-record
    /// wiring shipped (2026-05-18) have no Mission003_5 entry in their stats,
    /// so the mission card still shows as not-completed even though they
    /// played + won it. Detect that footprint — M1/M2/M3 done, M3.5 missing —
    /// and backfill a completion entry once. Flag persists, never replays.
    /// Internal (not private) so the persistence certification suite can
    /// exercise the footprint/flag logic directly — init-time migrations
    /// only run once per process, which tests can't observe.
    func migrateBackfillChaseCompletion() {
        let flagKey = "HexWire.Migration.ChaseBackfill.v1"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }

        let m1Done = (records["Mission001"]?.completed ?? false)
        let m2Done = (records["Mission002"]?.completed ?? false)
        let m3Done = (records["Mission003"]?.completed ?? false)
        let chaseDone = (records["Mission003_5"]?.completed ?? false)

        // Eligible: progressed past M3 (proves they unlocked + would have
        // played the chase to reach M4) but no chase record exists.
        if m1Done && m2Done && m3Done && !chaseDone {
            var rec = records["Mission003_5"] ?? .empty
            rec.attempts = max(1, rec.attempts)
            rec.bestScore = max(rec.bestScore, 800)   // neutral mid-tier score
            rec.lastCompletedAt = Date()
            records["Mission003_5"] = rec
            // INTENTIONAL: we backfill the completion record but do NOT add it
            // to paidThisRun. Pre-wiring builds never paid the chase, so an
            // eligible veteran gets a one-time make-good payout the first time
            // they actually run it — fair, and bounded to a single optional
            // mission per campaign.
            save()
        }
        UserDefaults.standard.set(true, forKey: flagKey)
    }

    func record(for missionId: String) -> MissionRecord {
        records[missionId] ?? .empty
    }

    /// Total best score across every mission completed at least once.
    var totalScore: Int {
        records.values.reduce(0) { $0 + $1.bestScore }
    }

    /// Number of distinct missions completed at least once.
    var missionsCompleted: Int {
        records.values.filter { $0.completed }.count
    }

    /// Register a victory. Pass the score you computed at finalize time and the
    /// mission id (e.g. "Mission001"). Updates best score (max), increments
    /// attempts, stamps lastCompletedAt, and persists.
    ///
    /// Optionally credit nuyen to the persistent wallet based on what the
    /// runner actually recovered this run (`dataAcquired` / `grimoireAcquired`).
    ///
    /// `rewardMultiplier` is the faction-heat risk multiplier from
    /// `ConsequenceEngine.rewardMultiplier` (+ any mission-type bonus) computed
    /// by `OutcomePipeline.finalizeRewardLayer` — high corp/gang attention
    /// means harder spawns, so the contract pays more. Callers without a
    /// consequence layer (interstitial scenes) omit it and pay flat rate.
    func recordVictory(missionId: String, score: Int,
                       dataAcquired: Bool = false,
                       grimoireAcquired: Bool = false,
                       rewardMultiplier: Double = 1.0) {
        var rec = records[missionId] ?? .empty
        rec.attempts += 1
        rec.bestScore = max(rec.bestScore, score)
        rec.lastCompletedAt = Date()
        records[missionId] = rec
        // THIS run's score — the end-of-run RANK reads it so a C-grade replay
        // shows C, not the historical bestScore merged via max() above.
        lastRunScore = score
        // Credit the wallet — the contract value scales with performance:
        //   (base + earned bonuses) × rank × risk (faction heat) × run factor.
        // Rank makes the letter grade PAY (an S-rank clear banks 60% more than
        // a C), so replaying for a better rank is a real economic decision,
        // not a cosmetic one. First clear this campaign run-through pays full
        // rate; replays pay a 25% "residual contract" — enough to make a
        // replay worthwhile without letting an early mission be farmed to buy
        // out the shop. `paidThisRun` clears on finale completion (new run).
        var contract = MissionStatsStore.basePayout(missionId: missionId)
        if dataAcquired     { contract += MissionStatsStore.dataBonus(missionId: missionId) }
        if grimoireAcquired { contract += MissionStatsStore.grimoireBonus(missionId: missionId) }
        let rankMult   = MissionStatsStore.rankPayoutMultiplier(forScore: score)
        let firstClear = !paidThisRun.contains(missionId)
        let runFactor  = firstClear ? 1.0 : 0.25
        if firstClear { paidThisRun.insert(missionId) }
        // Rank and risk stack ADDITIVELY, not multiplicatively. Multiplied, a
        // top clear ran 1.6 × 1.5 = 2.40× base — M5 paid ¥94,800 off a ¥34,000
        // contract, and a full campaign banked ~¥570k against the ~¥444k it
        // costs to buy every item for all four runners, so you could buy out
        // the shop and still have change (playtest 2026-07-25: "the pay scale
        // is kinda crazy"). Additive keeps both incentives legible — an S rank
        // is still worth chasing and heat still pays for the risk — while
        // capping the best case at 1.60× instead of 2.40×.
        let bonusStack = 1.0 + (rankMult - 1.0) + (rewardMultiplier - 1.0)
        let credit = Int((Double(contract) * bonusStack * runFactor).rounded())
        playerNuyen += credit
        // Expose the factors so the debrief can show WHY the number is what
        // it is ("RANK S ×1.6 · HEAT ×1.25 · REPLAY 25%") instead of a bare
        // total that doesn't match the mission-select preview.
        lastRankMultiplier = rankMult
        lastRiskMultiplier = rewardMultiplier
        lastRunFactor      = runFactor
        // What THIS victory actually banked — the victory/debrief screens
        // read it so a replay shows "¥0 (already paid this run)" instead of
        // claiming the full payout next to a wallet that didn't move.
        lastWalletCredit = credit
        save()
    }

    /// Nuyen credited by the most recent recordVictory (reduced to the 25%
    /// residual rate on a replay of an already-paid mission). Display-only;
    /// not persisted.
    @Published private(set) var lastWalletCredit: Int = 0

    /// Payout factors from the most recent recordVictory — the debrief screen
    /// shows these so the credited total is explainable. Display-only.
    @Published private(set) var lastRankMultiplier: Double = 1.0
    @Published private(set) var lastRiskMultiplier: Double = 1.0
    @Published private(set) var lastRunFactor: Double = 1.0

    /// Score of the most recent recordVictory (THIS run, not the historical
    /// best). Display-only; not persisted.
    @Published private(set) var lastRunScore: Int = 0

    /// Clear the per-run "already paid" set — call when the campaign finale is
    /// completed so the next run-through earns the full economy again.
    func resetPaidThisRun() {
        paidThisRun.removeAll()
        save()
    }

    /// Spend nuyen from the wallet (black-market purchases). Returns false and
    /// does nothing if the player can't afford it.
    @discardableResult
    func spend(_ amount: Int) -> Bool {
        guard amount >= 0, playerNuyen >= amount else { return false }
        playerNuyen -= amount
        save()
        return true
    }

    /// Bounty paid for downing an enemy, scaled by its toughness (maxHP).
    /// Combat kills used to pay only XP + loot; per-mission contract payouts
    /// alone made early upgrades a slow grind. A typical early room (~5-6
    /// grunts ≈12 HP) now adds ~¥700-900 on top of the contract — enough to
    /// chip toward a stim/mod without trivializing the economy. Tougher
    /// enemies and bosses pay proportionally more.
    static func killBounty(maxHP: Int) -> Int {
        // ¥12/HP, floored at ¥80 so even a weak drone is worth picking off.
        max(80, maxHP * 12)
    }

    func awardKillNuyen(maxHP: Int) {
        playerNuyen += MissionStatsStore.killBounty(maxHP: maxHP)
        save()
    }

    /// Generic wallet credit — for systems that pay OUTSIDE the contract
    /// pipeline (gauntlet floor bonuses, future bounty events). Contract
    /// payouts must keep going through `recordVictory` so the rank/heat/
    /// replay factors and `lastWalletCredit` bookkeeping stay authoritative.
    func credit(_ amount: Int) {
        guard amount > 0 else { return }
        playerNuyen += amount
        save()
    }

    /// Fixer payoff — buy down persisted faction attention (¥ → heat relief).
    /// The recurring spend side of the heat loop: attention drives extra
    /// patrols/ambushes, decays only on trace-0 runs, and until now had no
    /// other release valve. Also syncs the live GameState copy so a bribe
    /// bought between missions shows in the next briefing without a relaunch.
    /// Returns the new attention value.
    /// @MainActor because it syncs the live (MainActor-isolated) GameState;
    /// every caller is UI-side anyway.
    @MainActor
    @discardableResult
    func reduceFactionAttention(_ faction: Faction, by amount: Int = 1) -> Int {
        var attention = loadFactionAttention()
        let newValue = max(0, attention[faction, default: 0] - amount)
        attention[faction] = newValue
        saveFactionAttention(attention)
        GameState.shared.factionAttention[faction] = newValue
        return newValue
    }

    /// Letter rank for a mission score. Tuned to the score components
    /// (survival ≤1600, kills, objective 250, efficiency ≤600).
    static func rank(forScore score: Int) -> String {
        switch score {
        case 2600...:      return "S"
        case 2100..<2600:  return "A"
        case 1500..<2100:  return "B"
        case 1...1499:     return "C"
        default:           return "—"
        }
    }

    /// Contract payout multiplier for a mission rank — makes the letter grade
    /// an economic outcome, not a cosmetic one. Steps are deliberately gentle
    /// (C→S is +60%) so a flawless run feels rewarded without doubling the
    /// tuned economy.
    static func rankPayoutMultiplier(forScore score: Int) -> Double {
        switch rank(forScore: score) {
        case "S": return 1.6
        case "A": return 1.35
        case "B": return 1.15
        default:  return 1.0
        }
    }

    /// Record the player's best score for a single mini-game victory.
    /// Stored separately from the full-mission score so it persists even if
    /// the player bails the mission afterwards. Updates `bestMiniGameScore`
    /// with `max(prev, score)`.
    func recordMiniGameScore(missionId: String, score: Int) {
        var rec = records[missionId] ?? .empty
        rec.bestMiniGameScore = max(rec.bestMiniGameScore, score)
        records[missionId] = rec
        save()
    }

    /// Clear ALL records (debug menu / restart-from-scratch use).
    func resetAll() {
        records = [:]
        playerNuyen = 0
        paidThisRun.removeAll()
        save()
    }

    // MARK: - Persistence

    /// Decode the records dictionary from the live blob, falling back to the
    /// last-good backup when the live blob is present but corrupt. Pure —
    /// extracted from load() so the recovery chain is testable (load() itself
    /// runs once per process at singleton init).
    static func decodeRecords(live: Data?, backup: Data?) -> [String: MissionRecord]? {
        if let data = live,
           let decoded = try? JSONDecoder().decode([String: MissionRecord].self, from: data) {
            return decoded
        }
        if live != nil, let backup,
           let decoded = try? JSONDecoder().decode([String: MissionRecord].self, from: backup) {
            dlog("[MissionStatsStore] records blob failed to decode — recovered from last-good backup")
            return decoded
        }
        return nil
    }

    private func load() {
        // Try the live blob, then the last-good backup — a corrupt blob used
        // to silently zero records/wallet, and the next save() permanently
        // overwrote the corrupt-but-inspectable data.
        if let decoded = MissionStatsStore.decodeRecords(
            live: UserDefaults.standard.data(forKey: storageKey),
            backup: UserDefaults.standard.data(forKey: storageKey + ".lastGood")) {
            records = decoded
        }
        playerNuyen = UserDefaults.standard.integer(forKey: nuyenStorageKey)
        if let data = UserDefaults.standard.data(forKey: paidThisRunKey),
           let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) {
            paidThisRun = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            // Preserve the displaced blob as last-good — only when it still
            // decodes, so a corrupt blob never shadows a healthy backup.
            if let old = UserDefaults.standard.data(forKey: storageKey),
               (try? JSONDecoder().decode([String: MissionRecord].self, from: old)) != nil {
                UserDefaults.standard.set(old, forKey: storageKey + ".lastGood")
            }
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        UserDefaults.standard.set(playerNuyen, forKey: nuyenStorageKey)
        if let data = try? JSONEncoder().encode(paidThisRun) {
            UserDefaults.standard.set(data, forKey: paidThisRunKey)
        }
    }

    // MARK: - Faction attention (campaign world-reaction state)

    private static let factionAttentionKey = "HexWire.FactionAttention.v1"

    /// Persist the campaign's faction-attention dict. Lives here next to the
    /// other campaign stores — it used to be memory-only, so force-quitting
    /// between missions reset corp/gang attention to baseline every launch.
    func saveFactionAttention(_ attention: [Faction: Int]) {
        let raw = Dictionary(uniqueKeysWithValues: attention.map { ($0.key.rawValue, $0.value) })
        UserDefaults.standard.set(raw, forKey: MissionStatsStore.factionAttentionKey)
    }

    func loadFactionAttention() -> [Faction: Int] {
        var result: [Faction: Int] = [.corp: 0, .gang: 0, .unknown: 0]
        guard let raw = UserDefaults.standard.dictionary(forKey: MissionStatsStore.factionAttentionKey) as? [String: Int] else {
            return result
        }
        for (k, v) in raw {
            if let f = Faction(rawValue: k) { result[f] = v }
        }
        return result
    }

    func resetFactionAttention() {
        UserDefaults.standard.removeObject(forKey: MissionStatsStore.factionAttentionKey)
    }

    // MARK: - Score Calculation

    /// Computes the player's score for a mission victory.
    /// Components:
    ///   • survival   : 400 per living runner (max 1600)
    ///   • kills      : 80 per enemy defeated
    ///   • objective  : 250 if `dataAcquired` (mission required hacking)
    ///   • efficiency : up to 600 bonus, 20 lost per round taken (so a 5-round
    ///                  run banks 500, a 30-round run banks nothing)
    /// Floor at 0; no upper cap so dominant runs feel rewarding.
    static func computeScore(
        enemiesDefeated: Int,
        livingPlayers: Int,
        roundsTaken: Int,
        dataAcquired: Bool
    ) -> Int {
        let survival = min(4, livingPlayers) * 400
        let kills = enemiesDefeated * 80
        let objective = dataAcquired ? 250 : 0
        let efficiency = max(0, 600 - roundsTaken * 20)
        return survival + kills + objective + efficiency
    }
}

// MARK: - Roster Persistence (progression carries across missions + NG+)

/// Persists the player roster (level / XP / attributes / skills / gear) across
/// missions AND New Game+ replays. Backed by UserDefaults JSON. Transient
/// combat state (HP, stun, mana, status, position) is reset each mission via
/// `freshenForMission` so only PROGRESSION carries — you start every mission at
/// full health but keep the levels you've earned.
final class RosterStore {
    static let shared = RosterStore()
    private let key = "HexWire.Roster.v1"
    private let backupKey = "HexWire.Roster.v1.lastGood"
    private init() { StorageMigration.migrateLegacyKeysIfNeeded() }

    /// Versioned envelope so future format changes can MIGRATE instead of
    /// silently wiping progression. The old bare-array format meant any
    /// decode failure (corruption, a new required field) fell back to L1
    /// defaults — and the next save permanently overwrote the old blob.
    private struct Envelope: Codable {
        var version: Int
        var team: [Character]
    }
    private static let currentVersion = 1

    /// Decode either the envelope or the legacy bare-array format.
    private static func decodeTeam(_ data: Data) -> [Character]? {
        let dec = JSONDecoder()
        if let env = try? dec.decode(Envelope.self, from: data), !env.team.isEmpty {
            return env.team
        }
        if let team = try? dec.decode([Character].self, from: data), !team.isEmpty {
            return team
        }
        return nil
    }

    /// Load the live blob; on decode failure fall back to the last-good backup.
    private func loadTeam() -> [Character]? {
        if let data = UserDefaults.standard.data(forKey: key) {
            if let team = RosterStore.decodeTeam(data) { return team }
            dlog("[RosterStore] roster blob failed to decode — trying last-good backup")
            if let backup = UserDefaults.standard.data(forKey: backupKey),
               let team = RosterStore.decodeTeam(backup) {
                dlog("[RosterStore] recovered roster from last-good backup")
                return team
            }
        }
        return nil
    }

    /// Save the team's progression. Call on mission victory.
    func save(_ team: [Character]) {
        guard let data = try? JSONEncoder().encode(Envelope(version: RosterStore.currentVersion, team: team)) else { return }
        // Preserve the displaced blob as last-good — only when it still
        // decodes, so a corrupt blob never shadows a healthy backup.
        if let old = UserDefaults.standard.data(forKey: key), RosterStore.decodeTeam(old) != nil {
            UserDefaults.standard.set(old, forKey: backupKey)
        }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Load the persisted roster, freshened for a new mission. Returns nil if
    /// nothing has been saved yet (very first mission of a brand-new game).
    func loadForMission() -> [Character]? {
        guard let team = loadTeam() else { return nil }
        team.forEach { RosterStore.freshenForMission($0) }
        return team
    }

    /// Load the saved roster for between-mission editing (shop / team screen).
    /// The victory save serializes the live team mid-combat, so the blob can
    /// carry dead/0-HP/stun residue; freshen the transient combat state on
    /// load so the TEAM screen shows healthy runners (progression untouched).
    /// Returns the default L1 runners if nothing's saved yet.
    func loadCanonical() -> [Character] {
        let team = loadTeam() ?? Character.allRunners
        team.forEach { RosterStore.freshenForMission($0) }
        return team
    }

    /// Wipe saved progression (brand-new game from scratch).
    func reset() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: backupKey)
    }

    /// Reset a character's per-mission combat state, KEEPING progression
    /// (level / xp / attributes / skills / maxHP / gear).
    static func freshenForMission(_ c: Character) {
        c.currentHP = c.maxHP
        c.currentStun = 0
        c.currentMana = c.maxMana
        c.status = .wounded            // the alive default for a fresh runner
        c.statusEffects = []
        c.hasActedThisRound = false
        c.initiativeRoll = 0
        c.positionX = 0
        c.positionY = 0
        // Reset the per-mission progression tally (drives the debrief scorecard).
        c.missionLevelsGained = 0
        c.missionStatGains = [:]
        c.missionXPGained = 0
        c.lastLevelUpSummary = ""
    }
}

// MARK: - New Game+ Tier

/// Persistent New Game+ tier. 0 = first playthrough (baseline difficulty).
/// Increments each time the campaign finale (Mission006) is completed, and
/// drives the enemy difficulty scaling so replays get harder while your
/// progression carries forward.
final class NGPlusStore {
    static let shared = NGPlusStore()
    private let key = "HexWire.NGPlusTier.v1"
    private init() { StorageMigration.migrateLegacyKeysIfNeeded() }

    var tier: Int {
        get { UserDefaults.standard.integer(forKey: key) }
        set { UserDefaults.standard.set(max(0, newValue), forKey: key) }
    }

    /// Bump to the next NG+ tier (called on finale completion).
    func advance() { tier += 1 }
    /// Full reset back to a first playthrough.
    func reset() { UserDefaults.standard.set(0, forKey: key) }

    // ── Difficulty scaling derived from the current tier ──
    /// Enemy max-HP multiplier: +25% per tier.
    var hpMultiplier: Double { 1.0 + 0.25 * Double(tier) }
    /// Flat bonus damage added to enemy hits: +1 per tier.
    var damageBonus: Int { tier }
    /// Extra enemies added per room, capped at +3 so high NG+ tiers don't turn
    /// every room into an unwinnable swarm (count compounds with HP + stats).
    var extraEnemiesPerRoom: Int { min(3, tier + tier / 2) }
    /// Banner label, empty on the first playthrough.
    var label: String { tier > 0 ? "NEW GAME+\(tier)" : "" }

    /// Scale an enemy's durability for the current NG+ tier (mutates in place).
    /// Damage scaling is handled centrally in GameState.escalatedIncomingDamage,
    /// so this only touches HP. No-op on the first playthrough (tier 0).
    func scaleForTier(_ enemy: Enemy) {
        guard tier > 0 else { return }
        let scaled = Int((Double(enemy.maxHP) * hpMultiplier).rounded())
        enemy.maxHP = scaled
        enemy.currentHP = scaled
        // "Leveled-up" opposition: each NG+ tier raises AGI + REA (so enemies
        // hit and dodge a bit better) and sharpens their weapon. BOD/WIL are
        // deliberately NOT bumped — stacking soak (BOD) on top of the HP
        // multiplier made enemies unkillable damage-sponges by ~tier 3, which
        // (with the extra-enemy count) was multiplicatively runaway.
        enemy.attributes.agi += tier
        enemy.attributes.rea += tier
        if var w = enemy.equippedWeapon {
            w.accuracy += tier
            w.damage += tier / 2
            enemy.equippedWeapon = w
        }
    }
}

// MARK: - Cyberware

/// A passive augmentation a runner can have installed. Effects are summed from
/// all installed pieces and applied in Character (soak/initiative in
/// computeDerived, accuracy/defense dice in the pools). `maxHP` is applied once
/// at install time (it mutates the runner's HP pool).
struct Cyberware: Identifiable, Equatable {
    let id: String
    let name: String
    let blurb: String
    let cost: Int
    let icon: String        // SF Symbol
    var soak: Int = 0
    var initiative: Int = 0
    var accuracyDice: Int = 0
    var defenseDice: Int = 0
    var maxHP: Int = 0
}

enum CyberwareCatalog {
    static let all: [Cyberware] = [
        Cyberware(id: "wired_reflexes",    name: "Wired Reflexes",        blurb: "Rewired nerves — strike first, dodge more.", cost: 12000, icon: "bolt.fill",                          initiative: 2, defenseDice: 1),
        Cyberware(id: "smartlink",         name: "Smartlink",             blurb: "Targeting overlay wired to your eye.",       cost: 15000, icon: "scope",                             accuracyDice: 2),
        Cyberware(id: "bone_lacing",       name: "Bone Lacing",           blurb: "Plastic-laced bones soak the hits.",         cost: 9000,  icon: "shield.lefthalf.filled",            soak: 2),
        Cyberware(id: "dermal_plating",    name: "Dermal Plating",        blurb: "Subdermal armor under the skin.",            cost: 14000, icon: "shield.fill",                       soak: 3),
        Cyberware(id: "muscle_aug",        name: "Muscle Augmentation",   blurb: "Lab-grown muscle. Tougher, surer hits.",     cost: 11000, icon: "figure.strengthtraining.traditional", accuracyDice: 1, maxHP: 5),
        Cyberware(id: "reaction_enhancer", name: "Reaction Enhancer",     blurb: "Faster reflexes — harder to hit.",           cost: 10000, icon: "hare.fill",                         defenseDice: 2),
        Cyberware(id: "synaptic_booster",  name: "Synaptic Booster",      blurb: "Top-shelf wetware across the board.",        cost: 18000, icon: "brain.head.profile",                initiative: 1, accuracyDice: 1, defenseDice: 1),
        Cyberware(id: "titanium_lacing",   name: "Titanium Bone Lacing",  blurb: "Mil-spec skeleton. Walking tank.",           cost: 22000, icon: "figure.stand",                      soak: 4, maxHP: 6),
    ]
    static func byId(_ id: String) -> Cyberware? { all.first { $0.id == id } }
}

// MARK: - Shop catalog (weapons / armor / stims)

enum ShopCatalog {
    static let weapons: [(cost: Int, weapon: Weapon, blurb: String, icon: String, iconKey: String)] = [
        (8000,  Weapon(name: "Ares Predator V",        type: .pistol, damage: 6,  accuracy: 6, armorPiercing: 2), "Reliable heavy pistol.",        "target",     "shopicon_ares_predator"),
        (11000, Weapon(name: "Ingram Smartgun",         type: .smg,    damage: 7,  accuracy: 6, armorPiercing: 2), "Smartlinked SMG, high cyclic.", "burst.fill", "shopicon_ingram_smartgun"),
        (14000, Weapon(name: "AK-97",                   type: .rifle,  damage: 9,  accuracy: 5, armorPiercing: 3), "Brutal assault rifle.",         "scope",      "shopicon_ak97"),
        (13000, Weapon(name: "Monofilament Katana",     type: .blade,  damage: 9,  accuracy: 7, armorPiercing: 3), "Cuts armor like cloth.",        "scissors",   "shopicon_mono_katana"),
        (25000, Weapon(name: "Panther Assault Cannon",  type: .rifle,  damage: 12, accuracy: 4, armorPiercing: 5), "Anti-vehicle. Overkill.",       "flame.fill", "shopicon_panther_cannon"),
    ]
    static let armor: [(cost: Int, armor: Armor, blurb: String, icon: String, iconKey: String)] = [
        (5000,  Armor(name: "Armor Jacket",      armorValue: 3, spellPenalty: 0),  "Streetwear with a bite.",         "shield",                  "shopicon_armor_jacket"),
        (8000,  Armor(name: "Lined Coat",        armorValue: 4, spellPenalty: 0),  "Discreet, solid protection.",     "shield.lefthalf.filled",  "shopicon_lined_coat"),
        (15000, Armor(name: "Full Body Armor",   armorValue: 6, spellPenalty: -2), "Heavy plate, hampers casting.",   "shield.fill",             "shopicon_full_body"),
        (28000, Armor(name: "Mil-Spec Hardsuit", armorValue: 8, spellPenalty: -2), "Military-grade carapace.",        "shield.righthalf.filled", "shopicon_milspec"),
    ]
    static let stims: [(cost: Int, item: Item, icon: String, iconKey: String)] = [
        (1500, Item.medkit,  "cross.case.fill", "shopicon_medkit"),
        (1000, Item.stim,    "syringe.fill",    "shopicon_stim"),
        (2000, Item.grenade, "smoke.fill",      "shopicon_grenade"),
    ]
    /// Purchasable (non-base) spells for the mage.
    static let spells: [(cost: Int, spell: SpellType, iconKey: String)] = [
        (16000, .powerBolt, "shopicon_powerbolt"),
        (9000, .stormBolt, "shopicon_stormbolt"),
    ]
}

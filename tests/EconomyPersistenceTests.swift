import XCTest
#if canImport(HexWire)
@testable import HexWire

/// Economy + persistence certification tests. These run against the real
/// UserDefaults of the test host, so every test snapshots and restores the
/// keys it touches — the suite must leave no residue (and must not depend on
/// residue from a previous run).
final class EconomyPersistenceTests: XCTestCase {

    private let touchedKeys = [
        "HexWire.MissionStats.v1", "HexWire.MissionStats.v1.lastGood",
        "HexWire.PlayerNuyen.v1", "HexWire.PaidThisRun.v1",
        "HexWire.Roster.v1", "HexWire.Roster.v1.lastGood",
        "HexWire.NGPlusTier.v1",
        "HexWire.Migration.KeyRename.v1",
        "ShadowrunGame.MissionStats.v1", "ShadowrunGame.PlayerNuyen.v1",
        "ShadowrunGame.Roster.v1", "ShadowrunGame.NGPlusTier.v1",
    ]
    private var snapshot: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        let d = UserDefaults.standard
        snapshot = [:]
        for key in touchedKeys {
            if let v = d.object(forKey: key) { snapshot[key] = v }
        }
    }

    override func tearDown() {
        // Zero the singleton's memory (and its disk writes) FIRST, then put
        // the snapshotted blobs back — the reverse order would wipe the
        // restored data with resetAll's empty save.
        MissionStatsStore.shared.resetAll()
        let d = UserDefaults.standard
        for key in touchedKeys { d.removeObject(forKey: key) }
        for (key, v) in snapshot { d.set(v, forKey: key) }
        super.tearDown()
    }

    // MARK: - Legacy key migration

    func testLegacyKeyMigrationCopiesOldValuesOnce() {
        let d = UserDefaults.standard
        d.removeObject(forKey: "HexWire.Migration.KeyRename.v1")
        d.removeObject(forKey: "HexWire.PlayerNuyen.v1")
        d.set(4321, forKey: "ShadowrunGame.PlayerNuyen.v1")

        StorageMigration.migrateLegacyKeysIfNeeded()

        XCTAssertEqual(d.integer(forKey: "HexWire.PlayerNuyen.v1"), 4321,
                       "legacy value must copy to the new key")
        XCTAssertEqual(d.integer(forKey: "ShadowrunGame.PlayerNuyen.v1"), 4321,
                       "old key is preserved, not deleted")
        XCTAssertTrue(d.bool(forKey: "HexWire.Migration.KeyRename.v1"))

        // Second run must be a no-op even if the legacy value changes.
        d.set(9999, forKey: "ShadowrunGame.PlayerNuyen.v1")
        StorageMigration.migrateLegacyKeysIfNeeded()
        XCTAssertEqual(d.integer(forKey: "HexWire.PlayerNuyen.v1"), 4321,
                       "flag-guarded migration must never replay")
    }

    func testLegacyKeyMigrationNeverOverwritesExistingNewKey() {
        let d = UserDefaults.standard
        d.removeObject(forKey: "HexWire.Migration.KeyRename.v1")
        d.set(100, forKey: "HexWire.PlayerNuyen.v1")     // player already on new key
        d.set(999, forKey: "ShadowrunGame.PlayerNuyen.v1")
        StorageMigration.migrateLegacyKeysIfNeeded()
        XCTAssertEqual(d.integer(forKey: "HexWire.PlayerNuyen.v1"), 100,
                       "existing new-key data must win over the legacy copy")
    }

    // MARK: - Contract payout math (wallet updates exactly once, bounded)

    func testFirstClearPayoutUsesRankRiskAndFullRunFactor() {
        let store = MissionStatsStore.shared
        store.resetAll()
        // Score 2600 = rank S (+60%). Risk +25%. First clear x1.0.
        // Rank and risk stack ADDITIVELY (2026-07 rebalance), so this is
        // x(1 + 0.6 + 0.25), not x1.6 * 1.25. Derived from basePayout so the
        // test tracks tuning changes instead of pinning a magic number.
        store.recordVictory(missionId: "Mission001", score: 2600, rewardMultiplier: 1.25)
        let base = Double(MissionStatsStore.basePayout(missionId: "Mission001"))
        let expected = Int((base * (1.0 + 0.6 + 0.25) * 1.0).rounded())
        XCTAssertEqual(store.playerNuyen, expected)
        XCTAssertEqual(store.lastWalletCredit, expected)
        XCTAssertEqual(store.lastRunFactor, 1.0)
        XCTAssertEqual(store.record(for: "Mission001").attempts, 1)
        XCTAssertEqual(store.record(for: "Mission001").bestScore, 2600)
    }

    func testReplayPaysResidualRateNotFullContract() {
        let store = MissionStatsStore.shared
        store.resetAll()
        store.recordVictory(missionId: "Mission001", score: 1, rewardMultiplier: 1.0) // C rank x1.0
        let afterFirst = store.playerNuyen
        let m1 = MissionStatsStore.basePayout(missionId: "Mission001")
        XCTAssertEqual(afterFirst, m1)

        // Replay: same mission pays the 25% residual, never a second full payout.
        store.recordVictory(missionId: "Mission001", score: 1, rewardMultiplier: 1.0)
        XCTAssertEqual(store.playerNuyen - afterFirst, Int((Double(m1) * 0.25).rounded()))
        XCTAssertEqual(store.lastRunFactor, 0.25)
        XCTAssertEqual(store.record(for: "Mission001").attempts, 2)
    }

    func testDataAndGrimoireBonusesOnlyWhenAcquired() {
        let store = MissionStatsStore.shared
        store.resetAll()
        store.recordVictory(missionId: "Mission003", score: 1,
                            dataAcquired: true, grimoireAcquired: true, rewardMultiplier: 1.0)
        XCTAssertEqual(store.playerNuyen,
                       MissionStatsStore.basePayout(missionId: "Mission003")
                       + MissionStatsStore.dataBonus(missionId: "Mission003")
                       + MissionStatsStore.grimoireBonus(missionId: "Mission003"))
    }

    func testPayoutNeverNegativeAndZeroScoreIsUnranked() {
        let store = MissionStatsStore.shared
        store.resetAll()
        store.recordVictory(missionId: "Mission001", score: 0, rewardMultiplier: 1.0)
        XCTAssertGreaterThanOrEqual(store.playerNuyen, 0)
        XCTAssertEqual(MissionStatsStore.rank(forScore: 0), "—")
    }

    func testRankBoundaries() {
        XCTAssertEqual(MissionStatsStore.rank(forScore: 2600), "S")
        XCTAssertEqual(MissionStatsStore.rank(forScore: 2599), "A")
        XCTAssertEqual(MissionStatsStore.rank(forScore: 2100), "A")
        XCTAssertEqual(MissionStatsStore.rank(forScore: 2099), "B")
        XCTAssertEqual(MissionStatsStore.rank(forScore: 1500), "B")
        XCTAssertEqual(MissionStatsStore.rank(forScore: 1499), "C")
        XCTAssertEqual(MissionStatsStore.rank(forScore: 1), "C")
        XCTAssertEqual(MissionStatsStore.rankPayoutMultiplier(forScore: 2600), 1.6)
        XCTAssertEqual(MissionStatsStore.rankPayoutMultiplier(forScore: 2100), 1.35)
        XCTAssertEqual(MissionStatsStore.rankPayoutMultiplier(forScore: 1500), 1.15)
        XCTAssertEqual(MissionStatsStore.rankPayoutMultiplier(forScore: 100), 1.0)
    }

    func testKillBountyScalesWithFloor() {
        XCTAssertEqual(MissionStatsStore.killBounty(maxHP: 1), 80, "floor at ¥80")
        XCTAssertEqual(MissionStatsStore.killBounty(maxHP: 6), 80)
        XCTAssertEqual(MissionStatsStore.killBounty(maxHP: 20), 240)
    }

    func testComputeScoreComponentsAndCaps() {
        // survival caps at 4 runners × 400; efficiency floors at 0.
        XCTAssertEqual(MissionStatsStore.computeScore(
            enemiesDefeated: 0, livingPlayers: 9, roundsTaken: 0, dataAcquired: false), 1600 + 600)
        XCTAssertEqual(MissionStatsStore.computeScore(
            enemiesDefeated: 5, livingPlayers: 2, roundsTaken: 40, dataAcquired: true),
            800 + 400 + 250 + 0)
    }

    func testSpendRejectsNegativeAndInsufficientFunds() {
        let store = MissionStatsStore.shared
        store.resetAll()
        store.credit(500)
        XCTAssertFalse(store.spend(-1), "negative spend must be rejected")
        XCTAssertFalse(store.spend(501), "overdraft must be rejected")
        XCTAssertEqual(store.playerNuyen, 500, "failed spends must not move the wallet")
        XCTAssertTrue(store.spend(500))
        XCTAssertEqual(store.playerNuyen, 0)
    }

    func testCreditIgnoresNonPositiveAmounts() {
        let store = MissionStatsStore.shared
        store.resetAll()
        store.credit(0)
        store.credit(-50)
        XCTAssertEqual(store.playerNuyen, 0)
    }

    func testSaveKeepsLastGoodBackupOfPreviousDecodableBlob() {
        let store = MissionStatsStore.shared
        store.resetAll()
        store.recordVictory(missionId: "Mission001", score: 100, rewardMultiplier: 1.0)
        store.recordVictory(missionId: "Mission002", score: 100, rewardMultiplier: 1.0)
        let d = UserDefaults.standard
        guard let backup = d.data(forKey: "HexWire.MissionStats.v1.lastGood"),
              let decoded = try? JSONDecoder().decode([String: MissionRecord].self, from: backup) else {
            return XCTFail("lastGood backup missing or undecodable")
        }
        // The backup is the state BEFORE the most recent save.
        XCTAssertNotNil(decoded["Mission001"])
        XCTAssertNil(decoded["Mission002"])
    }

    // MARK: - Roster persistence (round trip, corruption, legacy format)

    func testRosterRoundTripPreservesProgression() {
        RosterStore.shared.reset()
        let team = Character.allRunners
        team[0].maxHP = 987   // progression marker
        RosterStore.shared.save(team)
        let loaded = RosterStore.shared.loadCanonical()
        XCTAssertEqual(loaded.count, team.count)
        XCTAssertEqual(loaded[0].maxHP, 987)
        XCTAssertEqual(loaded.map(\.name), team.map(\.name))
    }

    func testCorruptRosterBlobFallsBackToDefaults() {
        RosterStore.shared.reset()
        UserDefaults.standard.set(Data("not json".utf8), forKey: "HexWire.Roster.v1")
        let loaded = RosterStore.shared.loadCanonical()
        XCTAssertEqual(loaded.count, Character.allRunners.count,
                       "corrupt save with no backup must yield the default roster, not crash")
    }

    func testCorruptRosterBlobRecoversFromLastGoodBackup() {
        RosterStore.shared.reset()
        let teamA = Character.allRunners
        teamA[0].maxHP = 999
        RosterStore.shared.save(teamA)          // live = A
        let teamB = Character.allRunners
        teamB[0].maxHP = 555
        RosterStore.shared.save(teamB)          // live = B, lastGood = A
        UserDefaults.standard.set(Data("garbage".utf8), forKey: "HexWire.Roster.v1")
        let recovered = RosterStore.shared.loadCanonical()
        XCTAssertEqual(recovered[0].maxHP, 999,
                       "corrupt live blob must recover the last-good backup")
    }

    func testLegacyBareArrayRosterFormatStillDecodes() {
        RosterStore.shared.reset()
        let team = Character.allRunners
        team[0].maxHP = 777
        let bare = try! JSONEncoder().encode(team)   // pre-envelope format
        UserDefaults.standard.set(bare, forKey: "HexWire.Roster.v1")
        let loaded = RosterStore.shared.loadCanonical()
        XCTAssertEqual(loaded[0].maxHP, 777, "legacy bare-array saves must migrate-decode")
    }

    func testFreshenForMissionResetsTransientCombatStateOnly() {
        let c = Character.allRunners[0]
        c.maxHP = 40
        c.currentHP = 3
        c.currentStun = 5
        c.hasActedThisRound = true
        c.positionX = 9; c.positionY = 9
        RosterStore.freshenForMission(c)
        XCTAssertEqual(c.currentHP, 40, "HP refills to the PROGRESSED max")
        XCTAssertEqual(c.currentStun, 0)
        XCTAssertFalse(c.hasActedThisRound)
        XCTAssertEqual(c.positionX, 0)
        XCTAssertTrue(c.statusEffects.isEmpty)
        XCTAssertEqual(c.maxHP, 40, "progression is untouched")
    }

    // MARK: - New Game+ scaling

    func testNGPlusTierDerivedScaling() {
        let store = NGPlusStore.shared
        let saved = store.tier
        defer { store.tier = saved }

        store.tier = 0
        XCTAssertEqual(store.hpMultiplier, 1.0)
        XCTAssertEqual(store.extraEnemiesPerRoom, 0)
        store.tier = 2
        XCTAssertEqual(store.hpMultiplier, 1.5)
        XCTAssertEqual(store.damageBonus, 2)
        XCTAssertEqual(store.extraEnemiesPerRoom, 3)
        store.tier = 6
        XCTAssertEqual(store.extraEnemiesPerRoom, 3, "extra-enemy count caps at +3")
        store.tier = -5
        XCTAssertEqual(store.tier, 0, "tier clamps at zero")
    }

    func testNGPlusScaleForTierIsNoOpAtTierZeroAndScalesAbove() {
        let store = NGPlusStore.shared
        let saved = store.tier
        defer { store.tier = saved }

        store.tier = 0
        let base = Enemy.corpGuard()
        let baseHP = base.maxHP
        store.scaleForTier(base)
        XCTAssertEqual(base.maxHP, baseHP, "tier 0 must not scale")

        store.tier = 2
        let scaled = Enemy.corpGuard()
        let preHP = scaled.maxHP
        let preAgi = scaled.attributes.agi
        store.scaleForTier(scaled)
        XCTAssertEqual(scaled.maxHP, Int((Double(preHP) * 1.5).rounded()))
        XCTAssertEqual(scaled.currentHP, scaled.maxHP)
        XCTAssertEqual(scaled.attributes.agi, preAgi + 2)
    }

    // MARK: - Payout ceiling (2026-07 rebalance)

    /// Rank and risk must stack ADDITIVELY. Multiplied they hit 1.6 x 1.5 =
    /// 2.40x, which let a full campaign out-earn the entire shop catalogue
    /// (playtest 2026-07-25: "the pay scale is kinda crazy").
    func testRankAndRiskStackAdditivelyNotMultiplicatively() {
        MissionStatsStore.shared.resetAll()
        let base = MissionStatsStore.basePayout(missionId: "Mission005")
        // Best case: S rank (1.6) + high heat (1.5).
        MissionStatsStore.shared.recordVictory(
            missionId: "Mission005", score: 100_000,
            dataAcquired: false, grimoireAcquired: false, rewardMultiplier: 1.5)
        let paid = MissionStatsStore.shared.playerNuyen
        let multiplicative = Int((Double(base) * 1.6 * 1.5).rounded())
        let additive       = Int((Double(base) * (1.0 + 0.6 + 0.5)).rounded())
        XCTAssertEqual(paid, additive,
                       "best-case payout must use the additive stack (1.60x), not 2.40x")
        XCTAssertLessThan(paid, multiplicative,
                          "additive stacking must pay strictly less than the old compounding")
    }

    /// A full campaign of FIRST clears at the best rank and heat must not fund
    /// the entire catalogue for the whole team — gear has to stay a choice.
    func testFullCampaignCannotBuyOutTheShopForEveryone() {
        MissionStatsStore.shared.resetAll()
        let ids = ["Mission001","Mission002","Mission002_5","Mission003","Mission003_5",
                   "Mission004","Mission004_5","Mission005","Mission005_5","Mission006"]
        for id in ids {
            MissionStatsStore.shared.recordVictory(
                missionId: id, score: 100_000,
                dataAcquired: false, grimoireAcquired: false, rewardMultiplier: 1.5)
        }
        let banked = MissionStatsStore.shared.playerNuyen
        // One of every catalogue item, for one runner.
        let oneOfEverything = 111_000
        XCTAssertGreaterThan(banked, oneOfEverything,
                             "a perfect campaign should still afford a strong single loadout")
        XCTAssertLessThan(banked, oneOfEverything * 4,
                          "a perfect campaign must NOT fully kit all four runners "
                          + "(banked \(banked) vs \(oneOfEverything * 4) to buy everything)")
        MissionStatsStore.shared.resetAll()
    }
}
#endif

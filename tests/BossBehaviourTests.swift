import XCTest
#if canImport(HexWire)
@testable import HexWire

/// Boss behaviour certification.
///
/// Playtest 2026-07-25: "m3 boss (sato) is too easy, he doesn't move around or
/// attack much, he just kinda sat there" and "m5 boss ... moves a little, but
/// didn't make any attacks". Both bosses spawn MID-COMBAT once the room is
/// otherwise clear, so they exercise a path the authored-squad enemies never do.
///
/// These drive `runEnemyAI` directly — the synchronous per-enemy entry point the
/// enemy phase calls — and assert a boss actually does something on its turn.
@MainActor
final class BossBehaviourTests: XCTestCase {

    private let gs = GameState.shared
    private var savedTeam: [Character] = []
    private var savedEnemies: [Enemy] = []
    private var savedTier = 0

    override func setUp() async throws {
        savedTeam = gs.playerTeam
        savedEnemies = gs.enemies
        savedTier = NGPlusStore.shared.tier
        NGPlusStore.shared.tier = 0
    }

    override func tearDown() async throws {
        gs.playerTeam = savedTeam
        gs.enemies = savedEnemies
        NGPlusStore.shared.tier = savedTier
        RoomManager.shared.unloadMission()
    }

    /// Open arena so movement is never blocked by geometry — this isolates the
    /// AI's decision from pathing failures.
    private func openArena(_ w: Int = 7, _ h: Int = 12) -> [[Int]] {
        (0..<h).map { y in
            (0..<w).map { x in
                (x == 0 || y == 0 || x == w - 1 || y == h - 1) ? TileType.wall.rawValue
                                                               : TileType.floor.rawValue
            }
        }
    }

    /// Put one runner on the board at a known tile and clear the field.
    @discardableResult
    private func stageArena(bossAt: (x: Int, y: Int),
                            runnerAt: (x: Int, y: Int)) -> (boss: Enemy, runner: Character)? {
        // Load a real mission so the roster is populated the way combat expects,
        // then replace the board with a clean arena.
        if gs.playerTeam.isEmpty {
            guard RoomManager.shared.loadMission(named: "Mission003") != nil else { return nil }
            _ = gs.prepareMissionForCombat(named: "Mission003")
        }
        gs.currentMissionTiles = openArena()
        gs.pendingSpawns = []
        guard let runner = gs.playerTeam.first(where: { $0.isAlive })
                ?? gs.playerTeam.first else { return nil }
        for c in gs.playerTeam where c.id != runner.id { c.currentHP = 0 }
        runner.currentHP = runner.maxHP
        runner.positionX = runnerAt.x
        runner.positionY = runnerAt.y
        return (boss: Enemy.bossMage(), runner: runner)
    }

    private func runBossTurn(_ boss: Enemy, at pos: (x: Int, y: Int)) {
        boss.positionX = pos.x
        boss.positionY = pos.y
        gs.enemies = [boss]
        gs.runEnemyAI(enemy: boss, livingEnemies: [boss])
    }

    /// A boss must not idle. Every boss archetype, placed across the room from a
    /// runner, has to either close distance or land an attack on its turn.
    func testEveryBossArchetypeActsOnItsTurn() throws {
        // The REAL boss factories — the ones deployBoss/spawnSatoBoss use.
        // `combatMech()` is the rank-and-file mech, not M5's boss.
        let bosses: [(String, () -> Enemy)] = [
            ("bossmage", { Enemy.bossMage() }),
            ("bossmech", { Enemy.bossMech() }),
            ("bossagi", { Enemy.bossAGI() }),
            ("bosscorp", { Enemy.bossCorp() }),
        ]
        for (label, make) in bosses {
            guard let staged = stageArena(bossAt: (3, 9), runnerAt: (3, 2)) else {
                throw XCTSkip("no roster available")
            }
            let runner = staged.runner
            let boss = make()
            let hpBefore = runner.currentHP
            let startDist = CombatMechanics.hexDistance(x1: 3, y1: 9,
                                                        x2: runner.positionX, y2: runner.positionY)
            runBossTurn(boss, at: (3, 9))

            let endDist = CombatMechanics.hexDistance(x1: boss.positionX, y1: boss.positionY,
                                                      x2: runner.positionX, y2: runner.positionY)
            let closed = endDist < startDist
            let hurt = runner.currentHP < hpBefore
            XCTAssertTrue(closed || hurt,
                          "\(label): boss did nothing on its turn — did not close "
                          + "(\(startDist)→\(endDist)) and dealt no damage. This is the "
                          + "\"just sat there\" playtest bug.")
        }
    }

    /// Adjacent to a runner with nowhere to advance, a boss MUST attack. Closing
    /// distance is not an excuse when it is already in melee.
    func testBossAdjacentToRunnerAttacks() throws {
        guard let staged = stageArena(bossAt: (3, 3), runnerAt: (3, 2)) else {
            throw XCTSkip("no roster available")
        }
        let runner = staged.runner
        let hpBefore = runner.currentHP
        var landed = false
        // The bolt can miss on the dice; give it a few turns to connect rather
        // than asserting on a single roll.
        for _ in 0..<8 {
            runner.currentHP = runner.maxHP
            let boss = Enemy.bossMage()
            runBossTurn(boss, at: (3, 3))
            if runner.currentHP < runner.maxHP { landed = true; break }
        }
        XCTAssertTrue(landed,
                      "bossmage adjacent to a runner never landed a hit across 8 turns "
                      + "(runner started at \(hpBefore) HP)")
    }

    /// The M5 mech specifically. It spawns at (3,8) in room_3 while the party
    /// enters near the bottom — roughly 7 tiles apart. With a 2-tile move budget
    /// and a hard range-6 firing gate it could not shoot on the turn it spawned,
    /// so the party killed it on the approach and it "never attacked".
    func testMechBossThreatensFromItsSpawnDistance() throws {
        guard let staged = stageArena(bossAt: (3, 8), runnerAt: (3, 2)) else {
            throw XCTSkip("no roster available")
        }
        let runner = staged.runner
        var landed = false
        for _ in 0..<12 {
            runner.currentHP = runner.maxHP
            let boss = Enemy.bossMech()
            runBossTurn(boss, at: (3, 8))   // real M5 boss spawn tile
            if runner.currentHP < runner.maxHP { landed = true; break }
        }
        XCTAssertTrue(landed,
                      "MEKTON-7 spawned ~6 tiles from a runner and never landed a shot "
                      + "in 12 turns — it cannot only be a threat after walking half the arena")
    }

    /// Every boss reveal must raise the cinematic splash. Playtest 2026-07-25:
    /// "boss appeared without the boss splash screen" on M3R2.
    func testSatoRevealPresentsTheBossSplash() throws {
        guard RoomManager.shared.loadMission(named: "Mission003") != nil else {
            throw XCTSkip("mission JSONs not bundled")
        }
        _ = gs.prepareMissionForCombat(named: "Mission003")
        guard let room2 = RoomManager.shared.currentMission?.rooms
                .first(where: { $0.id == "room_2" }) else {
            throw XCTSkip("M3 room_2 missing")
        }
        gs.applyRoomEntry(to: room2, enemies: [], pendingSpawns: [],
                          spawnAnchor: room2.playerSpawn)
        gs.mageBossPhase2Triggered = false
        gs.mageBossPhase2Pending = false
        gs.bossIntro = nil

        // Stage the room exactly as the scripted trigger expects: the corp mage
        // is the ONLY enemy, so killing him manifests Sato immediately.
        let mage = MissionSetupService.makeEnemy(gameState: gs, for: "mage", archetype: .enforcer)
        mage.positionX = 3; mage.positionY = 9
        gs.enemies = [mage]
        gs.pendingSpawns = []
        mage.currentHP = 0

        CombatFlowController.checkMageBossPhase2(gameState: gs, deadEnemyId: mage.id)

        XCTAssertTrue(gs.enemies.contains { $0.archetype.lowercased() == "bossmage" },
                      "Sato must manifest when the corp mage dies alone in the chamber")
        XCTAssertNotNil(gs.bossIntro,
                        "the boss reveal must raise the cinematic splash — a boss that "
                        + "simply appears on the board reads as a bug")
        XCTAssertEqual(gs.bossIntro?.splashKey, "boss_splash_mage",
                       "Sato's reveal must use the mage splash art")
    }

    /// Bosses get a second activation per enemy phase to offset facing a squad
    /// of four. Regular enemies must NOT.
    func testOnlyBossArchetypesGetTheExtraActivation() {
        for arch in ["bossmage", "bossmech", "bossagi", "bosscorp"] {
            XCTAssertTrue(CombatFlowController.isBossArchetype(arch),
                          "\(arch) must qualify for the boss double activation")
        }
        for arch in ["guard", "elite", "mech", "juggernaut", "sniper", "drone"] {
            XCTAssertFalse(CombatFlowController.isBossArchetype(arch),
                           "\(arch) is rank-and-file — it must not act twice")
        }
    }
}
#endif

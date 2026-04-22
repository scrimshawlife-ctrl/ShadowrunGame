import Foundation

// Fallback mirror audit logic:
// This script mirrors the deterministic map-shaping rules from GameState.applyMapSituation
// because app-module import is not guaranteed in standalone script execution.

enum Tile: Int {
    case floor = 0
    case wall = 1
    case cover = 2
    case door = 3
    case extraction = 4
}

enum MapSituation: CaseIterable {
    case corridor
    case openZone
    case chokepoint

    var label: String {
        switch self {
        case .corridor: return "CORRIDOR"
        case .openZone: return "OPEN ZONE"
        case .chokepoint: return "CHOKEPOINT"
        }
    }
}

struct SpawnPoint: Codable {
    let x: Int
    let y: Int
}

struct EnemySpawn: Codable {
    let type: String
    let x: Int
    let y: Int
    let delay: Int
}

struct Mission: Codable {
    let id: String
    let title: String
    let width: Int
    let height: Int
    let playerSpawn: SpawnPoint
    let extractionPoint: SpawnPoint
    let map: [[Int]]
    let enemies: [EnemySpawn]
}

struct Room: Codable {
    let id: String
    let title: String
    let map: [[Int]]
    let playerSpawn: SpawnPoint
    let extractionPoint: SpawnPoint?
    let enemies: [EnemySpawn]
}

struct MultiRoomMission: Codable {
    let id: String
    let title: String
    let rooms: [Room]
}

struct MapFixture {
    let source: String
    let map: [[Int]]
    let playerSpawn: SpawnPoint
    let extraction: SpawnPoint
    let enemies: [EnemySpawn]
}

struct AuditResult {
    let source: String
    let situation: MapSituation
    let width: Int
    let height: Int
    let wallCount: Int
    let floorCount: Int
    let coverCount: Int
    let walkableRatio: Double
    let extractionReachable: Bool
    let flags: [String]
    let notes: [String]
}

func tileKey(x: Int, y: Int) -> String { "\(x),\(y)" }

func applyMapSituation(
    situation: MapSituation,
    to originalMap: [[Int]],
    extractionPoint: (x: Int, y: Int),
    protectedTiles: Set<String>
) -> ([[Int]], (x: Int, y: Int)) {
    guard !originalMap.isEmpty else { return (originalMap, extractionPoint) }

    var map = originalMap
    let height = map.count
    let width = map.first?.count ?? 0
    let laneX = width / 2
    var updatedExtraction = extractionPoint

    func isProtected(_ x: Int, _ y: Int) -> Bool {
        protectedTiles.contains(tileKey(x: x, y: y))
    }

    func canRewrite(_ x: Int, _ y: Int) -> Bool {
        guard y >= 0, y < height, x >= 0, x < map[y].count else { return false }
        if isProtected(x, y) { return false }
        let tile = map[y][x]
        return tile != Tile.door.rawValue && tile != Tile.extraction.rawValue
    }

    switch situation {
    case .corridor:
        for y in 0..<height {
            if canRewrite(laneX, y) { map[y][laneX] = Tile.floor.rawValue }
            if laneX - 1 >= 0, canRewrite(laneX - 1, y), y % 2 == 0 {
                map[y][laneX - 1] = Tile.cover.rawValue
            }
            if laneX + 1 < width, canRewrite(laneX + 1, y), y % 2 == 1 {
                map[y][laneX + 1] = Tile.cover.rawValue
            }
        }
    case .openZone:
        let xStart = max(1, width / 2 - 2)
        let xEnd = min(width - 2, width / 2 + 2)
        let yStart = max(1, height / 2 - 2)
        let yEnd = min(height - 2, height / 2 + 2)
        if xStart <= xEnd && yStart <= yEnd {
            for y in yStart...yEnd {
                for x in xStart...xEnd where canRewrite(x, y) {
                    map[y][x] = Tile.floor.rawValue
                }
            }
        }
        if height > 2 && width > 2 {
            for y in 1..<(height - 1) {
                for x in 1..<(width - 1) where canRewrite(x, y) {
                    if map[y][x] == Tile.wall.rawValue && (x + y) % 2 == 0 {
                        map[y][x] = Tile.floor.rawValue
                    }
                }
            }
        }
    case .chokepoint:
        let targetY = extractionPoint.y < height / 2 ? 1 : max(1, height - 2)
        let targetX = max(0, width - 1)
        if extractionPoint.y >= 0, extractionPoint.y < height, extractionPoint.x >= 0, extractionPoint.x < map[extractionPoint.y].count,
           map[extractionPoint.y][extractionPoint.x] == Tile.extraction.rawValue {
            map[extractionPoint.y][extractionPoint.x] = Tile.floor.rawValue
        }
        if targetY >= 0, targetY < height, targetX >= 0, targetX < map[targetY].count {
            map[targetY][targetX] = Tile.extraction.rawValue
            updatedExtraction = (targetX, targetY)
        }

        let laneY = targetY
        for x in min(laneX, targetX)...max(laneX, targetX) where canRewrite(x, laneY) {
            map[laneY][x] = Tile.floor.rawValue
        }
        for y in min(height / 2, laneY)...max(height / 2, laneY) where canRewrite(laneX, y) {
            map[y][laneX] = Tile.floor.rawValue
        }

        for y in 0..<height {
            for x in 0..<min(width, map[y].count) where canRewrite(x, y) {
                let isLane = (x == laneX) || (y == laneY && x >= min(laneX, targetX) && x <= max(laneX, targetX))
                if !isLane && (x <= 1 || x >= width - 2 || abs(x - laneX) >= 3) {
                    map[y][x] = Tile.wall.rawValue
                }
            }
        }
    }

    return (map, updatedExtraction)
}

func isWalkable(_ tile: Int) -> Bool {
    tile == Tile.floor.rawValue || tile == Tile.cover.rawValue || tile == Tile.door.rawValue || tile == Tile.extraction.rawValue
}

func bfsReachable(map: [[Int]], from start: SpawnPoint, to goal: SpawnPoint) -> Bool {
    let height = map.count
    guard height > 0 else { return false }
    let width = map.first?.count ?? 0
    guard start.x >= 0, start.x < width, start.y >= 0, start.y < height else { return false }
    guard goal.x >= 0, goal.x < width, goal.y >= 0, goal.y < height else { return false }
    guard isWalkable(map[start.y][start.x]), isWalkable(map[goal.y][goal.x]) else { return false }

    var queue: [(Int, Int)] = [(start.x, start.y)]
    var visited = Set<String>([tileKey(x: start.x, y: start.y)])
    var idx = 0
    let dirs = [(1,0),(-1,0),(0,1),(0,-1)]

    while idx < queue.count {
        let (x, y) = queue[idx]
        idx += 1
        if x == goal.x && y == goal.y { return true }
        for (dx, dy) in dirs {
            let nx = x + dx
            let ny = y + dy
            guard ny >= 0, ny < height, nx >= 0, nx < width else { continue }
            guard isWalkable(map[ny][nx]) else { continue }
            let key = tileKey(x: nx, y: ny)
            if visited.contains(key) { continue }
            visited.insert(key)
            queue.append((nx, ny))
        }
    }

    return false
}

func loadFixtures(missionsDir: URL) -> [MapFixture] {
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(at: missionsDir, includingPropertiesForKeys: nil) else { return [] }

    var fixtures: [MapFixture] = []
    let decoder = JSONDecoder()

    for file in files where file.pathExtension == "json" {
        guard let data = try? Data(contentsOf: file) else { continue }
        let name = file.lastPathComponent
        if name.contains("_multi") {
            if let mm = try? decoder.decode(MultiRoomMission.self, from: data), let first = mm.rooms.first {
                let extraction = first.extractionPoint ?? first.playerSpawn
                fixtures.append(MapFixture(
                    source: "\(name)::\(first.id)",
                    map: first.map,
                    playerSpawn: first.playerSpawn,
                    extraction: extraction,
                    enemies: first.enemies
                ))
            }
        } else {
            if let m = try? decoder.decode(Mission.self, from: data) {
                fixtures.append(MapFixture(
                    source: name,
                    map: m.map,
                    playerSpawn: m.playerSpawn,
                    extraction: m.extractionPoint,
                    enemies: m.enemies
                ))
            }
        }
    }

    return fixtures.sorted { $0.source < $1.source }
}

func auditFixture(_ fixture: MapFixture, situation: MapSituation) -> AuditResult {
    let protected = Set(fixture.enemies.map { tileKey(x: $0.x, y: $0.y) } + [tileKey(x: fixture.playerSpawn.x, y: fixture.playerSpawn.y)])
    let (shapedMap, extraction) = applyMapSituation(
        situation: situation,
        to: fixture.map,
        extractionPoint: (fixture.extraction.x, fixture.extraction.y),
        protectedTiles: protected
    )

    let height = shapedMap.count
    let width = shapedMap.first?.count ?? 0
    var flags: [String] = []
    var notes: [String] = ["OBSERVED: fallback mirror of map shaping rules (runtime module import not used)."]

    func inBounds(_ x: Int, _ y: Int) -> Bool {
        y >= 0 && y < height && x >= 0 && x < width
    }

    // Spawn safety
    var occupied = Set<String>()
    let playerValid = inBounds(fixture.playerSpawn.x, fixture.playerSpawn.y)
    if !playerValid || (playerValid && shapedMap[fixture.playerSpawn.y][fixture.playerSpawn.x] == Tile.wall.rawValue) {
        flags.append("SPAWN_BLOCKED")
        notes.append("Player spawn invalid after shaping.")
    }
    if playerValid {
        occupied.insert(tileKey(x: fixture.playerSpawn.x, y: fixture.playerSpawn.y))
    }

    for enemy in fixture.enemies {
        let valid = inBounds(enemy.x, enemy.y)
        if !valid || (valid && shapedMap[enemy.y][enemy.x] == Tile.wall.rawValue) {
            flags.append("SPAWN_BLOCKED")
            notes.append("Enemy spawn invalid: (\(enemy.x),\(enemy.y)).")
        }
        let key = tileKey(x: enemy.x, y: enemy.y)
        if occupied.contains(key) {
            flags.append("DUPLICATE_SPAWN")
        }
        occupied.insert(key)
    }

    // Extraction checks
    let extractionInBounds = inBounds(extraction.x, extraction.y)
    if !extractionInBounds {
        flags.append("NO_EXTRACTION_PATH")
        notes.append("Extraction out of bounds.")
    }
    let extractionIsWall = extractionInBounds ? shapedMap[extraction.y][extraction.x] == Tile.wall.rawValue : true
    if extractionIsWall {
        flags.append("NO_EXTRACTION_PATH")
        notes.append("Extraction is on wall tile.")
    }

    let extractionPoint = SpawnPoint(x: extraction.x, y: extraction.y)
    let reachable = bfsReachable(map: shapedMap, from: fixture.playerSpawn, to: extractionPoint)
    if !reachable {
        flags.append("NO_EXTRACTION_PATH")
    }

    var wallCount = 0
    var floorCount = 0
    var coverCount = 0
    var walkableCount = 0
    let total = max(1, width * height)

    for row in shapedMap {
        for tile in row {
            if tile == Tile.wall.rawValue { wallCount += 1 }
            if tile == Tile.floor.rawValue { floorCount += 1 }
            if tile == Tile.cover.rawValue { coverCount += 1 }
            if isWalkable(tile) { walkableCount += 1 }
        }
    }

    let ratio = Double(walkableCount) / Double(total)
    if ratio < 0.35 { flags.append("TOO_WALLED") }
    if ratio > 0.90 { flags.append("TOO_OPEN") }

    if flags.isEmpty {
        notes.append("No risk flags triggered.")
    }

    return AuditResult(
        source: fixture.source,
        situation: situation,
        width: width,
        height: height,
        wallCount: wallCount,
        floorCount: floorCount,
        coverCount: coverCount,
        walkableRatio: ratio,
        extractionReachable: reachable,
        flags: Array(Set(flags)).sorted(),
        notes: notes
    )
}

let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let missionsDir = cwd.appendingPathComponent("Missions")
let fixtures = loadFixtures(missionsDir: missionsDir)

if fixtures.isEmpty {
    print("No mission fixtures found under Missions/.")
    exit(0)
}

var results: [AuditResult] = []
for fixture in fixtures {
    for situation in MapSituation.allCases {
        results.append(auditFixture(fixture, situation: situation))
    }
}

let hasFail = results.contains { !$0.flags.isEmpty }
let hasCritical = results.contains { $0.flags.contains("NO_EXTRACTION_PATH") || $0.flags.contains("SPAWN_BLOCKED") }
let verdict: String = hasCritical ? "FAIL" : (hasFail ? "PARTIAL" : "PASS")

var lines: [String] = []
lines.append("# Map Situation Audit v0.1")
lines.append("")
lines.append("## Verdict")
lines.append(verdict)
lines.append("")
lines.append("## Summary Table")
lines.append("Situation | Size | Walkable Ratio | Extraction Reachable | Flags")
lines.append("---|---|---:|---|---")
for row in results {
    let size = "\(row.width)x\(row.height)"
    let flags = row.flags.isEmpty ? "none" : row.flags.joined(separator: ", ")
    let reach = row.extractionReachable ? "YES" : "NO"
    lines.append("\(row.situation.label) (\(row.source)) | \(size) | \(String(format: "%.2f", row.walkableRatio)) | \(reach) | \(flags)")
}

lines.append("")
lines.append("## Situation Details")
for situation in MapSituation.allCases {
    lines.append("")
    lines.append("### \(situation.label)")
    for row in results where row.situation == situation {
        lines.append("- Source: \(row.source)")
        lines.append("  - Map Size: \(row.width)x\(row.height)")
        lines.append("  - Counts: wall=\(row.wallCount), floor=\(row.floorCount), cover=\(row.coverCount)")
        lines.append("  - Walkable Ratio: \(String(format: "%.2f", row.walkableRatio))")
        lines.append("  - Extraction Reachable: \(row.extractionReachable ? "YES" : "NO")")
        lines.append("  - Flags: \(row.flags.isEmpty ? "none" : row.flags.joined(separator: ", "))")
        lines.append("  - Notes: \(row.notes.joined(separator: " | "))")
    }
}

lines.append("")
lines.append("## Recommendations")
let riskRows = results.filter { !$0.flags.isEmpty }
if riskRows.isEmpty {
    lines.append("- None. Current deterministic shaping passed all configured risk checks.")
} else {
    lines.append("- Investigate rows with `NO_EXTRACTION_PATH` or `SPAWN_BLOCKED` first.")
    lines.append("- Rebalance rows with `TOO_WALLED` / `TOO_OPEN` only if they conflict with intended mission feel.")
}

let auditDir = cwd.appendingPathComponent("docs").appendingPathComponent("audit")
try? FileManager.default.createDirectory(at: auditDir, withIntermediateDirectories: true)
let reportFile = auditDir.appendingPathComponent("MapSituationAudit.md")
try? lines.joined(separator: "\n").write(to: reportFile, atomically: true, encoding: .utf8)

print("Audited fixtures: \(fixtures.count)")
print("Audit rows: \(results.count)")
print("Verdict: \(verdict)")
print("Report: \(reportFile.path)")

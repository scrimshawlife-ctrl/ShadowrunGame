import Foundation

@MainActor
struct PathingAndAIHelpers {

    static func hexNeighbors(gameState: GameState, x: Int, y: Int) -> [(Int, Int)] {
        if x % 2 == 0 {
            return [(x,y-1),(x,y+1),(x-1,y-1),(x-1,y),(x+1,y-1),(x+1,y)]
        } else {
            return [(x,y-1),(x,y+1),(x-1,y),(x-1,y+1),(x+1,y),(x+1,y+1)]
        }
    }

    static func hexAdjacent(gameState: GameState, x1: Int, y1: Int, x2: Int, y2: Int) -> Bool {
        hexNeighbors(gameState: gameState, x: x1, y: y1).contains { $0.0 == x2 && $0.1 == y2 }
    }

    static func hexDistance(gameState: GameState, x1: Int, y1: Int, x2: Int, y2: Int) -> Int {
        let cx1 = x1
        let cz1 = y1 - (x1 - (x1 & 1)) / 2
        let cy1 = -cx1 - cz1
        let cx2 = x2
        let cz2 = y2 - (x2 - (x2 & 1)) / 2
        let cy2 = -cx2 - cz2
        return max(abs(cx1 - cx2), abs(cy1 - cy2), abs(cz1 - cz2))
    }

    static func tileWalkable(gameState: GameState, x: Int, y: Int, excluding enemyId: UUID) -> Bool {
        let h = gameState.currentMissionTiles.isEmpty ? 14 : gameState.currentMissionTiles.count
        guard x >= 0, x < TileMap.mapWidth, y >= 0, y < h else { return false }
        let playerBlocking = gameState.playerTeam.contains { $0.isAlive && $0.positionX == x && $0.positionY == y }
        if playerBlocking { return false }
        let enemyBlocking = gameState.enemies.contains { $0.isAlive && $0.id != enemyId && $0.positionX == x && $0.positionY == y }
        if enemyBlocking { return false }
        guard !gameState.currentMissionTiles.isEmpty, y < gameState.currentMissionTiles.count, x < gameState.currentMissionTiles[y].count else { return true }
        let tileType = gameState.currentMissionTiles[y][x]
        return tileType != 1
    }

    static func tileWalkableForHealer(gameState: GameState, x: Int, y: Int, excluding enemyId: UUID) -> Bool {
        let h = gameState.currentMissionTiles.isEmpty ? 14 : gameState.currentMissionTiles.count
        guard x >= 0, x < TileMap.mapWidth, y >= 0, y < h else { return false }
        let playerBlocking = gameState.playerTeam.contains { $0.isAlive && $0.positionX == x && $0.positionY == y }
        if playerBlocking { return false }
        guard !gameState.currentMissionTiles.isEmpty, y < gameState.currentMissionTiles.count, x < gameState.currentMissionTiles[y].count else { return true }
        let tileType = gameState.currentMissionTiles[y][x]
        return tileType != 1
    }

    static func isLineBlockedByWall(gameState: GameState, fromX sx: Int, fromY sy: Int, toX dx: Int, toY dy: Int) -> Bool {
        var x0 = sx, y0 = sy
        let x1 = dx, y1 = dy

        let dx = abs(x1 - x0)
        let dy = abs(y1 - y0)
        let sx_ = x0 < x1 ? 1 : -1
        let sy_ = y0 < y1 ? 1 : -1
        var err = dx - dy

        while true {
            if !(x0 == sx && y0 == sy) && !(x0 == x1 && y0 == y1) {
                guard x0 >= 0, x0 < TileMap.mapWidth, y0 >= 0 else { break }
                let h = gameState.currentMissionTiles.isEmpty ? 14 : gameState.currentMissionTiles.count
                guard y0 < h, x0 < gameState.currentMissionTiles[y0].count else { break }
                let tileType = gameState.currentMissionTiles[y0][x0]
                if tileType == 1 {
                    return true
                }
            }

            if x0 == x1 && y0 == y1 { break }
            let e2 = 2 * err
            if e2 > -dy {
                err -= dy
                x0 += sx_
            }
            if e2 < dx {
                err += dx
                y0 += sy_
            }
        }
        return false
    }

    static func bfsPathfind(gameState: GameState, from enemy: Enemy, toward target: Character) -> (Int, Int)? {
        let sx = enemy.positionX, sy = enemy.positionY
        let gx = target.positionX, gy = target.positionY
        if hexAdjacent(gameState: gameState, x1: sx, y1: sy, x2: gx, y2: gy) { return nil }

        struct Node { let x: Int; let y: Int }
        var queue: [Node] = [Node(x: sx, y: sy)]
        var visited: Set<String> = ["\(sx),\(sy)"]
        var i = 0

        while i < queue.count {
            let cur = queue[i]; i += 1
            for (nx, ny) in hexNeighbors(gameState: gameState, x: cur.x, y: cur.y) {
                let k = "\(nx),\(ny)"
                guard !visited.contains(k), tileWalkable(gameState: gameState, x: nx, y: ny, excluding: enemy.id) else { continue }
                visited.insert(k)
                if hexAdjacent(gameState: gameState, x1: nx, y1: ny, x2: gx, y2: gy) || (nx == gx && ny == gy) { return (nx, ny) }
                queue.append(Node(x: nx, y: ny))
            }
        }
        let neighbors = hexNeighbors(gameState: gameState, x: sx, y: sy)
        let sorted = neighbors.filter { tileWalkable(gameState: gameState, x: $0.0, y: $0.1, excluding: enemy.id) }
            .sorted { hexDistance(gameState: gameState, x1: $0.0, y1: $0.1, x2: gx, y2: gy) < hexDistance(gameState: gameState, x1: $1.0, y1: $1.1, x2: gx, y2: gy) }
        return sorted.first
    }

    static func bfsPathfindDrone(gameState: GameState, from enemy: Enemy, towardX gx: Int, y gy: Int) -> (Int, Int)? {
        let sx = enemy.positionX, sy = enemy.positionY
        if hexAdjacent(gameState: gameState, x1: sx, y1: sy, x2: gx, y2: gy) { return nil }

        struct Node { let x: Int; let y: Int }
        var queue: [Node] = [Node(x: sx, y: sy)]
        var visited: Set<String> = ["\(sx),\(sy)"]
        var i = 0

        while i < queue.count {
            let cur = queue[i]; i += 1
            for (nx, ny) in hexNeighbors(gameState: gameState, x: cur.x, y: cur.y) {
                let k = "\(nx),\(ny)"
                guard !visited.contains(k), tileWalkable(gameState: gameState, x: nx, y: ny, excluding: enemy.id) else { continue }
                visited.insert(k)
                if hexAdjacent(gameState: gameState, x1: nx, y1: ny, x2: gx, y2: gy) || (nx == gx && ny == gy) { return (nx, ny) }
                queue.append(Node(x: nx, y: ny))
            }
        }
        let neighbors = hexNeighbors(gameState: gameState, x: sx, y: sy)
        let sorted = neighbors.filter { tileWalkable(gameState: gameState, x: $0.0, y: $0.1, excluding: enemy.id) }
            .sorted { hexDistance(gameState: gameState, x1: $0.0, y1: $0.1, x2: gx, y2: gy) < hexDistance(gameState: gameState, x1: $1.0, y1: $1.1, x2: gx, y2: gy) }
        return sorted.first
    }

    static func bfsPathfindToWounded(gameState: GameState, from enemy: Enemy, toward target: Enemy) -> (Int, Int)? {
        let sx = enemy.positionX, sy = enemy.positionY
        let gx = target.positionX, gy = target.positionY
        if hexAdjacent(gameState: gameState, x1: sx, y1: sy, x2: gx, y2: gy) { return nil }

        struct Node { let x: Int; let y: Int }
        var queue: [Node] = [Node(x: sx, y: sy)]
        var visited: Set<String> = ["\(sx),\(sy)"]
        var i = 0

        while i < queue.count {
            let cur = queue[i]; i += 1
            for (nx, ny) in hexNeighbors(gameState: gameState, x: cur.x, y: cur.y) {
                let k = "\(nx),\(ny)"
                guard !visited.contains(k), tileWalkableForHealer(gameState: gameState, x: nx, y: ny, excluding: enemy.id) else { continue }
                visited.insert(k)
                if hexAdjacent(gameState: gameState, x1: nx, y1: ny, x2: gx, y2: gy) || (nx == gx && ny == gy) { return (nx, ny) }
                queue.append(Node(x: nx, y: ny))
            }
        }
        let neighbors = hexNeighbors(gameState: gameState, x: sx, y: sy)
        let sorted = neighbors.filter { tileWalkableForHealer(gameState: gameState, x: $0.0, y: $0.1, excluding: enemy.id) }
            .sorted { hexDistance(gameState: gameState, x1: $0.0, y1: $0.1, x2: gx, y2: gy) < hexDistance(gameState: gameState, x1: $1.0, y1: $1.1, x2: gx, y2: gy) }
        return sorted.first
    }

    static func bestRetreatTile(gameState: GameState, for enemy: Enemy, awayFrom target: Character) -> (Int, Int) {
        var candidates: [(Int, Int, Int)] = []

        for (nx, ny) in hexNeighbors(gameState: gameState, x: enemy.positionX, y: enemy.positionY) {
            if tileWalkable(gameState: gameState, x: nx, y: ny, excluding: enemy.id) {
                let newDist = hexDistance(gameState: gameState, x1: nx, y1: ny, x2: target.positionX, y2: target.positionY)
                candidates.append((nx, ny, newDist))
            }
        }

        if let best = candidates.max(by: { $0.2 < $1.2 }) {
            return (best.0, best.1)
        }
        return (enemy.positionX, enemy.positionY)
    }

    static func findWoundedAlly(gameState: GameState, for enemy: Enemy) -> Enemy? {
        let wounded = gameState.enemies.filter { ally in
            guard ally.id != enemy.id, ally.isAlive else { return false }
            let dist = hexDistance(gameState: gameState, x1: ally.positionX, y1: ally.positionY, x2: enemy.positionX, y2: enemy.positionY)
            let isWounded = Double(ally.currentHP) / Double(ally.maxHP) < 0.75
            return dist <= 5 && isWounded
        }
        return wounded.min { a, b in
            Double(a.currentHP) / Double(a.maxHP) < Double(b.currentHP) / Double(b.maxHP)
        }
    }

    static func distanceToNearestPlayer(gameState: GameState, x: Int, y: Int) -> Int {
        let living = gameState.playerTeam.filter { $0.isAlive }
        guard !living.isEmpty else { return Int.max }
        var best = Int.max
        for player in living {
            let distance = abs(player.positionX - x) + abs(player.positionY - y)
            if distance < best {
                best = distance
            }
        }
        return best
    }

    static func findNextLivingCharacter(gameState: GameState, after index: Int) -> Character? {
        for i in index..<gameState.playerTeam.count {
            if gameState.playerTeam[i].isAlive { return gameState.playerTeam[i] }
        }
        for i in 0..<index {
            if gameState.playerTeam[i].isAlive { return gameState.playerTeam[i] }
        }
        return nil
    }
}

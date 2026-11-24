import Foundation

// KaPlay's arcade (owner's call, 2026-11-23): Snake and 2048, native to K. Every game is seeded and
// deterministic, so a finished game's stamp (its seed and its moves, `ArcadeStamp`) replays to the
// same score anywhere: the indexer checks a score by playing it again (ARCADE.md). Nothing here
// knows about time or the screen: the views drive these engines and draw them.

/// The arcade's games.
enum ArcadeGame: String, CaseIterable, Identifiable, Codable {
    case snake
    case g2048 = "2048"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .snake: return "Snake"
        case .g2048: return "2048"
        }
    }

    /// One line on its KaPlay card.
    var detail: String {
        switch self {
        case .snake: return "Eat, grow, don't hit the walls or yourself. Scores go on Kaspa."
        case .g2048: return "Swipe to merge tiles and reach 2048. Scores go on Kaspa."
        }
    }

    var systemImage: String {
        switch self {
        case .snake: return "scribble.variable"
        case .g2048: return "square.grid.2x2.fill"
        }
    }
}

/// SplitMix64: the arcade's only source of chance. The same seed gives the same game, on any
/// device and in the indexer (ARCADE.md §2).
struct ArcadeRandom {
    private(set) var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0 ..< n (n > 0), as `next() % n`.
    mutating func below(_ n: Int) -> Int {
        Int(next() % UInt64(n))
    }

    /// A fresh seed for a new game.
    static func newSeed() -> UInt64 {
        var generator = SystemRandomNumberGenerator()
        return generator.next()
    }

    static func hex(_ seed: UInt64) -> String { String(format: "%016llx", seed) }

    static func seed(fromHex text: String) -> UInt64? {
        guard text.count == 16 else { return nil }
        return UInt64(text, radix: 16)
    }
}

enum ArcadeDirection: Character, CaseIterable {
    case up = "U", down = "D", left = "L", right = "R"

    var dx: Int {
        switch self {
        case .left: return -1
        case .right: return 1
        case .up, .down: return 0
        }
    }

    var dy: Int {
        switch self {
        case .up: return -1
        case .down: return 1
        case .left, .right: return 0
        }
    }

    var opposite: ArcadeDirection {
        switch self {
        case .up: return .down
        case .down: return .up
        case .left: return .right
        case .right: return .left
        }
    }
}

// MARK: - Snake (ARCADE.md §3)

/// A 16 by 16 board. The snake starts three long at (6,8), (5,8), (4,8), heading right. Each tick
/// it takes the turn queued for that tick (if any), moves one cell, and either eats the apple
/// (grows by one, score +1, a new apple) or moves its tail along. Hitting a wall or its own body
/// ends the game (the tail cell it is leaving doesn't count, unless it is eating).
struct SnakeEngine {
    static let width = 16
    static let height = 16

    struct Cell: Hashable {
        let x: Int
        let y: Int
    }

    private(set) var body: [Cell] = [Cell(x: 6, y: 8), Cell(x: 5, y: 8), Cell(x: 4, y: 8)]
    private(set) var heading: ArcadeDirection = .right
    private(set) var food: Cell?
    private(set) var score = 0
    private(set) var ticks = 0
    private(set) var isOver = false
    /// The turns taken, as the stamp writes them: "12R 30U" (the tick it was taken on, then the
    /// direction).
    private(set) var turns: [(tick: Int, direction: ArcadeDirection)] = []
    private var random: ArcadeRandom

    init(seed: UInt64) {
        random = ArcadeRandom(seed: seed)
        placeFood()
    }

    var head: Cell { body[0] }

    /// Whether `direction` would be taken now: not the way it is already going, nor straight back.
    func canTurn(_ direction: ArcadeDirection) -> Bool {
        direction != heading && direction != heading.opposite
    }

    /// One step. `turn`, if it can be taken, is taken first and recorded.
    @discardableResult
    mutating func tick(turn: ArcadeDirection? = nil) -> Bool {
        guard !isOver else { return false }
        if let turn, canTurn(turn) {
            heading = turn
            turns.append((ticks, turn))
        }
        ticks += 1
        let next = Cell(x: head.x + heading.dx, y: head.y + heading.dy)
        let eating = next == food
        guard next.x >= 0, next.x < Self.width, next.y >= 0, next.y < Self.height else {
            isOver = true
            return false
        }
        let blocking = eating ? body : Array(body.dropLast())
        if blocking.contains(next) {
            isOver = true
            return false
        }
        body.insert(next, at: 0)
        if eating {
            score += 1
            placeFood()
        } else {
            body.removeLast()
        }
        return true
    }

    /// The apple goes on one of the empty cells, counted row by row from the top left.
    private mutating func placeFood() {
        let taken = Set(body)
        var empty: [Cell] = []
        empty.reserveCapacity(Self.width * Self.height)
        for y in 0..<Self.height {
            for x in 0..<Self.width {
                let cell = Cell(x: x, y: y)
                if !taken.contains(cell) { empty.append(cell) }
            }
        }
        food = empty.isEmpty ? nil : empty[random.below(empty.count)]
        if empty.isEmpty { isOver = true }
    }

    var movesText: String {
        turns.map { "\($0.tick)\($0.direction.rawValue)" }.joined(separator: " ")
    }

    /// Replays a stamp: the score it really reaches, or nil when the moves don't make a game.
    static func replay(seed: UInt64, moves: String) -> (score: Int, ticks: Int)? {
        var turns: [Int: ArcadeDirection] = [:]
        var lastTick = -1
        for token in moves.split(separator: " ") {
            guard let letter = token.last, let direction = ArcadeDirection(rawValue: letter),
                  let tick = Int(token.dropLast()), tick > lastTick else { return nil }
            turns[tick] = direction
            lastTick = tick
        }
        var game = SnakeEngine(seed: seed)
        // a game can't take more ticks than this without its turns making it loop forever
        let limit = 1_000_000
        while !game.isOver, game.ticks < limit {
            let tick = game.ticks
            if let turn = turns[tick] {
                guard game.canTurn(turn) else { return nil }
                game.tick(turn: turn)
            } else {
                game.tick()
            }
        }
        return game.isOver ? (game.score, game.ticks) : nil
    }
}

// MARK: - 2048 (ARCADE.md §4)

/// A 4 by 4 board. Two tiles to start, then one after every move that changes the board: on one
/// of the empty cells (counted row by row from the top left), a 4 one time in ten, else a 2. A move
/// slides every tile as far as it goes and merges equal pairs once each, nearest the wall first;
/// each merge adds the new tile to the score. A move that changes nothing isn't a move. The game
/// is over when no move changes the board.
struct Game2048Engine {
    static let size = 4

    /// Row by row: `tiles[y * 4 + x]`, 0 for empty.
    private(set) var tiles: [Int] = Array(repeating: 0, count: 16)
    private(set) var score = 0
    private(set) var moves = ""
    private(set) var isOver = false
    /// Where the last tile appeared, for the view's pop.
    private(set) var lastSpawn: Int?
    private var random: ArcadeRandom

    init(seed: UInt64) {
        random = ArcadeRandom(seed: seed)
        spawn()
        spawn()
    }

    var bestTile: Int { tiles.max() ?? 0 }

    /// Plays `direction`; false (and nothing recorded) when it changes nothing.
    @discardableResult
    mutating func move(_ direction: ArcadeDirection) -> Bool {
        guard !isOver else { return false }
        var changed = false
        var gained = 0
        for line in 0..<Self.size {
            let indices = Self.lineIndices(line, direction)
            let values = indices.map { tiles[$0] }
            let (merged, points) = Self.slide(values)
            if merged != values {
                changed = true
                for (index, value) in zip(indices, merged) { tiles[index] = value }
            }
            gained += points
        }
        guard changed else { return false }
        score += gained
        moves.append(direction.rawValue)
        spawn()
        if !canMove { isOver = true }
        return true
    }

    var canMove: Bool {
        if tiles.contains(0) { return true }
        for y in 0..<Self.size {
            for x in 0..<Self.size {
                let value = tiles[y * Self.size + x]
                if x + 1 < Self.size, tiles[y * Self.size + x + 1] == value { return true }
                if y + 1 < Self.size, tiles[(y + 1) * Self.size + x] == value { return true }
            }
        }
        return false
    }

    /// The cells of one line, from the wall the tiles move toward. (The view follows each tile
    /// along these to slide it.)
    static func lineIndices(_ line: Int, _ direction: ArcadeDirection) -> [Int] {
        (0..<size).map { step in
            switch direction {
            case .left: return line * size + step
            case .right: return line * size + (size - 1 - step)
            case .up: return step * size + line
            case .down: return (size - 1 - step) * size + line
            }
        }
    }

    /// One line, slid toward its start: equal neighbours merge once each, the first pair first.
    private static func slide(_ values: [Int]) -> ([Int], Int) {
        let tiles = values.filter { $0 != 0 }
        var out: [Int] = []
        var points = 0
        var index = 0
        while index < tiles.count {
            if index + 1 < tiles.count, tiles[index] == tiles[index + 1] {
                let merged = tiles[index] * 2
                out.append(merged)
                points += merged
                index += 2
            } else {
                out.append(tiles[index])
                index += 1
            }
        }
        while out.count < size { out.append(0) }
        return (out, points)
    }

    private mutating func spawn() {
        let empty = tiles.indices.filter { tiles[$0] == 0 }
        guard !empty.isEmpty else { lastSpawn = nil; return }
        let cell = empty[random.below(empty.count)]
        tiles[cell] = random.below(10) == 0 ? 4 : 2
        lastSpawn = cell
    }

    /// Replays a stamp: the score it reaches and whether it ended, or nil when a move changes
    /// nothing (a real game never records one).
    static func replay(seed: UInt64, moves: String) -> (score: Int, isOver: Bool)? {
        var game = Game2048Engine(seed: seed)
        for letter in moves {
            guard let direction = ArcadeDirection(rawValue: letter), game.move(direction) else { return nil }
        }
        return (game.score, game.isOver)
    }
}

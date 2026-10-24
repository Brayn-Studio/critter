import CritterKit

/// The interface icons (Android `PixelIcons`, the mockups' `ICONS`): the marks the pet wears over its head and
/// every icon the phone UI draws (visual design §6). The raw value is the key the rows are known by.
public enum PixelIcon: String, CaseIterable, Sendable {
    case board, sliders, back, close, folder, branch, term, editor, laptop, wifi, bell, battery, send, letter, qr
    case keys, chevR, chevD, chevU, lock, ball, grid, paw, spark, seedling, seed, bud, sprout, dot
    /// The five state symbols (waiting, running, done, error, idle) and the night moon.
    case sun, q, bang, check, z, moon

    /// The symbol a state wears (Android `stateIcon`): the same marks the desktop pet shows over its head.
    public static func forState(_ state: PetState) -> PixelIcon {
        switch state {
        case .waiting: .q
        case .running: .sun
        case .done: .check
        case .error: .bang
        case .idle: .z
        }
    }
}

/// One horizontal run of filled cells: `length` cells from column `x` on row `y`.
public struct PixelRun: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var length: Int

    public init(x: Int, y: Int, length: Int) {
        self.x = x
        self.y = y
        self.length = length
    }
}

/// The icons as pixel rows (`#` filled, `.` empty), all rows of an icon the same length. Drawn in the text
/// colour, 2 pt a cell.
public enum PixelIcons {
    public static func rows(_ icon: PixelIcon) -> [String] {
        switch icon {
        case .board: ["#########", "#.......#", "#.......#", "#.......#", "#########", "...###...", ".#######."]
        case .sliders: ["..#......", "#########", "..#......", ".........", "......#..", "#########", "......#.."]
        case .back: ["...##", "..##.", ".##..", "##...", ".##..", "..##.", "...##"]
        case .close: ["##...##", ".##.##.", "..###..", ".##.##.", "##...##"]
        case .folder: ["####.....", "#########", "#.......#", "#.......#", "#.......#", "#########"]
        case .branch: ["##.....", "##..##.", ".#..##.", ".#..#..", ".#.#...", ".##....", ".#.....", "##.....", "##....."]
        case .term: ["#########", "#.......#", "#.#.....#", "#..#....#", "#.#..##.#", "#.......#", "#########"]
        case .editor: ["#########", "#########", "#.......#", "#.##....#", "#...###.#", "#.......#", "#########"]
        case .laptop: [".#######.", ".#.....#.", ".#.....#.", ".#######.", "#########"]
        case .wifi: ["..#####..", ".#.....#.", "#..###..#", "..#...#..", "....#...."]
        case .bell: ["...#...", "..###..", ".#####.", ".#####.", ".#####.", "#######", ".......", "..###.."]
        case .battery: ["########.", "#.###..##", "#.###..##", "########."]
        case .send: ["...#...", "..###..", ".#####.", "#..#..#", "...#...", "...#...", "...#..."]
        case .letter: ["#########", "##.....##", "#.#...#.#", "#..###..#", "#.......#", "#########"]
        case .qr: ["###.#.###", "#.#...#.#", "###.#.###", ".........", "#.#.#.#.#", ".#.#.#.#.", "###...#.#", "#.#.#.#..", "###.#.###"]
        case .keys: ["#########", "#.#.#.#.#", "#########", "#.#####.#", "#########"]
        case .chevR: ["##..", ".##.", "..##", ".##.", "##.."]
        case .chevD: ["#.....#", "##...##", ".##.##.", "..###.."]
        case .chevU: ["..###..", ".##.##.", "##...##", "#.....#"]
        case .lock: [".#####.", ".#...#.", ".#...#.", "#######", "###.###", "###.###", "#######"]
        case .ball: ["..###..", ".#####.", "#######", "#######", "#######", ".#####.", "..###.."]
        case .grid: ["###.###", "###.###", "###.###", ".......", "###.###", "###.###", "###.###"]
        case .paw: ["..#.#..", ".......", "#.###.#", ".#####.", ".#####.", "..###.."]
        case .spark: ["...#...", "...#...", "..###..", "#######", "..###..", "...#...", "...#..."]
        case .seedling: ["##.....##", "###...###", ".###.###.", "..##.##..", "....#....", "....#....", "..#####..", ".#######."]
        case .seed: ["........", "........", "........", "...##...", "..####..", "########"]
        case .bud: ["...##...", "..####..", "...##...", "...##...", "..####..", "########"]
        case .sprout: ["###..###", ".######.", "...##...", "...##...", "..####..", "########"]
        case .dot: ["##", "##"]
        case .sun: ["...#...", ".......", "..###..", "#.###.#", "..###..", ".......", "...#..."]
        case .q: ["###.", "...#", ".##.", ".#..", "....", ".#.."]
        case .bang: ["##", "##", "##", "..", "##"]
        case .check: ["....#", "...##", "#.##.", "###..", ".#..."]
        case .z: ["#####", "...#.", "..#..", ".#...", "#####"]
        case .moon: ["..###..", ".##....", "##.....", "##.....", "##.....", ".##....", "..###.."]
        }
    }

    /// Each row's horizontal runs of `#`, in reading order, so an icon is drawn with a few rectangles. Every
    /// filled cell is in exactly one run.
    public static func runs(_ rows: [String]) -> [PixelRun] {
        var out: [PixelRun] = []
        for (y, row) in rows.enumerated() {
            let cells = Array(row)
            var x = 0
            while x < cells.count {
                if cells[x] != "#" {
                    x += 1
                    continue
                }
                var end = x
                while end < cells.count && cells[end] == "#" { end += 1 }
                out.append(PixelRun(x: x, y: y, length: end - x))
                x = end
            }
        }
        return out
    }

    public static func runs(_ icon: PixelIcon) -> [PixelRun] {
        runs(rows(icon))
    }
}

/// One cell of the wordmark: ink, or the sprout on the `i` (two leaves over a stem).
public struct WordmarkCell: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case ink, leaf, stem
    }

    public var x: Int
    public var y: Int
    public var kind: Kind

    public init(x: Int, y: Int, kind: Kind) {
        self.x = x
        self.y = y
        self.kind = kind
    }
}

/// "Critter" drawn in pixels, not typed (visual design §6, Android `Wordmark`): the mockups' `LETTERS`, one empty
/// column between letters. In `rows`, `#` is ink, `G` a leaf of the sprout and `g` its stem.
public enum Wordmark {
    public static let width = 42
    public static let height = 9

    private static let letters: [Character: [String]] = [
        "C": [".####.", "##..##", "##....", "##....", "##....", "##....", "##....", "##..##", ".####."],
        "r": [".....", ".....", ".....", "##.##", "#####", "##...", "##...", "##...", "##..."],
        "i": ["G..G", ".gg.", "....", ".##.", ".##.", ".##.", ".##.", ".##.", ".##."],
        "t": [".....", ".##..", ".##..", "#####", ".##..", ".##..", ".##..", ".##..", "..###"],
        "e": ["......", "......", "......", ".####.", "##..##", "######", "##....", "##..##", ".####."],
    ]

    /// The nine rows of the whole word, 42 cells each.
    public static let rows: [String] = (0..<height).map { y in
        "Critter".map { letters[$0]![y] }.joined(separator: ".")
    }

    public static let cells: [WordmarkCell] = rows.enumerated().flatMap { y, row in
        row.enumerated().compactMap { x, ch -> WordmarkCell? in
            switch ch {
            case "#": WordmarkCell(x: x, y: y, kind: .ink)
            case "G": WordmarkCell(x: x, y: y, kind: .leaf)
            case "g": WordmarkCell(x: x, y: y, kind: .stem)
            default: nil
            }
        }
    }
}

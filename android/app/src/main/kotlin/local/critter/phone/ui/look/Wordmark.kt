package local.critter.phone.ui.look

/** One cell of the wordmark: ink, or the sprout on the `i` (two leaves over a stem). */
data class WordmarkCell(val x: Int, val y: Int, val kind: Kind) {
    enum class Kind { Ink, Leaf, Stem }
}

/** "Critter" drawn in pixels, not typed (design §6): the mockups' `LETTERS`, one empty column between letters. */
object Wordmark {
    const val WIDTH = 42
    const val HEIGHT = 9

    private val LETTERS = mapOf(
        'C' to listOf(".####.", "##..##", "##....", "##....", "##....", "##....", "##....", "##..##", ".####."),
        'r' to listOf(".....", ".....", ".....", "##.##", "#####", "##...", "##...", "##...", "##..."),
        'i' to listOf("G..G", ".gg.", "....", ".##.", ".##.", ".##.", ".##.", ".##.", ".##."),
        't' to listOf(".....", ".##..", ".##..", "#####", ".##..", ".##..", ".##..", ".##..", "..###"),
        'e' to listOf("......", "......", "......", ".####.", "##..##", "######", "##....", "##..##", ".####."),
    )

    private val CELLS: List<WordmarkCell> = buildList {
        var x0 = 0
        for (ch in "Critter") {
            val rows = LETTERS.getValue(ch)
            for ((y, row) in rows.withIndex()) {
                for ((x, c) in row.withIndex()) {
                    val kind = when (c) {
                        '#' -> WordmarkCell.Kind.Ink
                        'G' -> WordmarkCell.Kind.Leaf
                        'g' -> WordmarkCell.Kind.Stem
                        else -> continue
                    }
                    add(WordmarkCell(x0 + x, y, kind))
                }
            }
            x0 += rows[0].length + 1
        }
    }

    fun cells(): List<WordmarkCell> = CELLS
}

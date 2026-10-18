package local.critter.phone

import kotlinx.serialization.json.JsonObject
import local.critter.core.protocol.BridgeJson
import local.critter.phone.ui.answer.MdBlock
import local.critter.phone.ui.answer.Span
import local.critter.phone.ui.answer.parseInline
import local.critter.phone.ui.answer.parseMarkdownLite
import local.critter.phone.ui.answer.parseQuestions
import local.critter.phone.ui.answer.permissionBody
import local.critter.phone.ui.answer.planText
import local.critter.phone.ui.answer.submitsOnPick
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AnswerInputTest {
    private fun json(s: String) = BridgeJson.parseToJsonElement(s) as JsonObject

    @Test
    fun permissionBodyPrefersCommandThenFilePathThenUrl() {
        assertEquals("ls", permissionBody(json("""{"command":"ls","file_path":"/a","url":"u"}""")))
        assertEquals("/a", permissionBody(json("""{"file_path":"/a","url":"u"}""")))
        assertEquals("u", permissionBody(json("""{"url":"u"}""")))
        assertNull(permissionBody(json("""{"other":"x"}""")))
        assertNull(permissionBody(null))
    }

    @Test
    fun questionsAreReadWithOptionsAndMultiSelect() {
        val q = parseQuestions(
            json(
                """{"questions":[{"header":"DB","question":"Which database?","multiSelect":false,
                   "options":[{"label":"PostgreSQL","description":"relational"},{"label":"SQLite"}]},
                   {"question":"Which extras?","multiSelect":true,"options":[{"label":"A"}]}]}""",
            ),
        )
        assertEquals(2, q.size)
        assertEquals("Which database?", q[0].question)
        assertEquals(listOf("PostgreSQL", "SQLite"), q[0].options.map { it.label })
        assertEquals("relational", q[0].options[0].description)
        assertTrue(q[1].multiSelect)
        assertFalse(submitsOnPick(q))
        assertTrue(submitsOnPick(q.take(1)))
        assertFalse(submitsOnPick(q.drop(1)))
    }

    @Test
    fun planTextComesFromThePlanKey() {
        assertEquals("# Do it", planText(json("""{"plan":"# Do it"}""")))
        assertEquals("", planText(null))
    }

    @Test
    fun markdownBlocks() {
        val blocks = parseMarkdownLite(
            "# Title\n\n## Sub\nplain **bold** and `code`\n- one\n1. first\n```\nrm -rf x\n```\n#### not a heading",
        )
        assertEquals(
            listOf(
                MdBlock.Heading(1, listOf(Span("Title"))),
                MdBlock.Heading(2, listOf(Span("Sub"))),
                MdBlock.Paragraph(listOf(Span("plain "), Span("bold", bold = true), Span(" and "), Span("code", code = true))),
                MdBlock.Bullet(listOf(Span("one"))),
                MdBlock.Numbered(1, listOf(Span("first"))),
                MdBlock.CodeBlock("rm -rf x"),
                MdBlock.Paragraph(listOf(Span("#### not a heading"))),
            ),
            blocks,
        )
    }

    @Test
    fun unmatchedMarkersStayPlainText() {
        assertEquals(listOf(Span("a **b")), parseInline("a **b"))
        assertEquals(listOf(Span("a `b")), parseInline("a `b"))
    }

    @Test
    fun unclosedCodeFenceStillShowsItsText() {
        assertEquals(listOf(MdBlock.CodeBlock("x\ny")), parseMarkdownLite("```\nx\ny"))
    }
}

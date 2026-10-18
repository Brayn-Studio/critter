package local.critter.phone.ui.answer

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp

// Just enough Markdown for a plan: #/##/### headings, "-" and "1." lists, `code`, ``` blocks and **bold**.
// Anything else is shown as plain text.

internal data class Span(val text: String, val bold: Boolean = false, val code: Boolean = false)

internal sealed interface MdBlock {
    data class Heading(val level: Int, val spans: List<Span>) : MdBlock
    data class Bullet(val spans: List<Span>) : MdBlock
    data class Numbered(val number: Int, val spans: List<Span>) : MdBlock
    data class CodeBlock(val text: String) : MdBlock
    data class Paragraph(val spans: List<Span>) : MdBlock
}

private val NUMBERED = Regex("""^(\d+)\.\s+(.*)$""")

internal fun parseMarkdownLite(text: String): List<MdBlock> {
    val blocks = mutableListOf<MdBlock>()
    val code = mutableListOf<String>()
    var inCode = false
    for (raw in text.lines()) {
        if (raw.trimStart().startsWith("```")) {
            if (inCode) blocks += MdBlock.CodeBlock(code.joinToString("\n")).also { code.clear() }
            inCode = !inCode
            continue
        }
        if (inCode) {
            code += raw
            continue
        }
        val line = raw.trim()
        if (line.isEmpty()) continue
        // A number too long for an Int ("12345678901. …") is just a paragraph, not a crash.
        val numbered = NUMBERED.matchEntire(line)?.takeIf { it.groupValues[1].toIntOrNull() != null }
        blocks += when {
            line.startsWith("### ") -> MdBlock.Heading(3, parseInline(line.drop(4)))
            line.startsWith("## ") -> MdBlock.Heading(2, parseInline(line.drop(3)))
            line.startsWith("# ") -> MdBlock.Heading(1, parseInline(line.drop(2)))
            line.startsWith("- ") -> MdBlock.Bullet(parseInline(line.drop(2)))
            numbered != null -> MdBlock.Numbered(numbered.groupValues[1].toIntOrNull() ?: 0, parseInline(numbered.groupValues[2]))
            else -> MdBlock.Paragraph(parseInline(line))
        }
    }
    if (inCode) blocks += MdBlock.CodeBlock(code.joinToString("\n")) // an unclosed fence still shows its text
    return blocks
}

/** `**bold**` and `` `code` ``; an unmatched marker stays as plain text. */
internal fun parseInline(s: String): List<Span> {
    val spans = mutableListOf<Span>()
    val plain = StringBuilder()
    fun flush() {
        if (plain.isNotEmpty()) spans += Span(plain.toString()).also { plain.clear() }
    }
    var i = 0
    while (i < s.length) {
        when {
            s.startsWith("**", i) -> {
                val end = s.indexOf("**", i + 2)
                if (end > i + 2) {
                    flush()
                    spans += Span(s.substring(i + 2, end), bold = true)
                    i = end + 2
                } else {
                    plain.append("**")
                    i += 2
                }
            }

            s[i] == '`' -> {
                val end = s.indexOf('`', i + 1)
                if (end > i + 1) {
                    flush()
                    spans += Span(s.substring(i + 1, end), code = true)
                    i = end + 1
                } else {
                    plain.append('`')
                    i++
                }
            }

            else -> {
                plain.append(s[i])
                i++
            }
        }
    }
    flush()
    return spans
}

@Composable
fun MarkdownLite(text: String, modifier: Modifier = Modifier) {
    val blocks = remember(text) { parseMarkdownLite(text) }
    val codeBackground = MaterialTheme.colorScheme.surfaceVariant
    Column(modifier) {
        blocks.forEach { block ->
            when (block) {
                is MdBlock.Heading -> Text(
                    styled(block.spans, codeBackground),
                    style = when (block.level) {
                        1 -> MaterialTheme.typography.titleLarge
                        2 -> MaterialTheme.typography.titleMedium
                        else -> MaterialTheme.typography.titleSmall
                    },
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(top = 10.dp, bottom = 2.dp),
                )

                is MdBlock.Bullet -> Row(Modifier.padding(start = 8.dp, top = 2.dp)) {
                    Text("•  ", style = MaterialTheme.typography.bodyMedium)
                    Text(styled(block.spans, codeBackground), style = MaterialTheme.typography.bodyMedium)
                }

                is MdBlock.Numbered -> Row(Modifier.padding(start = 8.dp, top = 2.dp)) {
                    Text("${block.number}.  ", style = MaterialTheme.typography.bodyMedium)
                    Text(styled(block.spans, codeBackground), style = MaterialTheme.typography.bodyMedium)
                }

                is MdBlock.CodeBlock -> Text(
                    block.text,
                    fontFamily = FontFamily.Monospace,
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier
                        .padding(vertical = 6.dp)
                        .fillMaxWidth()
                        .background(codeBackground, RoundedCornerShape(8.dp))
                        .padding(8.dp),
                )

                is MdBlock.Paragraph -> Text(
                    styled(block.spans, codeBackground),
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.padding(top = 4.dp),
                )
            }
        }
    }
}

private fun styled(spans: List<Span>, codeBackground: androidx.compose.ui.graphics.Color): AnnotatedString =
    buildAnnotatedString {
        spans.forEach { span ->
            val style = SpanStyle(
                fontWeight = if (span.bold) FontWeight.Bold else null,
                fontFamily = if (span.code) FontFamily.Monospace else null,
                background = if (span.code) codeBackground else androidx.compose.ui.graphics.Color.Unspecified,
            )
            withStyle(style) { append(span.text) }
        }
    }

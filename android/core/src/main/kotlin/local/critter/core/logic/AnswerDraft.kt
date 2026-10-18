package local.critter.core.logic

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import local.critter.core.protocol.AnswerPayload
import local.critter.core.protocol.BridgePending
import local.critter.core.protocol.PendingKind
import java.util.concurrent.atomic.AtomicBoolean

private const val MAX_ANSWER_LENGTH = 4000

/**
 * How several selected options of a multi-select question are sent as one answer string.
 * Provisional until the end-to-end test confirms what Claude Code expects (docs/critter-bridge-protocol.md,
 * "AskUserQuestion answers"); every call site goes through here so it changes in one place.
 */
fun joinMultiSelect(labels: List<String>): String = labels.joinToString(", ")

/**
 * The answer being composed for one pending [request]. [payload] mirrors the Mac's
 * `AskDecision.validate`: it is null until the draft would be accepted.
 */
class AnswerDraft(val request: BridgePending) {
    private sealed interface Pick {
        data class One(val label: String) : Pick
        data class Many(val labels: LinkedHashSet<String>) : Pick
        data class Text(val text: String) : Pick
    }

    private var decision: String? = null
    private var message: String? = null
    private val picks = LinkedHashMap<String, Pick>()
    private val submitted = AtomicBoolean(false)

    private val questionTexts: List<String> =
        ((request.input?.get("questions") as? JsonArray) ?: JsonArray(emptyList()))
            .mapNotNull { ((it as? JsonObject)?.get("question") as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }

    fun allow() { decision = "allow"; message = null }

    fun deny(message: String?) { decision = "deny"; this.message = message?.trim()?.ifEmpty { null } }

    fun approve() { decision = "approve"; message = null }

    fun revise(message: String) { decision = "revise"; this.message = message.trim() }

    /** Single-select: [label] becomes the whole answer to [question]. */
    fun choose(question: String, label: String) {
        if (question in questionTexts) picks[question] = Pick.One(label)
    }

    /** Multi-select: adds [label] to the selection for [question], or removes it if already there. */
    fun toggle(question: String, label: String) {
        if (question !in questionTexts) return
        val current = picks[question] as? Pick.Many ?: Pick.Many(LinkedHashSet()).also { picks[question] = it }
        if (!current.labels.remove(label)) current.labels.add(label)
        if (current.labels.isEmpty()) picks.remove(question)
    }

    /** "Other": [text] replaces any selection for [question]; blank text clears it. */
    fun freeText(question: String, text: String) {
        if (question !in questionTexts) return
        val trimmed = text.trim()
        if (trimmed.isEmpty()) picks.remove(question) else picks[question] = Pick.Text(trimmed)
    }

    fun payload(): AnswerPayload? = when (request.kind) {
        PendingKind.permission -> when (decision) {
            "allow" -> AnswerPayload(decision = "allow")
            "deny" -> AnswerPayload(decision = "deny", message = message)
            else -> null
        }
        PendingKind.plan -> when (decision) {
            "approve" -> AnswerPayload(decision = "approve")
            "revise" -> message?.takeIf { it.isNotEmpty() }?.let { AnswerPayload(decision = "revise", message = it) }
            else -> null
        }
        PendingKind.question -> questionPayload()
        PendingKind.unknown -> null
    }

    private fun questionPayload(): AnswerPayload? {
        if (questionTexts.isEmpty()) return null
        val answers = LinkedHashMap<String, String>()
        for (q in questionTexts) {
            val text = when (val pick = picks[q]) {
                is Pick.One -> pick.label
                is Pick.Many -> joinMultiSelect(pick.labels.toList())
                is Pick.Text -> pick.text
                null -> return null
            }
            if (text.isBlank() || text.length > MAX_ANSWER_LENGTH) return null
            answers[q] = text
        }
        return AnswerPayload(answers = answers)
    }

    /** True only for the first call, so a notification button and a card cannot both answer. */
    fun markSubmitted(): Boolean = submitted.compareAndSet(false, true)
}

package local.critter.phone.ui.answer

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import local.critter.core.logic.AnswerDraft
import local.critter.core.protocol.BridgePending
import local.critter.core.protocol.BridgeSession
import local.critter.core.protocol.PendingKind
import local.critter.phone.service.Alerts
import local.critter.phone.ui.placeLine
import local.critter.phone.ui.theme.Critter

// --- what a request asks, read from its `input` -------------------------------------------------

internal data class QuestionOption(val label: String, val description: String?)

internal data class Question(
    val header: String?,
    val question: String,
    val options: List<QuestionOption>,
    val multiSelect: Boolean,
)

private fun JsonObject.string(key: String): String? =
    (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

/** The first of `command`, `file_path`, `url` that the request has. */
internal fun permissionBody(input: JsonObject?): String? =
    listOf("command", "file_path", "url").firstNotNullOfOrNull { input?.string(it)?.takeIf(String::isNotBlank) }

internal fun planText(input: JsonObject?): String = input?.string("plan").orEmpty()

internal fun parseQuestions(input: JsonObject?): List<Question> =
    (input?.get("questions") as? JsonArray).orEmpty().mapNotNull { element ->
        val q = element as? JsonObject ?: return@mapNotNull null
        val text = q.string("question") ?: return@mapNotNull null
        val options = (q["options"] as? JsonArray).orEmpty().mapNotNull { o ->
            val obj = o as? JsonObject ?: return@mapNotNull null
            QuestionOption(obj.string("label") ?: return@mapNotNull null, obj.string("description"))
        }
        Question(q.string("header"), text, options, (q["multiSelect"] as? JsonPrimitive)?.booleanOrNull == true)
    }

/** Whether picking an option should send the answer at once: one single-select question and nothing else to fill in. */
internal fun submitsOnPick(questions: List<Question>): Boolean = questions.size == 1 && !questions[0].multiSelect

// --- the sheet ----------------------------------------------------------------------------------

/**
 * The card for one pending request. [draft] collects the choice; [onSubmit] is called when the user commits it.
 * Everything is disabled while [online] is false or [busy] is true.
 */
@Composable
fun AnswerSheet(
    request: BridgePending,
    session: BridgeSession?,
    draft: AnswerDraft,
    online: Boolean,
    busy: Boolean,
    failure: String?,
    onSubmit: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val enabled = online && !busy
    Column(
        modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface, RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp))
            .padding(horizontal = 20.dp, vertical = 12.dp),
    ) {
        Box(
            Modifier.align(Alignment.CenterHorizontally).size(width = 36.dp, height = 4.dp)
                .background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(2.dp)),
        )
        Spacer(Modifier.size(12.dp))
        Text(Alerts.requestTitle(request, session), style = MaterialTheme.typography.titleMedium)
        session?.let {
            Text(
                placeLine(it),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (!online) {
            Text(
                "未连接，连上后才能作答",
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(top = 8.dp),
            )
        }
        Spacer(Modifier.size(12.dp))

        when (request.kind) {
            PendingKind.permission -> PermissionBody(request, draft, enabled, onSubmit)
            PendingKind.question -> QuestionBody(request, draft, enabled, onSubmit)
            PendingKind.plan -> PlanBody(request, draft, enabled, onSubmit)
            PendingKind.unknown -> Text("这个请求要在电脑上处理。", style = MaterialTheme.typography.bodyMedium)
        }

        failure?.let {
            Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(top = 8.dp))
        }
        Text(
            "电脑上也能答，谁先答算谁的",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth().padding(top = 12.dp),
        )
    }
}

@Composable
private fun PermissionBody(request: BridgePending, draft: AnswerDraft, enabled: Boolean, onSubmit: () -> Unit) {
    var writingReason by remember { mutableStateOf(false) }
    var reason by remember { mutableStateOf("") }

    permissionBody(request.input)?.let { body ->
        Text(
            body,
            fontFamily = FontFamily.Monospace,
            style = MaterialTheme.typography.bodySmall,
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = 200.dp)
                .background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(10.dp))
                .padding(10.dp)
                .verticalScroll(rememberScrollState()),
        )
        Spacer(Modifier.size(12.dp))
    }
    if (writingReason) {
        OutlinedTextField(
            value = reason,
            onValueChange = { reason = it },
            label = { Text("拒绝的理由（可不写）") },
            modifier = Modifier.fillMaxWidth(),
            enabled = enabled,
        )
        Spacer(Modifier.size(8.dp))
    } else {
        TextButton(onClick = { writingReason = true }, enabled = enabled) { Text("拒绝并写理由…") }
    }
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        OutlinedButton(
            onClick = { draft.deny(reason); onSubmit() },
            enabled = enabled,
            modifier = Modifier.weight(1f),
        ) { Text("拒绝") }
        Button(
            onClick = { draft.allow(); onSubmit() },
            enabled = enabled,
            modifier = Modifier.weight(1f),
        ) { Text("允许") }
    }
}

@Composable
private fun PlanBody(request: BridgePending, draft: AnswerDraft, enabled: Boolean, onSubmit: () -> Unit) {
    var revising by remember { mutableStateOf(false) }
    var note by remember { mutableStateOf("") }

    Box(Modifier.fillMaxWidth().heightIn(max = 320.dp).verticalScroll(rememberScrollState())) {
        MarkdownLite(planText(request.input))
    }
    Spacer(Modifier.size(12.dp))
    if (revising) {
        OutlinedTextField(
            value = note,
            onValueChange = { note = it },
            label = { Text("想让它怎么改") },
            modifier = Modifier.fillMaxWidth(),
            enabled = enabled,
        )
        Spacer(Modifier.size(8.dp))
    }
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        OutlinedButton(
            onClick = {
                if (!revising) revising = true else { draft.revise(note); onSubmit() }
            },
            enabled = enabled && (!revising || note.isNotBlank()),
            modifier = Modifier.weight(1f),
        ) { Text("让它改") }
        Button(
            onClick = { draft.approve(); onSubmit() },
            enabled = enabled,
            modifier = Modifier.weight(1f),
        ) { Text("批准") }
    }
}

@Composable
private fun QuestionBody(request: BridgePending, draft: AnswerDraft, enabled: Boolean, onSubmit: () -> Unit) {
    val questions = remember(request.requestId) { parseQuestions(request.input) }
    val instant = submitsOnPick(questions)
    val picked = remember(draft) { mutableStateMapOf<String, Set<String>>() }
    val typing = remember(draft) { mutableStateMapOf<String, Boolean>() }
    val typed = remember(draft) { mutableStateMapOf<String, String>() }
    var changes by remember(draft) { mutableIntStateOf(0) }
    val ready = changes >= 0 && draft.payload() != null

    Column(
        Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        questions.forEach { q ->
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                q.header?.let {
                    Text(it, style = MaterialTheme.typography.labelMedium, color = Critter.colors.brand)
                }
                Text(q.question, style = MaterialTheme.typography.titleSmall)
                q.options.forEach { option ->
                    val on = option.label in picked[q.question].orEmpty()
                    val colors = if (on) androidx.compose.material3.ButtonDefaults.buttonColors() else null
                    val click = {
                        typing[q.question] = false
                        if (q.multiSelect) {
                            draft.toggle(q.question, option.label)
                            val now = picked[q.question].orEmpty()
                            picked[q.question] = if (option.label in now) now - option.label else now + option.label
                        } else {
                            draft.choose(q.question, option.label)
                            picked[q.question] = setOf(option.label)
                        }
                        changes++
                        if (instant) onSubmit()
                    }
                    if (colors != null) {
                        Button(onClick = click, enabled = enabled, colors = colors, modifier = Modifier.fillMaxWidth()) {
                            OptionLabel(option)
                        }
                    } else {
                        OutlinedButton(onClick = click, enabled = enabled, modifier = Modifier.fillMaxWidth()) {
                            OptionLabel(option)
                        }
                    }
                }
                if (typing[q.question] == true) {
                    OutlinedTextField(
                        value = typed[q.question].orEmpty(),
                        onValueChange = {
                            typed[q.question] = it
                            draft.freeText(q.question, it)
                            picked[q.question] = emptySet()
                            changes++
                        },
                        label = { Text("自己写一句") },
                        enabled = enabled,
                        modifier = Modifier.fillMaxWidth(),
                    )
                } else {
                    TextButton(onClick = { typing[q.question] = true }, enabled = enabled) { Text("自己写一句…") }
                }
            }
        }
    }
    // A lone single-select question is answered by tapping an option; everything else needs 提交.
    if (!instant || typing.values.any { it }) {
        Spacer(Modifier.size(12.dp))
        Button(onClick = onSubmit, enabled = enabled && ready, modifier = Modifier.fillMaxWidth()) { Text("提交") }
    }
}

@Composable
private fun OptionLabel(option: QuestionOption) {
    Column(Modifier.fillMaxWidth()) {
        Text(option.label, textAlign = TextAlign.Start, modifier = Modifier.fillMaxWidth())
        option.description?.takeIf { it.isNotBlank() }?.let {
            Text(it, style = MaterialTheme.typography.bodySmall, textAlign = TextAlign.Start, modifier = Modifier.fillMaxWidth())
        }
    }
}

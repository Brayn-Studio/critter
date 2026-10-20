package local.critter.phone.ui.answer

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import local.critter.core.logic.AnswerDraft
import local.critter.core.protocol.AnswerPayload
import local.critter.core.protocol.BridgePending
import local.critter.core.protocol.BridgeSession
import local.critter.core.protocol.PendingKind
import local.critter.core.protocol.PetState
import local.critter.core.protocol.ResultReason
import local.critter.core.protocol.ServerMessage
import local.critter.core.skin.SkinManifest
import local.critter.phone.critter.CritterView
import local.critter.phone.service.Alerts
import local.critter.phone.ui.look.PixelSteps3
import local.critter.phone.ui.meadow.PetStage
import local.critter.phone.ui.sheet.SheetHeader
import local.critter.phone.ui.theme.ButtonKind
import local.critter.phone.ui.theme.ButtonSize
import local.critter.phone.ui.theme.Critter
import local.critter.phone.ui.theme.LightCritterColors
import local.critter.phone.ui.theme.Nunito
import local.critter.phone.ui.theme.OptionCard
import local.critter.phone.ui.theme.PixelButton
import local.critter.phone.ui.theme.PixelField
import local.critter.phone.ui.theme.PixelIcon
import local.critter.phone.ui.theme.PixelShape
import local.critter.phone.ui.theme.WriteOwnCard
import local.critter.phone.ui.theme.pixelSurface
import local.critter.phone.ui.theme.rememberReduceMotion

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

// --- what came of an answer ---------------------------------------------------------------------

/** What the Mac's receipt for an answer means for the card. */
sealed interface AnswerOutcome {
    /** The Mac took it. */
    data object Sent : AnswerOutcome

    /** Someone answered first (on the Mac): not an error, the card says so and closes. */
    data object HandledElsewhere : AnswerOutcome

    /**
     * Too late: the request's time ran out and the hook no longer waits for it. As with [HandledElsewhere], the card
     * says so ([message], the Mac's words) and closes: there is nothing to retry.
     */
    data class Expired(val message: String) : AnswerOutcome

    /** It did not get through; the card stays open with [message] over the buttons. */
    data class Failed(val message: String) : AnswerOutcome
}

fun answerOutcome(result: ServerMessage.Result): AnswerOutcome {
    val message = result.message?.takeIf { it.isNotBlank() }
    return when {
        result.ok -> AnswerOutcome.Sent
        result.reason == ResultReason.resolved -> AnswerOutcome.HandledElsewhere
        result.reason == ResultReason.expired -> AnswerOutcome.Expired(message ?: "这个请求已经过期了")
        else -> AnswerOutcome.Failed(message ?: "没有发送出去，再试一次")
    }
}

/** How long the card shows "✓ 已允许" and the cheering Critter before it slides away (design §7). */
const val SUCCESS_HOLD_MS = 900L

/**
 * What the primary button says once the Mac took [payload] ("已允许"); null for a no (a deny, a revise), which
 * gets no success beat: the Critter nods and the card closes.
 */
internal fun successLabel(payload: AnswerPayload): String? = when {
    payload.answers != null -> "已提交"
    payload.decision == "allow" -> "已允许"
    payload.decision == "approve" -> "已批准"
    else -> null
}

// --- the card -----------------------------------------------------------------------------------

/**
 * The card for one pending request (design §8.6), the content of a `SheetScaffold`: the header with the waiting
 * Critter ([onView] hands over its view), what is asked, the buttons, the footer. [draft] collects the choice;
 * [onSubmit] is called when the user commits it. Everything is disabled while [online] is false or [busy] is
 * true. Once the Mac took the answer, [doneLabel] ("已允许") replaces the primary button and the Critter cheers.
 */
@Composable
fun AnswerSheet(
    request: BridgePending,
    session: BridgeSession?,
    manifest: SkinManifest,
    draft: AnswerDraft,
    online: Boolean,
    busy: Boolean,
    failure: String?,
    doneLabel: String?,
    onView: (CritterView) -> Unit,
    onSubmit: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val c = Critter.colors
    val enabled = online && !busy
    Column(
        modifier.fillMaxWidth().padding(start = 18.dp, end = 18.dp, bottom = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        SheetHeader(
            manifest = manifest,
            state = if (doneLabel != null) PetState.done else PetState.waiting,
            activity = session?.activity,
            title = Alerts.requestTitle(request, session),
            session = session,
            onView = onView,
        )
        if (!online) {
            Text("未连接，连上后才能作答", color = c.err, fontFamily = Nunito, fontWeight = FontWeight.W800, fontSize = 13.sp)
        }

        when (request.kind) {
            PendingKind.permission -> PermissionBody(request, draft, enabled, failure, doneLabel, onSubmit)
            PendingKind.question -> QuestionBody(request, draft, enabled, failure, doneLabel, onSubmit)
            PendingKind.plan -> PlanBody(request, draft, enabled, failure, doneLabel, onSubmit)
            PendingKind.unknown -> Text(
                "这个请求要在电脑上处理。", color = c.ink2, fontFamily = Nunito, fontWeight = FontWeight.W600, fontSize = 14.sp,
            )
        }

        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            PixelIcon("laptop", tint = c.ink2)
            Text("电脑上也能答，谁先答算谁的", color = c.ink2, fontFamily = Nunito, fontWeight = FontWeight.W600, fontSize = 11.5.sp)
        }
    }
}

@Composable
private fun ColumnScope.PermissionBody(
    request: BridgePending,
    draft: AnswerDraft,
    enabled: Boolean,
    failure: String?,
    doneLabel: String?,
    onSubmit: () -> Unit,
) {
    var writingReason by remember(request.requestId) { mutableStateOf(false) }
    var reason by remember(request.requestId) { mutableStateOf("") }

    permissionBody(request.input)?.let { CommandSlip(it, Modifier.weight(1f, fill = false)) }
    if (writingReason) {
        PixelField(
            reason, { reason = it }, placeholder = "拒绝的理由（可不写）", modifier = Modifier.fillMaxWidth(),
            enabled = enabled, maxLines = 3, contentDescription = "拒绝的理由",
        )
    } else {
        PixelButton("拒绝并写理由…", { writingReason = true }, kind = ButtonKind.Ghost, enabled = enabled)
    }
    FailureLine(failure)
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        // With a reason the deny button says so, and needs the room: the two share the row evenly then.
        PixelButton(
            if (writingReason) "拒绝并发送理由" else "拒绝",
            onClick = { draft.deny(reason); onSubmit() },
            modifier = Modifier.weight(1f), kind = ButtonKind.Secondary, size = ButtonSize.Large, enabled = enabled,
        )
        PrimaryAnswer("允许", doneLabel, enabled, { draft.allow(); onSubmit() }, Modifier.weight(if (writingReason) 1f else 1.4f))
    }
}

/** The command on a dark slip, as in the terminal: monospace after a `›`, up to eight lines, then it scrolls. */
@Composable
private fun CommandSlip(command: String, modifier: Modifier) {
    val c = Critter.colors
    val maxHeight = with(LocalDensity.current) { (SlipLine * 8).toDp() } + 18.dp
    val text = remember(command, c.termDim) {
        buildAnnotatedString {
            withStyle(SpanStyle(color = c.termDim)) { append("›") }
            append(" ")
            append(command)
        }
    }
    Box(
        modifier
            .fillMaxWidth()
            .heightIn(max = maxHeight)
            .clip(PixelShape(3.dp))
            .background(c.term)
            .verticalScroll(rememberScrollState())
            .padding(start = 10.dp, end = 10.dp, top = 8.dp, bottom = 10.dp),
    ) {
        Text(text, color = c.termInk, fontFamily = FontFamily.Monospace, fontSize = 12.5.sp, lineHeight = SlipLine)
    }
}

private val SlipLine = 19.4.sp

@Composable
private fun ColumnScope.QuestionBody(
    request: BridgePending,
    draft: AnswerDraft,
    enabled: Boolean,
    failure: String?,
    doneLabel: String?,
    onSubmit: () -> Unit,
) {
    val c = Critter.colors
    val questions = remember(request.requestId) { parseQuestions(request.input) }
    val instant = submitsOnPick(questions)
    val picked = remember(draft) { mutableStateMapOf<String, Set<String>>() }
    val typing = remember(draft) { mutableStateMapOf<String, Boolean>() }
    val typed = remember(draft) { mutableStateMapOf<String, String>() }
    var changes by remember(draft) { mutableIntStateOf(0) }
    val ready = changes >= 0 && draft.payload() != null

    Column(
        Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        questions.forEach { q ->
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    q.header?.takeIf { it.isNotBlank() }?.let { TopicChip(it) }
                    Text(
                        q.question, Modifier.weight(1f, fill = false), color = c.ink, fontFamily = Nunito,
                        fontWeight = FontWeight.W900, fontSize = 15.sp, lineHeight = 20.sp,
                    )
                    if (q.multiSelect) {
                        Text("可多选", color = c.ink2, fontFamily = Nunito, fontWeight = FontWeight.W700, fontSize = 11.5.sp)
                    }
                }
                q.options.forEach { option ->
                    OptionCard(
                        title = option.label,
                        description = option.description?.takeIf { it.isNotBlank() },
                        selected = option.label in picked[q.question].orEmpty(),
                        multi = q.multiSelect,
                        onClick = {
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
                        },
                        enabled = enabled,
                    )
                }
                if (typing[q.question] == true) {
                    PixelField(
                        value = typed[q.question].orEmpty(),
                        onValueChange = {
                            typed[q.question] = it
                            draft.freeText(q.question, it)
                            picked[q.question] = emptySet()
                            changes++
                        },
                        placeholder = "自己写一句",
                        modifier = Modifier.fillMaxWidth(),
                        enabled = enabled,
                        maxLines = 3,
                        contentDescription = q.question,
                    )
                } else {
                    WriteOwnCard(
                        "自己写一句…",
                        onClick = { if (enabled) typing[q.question] = true },
                        modifier = Modifier.alpha(if (enabled) 1f else 0.5f),
                    )
                }
            }
        }
    }
    FailureLine(failure)
    // A lone single-select question is answered by tapping an option; everything else needs the button.
    if (doneLabel != null) {
        DoneButton(doneLabel, Modifier.fillMaxWidth())
    } else if (!instant || typing.values.any { it }) {
        PixelButton(
            "提交 ${questions.size} 个回答", onSubmit, Modifier.fillMaxWidth(),
            size = ButtonSize.Large, enabled = enabled && ready,
        )
    }
}

/** A question's topic ("缓存"): a small brand-tinted tag. */
@Composable
private fun TopicChip(text: String) {
    val c = Critter.colors
    Text(
        text,
        Modifier
            .widthIn(max = 120.dp)
            .pixelSurface(c.brandSoft, step = 2.dp, lip = 2.dp, lipColor = c.brand.copy(alpha = 0.18f))
            .padding(start = 7.dp, end = 7.dp, bottom = 2.dp),
        color = c.brand, fontFamily = Nunito, fontWeight = FontWeight.W900, fontSize = 11.5.sp, lineHeight = 20.sp,
        maxLines = 1, overflow = TextOverflow.Ellipsis,
    )
}

@Composable
private fun ColumnScope.PlanBody(
    request: BridgePending,
    draft: AnswerDraft,
    enabled: Boolean,
    failure: String?,
    doneLabel: String?,
    onSubmit: () -> Unit,
) {
    var revising by remember(request.requestId) { mutableStateOf(false) }
    var note by remember(request.requestId) { mutableStateOf("") }

    // Writing a change, the paper gets shorter to make room for the field (and the keyboard).
    PlanPaper(planText(request.input), Modifier.weight(1f, fill = false).heightIn(max = if (revising) 200.dp else 356.dp))
    if (revising) {
        PixelField(
            note, { note = it }, placeholder = "想让它怎么改", modifier = Modifier.fillMaxWidth(),
            enabled = enabled, maxLines = 4, contentDescription = "想让它怎么改",
        )
    }
    FailureLine(failure)
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        PixelButton(
            if (revising) "发回去" else "让它改…",
            onClick = { if (!revising) revising = true else { draft.revise(note); onSubmit() } },
            modifier = Modifier.weight(1f), kind = ButtonKind.Secondary, size = ButtonSize.Large,
            enabled = enabled && (!revising || note.isNotBlank()),
        )
        PrimaryAnswer("批准计划", doneLabel, enabled, { draft.approve(); onSubmit() }, Modifier.weight(1.4f))
    }
}

/** The plan on a recessed sheet of paper that scrolls; its bottom fades out while there is more below. */
@Composable
private fun PlanPaper(plan: String, modifier: Modifier) {
    val c = Critter.colors
    val scroll = rememberScrollState()
    Box(
        modifier
            .fillMaxWidth()
            .pixelSurface(c.surface2, step = 4.dp, lip = 3.dp, lipColor = c.shade, recessed = true)
            .drawWithContent {
                drawContent()
                if (scroll.canScrollForward) {
                    val fade = PaperFade.toPx()
                    val top = size.height - fade
                    drawRect(
                        Brush.verticalGradient(listOf(c.surface2.copy(alpha = 0f), c.surface2), startY = top, endY = size.height),
                        Offset(0f, top), Size(size.width, fade),
                    )
                }
            },
    ) {
        MarkdownLite(
            plan,
            Modifier.fillMaxWidth().verticalScroll(scroll).padding(start = 16.dp, end = 16.dp, top = 14.dp, bottom = 14.dp),
            codeBackground = c.surface,
        )
    }
}

private val PaperFade = 46.dp

/** Why the answer did not get through, in red over the buttons; the card stays open. */
@Composable
private fun FailureLine(failure: String?) {
    failure ?: return
    Text(
        failure, Modifier.semantics { liveRegion = LiveRegionMode.Polite }, color = Critter.colors.err,
        fontFamily = Nunito, fontWeight = FontWeight.W800, fontSize = 13.sp,
    )
}

/** The primary button, or once the answer was taken, the green [doneLabel] in its place. */
@Composable
private fun PrimaryAnswer(text: String, doneLabel: String?, enabled: Boolean, onClick: () -> Unit, modifier: Modifier) {
    if (doneLabel != null) {
        DoneButton(doneLabel, modifier)
    } else {
        PixelButton(text, onClick, modifier, size = ButtonSize.Large, enabled = enabled)
    }
}

/** The done button stands in for a large primary [PixelButton], so it has its size. */
private val DoneSize = ButtonSize.Large

/** Ink on the solid green, the same in both themes (5.7:1 on the light green, 8.1:1 on the dark one). */
private val InkOnDone = LightCritterColors.ink

/**
 * "✓ 已允许": the primary button turns green in three jumps (180 ms, the pet's beat); under reduce motion a
 * 150 ms fade. It takes no more taps.
 */
@Composable
private fun DoneButton(text: String, modifier: Modifier) {
    val c = Critter.colors
    val reduce = rememberReduceMotion()
    val turn = remember { Animatable(0f) }
    LaunchedEffect(Unit) { turn.animateTo(1f, if (reduce) tween(150) else tween(180, easing = PixelSteps3)) }
    val t = turn.value
    val fg = lerp(c.onBrand, InkOnDone, t)
    Row(
        modifier
            .height(DoneSize.height)
            .pixelSurface(lerp(c.brand, c.doneGlyph, t), step = 3.dp, lip = DoneSize.lip, lipColor = lerp(c.brandDeep, c.done, t), highlight = c.highlight)
            .padding(start = DoneSize.padding, end = DoneSize.padding, bottom = DoneSize.lip)
            .semantics { liveRegion = LiveRegionMode.Polite },
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        PixelIcon("check", tint = fg)
        Text(
            text, color = fg, fontFamily = Nunito, fontWeight = FontWeight.W900, fontSize = DoneSize.fontSize, letterSpacing = 0.02.em,
            maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
    }
}

/**
 * Someone answered on the Mac first: not an error, so the Critter is in bloom (done) and the words are plain.
 * [name] is the session's, when it was seen; [onOk] closes the card (it also closes by itself).
 */
@Composable
internal fun HandledElsewhereCard(name: String?, manifest: SkinManifest, onOk: () -> Unit, expired: String? = null) {
    val c = Critter.colors
    Column(
        Modifier.fillMaxWidth().padding(start = 18.dp, end = 18.dp, bottom = 16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        PetStage(
            manifest, PetState.done, activity = null,
            Modifier.fillMaxWidth().height(150.dp).clip(PixelShape(5.dp)), cell = 5.dp, groundInset = 24.dp,
        )
        Text(
            if (expired != null) "已经过期了" else "已在电脑上处理", Modifier.padding(top = 4.dp), color = c.ink,
            fontFamily = Nunito, fontWeight = FontWeight.W900, fontSize = 19.sp,
        )
        Text(
            when {
                expired != null -> expired
                name != null -> "$name 的这个请求已经在电脑上处理了。"
                else -> "这个请求已经在电脑上处理了。"
            },
            color = c.ink2, fontFamily = Nunito, fontWeight = FontWeight.W600, fontSize = 13.5.sp, textAlign = TextAlign.Center,
        )
        PixelButton("好的", onOk, Modifier.padding(top = 6.dp).width(140.dp), kind = ButtonKind.Secondary)
    }
}

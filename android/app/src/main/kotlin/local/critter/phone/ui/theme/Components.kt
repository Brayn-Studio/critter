package local.critter.phone.ui.theme

import android.content.ContentResolver
import android.provider.Settings
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.LifecycleResumeEffect
import kotlinx.coroutines.delay
import local.critter.core.protocol.PetState
import local.critter.phone.critter.MotionPrefs
import local.critter.phone.ui.look.MeterLevel
import local.critter.phone.ui.look.PixelSteps3
import local.critter.phone.ui.look.litSegments
import local.critter.phone.ui.look.meterLevel
import local.critter.phone.ui.stateIcon
import local.critter.phone.ui.stateLabel
import kotlin.math.roundToInt

// The pixel widgets (the mockups' "部件" section). Small widgets move on the pet's 60 ms beat; presses don't tween.

/** The darker bottom row of a lit meter cell. */
private val LitCellLip = Color.Black.copy(alpha = 0.14f)

/** The switch knob's bottom row while on, the same ink tint in both themes. */
private val KnobLipOn = LightCritterColors.ink.copy(alpha = 0.22f)

enum class ButtonKind { Primary, Secondary, Warning, Ghost }

enum class ButtonSize(internal val height: Dp, internal val lip: Dp, internal val fontSize: TextUnit, internal val padding: Dp) {
    Small(34.dp, 3.dp, 13.5.sp, 12.dp),
    Regular(44.dp, 4.dp, 15.sp, 16.dp),
    Large(52.dp, 4.dp, 16.sp, 16.dp),
}

/** A pixel button: pressed, it sinks 3 dp and its bottom row shrinks to 1 dp, in one step. */
@Composable
fun PixelButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    kind: ButtonKind = ButtonKind.Primary,
    size: ButtonSize = ButtonSize.Regular,
    enabled: Boolean = true,
    icon: String? = null,
) {
    val c = Critter.colors
    val source = remember { MutableInteractionSource() }
    val down = source.collectIsPressedAsState().value && enabled
    val ghost = kind == ButtonKind.Ghost
    val fg: Color
    val face: Color
    val lipColor: Color
    var shine: Color? = null
    when {
        !enabled -> { fg = c.ink3; face = c.surface2; lipColor = c.line }
        kind == ButtonKind.Primary -> { fg = c.onBrand; face = c.brand; lipColor = c.brandDeep; shine = c.highlight }
        kind == ButtonKind.Warning -> { fg = c.state(PetState.waiting).fg; face = c.wait; lipColor = c.waitDeep; shine = c.highlight }
        ghost -> { fg = c.brand; face = Color.Transparent; lipColor = Color.Transparent }
        else -> { fg = c.ink; face = c.surface2; lipColor = c.shade }
    }
    Row(
        modifier
            .height(size.height)
            .graphicsLayer { translationY = if (down) 3.dp.toPx() else 0f }
            .then(
                if (ghost) Modifier
                else Modifier.pixelSurface(face, step = 3.dp, lip = if (down) 1.dp else size.lip, lipColor = lipColor, highlight = shine),
            )
            .clickable(source, indication = null, enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(start = if (ghost) 4.dp else size.padding, end = if (ghost) 4.dp else size.padding, bottom = if (ghost) 0.dp else size.lip),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) PixelIcon(icon, tint = fg)
        Text(
            text, color = fg, fontFamily = Nunito, fontWeight = FontWeight.W900,
            fontSize = if (ghost) 14.sp else size.fontSize, letterSpacing = 0.02.em,
            maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
    }
}

/** A state's label with its icon; when the state changes it hops up 3 dp for one tick (60 ms). */
@Composable
fun StateChip(state: PetState, text: String = stateLabel(state), modifier: Modifier = Modifier) {
    val c = Critter.colors
    val colors = c.state(state)
    val reduce = rememberReduceMotion()
    var shown by remember { mutableStateOf(state) }
    var lifted by remember { mutableStateOf(false) }
    LaunchedEffect(state) {
        if (state == shown) return@LaunchedEffect
        shown = state
        if (reduce) return@LaunchedEffect
        lifted = true
        delay(TICK_MS)
        lifted = false
    }
    Row(
        modifier
            .graphicsLayer { translationY = if (lifted) -3.dp.toPx() else 0f }
            .pixelSurface(
                colors.bg, step = 2.dp, lip = 2.dp,
                lipColor = if (state == PetState.waiting) c.waitDeep else colors.fg.copy(alpha = 0.18f),
            )
            .heightIn(min = 22.dp)
            .padding(start = 7.dp, end = 7.dp, bottom = 2.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        PixelIcon(stateIcon(state), tint = colors.fg)
        Text(
            text, color = colors.fg, fontFamily = Nunito, fontWeight = FontWeight.W900, fontSize = 11.5.sp,
            lineHeight = 20.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
    }
}

/** A 46×28 recessed track with a 20 dp knob that crosses in three jumps (180 ms). */
@Composable
fun PixelSwitch(checked: Boolean, onCheckedChange: (Boolean) -> Unit, contentDescription: String, modifier: Modifier = Modifier) {
    val c = Critter.colors
    val reduce = rememberReduceMotion()
    val knobX = animateDpAsState(
        if (checked) 18.dp else 0.dp,
        if (reduce) snap() else tween(180, easing = PixelSteps3),
        label = "knob",
    )
    Box(
        modifier
            .size(46.dp, 28.dp)
            .pixelSurface(
                if (checked) c.brand else c.surface2, step = 3.dp, lip = 3.dp,
                lipColor = if (checked) c.brandDeep else c.shade, recessed = true,
            )
            .toggleable(checked, interactionSource = null, indication = null, role = Role.Switch, onValueChange = onCheckedChange)
            .semantics { this.contentDescription = contentDescription },
    ) {
        Box(
            Modifier
                .offset { IntOffset((4.dp + knobX.value).roundToPx(), 4.dp.roundToPx()) }
                .size(20.dp)
                .pixelSurface(c.knob, step = 2.dp, lip = 3.dp, lipColor = if (checked) KnobLipOn else c.shade),
        )
    }
}

/** A recessed row of choices; the chosen one stands up out of it. */
@Composable
fun PixelSegmented(options: List<String>, selected: Int, onSelect: (Int) -> Unit, modifier: Modifier = Modifier) {
    val c = Critter.colors
    Row(
        modifier
            .pixelSurface(c.surface2, step = 3.dp, lip = 2.dp, lipColor = c.shade, recessed = true)
            .padding(3.dp)
            .selectableGroup(),
        horizontalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        options.forEachIndexed { i, label ->
            val on = i == selected
            Box(
                Modifier
                    .weight(1f)
                    .heightIn(min = 32.dp)
                    .then(if (on) Modifier.pixelSurface(c.surface, step = 2.dp, lip = 3.dp, lipColor = c.shade) else Modifier)
                    .selectable(on, interactionSource = null, indication = null, role = Role.Tab, onClick = { onSelect(i) })
                    .padding(horizontal = 10.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    label, color = if (on) c.ink else c.ink2, fontFamily = Nunito, fontWeight = FontWeight.W800,
                    fontSize = 13.5.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

/** Whole-pixel cells across the width, [gapPx] apart: `cell(index, left, width)` for each. */
private inline fun DrawScope.forEachSegment(count: Int, gapPx: Float, cell: (Int, Float, Float) -> Unit) {
    val span = size.width + gapPx
    for (i in 0 until count) {
        val left = (i * span / count).roundToInt().toFloat()
        val right = ((i + 1) * span / count).roundToInt() - gapPx
        cell(i, left, right - left)
    }
}

/** A slider in [segments] cells; the value snaps to them. Drag or tap; the thumb wears the sun. */
@Composable
fun PixelSlider(
    value: Float,
    onValueChange: (Float) -> Unit,
    range: ClosedFloatingPointRange<Float>,
    segments: Int = 10,
    modifier: Modifier = Modifier,
) {
    val c = Critter.colors
    val span = range.endInclusive - range.start
    val lit = if (span <= 0f) 0 else ((value - range.start) / span * segments).roundToInt().coerceIn(0, segments)
    val change by rememberUpdatedState(onValueChange)
    val current by rememberUpdatedState(lit)
    fun pick(k: Int) {
        val snapped = k.coerceIn(0, segments)
        if (snapped != current) change(range.start + span * snapped / segments)
    }
    BoxWithConstraints(
        modifier
            .fillMaxWidth()
            .height(28.dp)
            .semantics {
                progressBarRangeInfo = ProgressBarRangeInfo(value, range, steps = segments - 1)
                setProgress { target ->
                    pick(if (span <= 0f) 0 else ((target - range.start) / span * segments).roundToInt())
                    true
                }
            }
            .pointerInput(segments, range) {
                detectTapGestures { pick((it.x / size.width * segments).roundToInt()) }
            }
            .pointerInput(segments, range) {
                detectHorizontalDragGestures(onDragStart = { pick((it.x / size.width * segments).roundToInt()) }) { change, _ ->
                    pick((change.position.x / size.width * segments).roundToInt())
                }
            },
    ) {
        val width = maxWidth
        Canvas(Modifier.fillMaxWidth().height(10.dp).align(Alignment.Center)) {
            val lip = wholePx(2.dp)
            forEachSegment(segments, wholePx(2.dp)) { i, left, w ->
                if (i < lit) {
                    drawRect(c.brand, Offset(left, 0f), Size(w, size.height))
                    drawRect(c.brandDeep, Offset(left, size.height - lip), Size(w, lip))
                } else {
                    drawRect(c.surface2, Offset(left, 0f), Size(w, size.height))
                    drawRect(c.shade, Offset(left, 0f), Size(w, lip))
                }
            }
        }
        val thumbX = (width * lit / segments - 12.dp).coerceIn(0.dp, width - 24.dp)
        Box(
            Modifier
                .offset { IntOffset(thumbX.roundToPx(), 2.dp.roundToPx()) }
                .size(24.dp)
                .pixelSurface(c.surface, step = 3.dp, lip = 3.dp, lipColor = c.shade, border = c.brand, borderWidth = 2.dp),
            contentAlignment = Alignment.Center,
        ) { PixelIcon("sun", tint = c.runGlyph) }
    }
}

/** A meter in [segments] cells: green, amber or red by [level]; the brand color when [level] is null. */
@Composable
fun SegmentMeter(
    percent: Double?,
    segments: Int,
    modifier: Modifier = Modifier,
    height: Dp = 8.dp,
    level: MeterLevel? = meterLevel(percent),
) {
    val c = Critter.colors
    val on = when (level) {
        MeterLevel.Calm -> c.doneGlyph
        MeterLevel.Busy -> c.runGlyph
        MeterLevel.Hot -> c.errGlyph
        null -> c.brand
    }
    val lit = litSegments(percent, segments)
    Canvas(
        modifier
            .fillMaxWidth()
            .height(height)
            .semantics { progressBarRangeInfo = ProgressBarRangeInfo(((percent ?: 0.0) / 100).toFloat().coerceIn(0f, 1f), 0f..1f) },
    ) {
        val litLip = wholePx(2.dp)
        val offLip = wholePx(1.dp)
        forEachSegment(segments, wholePx(2.dp)) { i, left, w ->
            val isLit = i < lit
            val lip = if (isLit) litLip else offLip
            drawRect(if (isLit) on else c.surface2, Offset(left, 0f), Size(w, size.height))
            drawRect(if (isLit) LitCellLip else c.line, Offset(left, size.height - lip), Size(w, lip))
        }
    }
}

/** A recessed text field (the well's dark row on top); focused, it gets a brand-colored edge. */
@Composable
fun PixelField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    minLines: Int = 1,
    maxLines: Int = 5,
) {
    val c = Critter.colors
    val source = remember { MutableInteractionSource() }
    val focused by source.collectIsFocusedAsState()
    val style = TextStyle(color = if (enabled) c.ink else c.ink3, fontFamily = Nunito, fontWeight = FontWeight.W600, fontSize = 14.5.sp)
    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier,
        enabled = enabled,
        textStyle = style,
        minLines = minLines,
        maxLines = maxLines,
        interactionSource = source,
        cursorBrush = SolidColor(c.brand),
        decorationBox = { inner ->
            Box(
                Modifier
                    .fillMaxWidth()
                    .heightIn(min = 44.dp)
                    .pixelSurface(
                        c.surface2, step = 3.dp, lip = 3.dp, lipColor = c.shade, recessed = true,
                        border = if (focused && enabled) c.brand else null, borderWidth = 2.dp,
                    )
                    .padding(start = 12.dp, end = 12.dp, top = 11.dp, bottom = 9.dp),
            ) {
                if (value.isEmpty()) Text(placeholder, style = style.copy(color = c.ink3))
                inner()
            }
        },
    )
}

/** One answer to a question: a round marker for one choice, a square one with a check for several. */
@Composable
fun OptionCard(
    title: String,
    description: String?,
    selected: Boolean,
    multi: Boolean,
    onClick: () -> Unit,
    enabled: Boolean = true,
    modifier: Modifier = Modifier,
) {
    val c = Critter.colors
    val pick = if (multi) {
        Modifier.toggleable(selected, interactionSource = null, indication = null, enabled = enabled, role = Role.Checkbox) { onClick() }
    } else {
        Modifier.selectable(selected, interactionSource = null, indication = null, enabled = enabled, role = Role.RadioButton, onClick = onClick)
    }
    Box(
        modifier
            .fillMaxWidth()
            .alpha(if (enabled) 1f else 0.5f)
            .pixelSurface(
                if (selected) c.brandSoft else c.surface, step = 3.dp, lip = 3.dp,
                lipColor = if (selected) c.brand.copy(alpha = 0.3f) else c.shade,
                border = if (selected) c.brand else c.line, borderWidth = 2.dp,
            )
            .then(pick),
    ) {
        OptionMarker(selected, multi, Modifier.offset(13.dp, 11.dp))
        Column(Modifier.padding(start = 42.dp, end = 12.dp, top = 9.dp, bottom = 12.dp), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(title, color = c.ink, fontFamily = Nunito, fontWeight = FontWeight.W800, fontSize = 14.sp, lineHeight = 19.sp)
            if (description != null) {
                Text(description, color = c.ink2, fontFamily = Nunito, fontWeight = FontWeight.W600, fontSize = 12.sp, lineHeight = 17.sp)
            }
        }
    }
}

/** The 18 dp marker: stepped round for one choice, notched square for several; a recessed well until chosen. */
@Composable
private fun OptionMarker(selected: Boolean, multi: Boolean, modifier: Modifier) {
    val c = Critter.colors
    if (!multi) {
        Box(
            modifier
                .size(18.dp)
                .pixelSurface(if (selected) c.brand else c.surface2, step = 3.dp, lip = if (selected) 0.dp else 3.dp, lipColor = c.shade, recessed = true),
        ) {
            if (selected) Box(Modifier.offset(6.dp, 6.dp).size(6.dp).background(c.onBrand))
        }
        return
    }
    Box(
        modifier
            .size(18.dp)
            .drawBehind {
                val n = wholePx(3.dp)
                val fill = if (selected) c.brand else c.surface2
                drawRect(fill, Offset(n, 0f), Size(size.width - 2 * n, size.height))
                drawRect(fill, Offset(0f, n), Size(size.width, size.height - 2 * n))
                if (!selected) drawRect(c.shade, Offset(n, 0f), Size(size.width - 2 * n, n))
            },
    ) {
        if (selected) PixelIcon("check", Modifier.offset(4.dp, 4.dp), tint = c.onBrand)
    }
}

/** "Write my own…": a dashed card under the options. */
@Composable
fun WriteOwnCard(text: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val c = Critter.colors
    Box(
        modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp)
            .clip(PixelShape(3.dp))
            .drawBehind {
                val t = wholePx(2.dp)
                val dash = wholePx(6.dp)
                val period = dash + wholePx(4.dp)
                var x = 0f
                while (x < size.width) {
                    val w = minOf(dash, size.width - x)
                    drawRect(c.ink3, Offset(x, 0f), Size(w, t))
                    drawRect(c.ink3, Offset(x, size.height - t), Size(w, t))
                    x += period
                }
                var y = 0f
                while (y < size.height) {
                    val h = minOf(dash, size.height - y)
                    drawRect(c.ink3, Offset(0f, y), Size(t, h))
                    drawRect(c.ink3, Offset(size.width - t, y), Size(t, h))
                    y += period
                }
            }
            .clickable(interactionSource = null, indication = null, role = Role.Button, onClick = onClick)
            .padding(start = 12.dp, end = 12.dp, top = 9.dp, bottom = 12.dp),
        contentAlignment = Alignment.CenterStart,
    ) {
        Text(text, color = c.brand, fontFamily = Nunito, fontWeight = FontWeight.W800, fontSize = 14.sp)
    }
}

/** Reduce motion: the settings switch ([MotionPrefs.manual]) or the system's animation scale at 0; re-read on resume. */
@Composable
fun rememberReduceMotion(): Boolean {
    val resolver = LocalContext.current.contentResolver
    var reduce by remember { mutableStateOf(readReduceMotion(resolver)) }
    LifecycleResumeEffect(resolver) {
        reduce = readReduceMotion(resolver)
        onPauseOrDispose {}
    }
    return reduce
}

private fun readReduceMotion(resolver: ContentResolver): Boolean =
    MotionPrefs.manual || Settings.Global.getFloat(resolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f

/** The pet engine's beat. */
private const val TICK_MS = 60L

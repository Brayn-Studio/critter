package local.critter.phone.overlay

import android.content.Context
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Typeface
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.compose.ui.graphics.toArgb
import local.critter.phone.R
import local.critter.phone.ui.look.PixelDrawable
import local.critter.phone.ui.look.PixelIcons
import local.critter.phone.ui.look.bitmap
import local.critter.phone.ui.theme.CritterColors
import local.critter.phone.ui.theme.DarkCritterColors
import local.critter.phone.ui.theme.LightCritterColors
import kotlin.math.max
import kotlin.math.roundToInt

// The floating pile's pixel look for View code (design §8.4): the theme's colors by the current night mode, the
// app's fonts, the little white stepped tags and the count row.

/** Whether the system is in dark mode right now (the pile follows it like the app). */
internal fun Context.isNight(): Boolean =
    (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES

/** The Critter colors for the current night mode. */
internal fun Context.critterColors(): CritterColors = if (isNight()) DarkCritterColors else LightCritterColors

/** [dp] in whole pixels, at least 1. */
internal fun Context.px(dp: Float): Int = max(1, (dp * resources.displayMetrics.density).roundToInt())

internal object OverlayLook {
    private var nunito: Typeface? = null
    private var silkscreen: Typeface? = null
    private val icons = HashMap<Triple<String, Int, Int>, Bitmap>()

    fun nunito(context: Context): Typeface? =
        nunito ?: runCatching { context.resources.getFont(R.font.nunito) }.getOrNull().also { nunito = it }

    fun silkscreen(context: Context): Typeface? =
        silkscreen ?: runCatching { context.resources.getFont(R.font.silkscreen_regular) }.getOrNull().also { silkscreen = it }

    /** A pixel icon as a bitmap, made once per name, color and cell size. */
    fun icon(name: String, color: Int, cellPx: Int): Bitmap =
        icons.getOrPut(Triple(name, color, cellPx)) { PixelIcons.bitmap(name, color, cellPx) }

    /** Text in Nunito at [weight] (a variable font), [sizeSp] sp, one line ending in "…". */
    fun text(context: Context, sizeSp: Float, weight: Int, color: Int): TextView = TextView(context).apply {
        typeface = nunito(context)
        fontVariationSettings = "'wght' $weight"
        setTextSize(TypedValue.COMPLEX_UNIT_SP, sizeSp)
        setTextColor(color)
        includeFontPadding = false
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
    }

    /** The white stepped tag (2 dp steps, a 2 dp shade row at the bottom) the pile's labels sit on. */
    fun tag(context: Context, colors: CritterColors): PixelDrawable =
        PixelDrawable(colors.surface.toArgb(), context.px(2f), context.px(2f), colors.shade.toArgb())

    /** The tag's padding: 8 dp at the sides, 2 dp on top, 4 dp below (the shade row included). */
    fun padTag(view: android.view.View, sides: Float = 8f) {
        val c = view.context
        view.setPadding(c.px(sides), c.px(2f), c.px(sides), c.px(4f))
    }

    /** How tall a tag with a line of [label]'s text is. */
    fun tagHeight(label: TextView): Int = label.lineHeight + label.context.px(2f) + label.context.px(4f)

    /** The count row's icon colors, as on the mockup: the deep orange question mark, the sun, the check… */
    fun iconColor(icon: String, colors: CritterColors): Int = when (icon) {
        "q" -> colors.waitDeep
        "sun" -> colors.runGlyph
        "check" -> colors.doneGlyph
        "bang" -> colors.errGlyph
        else -> colors.ink3
    }.toArgb()
}

/**
 * A row of [pileCounts] entries (a pixel icon and a Silkscreen number each), on a [OverlayLook.tag] when [framed].
 * When the row does not fit [show]'s width, the least urgent states are left out (idle first, then done, running,
 * error); the total is on the pile's "n 个会话" tag anyway.
 */
internal class CountsRow(context: Context, private val colors: CritterColors, private val framed: Boolean) : LinearLayout(context) {
    private val cell = context.px(1.5f)
    private val inner = context.px(3f)
    private val between = context.px(6f)
    private var shown: List<Pair<String, Int>>? = null
    private val measure = number("0")

    init {
        orientation = HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        if (framed) {
            background = OverlayLook.tag(context, colors)
            OverlayLook.padTag(this, sides = 7f)
        }
        isClickable = false
    }

    fun show(counts: List<Pair<String, Int>>, maxWidth: Int) {
        val fitting = fit(counts, maxWidth)
        if (fitting == shown) return
        shown = fitting
        removeAllViews()
        fitting.forEachIndexed { i, (icon, n) ->
            val color = OverlayLook.iconColor(icon, colors)
            addView(
                ImageView(context).apply { setImageBitmap(OverlayLook.icon(icon, color, cell)) },
                LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply { if (i > 0) marginStart = between },
            )
            addView(number("$n"), LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply { marginStart = inner })
        }
    }

    private fun number(text: String) = TextView(context).apply {
        typeface = OverlayLook.silkscreen(context)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
        setTextColor(colors.ink.toArgb())
        includeFontPadding = false
        this.text = text
    }

    private fun width(entries: List<Pair<String, Int>>): Int {
        var w = paddingLeft + paddingRight + between * (entries.size - 1).coerceAtLeast(0)
        for ((icon, n) in entries) {
            val cols = PixelIcons.rows[icon]?.firstOrNull()?.length ?: 0
            w += cols * cell + inner + measure.paint.measureText("$n").roundToInt()
        }
        return w
    }

    private fun fit(counts: List<Pair<String, Int>>, maxWidth: Int): List<Pair<String, Int>> {
        var entries = counts
        for (drop in DROP_ORDER) {
            if (entries.size <= 1 || width(entries) <= maxWidth) break
            entries = entries.filter { it.first != drop }
        }
        return entries
    }

    private companion object {
        val DROP_ORDER = listOf("z", "check", "sun", "bang")
    }
}

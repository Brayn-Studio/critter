package local.critter.phone.ui.settings

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathOperation
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import local.critter.core.net.ConnState
import local.critter.core.protocol.PetState
import local.critter.core.skin.SkinManifest
import local.critter.phone.board.BlockFix
import local.critter.phone.board.BoardBlock
import local.critter.phone.board.blockAdvice
import local.critter.phone.board.pendingBlock
import local.critter.phone.bridge.BridgeRepository
import local.critter.phone.critter.CritterView
import local.critter.phone.data.PhoneSettings
import local.critter.phone.onboarding.OemGuide
import local.critter.phone.onboarding.OnboardingActivity
import local.critter.phone.onboarding.bundledSkin
import local.critter.phone.service.BridgeService
import local.critter.phone.ui.connText
import local.critter.phone.ui.meadow.LonePet
import local.critter.phone.ui.look.skyColors
import local.critter.phone.ui.meadow.MeadowBackdrop
import local.critter.phone.ui.meadow.PetStage
import local.critter.phone.ui.meadow.STAGE_PET
import local.critter.phone.ui.meadow.currentSkyTime
import local.critter.phone.ui.theme.ButtonKind
import local.critter.phone.ui.theme.ButtonSize
import local.critter.phone.ui.theme.Critter
import local.critter.phone.ui.theme.Nunito
import local.critter.phone.ui.theme.PixelButton
import local.critter.phone.ui.theme.PixelDialog
import local.critter.phone.ui.theme.PixelIcon
import local.critter.phone.ui.theme.PixelIconButton
import local.critter.phone.ui.theme.PixelSegmented
import local.critter.phone.ui.theme.PixelShape
import local.critter.phone.ui.theme.PixelSlider
import local.critter.phone.ui.theme.PixelSwitch
import local.critter.phone.ui.theme.Silkscreen
import local.critter.phone.ui.theme.outlinePath
import local.critter.phone.ui.theme.pixelSurface
import local.critter.phone.ui.theme.wholePx
import kotlin.math.roundToInt

/** The five bundled skins, in the order the settings show them. */
private val SKINS = listOf("clawd", "sprig", "mochi", "peep", "bristle")

/** A row's side padding inside its group card. */
private val ROW_PADDING = 16.dp

/**
 * The settings (design §8.8): the connection card, then grouped cards each under a pixel icon: the skin, the
 * floating pile, the board, alerts, motion and power. Every switch writes [PhoneSettings] at once.
 */
@Composable
fun SettingsScreen(
    repo: BridgeRepository,
    onBack: () -> Unit,
    onRepair: () -> Unit,
    onUnpaired: () -> Unit,
) {
    val context = LocalContext.current
    val c = Critter.colors
    val settings by repo.settingsStore.settings.collectAsState()
    val state by repo.state.collectAsState()
    val pairing by repo.pairing.collectAsState()
    var ignoring by remember { mutableStateOf(isIgnoringBatteryOptimizations(context)) }
    var confirmUnpair by remember { mutableStateOf(false) }
    var canOverlay by remember { mutableStateOf(Settings.canDrawOverlays(context)) }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
        ignoring = isIgnoringBatteryOptimizations(context)
        val granted = Settings.canDrawOverlays(context)
        // Back from the permission screen: the service shows the pile now.
        if (granted && !canOverlay && settings.overlayEnabled) BridgeService.sync(context, repo)
        canOverlay = granted
    }
    val macName = pairing?.macName?.ifEmpty { "Mac" } ?: "未配对"
    fun update(transform: (PhoneSettings) -> PhoneSettings) = repo.settingsStore.update(transform)

    Column(Modifier.fillMaxSize().background(c.bg).safeDrawingPadding()) {
        Row(
            Modifier.padding(start = 14.dp, end = 14.dp, top = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            PixelIconButton("back", "返回", onBack)
            Text(
                "设置", color = c.ink, fontFamily = Nunito, fontWeight = FontWeight.W900, fontSize = 20.sp,
                modifier = Modifier.semantics { heading() },
            )
        }
        Column(
            Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(start = 14.dp, end = 14.dp, top = 16.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            ConnectionCard(
                macName, state, settings.bridgeEnabled,
                onBridge = { on ->
                    update { it.copy(bridgeEnabled = on) }
                    BridgeService.sync(context, repo)
                },
                onRepair = onRepair,
                onUnpair = { confirmUnpair = true },
            )

            Group("paw", "形象") {
                SkinPicker(settings.skinOverride) { name -> update { it.copy(skinOverride = name) } }
            }

            Group("ball", "悬浮球") {
                SwitchRow("显示悬浮球", "浮在其他 App 上，点一下展开所有会话", settings.overlayEnabled) { on ->
                    update { it.copy(overlayEnabled = on) }
                    BridgeService.sync(context, repo)
                }
                if (settings.overlayEnabled && !canOverlay) {
                    NoticeRow("需要「显示在其他应用上层」的权限", "去授权") {
                        context.startActivity(
                            Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:${context.packageName}")),
                        )
                    }
                }
                Line()
                SizeRow(settings.overlaySize, settings.skinOverride) { size -> update { it.copy(overlaySize = size) } }
                Line()
                SwitchRow("空闲淡化跟着电脑", null, settings.overlayIdleDim == null) { follow ->
                    update { it.copy(overlayIdleDim = if (follow) null else 0.6f) }
                }
                settings.overlayIdleDim?.let { dim ->
                    SliderRow("空闲淡化", dim, 0f..1f, "悬浮球空闲淡化") { v -> update { it.copy(overlayIdleDim = v.coerceIn(0f, 1f)) } }
                }
                Line()
                SwitchRow("没有会话时藏起来", "关着时显示一只睡着的宠物", settings.overlayAutoHide) { on ->
                    update { it.copy(overlayAutoHide = on) }
                }
                Line()
                SwitchRow("全屏应用里隐藏", null, settings.overlayHideInFullscreen) { on ->
                    update { it.copy(overlayHideInFullscreen = on) }
                }
            }

            Group("board", "看板") {
                // Ten cells for 10 % to 100 %: the first cell is the floor, the board is never fully dark.
                SliderRow("亮度", settings.boardBrightness, 0f..1f, "看板亮度") { v ->
                    update { it.copy(boardBrightness = v.coerceIn(0.1f, 1f)) }
                }
                Line()
                SwitchRow(
                    "充电横放时自动打开", "充电、横放、静止 3 秒后打开；拔电 10 秒后或竖起来 3 秒后退出，平放不退出",
                    settings.boardAutoOpen,
                ) { on -> update { it.copy(boardAutoOpen = on) } }
                // What last kept it from opening by itself, while that still holds.
                val block = pendingBlock(settings.boardBlockedAt, settings.boardBlockedBy, canOverlay)
                if (settings.boardAutoOpen) {
                    // The missing permission is said once: by the notice below when that is what blocked it.
                    val missing = !canOverlay && block != BoardBlock.NoOverlayPermission
                    Text(
                        (if (missing) "还没有「显示在其他应用上层」权限，看板打不开。" else "") +
                            "自动打开需要「显示在其他应用上层」权限；vivo、小米等手机还要在应用权限里打开「后台弹出界面」。" +
                            "系统拦下时，这次充电不再尝试，下次插电再试。",
                        color = if (missing) c.err else c.ink2, fontFamily = Nunito, fontWeight = FontWeight.W600,
                        fontSize = 12.sp, lineHeight = 17.sp,
                        modifier = Modifier.padding(start = ROW_PADDING, end = ROW_PADDING, bottom = 10.dp),
                    )
                }
                if (block != null) {
                    val advice = blockAdvice(block)
                    NoticeRow(advice.notice, advice.noticeAction) {
                        when (advice.fix) {
                            BlockFix.OverlayPermission -> context.startActivity(
                                Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:${context.packageName}")),
                            )
                            BlockFix.AppDetails -> OemGuide.openAppDetails(context)
                        }
                        update { it.copy(boardBlockedAt = null) }
                    }
                }
                Line()
                SwitchRow("看板提示音", "只在看板打开时响；勿扰模式下不响", settings.boardSounds) { on ->
                    update { it.copy(boardSounds = on) }
                }
            }

            Group("bell", "提醒") {
                SwitchRow("等你确认时震动", null, settings.vibrateOnWaiting) { on -> update { it.copy(vibrateOnWaiting = on) } }
                Line()
                SwitchRow("做完了时通知", null, settings.notifyDone) { on -> update { it.copy(notifyDone = on) } }
                Line()
                SwitchRow("出错时通知", null, settings.notifyError) { on -> update { it.copy(notifyError = on) } }
            }

            Group("spark", "动画与省电") {
                SwitchRow("减少动态效果", "宠物停在代表姿势上；系统“移除动画”打开时也会减少", settings.reduceMotion) { on ->
                    update { it.copy(reduceMotion = on) }
                }
                Line()
                BatteryRow(ignoring) {
                    context.startActivity(
                        Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${context.packageName}")),
                    )
                }
                Line()
                NavRow("保持后台运行", "熄屏后连接被系统停掉时，按手机品牌打开自启动、后台耗电等开关。") {
                    context.startActivity(OnboardingActivity.intent(context, onlyKeepAlive = true))
                }
                Line()
                NavRow("重新走一遍引导", null) { context.startActivity(OnboardingActivity.intent(context)) }
            }
        }
    }

    if (confirmUnpair) {
        PixelDialog(
            title = "取消和 $macName 的配对？",
            confirmText = "取消配对",
            onConfirm = {
                confirmUnpair = false
                repo.unpair()
                onUnpaired()
            },
            dismissText = "保留",
            onDismiss = { confirmUnpair = false },
            confirmKind = ButtonKind.Danger,
        ) {
            Text("手机会断开，不再收到提醒。之后要用，得在 Mac 上重新「添加手机」再扫码。")
        }
    }
}

// --- the connection ------------------------------------------------------------------------------------------

/**
 * The Mac and how the connection is, on a status row that never changes height (only its words and the dot
 * change), the two pairing buttons, and the switch that keeps the connection up in the background.
 */
@Composable
private fun ConnectionCard(
    macName: String,
    state: ConnState,
    bridgeEnabled: Boolean,
    onBridge: (Boolean) -> Unit,
    onRepair: () -> Unit,
    onUnpair: () -> Unit,
) {
    val c = Critter.colors
    val (tone, dot) = when (state) {
        is ConnState.Connected -> c.done to c.doneGlyph
        is ConnState.NeedsRepair -> c.err to c.errGlyph
        else -> c.ink2 to c.ink3
    }
    Column(
        Modifier
            .fillMaxWidth()
            .pixelSurface(c.surface, step = 5.dp, lip = 4.dp, lipColor = c.shade)
            .padding(start = 14.dp, end = 14.dp, top = 14.dp, bottom = 18.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 44.dp).semantics(mergeDescendants = true) {},
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier.size(44.dp).pixelSurface(c.brandSoft, step = 3.dp, lip = 0.dp, lipColor = c.brandSoft),
                contentAlignment = Alignment.Center,
            ) { PixelIcon("laptop", tint = c.brand, cell = 3.dp) }
            // One line each: a long reason is cut short rather than making the card jump.
            Column(Modifier.weight(1f)) {
                Text(
                    macName, color = c.ink, fontFamily = Nunito, fontWeight = FontWeight.W800, fontSize = 16.sp,
                    maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.CenterVertically) {
                    PixelIcon("dot", tint = dot)
                    Text(
                        connText(state), color = tone, fontFamily = Nunito, fontWeight = FontWeight.W800, fontSize = 12.5.sp,
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            PixelButton("重新配对", onRepair, Modifier.weight(1f), kind = ButtonKind.Secondary, size = ButtonSize.Small)
            PixelButton("取消配对", onUnpair, Modifier.weight(1f), kind = ButtonKind.Danger, size = ButtonSize.Small)
        }
        SwitchRow("保持后台连接", "关掉后不再收到提醒，也看不到实时状态", bridgeEnabled, padding = 0.dp, onChange = onBridge)
    }
}

// --- groups and rows -----------------------------------------------------------------------------------------

/** A card of settings under a heading with its pixel [icon]. */
@Composable
private fun Group(icon: String, title: String, content: @Composable ColumnScope.() -> Unit) {
    val c = Critter.colors
    Column(
        Modifier
            .fillMaxWidth()
            .pixelSurface(c.surface, step = 5.dp, lip = 0.dp, lipColor = c.surface)
            .padding(top = 4.dp, bottom = 8.dp),
    ) {
        Row(
            Modifier.padding(start = 20.dp, end = 20.dp, top = 14.dp, bottom = 8.dp).semantics(mergeDescendants = true) { heading() },
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            PixelIcon(icon, tint = c.brand)
            Text(title, color = c.ink2, fontFamily = Nunito, fontWeight = FontWeight.W900, fontSize = 13.sp)
        }
        content()
    }
}

/** The thin line between two rows of a group. */
@Composable
private fun Line() {
    Box(Modifier.fillMaxWidth().height(1.dp).background(Critter.colors.line))
}

@Composable
private fun RowText(title: String, subtitle: String?, modifier: Modifier, subtitleColor: Color = Critter.colors.ink2) {
    val c = Critter.colors
    Column(modifier) {
        Text(title, color = c.ink, fontFamily = Nunito, fontWeight = FontWeight.W800, fontSize = 15.sp, lineHeight = 20.sp)
        if (subtitle != null) {
            Text(
                subtitle, color = subtitleColor, fontFamily = Nunito, fontWeight = FontWeight.W600, fontSize = 12.sp,
                lineHeight = 17.sp, modifier = Modifier.padding(top = 2.dp),
            )
        }
    }
}

@Composable
private fun SwitchRow(
    title: String,
    subtitle: String?,
    checked: Boolean,
    padding: Dp = ROW_PADDING,
    onChange: (Boolean) -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 52.dp).padding(horizontal = padding, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RowText(title, subtitle, Modifier.weight(1f))
        PixelSwitch(checked, onChange, contentDescription = title)
    }
}

/** A row that opens another screen. */
@Composable
private fun NavRow(title: String, subtitle: String?, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .clickable(interactionSource = null, indication = null, role = Role.Button, onClick = onClick)
            .padding(horizontal = ROW_PADDING, vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RowText(title, subtitle, Modifier.weight(1f))
        PixelIcon("chevR", tint = Critter.colors.ink3)
    }
}

/** A label with its value in percent over a ten-cell slider. */
@Composable
private fun SliderRow(
    title: String,
    value: Float,
    range: ClosedFloatingPointRange<Float>,
    description: String,
    onChange: (Float) -> Unit,
) {
    val c = Critter.colors
    Column(
        Modifier.fillMaxWidth().padding(horizontal = ROW_PADDING, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
            Text(title, color = c.ink, fontFamily = Nunito, fontWeight = FontWeight.W800, fontSize = 15.sp)
            // The number in Silkscreen, the "%" in Nunito (Silkscreen's % reads as a z when small).
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("${(value * 100).roundToInt()}", color = c.ink2, fontFamily = Silkscreen, fontSize = 14.sp)
                Text("%", color = c.ink2, fontFamily = Nunito, fontWeight = FontWeight.W800, fontSize = 14.sp)
            }
        }
        PixelSlider(value, onChange, range, segments = 10, contentDescription = description)
    }
}

/** The pile's size as three choices, with the pet drawn at that size beside them (2, 3, 4 dp a cell). */
@Composable
private fun SizeRow(size: Int, skin: String?, onSize: (Int) -> Unit) {
    Column(
        Modifier.fillMaxWidth().padding(horizontal = ROW_PADDING, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        RowText("大小", null, Modifier)
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.Bottom) {
            PixelSegmented(listOf("小", "中", "大"), (size - 1).coerceIn(0, 2), { onSize(it + 1) }, Modifier.weight(1f))
            Box(Modifier.size(76.dp, 52.dp), contentAlignment = Alignment.BottomCenter) {
                LonePet(bundledSkin(skin ?: "sprig"), PetState.idle, cell = (size.coerceIn(1, 3) + 1).dp, columns = 19, rows = 13)
            }
        }
    }
}

/** An orange line with what to switch on and a button that goes there. */
@Composable
private fun NoticeRow(text: String, action: String, onAction: () -> Unit) {
    val c = Critter.colors
    Row(
        Modifier
            .fillMaxWidth()
            .padding(start = ROW_PADDING, end = ROW_PADDING, top = 6.dp, bottom = 4.dp)
            .pixelSurface(c.waitBg, step = 3.dp, lip = 0.dp, lipColor = c.waitBg)
            .padding(start = 12.dp, end = 12.dp, top = 10.dp, bottom = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        PixelIcon("bang", tint = c.waitInk)
        Text(
            text, color = c.waitInk, fontFamily = Nunito, fontWeight = FontWeight.W700, fontSize = 12.5.sp, lineHeight = 19.sp,
            modifier = Modifier.weight(1f),
        )
        PixelButton(action, onAction, kind = ButtonKind.Warning, size = ButtonSize.Small)
    }
}

@Composable
private fun BatteryRow(ignoring: Boolean, onIgnore: () -> Unit) {
    val c = Critter.colors
    Row(
        Modifier.fillMaxWidth().heightIn(min = 52.dp).padding(horizontal = ROW_PADDING, vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RowText(
            "电池优化",
            if (ignoring) "已忽略，后台连接不容易被停掉" else "系统的电池优化可能会停掉后台连接。",
            Modifier.weight(1f),
            subtitleColor = if (ignoring) c.done else c.ink2,
        )
        if (!ignoring) PixelButton("忽略电池优化", onIgnore, kind = ButtonKind.Secondary, size = ButtonSize.Small)
    }
}

// --- the skin ------------------------------------------------------------------------------------------------

/**
 * A row of little meadows to scroll through: "跟着电脑" first, then the five skins, each with a live pet. The
 * chosen one has a brand frame and a check; picking a skin makes its pet cheer (its `done` entrance).
 */
@Composable
private fun SkinPicker(selected: String?, onPick: (String?) -> Unit) {
    val views = remember { HashMap<String, CritterView>() }
    Row(
        Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(start = ROW_PADDING, end = ROW_PADDING, top = 4.dp, bottom = 6.dp)
            .selectableGroup(),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        SkinTile("跟着电脑", selected == null, onClick = { onPick(null) }) { FollowPicture() }
        SKINS.forEach { name ->
            val manifest = bundledSkin(name)
            SkinTile(
                shortTitle(manifest), selected == name,
                onClick = {
                    onPick(name)
                    cheer(manifest)?.let { views[name]?.playClip(STAGE_PET, it) }
                },
            ) {
                PetStage(
                    manifest, PetState.idle, null, Modifier.matchParentSize(),
                    cell = 3.dp, groundInset = 9.dp, bright = true, onView = { views[name] = it },
                )
            }
        }
    }
}

/** The clip a skin plays on entering `done` (the cheer with petals), if it has one. */
private fun cheer(manifest: SkinManifest) = manifest.state(PetState.done).enter?.let { manifest.clips[it] }

/** "小芽" from "小芽 Sprig"; "Clawd" for the skin without a title. */
private fun shortTitle(manifest: SkinManifest): String =
    manifest.title?.substringBefore(' ')?.ifEmpty { null } ?: manifest.name.replaceFirstChar { it.uppercase() }

@Composable
private fun SkinTile(label: String, on: Boolean, onClick: () -> Unit, picture: @Composable BoxScope.() -> Unit) {
    val c = Critter.colors
    Column(
        Modifier
            .width(76.dp)
            .selectable(on, interactionSource = null, indication = null, role = Role.RadioButton, onClick = onClick),
        verticalArrangement = Arrangement.spacedBy(5.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(Modifier.size(76.dp, 70.dp).clip(PixelShape(3.dp)).chosenFrame(on, c.brand)) {
            picture()
            if (on) {
                Box(
                    Modifier
                        .align(Alignment.TopEnd)
                        .padding(top = 5.dp, end = 5.dp)
                        .size(18.dp)
                        .pixelSurface(c.brand, step = 2.dp, lip = 0.dp, lipColor = c.brand),
                    contentAlignment = Alignment.Center,
                ) { PixelIcon("check", tint = c.onBrand) }
            }
        }
        Text(
            label, color = if (on) c.ink else c.ink2, fontFamily = Nunito, fontWeight = FontWeight.W800, fontSize = 12.sp,
            maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
    }
}

/** "跟着电脑": the meadow with a little computer on it, in the sky's ink so it shows at night too. */
@Composable
private fun BoxScope.FollowPicture() {
    val time = currentSkyTime()
    MeadowBackdrop(time, 61.dp, Modifier.matchParentSize())
    PixelIcon("laptop", Modifier.align(Alignment.Center), tint = Color(skyColors(time).onSky), cell = 4.dp)
}

/** A 3 dp [color] frame inside the tile's stepped edge, drawn over the picture, when [on]. */
private fun Modifier.chosenFrame(on: Boolean, color: Color): Modifier = drawWithCache {
    val t = wholePx(3.dp)
    val outer = outlinePath(size.width, size.height, wholePx(3.dp), topOnly = false)
    val inner = outlinePath(size.width - 2 * t, size.height - 2 * t, wholePx(2.dp), topOnly = false, dx = t, dy = t)
    val frame = Path.combine(PathOperation.Difference, outer, inner)
    onDrawWithContent {
        drawContent()
        if (on) drawPath(frame, color)
    }
}

private fun isIgnoringBatteryOptimizations(context: Context): Boolean =
    context.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(context.packageName)

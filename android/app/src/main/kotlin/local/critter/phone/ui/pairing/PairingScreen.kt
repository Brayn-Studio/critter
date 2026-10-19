package local.critter.phone.ui.pairing

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
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
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import local.critter.core.net.ConnState
import local.critter.core.net.PairFailure
import local.critter.core.net.PrivateNetwork
import local.critter.core.protocol.PairingUri
import local.critter.core.protocol.PetState
import local.critter.core.skin.ClipKey
import local.critter.core.skin.MotionClip
import local.critter.core.skin.SkinManifest
import local.critter.phone.bridge.BridgeRepository
import local.critter.phone.bridge.CertProbe
import local.critter.phone.bridge.FoundMac
import local.critter.phone.critter.CritterView
import local.critter.phone.onboarding.SeedRow
import local.critter.phone.onboarding.SkipNote
import local.critter.phone.onboarding.StepBody
import local.critter.phone.onboarding.StepGutter
import local.critter.phone.onboarding.StepPage
import local.critter.phone.onboarding.StepPosition
import local.critter.phone.onboarding.StepStage
import local.critter.phone.onboarding.StepTitle
import local.critter.phone.onboarding.bundledSkin
import local.critter.phone.ui.meadow.LonePet
import local.critter.phone.ui.meadow.STAGE_PET
import local.critter.phone.ui.theme.ButtonKind
import local.critter.phone.ui.theme.ButtonSize
import local.critter.phone.ui.theme.Critter
import local.critter.phone.ui.theme.CritterTheme
import local.critter.phone.ui.theme.Nunito
import local.critter.phone.ui.theme.PixelButton
import local.critter.phone.ui.theme.PixelDialog
import local.critter.phone.ui.theme.PixelIcon
import local.critter.phone.ui.theme.PixelIconButton
import local.critter.phone.ui.theme.Silkscreen
import local.critter.phone.ui.theme.pixelSurface
import local.critter.phone.ui.theme.wholePx

private enum class Mode { Scan, Manual }

private const val CODE_LENGTH = 8

/** How long the viewfinder shows green after a read, before pairing starts: six beats of the pet engine. */
private const val FLASH_MS = 360L

/** How many times Sprig looks up, blinks and looks up again under the viewfinder before it goes about its day. */
private const val LOOK_UP_ROUNDS = 5

/**
 * The picture while the Mac is asked, and on the onboarding's "已配对" page: the same size, so going from one to
 * the other changes only the pet.
 */
val PAIRED_STAGE_HEIGHT = 210.dp

/**
 * Pairing: scan the QR code the Mac shows (or open its `critter-pair://` link), or pick the Mac from the
 * network and type the code. [deepLink] (a link any web page can open) is shown in a confirmation first, with
 * the Mac's name, address and fingerprint; [onCancel] is null when there is nothing to go back to. Only Macs on
 * the local network are paired with ([PrivateNetwork], the ranges the Mac itself serves). In the onboarding,
 * [position] puts the seeds on top and [onSkip] with its [skipNote] offers to do without.
 */
@Composable
fun PairingScreen(
    repo: BridgeRepository,
    deepLink: PairingUri?,
    onDeepLinkConsumed: () -> Unit,
    onPaired: () -> Unit,
    onCancel: (() -> Unit)?,
    modifier: Modifier = Modifier,
    position: StepPosition? = null,
    onSkip: (() -> Unit)? = null,
    skipNote: String? = null,
) {
    val c = Critter.colors
    val scope = rememberCoroutineScope()
    var mode by rememberSaveable { mutableStateOf(Mode.Scan) }
    var busy by remember { mutableStateOf(false) }
    var attempt by remember { mutableStateOf<Job?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    // The camera keeps reading the code that just failed; it must not start the same attempt again and again.
    var failedScan by remember { mutableStateOf<String?>(null) }
    val pairState by repo.pairState.collectAsState()
    val existing by repo.pairing.collectAsState()
    var linkToConfirm by remember { mutableStateOf<PairingUri?>(null) }

    fun pair(uri: PairingUri, scanned: String? = null) {
        if (busy) return
        if (!PrivateNetwork.isAllowed(uri.host)) {
            error = "地址 ${uri.host} 不在局域网里。Critter 只和同一个局域网里的 Mac 配对。"
            failedScan = scanned
            return
        }
        busy = true
        error = null
        attempt = scope.launch {
            val why = repo.pair(uri)
            busy = false
            if (why == null) {
                onPaired()
            } else {
                error = pairFailureText(why)
                failedScan = scanned
            }
        }
    }

    fun switchTo(next: Mode) {
        error = null
        failedScan = null
        mode = next
    }

    LaunchedEffect(deepLink) {
        if (deepLink != null) {
            onDeepLinkConsumed()
            if (PrivateNetwork.isAllowed(deepLink.host)) {
                linkToConfirm = deepLink
            } else {
                error = "这个配对链接指向 ${deepLink.host}，不在局域网里，已忽略。"
            }
        }
    }

    linkToConfirm?.let { uri ->
        val cancel = {
            linkToConfirm = null
            onCancel?.invoke()
            Unit
        }
        PixelDialog(
            title = "和这台 Mac 配对？",
            confirmText = "配对",
            onConfirm = {
                linkToConfirm = null
                pair(uri)
            },
            dismissText = "取消",
            onDismiss = cancel,
        ) {
            Text("一个链接要让这台手机和「${uri.name.ifEmpty { "Mac" }}」配对。只在你刚在 Mac 上点了「添加手机」时才继续。")
            Text("地址  ${hostAndPort(uri.host, uri.port)}", fontSize = 12.5.sp)
            Text(
                "证书指纹  ${PairingUri.fingerprintPrefix(uri.fingerprint)}",
                color = c.ink, fontFamily = FontFamily.Monospace, fontSize = 14.sp,
            )
            Text("和 Mac 上「添加手机」里码下面的指纹一致时才配对。", fontSize = 12.sp, lineHeight = 18.sp)
            existing?.let { p ->
                Text("这会替换现在和「${p.macName.ifEmpty { "Mac" }}」的配对。", color = c.err, fontWeight = FontWeight.W700)
            }
        }
    }

    Box(modifier.fillMaxSize()) {
        when {
            busy -> WaitingPane(
                position, pairState,
                onCancel = {
                    // The attempt's own cleanup closes the socket and brings back an earlier pairing's connection.
                    attempt?.cancel()
                    attempt = null
                    busy = false
                },
            )

            mode == Mode.Scan -> ScanPane(
                position = position,
                error = error,
                ignore = failedScan,
                onLink = { uri, text -> pair(uri, text) },
                onNotALink = { text ->
                    error = "这不是 Critter 的配对二维码。"
                    failedScan = text
                },
                onManual = { switchTo(Mode.Manual) },
                onCancel = onCancel,
                onSkip = onSkip,
                skipNote = skipNote,
            )

            else -> ManualPane(
                repo = repo,
                error = error,
                onPair = ::pair,
                onProbeFailed = { error = "连不上这台 Mac，换个方式或稍后再试。" },
                onScan = { switchTo(Mode.Scan) },
            )
        }
    }
}

// --- waiting for the Mac -------------------------------------------------------------------------------------

/** Sprig waits with its hand up, over the row the Mac's "添加手机" window shows now, with 「允许」 circled. */
@Composable
private fun WaitingPane(position: StepPosition?, pairState: ConnState, onCancel: () -> Unit) {
    BackHandler(onBack = onCancel)
    StepPage(
        position, "在 Mac 上点「允许」", "Mac 的「添加手机」窗口里出现了下面这一行。点允许之后，这里会自己往下走。",
        ghost = "取消", onGhost = onCancel,
        extra = { MacRequestRow(pairState) },
    ) { StepStage("sprig", PetState.waiting, height = PAIRED_STAGE_HEIGHT) }
}

/** A drawing of the Mac's request row; its buttons are pictures, not buttons. */
@Composable
private fun MacRequestRow(pairState: ConnState) {
    val c = Critter.colors
    Column(
        Modifier
            .fillMaxWidth()
            .padding(top = 6.dp)
            .pixelSurface(c.surface, step = 5.dp, lip = 4.dp, lipColor = c.shade)
            .padding(start = 16.dp, end = 16.dp, top = 14.dp, bottom = 18.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            PixelIcon("laptop", tint = c.brand, cell = 3.dp)
            Text(
                "「${Build.MODEL ?: "Android"}」请求连接", color = c.ink, fontFamily = Nunito, fontWeight = FontWeight.W800,
                fontSize = 14.5.sp, maxLines = 2, overflow = TextOverflow.Ellipsis,
            )
        }
        Text(
            if (pairState is ConnState.AwaitingApproval) "在 Mac 上点「允许」" else "连接中…",
            color = c.ink2, fontFamily = Nunito, fontWeight = FontWeight.W600, fontSize = 12.5.sp,
        )
        Row(Modifier.fillMaxWidth().clearAndSetSemantics {}, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            PictureButton("拒绝", primary = false, Modifier.weight(1f))
            PictureButton("允许", primary = true, Modifier.weight(1.4f))
        }
    }
}

/** A small button as drawn on the Mac; the primary one has the orange dashed ring around it, 2 dp out. */
@Composable
private fun PictureButton(text: String, primary: Boolean, modifier: Modifier) {
    val c = Critter.colors
    Box(
        modifier
            .height(34.dp)
            .then(if (primary) Modifier.drawBehind { dashedRing(c.wait) } else Modifier)
            .pixelSurface(
                if (primary) c.brand else c.surface2, step = 3.dp, lip = 3.dp,
                lipColor = if (primary) c.brandDeep else c.shade, highlight = if (primary) c.highlight else null,
            )
            .padding(bottom = 3.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(text, color = if (primary) c.onBrand else c.ink, fontFamily = Nunito, fontWeight = FontWeight.W900, fontSize = 13.5.sp)
    }
}

/** A 3 dp dashed rectangle 2 dp outside the bounds (the CSS `outline: 3px dashed; outline-offset: 2px`). */
private fun androidx.compose.ui.graphics.drawscope.DrawScope.dashedRing(color: Color) {
    val t = wholePx(3.dp)
    val out = wholePx(2.dp) + t
    val dash = wholePx(6.dp)
    val period = dash + wholePx(4.dp)
    val left = -out
    val top = -out
    val width = size.width + 2 * out
    val height = size.height + 2 * out
    var x = 0f
    while (x < width) {
        val w = minOf(dash, width - x)
        drawRect(color, Offset(left + x, top), Size(w, t))
        drawRect(color, Offset(left + x, top + height - t), Size(w, t))
        x += period
    }
    var y = 0f
    while (y < height) {
        val h = minOf(dash, height - y)
        drawRect(color, Offset(left, top + y), Size(t, h))
        drawRect(color, Offset(left + width - t, top + y), Size(t, h))
        y += period
    }
}

// --- scanning ------------------------------------------------------------------------------------------------

/** The scanner's Critter, handed over by its view once it exists. */
private class PetHandle {
    var view: CritterView? = null
}

/**
 * Dark and full screen: the camera shows through the 248 dp viewfinder, dimmed everywhere else, with Sprig under
 * the frame looking up at it. A read turns the frame green and Sprig hops, then pairing starts.
 */
@Composable
private fun ScanPane(
    position: StepPosition?,
    error: String?,
    ignore: String?,
    onLink: (PairingUri, String) -> Unit,
    onNotALink: (String) -> Unit,
    onManual: () -> Unit,
    onCancel: (() -> Unit)?,
    onSkip: (() -> Unit)?,
    skipNote: String?,
) = CritterTheme(dark = true) {
    LightSystemBarIcons()
    val c = Critter.colors
    val context = LocalContext.current
    fun cameraGranted() =
        ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
    var granted by remember { mutableStateOf(cameraGranted()) }
    var denied by remember { mutableStateOf(false) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        granted = it
        denied = !it
    }
    LaunchedEffect(Unit) { if (!granted) launcher.launch(Manifest.permission.CAMERA) }
    // Back from the system settings, where the permission may have been turned on.
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { if (!granted && cameraGranted()) granted = true }

    val scope = rememberCoroutineScope()
    val pet = remember { PetHandle() }
    var flash by remember { mutableStateOf(false) }
    var hole by remember { mutableStateOf<Rect?>(null) }
    var origin by remember { mutableStateOf(Offset.Zero) }

    fun onRead(text: String) {
        if (flash || text == ignore) return
        val uri = PairingUri.parse(text)
        if (uri == null) {
            onNotALink(text)
            return
        }
        flash = true
        pet.view?.hop(STAGE_PET)
        scope.launch {
            delay(FLASH_MS)
            flash = false
            onLink(uri, text)
        }
    }

    Box(Modifier.fillMaxSize().background(c.shade).onGloballyPositioned { origin = it.positionInRoot() }) {
        if (granted) QrScanner(onResult = ::onRead, modifier = Modifier.fillMaxSize())
        Canvas(Modifier.fillMaxSize()) {
            val window = hole?.translate(-origin)
            if (window == null) {
                drawRect(c.scrim)
            } else {
                drawRect(c.scrim, Offset.Zero, Size(size.width, window.top))
                drawRect(c.scrim, Offset(0f, window.bottom), Size(size.width, size.height - window.bottom))
                drawRect(c.scrim, Offset(0f, window.top), Size(window.left, window.height))
                drawRect(c.scrim, Offset(window.right, window.top), Size(size.width - window.right, window.height))
            }
        }
        Column(Modifier.fillMaxSize().safeDrawingPadding().padding(horizontal = StepGutter)) {
            if (position != null) SeedRow(position, Modifier.padding(top = 8.dp))
            Column(
                Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(top = 12.dp, bottom = 16.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                StepTitle("扫 Mac 上的二维码", Modifier.fillMaxWidth())
                Spacer(Modifier.height(28.dp))
                // Sprig stands 24 dp below the frame, its head reaching up into the frame's bottom edge.
                Box(Modifier.width(VIEWFINDER).height(VIEWFINDER + 24.dp)) {
                    Box(
                        Modifier.size(VIEWFINDER).onGloballyPositioned { hole = it.boundsInRoot() },
                        contentAlignment = Alignment.Center,
                    ) {
                        PixelViewfinder(if (flash) c.doneGlyph else c.ink, Modifier.matchParentSize())
                        if (!granted) CameraAsk(denied, onAsk = { launcher.launch(Manifest.permission.CAMERA) })
                    }
                    val sprig = bundledSkin("sprig")
                    LonePet(
                        sprig, PetState.idle, Modifier.align(Alignment.BottomCenter), cell = 4.dp, rows = 16,
                        onView = { view ->
                            pet.view = view
                            view.post { view.playClip(STAGE_PET, lookingUp(sprig)) }
                        },
                    )
                }
                Spacer(Modifier.height(18.dp))
                StepBody(
                    "在 Mac 上打开 Critter 的「设置…」，打开「允许手机连接」，点「添加手机…」，把出现的二维码放进框里。",
                    Modifier.fillMaxWidth().padding(horizontal = 4.dp), align = TextAlign.Center,
                )
                if (error != null) {
                    Spacer(Modifier.height(14.dp))
                    ErrorNote(error)
                }
            }
            Column(
                Modifier.fillMaxWidth().padding(bottom = 16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                PixelButton("手动输入", onManual, Modifier.fillMaxWidth(), kind = ButtonKind.Secondary, icon = "keys")
                if (onCancel != null || onSkip != null) {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
                        if (onCancel != null) PixelButton("返回", onCancel, kind = ButtonKind.Ghost)
                        if (onSkip != null) PixelButton("跳过", onSkip, kind = ButtonKind.Ghost)
                    }
                }
                if (onSkip != null && skipNote != null) SkipNote(skipNote)
            }
        }
    }
}

private val VIEWFINDER = 248.dp

/** Asking for the camera, inside the empty viewfinder. */
@Composable
private fun CameraAsk(denied: Boolean, onAsk: () -> Unit) {
    val c = Critter.colors
    val context = LocalContext.current
    Column(
        Modifier.padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        StepBody(
            if (denied) "扫码需要相机权限。你可以在系统设置里打开它，或者改用手动输入。" else "需要相机权限来扫描二维码。",
            color = c.ink, align = TextAlign.Center,
        )
        if (denied) {
            PixelButton("去设置", {
                context.startActivity(
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}")),
                )
            }, size = ButtonSize.Small)
        } else {
            PixelButton("允许使用相机", onAsk, size = ButtonSize.Small)
        }
    }
}

/** Sprig's eyes on the viewfinder: looking up, a blink now and then, for half a minute or so. */
private fun lookingUp(skin: SkinManifest): MotionClip {
    val n = skin.interactions
    val round = listOf(ClipKey(n.lookUp, 40), ClipKey(n.blinkPose, 2), ClipKey(n.lookUp, 60))
    return List(LOOK_UP_ROUNDS) { round.map { it.copy() } }.flatten() + ClipKey(n.lookCenter, 2)
}

/** Light status and navigation bar icons while this is on screen (the scanner is dark in either theme). */
@Composable
private fun LightSystemBarIcons() {
    val view = LocalView.current
    DisposableEffect(view) {
        val window = view.context.findActivity()?.window ?: return@DisposableEffect onDispose {}
        val bars = WindowCompat.getInsetsController(window, view)
        val status = bars.isAppearanceLightStatusBars
        val navigation = bars.isAppearanceLightNavigationBars
        bars.isAppearanceLightStatusBars = false
        bars.isAppearanceLightNavigationBars = false
        onDispose {
            bars.isAppearanceLightStatusBars = status
            bars.isAppearanceLightNavigationBars = navigation
        }
    }
}

private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}

// --- typing the code -----------------------------------------------------------------------------------------

/** The Macs found on the network as one card, the chosen one marked "已选", and the code in 4 + 4 cells. */
@Composable
private fun ManualPane(
    repo: BridgeRepository,
    error: String?,
    onPair: (PairingUri) -> Unit,
    onProbeFailed: () -> Unit,
    onScan: () -> Unit,
) {
    val c = Critter.colors
    val scope = rememberCoroutineScope()
    val macs by produceState(emptyList<FoundMac>()) {
        repo.nsd.browse().collect { found -> value = value.filter { it.name != found.name } + found }
    }
    var selected by remember { mutableStateOf<FoundMac?>(null) }
    var code by rememberSaveable { mutableStateOf("") }
    var probing by remember { mutableStateOf(false) }
    var confirm by remember { mutableStateOf<Pair<FoundMac, String>?>(null) }
    // Back goes to the scanner this screen came from, like the back icon.
    BackHandler(onBack = onScan)

    Column(Modifier.fillMaxSize().background(c.bg).safeDrawingPadding().padding(horizontal = 18.dp)) {
        Row(
            Modifier.padding(top = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            PixelIconButton("back", "返回", onScan)
            Text("手动输入", color = c.ink, fontFamily = Nunito, fontWeight = FontWeight.W900, fontSize = 18.sp)
        }
        Column(
            Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(top = 22.dp, bottom = 16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            FieldLabel("局域网里的 Mac")
            MacList(macs, selected, onSelect = { selected = it })
            FieldLabel("Mac 上显示的 $CODE_LENGTH 位码", Modifier.padding(top = 8.dp))
            CodeCells(code, { code = it.uppercase().filter { ch -> ch.isLetterOrDigit() }.take(CODE_LENGTH) }, error != null)
            if (error != null) ErrorNote(error, Modifier.padding(top = 4.dp))
        }
        Column(
            Modifier.fillMaxWidth().padding(bottom = 16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            PixelButton(
                if (probing) "正在连接…" else "连接",
                onClick = {
                    val mac = selected ?: return@PixelButton
                    probing = true
                    scope.launch {
                        val fp = CertProbe.fingerprint(mac.host, mac.port)
                        probing = false
                        if (fp == null) onProbeFailed() else confirm = mac to fp
                    }
                },
                modifier = Modifier.fillMaxWidth(),
                size = ButtonSize.Large,
                enabled = selected != null && code.length == CODE_LENGTH && !probing,
            )
            PixelButton("改用扫码", onScan, kind = ButtonKind.Ghost, icon = "qr")
        }
    }

    confirm?.let { (mac, fp) ->
        PixelDialog(
            title = "信任这台 Mac？",
            confirmText = "信任并配对",
            onConfirm = {
                confirm = null
                onPair(PairingUri(mac.host, mac.port, fp, code, mac.name))
            },
            dismissText = "取消",
            onDismiss = { confirm = null },
        ) {
            Text("第一次连接「${mac.name}」。只有下面的证书指纹和 Mac 上「添加手机」里码下面显示的一致时才继续：")
            Text(PairingUri.fingerprintPrefix(fp), color = c.ink, fontFamily = FontFamily.Monospace, fontSize = 16.sp)
        }
    }
}

@Composable
private fun FieldLabel(text: String, modifier: Modifier = Modifier) {
    Text(text, color = Critter.colors.ink2, fontFamily = Nunito, fontWeight = FontWeight.W800, fontSize = 12.sp, modifier = modifier)
}

@Composable
private fun MacList(macs: List<FoundMac>, selected: FoundMac?, onSelect: (FoundMac) -> Unit) {
    val c = Critter.colors
    Column(
        Modifier
            .fillMaxWidth()
            .pixelSurface(c.surface, step = 4.dp, lip = 4.dp, lipColor = c.shade)
            .padding(top = 4.dp, bottom = 8.dp)
            .selectableGroup(),
    ) {
        if (macs.isEmpty()) {
            Row(
                Modifier.fillMaxWidth().heightIn(min = 52.dp).padding(horizontal = 16.dp, vertical = 10.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                PixelIcon("laptop", tint = c.ink3, cell = 3.dp)
                Text("正在寻找…", color = c.ink2, fontFamily = Nunito, fontWeight = FontWeight.W700, fontSize = 14.sp)
            }
        }
        macs.forEachIndexed { i, mac ->
            if (i > 0) Box(Modifier.fillMaxWidth().height(1.dp).background(c.line))
            val on = selected?.name == mac.name
            Row(
                Modifier
                    .fillMaxWidth()
                    .heightIn(min = 52.dp)
                    .selectable(on, interactionSource = null, indication = null, role = Role.RadioButton) { onSelect(mac) }
                    .padding(horizontal = 16.dp, vertical = 10.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                PixelIcon("laptop", tint = if (on) c.brand else c.ink3, cell = 3.dp)
                Column(Modifier.weight(1f)) {
                    Text(
                        mac.name, color = c.ink, fontFamily = Nunito, fontWeight = FontWeight.W800, fontSize = 15.sp,
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                    Text("${mac.host}:${mac.port}", color = c.ink2, fontFamily = Nunito, fontWeight = FontWeight.W600, fontSize = 12.sp)
                }
                if (on) ChosenChip()
            }
        }
    }
}

@Composable
private fun ChosenChip() {
    val c = Critter.colors
    Row(
        Modifier
            .pixelSurface(c.brandSoft, step = 2.dp, lip = 2.dp, lipColor = c.brand.copy(alpha = 0.18f))
            .heightIn(min = 22.dp)
            .padding(start = 7.dp, end = 7.dp, bottom = 2.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        PixelIcon("check", tint = c.brand)
        Text("已选", color = c.brand, fontFamily = Nunito, fontWeight = FontWeight.W900, fontSize = 11.5.sp)
    }
}

/**
 * The code as eight cells in two groups of four, like the Mac shows it. One invisible text field behind them
 * takes the typing; the cell the next character goes into has the brand edge while focused.
 */
@Composable
private fun CodeCells(code: String, onChange: (String) -> Unit, error: Boolean) {
    val c = Critter.colors
    val source = remember { MutableInteractionSource() }
    val focused by source.collectIsFocusedAsState()
    BasicTextField(
        value = code,
        onValueChange = onChange,
        singleLine = true,
        interactionSource = source,
        keyboardOptions = KeyboardOptions(
            capitalization = KeyboardCapitalization.Characters,
            autoCorrectEnabled = false,
            keyboardType = KeyboardType.Ascii,
            imeAction = ImeAction.Done,
        ),
        textStyle = TextStyle(color = Color.Transparent),
        cursorBrush = SolidColor(Color.Transparent),
        modifier = Modifier.fillMaxWidth().semantics { contentDescription = "Mac 上显示的 $CODE_LENGTH 位码" },
        decorationBox = { inner ->
            Box {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                    for (i in 0 until CODE_LENGTH) {
                        if (i == CODE_LENGTH / 2) Spacer(Modifier.width(10.dp))
                        CodeCell(code.getOrNull(i), active = focused && i == code.length, error = error, Modifier.weight(1f))
                    }
                }
                Box(Modifier.matchParentSize()) { inner() }
            }
        },
    )
}

@Composable
private fun CodeCell(char: Char?, active: Boolean, error: Boolean, modifier: Modifier) {
    val c = Critter.colors
    Box(
        modifier
            .height(48.dp)
            .pixelSurface(
                c.surface, step = 3.dp, lip = 4.dp, lipColor = c.shade,
                border = when {
                    active -> c.brand
                    error -> c.errBg
                    else -> null
                },
                borderWidth = 2.dp,
            )
            .padding(bottom = 4.dp),
        contentAlignment = Alignment.Center,
    ) {
        if (char != null) Text(char.toString(), color = c.ink, fontFamily = Silkscreen, fontSize = 24.sp)
    }
}

// --- errors --------------------------------------------------------------------------------------------------

/** A red card with a wilted Sprig and why it did not work; read out when it appears. */
@Composable
private fun ErrorNote(text: String, modifier: Modifier = Modifier) {
    val c = Critter.colors
    Row(
        modifier
            .fillMaxWidth()
            .pixelSurface(c.errBg, step = 3.dp, lip = 0.dp, lipColor = c.errBg)
            .padding(start = 10.dp, end = 10.dp, top = 8.dp, bottom = 10.dp)
            .semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        LonePet(bundledSkin("sprig"), PetState.error, cell = 2.dp)
        Text(text, color = c.err, fontFamily = Nunito, fontWeight = FontWeight.W700, fontSize = 12.5.sp, lineHeight = 19.sp)
    }
}

private fun hostAndPort(host: String, port: Int) = if (':' in host) "[$host]:$port" else "$host:$port"

/** What the pairing screen says when a pairing attempt fails (design §8.2). */
fun pairFailureText(why: PairFailure): String = when (why) {
    PairFailure.BadCode -> "这个码不对，或者已经过期了。在 Mac 的「添加手机」里点「重新生成」再试。"
    PairFailure.Rejected -> "Mac 上点了「拒绝」。要配对的话重新扫码，这次点「允许」。"
    PairFailure.Protocol -> "这台 Mac 上的 Critter 版本和手机不一致，把两边都更新到最新再试。"
    PairFailure.CertMismatch -> "这台 Mac 的证书和二维码里的不一样，已经停下。确认扫的是你自己的 Mac。"
    PairFailure.NoAnswer -> "Mac 上一直没人点「允许」。回到 Mac 前，重新扫一次码。"
    PairFailure.Unreachable -> "连不上这台 Mac。确认手机和电脑在同一个 Wi‑Fi，并且 Mac 上开着「允许手机连接」。"
}

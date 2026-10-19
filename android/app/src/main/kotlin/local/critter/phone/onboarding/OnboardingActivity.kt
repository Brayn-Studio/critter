package local.critter.phone.onboarding

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import local.critter.core.protocol.PetState
import local.critter.phone.bridge.BridgeRepository
import local.critter.phone.repository
import local.critter.phone.service.BridgeService
import local.critter.phone.ui.look.SkyTime
import local.critter.phone.ui.meadow.PetStage
import local.critter.phone.ui.pairing.PAIRED_STAGE_HEIGHT
import local.critter.phone.ui.pairing.PairingScreen
import local.critter.phone.ui.theme.ButtonKind
import local.critter.phone.ui.theme.ButtonSize
import local.critter.phone.ui.theme.Critter
import local.critter.phone.ui.theme.CritterTheme
import local.critter.phone.ui.theme.Nunito
import local.critter.phone.ui.theme.PixelButton
import local.critter.phone.ui.theme.PixelIcon
import local.critter.phone.ui.theme.PixelShape
import local.critter.phone.ui.theme.Silkscreen
import local.critter.phone.ui.theme.pixelSurface

private const val LOCAL_NETWORK_PERMISSION = "android.permission.ACCESS_LOCAL_NETWORK"

/**
 * First run (spec §8.8, design §8.2): the welcome page, pairing, then the permissions one at a time, then the
 * brand's keep-alive steps. Every step can be skipped, and says what that costs. Opened with
 * [EXTRA_ONLY_KEEP_ALIVE] it shows just the last step (the "保持后台运行" entry in the settings).
 */
class OnboardingActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val repo = repository
        val onlyKeepAlive = intent.getBooleanExtra(EXTRA_ONLY_KEEP_ALIVE, false)
        setContent {
            CritterTheme {
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    Flow(repo, onlyKeepAlive)
                }
            }
        }
    }

    @Composable
    private fun Flow(repo: BridgeRepository, onlyKeepAlive: Boolean) {
        val context = LocalContext.current
        val steps = remember { onboardingSteps(onlyKeepAlive, Build.VERSION.SDK_INT) }
        var index by rememberSaveable { mutableIntStateOf(0) }
        val step = steps[index]

        fun next() {
            if (index + 1 < steps.size) {
                index += 1
            } else {
                if (!onlyKeepAlive) repo.settingsStore.update { it.copy(onboardingDone = true) }
                BridgeService.sync(context, repo)
                setResult(RESULT_OK)
                finish()
            }
        }
        BackHandler { if (index > 0) index -= 1 else finish() }

        // "n / 6" leaves out the welcome page; a lone keep-alive step has no row of seeds.
        val position = stepPosition(steps, step)?.takeIf { it.total > 1 }
        when (step) {
            Step.Welcome -> WelcomePage(onStart = ::next)
            Step.Pair -> PairStep(repo, position, ::next, onBack = { index -= 1 })
            Step.LocalNetwork -> LocalNetworkStep(position, ::next)
            Step.Notifications -> NotificationsStep(position, ::next)
            Step.Overlay -> OverlayStep(position, ::next)
            Step.Battery -> BatteryStep(position, ::next)
            Step.KeepAlive -> KeepAliveStep(position, if (onlyKeepAlive) "完成" else "完成引导", ::next)
        }
    }

    @Composable
    private fun PairStep(repo: BridgeRepository, position: StepPosition?, next: () -> Unit, onBack: () -> Unit) {
        val pairing by repo.pairing.collectAsState()
        val paired = pairing
        if (paired != null) {
            // The same page as "在 Mac 上点「允许」" while pairing, with the pet done.
            StepPage(
                position, "已配对", "已经和 ${paired.macName.ifEmpty { "Mac" }} 配对了。",
                primary = "下一步", onPrimary = next,
            ) { StepStage("sprig", PetState.done, height = PAIRED_STAGE_HEIGHT) }
            return
        }
        PairingScreen(
            repo = repo, deepLink = null, onDeepLinkConsumed = {},
            onPaired = next, onCancel = onBack,
            position = position,
            onSkip = next, skipNote = "之后手机不会连上电脑，要用时在首页配对",
        )
    }

    @Composable
    private fun LocalNetworkStep(position: StepPosition?, next: () -> Unit) {
        val context = LocalContext.current
        fun granted() = ContextCompat.checkSelfPermission(context, LOCAL_NETWORK_PERMISSION) == PackageManager.PERMISSION_GRANTED
        var ok by remember { mutableStateOf(granted()) }
        val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok = it }
        StepPage(
            position, "本地网络",
            "Critter 要通过局域网找到并连接你的 Mac，没有这个权限就找不到它。",
            done = ok,
            primary = if (ok) "下一步" else "允许",
            onPrimary = if (ok) next else ({ launcher.launch(LOCAL_NETWORK_PERMISSION) }),
            ghost = "跳过", onGhost = next, note = "跳过后手机找不到电脑，连接和重连都会失败。",
        ) { StepStage("sprig", if (ok) PetState.done else PetState.idle) }
    }

    @Composable
    private fun NotificationsStep(position: StepPosition?, next: () -> Unit) {
        val context = LocalContext.current
        fun granted() = ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        var ok by remember { mutableStateOf(granted()) }
        val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok = it }
        LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { ok = granted() }
        StepPage(
            position, "通知",
            "有会话在等你确认时，在锁屏和别的应用上面提醒你。常驻通知也会显示连接状态。",
            done = ok,
            primary = if (ok) "下一步" else "允许通知",
            onPrimary = if (ok) next else ({ launcher.launch(Manifest.permission.POST_NOTIFICATIONS) }),
            ghost = "跳过", onGhost = next, note = "跳过后不会收到「等你确认」的提醒，只能打开应用才看得到。",
        ) {
            StepStage("mochi", if (ok) PetState.done else PetState.waiting) {
                SampleNotification(Modifier.align(Alignment.TopCenter).padding(start = 30.dp, end = 30.dp, top = 22.dp))
            }
        }
    }

    @Composable
    private fun OverlayStep(position: StepPosition?, next: () -> Unit) {
        val context = LocalContext.current
        var ok by remember { mutableStateOf(Settings.canDrawOverlays(context)) }
        LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { ok = Settings.canDrawOverlays(context) }
        StepPage(
            position, "悬浮窗",
            "让小人浮在别的应用上面，也让看板能在充电横放时自己打开。授权后在设置里打开「显示悬浮球」。",
            done = ok,
            primary = if (ok) "下一步" else "去授权",
            onPrimary = if (ok) next else ({
                context.startActivity(
                    Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:${context.packageName}")),
                )
            }),
            ghost = "跳过", onGhost = next, note = "跳过后没有悬浮球，看板也不会自己打开；仍然可以手动打开看板。",
        ) { StepStage("peep", if (ok) PetState.done else PetState.idle) }
    }

    @Composable
    private fun BatteryStep(position: StepPosition?, next: () -> Unit) {
        val context = LocalContext.current
        fun ignoring() = context.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(context.packageName)
        var ok by remember { mutableStateOf(ignoring()) }
        LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { ok = ignoring() }
        StepPage(
            position, "忽略电池优化",
            "系统的电池优化会在熄屏后停掉后台连接。允许后，连接更稳；耗电几乎不变，因为只保持一条连接。",
            done = ok,
            primary = if (ok) "下一步" else "去允许",
            onPrimary = if (ok) next else ({
                context.startActivity(
                    Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${context.packageName}")),
                )
            }),
            ghost = "跳过", onGhost = next, note = "跳过后熄屏一段时间，系统可能停掉连接，提醒会晚到或收不到。",
        ) { StepStage("bristle", if (ok) PetState.done else PetState.idle) }
    }

    /**
     * The brand's steps, numbered because their order matters. A step whose page was opened from here counts as
     * done once the user is back (none of them can be read back): its number turns into a check and its button
     * goes. The first step not done is the current one.
     */
    @Composable
    private fun KeepAliveStep(position: StepPosition?, finishLabel: String, next: () -> Unit) {
        val context = LocalContext.current
        val c = Critter.colors
        val guide = remember { OemGuide.forManufacturer(Build.MANUFACTURER) }
        var fellBack by remember { mutableStateOf<String?>(null) }
        var opened by remember { mutableStateOf<Int?>(null) }
        var done by remember { mutableStateOf(emptySet<Int>()) }
        LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
            opened?.let { done = done + it }
            opened = null
        }
        val current = guide.steps.indices.firstOrNull { it !in done }
        Column(Modifier.fillMaxSize().background(c.bg).safeDrawingPadding().padding(horizontal = StepGutter)) {
            if (position != null) SeedRow(position, Modifier.padding(top = 8.dp))
            Column(
                Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(top = 12.dp, bottom = 16.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
                    // Peep asleep in the night meadow: what the phone does with the screen off.
                    PetStage(
                        bundledSkin("peep"), PetState.idle, null,
                        Modifier.size(96.dp, 84.dp).clip(PixelShape(5.dp)),
                        cell = 3.dp, time = SkyTime.Night, groundInset = 14.dp, asleep = true,
                    )
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        StepTitle("保持后台运行", size = 21.sp)
                        StepBody("${guide.brand}：${guide.intro}", size = 13.sp)
                    }
                }
                Spacer(Modifier.height(2.dp))
                guide.steps.forEachIndexed { i, step ->
                    KeepAliveCard(
                        number = i + 1, step = step, done = i in done, current = i == current,
                        fellBack = fellBack == step.title,
                        onOpen = {
                            val specific = OemGuide.open(context, step)
                            fellBack = if (specific) null else step.title
                            opened = i
                        },
                    )
                }
            }
            Column(Modifier.fillMaxWidth().padding(bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                PixelButton(finishLabel, next, Modifier.fillMaxWidth(), size = ButtonSize.Large)
                SkipNote("不设置也能用，只是熄屏一段时间后连接可能被系统停掉，要重新打开应用才会恢复。")
            }
        }
    }

    @Composable
    private fun KeepAliveCard(
        number: Int,
        step: OemGuide.Step,
        done: Boolean,
        current: Boolean,
        fellBack: Boolean,
        onOpen: () -> Unit,
    ) {
        val c = Critter.colors
        Row(
            Modifier
                .fillMaxWidth()
                .pixelSurface(c.surface, step = 4.dp, lip = 4.dp, lipColor = c.shade)
                .padding(start = 14.dp, end = 14.dp, top = 12.dp, bottom = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            val (badgeBg, badgeFg) = when {
                done -> c.doneBg to c.done
                current -> c.brandSoft to c.brand
                else -> c.idleBg to c.ink2
            }
            Box(
                Modifier
                    .size(26.dp)
                    .background(badgeBg)
                    .semantics { contentDescription = if (done) "第 $number 步，已去设置" else "第 $number 步" },
                contentAlignment = Alignment.Center,
            ) {
                if (done) PixelIcon("check", tint = badgeFg) else Text("$number", color = badgeFg, fontFamily = Silkscreen, fontSize = 15.sp)
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(step.title, color = c.ink, fontFamily = Nunito, fontWeight = FontWeight.W800, fontSize = 15.sp, lineHeight = 20.sp)
                Text(step.detail, color = c.ink2, fontFamily = Nunito, fontWeight = FontWeight.W600, fontSize = 12.5.sp, lineHeight = 18.sp)
                if (fellBack) {
                    Text(
                        "这台手机上找不到这一页，已打开应用详情，请在里面或系统设置里找「${step.title}」。",
                        color = c.ink2, fontFamily = Nunito, fontWeight = FontWeight.W600, fontSize = 12.sp, lineHeight = 17.sp,
                    )
                }
                if (!done) {
                    Spacer(Modifier.height(6.dp))
                    PixelButton(
                        if (step.jumps.isEmpty()) "打开应用详情" else "去设置", onOpen,
                        kind = if (current) ButtonKind.Primary else ButtonKind.Secondary, size = ButtonSize.Small,
                    )
                }
            }
        }
    }

    /** The notification the user will get, floating over the notification step's meadow (a system notification's shape). */
    @Composable
    private fun SampleNotification(modifier: Modifier) {
        val c = Critter.colors
        Column(
            modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(14.dp))
                .background(c.surface.copy(alpha = 0.94f))
                .padding(horizontal = 12.dp, vertical = 9.dp)
                .clearAndSetSemantics {},
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(18.dp).clip(CircleShape).background(c.brand), contentAlignment = Alignment.Center) {
                    PixelIcon("seedling", tint = c.onBrand, cell = 1.dp)
                }
                Spacer(Modifier.width(6.dp))
                Text("Critter · 现在", color = c.ink2, fontFamily = Nunito, fontWeight = FontWeight.W700, fontSize = 11.5.sp)
            }
            Text(
                "critter-4c 想运行命令", color = c.ink, fontFamily = Nunito, fontWeight = FontWeight.W800, fontSize = 12.5.sp,
                modifier = Modifier.padding(top = 2.dp),
            )
        }
    }

    companion object {
        const val EXTRA_ONLY_KEEP_ALIVE = "onlyKeepAlive"

        fun intent(context: Context, onlyKeepAlive: Boolean = false): Intent =
            Intent(context, OnboardingActivity::class.java).putExtra(EXTRA_ONLY_KEEP_ALIVE, onlyKeepAlive)
    }
}

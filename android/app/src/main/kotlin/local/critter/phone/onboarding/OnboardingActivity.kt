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
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import local.critter.phone.bridge.BridgeRepository
import local.critter.phone.repository
import local.critter.phone.service.BridgeService
import local.critter.phone.ui.pairing.PairingScreen
import local.critter.phone.ui.theme.CritterTheme

/** The permissions the onboarding steps ask for and what each is for. */
private enum class Step { Pair, LocalNetwork, Notifications, Overlay, Battery, KeepAlive }

private const val LOCAL_NETWORK_PERMISSION = "android.permission.ACCESS_LOCAL_NETWORK"

/**
 * First run (spec §8.8): pair, then the permissions one at a time, then the brand's keep-alive steps. Every
 * step can be skipped, and says what that costs. Opened with [EXTRA_ONLY_KEEP_ALIVE] it shows just the last
 * step (the "保持后台运行" entry in the settings).
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
        val steps = remember {
            if (onlyKeepAlive) listOf(Step.KeepAlive)
            else Step.entries.filter { it != Step.LocalNetwork || Build.VERSION.SDK_INT >= 37 }
                .filter { it != Step.Notifications || Build.VERSION.SDK_INT >= 33 }
        }
        var index by rememberSaveable { mutableIntStateOf(0) }
        val step = steps[index]

        fun next() {
            if (index + 1 < steps.size) {
                index += 1
            } else {
                if (!onlyKeepAlive) repo.settingsStore.update { it.copy(onboardingDone = true) }
                BridgeService.sync(context, repo)
                finish()
            }
        }
        BackHandler { if (index > 0) index -= 1 else finish() }

        val pairing by repo.pairing.collectAsState()
        if (step == Step.Pair) {
            if (pairing != null) {
                Panel(
                    1 to steps.size, "已配对", "已经和 ${pairing?.macName?.ifEmpty { "Mac" } ?: "Mac"} 配对了。",
                    primary = "下一步" to ::next, skip = null, skipNote = null,
                )
            } else {
                Column(Modifier.fillMaxSize()) {
                    PairingScreen(
                        repo = repo, deepLink = null, onDeepLinkConsumed = {},
                        onPaired = ::next, onCancel = null,
                        modifier = Modifier.weight(1f),
                    )
                    HorizontalDivider()
                    TextButton(onClick = ::next, Modifier.align(Alignment.CenterHorizontally)) {
                        Text("跳过：之后手机不会连上电脑，要用时在首页配对")
                    }
                }
            }
            return
        }
        val position = index + 1 to steps.size
        when (step) {
            Step.LocalNetwork -> LocalNetworkStep(position, ::next)
            Step.Notifications -> NotificationsStep(position, ::next)
            Step.Overlay -> OverlayStep(position, ::next)
            Step.Battery -> BatteryStep(position, ::next)
            Step.KeepAlive -> KeepAliveStep(position, if (onlyKeepAlive) "完成" else "完成引导", ::next)
            Step.Pair -> Unit
        }
    }

    @Composable
    private fun LocalNetworkStep(position: Pair<Int, Int>, next: () -> Unit) {
        val context = LocalContext.current
        fun granted() = ContextCompat.checkSelfPermission(context, LOCAL_NETWORK_PERMISSION) == PackageManager.PERMISSION_GRANTED
        var ok by remember { mutableStateOf(granted()) }
        val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok = it }
        Panel(
            position, "本地网络",
            "Critter 要通过局域网找到并连接你的 Mac，没有这个权限就找不到它。",
            done = ok,
            primary = if (ok) "下一步" to next else "允许" to { launcher.launch(LOCAL_NETWORK_PERMISSION) },
            skip = next, skipNote = "跳过后手机找不到电脑，连接和重连都会失败。",
        )
    }

    @Composable
    private fun NotificationsStep(position: Pair<Int, Int>, next: () -> Unit) {
        val context = LocalContext.current
        fun granted() = ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        var ok by remember { mutableStateOf(granted()) }
        val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok = it }
        LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { ok = granted() }
        Panel(
            position, "通知",
            "有会话在等你确认时，在锁屏和别的应用上面提醒你；常驻通知也会显示连接状态。",
            done = ok,
            primary = if (ok) "下一步" to next else "允许" to { launcher.launch(Manifest.permission.POST_NOTIFICATIONS) },
            skip = next, skipNote = "跳过后不会收到「等你确认」的提醒，只能打开应用才看得到。",
        )
    }

    @Composable
    private fun OverlayStep(position: Pair<Int, Int>, next: () -> Unit) {
        val context = LocalContext.current
        var ok by remember { mutableStateOf(Settings.canDrawOverlays(context)) }
        LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { ok = Settings.canDrawOverlays(context) }
        Panel(
            position, "悬浮窗",
            "让小人浮在别的应用上面，也让看板能在充电横放时自己打开。授权后在设置里打开「显示悬浮球」。",
            done = ok,
            primary = if (ok) "下一步" to next else "去授权" to {
                context.startActivity(
                    Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:${context.packageName}")),
                )
            },
            skip = next, skipNote = "跳过后没有悬浮球，看板也不会自己打开；仍然可以手动打开看板。",
        )
    }

    @Composable
    private fun BatteryStep(position: Pair<Int, Int>, next: () -> Unit) {
        val context = LocalContext.current
        fun ignoring() = context.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(context.packageName)
        var ok by remember { mutableStateOf(ignoring()) }
        LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { ok = ignoring() }
        Panel(
            position, "忽略电池优化",
            "系统的电池优化会在熄屏后停掉后台连接。允许后，连接更稳；耗电几乎不变，因为只保持一条连接。",
            done = ok,
            primary = if (ok) "下一步" to next else "去允许" to {
                context.startActivity(
                    Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${context.packageName}")),
                )
            },
            skip = next, skipNote = "跳过后熄屏一段时间，系统可能停掉连接，提醒会晚到或收不到。",
        )
    }

    @Composable
    private fun KeepAliveStep(position: Pair<Int, Int>, finishLabel: String, next: () -> Unit) {
        val context = LocalContext.current
        val guide = remember { OemGuide.forManufacturer(Build.MANUFACTURER) }
        var fellBack by remember { mutableStateOf<String?>(null) }
        Column(Modifier.fillMaxSize().safeDrawingPadding().padding(24.dp)) {
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("${position.first} / ${position.second}", style = MaterialTheme.typography.labelMedium)
                Text("保持后台运行", style = MaterialTheme.typography.headlineSmall)
                Text("${guide.brand}：${guide.intro}", style = MaterialTheme.typography.bodyMedium)
                guide.steps.forEachIndexed { i, step ->
                    HorizontalDivider()
                    Text("${i + 1}. ${step.title}", style = MaterialTheme.typography.titleMedium)
                    Text(step.detail, style = MaterialTheme.typography.bodyMedium)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(onClick = {
                            val specific = OemGuide.open(context, step)
                            fellBack = if (specific) null else step.title
                        }) { Text(if (step.jumps.isEmpty()) "打开应用详情" else "去设置") }
                    }
                    if (fellBack == step.title) {
                        Text(
                            "这台手机上找不到这一页，已打开应用详情，请在里面或系统设置里找「${step.title}」。",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                Text(
                    "不设置也能用，只是熄屏一段时间后连接可能被系统停掉，要重新打开应用才会恢复。",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Button(onClick = next, Modifier.fillMaxWidth()) { Text(finishLabel) }
        }
    }

    @Composable
    private fun Panel(
        position: Pair<Int, Int>,
        title: String,
        body: String,
        done: Boolean = false,
        primary: Pair<String, () -> Unit>,
        skip: (() -> Unit)? = null,
        skipNote: String? = null,
    ) {
        Column(
            Modifier.fillMaxSize().safeDrawingPadding().padding(24.dp),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text("${position.first} / ${position.second}", style = MaterialTheme.typography.labelMedium)
            Text(title, style = MaterialTheme.typography.headlineSmall, modifier = Modifier.padding(top = 8.dp))
            Text(body, modifier = Modifier.padding(vertical = 12.dp))
            if (done) Text("已完成", color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(bottom = 8.dp))
            Button(onClick = primary.second) { Text(primary.first) }
            if (skip != null && !done) {
                TextButton(onClick = skip) { Text("跳过") }
                if (skipNote != null) {
                    Text(skipNote, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }

    companion object {
        const val EXTRA_ONLY_KEEP_ALIVE = "onlyKeepAlive"

        fun intent(context: Context, onlyKeepAlive: Boolean = false): Intent =
            Intent(context, OnboardingActivity::class.java).putExtra(EXTRA_ONLY_KEEP_ALIVE, onlyKeepAlive)
    }
}

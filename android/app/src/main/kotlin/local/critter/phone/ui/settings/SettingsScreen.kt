package local.critter.phone.ui.settings

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import kotlin.math.roundToInt
import local.critter.phone.bridge.BridgeRepository
import local.critter.phone.service.BridgeService
import local.critter.phone.ui.connText

@Composable
fun SettingsScreen(
    repo: BridgeRepository,
    onBack: () -> Unit,
    onRepair: () -> Unit,
    onUnpaired: () -> Unit,
) {
    val context = LocalContext.current
    val settings by repo.settingsStore.settings.collectAsState()
    val state by repo.state.collectAsState()
    val pairing by repo.pairing.collectAsState()
    var ignoring by remember { mutableStateOf(isIgnoringBatteryOptimizations(context)) }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { ignoring = isIgnoringBatteryOptimizations(context) }

    Column(Modifier.fillMaxSize().safeDrawingPadding().verticalScroll(rememberScrollState())) {
        Row(Modifier.fillMaxWidth().padding(start = 8.dp, top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = onBack) { Text("返回") }
            Text("设置", style = MaterialTheme.typography.titleLarge)
        }

        Section("连接")
        Column(Modifier.padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(pairing?.macName?.ifEmpty { "Mac" } ?: "未配对", style = MaterialTheme.typography.bodyLarge)
            Text(connText(state), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        SwitchRow("保持后台连接", "关掉后不再收到提醒，也看不到实时状态", settings.bridgeEnabled) { on ->
            repo.settingsStore.update { it.copy(bridgeEnabled = on) }
            BridgeService.sync(context, repo)
        }
        Row(Modifier.padding(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = onRepair) { Text("重新配对") }
            OutlinedButton(onClick = {
                repo.unpair()
                onUnpaired()
            }) { Text("取消配对") }
        }

        Section("提醒")
        SwitchRow("等你确认时震动", null, settings.vibrateOnWaiting) { on ->
            repo.settingsStore.update { it.copy(vibrateOnWaiting = on) }
        }
        SwitchRow("做完了时通知", null, settings.notifyDone) { on ->
            repo.settingsStore.update { it.copy(notifyDone = on) }
        }
        SwitchRow("出错时通知", null, settings.notifyError) { on ->
            repo.settingsStore.update { it.copy(notifyError = on) }
        }

        Section("看板")
        Column(Modifier.padding(horizontal = 20.dp)) {
            Text("亮度 ${(settings.boardBrightness * 100).roundToInt()}%", style = MaterialTheme.typography.bodyLarge)
            Slider(
                value = settings.boardBrightness,
                onValueChange = { v -> repo.settingsStore.update { it.copy(boardBrightness = v.coerceIn(0.1f, 1f)) } },
                valueRange = 0.1f..1f,
            )
        }

        Section("省电")
        Column(Modifier.padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                if (ignoring) "已忽略电池优化，后台连接不容易被系统停掉。" else "系统的电池优化可能会停掉后台连接。",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (!ignoring) {
                OutlinedButton(onClick = {
                    context.startActivity(
                        Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${context.packageName}")),
                    )
                }) { Text("忽略电池优化") }
            }
        }
    }
}

private fun isIgnoringBatteryOptimizations(context: Context): Boolean =
    context.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(context.packageName)

@Composable
private fun Section(title: String) {
    HorizontalDivider(Modifier.padding(top = 16.dp))
    Text(
        title,
        style = MaterialTheme.typography.labelLarge,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 20.dp, top = 12.dp, bottom = 4.dp),
    )
}

@Composable
private fun SwitchRow(title: String, subtitle: String?, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            subtitle?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        Switch(checked = checked, onCheckedChange = onChange)
    }
}

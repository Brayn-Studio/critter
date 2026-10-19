package local.critter.phone.ui.pairing

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import kotlinx.coroutines.launch
import local.critter.core.net.PairFailure
import local.critter.core.net.PrivateNetwork
import local.critter.core.protocol.PairingUri
import local.critter.phone.bridge.BridgeRepository
import local.critter.phone.bridge.CertProbe
import local.critter.phone.bridge.FoundMac
import local.critter.phone.ui.connText

private enum class Mode { Scan, Manual }

private const val CODE_LENGTH = 8

/**
 * Pairing: scan the QR code the Mac shows (or open its `critter-pair://` link), or pick the Mac from the
 * network and type the code. [deepLink] (a link any web page can open) is shown in a confirmation first, with
 * the Mac's name, address and fingerprint; [onCancel] is null when there is nothing to go back to. Only Macs on
 * the local network are paired with ([PrivateNetwork], the ranges the Mac itself serves).
 */
@Composable
fun PairingScreen(
    repo: BridgeRepository,
    deepLink: PairingUri?,
    onDeepLinkConsumed: () -> Unit,
    onPaired: () -> Unit,
    onCancel: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    var mode by rememberSaveable { mutableStateOf(Mode.Scan) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val pairState by repo.pairState.collectAsState()
    val existing by repo.pairing.collectAsState()
    var linkToConfirm by remember { mutableStateOf<PairingUri?>(null) }

    fun pair(uri: PairingUri) {
        if (busy) return
        if (!PrivateNetwork.isAllowed(uri.host)) {
            error = "地址 ${uri.host} 不在局域网里。Critter 只和同一个局域网里的 Mac 配对。"
            return
        }
        busy = true
        error = null
        scope.launch {
            val why = repo.pair(uri)
            busy = false
            if (why == null) onPaired() else error = pairFailureText(why)
        }
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
        AlertDialog(
            onDismissRequest = cancel,
            title = { Text("和这台 Mac 配对？") },
            text = {
                Column {
                    Text("一个链接要让这台手机和「${uri.name.ifEmpty { "Mac" }}」配对。只在你刚在 Mac 上点了「添加手机」时才继续。")
                    Spacer(Modifier.height(8.dp))
                    Text("地址  ${hostAndPort(uri.host, uri.port)}", style = MaterialTheme.typography.bodySmall)
                    Text(
                        "证书指纹  ${PairingUri.fingerprintPrefix(uri.fingerprint)}",
                        fontFamily = FontFamily.Monospace,
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    Text(
                        "和 Mac 上「添加手机」里码下面的指纹一致时才配对。",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    existing?.let { p ->
                        Spacer(Modifier.height(8.dp))
                        Text(
                            "这会替换现在和「${p.macName.ifEmpty { "Mac" }}」的配对。",
                            color = MaterialTheme.colorScheme.error,
                            style = MaterialTheme.typography.bodyMedium,
                        )
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    linkToConfirm = null
                    pair(uri)
                }) { Text("配对") }
            },
            dismissButton = { OutlinedButton(onClick = cancel) { Text("取消") } },
        )
    }

    Column(modifier.fillMaxSize().safeDrawingPadding().padding(20.dp)) {
        Text("配对 Mac", style = MaterialTheme.typography.headlineSmall)
        Spacer(Modifier.height(4.dp))
        Text(
            "在 Mac 上打开 Critter 的手机连接，按提示显示二维码。",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(16.dp))

        when {
            busy -> Column(
                Modifier.fillMaxWidth().weight(1f),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                CircularProgressIndicator()
                Spacer(Modifier.height(16.dp))
                // "请在 Mac 上点允许" while the Mac is waiting for its user.
                Text(connText(pairState), style = MaterialTheme.typography.titleMedium)
            }

            mode == Mode.Scan -> ScanPane(
                modifier = Modifier.fillMaxWidth().weight(1f),
                onText = { text ->
                    val uri = PairingUri.parse(text)
                    if (uri == null) error = "这不是 Critter 的配对二维码。" else pair(uri)
                },
            )

            else -> ManualPane(
                repo = repo,
                modifier = Modifier.fillMaxWidth().weight(1f),
                onPair = ::pair,
                onProbeFailed = { error = "连不上这台 Mac，换个方式或稍后再试。" },
            )
        }

        error?.let {
            Spacer(Modifier.height(8.dp))
            Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium)
        }
        Spacer(Modifier.height(8.dp))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            if (onCancel != null) TextButton(onClick = onCancel, enabled = !busy) { Text("返回") } else Spacer(Modifier.height(1.dp))
            TextButton(
                onClick = { error = null; mode = if (mode == Mode.Scan) Mode.Manual else Mode.Scan },
                enabled = !busy,
            ) { Text(if (mode == Mode.Scan) "手动输入" else "扫码") }
        }
    }
}

@Composable
private fun ScanPane(modifier: Modifier, onText: (String) -> Unit) {
    val context = LocalContext.current
    var granted by remember {
        mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED)
    }
    var denied by remember { mutableStateOf(false) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        granted = it
        denied = !it
    }
    LaunchedEffect(Unit) { if (!granted) launcher.launch(Manifest.permission.CAMERA) }

    Box(modifier.clip(RoundedCornerShape(16.dp)), contentAlignment = Alignment.Center) {
        if (granted) {
            QrScanner(onResult = onText, modifier = Modifier.fillMaxSize())
        } else {
            Column(Modifier.padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(
                    if (denied) "扫码需要相机权限。你可以在系统设置里打开它，或者改用手动输入。" else "需要相机权限来扫描二维码。",
                    style = MaterialTheme.typography.bodyMedium,
                )
                Spacer(Modifier.height(12.dp))
                if (denied) {
                    Button(onClick = {
                        context.startActivity(
                            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}")),
                        )
                    }) { Text("去设置") }
                } else {
                    Button(onClick = { launcher.launch(Manifest.permission.CAMERA) }) { Text("允许使用相机") }
                }
            }
        }
    }
}

@Composable
private fun ManualPane(
    repo: BridgeRepository,
    modifier: Modifier,
    onPair: (PairingUri) -> Unit,
    onProbeFailed: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val macs by produceState(emptyList<FoundMac>()) {
        repo.nsd.browse().collect { found -> value = value.filter { it.name != found.name } + found }
    }
    var selected by remember { mutableStateOf<FoundMac?>(null) }
    var code by rememberSaveable { mutableStateOf("") }
    var probing by remember { mutableStateOf(false) }
    var confirm by remember { mutableStateOf<Pair<FoundMac, String>?>(null) }

    Column(modifier) {
        Text("局域网里的 Mac", style = MaterialTheme.typography.titleSmall)
        Spacer(Modifier.height(8.dp))
        if (macs.isEmpty()) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.height(20.dp))
                Spacer(Modifier.padding(4.dp))
                Text("正在寻找…", style = MaterialTheme.typography.bodyMedium)
            }
        }
        LazyColumn(Modifier.weight(1f)) {
            items(macs, key = { it.name }) { mac ->
                Row(
                    Modifier.fillMaxWidth().clickable { selected = mac }.padding(vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(if (selected?.name == mac.name) "●" else "○")
                    Spacer(Modifier.padding(6.dp))
                    Column {
                        Text(mac.name, style = MaterialTheme.typography.bodyLarge)
                        Text("${mac.host}:${mac.port}", style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
        }
        OutlinedTextField(
            value = code,
            onValueChange = { code = it.uppercase().filter { c -> c.isLetterOrDigit() }.take(CODE_LENGTH) },
            label = { Text("电脑上显示的 $CODE_LENGTH 位码") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(12.dp))
        Button(
            enabled = selected != null && code.length == CODE_LENGTH && !probing,
            onClick = {
                val mac = selected ?: return@Button
                probing = true
                scope.launch {
                    val fp = CertProbe.fingerprint(mac.host, mac.port)
                    probing = false
                    if (fp == null) onProbeFailed() else confirm = mac to fp
                }
            },
            modifier = Modifier.fillMaxWidth(),
        ) { Text(if (probing) "正在连接…" else "连接") }
    }

    confirm?.let { (mac, fp) ->
        AlertDialog(
            onDismissRequest = { confirm = null },
            title = { Text("信任这台 Mac？") },
            text = {
                Column {
                    Text("第一次连接「${mac.name}」。只有下面的证书指纹和 Mac 上「添加手机」里码下面显示的一致时才继续：")
                    Spacer(Modifier.height(8.dp))
                    Text(
                        PairingUri.fingerprintPrefix(fp),
                        fontFamily = FontFamily.Monospace,
                        style = MaterialTheme.typography.titleMedium,
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    confirm = null
                    onPair(PairingUri(mac.host, mac.port, fp, code, mac.name))
                }) { Text("信任并配对") }
            },
            dismissButton = { OutlinedButton(onClick = { confirm = null }) { Text("取消") } },
        )
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

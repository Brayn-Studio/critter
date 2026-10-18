package local.critter.phone.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
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
import local.critter.core.protocol.PairingUri
import local.critter.phone.bridge.BridgeRepository
import local.critter.phone.repository
import local.critter.phone.service.BridgeService
import local.critter.phone.ui.answer.AnswerActivity
import local.critter.phone.ui.board.BoardActivity
import local.critter.phone.ui.home.HomeScreen
import local.critter.phone.ui.pairing.PairingScreen
import local.critter.phone.ui.settings.SettingsScreen
import local.critter.phone.ui.theme.CritterTheme

private const val LOCAL_NETWORK_PERMISSION = "android.permission.ACCESS_LOCAL_NETWORK"

class MainActivity : ComponentActivity() {
    private var deepLink by mutableStateOf<PairingUri?>(null)

    /** True while the pairing screen is wanted even though a pairing exists (re-pairing, or a link was opened). */
    private var repairing by mutableStateOf(false)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        pairingUriOf(intent)?.let { openLink(it) }
        val repo = repository
        setContent {
            CritterTheme {
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    LocalNetworkGate {
                        App(repo)
                    }
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        pairingUriOf(intent)?.let { openLink(it) }
    }

    private fun openLink(uri: PairingUri) {
        deepLink = uri
        repairing = true
    }

    override fun onStart() {
        super.onStart()
        // Opening the app is a good moment to make sure the connection service is up.
        BridgeService.sync(this, repository)
    }

    private fun pairingUriOf(intent: Intent?): PairingUri? = intent?.dataString?.let(PairingUri::parse)

    @Composable
    private fun App(repo: BridgeRepository) {
        val pairing by repo.pairing.collectAsState()
        var settingsOpen by rememberSaveable { mutableStateOf(false) }
        val askNotifications = rememberNotificationPermissionRequest()
        val link = deepLink

        if (pairing == null || repairing) {
            PairingScreen(
                repo = repo,
                deepLink = link,
                onDeepLinkConsumed = { deepLink = null },
                onPaired = {
                    repairing = false
                    settingsOpen = false
                    askNotifications()
                },
                onCancel = if (pairing != null) ({ repairing = false }) else null,
            )
        } else if (settingsOpen) {
            BackHandler { settingsOpen = false }
            SettingsScreen(
                repo = repo,
                onBack = { settingsOpen = false },
                onRepair = { settingsOpen = false; repairing = true },
                onUnpaired = { settingsOpen = false; repairing = false },
            )
        } else {
            HomeScreen(
                repo = repo,
                onOpenSettings = { settingsOpen = true },
                onOpenBoard = { startActivity(Intent(this, BoardActivity::class.java)) },
                onOpenRequest = { startActivity(AnswerActivity.intent(this, it)) },
            )
        }
    }
}

/** Asks for the notification permission (API 33+) when called, if it is not granted yet. */
@Composable
private fun rememberNotificationPermissionRequest(): () -> Unit {
    val context = LocalContext.current
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {}
    return remember(launcher) {
        {
            if (Build.VERSION.SDK_INT >= 33 &&
                ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
                PackageManager.PERMISSION_GRANTED
            ) {
                launcher.launch(Manifest.permission.POST_NOTIFICATIONS)
            }
        }
    }
}

/** On API 37+ nothing on the LAN can be reached without this permission, so ask before showing anything. */
@Composable
private fun LocalNetworkGate(content: @Composable () -> Unit) {
    if (Build.VERSION.SDK_INT < 37) {
        content()
        return
    }
    val context = LocalContext.current
    fun check() = ContextCompat.checkSelfPermission(context, LOCAL_NETWORK_PERMISSION) == PackageManager.PERMISSION_GRANTED
    var granted by remember { mutableStateOf(check()) }
    var asked by rememberSaveable { mutableStateOf(false) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        granted = it
        asked = true
    }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { granted = check() }

    if (granted) {
        content()
        return
    }
    Column(
        Modifier.fillMaxSize().safeDrawingPadding().padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("需要访问本地网络", style = MaterialTheme.typography.headlineSmall)
        Text(
            "Critter 要通过局域网连接你的 Mac。没有这个权限就找不到它。",
            modifier = Modifier.padding(vertical = 12.dp),
        )
        Button(onClick = { launcher.launch(LOCAL_NETWORK_PERMISSION) }) { Text("允许") }
        if (asked) {
            TextButton(onClick = {
                context.startActivity(
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}")),
                )
            }) { Text("去设置") }
        }
    }
}

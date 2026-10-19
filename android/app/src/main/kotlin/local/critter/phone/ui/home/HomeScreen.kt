package local.critter.phone.ui.home

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
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
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import local.critter.core.logic.LimitsText
import local.critter.core.net.ConnState
import local.critter.core.protocol.BridgeLimits
import local.critter.core.protocol.BridgePending
import local.critter.core.protocol.BridgeSession
import local.critter.core.protocol.PetState
import local.critter.core.protocol.RateWindow
import local.critter.phone.bridge.BridgeRepository
import local.critter.phone.ui.agoText
import local.critter.phone.ui.connText
import local.critter.phone.ui.contextFraction
import local.critter.phone.ui.contextPercentText
import local.critter.phone.ui.doingText
import local.critter.phone.ui.folderBranch
import local.critter.phone.ui.rememberMinuteClock
import local.critter.phone.ui.sourceLabel
import local.critter.phone.ui.stateColor
import local.critter.phone.ui.stateLabel
import local.critter.phone.ui.theme.WaitingOrange
import java.time.ZoneId

@Composable
fun HomeScreen(
    repo: BridgeRepository,
    onOpenSettings: () -> Unit,
    onOpenBoard: () -> Unit,
    onOpenRequest: (requestId: String) -> Unit,
    onOpenDetail: (sessionId: String) -> Unit,
    onRepair: () -> Unit,
) {
    val state by repo.state.collectAsState()
    val snapshot by repo.snapshot.collectAsState()
    val pairing by repo.pairing.collectAsState()
    val updatedAt by repo.lastUpdated.collectAsState()
    val now by rememberMinuteClock()
    val scope = rememberCoroutineScope()

    val body = snapshot
    val sessions = body?.let { local.critter.core.logic.SessionOrder.forBoard(it) }.orEmpty()
    val oldestRequest = body?.pending.orEmpty().groupBy { it.sessionId }.mapValues { (_, r) -> r.minBy { it.createdAt } }

    Column(Modifier.fillMaxSize().safeDrawingPadding()) {
        Row(
            Modifier.fillMaxWidth().padding(start = 20.dp, end = 8.dp, top = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text(pairing?.macName?.ifEmpty { "Mac" } ?: "Mac", style = MaterialTheme.typography.titleLarge)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        Modifier.size(8.dp).clip(CircleShape)
                            .background(if (state is ConnState.Connected) stateColor(PetState.done) else stateColor(PetState.idle)),
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(connText(state), style = MaterialTheme.typography.bodyMedium)
                    if (state !is ConnState.Connected) updatedAt?.let {
                        Text(" · ${agoText(it, now)}", style = MaterialTheme.typography.bodyMedium)
                    }
                }
            }
            TextButton(onClick = onOpenBoard) { Text("看板") }
            TextButton(onClick = onOpenSettings) { Text("设置") }
        }

        // Retrying cannot help (wrong certificate, revoked on the Mac): the way out is right here, not in the settings.
        if (state is ConnState.NeedsRepair) {
            Button(onClick = onRepair, modifier = Modifier.padding(start = 20.dp, top = 8.dp)) { Text("重新配对") }
        }

        LimitsRow(body?.limits, now, Modifier.padding(horizontal = 20.dp, vertical = 12.dp))

        if (sessions.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(
                    if (state is ConnState.Connected) "电脑上还没有会话" else "还没有数据",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        } else {
            LazyColumn(
                Modifier.fillMaxSize(),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp, vertical = 4.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                items(sessions, key = { it.id }) { session ->
                    val request = oldestRequest[session.id]
                    // Like a tap on a Critter (SessionTap): a request opens its card; anything else the details,
                    // and a finished session is marked seen on the way.
                    SessionRow(session, request) {
                        if (request != null) {
                            onOpenRequest(request.requestId)
                        } else {
                            if (session.state == PetState.done) scope.launch { repo.seen(session.id) }
                            onOpenDetail(session.id)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun LimitsRow(limits: BridgeLimits?, now: Long, modifier: Modifier) {
    Column(modifier) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            LimitCard("5 小时额度", limits?.fiveHour, now, Modifier.weight(1f))
            LimitCard("7 天额度", limits?.sevenDay, now, Modifier.weight(1f))
        }
        limits?.let { LimitsText.staleness(it.updatedAt, now) }?.let {
            Text(
                "额度更新于 $it",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 4.dp),
            )
        }
    }
}

@Composable
private fun LimitCard(title: String, window: RateWindow?, now: Long, modifier: Modifier) {
    Card(modifier, colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)) {
        Column(Modifier.padding(12.dp)) {
            Text(title, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(LimitsText.percent(window), style = MaterialTheme.typography.headlineSmall)
            Text(
                LimitsText.resets(window, now, ZoneId.systemDefault()),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun SessionRow(session: BridgeSession, request: BridgePending?, onClick: () -> Unit) {
    Card(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick),
        shape = RoundedCornerShape(14.dp),
        border = if (request != null) BorderStroke(2.dp, WaitingOrange) else null,
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
    ) {
        Column(Modifier.padding(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(10.dp).clip(CircleShape).background(stateColor(session.state)))
                Spacer(Modifier.width(8.dp))
                Text(
                    session.name,
                    style = MaterialTheme.typography.titleMedium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                Text(stateLabel(session.state), style = MaterialTheme.typography.labelMedium, color = stateColor(session.state))
            }
            Text(
                "${sourceLabel(session.source)} · ${doingText(session)}",
                style = MaterialTheme.typography.bodyMedium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(top = 4.dp),
            )
            Text(
                folderBranch(session),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            session.context?.let { c ->
                Row(Modifier.padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    LinearProgressIndicator(
                        progress = { contextFraction(c) },
                        modifier = Modifier.weight(1f).height(4.dp).clip(RoundedCornerShape(2.dp)),
                    )
                    Text(
                        "  ${contextPercentText(c)}",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

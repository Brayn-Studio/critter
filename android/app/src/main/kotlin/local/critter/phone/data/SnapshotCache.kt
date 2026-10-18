package local.critter.phone.data

import android.content.Context
import kotlinx.serialization.Serializable
import local.critter.core.protocol.BridgeJson
import local.critter.core.protocol.SnapshotBody
import java.io.File

/** The last snapshot received, kept in a private file so the app has something to show while offline. */
class SnapshotCache(context: Context) {
    private val dir = context.applicationContext.filesDir
    private val file = File(dir, "snapshot.json")

    @Serializable
    private class Stored(val savedAt: Long, val body: SnapshotBody)

    /** The cached snapshot and when it was saved, or null if there is none or it cannot be read. */
    fun load(): Pair<SnapshotBody, Long>? = try {
        if (!file.exists()) null
        else BridgeJson.decodeFromString(Stored.serializer(), file.readText()).let { it.body to it.savedAt }
    } catch (_: Exception) {
        null
    }

    @Synchronized
    fun save(body: SnapshotBody, savedAt: Long) {
        try {
            val tmp = File(dir, "snapshot.json.tmp")
            tmp.writeText(BridgeJson.encodeToString(Stored.serializer(), Stored(savedAt, body)))
            if (!tmp.renameTo(file)) file.writeText(tmp.readText())
        } catch (_: Exception) {
            // The cache is a convenience; losing a write is harmless.
        }
    }

    @Synchronized
    fun clear() {
        file.delete()
    }
}

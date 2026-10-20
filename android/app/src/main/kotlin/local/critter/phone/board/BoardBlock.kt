package local.critter.phone.board

/**
 * Why the board did not open by itself, remembered next to the time (`PhoneSettings.boardBlockedBy`) so the
 * settings and the notification name the switch that would help.
 */
enum class BoardBlock {
    /** No "display over other apps": nothing opens from the background without it, so it was not even tried. */
    NoOverlayPermission,

    /** The system refused it: the start threw, or nothing came up within 2 s (vivo's and Xiaomi's "background pop-up"). */
    BackgroundPopup;

    companion object {
        /** A stored name back. A block stored before its cause was (or an unknown name) is [BackgroundPopup], all the app said then. */
        fun parse(name: String?): BoardBlock = entries.firstOrNull { it.name == name } ?: BackgroundPopup
    }
}

/** Where a block's button leads: the "display over other apps" page, or the app's details (its permissions). */
enum class BlockFix { OverlayPermission, AppDetails }

/** What the settings notice and the notification say about a [BoardBlock], and where their buttons lead. */
data class BlockAdvice(
    val notice: String,
    val noticeAction: String,
    val notification: String,
    val notificationAction: String,
    val fix: BlockFix,
)

private const val NO_OVERLAY = "还没有「显示在其他应用上层」权限，看板打不开。"

fun blockAdvice(block: BoardBlock): BlockAdvice = when (block) {
    BoardBlock.NoOverlayPermission -> BlockAdvice(
        notice = NO_OVERLAY, noticeAction = "去授权",
        notification = NO_OVERLAY, notificationAction = "去授权",
        fix = BlockFix.OverlayPermission,
    )
    BoardBlock.BackgroundPopup -> BlockAdvice(
        notice = "上次插电时被系统拦下了。vivo、小米等手机要在应用权限里打开「后台弹出界面」。", noticeAction = "去打开",
        notification = "系统拦下了后台弹出的界面。打开「后台弹出界面」后，下次插电就能自动打开。", notificationAction = "去设置",
        fix = BlockFix.AppDetails,
    )
}

/**
 * The block the settings still tell about: none once it was cleared ([blockedAt] null), and a missing permission
 * no longer once it has been granted.
 */
fun pendingBlock(blockedAt: Long?, block: BoardBlock, canOverlay: Boolean): BoardBlock? = when {
    blockedAt == null -> null
    block == BoardBlock.NoOverlayPermission && canOverlay -> null
    else -> block
}

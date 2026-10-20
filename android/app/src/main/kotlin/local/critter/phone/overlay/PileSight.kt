package local.critter.phone.overlay

/**
 * Why the floating pile's content may be hidden ([OverlayController]): [boardUp] (it sinks out of sight while the
 * board is up; [sinkingForBoard] while that plays), [fullscreen] (a full-screen app, with "全屏应用里隐藏" on),
 * [emptyAndAutoHide] (nothing to show, with "没有会话时隐藏" on).
 */
internal data class PileHiding(
    val boardUp: Boolean,
    val sinkingForBoard: Boolean,
    val fullscreen: Boolean,
    val emptyAndAutoHide: Boolean,
) {
    /** The content is shown (it can still be out of sight: the screen off or locked). */
    val shown: Boolean get() = !(boardUp && !sinkingForBoard) && !fullscreen && !emptyAndAutoHide

    /**
     * Shown, or would be but for the board. The board is what makes the screen full while it is up, so the
     * full-screen rule does not count under it.
     */
    val shownButForBoard: Boolean get() = !(fullscreen && !boardUp) && !emptyAndAutoHide
}

/**
 * Whether the user can see the requests (spec §8.7): on the pile, or on the board standing in for a pile that would
 * show. Notifications wait meanwhile. With the pile switched off ([pileOn] false) the board holds nothing back.
 * [screenInUse]: the screen is on and unlocked.
 */
internal fun requestsInSight(pileOn: Boolean, screenInUse: Boolean, hiding: PileHiding): Boolean =
    pileOn && screenInUse && hiding.shownButForBoard

package local.critter.phone

import local.critter.phone.board.BlockFix
import local.critter.phone.board.BoardBlock
import local.critter.phone.board.blockAdvice
import local.critter.phone.board.pendingBlock
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class BoardBlockTest {
    @Test fun storedNamesComeBack() {
        for (b in BoardBlock.entries) assertEquals(b, BoardBlock.parse(b.name))
    }

    /** Stored before the cause was, or garbled: the background pop-up, which is all the app said then. */
    @Test fun aMissingOrUnknownCauseIsTheBackgroundPopUp() {
        assertEquals(BoardBlock.BackgroundPopup, BoardBlock.parse(null))
        assertEquals(BoardBlock.BackgroundPopup, BoardBlock.parse("Sideways"))
    }

    /** No "display over other apps": the advice is that permission and its page, not the OEM switch. */
    @Test fun aMissingPermissionAsksForThePermission() {
        val a = blockAdvice(BoardBlock.NoOverlayPermission)
        assertEquals("还没有「显示在其他应用上层」权限，看板打不开。", a.notice)
        assertEquals("去授权", a.noticeAction)
        assertEquals("还没有「显示在其他应用上层」权限，看板打不开。", a.notification)
        assertEquals("去授权", a.notificationAction)
        assertEquals(BlockFix.OverlayPermission, a.fix)
    }

    @Test fun aRefusalPointsAtTheBackgroundPopUpSwitch() {
        val a = blockAdvice(BoardBlock.BackgroundPopup)
        assertEquals("上次插电时被系统拦下了。vivo、小米等手机要在应用权限里打开「后台弹出界面」。", a.notice)
        assertEquals("去打开", a.noticeAction)
        assertEquals("系统拦下了后台弹出的界面。打开「后台弹出界面」后，下次插电就能自动打开。", a.notification)
        assertEquals("去设置", a.notificationAction)
        assertEquals(BlockFix.AppDetails, a.fix)
    }

    @Test fun theSettingsTellOnlyABlockThatStillHolds() {
        // Cleared: nothing, whatever the cause was.
        assertNull(pendingBlock(null, BoardBlock.NoOverlayPermission, canOverlay = false))
        assertNull(pendingBlock(null, BoardBlock.BackgroundPopup, canOverlay = true))
        // A missing permission until it is granted.
        assertEquals(BoardBlock.NoOverlayPermission, pendingBlock(1L, BoardBlock.NoOverlayPermission, canOverlay = false))
        assertNull(pendingBlock(1L, BoardBlock.NoOverlayPermission, canOverlay = true))
        // A refusal until the board opens by itself again: the permission does not say whether the switch is on.
        assertEquals(BoardBlock.BackgroundPopup, pendingBlock(1L, BoardBlock.BackgroundPopup, canOverlay = true))
        assertEquals(BoardBlock.BackgroundPopup, pendingBlock(1L, BoardBlock.BackgroundPopup, canOverlay = false))
    }
}

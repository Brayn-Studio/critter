package local.critter.phone

import local.critter.phone.onboarding.OemGuide
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class OemGuideTest {
    private fun titles(manufacturer: String) = OemGuide.forManufacturer(manufacturer).steps.map { it.title }

    @Test fun vivoCoversTheTogglesThatStopTheFreeze() {
        val t = titles("vivo")
        listOf("自启动", "允许后台高耗电", "后台弹出界面", "在最近任务里锁定", "后台冻结").forEach { assertTrue(it in t, it) }
        assertEquals(t, titles("VIVO"))
        assertEquals(t, titles("iQOO"))
    }

    @Test fun brandsShareTheirGuides() {
        assertEquals(titles("xiaomi"), titles("Redmi"))
        assertEquals(titles("OPPO"), titles("realme"))
        assertEquals(titles("OnePlus"), titles("oppo"))
        assertEquals(titles("huawei"), titles("HONOR"))
    }

    @Test fun unknownBrandOnlyGuidesBatteryOptimization() {
        assertEquals(listOf("关闭电池优化"), titles("Google"))
        assertEquals("你的手机", OemGuide.forManufacturer("").brand)
    }

    @Test fun xiaomiHasTheAutostartPage() {
        val jumps = OemGuide.forManufacturer("xiaomi").steps.first { it.title == "自启动" }.jumps
        assertEquals(
            "com.miui.securitycenter/com.miui.permcenter.autostart.AutoStartManagementActivity",
            jumps.first().component,
        )
    }
}

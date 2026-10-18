package local.critter.phone.onboarding

import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings

/**
 * The per-brand steps that keep the connection alive with the screen off (spec §8.8). Brands add their own
 * freezer on top of Android's battery optimization, so the steps differ; each may carry system pages worth
 * trying to jump to ([Step.jumps], tried in order). Whatever fails falls back to this app's details page.
 */
object OemGuide {
    /** A page to try: an explicit activity ("package/class"), or a system settings action. */
    data class Jump(val component: String? = null, val action: String? = null)

    class Step(val title: String, val detail: String, val jumps: List<Jump> = emptyList())

    class Guide(val brand: String, val intro: String, val steps: List<Step>)

    fun forManufacturer(manufacturer: String): Guide = when (val m = manufacturer.trim().lowercase()) {
        "vivo", "iqoo" -> vivo()
        "xiaomi", "redmi", "poco" -> xiaomi()
        "oppo", "oneplus", "realme" -> oppo()
        "huawei", "honor" -> huawei()
        "samsung" -> samsung()
        else -> generic(m)
    }

    private fun vivo() = Guide(
        "vivo",
        "熄屏后 vivo 会把整个应用冻结（日志里是 this package has been frozen），连接会断。下面几项都要打开，缺一项都可能被冻结。",
        listOf(
            Step(
                "自启动", "在「自启动」里打开 Critter。",
                listOf(
                    Jump("com.vivo.permissionmanager/.activity.BgStartUpManagerActivity"),
                    Jump("com.vivo.permissionmanager/com.vivo.permissionmanager.activity.BgStartUpManagerActivity"),
                    Jump("com.iqoo.secure/.ui.phoneoptimize.BgStartUpManager"),
                ),
            ),
            Step(
                "允许后台高耗电", "在「电池」的「后台耗电管理」里，把 Critter 设为「允许后台高耗电」。",
                listOf(
                    Jump("com.vivo.abe/.unifiedpower.HighPowerConsumptionActivity"),
                    Jump("com.iqoo.powersaving/.PowerSavingManagerActivity"),
                ),
            ),
            Step(
                "后台弹出界面", "在「权限管理」的「后台弹出界面」里允许 Critter，否则看板不能在充电横放时自己打开。",
                listOf(Jump("com.vivo.permissionmanager/.activity.PurviewTabActivity")),
            ),
            Step(
                "在最近任务里锁定", "打开最近任务，把 Critter 的卡片往下拉（或点卡片上的锁）锁住，清理内存时就不会被关掉。",
            ),
            Step(
                "后台冻结", "如果「电池」或「应用管理」里有「后台冻结」或「应用冻结」的开关，把 Critter 排除在外。没有这一项就不用管。",
            ),
        ),
    )

    private fun xiaomi() = Guide(
        "小米 / 红米",
        "小米会限制后台自启和省电策略，下面几项都要设置。",
        listOf(
            Step(
                "自启动", "打开 Critter 的自启动。",
                listOf(Jump("com.miui.securitycenter/com.miui.permcenter.autostart.AutoStartManagementActivity")),
            ),
            Step(
                "省电策略", "在应用详情的「省电策略」里选「无限制」。",
                listOf(Jump("com.miui.powerkeeper/.ui.HiddenAppsConfigActivity")),
            ),
            Step("后台弹出界面", "在应用详情的「其他权限」里允许「后台弹出界面」和「显示悬浮窗」。"),
            Step("锁定最近任务", "打开最近任务，长按 Critter 的卡片，点锁形图标。"),
        ),
    )

    private fun oppo() = Guide(
        "OPPO / 一加 / realme",
        "ColorOS 会清理后台应用，下面几项都要设置。",
        listOf(
            Step(
                "自启动", "打开 Critter 的自启动。",
                listOf(
                    Jump("com.coloros.safecenter/.startupapp.StartupAppListActivity"),
                    Jump("com.oplus.battery/.startupapp.StartupAppListActivity"),
                ),
            ),
            Step("允许后台运行", "在应用详情的「耗电管理」里打开「允许后台运行」。"),
            Step("关闭电池优化", "在应用详情的「耗电管理」里选「不限制」，不要让系统优化它。"),
            Step("锁定最近任务", "打开最近任务，点 Critter 卡片上的菜单，选「锁定」。"),
            Step("悬浮窗", "在应用详情的权限里允许「显示在其他应用上层」。"),
        ),
    )

    private fun huawei() = Guide(
        "华为 / 荣耀",
        "EMUI / MagicOS 默认会自动管理后台，要改成手动。",
        listOf(
            Step(
                "应用启动管理", "在「电池」的「应用启动管理」里找到 Critter，改为手动管理，把自启动、关联启动、后台活动三个开关全部打开。",
                listOf(
                    Jump("com.huawei.systemmanager/.startupmgr.ui.StartupNormalAppListActivity"),
                    Jump("com.huawei.systemmanager/.optimize.process.ProtectActivity"),
                ),
            ),
        ),
    )

    private fun samsung() = Guide(
        "三星",
        "One UI 会让不常用的应用休眠。",
        listOf(
            Step(
                "电池不受限制", "在「电池」的「后台使用限制」里，把 Critter 设为「不受限制」。",
                listOf(Jump("com.samsung.android.lool/com.samsung.android.sm.ui.battery.BatteryActivity")),
            ),
            Step("永不休眠的应用", "把 Critter 加入「永不休眠的应用」，并关闭「自动停用未使用的应用」。"),
        ),
    )

    private fun generic(manufacturer: String) = Guide(
        manufacturer.ifEmpty { "你的手机" },
        "这个品牌没有专门的步骤，关掉电池优化通常就够了。",
        listOf(
            Step(
                "关闭电池优化", "允许 Critter 忽略电池优化。",
                listOf(Jump(action = Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)),
            ),
        ),
    )

    /**
     * Opens the first page of [step] that exists on this phone; if none does, this app's details page. Returns
     * whether a brand-specific page opened (false: the fallback, which the screen can say).
     */
    fun open(context: Context, step: Step): Boolean {
        for (jump in step.jumps) {
            val intent = jump.intent() ?: continue
            if (tryStart(context, intent)) return true
        }
        openAppDetails(context)
        return false
    }

    fun openAppDetails(context: Context) {
        tryStart(
            context,
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}")),
        )
    }

    private fun Jump.intent(): Intent? = when {
        component != null -> ComponentName.unflattenFromString(component)?.let { Intent().setComponent(it) }
        action != null -> Intent(action)
        else -> null
    }

    private fun tryStart(context: Context, intent: Intent): Boolean = try {
        context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        true
    } catch (_: ActivityNotFoundException) {
        false
    } catch (_: SecurityException) {
        false // not exported on this version
    }
}

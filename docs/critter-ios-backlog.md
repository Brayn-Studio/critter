# Critter iOS 版待办

iOS 计划 1（`docs/superpowers/plans/2026-10-24-critter-ios-1-skeleton.md`）、计划 2（`2026-10-24-critter-ios-2-critters-board-visual.md`，宠物、看板和像素外观）和计划 3（`2026-10-24-critter-ios-3-mac-push.md`，Mac 端推送）做完时，各轮审查留下、判定放到后面处理的事项。按要落到的计划分组，写后面的计划时逐条认领。计划 2 已经做完的条目（计划 2 一组、前端优化轮里的四条）已经删掉。

## iOS 推送与扩展计划（App Group）

- **首次引导（欢迎页）**：计划 2 没做（它属于推送计划，spec §14 第 5 步）。
- **设置里计划 2 没做的行**：提醒和推送、实时活动、电池和保活、"看板被系统拦下"的提示、"保持后台连接"。草图里有，其中有些只属于 Android。草图的「悬浮球」一组 iOS 不做：iOS 不允许 App 画在其他 App 上面，由实时活动代替（spec §8.5）。
- 自动打开看板时如果配对页开着（`RootView` 里没有首页），看板打不开，触发器 2 秒后报 `.blocked`，本次充电不再试。推送带来"点通知进入"之后，这条路径会常见，要有处理。
- **真的往 APNs 发一条**（计划 3 只用假的传输层测过）：用户给 `.p8`、在开发者账号里给 App ID 开推送后，从 Mac 设置里"发送测试通知"。同时验证这台 Mac 访问 `api.sandbox.push.apple.com` 要不要走代理（spec §13.6）：Mac 用 `URLSession`，只认系统的代理设置，不认命令行用的 127.0.0.1:1082。
- **实时活动的推送 token 能不能在后台送回 Mac**（spec §13.1）：push-to-start 启动后，App 在后台被唤醒时能不能连上 Mac，把 `activityToken` 用推送登记送过去。不行就改用 iOS 18 的广播频道，或者只在前台启动。Mac 这边现在的做法：启动一次后等 token，拿不到就不再启动，活动停在旧内容（15 分钟后变灰），直到 7.5 小时或会话全部结束 5 分钟后。
- Mac 端的联机检查（计划 3 推迟到合回 `main` 之后，因为要运行这条线构建的 Critter.app，会替换用户正在用的那个）：用 `critter-bridge-client` 配一台临时设备，`push --token <64 个 0> --done` 后 `~/.critter/bridge/devices.json` 里有这份登记、权限仍是 0600，设置里这台设备后面有"推送"标签；`push --clear` 后登记消失；没有 `.p8` 时设置显示"未配置"，`~/.critter/app.json` 的 `pushReachable` 为 false；`scripts/dev/e2e-phone.sh` 照常通过；最后撤销这台临时设备。
- App 的 `ActivityAttributes` 类型要叫 `CritterActivity`：Mac 的 push-to-start 写的是 `LiveActivityContent.attributesName`。
- App 的 bundle id 定下来后，核对 Mac 设置里的默认值 `com.braynlabs.critter`。Mac 只给登记的 `bundleId` 和设置一致的 iPhone 推送（不一致时设置里写"登记了的 iPhone 不是这个 bundle id 的 App"）。
- 用户划掉实时活动后，Mac 分不清"划掉"和"结束"，有会话时最多每 10 分钟重新启动一次。真机上嫌烦的话，加一个开关，或者只在有会话开始等你确认时才重开。
- Codex 控制通道在 Mac 重启后才列出的待批请求，晚于"只记下现状"的第一份快照到达，可能被当成新请求推一次。
- `push` 帧解码失败（比如不认识的 `environment`）时 Mac 不回 `result`，手机会以为 Mac 版本太旧。只在两边版本不一致时出现。
- `BridgeClient` 的 init 文档还写着每个请求超时都会断开连接，`registerPush` 例外，改掉。
- 测试 `devicesFileStaysPrivate` 里 `setActivity` 那一步是空操作（登记里没有实时活动那一部分），补上实时活动再测。
- 计划 3 的最终审查留下、指派给这份计划的 Mac 端修复（写不进 `devices.json` 时无限递归、被拒收的启动要马上写盘、启动规则和协议文档对齐），记在计划 3 的台账里，见计划 4 的 Task 1。

## 装到真机的计划

计划 1 留下的：

- 扫码器 `startScanning()` 失败时没有任何提示（`try?`），相机开着却不识别。
- 等 Mac 点允许的最多 120 秒里，屏幕可能自动锁定，配对因此失败。`.awaitingApproval` 期间设 `isIdleTimerDisabled`（计划 2 只在看板里用了它）。
- 用户拒绝了本地网络权限时，App 一直显示"未连接，正在重试"，没有任何提示。
- 6 秒连接时限可能把用户第一次回答本地网络权限弹窗的时间也算进去，第一次配对可能报"连不上"、要再试一次。真机上验证。
- 证书固定、连接打开、关闭的判断没有不依赖真机的测试，只有联机测试覆盖。装真机前补上。
- Bonjour 查找每次固定等 3 秒；查找窗口里进入 `.waiting` 的服务不会重试。

计划 2 留下的，模拟器里做不到、只读过代码没试过的（`xcrun simctl` 发不了触摸、键盘、传感器，也不能改系统的减少动态效果）：

- **触摸。** 草地和看板上宠物的按下、拎起、拖着走、摩擦、点一下（`CritterStageView` 是 `CritterView.kt` 的逐行移植，只看过代码和一张"拎起"的静态截图）。详情里的草地在弹层的滚动视图里，拎宠物会不会被 `UIScrollView` 的触摸延迟抢走（需要的话像 `UISlider` 那样覆写 `gestureRecognizerShouldBegin`）。首页卡片上的「拒绝」「允许」和"正在提交…"，停止当前回合的回执。作答卡下拉关闭、点遮罩关闭；顶部拖拽带和内容滚动同时识别，内容能滚的卡片里顶部快速下划可能把卡片关掉（要按滚动偏移门控）。设置里的 `PixelSlider` 改成了 UIKit 识别器（按下不改值，抬起算点按落在那一格，横向过 6 pt 才拖，竖向立刻让给滚动；只有 `SliderTouch` 规则的单元测试）：真手指上点、横拖、竖着从它上面滑过翻页各试一次。按钮在 `ScrollView` 里按下的反馈有没有被触摸延迟吃掉。看板上的模式和关闭按钮、`TouchWatch` 把调暗计时归零、看板上拖宠物、专业看板的行内「拒绝」「允许」。
- **左边缘右滑返回。** 设置页只验证了手势状态和代理的回答，没真的滑过；一次取消的交互式返回之后重新接管靠 `viewDidAppear`。
- **键盘。** 聚焦的输入框会不会自动滚到键盘上方（作答卡、详情、"让它改…"）；详情的事实区随键盘折起；横屏看板上的作答卡弹键盘；"自己写一句…"点一下会不会聚焦（`PixelTextField` 自己持有 `@FocusState`）。
- **亮度和常亮。** 模拟器不理亮度写入（一直读回 0.50），日志只证明调用和数值对。要看亮度真的调到设定值、15 分钟无操作调暗、每一种离开方式之后还原，`isIdleTimerDisabled` 也还原。不在前台（控制中心、切换器、来电）就还原、回到前台再接管：模拟器里只走过"切到别的 App 再切回来"。`willTerminate` 这条路在模拟器里走不到（`simctl terminate` 不发这个通知）。
- **CoreMotion 和电池。** 真传感器的单位（重力 g × 9.80665 只在假传感器上走过）、`UIDevice` 的电池状态、充电横放 3 秒自动打开、竖起 3 秒或拔电 10 秒退出；看板上开着作答卡时，自动退出等卡片关了再算（只用 `-critterFakeDock card` 走过）。
- **静音开关。** `.ambient` 的看板提示音随响铃/静音键；设置里"静音模式下不响"才算真话；专注模式（勿扰）不会让它静音。
- **睡着的宠物耗电。** 睡着的宠物每秒仍重画约 6 帧（一只约 60 帧 / 10 秒，四只全睡着约 100；飘的 z 每约 3 个 tick 动一格）。iOS 规格 §9（第 292 行）写的是"只在画面变化时才画：宠物时钟按 `ticksUntilChange` 醒来；所有会话空闲时不重画；App 不在前台、视图看不见时停掉时钟"，和规格目标 7（小宠物的画面和动画与桌面版逐像素一致，桌面上睡着的宠物也打鼾）冲突；现在按桌面的样子留着鼾声，要不要在 iOS 上让睡着的宠物停住，等用户定。规格 §9 定了不做耗电实测；用户想要实测时，再在真机上把首页和看板全睡着放几分钟，看耗电和发热。
- **减少动态效果。** 系统开关下弹层开合和首页列表重排是 150 ms 淡入淡出（只读过代码；App 自己的开关验证过：宠物停在代表姿势，间隔 1.3 秒的三张截图逐像素一致）；列表重排的第一帧会不会闪。
- **深色和着色的 App 图标。** 模拟器主屏永远显示浅色图标，只验证了 `Assets.car` 里有三份。
- **扫码页。** 相机只在 248 pt 的框里出画，草图是全屏相机加遮罩；真机相机上看了再定。
- **Mac 上的自定义形象。** 手机没有的形象先画小芽，清单推来后只换这一只：只有单元测试，联机看到的是 Mac 分配的内置形象。

## 前端优化轮

看得见、摸得着的：

- 已过期的作答卡里宠物用的是 idle（没有盛开）；Android 的"已在电脑上处理"卡片一直用 done。
- 首页那一行作答失败过，再从卡片重试时，卡片会又显示一遍旧的行内失败（`AnswerSheet` 的 `failure ?? inlineFailure`，`HomeView` 从不清 `.failed`）。
- 详情里「打开回答」在发一句发送途中仍可点（Android：在线且不忙才可点）；详情点「打开回答」时两个弹层先后动，遮罩叠了约 200 ms。
- 详情的拖拽带（160 pt）盖住了 150 pt 的草地：拖详情里的宠物，弹层也跟着被拉；草地现在随内容一起滚动。
- 4000 字上限做在自定义绑定里，到上限时多出的那个字符可能还留在输入框里；这段和 `HomeView.dayNumber` 是没有测试的 App 层逻辑，挪到 `CritterClient` 并补测试。
- 配对确认窗的指纹在最大辅助字号下落在屏幕以下，没有滚动提示（`.scrollIndicatorsFlash`）；`PixelDialog` 的 `contentHeight` 从 0 起。
- 手动输入页没有左边缘右滑（它是页面切换，不是导航推送，和计划 1 一样）。
- 启动画面只有一种颜色加居中的圆形图标（`UILaunchScreen` 做不出草图里分层的天空和草地，要换成 storyboard）。
- 看板上字体跟随动态字体；像素对齐的看板可能想用固定字号。

和草图或 Android 不一致、等用户看过再定的（计划 2 时已按"草图为准、Android 为参考"定下，写在提交说明里）：

- 首页草地在 iPhone 17 Pro 上是 268 / 232 pt，不是草图的 236 / 200（草图的 30 pt 状态栏换成了真的状态栏高度）；首页放 4 只加一堆，不是"5 只加一堆"（`placeRow` 把那堆算作一格，Android 同样）。
- 看板里点一只不在等你的宠物只是逗一下，不进详情（视觉设计 §8.7；Android 是进详情）；没有滑动切换模式（只有按钮）。
- 看板的内容左右留 50 pt，不是整个 62 pt 的安全区；完成的宠物在看板上不调暗（草图和 Android 都是亮的，视觉设计 §5 那句"空闲、做完的宠物调暗"已过时）；专业看板的出错标签红色是自己配的。
- 专业看板保留 Android 的"Claude Code 额度"标签（草图没有），所以额度卡比草图低约 30 pt；气泡写 `what`（"想 ./gradlew …"），草图写"想运行命令"。
- 「看板提示音」的副标题：Android 是"只在看板打开时响；勿扰模式下不响"，iOS 改成"只在看板打开时响；静音模式下不响"。iOS 的 `.ambient` 提示音跟着响铃/静音键，专注模式（勿扰）不会让 App 内的声音静音，照抄会说错话。
- `BoardTrigger` 在"自动打开"被关掉时不清掉正在计的静止时间，唤醒点会反复 0 ms 重排：iOS 已修（`a89f1d5`，`autoOpen` 加了 `didSet`，加了测试 `switchingOffDuringTheHoldForgetsIt`）；Android 的同样写法还没修，记在 `docs/critter-phone-backlog.md` 第四部分。
- 没有 Android 对应文案的新句子：已提交卡片的"这个请求已经在这台手机上答过了。"、4000 字的提示"一次最多发 4000 个字，多出来的没有放进输入框。"、看板的"关闭看板"按钮。Android 要不要同样处理，再定。

代码整理（审查时判为次要、没修）：

- `DetailSheet.swift` 532 行、六个私有类型：拆出 `DetailStage`、`SideBubble`、`Facts`。
- 三个只放一只宠物的小包装（`MiniPet`、`LookingUp`、`TilePet`）和 `LonePet` 重复；`SessionRow` 和 `SheetShell` 里各有一段一样的草地条；运行中的头像底色写死在 `SessionRow`。
- `SkinPicker` 的 `@State` 初值每次设置页 body 刷新都建 7 个 `CritterStageControl`；设置页里私有的 `enum Group` 盖住了 `SwiftUI.Group`。
- `QuestionForm` 里外层 `.focused` 驱动不了 `PixelTextField` 自己的 `FocusState`，那几行是死代码。
- `EdgeSwipeBack` 把 `pop.isEnabled` 设成 true 后不还原；原来的代理只弱引用。
- `DebugLaunch` 的 `pickSkin` 是 `String??`，改成两个 case 的枚举；`-critterFakeDock` 会真的改存下来的"自动打开"设置，`-critterBoard` 会存下模式（都只在 DEBUG）。
- 宠物舞台：`delayedClips` 里跑完的任务不会逐个清掉（离开窗口时整批取消并清空，所以只是在视图一直在窗口里时慢慢多；Android 是每个跑完就移除）；时钟只在进后台、回前台时暂停，不跟 `willResignActive`（控制中心、切换器）；后台帧数检查分不出"时钟停了"和"进程被挂起"；清单按值比较，肖像缓存的键里 undimmed 状态也带 `dimStrength`（有界，无害）。
- `Theme.highlight` 没人用，且深色的 40% 不在视觉设计 §4 的 45–50% 里；`PressedLook` 在 `onChange` 里翻回抬起，可能比内容晚一帧。
- `BridgeClient` 里的 `skipNextPause` 是死状态（没人读），连同 `wait()` 里的分支和 `stop()` 的重置一起删；`BridgeStore.restPingInterval = 60` 和 `BridgeClient` 的默认 60 秒重复；`FakeMac.pingBehaviour` 的 getter 会改 `pings`，该是个方法。
- `BoardAutoOpen.swift` 里 `update(afterIdleTick:)` 和 `reschedule(afterIdleTick:)` 的注释把重新瞄准说过头了：说"下一次告知触发器的事会重新瞄准唤醒"，但 `reschedule` 在提前返回之前就把 `scheduledAt` 记成了那个已过期的时刻，之后 `nextDeadline()` 不变就一直不再武装，要等它自己变了才会。结果无害（本来就没有要做的事），但注释该这么写，或者提前返回时不记 `scheduledAt`。
- ~~`InlineAnswerState`（首页和专业看板共用的行内作答状态：`status` 的文字和色调、`buttonsEnabled(_:)`）没有单元测试；它是纯逻辑，挪到 `CritterClient` 并补测试，和 `HomeRules` 放在一起。~~ **已完成**（`d30093e`，一起挪进库并补了测试的还有看板提示音的判断 `BoardSoundCue`、设置里形象的排序、开场动画的日期、"发一句"的 4000 字截断）。
- `PhoneFlock` 和 Mac 的 `FlockModel` 近似重复（约 20 行，会话类型和排序键不同）；`PhoneFlock.merged` 对空数组会崩，和 Kotlin 一样，已在注释里写明。
- 测试：`everyWayOutRestoresTheScreen` 失败不了（`restore(saved:on:)` 不看出口，签名是计划定的），真正的覆盖是 `-critterBoardLog` 对每种出口的检查；`MotionCues` 的测试比计划松（没有精确的提示前缀、12-2-10-2 的拆分）；`everyStateHasAnIcon` 里的循环是空转；`SkyTests` 没有把天空的随机数和 Kotlin 对上的黄金格；两个测试名里写的是 Pt 而不是 Dp。

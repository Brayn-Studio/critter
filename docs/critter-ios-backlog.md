# Critter iOS 版待办

iOS 计划 1（`docs/superpowers/plans/2026-10-24-critter-ios-1-skeleton.md`）、计划 2（`2026-10-24-critter-ios-2-critters-board-visual.md`，宠物、看板和像素外观）、计划 3（`2026-10-24-critter-ios-3-mac-push.md`，Mac 端推送）、计划 4（`2026-10-24-critter-ios-4-ios-push.md`，手机上的推送、实时活动和首次引导）和计划 5（`2026-10-24-critter-ios-5-device.md`，装到真机）做完时，各轮审查留下、判定放到后面处理的事项。按要落到的计划分组，写后面的计划时逐条认领。做完的条目已经删掉：计划 2 做完的（计划 2 一组、前端优化轮里的四条），以及计划 4 认领的整组"iOS 推送与扩展计划"（首次引导、设置里的推送和实时活动两组、`CritterActivity` 这个名字、bundle id、Mac 端的联机检查、计划 3 留给它的 Mac 端修复）。

## Mac 端（推送）留下的

- Codex 控制通道在 Mac 重启后才列出的待批请求，晚于"只记下现状"的第一份快照到达，可能被当成新请求推一次。
- `push` 帧解码失败（比如不认识的 `environment`）时 Mac 不回 `result`，手机会以为 Mac 版本太旧。只在两边版本不一致时出现。
- `BridgeClient` 的 init 文档还写着每个请求超时都会断开连接，`registerPush` 例外，改掉。
- 测试 `devicesFileStaysPrivate` 里 `setActivity` 那一步是空操作（登记里没有实时活动那一部分），补上实时活动再测。
- 撤销登记（空 token）也会走一遍 `canPush(to:)`：读一次推送配置、写一行日志，可以跳过。`PushCoordinator.swift` 里讲什么时候有定时器的那段注释过时了。
- 按设计的取舍，真机上觉得不对再改：手机从通知按钮作答的那条连接（最多 20 秒）也算"连着"，这段时间 Mac 不会 push-to-start（`PushFanout` 认为连着的手机自己会启动实时活动）；手机连着时，7.5 小时到期的实时活动替换要等断开以后才做。
- 计划 4 的联机检查（Task 11）没看 Mac 设置窗口里设备名后面的"推送"标签（不驱动窗口），也没跑 `scripts/dev/e2e-phone.sh`（它会开一个真的 Claude Code 会话）。`scripts/dev/ios-sim-live.sh` 在 Task 11 改成从 App Group 读配对和快照（计划 4 把它们挪过去了），只对着文件格式核对过，没有再联机跑。下次有人在 Mac 前时补上这三样。

## 真机上还没验证的（计划 5）

计划 5 在用户的 iPhone 16 Pro（iPhone17,1，有灵动岛）/ iOS 27.0.1 上走完了 spec §12 的检查点（2026-10-24），用户在手机上点按、看结果。通过的已经删掉：
- 构建、安装：`ALLOW_PROVISIONING=1 make ios` 登记了一次，之后的 `make ios` 只用装好的描述文件；Release 构建登记的是 `sandbox`。
- 首次引导和配对：本地网络弹窗那次失败会自己重连。
- 推送：
  - 真推送和代理：系统代理 127.0.0.1:1082，直连也通；
  - 扩展解密，锁屏按"显示预览"只显示「一条通知」；
  - 解开后的「允许」「拒绝」「拒绝并写理由…」；
  - 后台作答：App 被划掉时也几乎瞬间生效；断网时显示"没送到"、保留按钮，联网后再点能成；
  - 提问和计划从卡片作答，拒绝理由、计划修改意见 Claude 读得懂；
  - 撤回；
  - 取消配对。
- 专注模式：等你确认的是时效性通知，能不能穿过看用户自己的专注模式设置。
- 实时活动：锁屏、灵动岛、待机、点按进 App。
- 看板：快捷指令自动化、亮度、常亮、静音、退出。
- 触摸、弹层、返回手势、键盘、亮度滑块、深色和着色图标、减少动态效果、扫码页。

还没验证、或者真机上看到了要记下的：

- **本地网络被拒的那条路。** 只走过"第一次弹窗点允许"。没试过的是"不允许 → 页面上的「去设置」→ 打开本地网络 → 回到 App"：
  - 配对前的 Bonjour 关卡（`LocalNetworkGate`）在弹窗还没答时没有报拒绝，真机上没出现"等你允许「本地网络」"那页；
  - 真被拒时，它的浏览器停在 `.waiting` 不会重开，打开开关回来后可能一直等到「取消」；
  - 回到前台的自动重连（`PairingRetry`）只管连不上的失败，管不到这一页。

  下一步：在 设置 › Critter 里关掉本地网络，重走一遍配对。系统日志（子系统 `com.braynlabs.critter`，类别 `pairing`）会记下浏览器的每个状态和场景切换，用 Mac 的「控制台」看。首页离线卡片、手动输入页、失败页上的"没有本地网络权限"提示也一起看。
- **撤回推送没叫醒 App。** 在 Mac 上答掉以后，通知要等打开 App 才消失（回到前台的对账起作用）。后台推送的设置都对：`remote-notification`、`apns-push-type: background`、优先级 5。系统按自己的节奏送后台推送，App 被划掉时完全不送，所以这符合 spec 的"尽力而为"。想更快的话，可以改成用同一个 `apns-collapse-id` 发一条安静的可见通知，把原来的替换成"已在电脑上处理"。
- **Codex**（Mac 端的问题，不只是 iOS）：
  - Codex 用工具提的问题，桌面上和手机上都不显示；
  - 这次也没能触发 Codex 的权限请求：默认的批准策略在工作目录里自动放行，可以用 `codex -a untrusted` 试，所以"Codex 的通知只有两个按钮"还没看到。
- **安静时实时活动会不会变灰**（spec §13.2）。Mac 每约 12 分钟刷新一次，等所有会话都安静 20 分钟以上时看一眼锁屏。更新多的时候有没有被系统压住，也还没专门看。
- **push-to-start 之后 token 能不能在后台送回 Mac**（spec §13.1）。只看到首次配对时（前台）`startToken`、`activityToken` 都送到了 Mac。Mac 在手机不连着时用 push-to-start 启动、App 在后台被叫醒送回 token 的那条路，还没专门测。
- **实时活动的几处边角。**
  - 用户划掉实时活动后，Mac 分不清"划掉"和"结束"，有会话时最多每 10 分钟重新启动一次：真机上嫌烦的话，加一个开关，或者只在有会话开始等你确认时才重开。
  - 迟到的、属于已结束活动的 token 被忽略，只有纯测试覆盖。
  - 活动在 App 订阅它之前就结束时，跟着它的任务可能留着。
  - App 挂起期间结束的活动，`ActivityTokens` 可能一直把它当作登记的那个，直到 `.ended` 到达（可以在 `sync` 时和 `Activity.activities` 对一下）。
- **换了 Mac 之后旧 Mac 的推送**（要第二台 Mac）。
  - 旧 Mac 连不上、没确认撤销时，它再推来的通知应该只显示"有会话需要你"，权限请求只有「打开」。
  - 它手里的 push-to-start token 换不掉：要确认它还能启动实时活动，在那台 Mac 上撤销这台手机后就停了。
- **已接受的缺口（少见）：重新配对到同一台 Mac。** 同一台 Mac（证书指纹相同）不算离开它：不换推送密钥，也不提示去撤销。但在那台 Mac 不在线、手机上所有通知和实时活动又都关着时重新配对到它，旧记录会带着没换的密钥继续推。接受它，不处理。
- **开机后还没解锁过时收到推送。** 这时扩展读不到钥匙串里的密钥，应该显示通用文字、不崩。没测。
- **发布构建。** 以后做 App Store、TestFlight 构建（签的是 `production`）时，App 登记的环境要跟着签名改（`PushSetup.environment` 现在一律是 `sandbox`），否则 Mac 推送会被 APNs 拒（`BadDeviceToken`）。
- **Mac 上的自定义形象。** 手机没有的形象先画小芽，清单推来后只换这一只。只有单元测试。
- **睡着的宠物耗电。** 用户定了保持打呼（和桌面一致），不做耗电实测。想实测时，在真机上让首页和看板全睡着放几分钟，看耗电和发热。
- Bonjour 查找每次固定等满 3 秒，找到了也要等完。

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
- 从通知打开的作答卡片，如果手机正充电横放，几秒后看板自动打开时会先把首页的卡片关掉（现有规则：看板自动打开前先关首页的卡片和详情，草稿保留）。可以考虑把这张卡片带到看板上（`boardRequestId`）。
- 从通知打开的会话详情如果开在看板上面，会像点了关闭按钮那样关掉看板（算手动离开，本次充电不再自动打开）；该用一个不算手动的原因。
- 实时活动只跟 Mac 分配的形象，不跟手机上单独选的形象。
- 首次引导：配对的手动输入、等待、失败几页没有「跳过」；在已配对的手机上重新走引导，欢迎页的按钮还是「开始配对」；看板那一步在 iPhone 17 Pro 上，第 3 张步骤卡被底部按钮压住一截，要往上滚才看全。

和草图或 Android 不一致、等用户看过再定的（计划 2 时已按"草图为准、Android 为参考"定下，写在提交说明里）：

- 首页草地在 iPhone 17 Pro 上是 268 / 232 pt，不是草图的 236 / 200（草图的 30 pt 状态栏换成了真的状态栏高度）；首页放 4 只加一堆，不是"5 只加一堆"（`placeRow` 把那堆算作一格，Android 同样）。
- 看板里点一只不在等你的宠物只是逗一下，不进详情（视觉设计 §8.7；Android 是进详情）；没有滑动切换模式（只有按钮）。
- 看板的内容左右留 50 pt，不是整个 62 pt 的安全区；完成的宠物在看板上不调暗（草图和 Android 都是亮的，视觉设计 §5 那句"空闲、做完的宠物调暗"已过时）；专业看板的出错标签红色是自己配的。
- 专业看板保留 Android 的"Claude Code 额度"标签（草图没有），所以额度卡比草图低约 30 pt；气泡写 `what`（"想 ./gradlew …"），草图写"想运行命令"。
- 「看板提示音」的副标题：Android 是"只在看板打开时响；勿扰模式下不响"，iOS 改成"只在看板打开时响；静音模式下不响"。iOS 的 `.ambient` 提示音跟着响铃/静音键，专注模式（勿扰）不会让 App 内的声音静音，照抄会说错话。
- `BoardTrigger` 在"自动打开"被关掉时不清掉正在计的静止时间，唤醒点会反复 0 ms 重排：iOS 已修（`a89f1d5`，`autoOpen` 加了 `didSet`，加了测试 `switchingOffDuringTheHoldForgetsIt`）；Android 的同样写法还没修，记在 `docs/critter-phone-backlog.md` 第四部分。
- 没有 Android 对应文案的新句子：已提交卡片的"这个请求已经在这台手机上答过了。"、4000 字的提示"一次最多发 4000 个字，多出来的没有放进输入框。"、看板的"关闭看板"按钮。Android 要不要同样处理，再定。
- 计划 4：从通知按钮作答后的结果通知，正文是原来那条通知的标题（"已允许"下面一行"clawd 想 运行 swift test"）；Android 只有结果一行。
- 计划 4 新写的、没有 Android 对应的文案：实时活动一步（第二个按钮是「关掉实时活动」，已经关着时才是「跳过」）、看板一步、设置里推送一组的几行和"离开的 Mac"那一行、配对时的"正在配对"和"手机没能保存这次配对，再配对一次。"。配对一步跳过的说明，iOS 写的是"之后手机不会连上电脑，走完引导后再配对"（Android 是"要用时在首页配对"；iOS 上没配对的手机走完引导就到配对页）。

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
- 计划 4 的推送和配对：一个已被换掉的连接回来的推送登记结果直接返回，不再问一次要不要登记（`BridgeStore`，很窄的竞争；返回前调 `registerPushIfNeeded()`）；离开一台 Mac 时，还在路上的第一份登记不算进 `mayHold`，极少数情况下漏掉换推送密钥；`PushRegistrar.takingBack` 和 `shouldUnregister` 的版本检查、空 token 的写法重复了一遍；设置里"离开的 Mac"那一行没提实时活动的 token，推送密钥没写进去时也照样显示（`PushSetup`）。`BridgeStore` 少两条测试：正在连接、见过 Mac 版本但还没 `.connected` 时什么都不发；20 秒后才到的结果。
- 计划 4 的存储：写配对记录失败的那条路没有测试（`DiskPairingStorage`）；`removeSecrets(keeping:)` 在 `accounts()` 为 nil 时什么也不说，该记一行日志；`SharedContainer.keychainGroup` 在 Info.plist 少了那个键时静静地是 ""，该像 `url` 那样记 fault；`KeychainPairingStorage.swift` 的文件名和里面的类型（`KeychainSecrets`）对不上。
- 计划 4 的通知：点按和划掉的系统动作 id 是写死的（DEBUG 里可以断言等于 `UNNotificationDefaultActionIdentifier`）；读推送密钥的代码在 `NotificationService.swift` 和 `PushSetup.swift` 里各有一份；DEBUG 参数里 `@秒` 的解析重复了几处。
- 计划 4 的实时活动：`ActivitySkins.bundled` 和 `SkinStore.bundled` 重复（少了 `isPlain`）；小组件里打包了用不到的 `silkscreen_bold.ttf`；两条"内容相同"的测试是同义反复；历史草图 HTML 里还是改色之前的颜色。
- 看板自动打开：判断要不要重新武装时，在 `onTick`/`perform` 之后又读了一次时钟（`BoardAutoOpen.swift`；Android `BoardTriggerService.kt` 同样），每个 tick 该只读一次。

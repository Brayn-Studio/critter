# Critter iOS 版待办

iOS 计划 1（`docs/superpowers/plans/2026-10-24-critter-ios-1-skeleton.md`）、计划 2（`2026-10-24-critter-ios-2-critters-board-visual.md`，宠物、看板和像素外观）、计划 3（`2026-10-24-critter-ios-3-mac-push.md`，Mac 端推送）和计划 4（`2026-10-24-critter-ios-4-ios-push.md`，手机上的推送、实时活动和首次引导）做完时，各轮审查留下、判定放到后面处理的事项。按要落到的计划分组，写后面的计划时逐条认领。做完的条目已经删掉：计划 2 做完的（计划 2 一组、前端优化轮里的四条），以及计划 4 认领的整组"iOS 推送与扩展计划"（首次引导、设置里的推送和实时活动两组、`CritterActivity` 这个名字、bundle id、Mac 端的联机检查、计划 3 留给它的 Mac 端修复）。

## Mac 端（推送）留下的

- Codex 控制通道在 Mac 重启后才列出的待批请求，晚于"只记下现状"的第一份快照到达，可能被当成新请求推一次。
- `push` 帧解码失败（比如不认识的 `environment`）时 Mac 不回 `result`，手机会以为 Mac 版本太旧。只在两边版本不一致时出现。
- `BridgeClient` 的 init 文档还写着每个请求超时都会断开连接，`registerPush` 例外，改掉。
- 测试 `devicesFileStaysPrivate` 里 `setActivity` 那一步是空操作（登记里没有实时活动那一部分），补上实时活动再测。
- 撤销登记（空 token）也会走一遍 `canPush(to:)`：读一次推送配置、写一行日志，可以跳过。`PushCoordinator.swift` 里讲什么时候有定时器的那段注释过时了。
- 按设计的取舍，真机上觉得不对再改：手机从通知按钮作答的那条连接（最多 20 秒）也算"连着"，这段时间 Mac 不会 push-to-start（`PushFanout` 认为连着的手机自己会启动实时活动）；手机连着时，7.5 小时到期的实时活动替换要等断开以后才做。
- 计划 4 的联机检查（Task 11）没看 Mac 设置窗口里设备名后面的"推送"标签（不驱动窗口），也没跑 `scripts/dev/e2e-phone.sh`（它会开一个真的 Claude Code 会话）。`scripts/dev/ios-sim-live.sh` 在 Task 11 改成从 App Group 读配对和快照（计划 4 把它们挪过去了），只对着文件格式核对过，没有再联机跑。下次有人在 Mac 前时补上这三样。

## 装到真机的计划

装之前必须先做的：

- **不让 Xcode 自己去开发者账号里登记。** `ios/Config/Base.xcconfig` 模拟器构建是 `CODE_SIGN_STYLE = Automatic`（本地签名 `-`），旁边是真的 entitlements（`ios/Config/Critter.entitlements` 等：App Group、钥匙串共享组、推送、时效性通知）。在 Xcode 界面里给真机构建时，自动签名会自己去账号里给 App ID 打开这些能力、登记 App Group、生成描述文件；所以真机构建已经是 `CODE_SIGN_STYLE[sdk=iphoneos*] = Manual`（计划 4 最终修复轮加的，带注释）。真机构建在描述文件备好之前会签名失败，这是故意的；要改成别的，先问过用户；不加 `-allowProvisioningUpdates`。
- **描述文件要带齐这些能力**，由用户自己在开发者账号里给 `com.braynlabs.critter` 和两个扩展打开：App Group `group.com.braynlabs.critter`（App、`CritterNotify`、`CritterWidgets` 三个都要）；钥匙串共享组 `<Team ID>.com.braynlabs.critter.shared`（App 和 `CritterNotify`）；推送（`aps-environment = development`，App）；Time Sensitive Notifications（App）。少一样签名就失败。模拟器构建的 entitlements 写在二进制的 `__TEXT,__entitlements` 里，`codesign -d` 显示为空是正常的。

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

计划 4 留下的，这个模拟器上做不到的（`xcrun simctl push` 把推送当本地通知投递，通知服务扩展从不运行；通知只有"临时"授权，安静地进通知中心，不出横幅；命令行打不开通知中心、锁屏和待机模式，也锁不了屏；`simctl push` 现在连只有 `content-available` 的撤回推送都拒收："Notification has no user visible content"）。spec §13 的几条也在这里：

- **真的往 APNs 发一条**（spec §13.7）。用户给 `.p8`（他另一个 App 已经在用推送的话，可以用那一把）、在开发者账号里给 App ID 打开推送之后，在 Mac 设置里"发送测试通知"，手机上要看到"Critter 推送测试 / 能看到这条，说明推送通了"。计划 3、4 只用假的传输层和 `critter-bridge-client` 测过；计划 4 的联机检查里，Mac 收到了模拟器真的 sandbox token（80 字节），没有 `.p8` 时回"已登记；这台 Mac 还没配置推送"，手机设置里照原话显示。
- **代理**（spec §13.6）。这台 Mac 访问 `api.sandbox.push.apple.com` 要不要走代理：Mac 发推送用 `URLSession`，只认系统的代理设置，不认命令行用的 127.0.0.1:1082。连不上时 Mac 设置里显示"出错：连不上 APNs"。
- **机型和系统**（spec §13.5）。用户 iPhone 的型号（有没有灵动岛）和系统版本（至少 iOS 17.2）。没有灵动岛时实时活动只在锁屏上；iOS 17 没有 iOS 18 的广播频道（下面 §13.1 的退路）。
- **推送环境。** App 一律登记 `sandbox`（`PushSetup.environment`）：Debug 和 Release 都用 `Critter.entitlements` 的 `aps-environment = development` 签名、从 Xcode 装，拿到的都是 sandbox 的 token。以后做发布构建（App Store、TestFlight，签的是 `production`）时，登记的环境要跟着签名改，否则 Mac 推送会被 APNs 拒（`BadDeviceToken`），Mac 删掉登记。真机上确认 Release 构建登记的是 sandbox、推送能到。
- **通知服务扩展解密，包括锁着的手机。** 真推送到真机后：标题、副标题、正文换成解密后的文字；类别（按钮）、线程（会话）、等你确认的是"时效性"级别；密钥不对、坏的密文显示"Critter / 有会话需要你"，权限请求只剩「打开」（扩展换成 `sealed` 类别，点了进卡片），不出「允许」「拒绝」；扩展来不及解完就被系统交出时也应如此（先套上 `sealed`）。手机锁着时扩展也要解得开（钥匙串的可访问性是"首次解锁后"）；开机后还没解锁过时读不到密钥，要显示通用文字，不能崩。规则只有 `PushOpeningTests` 和 `scripts/dev/push-payloads/make.sh` 生成的载荷过了一遍纯函数；扩展本身没跑过。
- **通知上的按钮和横幅，先面容 ID 再作答。** 下拉后的「允许」「拒绝」「拒绝并写理由…」（输入框"拒绝的理由（可不写）"、发送"拒绝并发送理由"）都要先解锁（`.authenticationRequired`）：锁着时点按钮先弹面容 ID，通过后答案才发出，取消时什么也不发。Codex 的只有两个按钮；提问、计划的「打开」。模拟器里只从日志看到系统登记的类别和选项（`-critterNotificationAction` 走的是同一个处理函数，按不了真按钮）。前台：快照里已有的请求只轻震（模拟器没有触感），其它出横幅、有声音。
- **点按钮作答的整条路和耗时**（spec §13.3）。App 被划掉时点「允许」：系统在后台启动 App、连 Mac、送答案、用同一个通知 id（APNs 的 `apns-collapse-id`）换成"已允许"。量一下连接、`hello`、`answer`、`result` 一共多久，是不是在系统给的后台时间里（Android 送不到时约 8–9.5 秒给出提示）；后台作答只用存下的地址，20 秒内不做 Bonjour 查找。Mac 连不上时 20 秒内换成"没送到…"并保留按钮，再点一次能成；后台时间用完时（`BackgroundAnswer` 被取消），"没送到…"在 `onExpire` 里先发出去，要确认它在 App 被挂起前真的出现、带着按钮。点通知正文冷启动 App 时直接打开那张卡片。模拟器里 `simctl push` 没有 collapse id，同一个请求会有好几条通知，App 按推送里的 `r`/`k`/`s` 认通知，真机上要确认按 collapse id 换掉的是同一条。
- **撤回推送。** `didReceiveRemoteNotification` 只用 DEBUG 的 `-critterWithdrawPush` 走过。真机上看后台推送能不能叫醒 App 删通知；App 被划掉、低电量模式时系统不送后台推送，那时靠回到前台后的对账（模拟器里验证过）。
- **时效性通知和专注模式**（spec §13.4）。`Critter.entitlements` 有 `com.apple.developer.usernotifications.time-sensitive`（等你确认的通知要能穿过专注模式，spec §8.7），没有这个能力时系统把时效性通知当普通通知。真机上打开一个专注模式，看等你确认的通知能不能按用户的设置提醒；扩展设的 `.timeSensitive` 不生效，就给 `CritterNotify.entitlements` 也加上同一个键。做完了、出错是普通级别，专注模式里不该响。
- **换了 Mac、取消配对之后旧 Mac 的推送。** 旧 Mac 连不上、没确认撤销时，手机换了推送密钥、结束了正在显示的实时活动，并在设置和配对页提示去那台 Mac 上撤销：旧 Mac 再推来的通知应该只显示"有会话需要你"、权限请求只有「打开」（扩展解不开）。它手里的 push-to-start token 换不掉：确认它还能启动实时活动、在那台 Mac 上撤销这台手机后就停了。Mac 已经撤销了这台手机（`denied badToken`）时什么也不提示。模拟器里扩展不运行，通知那部分看不到。
- **实时活动的推送 token 能不能在后台送回 Mac**（spec §13.1）。push-to-start 启动后，App 在后台被唤醒时能不能连上 Mac，把 `activityToken` 用推送登记送过去（模拟器里挂起时拿到的 token，要到下次回前台连上才送到）。不行就改用 iOS 18 的广播频道，或者只在前台启动。Mac 这边现在的做法：启动一次后等 token，拿不到就不再启动，活动停在旧内容（15 分钟后变灰），直到 7.5 小时或会话全部结束 5 分钟后。
- **实时活动的更新预算**（spec §13.2）。Mac 在内容变化时更新（低优先级，最多每 10 秒一次；多了等你确认的会话时马上发、高优先级），安静时每约 12 分钟刷新一次，免得 15 分钟后变灰。看系统会不会把这些压住（压住了就会变灰，或者等你确认的数字来晚了）。
- **实时活动在真机上的样子和点按。** 锁屏、push-to-start 启动时的提醒横幅、待机模式（StandBy，`isActivityFullscreen` 那套样子）、灵动岛的最小视图、展开视图的"可能不是最新的"、真的点一下进 App：模拟器里只看过 `-critterActivityDemo` 在 App 里画出的锁屏块，和 `simctl io recordVideo` 录到的灵动岛紧凑、展开两种。`.opacity` 在归档渲染里是否生效。
- **实时活动的几处边角。** 用户划掉实时活动后，Mac 分不清"划掉"和"结束"，有会话时最多每 10 分钟重新启动一次：真机上嫌烦的话，加一个开关，或者只在有会话开始等你确认时才重开。迟到的、属于已结束活动的 token 被忽略，只有纯测试覆盖。活动在 App 订阅它之前就结束时，跟着它的任务可能留着；App 挂起期间结束的活动，`ActivityTokens` 可能一直把它当作登记的那个，直到 `.ended` 到达（可以在 `sync` 时和 `Activity.activities` 对一下）。

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

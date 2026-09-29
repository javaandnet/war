# 战棋 AI · iPhone 版

把 `../war` 里的 JS 战棋原型重写成了 iOS 原生应用：规则与 AI 全部移植成 Swift，
棋盘用 SpriteKit 画，控制面板用 SwiftUI，AI 决策可解释（能看到"为什么这么走"）。

在原型之外多长出了三套系统：**首领（斩首即终局）**、**魔法（只有首领会用）**、
**军费（跨局钱包）**。它们不是三层皮：首领改写胜负判据，魔法改写首领的动作空间，
军费同时给玩家和 AI 买兵买档买充能 —— 所以军费是难度表的第四个旋钮，而不是玩家专属的外挂。

## 目录结构

```
ios/
├── WarKit/          纯逻辑内核（Swift Package，零 UI 依赖）
│   ├── Sources/WarKit/      规则、可达域、威胁图、候选枚举、评分、战略层、前瞻、难度、配兵
│   └── Tests/WarKitTests/   回归测试 + 难度量尺
├── War/             iPhone App 外壳
│   ├── Model/       GameStore（状态机）/ BoardFrame（渲染输入）/ GameSettings / Wallet
│   ├── Rendering/   BoardScene（SpriteKit 四层）/ BoardView
│   ├── UI/          ContentView / ActionPanel（含军费面板）/ DecisionLogView / SettingsView
│   └── Support/     Theme / PowerPolicy（省电预算）
├── tools/
│   ├── smoke.sh     无头冒烟：在 macOS 上真跑 App 逻辑层
│   └── Smoke/main.swift
└── project.yml      XcodeGen 工程描述（War.xcodeproj 是生成物，已 gitignore）
```

分层原则：**规则与 AI 只在 WarKit 里**，App 外壳只通过公开 API 消费它。
所以内核的回归测试不需要模拟器，`swift test` 直接跑。

两处刻意的例外：`Wallet`（跨局军费）留在 App 层 —— 它是存档而不是规则，内核不该
知道玩家有钱；`ArmyComposer`（在预算内配兵）则必须留在内核 —— AI 的编成要和规则
一起进复现不变式。新增 App 源文件后必须 `xcodegen generate`，否则工程搜不到它
（`tools/smoke.sh` 自己列 swiftc 文件清单，也要同步加一行）。

## 三层验证

```sh
cd ios/WarKit && swift test -c release     # ① 内核回归：36 项（难度量尺需显式开启）
sh ios/tools/smoke.sh                      # ② App 逻辑层无头冒烟：140 项断言
xcodebuild -project ios/War.xcodeproj -scheme War -sdk iphonesimulator \
    -configuration Debug -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=NO build          # ③ 模拟器免签构建（要求 0 代码警告）
xcodebuild -project ios/War.xcodeproj -scheme War -sdk iphoneos \
    -configuration Release -destination 'generic/platform=iOS' \
    CODE_SIGNING_ALLOWED=NO build          # ③' 设备侧 Release 同样要过
```

②按入口分成 5 段（共 8 个小节），可单选快跑：`WAR_SMOKE_ONLY=manual|auto|intel|chief|wallet`
（`chief` 段的旧名 `wipe` 仍当同义词收着，免得老命令行静默跑空）。
它订阅 `GameStore` 真实发布的每一帧，逐帧检查
"没有两个活单位同格 / 单帧位移 ≤1 格 / 不凭空冒出新单位 / 被冻单位解冻前不位移 /
首领充能不为负"，并比对同设置两局的逐帧指纹。它上手就抓到一个真 bug：`newGame` 与 `startAuto`
在同一帧里各排了一次 AI 回合，被 `cancel()` 的旧 Task 照样执行完整个回合
（Swift 的取消只置标志位），把开局第一个 AI 回合压缩成一帧"集体瞬移" ——
现由 `pendingAiCamp` 去重 + `runAiTurn` 入口的 `Task.isCancelled` 让位堵住。

回合推进也在它的监视范围内：`afterAiTurn` 曾经只在观战模式推进阵营，对站 AI 模式下
AI 打完不交还玩家，而 `handleTap` 第一道守卫就是 `!isAIControlled(currentCamp)` ——
表现为"第一轮能动、第二轮点什么都没反应"。现在第 3 段直接断言"AI 打完自动交还 +
轮次推进到 2 + 第二轮点己方单位可选中"。

结局判定是第 7 段（`chief`）：对站 AI 下让玩家完全不抵抗（每轮到自己就立刻交出），
噩梦档 AI 在第 6 回合就砍掉蓝方首领 —— 而此刻蓝方还剩 4 个兵，断言正落在
“立即判负 + 原因是斩首 + 靠战场判据而非回合上限”上。把 `checkOutcome` 的 guard 回退成原写法后，
这一条确实变成了"51/50 回合才由上限兜底"（帧数 231→828）。

**每条新断言都要反证一遍**（本项目惯例：临时把对应修复回退，确认断言真的会红，
否则它们只是假安全感）。三系统落地后已跑过五次：

| 回退了什么 | 谁报了错 |
|---|---|
| `Wallet.beginBattle` 的"上一局未结算就不再发钱"守卫 | 冒烟 2 条（余额变 240、开局 4 次） |
| `undoPlacement` 的退款 | 冒烟 1 条（撤销后余额没回到 120） |
| `Battlefield.castSpell` 的扣发那一行 | 内核 4 条 + 冒烟 1 条（施法飘字却没人掉发数） |
| `ArmyComposer` 的定序买兵（换成 `shuffled()`） | 内核 4 条 + 冒烟 3 条（两局指纹分叉） |
| `matchOutcome` 的斩首优先级（`\|\|` 改成 `&&`） | 内核 3 条 + 冒烟 1 条（歼灭局里败方首领已倒） |

第三条最初只有内核抓到、冒烟漏抓 —— 于是补了一条 App 侧联动断言：
"整局只要出现过施法类飘字，就必须有哪位首领的发数低于军费买到的上限"，
专抓"App 演一场不花钱的施法戏"。

内核测试只在 release 下跑性能门槛：`swift test -c release`；
难度阶梯量尺（40/200 seed 轮流先手）默认跳过，需要时
`WAR_MEASURE_DIFFICULTY=1 swift test -c release --filter DifficultyMeter`。

### 在模拟器/真机上跑

模拟器需要先装 iOS 运行时（Xcode → Settings → Components，或
`xcodebuild -downloadPlatform iOS`，数 GB）。装好后：

```sh
xcrun simctl list devices available        # 找一台 iPhone
xcrun simctl boot "iPhone 16"
xcrun simctl install booted <DerivedData>/Build/Products/Debug-iphonesimulator/War.app
xcrun simctl launch booted com.war.tactics
xcrun simctl io booted screenshot shot.png
```

真机：`project.yml` 里已填 `DEVELOPMENT_TEAM`，Xcode 里选自己的 Team 签名后 ⌘R。
设备构建免签核验：`-sdk iphoneos -configuration Release CODE_SIGNING_ALLOWED=NO build`。

## 玩法与操作

- **模式**：对战 AI / 本地双人 / AI 自动对战（观战）。
- **布阵**：点出生区落子（按兵种单价扣军费），再点该子可撤销并退款；「一键布阵开战」
  按默认模板把钱花在兵上，**不**自动买充能或升档（那是面板上的主动选择）。
- **军费面板**：布阵页有「升兵 / 魔法」两页，显示余额、兵位 `x/6`、本局已花，
  可以买档位、买断魔法、买本局充能。
- **行动**：选中单位 → 蓝格机动、点敌人攻击、`待命`放弃剩余配额、`结束回合`。
- **施法**：选中**己方首领**时行动面板出现施法按钮组，选中哪门魔法后棋盘上紫色格
  就是它能命中的目标（口径由内核算，UI 不自己推射程），点目标即施放。
  聚焦模式的迷你条只放一个施法入口（待施法中再点就是取消），多门魔法的选择留给行动面板。
- **叠层**：机动范围（含地形消耗）、敌方威胁图（越红越危险）、AI 最优落点 ★。
- **决策日志**：战略结论（进攻/防守/冲锋/脱离接触 + 目标区 + 集火对象），
  以及每个单位的候选动作、评分分项、softmax 采样偏移 —— 调参不用回读代码。
- **复现一局**：`地形 seed` 决定地图，`AI seed` 决定采样；两个 seed + 模式 +
  难度相同 ⇒ 整局逐帧一致（冒烟测试第 5 段就是这条断言）。
  AI 的编成来自难度预算而不是玩家余额，正是为了让这条不变式在经济系统之下仍然成立。

## 首领与斩首

每方必带 1 名首领（`commander`），它**不占士兵名额、不花钱**：兵上限仍是 6
（`WarConfig.soldiersPerSide`），`maxUnitsPerSide = 7` 是含首领的语义。

| 项 | hp | atk | def | move | range | 反击 | value |
|---|---|---|---|---|---|---|---|
| 首领 | 160 | 50 | 16 | 4 | 1 | 是 | **2.5** |

`value` 2.5 刻意远高于士兵上限（弓兵 1.35）。AI 的 `targetValue`、`materialScore`、
`centerOfMass` 全都读这个字段，于是"集火敌方首领"与"护卫己方首领"不用写新规则就会
自然出现。这也是斩首判据必须待在内核的原因：AI 的评分项和真实胜利条件必须是同一件事，
否则它会为了一个不值得抢的目标阵型变形（难度阶梯当年就是这样退化的）。

## 军费：跨局钱包

`Wallet` 落在 `UserDefaults` 键 `war.wallet.v1`，是 Codable 值类型；所有写入都经
`GameStore.mutateWallet` 这一个入口（一次整体赋值，同时触发 `@Published` 与落盘）。

- **余额永不为负**：`spend` 是唯一扣款口，钱不够就返回 false；扣了钱而事没办成
  （比如落子被内核拒绝）走 `refund` 原路退回。
- **每局补贴 30**：只在 `newGame()` 入口入一次账。`pendingBattleID` 非 nil 时
  `beginBattle()` 直接返回 —— 反复重开不会被当成提款机（冒烟专测这条）。
- **结局结算**：胜利 `60 + 难度加成`（简单 0 / 普通 20 / 困难 40 / 噩梦 70）、
  平局 30、败局安慰 10，同一局只结一次；结局卡片列出"奖金 / 本局军费 / 余额"。
- **价目表**（玩家与 AI 同价同档）：步兵 20、骑兵 30、弓兵 25、首领 0；
  升档 `tierCosts = [0, 80, 140]`（tier2：hp/atk ×1.15、def ×1.10、value ×1.15；
  tier3：×1.35/×1.30/×1.20、value ×1.35）。
- **升档按兵种永久生效**：升了步兵，之后所有步兵都是那个档 —— 单位本身不跨局存在，
  个体升级无意义。倍率走纯函数 `WarConfig.unitStat(_:tier:)`，所以 `WarUnit` 的
  maxHp/atk/def 仍是 `let`，快照结构与 AI 评分都不必改。
- **买断 vs 充能**：魔法买断是跨局永久资产（任何时候可买），充能是本局消耗品
  （**只有布阵期能买** —— 携带发数在「完成布阵」那一刻写死进首领，开战后再买也不会
  凭空多出发数，所以直接把入口关掉，不做一个"收了钱不办事"的按钮）。
  结清本局时充能作废、买断留着：一局失败不该蒸发跨局资产。

观战与本地双人模式不动账（没上场就不该领钱），军费面板整块隐藏。

## 魔法：首领专属

三种都只有首领能施放，士兵永不带法（`WarConfig.maxSpellsPerTurn = 1`，
**施法与普攻同回合互斥** —— 一回合一个动作，内核"每单位一次决策"的结构不破裂）。

| key | 名称 | 射程 | 效果 | 买断 | 每发 |
|---|---|---|---|---|---|
| fireball | 火球 | 3 | 中心 60 固定伤害 + 半径 1 溅射 25（无视防御与地形减伤，只烧敌方） | 60 | 20 |
| heal | 治疗 | 2 | 己方目标恢复 45（不超 maxHp，满血拒施） | 45 | 15 |
| freeze | 冰冻 | 3 | 敌方目标本回合禁机动/禁攻击/禁反击 | 70 | 25 |

- **唯一写路径** `Battlefield.castSpell`：校验身份、施法次数、充能、射程、视线、
  目标阵营，**全过了才扣资源** —— 校验失败不得偷走充能（UI 才能把失败原因直说）。
  扣资源 = 扣那一发充能 + 吃掉本回合动作配额。
- 魔法伤害是固定值、不吃防御与地形：否则首领自身 def 16 + 山地减伤会把火球磨到
  看不出意义；溅射也不触发反击（不然 AOE 会打成连锁械斗）。
- 被冻单位：`computeReachable` 返回空域、`beginTurn` 跳过它的配额重置、
  `canCounter` / `canCounterAttackerAt` 都加 `&& !stunned`。冰冻只压下一回合，不跨回合累积。
- `spellCharges` / `remainingSpell` / `stunned` 三个字段全部进 `UnitState` 快照 ——
  AI 前瞻靠 restore 回滚，漏一个字段推演就会和重放不一致。
- **AI 四处同时接入**：`Enumerator`（只有带法的首领才枚举施法候选）、
  `Scorer`（新增 `heal: 18`、`freeze: 30`，实测不压过 `kill: 80`，AI 不会放弃到手的
  击杀去施法）、`Lookahead.applyCandidate`、`WarAI.Replay.apply`。
  后两处必须同调 `castSpell`，否则"推演的局面"和"动画重放的局面"会分叉。

### 图标

- 兵种：步兵 `person.fill`、骑兵 `hare.fill`（对应高机动）、弓兵 `scope`（对应远程、不反击）、
  首领 `crown.fill`。阵营仍由方块底色区分（蓝=我方、红=敌方），图标固定白色，血量数字在格子下方。
- 魔法：火球 `flame.fill`、治疗 `cross.fill`、冰冻 `snowflake`（`Theme.spellIconName(for:)`）。
- 地形：森林 `tree.fill`、山地 `mountain.2.fill`、河流 `drop.fill`、城墙 `square.grid.2x2.fill`；
  平原不画图标（每格都带符号只会变成噪点）。
- 映射表只有 `Theme.unitIcons` / `Theme.terrainIcons` / `Theme.spellIcons` 几份，棋盘（SpriteKit，
  纹理按「名称@尺寸」缓存）与面板（SwiftUI `UnitGlyph`/`TerrainGlyph`/`SpellGlyph`）共用，
  保证同一兵种到处同形。内核的字母 `symbol` 保留作为兜底：任何图标取不到时自动退回字母，
  不会空白。新增兵种或魔法若漏配图标，冒烟第 6 段的"每个兵种/每门魔法都有图标映射"会直接报错。
- **SF Symbol 名字必须实测**：拼错不会编译报错，只在运行时返回 nil。加图标时先写个
  临时脚本用 `NSImage(systemSymbolName:)` 逐个验证（本项目因此把 `cents.circle.fill`
  换成了 `dollarsign.circle.fill` —— 前者根本不存在），验完删掉脚本。

## 胜负判定

判据本体在内核 `Battlefield.matchOutcome`（App 与 AI 自对弈共用同一个口径，UI 层不再
自写一套），优先级是：

1. **首领阵亡（斩首）** —— 任一方曾有首领而现已无存活首领，就地结束，**即使它还剩一半兵**；
   双方首领同帧皆失按物质分定胜者（同分计平）。
2. **士兵全灭（歼灭）** —— 不含首领的存活数为 0；`unitsOfCampExcludingChief` 就是为这条
   存在的，用 `unitsOfCamp` 会把"只剩首领"误算成"还有兵"。
3. **回合上限兜底** —— 50 回合未分胜负才按剩余兵力物质分判定（势均力敌的正常结局）。

触发时机：每次攻击/施法结算后（含反击打死攻击方）与每个 AI 回合结束时都跑
`checkOutcome()`；`advanceCamp` 只在推进阵营前查回合上限 —— 结构上就保证了战场判据在前、
兜底在后。结局卡片会写明是哪一种原因（首领阵亡 / 部队全体覆没 / 到回合上限），
并列出本局收支；判定后所有按钮变灰，不给出可见反馈的话玩家只会以为"又卡住了"。

## 聚焦模式与缩放

竖屏宽度除以 14 格 ≈ 单格 27pt，这是"格子小"的硬约束 —— 把面板挤掉才能放大，
所以两条路一起走：

- **聚焦模式**（默认开，开战后生效；布阵阶段面板仍常驻，因为要落子）：整屏只留
  棋盘 + 顶部一行状态 + 底部一条迷你操作条。行动/情报/AI 决策面板改成**按需升起的
  浮层**，浮层是 overlay 而不是布局分支，所以开合面板不会改变场景尺寸（不触发地形
  重建、也不闪）。顶部状态条有 `聚焦` 按钮可随时切换，设置里也有开关。
- **缩放**：只由**双指捏合**控制（点击、双击都不改动缩放 —— 地图上的点击必须留给格子），
  1~3× 连续可调，以两指中心为锚点（不会越缩越偏）；底部迷你条的「全图」按钮一键复位。
  设置里可指定默认缩放档位（1× / 1.35× / 1.8× / 2.4×，即每局开局的起始倍数），改完立即生效。
- **平移**：仅当图放大到超出屏幕才响应单指拖动（全图模式下单指留给点格子，
  不会被 pan 吞掉），偏移会夹紧 —— 比屏小的图居中锁定，比屏大的图拖不出空白边。
- **跟手**：放大后选中单位会自动带到视野中心，不会跟丢。
- 缩放/平移只改场景里一个容器节点的 `scale/position`，网格坐标一律不动，
  因此零重建、零地形重画（省电）。点击靠"按下记录 → 抬起校验位移与多指"判定，
  并用 `worldNode.convert(_:from:)` 反算网格坐标，缩放后点哪格就是哪格。
- 单格边长小于 20pt 时会隐藏单位头顶的 `⚡/⚔` 余量数字（会跟邻居压字），
  施法徽标在 cell < 26 时同样隐藏；放大后自动出现。血量数字始终显示。

## 难度

四档共享同一份评分与同一套规则，只有四个正交旋钮 —— 前三个管"打得怎么样"，
第四个管"拿什么打"：

| 档位 | 视野（信息） | 温度（softmax） | 前瞻（rollout 层） | 军费预算 |
|---|---|---|---|---|
| 简单 | 5 个敌人 | 0.90 | 0 | 40 |
| 普通 | 9 | 0.35 | 0 | 90 |
| 困难 | 全图 | 0.10 | 1 | 140 |
| 噩梦 | 全图 | 0.02 | 2 | 200 |

预算由内核 `ArmyComposer` 花掉：在预算内做**全序确定**的贪心配兵
（首领免费 → 按 `defaultRoster` 模板买兵 → 有余款按 `unitTypeOrder` 定序买最高性价比
升档 → 再有余款按（充能价, key）升序轮着买充能）。三条硬要求：不许有随机源（连
`SeededRng` 都不用，纯算术）、不许读玩家钱包、每个循环都要有确定次序 —— 破坏任何一条
都会让冒烟第 5 段"同设置两局逐帧一致"当场失效（这条已被反证过一次）。

40 seed 轮流先手实测（军费成为第四个旋钮之后）：噩梦 40/40 胜简单、困难 40/40 胜简单、
困难 34/40 胜普通、噩梦 35/40 胜困难，噩梦自对弈 20/20（噪声底）。
`testDifficultyOrderingWins` 的回归阈值另按 200 seed 校准值（200/200、200/200、
176/200、165/200）取 40 样本均值 −2σ 来定：跨度最大的两对已经饱和，它们只能报"不能输"，
真正有分辨力的是相邻两对。

## 省电

内核本身很轻（18×18 满编一回合中位数 <20ms，噩梦含前瞻 <40ms），常驻耗电来自
**屏幕刷新与连续动画**。`PowerPolicy` 只做三件事，全靠系统通知驱动、不自建定时器：

1. `thermalState` 到 serious/critical 或系统低电量模式 ⇒ AI 前瞻压到 ≤1 层；
2. 同上状态 ⇒ SKView 降到 30fps、动画节拍 ×1.35；
3. 退到后台立刻停自动对战并取消动画 Task。

**降的是算力，不降任何单位数值，也不改军费预算** —— 手机发烫不会让敌军变脆，
也不该让 AI 少买一个兵（那等于篡改玩家挑好的难度）。

## 渲染层踩过的坑（已修，但容易再犯）

- **设置页 `EXC_BREAKPOINT`**：`Stepper(value:in: Int.min...Int.max)` 会直接崩 —— SwiftUI
  内部要算区间跨度，`Int.max - Int.min` 溢出 trap，表现为"打开设置页就断住"。
  给无界整数用 `-99_999_999...99_999_999` 这种"够宽但不溢出"的区间。
- **单位文字不刷新**：hp / AP 文本曾只在 `makeUnitNode` 写一次，之后 `move()`
  只改颜色和透明度 —— 结果是掉血后数字停在满血。现在 `makeUnitNode` 只搭
  无文本骨架，`decorate` 是唯一的可见字段刷新入口；以后给单位加新显示字段
  （首领金环、冰冻蓝罩、施法徽标都是这么加的），只改 `decorate` 就不会漏。
- **`SKSpriteNode` 没有 `colorMultiply`**：那是 `SKAction` 的方法。纹理只有一份白图，
  上色要靠节点自身的 `color` + `colorBlendFactor = 1.0`（写错只是编译不过，但在注释里
  沿用了那个说法会误导下一个改代码的人）。
- **两套单位类型别混**：`GameStore.selectedUnit()` 返回内核 `WarUnit`（唯一带
  `remainingSpell` 的类型），`frame.units` 是 `BoardFrame.UnitView`（渲染输入，带 `tier`）。
  施法按钮读前者，徽标与描边读后者。

## 已知边界

- 渲染层与手势（捏合缩放的手感、放大后拖动、点击命中精度、聚焦布局）只能靠真机看，
  无头冒烟不覆盖；当前机器未装 iOS 模拟器运行时，尚未做这一步目视确认。
  代码侧只保证了编译干净与坐标反算自洽（缩放后点哪格就是哪格），
  实际多指体验以真机为准。
- 双方都是噩梦档时容易走到 50 回合上限按物质分判定（势均力敌的正常结局）。
- `WarKit` 的 `DifficultyMeter` 量尺每次改权重/温度/预算后需手动重跑并回填测试阈值。
- 军费与买断只存本机（`UserDefaults`），没有 iCloud 同步，删 App 即清零；
  钱包作为可注入依赖传给 `GameStore`，冒烟因此能用一份干净账面跑，不受本机历史余额污染。
- `Difficulty.noise` 是从 JS 原型带过来的字段，伤害公式无随机，目前不参与任何决策，
  只在 `PowerPolicy` 重建难度实例时原样搬运 —— 想用它得先决定"无随机"这条要不要破。

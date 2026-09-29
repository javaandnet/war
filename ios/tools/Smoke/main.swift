import Foundation
import Combine
import WarKit

// ============================================================
// 无头冒烟验证
//
// 存在的理由：App 的逻辑层（GameStore / BoardFrame / PowerPolicy）只依赖
// SwiftUI + Combine + WarKit，在 macOS 上同样可编译可运行。于是可以不装
// iOS 模拟器，就把下面这些真跑一遍：
//   1. 点击路由（布阵落子 / 撤销 / 选子 / 机动 / 攻击守卫 / 待命）；
//   2. **AI 回合按事件重放**在真实帧序列上成立 —— 逐帧检查从不出现
//      同格两个活单位、凭空复活、单帧跨多格"瞬移"（这正是斜穿 bug 的形状）；
//   3. 同一份设置两局逐帧指纹完全一致（App 层没有偷偷引入不确定性）；
//   4. BoardFrame 的 terrain[y][x] 与单位坐标口径一致（行优先，防 [x][y] 搞反）；
//   5. 军费不变式：余额永不为负、补贴每局仅一次、买断与充能的界限不串。
//
// 渲染层（SpriteKit/UIKit）不在覆盖范围内 —— 那部分只能靠模拟器或真机看。
// 跑法：sh tools/smoke.sh（WAR_SMOKE_ONLY=manual|auto|intel|chief|wallet 单跑一段）
// ============================================================

// MARK: - 断言

var failures: [String] = []
var passedCount = 0

func expect(_ ok: Bool, _ what: String) {
    if ok {
        passedCount += 1
        print("  ✓ \(what)")
    } else {
        failures.append(what)
        print("  ✗ \(what)")
    }
}

func section(_ title: String) { print("\n\u{001B}[1m▌ \(title)\u{001B}[0m") }

// MARK: - 主线程驱动
//
// GameStore 的动画跑在 MainActor 的 Task 上，而 Task 只有在主队列被抽取时
// 才推进，所以"等一会儿"必须显式转 RunLoop（CLI 里没有 SwiftUI 的场景循环）。

func pump(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.001))
    }
}

func waitUntil(timeout: TimeInterval = 30, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.001))
    }
    return condition()
}

// MARK: - 帧采集与不变式

func manhattan(_ ax: Int, _ ay: Int, _ bx: Int, _ by: Int) -> Int { abs(ax - bx) + abs(ay - by) }

/// 只取会影响画面的字段做逐帧比较
func fingerprint(_ f: BoardFrame) -> String {
    f.units.sorted { $0.id < $1.id }
        .map { "\($0.id):\($0.camp)@(\($0.x),\($0.y)) hp\($0.hp) q\($0.remainingMove)/\($0.remainingAttacks)" }
        .joined(separator: "|")
}

/// 逐帧不变式：任何一条被破坏，都意味着屏幕上会出现规则上不可能的局面
/// - Parameter allowSpawn: 布阵阶段单位本来就要反复放上/拿掉，只查硬不变式
func checkFrameSequence(_ frames: [BoardFrame], context: String, allowSpawn: Bool = false) {
    expect(!frames.isEmpty, "\(context)：采集到帧（\(frames.count) 帧）")

    var overlap = 0
    var outOfBounds = 0
    var badHP = 0
    // 施法相关的逐帧不变式（一次扫全部帧）：
    // • 被冻单位逐次取锚点：一次冰冻期间只能站在一个格上，解冻后重新记 ——
    //   直接比“历史上所有 stunned 帧的落点集合”会误判：同一单位可能被冻两次、中间动过；
    // • 充能不得为负（上限在“本局携带量”那一层，见 1b 与 4）。
    var frozenAnchor: [Int: String] = [:]
    var frozenDrift = 0
    var badCharges = 0
    for f in frames {
        var cells: [String: Int] = [:]
        for u in f.units {
            cells["\(u.x),\(u.y)", default: 0] += 1
            if u.x < 0 || u.x >= f.width || u.y < 0 || u.y >= f.height { outOfBounds += 1 }
            if u.hp <= 0 || u.hp > u.maxHp { badHP += 1 }
            if u.spellCharges.values.contains(where: { $0 < 0 }) { badCharges += 1 }
            if u.stunned {
                let cell = "\(u.x),\(u.y)"
                if let anchor = frozenAnchor[u.id] {
                    if anchor != cell { frozenDrift += 1 }
                } else {
                    frozenAnchor[u.id] = cell
                }
            } else {
                frozenAnchor[u.id] = nil
            }
        }
        if cells.values.contains(where: { $0 > 1 }) { overlap += 1 }
    }
    expect(overlap == 0, "\(context)：没有两个活单位同格（违规帧 \(overlap)）")
    expect(outOfBounds == 0, "\(context)：单位不越界（违规 \(outOfBounds)）")
    expect(badHP == 0, "\(context)：血量恒在 1...maxHp（违规 \(badHP)）")
    expect(frozenDrift == 0, "\(context)：被冻单位解冻前不位移（漂移 \(frozenDrift) 次）")
    expect(badCharges == 0, "\(context)：充能恒不为负（违规 \(badCharges) 帧）")

    var teleports = 0
    var teleportSamples: [String] = []
    var appearances = 0
    var heals = 0
    var unjustifiedHeals = 0
    for (index, pair) in zip(frames, frames.dropFirst()).enumerated() {
        let previous = Dictionary(uniqueKeysWithValues: pair.0.units.map { ($0.id, $0) })
        // 首领的治疗魔法是全场唯一的回血来源：允许 hp 上升，但同一帧
        // 那一格必须带 .heal 飘字 —— 只断“不许回血”会把合法施法误判成 bug，
        // 断“回血必带原因”才同时钉住了时机、原因与盘面自洽。
        let healCells = Set(pair.1.effects.filter { $0.kind == .heal }.map { "\($0.x),\($0.y)" })
        for u in pair.1.units {
            guard let old = previous[u.id] else { appearances += 1; continue }
            if manhattan(old.x, old.y, u.x, u.y) > 1 {
                teleports += 1
                if teleportSamples.count < 6 {
                    teleportSamples.append("帧#\(index) 单位\(u.id) (\(old.x),\(old.y))→(\(u.x),\(u.y))")
                }
            }
            if u.hp > old.hp {
                heals += 1
                if !healCells.contains("\(u.x),\(u.y)") { unjustifiedHeals += 1 }
            }
        }
    }
    // 每帧最多挪一格：内核逐格发布，所以画面不可能出现"斜穿/瞬移"
    expect(teleports == 0, "\(context)：单帧位移 ≤1 格（瞬移 \(teleports) 次）")
    for s in teleportSamples { print("      ⤷ \(s)") }
    if !allowSpawn {
        expect(appearances == 0, "\(context)：不凭空冒出新单位（\(appearances) 次）")
        expect(unjustifiedHeals == 0,
               "\(context)：回血必带治疗飘字（无端回血 \(unjustifiedHeals)/\(heals) 次）")
    }
    // 刻意不断“充能逐帧单调不增”：AI 回合重放开头就有一帧 `restore(before)`，
    // 那是设计上要回填回合起点状态（数值可以回去）。上限的真假设在携带量那一层。
}

final class Recorder {
    private var storage: [BoardFrame] = []
    private var seen: Set<Int> = []
    var cancellable: AnyCancellable?

    /// @Published 的回调就在主线程上跑，这里只做收集
    func append(_ frame: BoardFrame) {
        if seen.insert(frame.revision).inserted { storage.append(frame) }
    }

    var frames: [BoardFrame] { storage }

    @MainActor func attach(_ store: GameStore) {
        cancellable = store.$frame.sink { [weak self] frame in self?.append(frame) }
    }
}

// MARK: - 设置

func makeSettings(mode: GameSettings.Mode, difficulty: String = "hard") -> GameSettings {
    var s = GameSettings()
    s.mode = mode
    s.boardIndex = 1                 // 14×14（默认竖屏棋盘）
    s.terrainSeed = 7
    s.aiSeed = 20260928
    s.difficultyKey = difficulty
    s.stepDelayMs = 0                // 冒烟不等动画
    s.showReach = true
    s.showThreat = true
    s.showBestMark = true
    return s
}

// MARK: - 用例 1/2：布阵、点击路由、手动指令、AI 回合

@MainActor
func smokePlacementAndManualCommand() {
    section("1. 布阵与点击路由（对战 AI 模式）")

    let store = GameStore(settings: makeSettings(mode: .vsAI), wallet: Wallet())
    let recorder = Recorder()
    recorder.attach(store)

    if case .placement(let camp) = store.phase {
        expect(camp == 0, "开局进入蓝方布阵阶段")
    } else {
        expect(false, "开局进入蓝方布阵阶段（实际 \(store.phase)）")
    }

    let board = store.settings.board
    store.handleTap(GridPoint(x: board.width - 2, y: 4))
    pump(0.02)
    expect(store.unitCount(camp: 0) == 0, "点出生区外不放子（提示：\(store.hint ?? "无")）")

    let spot = GridPoint(x: 1, y: 4)
    store.handleTap(spot)
    pump(0.02)
    expect(store.unitCount(camp: 0) == 1, "点出生区落子 1 个")

    store.handleTap(spot)
    pump(0.02)
    expect(store.unitCount(camp: 0) == 0, "再点同一格撤销该子")

    store.placingType = "archer"
    store.handleTap(GridPoint(x: 0, y: 3))
    store.handleTap(GridPoint(x: 2, y: 5))
    store.handleTap(GridPoint(x: 1, y: 6))
    pump(0.05)
    expect(store.unitCount(camp: 0) == 3, "放置 3 个单位")

    store.finishPlacement()
    pump(0.05)
    expect(store.phase == .battle, "完成布阵开战（\(store.statusLine)）")
    // 敌军规模不再是个常量：它由难度军费算出来，所以断言也得回到同一个出处
    let enemyPlan = ArmyComposer.compose(difficultyKey: store.settings.difficultyKey)
    expect(store.unitCount(camp: 1) == (enemyPlan?.soldierCount ?? WarConfig.defaultRoster.count) + 1,
           "敌方按难度军费自动补齐（\(store.unitCount(camp: 1)) 个，含首领；计划 \(enemyPlan?.soldierCount ?? -1) 兵）")
    expect(store.hasLivingChief(camp: 0) && store.hasLivingChief(camp: 1),
           "开战前双方都被补上首领（玩家忘放也得有，否则斩首判据缺一角）")
    expect(store.unitCount(camp: 0) == 4, "玩家只放了 3 个子 + 自动补的 1 名首领 = 4")
    checkFrameSequence(recorder.frames, context: "布阵阶段", allowSpawn: true)

    section("1b. 军费确实转成了兵力（第四个难度旋钮）")

    // 同一张地图、同一个地形 seed，只换难度：兵数与首领充能都必须跟着预算变。
    // 只断"难度名不同"不算测到东西，这里比的是内核真拿出来的那支军。
    let easyStore = GameStore(settings: makeSettings(mode: .vsAI, difficulty: "easy"), wallet: Wallet())
    easyStore.newGame(autoLayout: true)
    let richStore = GameStore(settings: makeSettings(mode: .vsAI, difficulty: "nightmare"), wallet: Wallet())
    richStore.newGame(autoLayout: true)
    pump(0.02)
    let easyChief = easyStore.frame.units.first { $0.camp == 1 && $0.isChief }
    let richChief = richStore.frame.units.first { $0.camp == 1 && $0.isChief }
    expect(easyStore.unitCount(camp: 1) < richStore.unitCount(camp: 1),
           "预算多的档位敌军更多（简单 \(easyStore.unitCount(camp: 1)) vs 噩梦 \(richStore.unitCount(camp: 1))，均含首领）")
    expect(richStore.unitCount(camp: 1) == WarConfig.soldiersPerSide + 1, "噩梦档满编 + 首领")
    expect(easyChief?.spellCharges.values.reduce(0, +) == 0, "简单档买不起充能：首领 0 发")
    expect((richChief?.spellCharges.values.reduce(0, +) ?? 0) > 0, "噩梦档首领带着买到的充能上场")
    // 上场携带表必须逐 key 等于军费计划：否则“买了治疗却只给火球”这种错配没人拦得住
    let richPlan = ArmyComposer.compose(difficultyKey: "nightmare")
    expect(richChief?.spellCharges == (richPlan?.spellCharges ?? [:]),
           "首领上场充能逐 key 等于军费计划（\(richChief?.spellCharges ?? [:])）")
    // 同一难度的两条入口（手动布阵补军 / 一键开战）必须给出同一支军：
    // 难度不能看入口送兵。
    let hardAuto = GameStore(settings: makeSettings(mode: .vsAI, difficulty: "hard"), wallet: Wallet())
    hardAuto.newGame(autoLayout: true)
    expect(hardAuto.unitCount(camp: 1) == store.unitCount(camp: 1),
           "手动布阵与一键开战拿到同一支敌军（\(store.unitCount(camp: 1)) 个）")

    section("2. 手动指令：可达域、机动、攻击守卫、待命")

    let mine = store.frame.units.filter { $0.camp == 0 }.sorted { $0.id < $1.id }
    expect(!mine.isEmpty, "帧里有己方单位")
    let selected = mine[0]
    store.select(selected.id)
    pump(0.02)
    expect(store.frame.reach.isEmpty == false, "选中后发布可达域（\(store.frame.reach.count) 格）")

    var badReach = 0
    for (p, cost) in store.frame.reach {
        if cost < 1 { badReach += 1 }
        // 地形消耗 ≥1，所以曼哈顿距离不可能大于消耗
        if manhattan(selected.x, selected.y, p.x, p.y) > cost { badReach += 1 }
        if store.frame.units.contains(where: { $0.x == p.x && $0.y == p.y }) { badReach += 1 }
    }
    expect(badReach == 0, "可达域：消耗 ≥1、曼哈顿距离 ≤ 消耗、且不含已占格")

    let target = store.frame.reach.keys.max { manhattan(selected.x, selected.y, $0.x, $0.y)
        < manhattan(selected.x, selected.y, $1.x, $1.y) }!
    let moveRecorder = Recorder()
    moveRecorder.attach(store)
    store.handleTap(target)
    expect(waitUntil { store.busy == false }, "机动动画在超时内播完")
    let moved = store.frame.units.first { $0.id == selected.id }
    expect(moved?.x == target.x && moved?.y == target.y,
           "机动落到点去的格子（(\(moved?.x ?? -1),\(moved?.y ?? -1)) vs (\(target.x),\(target.y))）")
    expect(moved?.hp == selected.hp, "机动不掉血")
    checkFrameSequence(moveRecorder.frames, context: "手动机动")

    // 攻击守卫：挑最远的敌人。打不到就必须给提示；真在射程内则允许它掉血
    let foes = store.frame.units.filter { $0.camp == 1 }
    let farFoe = foes.max { manhattan(selected.x, selected.y, $0.x, $0.y)
        < manhattan(selected.x, selected.y, $1.x, $1.y) } ?? foes[0]
    store.select(moved?.id ?? selected.id)
    store.handleTap(GridPoint(x: farFoe.x, y: farFoe.y))
    _ = waitUntil { store.busy == false }
    let foeNow = store.frame.units.first { $0.id == farFoe.id }
    expect(store.hint?.contains("打不到") == true || (foeNow?.hp ?? 0) < farFoe.hp,
           "越射程攻击被拒（提示：\(store.hint ?? "无")）")

    let commandedId = moved?.id ?? selected.id
    store.select(commandedId)
    store.waitSelected()
    pump(0.02)
    let waited = store.frame.units.first { $0.id == commandedId }
    expect(waited?.remainingMove == 0 && waited?.remainingAttacks == 0 && waited?.spent == true,
           "待命清空剩余配额并置灰")

    section("3. AI 回合：事件重放逐帧合法 + 自动交还玩家")

    let aiRecorder = Recorder()
    aiRecorder.attach(store)
    store.endTurn()
    expect(store.currentCamp == 1, "结束回合后阵营切到红方")
    // 必须等到“AI 真跑过 + 阵营回到玩家”，只等 currentCamp == 1 是无效的：
    // endTurn 同步就把它置 1，而“交还”恰是曾经漏掉的那一步。
    let handedBack = waitUntil(timeout: 90) {
        store.lastPlan?.camp == 1 && store.currentCamp == 0 && !store.busy
    }
    expect(handedBack, "AI 打完自动把回合交还玩家（卡住即“第二轮点不动”）")
    expect(store.canCommandCurrentCamp, "交还后玩家可以指挥")
    expect(store.turnCount == 2, "交还时轮次推进到 2（实际 \(store.turnCount)）")

    if let mine = store.frame.units.first(where: { $0.camp == 0 }) {
        store.select(nil)
        store.handleTap(GridPoint(x: mine.x, y: mine.y))
        pump(0.02)
        expect(store.selectedUnit()?.id == mine.id,
               "第二轮确实能操作：点己方单位可选中")
    }

    if let plan = store.lastPlan {
        expect(plan.camp == 1, "决策记录归属红方（camp \(plan.camp)）")
        expect(plan.events.count >= plan.logs.count, "事件数 ≥ 决策数（每单位至少一个事件）")
        print("    战略=\(plan.strategy) 目标=(\(plan.objective.x),\(plan.objective.y)) "
              + "事件\(plan.events.count) 决策\(plan.decisionCount) 用时\(String(format: "%.1f", plan.elapsedMs))ms")
    }
    checkFrameSequence(aiRecorder.frames, context: "AI 回合")
    expect(aiRecorder.frames.count > 2, "AI 回合逐事件发布了多帧（\(aiRecorder.frames.count) 帧）")
}

// MARK: - 用例 4：整局收敛 + 逐帧一致

/// 采到给定帧数就停表。截止条件用**帧预算**而不是回合数：停表是轮询驱动的，
/// 按回合截止时，机器一忙（紧接两次 xcodebuild 之后实测 202 vs 205 帧）就会让
/// 两局各多几帧尾巴，看着像不确定性，其实前缀逐帧全等。截同一长度再比，
/// 才是这条不变式真正想说的话：App 层没有额外随机源。
@MainActor
func replayDigest(_ settings: GameSettings, stopAtFrames target: Int) -> [String] {
    let s = GameStore(settings: settings, wallet: Wallet())
    let r = Recorder()
    r.attach(s)
    s.stopAuto()                     // init 已按 aiVsAI 自动开跑，回到干净起点
    s.newGame(autoLayout: true)
    s.startAuto()
    _ = waitUntil(timeout: 180) {
        if case .over = s.phase { return true }
        return r.frames.count >= target
    }
    s.stopAuto()
    pump(0.02)
    return r.frames.prefix(target).map(fingerprint)
}

@MainActor
func smokeAutoMatch() {
    section("4. 整局自动对战收敛")

    let watcher = GameStore(settings: makeSettings(mode: .aiVsAI), wallet: Wallet())
    let watchRec = Recorder()
    watchRec.attach(watcher)
    watcher.stopAuto()
    watcher.newGame(autoLayout: true)
    watcher.startAuto()
    let finished = waitUntil(timeout: 180) {
        if case .over = watcher.phase { return true }
        return false
    }
    watcher.stopAuto()
    pump(0.02)
    expect(finished, "整局在超时内结束（\(watcher.statusLine)）")
    if case .over(let winner) = watcher.phase {
        expect(winner == 0 || winner == 1 || winner == -1, "判决有明确胜者（\(winner)）")
        if winner != -1 {
            let loser = winner == 0 ? 1 : 0
            // 三种合法终局：败方首领阵亡（斩首）、败方士兵全灭、打满回合上限。
            // 不能再只断 `unitCount == 0`：斩首局败方通常还带着几个兵。
            let beheaded = !watcher.hasLivingChief(camp: loser)
            let soldiersGone = watcher.soldierCount(camp: loser) == 0
            expect(beheaded || soldiersGone || watcher.turnCount >= WarConfig.maxTurns,
                   "胜方成立：对方首领阵亡 / 对方兵全灭 / 到回合上限")
            // 结束原因必须与实际盘面自洽：标错了在这里就推得住
            switch watcher.endReason {
            case .beheaded:
                expect(beheaded, "标为斩首局：败方首领确实已阵亡")
            case .wipeout:
                expect(soldiersGone, "标为歼灭局：败方士兵确实全灭")
            case .turnLimit:
                expect(watcher.turnCount >= WarConfig.maxTurns, "标为回合上限：确实打满")
            case .none:
                expect(false, "对局已结束却没有结束原因")
            }
        }
    }
    print("    回合数 \(watcher.turnCount) · 存活 蓝\(watcher.unitCount(camp: 0))/红\(watcher.unitCount(camp: 1)) "
          + "· \(watcher.endReasonText) · 帧 \(watchRec.frames.count)")
    checkFrameSequence(watchRec.frames, context: "自动对战整局")
    // 发数的真上限是“军费买到的那一叠”：逐帧单调不增会被 AI 回合的
    // `restore(before)`（设计上就要的回填）合法打破，但超上限一定是有东西平白供了法。
    let ceiling = ArmyComposer.compose(difficultyKey: watcher.settings.difficultyKey)?
        .spellCharges.values.reduce(0, +) ?? 0
    var overCeiling = 0
    for f in watchRec.frames {
        for u in f.units where u.isChief && u.spellCharges.values.reduce(0, +) > ceiling { overCeiling += 1 }
    }
    expect(overCeiling == 0, "整局首领发数从未超过军费买到的 \(ceiling) 发（超限 \(overCeiling) 帧）")

    // 施法表现与扣发必须同生同灭：整局只要出现过施法类飘字，就一定有哪位首领的
    // 发数少过上限。内核测试盯“扣得对不对”，这条盯的是“App 演一场不花钱的施法戏”。
    let spellFrames = watchRec.frames.filter { f in
        f.effects.contains { $0.kind == .spell || $0.kind == .heal || $0.kind == .freeze }
    }.count
    let minCharge = [0, 1].map { camp -> Int in
        let totals = watchRec.frames.flatMap(\.units)
            .filter { $0.isChief && $0.camp == camp }
            .map { $0.spellCharges.values.reduce(0, +) }
        return totals.min() ?? 0
    }
    if spellFrames > 0 {
        expect(minCharge.contains(where: { $0 < ceiling }),
               "\(spellFrames) 帧施法飘字 ⇒ 至少一方首领的发数少于上限（实到 蓝\(minCharge[0])/红\(minCharge[1])，上限 \(ceiling)）")
    } else {
        print("      （本局两边都没施法，跳过扣发联动断言）")
    }
    if ProcessInfo.processInfo.environment["WAR_SMOKE_DUMP"] != nil {
        for (i, f) in watchRec.frames.prefix(12).enumerated() {
            print("      frame#\(i) rev\(f.revision): " + fingerprint(f))
        }
    }

    section("5. 同设置两局逐帧一致（App 层无额外随机）")

    let cfg = makeSettings(mode: .aiVsAI, difficulty: "nightmare")
    let frameBudget = 180
    let digestA = replayDigest(cfg, stopAtFrames: frameBudget)
    let digestB = replayDigest(cfg, stopAtFrames: frameBudget)
    expect(digestA.count > 20, "第一局采集 \(digestA.count) 帧")
    expect(digestA == digestB, "两局逐帧指纹完全一致（\(digestA.count) vs \(digestB.count) 帧）")
    if digestA != digestB {
        for (i, pair) in zip(digestA, digestB).enumerated() where pair.0 != pair.1 {
            print("    首个差异帧 #\(i):\n      A \(pair.0)\n      B \(pair.1)")
            break
        }
    }
}

// MARK: - 用例 6：情报面板口径

@MainActor
func smokeIntelPanel() {
    section("6. 情报面板与内核口径")

    let probe = GameStore(settings: makeSettings(mode: .manual), wallet: Wallet())
    probe.newGame(autoLayout: true)
    pump(0.05)
    var mismatch = 0
    for u in probe.frame.units {
        guard let info = probe.inspection(of: u.id) else { mismatch += 1; continue }
        // 行优先：terrain[y][x]。口径反了这里立刻炸
        let keyAtUnitPos = probe.frame.terrain[u.y][u.x]
        if info.terrainName != WarConfig.terrains[keyAtUnitPos]?.name { mismatch += 1 }
        if info.unit.x != u.x || info.unit.y != u.y { mismatch += 1 }
        if info.threat < 0 { mismatch += 1 }
    }
    expect(mismatch == 0, "每个单位的地形取值与 (x,y) 口径一致（不一致 \(mismatch)）")
    expect(probe.canCommandCurrentCamp, "本地双人模式双方都可指挥")
    expect(probe.currentCamp == 0 && probe.turnCount == 1, "开局蓝方第 1 回合")
    probe.endTurn()
    pump(0.1)
    expect(probe.currentCamp == 1, "双人模式结束回合切换到红方")
    expect(probe.canCommandCurrentCamp, "红方回合同样可手动指挥")

    // 省电策略：只降算力不降数值
    let power = PowerPolicy()
    let hard = WarConfig.difficulties["nightmare"]!
    let budgeted = power.budgeted(hard)
    expect(power.preferredFPS == 60 || power.preferredFPS == 30, "帧率取值合法（\(power.preferredFPS)）")
    expect(budgeted.lookahead <= max(1, hard.lookahead), "前瞻降级不会反而加深（\(budgeted.lookahead)）")
    if power.shouldReduceWorkload {
        expect(budgeted.lookahead <= 1, "发热/低电量下前瞻压到 ≤1 层")
    }
    expect(budgeted.temperature == hard.temperature && budgeted.vision == hard.vision,
           "温度与视野不被省电策略改动")
    expect(!power.statusLine.isEmpty, "功耗状态可见：\(power.statusLine)")

    // 图标契约：内核只给字母，棋盘/面板靠 Theme 的映射表出图标。
    // 新增兵种却漏配图标时，唯一后果“默默退回字母”只有肉眼看得到 —— 让测试盯着。
    // 比全量 `unitTypes` 而不是 `unitTypeOrder`：首领不在展示序里，只看后者会漏验它。
    let allTypes = Array(WarConfig.unitTypes.keys).sorted()
    let unmapped = allTypes.filter { Theme.unitIconName(for: $0) == nil }
    expect(unmapped.isEmpty, "每个兵种（含首领）都有图标映射（缺失：\(unmapped)）")
    let badType = probe.frame.units.filter { WarConfig.unitTypes[$0.type] == nil }
    expect(badType.isEmpty, "UnitView.type 都是合法兵种 key（异常 \(badType.count) 个）")
    let chiefs = [0, 1].map { camp in
        probe.frame.units.filter { $0.type == WarConfig.chiefTypeKey && $0.camp == camp }.count
    }
    expect(chiefs == [1, 1], "每阵营帧内恰好 1 名首领（实际 蓝\(chiefs[0]) 红\(chiefs[1])）")
    let terrainWithoutIcon = WarConfig.terrainOrder.filter { Theme.terrainIconName(for: $0) == nil }
    // 魔法图标同一张契约：漏配时面板只能退回内核符号（* / + / =），玩家看不出区别
    let unmappedSpells = WarConfig.spellOrder.filter { Theme.spellIconName(for: $0) == nil }
    expect(unmappedSpells.isEmpty, "每门魔法都有图标映射（缺失：\(unmappedSpells)）")
    print("    图标映射：兵种 \(allTypes.count - unmapped.count)/\(allTypes.count) ，"
          + "无图标地形（保留字母）：\(terrainWithoutIcon)")
}

// MARK: - 用例 7：终局判据（斩首优先于歼灭，且不等到回合上限）

@MainActor
func smokeChiefEndgame() {
    section("7. 首领阵亡立即判负，不等歼灭也不等回合上限")

    // 玩家完全不抵抗：每次轮到我就立刻交出，让噩梦档 AI 单方面推平
    let store = GameStore(settings: makeSettings(mode: .vsAI, difficulty: "nightmare"), wallet: Wallet())
    store.newGame(autoLayout: true)
    let recorder = Recorder()
    recorder.attach(store)

    var loops = 0
    while loops < 4000 {
        loops += 1
        if case .over = store.phase { break }
        if store.currentCamp == 0, !store.busy { store.endTurn() }
        pump(0.01)
    }

    var ended = false
    var winner = -1
    if case .over(let w) = store.phase { ended = (w == 1); winner = w }
    expect(ended, "不抵抗方被推平后对局立即判负（\(store.statusLine)）")

    // 判据要落在「时机 + 原因」上，不能落在“败方一个子不剩”：
    // 首领 value 2.5 是全场最高优先目标，实测常常在它阵亡时蓝方还剩 4 个兵 ——
    // 那正是需求“把首领击败就彻底结束，不管是否剩下兵”的体现。
    let blueAlive = store.frame.units.filter { $0.camp == 0 }.count
    let blueSoldiers = store.soldierCount(camp: 0)
    switch store.endReason {
    case .beheaded:
        expect(!store.hasLivingChief(camp: 0),
               "斩首局：蓝方首领确实阵亡（此时尚存 \(blueAlive) 个单位、其中士兵 \(blueSoldiers) 个）")
    case .wipeout:
        expect(blueSoldiers == 0, "歼灭局：蓝方士兵确实全灭（尚存 \(blueAlive) 个）")
        // 判据顺序的 App 侧反证：歼灭局收尾时败方首领必须还站着 ——
        // 首领先倒的局本该记成斩首，写成歼灭就说明斩首被排到了歼灭后面。
        if winner == 0 || winner == 1 {
            let loser = winner == 0 ? 1 : 0
            expect(store.hasLivingChief(camp: loser),
                   "歼灭局里败方（\(store.campLabel(loser))）首领仍存活（否则这本该是斩首局）")
        }
    default:
        expect(false, "结束原因应是斩首或歼灭，实际为 \(store.endReason)")
    }
    expect(store.turnCount < WarConfig.maxTurns,
           "靠战场判据提前结束而非回合上限兜底（第 \(store.turnCount)/\(WarConfig.maxTurns) 回合结束）")
    expect(store.canCommandCurrentCamp == false, "结束后不再接受指令")

    // 军费必须随终局一起结清：玩家真上场的局，败了也有安慰金，而且明细可展示
    if let settlement = store.lastSettlement {
        expect(settlement.outcome == .loss && settlement.bonus == Wallet.lossConsolation,
               "败局结算：安慰金 \(settlement.bonus)（本局已花 \(settlement.spent)，余额 \(settlement.goldAfter)）")
        expect(store.wallet.gold == settlement.goldAfter && store.wallet.gold >= 0,
               "结算后的余额与明细一致且不为负（\(store.wallet.gold)）")
        expect(store.wallet.losses == 1 && store.wallet.pendingBattleID == nil && store.wallet.charges.isEmpty,
               "战绩记一次、这局的账已结清、本局充能作废")
    } else {
        expect(false, "对战 AI 终局后必须给出结算明细")
    }

    if let survivor = store.frame.units.first {
        store.handleTap(GridPoint(x: survivor.x, y: survivor.y))
        pump(0.02)
        expect(store.selectedUnit() == nil, "结束后点棋盘不会重新选中单位")
    }
    checkFrameSequence(recorder.frames, context: "终局局")
}

// MARK: - 用例 8：军费不变式

/// 钱包是跨局资产，不是本局 cheat code。这里盯的是三条数字不变式，
/// 而不是“按钮能不能点”：余额永不为负、补贴每局仅一份、买断与充能的界限不串。
@MainActor
func smokeWalletEconomy() {
    section("8. 军费：余额永不为负、补贴每局仅一次")

    // —— 补贴与入口 ——
    let store = GameStore(settings: makeSettings(mode: .vsAI, difficulty: "normal"), wallet: Wallet())
    let opening = store.wallet.gold
    expect(opening == Wallet.startingGold + Wallet.battleStipend,
           "开局入账一次补贴（\(Wallet.startingGold) + \(Wallet.battleStipend) = \(opening)）")

    store.newGame()
    store.newGame()
    store.newGame()
    pump(0.02)
    expect(store.wallet.gold == opening, "反复重开不会重复领补贴（仍是 \(store.wallet.gold)）")
    expect(store.wallet.pendingBattleID != nil && store.wallet.battleCounter == 1,
           "同一时刻只有一个未结算的局（已开局 \(store.wallet.battleCounter) 次）")

    let watcher = GameStore(settings: makeSettings(mode: .aiVsAI), wallet: Wallet())
    watcher.stopAuto()
    pump(0.02)
    expect(watcher.wallet.gold == Wallet.startingGold,
           "观战模式不动账：没上场就不该领钱（\(watcher.wallet.gold)）")

    // —— 落子扣款 / 撤销退款 ——
    let price = Wallet.cost(ofUnit: "cavalry")
    let beforePlace = store.wallet.gold
    let spot = GridPoint(x: 1, y: 4)
    store.placeUnit(type: "cavalry", at: spot)
    pump(0.02)
    expect(store.soldierCount(camp: 0) == 1 && store.wallet.gold == beforePlace - price,
           "落一名骑兵扣一个单价（\(beforePlace) → \(store.wallet.gold)）")
    store.undoPlacement(at: spot)
    pump(0.02)
    expect(store.soldierCount(camp: 0) == 0 && store.wallet.gold == beforePlace,
           "撤销该子原额退回（回到 \(store.wallet.gold)）")

    // —— 余额见底：买不起就真买不起 ——
    var brokeWallet = Wallet()
    brokeWallet.gold = 0
    let broke = GameStore(settings: makeSettings(mode: .vsAI), wallet: brokeWallet)
    var badTx = 0
    for p in [GridPoint(x: 1, y: 4), GridPoint(x: 0, y: 3), GridPoint(x: 2, y: 5), GridPoint(x: 1, y: 6)] {
        let before = broke.wallet.gold
        broke.placeUnit(type: "infantry", at: p)
        let delta = before - broke.wallet.gold
        if delta != 0 && delta != Wallet.cost(ofUnit: "infantry") { badTx += 1 }
        if broke.wallet.gold < 0 { badTx += 1 }
    }
    pump(0.02)
    expect(badTx == 0, "每笔扣款要么恰好一个单价、要么分文不动（异常 \(badTx) 笔）")
    expect(broke.soldierCount(camp: 0) == 1
           && broke.wallet.gold == Wallet.battleStipend - Wallet.cost(ofUnit: "infantry"),
           "只拿补贴时只买得起一名步兵：第二子被拒（余额 \(broke.wallet.gold)）")
    expect(broke.wallet.spentThisBattle == Wallet.cost(ofUnit: "infantry"),
           "被拒的尝试不记入本局已花（记了 \(broke.wallet.spentThisBattle)）")

    // —— 买断与充能的界限 ——
    var fresh = Wallet()
    fresh.gold = 500
    expect(!fresh.buyCharge("heal"), "未买断的魔法买不了充能")
    expect(fresh.gold == 500, "这一步分文未扣：买断与充能的先后顺序不由 UI 兜着")
    expect(!fresh.upgradeUnitTier(WarConfig.chiefTypeKey), "首领不卖：不能给首领升档")

    var tight = Wallet()
    tight.gold = Wallet.unlockCost("fireball") - 1
    expect(!tight.unlockSpell("fireball") && tight.gold == Wallet.unlockCost("fireball") - 1,
           "买断钱不够时拒绝且余额不动")
    tight.gold = Wallet.unlockCost("fireball") + Wallet.chargeCost("fireball")
    expect(tight.unlockSpell("fireball") && tight.buyCharge("fireball"), "买断后一发充能刚好付清")
    expect(tight.gold == 0 && tight.charges["fireball"] == 1, "余额恰好清零而不是变负数")
    expect(!tight.buyCharge("fireball") && tight.gold == 0, "余额为 0 时再买仍被拒")

    // —— 升档（跨局永久，该型兵一起升）——
    var up = Wallet()
    up.gold = 1000
    let firstUpgrade = up.upgradeCost("infantry") ?? -1
    expect(firstUpgrade == WarConfig.tierCosts[1] && up.upgradeUnitTier("infantry"),
           "步兵升一档收 tierCosts[1]（\(firstUpgrade)）")
    expect(up.tier(of: "infantry") == 2 && up.gold == 1000 - firstUpgrade, "升档后档位与余额同步")
    _ = up.upgradeUnitTier("infantry")
    expect(up.tier(of: "infantry") == WarConfig.maxTier && up.upgradeCost("infantry") == nil,
           "满档后不再报价（也不该再收钱）")
    expect(!up.upgradeUnitTier("infantry") && up.tier(of: "infantry") == WarConfig.maxTier,
           "满档再升被拒")

    // —— 一键开战：只买非买不可的钱 ——
    var quick = Wallet()
    quick.gold = 100
    let plan = quick.playerQuickDeployPlan()
    expect(plan.soldiers.count == 4 && quick.gold == 0,
           "100 金按默认模板买到买不起为止（\(plan.soldiers.count) 兵、恰余 \(quick.gold)，不为负）")
    expect(plan.spellCharges.isEmpty, "一键开战不自动买充能、不自动升档（那是面板上的主动选择）")

    // —— 结算 ——
    var settleWallet = Wallet()
    settleWallet.beginBattle()
    let afterStipend = settleWallet.gold
    let winBonus = Wallet.winBonusBase + (Wallet.difficultyBonus["nightmare"] ?? 0)
    let won = settleWallet.settle(outcome: .win, difficultyKey: "nightmare")
    expect(won?.bonus == winBonus && settleWallet.gold == afterStipend + winBonus,
           "噩梦档胜利奖金 = 基础 + 难度加成（+\(winBonus)）")
    expect(settleWallet.settle(outcome: .win, difficultyKey: "nightmare") == nil,
           "同一局不重复结算（结算不能当提款机）")
    expect(settleWallet.wins == 1 && settleWallet.pendingBattleID == nil, "战绩只记一次、这局已结清")

    var cycle = Wallet()
    cycle.gold = 500
    expect(cycle.unlockSpell("fireball"), "买断跨局资产入账")
    cycle.beginBattle()
    expect(cycle.buyCharge("fireball") && cycle.battleCharges["fireball"] == 1, "本局携带 1 发")
    let lost = cycle.settle(outcome: .loss, difficultyKey: "easy")
    expect(lost?.bonus == Wallet.lossConsolation && cycle.charges.isEmpty,
           "结清后本局充能作废（败局安慰金 \(lost?.bonus ?? -1)）")
    expect(cycle.isUnlocked("fireball"), "但买断仍留着：跨局资产不因一局失败而蒸发")

    // —— 持久化 ——
    var back: Wallet?
    if let data = try? JSONEncoder().encode(cycle) {
        back = try? JSONDecoder().decode(Wallet.self, from: data)
    }
    expect(back == cycle, "钱包编解码 round-trip（含 Set 与两个字典）")
    cycle.save()
    expect(Wallet.load() == cycle, "落盘后读回一致（App 重启不会忘账）")

    expect(store.wallet.unlockedSpells.isEmpty && store.wallet.unitTiers.isEmpty && store.wallet.charges.isEmpty,
           "上面在局部钱包上的买卖不会回写进对局（值类型拷贝，账目互不串）")

    // —— 面板买到的东西真的上了场（表现层与内核同一个口径）——
    var rich = Wallet()
    rich.gold = 1000
    let shop = GameStore(settings: makeSettings(mode: .vsAI), wallet: rich)
    shop.purchaseTierUpgrade("infantry")
    expect(shop.wallet.tier(of: "infantry") == 2, "军费面板升一档生效")
    shop.placeUnit(type: "infantry", at: GridPoint(x: 1, y: 4))
    shop.placeUnit(type: WarConfig.chiefTypeKey, at: GridPoint(x: 0, y: 3))
    pump(0.02)
    let raised = shop.frame.units.first { $0.type == "infantry" }
    expect(raised?.tier == 2, "布阵放出的兵带着买到的档位上场")
    expect(raised?.maxHp == WarConfig.unitStat("infantry", tier: 2)?.hp,
           "档位数值由内核倍率决定（UI 不自己乘）：\(raised?.maxHp ?? -1) vs \(WarConfig.unitStat("infantry", tier: 2)?.hp ?? -1)")
    // 先放首领、再买断再买发数：携带表必须跟着刷新，不能要求玩家记住一个隐形顺序
    shop.purchaseSpellUnlock("heal")
    shop.purchaseCharge("heal")
    pump(0.02)
    expect(shop.wallet.charges["heal"] == 1 && shop.wallet.isUnlocked("heal"), "买断后充能入账")
    let chiefView = shop.frame.units.first { $0.isChief && $0.camp == 0 }
    expect(chiefView?.spellCharges["heal"] == 1,
           "已放下的首领当场拿到新买的充能（不必重开一局）")
}

// MARK: - 入口

@MainActor
func runAll() {
    print("战棋 App 逻辑层无头冒烟 · 棋盘 \(WarConfig.boardSizes[1].width)×\(WarConfig.boardSizes[1].height)"
          + " · 默认编成 \(WarConfig.defaultRoster.count) 兵 + 1 首领 ×2")
    // WAR_SMOKE_ONLY=manual|auto|intel|chief|wallet 可单选一段快跑（排障用）
    // chief 段的旧名 wipe（当年只验“歼灭即结束”）保留成同义词，以免旧命令行静默跑空
    let only = ProcessInfo.processInfo.environment["WAR_SMOKE_ONLY"]
    if only == nil || only == "manual" { smokePlacementAndManualCommand() }
    if only == nil || only == "auto" { smokeAutoMatch() }
    if only == nil || only == "intel" { smokeIntelPanel() }
    if only == nil || only == "chief" || only == "wipe" { smokeChiefEndgame() }
    if only == nil || only == "wallet" { smokeWalletEconomy() }
}

// CLI 的主线程本就是 main executor，只是顶层代码不被编译器认定为 MainActor，
// 所以这里显式声明这一次隔离转换（SwiftUI 场景循环在真机上由 App 自己提供）。
MainActor.assumeIsolated {
    // 本机上一台真机（或上一次真跑）留下的余额会把“起始 120 + 补贴 30”这类
    // 基线断言带歪，所以从干净账面开始；冒烟内的 store 全部另注新钱包。
    UserDefaults.standard.removeObject(forKey: Wallet.userDefaultsKey)
    runAll()
}

print("\n" + String(repeating: "─", count: 52))
if failures.isEmpty {
    print("\u{001B}[1;32m冒烟通过\u{001B}[0m · \(passedCount) 项断言")
    exit(0)
} else {
    print("\u{001B}[1;31m冒烟失败\u{001B}[0m · \(failures.count)/\(passedCount + failures.count) 项：")
    for f in failures { print("  · \(f)") }
    exit(1)
}

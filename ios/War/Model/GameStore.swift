import Foundation
import SwiftUI
import WarKit

/// 全局游戏状态机（唯一可变状态持有者，钉在 MainActor 上）。
///
/// 三条不可让步的规则：
/// 1. **一切状态写入都走内核方法**（`moveAlongPath` / `attack` / `Replay.apply`），
///    UI 绝不自己扣血或挪子；
/// 2. **AI 回合按事件重放**：`executeTurn` 真实推演 → 记录 final → restore(before)
///    → 逐事件重放动画 → 收尾 restore(final)。所以玩家看到的动画与 AI 的决策
///    必然逐字段一致（内核只有 SeededRng 一个随机源，伤害无随机）。
/// 3. 回合中途被打断（切后台/新开局/停止观战）也必须落在 `final` 上，
///    不允许出现"动画播一半、状态停在中间"的半成品局面。
@MainActor
final class GameStore: ObservableObject {
    enum Phase: Equatable {
        case placement(camp: Int)
        case battle
        case over(winner: Int)      // 0=我方/蓝胜, 1=敌方/红胜, -1=平
    }

    /// 结束原因。不靠它推导胜负（胜负在 `finish` 已定），只给结局卡片一句说明。
    enum EndReason: Equatable {
        case none
        case beheaded      // 首领阵亡（斩首）
        case wipeout       // 士兵全灭
        case turnLimit     // 回合上限，按物质分判定
    }

    // MARK: 对外状态（SwiftUI 观察）
    @Published var settings: GameSettings { didSet { settings.save() } }
    @Published private(set) var frame: BoardFrame
    @Published private(set) var phase: Phase = .battle
    @Published private(set) var currentCamp: Int = 0
    @Published private(set) var turnCount: Int = 0
    @Published private(set) var selectedId: Int?
    @Published private(set) var lastPlan: TurnPlan?
    @Published private(set) var busy = false
    @Published private(set) var autoRunning = false
    @Published private(set) var hint: String?
    @Published private(set) var endReason: EndReason = .none
    /// 跨局军费（注入可换：冒烟需要一个干净的钱包，App 用落盘的那份）
    @Published private(set) var wallet: Wallet { didSet { wallet.save() } }
    /// 本局结算明细（结局卡片展示；新一局开始时清空）
    @Published private(set) var lastSettlement: Wallet.Settlement?

    let power = PowerPolicy()

    // MARK: 内部
    private var bf: Battlefield
    private var ai: WarAI
    private var revision = 0
    private var placementSeq = 0
    private var pendingEffects: [BoardFrame.Effect] = []
    private var playback: Task<Void, Never>?
    private var hintTask: Task<Void, Never>?
    /// 已排队但还没开跑的 AI 回合归属阵营，以及排期令牌。
    /// 用来堵住重复排期：被 cancel 的旧 Task **照样会执行**（Swift 只置取消标志），
    /// 于是旧任务会跑完一整个回合、新任务又因 `busy` 直接返回。
    private var pendingAiCamp: Int?
    private var aiScheduleToken = 0

    private static var initialBoard: Battlefield {
        let b = GameSettings.load().board
        return Battlefield(width: b.width, height: b.height,
                           terrain: Battlefield.generateTerrain(width: b.width, height: b.height, seed: 7))
    }

    init(settings: GameSettings = GameSettings.load(), wallet: Wallet? = nil) {
        self.settings = settings
        self.wallet = wallet ?? Wallet.load()
        self.lastSettlement = nil
        self.bf = GameStore.initialBoard
        self.ai = WarAI(bf: self.bf)
        // 先给 frame 一个合法初值，再走 newGame()（Swift 要求属性先初始化）
        self.frame = BoardFrame(width: bf.width, height: bf.height, terrain: bf.terrain, units: [],
                                reach: [:], threat: nil, bestMarks: [:], deployZoneCamp: nil,
                                objective: nil, spellTargets: [], effects: [], revision: 0)
        newGame()
    }

    // MARK: - 局间控制

    /// 重开一局。`autoLayout` = true 时直接按默认编成开战（跳过布阵）。
    func newGame(autoLayout: Bool = false) {
        stopAuto()
        // 军费只对“玩家真上场”的模式动账：观战 AI 互殴与本地双人都不该刷钱。
        // beginBattle 自己在有未结算局时拒发补贴，所以反复点新开局刷不出第二份。
        if settings.mode == .vsAI {
            mutateWallet { $0.beginBattle() }
            lastSettlement = nil
        }
        let board = settings.board
        bf = Battlefield(width: board.width, height: board.height,
                         terrain: Battlefield.generateTerrain(width: board.width, height: board.height,
                                                              seed: settings.terrainSeed))
        ai = WarAI(bf: bf)
        turnCount = 0
        currentCamp = 0
        selectedId = nil
        lastPlan = nil
        endReason = .none
        placementSeq = 0
        pendingEffects = []
        pendingSpellKey = nil

        if autoLayout {
            deployDefaultArmies()
            beginBattle()
            return
        }
        if settings.mode == .aiVsAI {
            deployDefaultArmies()
            beginBattle()
            startAuto()
            return
        }
        phase = .placement(camp: 0)
        publish()
        flash(settings.mode == .vsAI
              ? "在左侧蓝色出生区点击放置兵力，然后完成布阵"
              : "双方轮流布阵：蓝方出生区在左、红方在右")
    }

    func quickDeploy() { newGame(autoLayout: true) }

    /// 默认布阵。军费只给 AI 那一侧：
    /// • 观战（aiVsAI）：双方同档同预算，既公平又可复现；
    /// • 对站 AI：蓝方是玩家的兵（阶段 4 换成钱包编成），红方按难度拿预算；
    /// • 双人：两侧都走基线免费编成（经济只属于玩家与 AI 之间）。
    private func deployDefaultArmies() {
        switch settings.mode {
        case .aiVsAI:
            _ = bf.setDefaultLayout(difficultyKey: settings.difficultyKey)
        case .vsAI:
            // 玩家侧：一键开战只花“非买不可”的钱（买兵），升档与充能留给军费面板
            let plan = mutateWallet { $0.playerQuickDeployPlan() }
            _ = bf.placeArmy(plan, camp: 0)
            _ = bf.setDefaultLayout(difficultyKey: settings.difficultyKey, camp: 1)
        case .manual:
            _ = bf.setDefaultLayout()
        }
    }

    /// 钱包变更的唯一入口：整体赋值一次，`@Published` 与 `didSet`（落盘）都必然触发，
    /// 不依赖结构体就地写的语义。闭包需要拿到返回值（比如编成）时用它。
    @discardableResult
    private func mutateWallet<T>(_ change: (inout Wallet) -> T) -> T {
        var copy = wallet
        let result = change(&copy)
        wallet = copy
        return result
    }

    private func beginBattle() {
        phase = .battle
        currentCamp = 0
        turnCount = 1
        beginCampTurn(0)
    }

    /// 阵营回合开始的唯一起点：重置该方配额（内核负责）
    private func beginCampTurn(_ camp: Int) {
        bf.beginTurn(camp: camp)
        selectedId = nil
        publish()
        if isAIControlled(camp) {
            scheduleAiTurn(camp)
        } else {
            flash(camp == 0 ? "轮到你行动" : "轮到红方行动")
        }
    }

    // MARK: - 布阵

    func deployZone(of camp: Int) -> Range<Int> {
        camp == 0 ? 0..<WarConfig.deployColumnCount
                  : (bf.width - WarConfig.deployColumnCount)..<bf.width
    }

    func isInDeployZone(camp: Int, _ p: GridPoint) -> Bool { deployZone(of: camp).contains(p.x) }

    func unitCount(camp: Int) -> Int { bf.unitsOfCamp(camp).count }

    /// 当前放置阶段的士兵数（不含首领）
    func soldierCount(camp: Int) -> Int { bf.unitsOfCampExcludingChief(camp).count }

    /// 该阵营是否已有首领（含已阵亡：死后不该再“长”出一个）
    func hasChief(camp: Int) -> Bool {
        bf.units.contains { $0.isChief && $0.camp == camp }
    }

    /// 该阵营首领是否还活着。斩首局结算后“败方仍可存有士兵”，
    /// 所以断言/UI 不能用 `unitCount == 0` 反推结束原因。
    func hasLivingChief(camp: Int) -> Bool { bf.chief(of: camp) != nil }

    /// 在出生区放一个单位；失败原因走 flash，不弹模态
    func placeUnit(type: String, at p: GridPoint) {
        guard case .placement(let camp) = phase else { return }
        guard isInDeployZone(camp: camp, p) else {
            flash("只能放在本方出生区（\(camp == 0 ? "左" : "右") \(WarConfig.deployColumnCount) 列）"); return
        }
        guard bf.isCellAvailable(p) else { flash("该格不可通行或已有人"); return }
        let isChiefType = type == WarConfig.chiefTypeKey
        if isChiefType {
            // 一名以上首领会把“斩首”语义拆成两半（到底哪个死了才算输），直接拒绝
            guard !bf.units.contains(where: { $0.isChief && $0.camp == camp }) else {
                flash("每方只能有一名首领"); return
            }
        } else {
            guard soldierCount(camp: camp) < WarConfig.soldiersPerSide else {
                flash("士兵已达上限（\(WarConfig.soldiersPerSide)），完成布阵吧"); return
            }
        }

        // 只有“玩家自己的兵”要掏钱：首领每局必带且免费，双人模式与观战都不动账。
        let mustPay = settings.mode == .vsAI && camp == 0 && !isChiefType
        let price = Wallet.cost(ofUnit: type)
        if mustPay, !mutateWallet({ $0.spend(price) }) {
            flash("金币不足（需 \(price)，只有 \(wallet.gold)）"); return
        }

        placementSeq += 1
        // 手工单位 id 段与默认布阵（100+/200+）错开，避免重放与快照按 id 找错人
        let unit = WarUnit(id: 500 + camp * 100 + placementSeq, type: type, camp: camp, x: p.x, y: p.y,
                           tier: wallet.tier(of: type))
        guard bf.place(unit) else {
            if mustPay { mutateWallet { $0.refund(price) } }   // 钱扣了人没落下，账目不能留脏数字
            flash("放置失败"); return
        }
        publish()
    }

    /// 布阵阶段点掉自己放错的单位（放出去的钱原路退回）
    func undoPlacement(at p: GridPoint) {
        guard case .placement(let camp) = phase, let unit = bf.getUnitAt(p), unit.camp == camp else { return }
        guard bf.removeForPlacement(id: unit.id) else { return }
        if settings.mode == .vsAI && camp == 0 && !unit.isChief {
            mutateWallet { $0.refund(Wallet.cost(ofUnit: unit.type)) }   // 拿掉的兵得把钱退回去
        }
        publish()
    }

    /// 结束布阵：进入对方布阵，或（对 AI 模式下）自动补齐敌军并开战
    func finishPlacement() {
        guard case .placement(let camp) = phase else { return }
        guard unitCount(camp: camp) > 0 else { flash("至少放一个单位"); return }

        if settings.mode == .manual && camp == 0 {
            phase = .placement(camp: 1)
            publish()
            flash("红方布阵（右侧出生区）")
            return
        }
        if settings.mode == .vsAI && unitCount(camp: 1) == 0 {
            autoDeployRoster(camp: 1)
        }
        // 开战前双方都必须有首领：没放的就补到出生区，
        // 否则那一侧永远触发不了斩首判据（对方打穿它只能等歼灭）。
        for c in [0, 1] { ensureChief(camp: c) }
        // 首领携带的充能到这一刻才写死：玩家完全可能先放首领、再去军费面板买发数
        if settings.mode == .vsAI, let chief = bf.chief(of: 0) {
            chief.carrySpells(wallet.battleCharges)
        }
        beginBattle()
    }

    /// 幂等地保证该阵营有一名首领。id 取现有最大值 +1，
    /// 不靠固定段号 —— 手动布阵（500+）与默认布阵（100+/200+）共存时也不撞号。
    @discardableResult
    private func ensureChief(camp: Int) -> Bool {
        guard !hasChief(camp: camp) else { return true }
        guard let spot = bf.findSpawnSpot(camp: camp, WarConfig.soldiersPerSide) else { return false }
        let id = (bf.units.map(\.id).max() ?? 0) + 1
        return bf.place(WarUnit(id: id, type: WarConfig.chiefTypeKey, camp: camp,
                                x: spot.x, y: spot.y))
    }

    /// 用默认编成给指定阵营补满（对方出生区逐个落位）。
    /// 这一条只服务“玩家布阵 vs AI”：AI 那一侧按难度军费配兵，
    /// 于是手工布阵与一键开战拿到的是同一支敌军（难度不能看入口送兵）。
    private func autoDeployRoster(camp: Int) {
        let plan = ArmyComposer.compose(difficultyKey: settings.difficultyKey) ?? ArmyComposer.baselinePlan
        _ = bf.placeArmy(plan, camp: camp)
    }

    // MARK: - 军费面板（玩家侧购买）

    /// 钱包只对“玩家真上场”的模式有意义：观战与本地双人没进这条流水账，面板整块隐藏。
    var walletUsable: Bool { settings.mode == .vsAI }

    /// 布阵期是否还在（充能只能在布阵期买，见下方守卫）
    private var isPlacementPhase: Bool {
        if case .placement = phase { return true }
        return false
    }

    /// 兵档与魔法买断是跨局永久资产，任何时候都能买（这一局的兵已落定，
    /// 升档只影响之后放出去的兵与下一局）；充能则是本局消耗品。
    var canBuyPermanent: Bool { walletUsable }

    /// 充能的携带发数在「完成布阵」那一刻写死进首领，开战后再买也不会
    /// 凭空多出发数 —— 直接把入口关掉，不做一个“收了钱不办事”的按钮。
    var canBuyCharges: Bool { walletUsable && isPlacementPhase }

    /// 买断一门魔法（跨局永久）。失败原因直陈，不在 UI 再推一遍余额规则。
    func purchaseSpellUnlock(_ spellKey: String) {
        guard canBuyPermanent else { return }
        let stat = WarConfig.spells[spellKey]
        if wallet.isUnlocked(spellKey) { flash("\(stat?.name ?? spellKey)已解锁"); return }
        let cost = Wallet.unlockCost(spellKey)
        if mutateWallet({ $0.unlockSpell(spellKey) }) {
            flash("已解锁\(stat?.name ?? spellKey)（-\(cost)）")
        } else {
            flash("金币不足（需 \(cost)，只有 \(wallet.gold)）")
        }
        publish()
    }

    /// 买一发本局充能（仅布阵期）。买了就得让首领知道，所以同步重写入携带表。
    func purchaseCharge(_ spellKey: String) {
        guard canBuyCharges else {
            flash("充能只能在布阵期购买"); return
        }
        let stat = WarConfig.spells[spellKey]
        guard wallet.isUnlocked(spellKey) else {
            flash("\(stat?.name ?? spellKey)尚未买断"); return
        }
        let cost = Wallet.chargeCost(spellKey)
        guard mutateWallet({ $0.buyCharge(spellKey) }) else {
            flash("金币不足（需 \(cost)，只有 \(wallet.gold)）"); return
        }
        syncChiefCharges()
        flash("已携带 1 发\(stat?.name ?? spellKey)（-\(cost)）")
        publish()
    }

    /// 升兵种档（跨局永久，该型兵一起升）。
    func purchaseTierUpgrade(_ typeKey: String) {
        guard canBuyPermanent else { return }
        let stat = WarConfig.unitTypes[typeKey]
        guard mutateWallet({ $0.upgradeUnitTier(typeKey) }) else {
            if stat?.isChief == true { flash("首领不卖：它每局必带且免费") }
            else { flash("已是最高档或金币不足（只有 \(wallet.gold)）") }
            return
        }
        flash("\(stat?.name ?? typeKey)已升至 \(wallet.tier(of: typeKey)) 档")
        publish()
    }

    /// 把钱包里的充能同步给尚未开战的我方首领：玩家可能先放首领、再回头买发数，
    /// 不能要求他“先买后放”（那是一条只有代码知道的隐形顺序）。
    private func syncChiefCharges() {
        guard let chief = bf.chief(of: 0) else { return }
        chief.carrySpells(wallet.battleCharges)
    }

    // MARK: - 棋盘交互

    /// 单击棋盘：按当前阶段与模式路由（选子 / 移动 / 攻击）
    func handleTap(_ p: GridPoint) {
        guard !busy else { return }
        if case .placement = phase {
            if bf.hasUnitAt(p) { undoPlacement(at: p) } else { placeUnit(type: placingType, at: p) }
            return
        }
        guard phase == .battle, !isAIControlled(currentCamp) else { return }

        // 待施法：这一次点击是选魔法目标，不再走移动/普攻路由
        if let spellKey = pendingSpellKey {
            castSelectedSpell(spell: spellKey, at: p)
            return
        }

        let clicked = bf.getUnitAt(p)
        if let selected = selectedUnit(), selected.camp == currentCamp, clicked == nil,
           bf.computeReachable(selected)[p] != nil {
            moveSelected(to: p)
            return
        }
        if let enemy = clicked, enemy.camp != currentCamp {
            attackSelected(target: enemy)
            return
        }
        if let mine = clicked, mine.camp == currentCamp {
            select(mine.id)
            return
        }
        selectedId = nil
        publish()
    }

    /// 布阵阶段正在放置的兵种（UI 选择器双向绑定）
    @Published var placingType: String = "infantry"

    /// 待施法的魔法 key（点了「施法」但还没选目标）。非 nil 时下一次点击棋盘 = 选施法目标。
    @Published private(set) var pendingSpellKey: String?

    func select(_ id: Int?) {
        selectedId = id
        publish()
    }

    func selectedUnit() -> WarUnit? {
        selectedId.flatMap { bf.findUnitById($0) }
    }

    private func moveSelected(to p: GridPoint) {
        guard let unit = selectedUnit() else { return }
        guard let cell = bf.computeReachable(unit)[p] else { flash("该格不在机动范围内（注意地形消耗）"); return }
        busy = true
        playback = Task { [weak self] in
            guard let self else { return }
            _ = await self.animatePath(unit: unit, path: cell.path)
            self.busy = false
            self.publish()
        }
    }

    private func attackSelected(target: WarUnit) {
        guard let unit = selectedUnit() else { flash("先选择己方单位"); return }
        guard unit.remainingAttacks > 0, bf.canAttackWithLineOfSight(unit, target) else {
            flash("打不到：超出射程、无视线，或本回合已攻击过"); return
        }
        busy = true
        playback = Task { [weak self] in
            guard let self else { return }
            let result = self.bf.attack(unit, target)
            self.emitCombatEffects(attacker: unit, target: target, damage: result.damage,
                                   counter: result.counterDamage, killed: result.targetKilled)
            self.publish()
            _ = await self.nap(self.stepDelay)
            self.busy = false
            self.checkOutcome()
            self.publish()
        }
    }

    /// 主动放弃剩余配额（AI 评分里有 wait 候选，玩家也该有）
    func waitSelected() {
        guard let unit = selectedUnit(), !busy, phase == .battle, !isAIControlled(currentCamp) else { return }
        bf.wait(unit)
        selectedId = nil
        pendingSpellKey = nil
        publish()
    }

    // MARK: - 施法（玩家侧）

    /// 该首领本回合能不能施法（指令面板的「施法」按钮可用性）
    var selectedChiefCanCast: Bool { selectedUnit()?.canCast ?? false }

    /// 选中首领本局携带且还有发的魔法名单（按配置表固定次序，字典无序）
    var selectableSpells: [String] {
        guard let unit = selectedUnit(), unit.isChief else { return [] }
        return WarConfig.spellOrder.filter { unit.charges(for: $0) > 0 }
    }

    /// 进入“待选目标”态；再点一次同一按钮则取消
    func armSpell(_ spellKey: String) {
        guard selectedChiefCanCast, pendingSpellKey != spellKey else { pendingSpellKey = nil; publish(); return }
        pendingSpellKey = spellKey
        let stat = WarConfig.spells[spellKey]
        flash("选择\(stat?.name ?? spellKey)目标（射程 \(stat?.range ?? 0)）")
        publish()
    }

    /// 玩家施法。目标格由点击给出，**校验全在内核**；失败就把内核给的原因原话闪提示，
    /// 不在 UI 复述一套规则（否则两边口径早晚分家）。
    func castSelectedSpell(spell spellKey: String, at p: GridPoint) {
        guard !busy, phase == .battle, !isAIControlled(currentCamp), let unit = selectedUnit() else { return }
        let result = bf.castSpell(unit, spell: spellKey, at: p)
        if !result.success {
            flash(result.message)
            publish()
            return
        }
        emitSpellEffects(result)
        pendingSpellKey = nil
        publish()
        _ = checkOutcome()    // 火球可能当场烧死敌方首领：斩首必须就地生效，不能等回合切换
        publish()
    }

    func endTurn() {
        guard phase == .battle, !busy else { return }
        advanceCamp()
    }

    private func advanceCamp() {
        let next = bf.campOf(otherThan: currentCamp)
        if next == 0 { turnCount += 1 }
        if turnCount > WarConfig.maxTurns { finishByTurnLimit(); return }
        currentCamp = next
        beginCampTurn(next)
    }

    // MARK: - AI 回合

    private func isAIControlled(_ camp: Int) -> Bool {
        switch settings.mode {
        case .aiVsAI: return true
        case .vsAI: return camp == 1
        case .manual: return false
        }
    }

    private func seedFor(camp: Int) -> Int {
        // 同一 (aiSeed, 回合, 阵营) ⇒ 同一随机流：复现一局只需记下两个 seed
        settings.aiSeed &* 31 &+ turnCount &* 7 &+ camp
    }

    /// 可用算力预算下的难度（发热/低电量时前瞻降级）
    var effectiveDifficulty: WarConfig.Difficulty { power.budgeted(settings.difficulty) }

    private func scheduleAiTurn(_ camp: Int) {
        // 同一个阵营只允许有一个待执行排期（`beginCampTurn` 与 `startAuto`
        // 会在同一帧内先后各排一次，不拦住就出现下面的错乱）
        if pendingAiCamp == camp { return }
        pendingAiCamp = camp
        let token = aiScheduleToken + 1
        aiScheduleToken = token
        playback?.cancel()
        playback = Task { [weak self] in
            guard let self else { return }
            await self.runAiTurn(camp: camp)
            if self.aiScheduleToken == token { self.pendingAiCamp = nil }
            // 只有本回合真的跑完才推进；被取消或被更晚的排期接管时交给对方推进
            if !Task.isCancelled, !self.busy { self.afterAiTurn() }
        }
    }

    /// 重放式执行 AI 回合（动画与决策同源，见类型注释第 2 条）
    func runAiTurn(camp: Int) async {
        guard phase == .battle, !busy else { return }
        // 还没开跑就被取消（典型：连续两次排期）：整回合让位给接替者。
        // 否则旧任务会一上来就 `restore(final)` 收尾，画面出现整队“集体瞬移”。
        if Task.isCancelled { return }
        busy = true
        defer { busy = false }

        let started = ProcessInfo.processInfo.systemUptime
        let plan = ai.executeTurn(camp: camp, difficulty: effectiveDifficulty, seed: seedFor(camp: camp))
        lastPlan = plan
        _ = started

        // 回到回合前，逐事件重放
        bf.restore(plan.before)
        publish()
        // 兜底：无论正常播完还是被取消，最终状态都必须等于 AI 推演结果
        defer {
            bf.restore(plan.final)
            publish()
        }

        for event in plan.events {
            if await animate(event: event) { break }     // true = 已取消
        }
    }

    /// 播放单个事件；返回 true 表示任务被取消（调用方据此提前收尾）
    private func animate(event: AiEvent) async -> Bool {
        switch event.kind {
        case .move:
            guard let unit = bf.findUnitById(event.unitId) else { return false }
            return await animatePath(unit: unit, path: event.path)
        case .attack:
            guard Replay.apply(bf, event) else { return false }
            if let attacker = bf.findUnitById(event.unitId),
               let targetId = event.targetId, let target = bf.findUnitById(targetId) {
                emitCombatEffects(attacker: attacker, target: target, damage: event.damage,
                                  counter: event.counterDamage, killed: event.killed)
            } else if event.damage > 0 {
                pendingEffects.append(BoardFrame.Effect(kind: .damage, x: event.to.x, y: event.to.y,
                                                        text: "-\(event.damage)"))
            }
            publish()
            return await nap(stepDelay)
        case .wait:
            return await nap(stepDelay / 3)
        case .spell:
            // 直接调 `castSpell`：参数与 `Replay.apply` 里的 `.spell` 分支完全同一套，
            // 而这里需要 SpellResult 逐格拿真实生效量（被目标残血钳过的那个数），
            // 否则飘字会显一个“宣称值”而非“真实值”。
            guard let key = event.spellKey, let caster = bf.findUnitById(event.unitId),
                  let target = bf.findUnitById(event.targetId ?? -1) else { return false }
            let result = bf.castSpell(caster, spell: key, at: target.position)
            emitSpellEffects(result)
            publish()
            return await nap(stepDelay)
        }
    }

    /// 逐格移动动画。直接调用内核 `moveAlongPath` 走单步，状态始终合法。
    private func animatePath(unit: WarUnit, path: [GridPoint]) async -> Bool {
        for step in path.dropFirst() {
            let from = unit.position
            if Grid.manhattan(from, step) != 1 { continue }
            _ = bf.moveAlongPath(unit, path: [from, step])
            publish()
            if await nap(stepDelay / 2.5) { return true }
        }
        return false
    }

    private func emitCombatEffects(attacker: WarUnit, target: WarUnit, damage: Int,
                                   counter: Int, killed: Bool) {
        if damage > 0 {
            pendingEffects.append(BoardFrame.Effect(kind: killed ? .kill : .damage,
                                                    x: target.x, y: target.y, text: "-\(damage)"))
        }
        if counter > 0 {
            pendingEffects.append(BoardFrame.Effect(kind: .counter, x: attacker.x, y: attacker.y,
                                                    text: "-\(counter)"))
        }
    }

    /// 施法飘字。溅射可能一次命中多格，所以逐格一条；
    /// 逐格顺序取内核 `affectedPoints`（先 y 后 x）—— 字典本身无序，
    /// 直接遍历会让“同 seed 两局逐帧一致”在飘字序上崩掉。
    private func emitSpellEffects(_ result: SpellResult) {
        guard let stat = WarConfig.spells[result.spellKey] else { return }
        for p in result.affectedPoints {
            let value = result.affected[p] ?? 0
            switch stat.effect {
            case .damage:
                let killed = result.killed.contains(p)
                pendingEffects.append(BoardFrame.Effect(kind: killed ? .kill : .spell,
                                                        x: p.x, y: p.y, text: "-\(value)"))
            case .heal:
                pendingEffects.append(BoardFrame.Effect(kind: .heal, x: p.x, y: p.y, text: "+\(value)"))
            case .stun:
                pendingEffects.append(BoardFrame.Effect(kind: .freeze, x: p.x, y: p.y, text: "冻结"))
            }
        }
    }

    private func afterAiTurn() {
        if checkOutcome() { return }
        switch settings.mode {
        case .vsAI:
            // AI 打完必须把回合交还玩家。不推进的话 `currentCamp` 永远停在 AI 方，
            // 而 `handleTap` 第一道守卫就是 `!isAIControlled(currentCamp)`
            // —— 表现是“走完第一轮，第二轮点什么都没反应”。
            advanceCamp()
        case .aiVsAI:
            if autoRunning { advanceCamp() }    // 暂停观战时停在原地等手动继续
        case .manual:
            break                              // 双方都是人，各自点「结束回合」
        }
    }

    /// AI 动画 Task 被取消（切后台/下拉通知中心）且没有接替者时，阵营会停在 AI
    /// 手上永远不动 —— 回前台必须重新排期。
    private func resumeInterruptedAiTurn() {
        guard phase == .battle, !busy, isAIControlled(currentCamp), pendingAiCamp == nil else { return }
        if settings.mode == .aiVsAI, !autoRunning { return }   // 观战被手动暂停就尊重暂停
        scheduleAiTurn(currentCamp)
    }

    // MARK: - 自动对战（观战）

    func startAuto() {
        guard settings.mode == .aiVsAI || isAIControlled(currentCamp) else { return }
        autoRunning = true
        if !busy, phase == .battle, isAIControlled(currentCamp) { scheduleAiTurn(currentCamp) }
        else if phase == .battle { advanceCamp() }
    }

    func stopAuto() {
        autoRunning = false
        pendingAiCamp = nil
        playback?.cancel()
        playback = nil
    }

    func toggleAuto() {
        if autoRunning { stopAuto() } else { startAuto() }
    }

    // MARK: - 结局

    /// 返回 true 表示已结束（UI 据此禁用操作）
    @discardableResult
    private func checkOutcome() -> Bool {
        // 只能在战斗期判定：已经结束后不重复判（.placement 期一方本就没有子）
        guard phase == .battle else { return isOverPhase }
        // 规则本体在内核（`Battlefield.matchOutcome`）：App 只做口径映射。
        // 曾在这里自写一套“歼灭即结束”，而内核 AI 的评分项并不知道首领阵亡才是终局，
        // 两套口径会让难度阶梯实测退化。
        guard case .ended(let winner, let reason) = bf.matchOutcome(forTurnOf: currentCamp) else {
            return false
        }
        switch reason {
        case .beheaded: endReason = .beheaded
        case .wipeout: endReason = .wipeout
        }
        finish(winner: winner)
        return true
    }

    /// 结局卡片上的一句原因说明
    var endReasonText: String {
        switch endReason {
        case .beheaded: return "首领阵亡"
        case .wipeout: return "部队全体覆没"
        case .turnLimit: return "回合上限，按剩余兵力判定"
        case .none: return ""
        }
    }

    private var isOverPhase: Bool {
        if case .over = phase { return true }
        return false
    }

    private func finishByTurnLimit() {
        endReason = .turnLimit
        finish(winner: bf.materialWinner())
        flash("达到回合上限，按剩余兵力判定")
    }

    private func finish(winner: Int) {
        stopAuto()
        selectedId = nil
        // 结算：胜负相对玩家（camp0）换算，平局按物质分判出的 -1 走安慰金以外的档。
        // `settle` 自己在没有待结算局时返回 nil，所以重复结束/观战局都不会发钱。
        if settings.mode == .vsAI {
            let outcome: Wallet.Outcome = winner == 0 ? .win : (winner == -1 ? .draw : .loss)
            lastSettlement = mutateWallet { $0.settle(outcome: outcome, difficultyKey: settings.difficultyKey) }
        }
        phase = .over(winner: winner)
        publish()
    }

    func restartSameSeed() { newGame(autoLayout: true) }

    // MARK: - 派生信息（UI 直接读）

    var stepDelay: Double { settings.stepDelayMs * power.animationScale }

    /// 当前回合是否由玩家指挥（AI 回合时禁用指令按钮）
    var canCommandCurrentCamp: Bool {
        phase == .battle && !isAIControlled(currentCamp)
    }

    func materialScore(camp: Int) -> Double { bf.materialScore(camp: camp) }

    /// 该兵种按钱包当前档取实际数值（布阵页与升档页共用）。
    /// 倍率口径归内核 `WarConfig.unitStat`，UI 不自己乘 —— 否则面板说的与棋盘上跑的不是一个兵。
    func placedStat(for typeKey: String) -> WarConfig.UnitStat {
        WarConfig.unitStat(typeKey, tier: wallet.tier(of: typeKey)) ?? WarConfig.unitTypes[typeKey]!
    }

    /// 设置变更但不重开局：只重发一帧（叠层开关等立即生效项）
    func publishSettingsChange() { publish() }

    /// 棋盘视图复位请求（「全图」按钮每点一次 +1，`BoardView` 在 updateUIView 里比对消费）。
    /// 走单向数据流而不是持有 scene：缩放状态归场景，按钮只是指令。
    @Published var viewResetTick = 0

    var statusLine: String {
        switch phase {
        case .placement(let camp):
            return "布阵：\(campLabel(camp))（\(unitCount(camp: camp))/\(WarConfig.maxUnitsPerSide)）"
        case .battle:
            let actor = isAIControlled(currentCamp) ? "\(campLabel(currentCamp))·AI" : campLabel(currentCamp)
            return "第 \(turnCount)/\(WarConfig.maxTurns) 回合 · \(actor)"
        case .over(let winner):
            return winner == -1 ? "对局结束：平局" : "对局结束：\(campLabel(winner))获胜"
        }
    }

    func campLabel(_ camp: Int) -> String {
        switch settings.mode {
        case .vsAI: return camp == 0 ? "我方" : "敌方"
        case .aiVsAI: return camp == 0 ? "蓝方AI" : "红方AI"
        case .manual: return camp == 0 ? "蓝方" : "红方"
        }
    }

    func inspection(of id: Int?) -> UnitInspection? {
        guard let id, let unit = bf.findUnitById(id), !unit.isDead else { return nil }
        let terrain = bf.getTerrain(unit.position)
        let enemy = bf.campOf(otherThan: unit.camp)
        let map = bf.buildThreatMap(camp: enemy)
        let view = makeUnitView(unit)
        return UnitInspection(unit: view, terrainName: terrain.name, terrainDefBonus: terrain.defBonus,
                              moveCost: terrain.moveCost, attack: unit.atk, defense: unit.def,
                              attackRange: unit.attackRange, counterAttack: unit.counterAttack,
                              threat: bf.threatAt(map, unit.x, unit.y))
    }

    // MARK: - 帧装配

    private func publish() {
        revision += 1
        frame = makeFrame()
    }

    private func makeUnitView(_ unit: WarUnit) -> BoardFrame.UnitView {
        let selectable = phase == .battle && unit.camp == currentCamp && !isAIControlled(currentCamp)
        let targetable: Bool
        if let selected = selectedUnit(), selected.camp != unit.camp, !busy {
            targetable = selected.remainingAttacks > 0 && bf.canAttackFrom(selected, from: selected.position, to: unit)
        } else {
            targetable = false
        }
        return BoardFrame.UnitView(id: unit.id, camp: unit.camp, x: unit.x, y: unit.y,
                                   type: unit.type, symbol: unit.symbol, name: unit.name, tier: unit.tier,
                                   hp: unit.hp, maxHp: unit.maxHp,
                                   remainingMove: unit.remainingMove, remainingAttacks: unit.remainingAttacks,
                                   spent: unit.remainingMove == 0 && unit.remainingAttacks == 0,
                                   selected: unit.id == selectedId && selectable,
                                   targetable: targetable,
                                   isChief: unit.isChief, spellCharges: unit.spellCharges, stunned: unit.stunned)
    }

    private func makeFrame() -> BoardFrame {
        var views: [BoardFrame.UnitView] = []
        views.reserveCapacity(bf.units.count)
        for unit in bf.units where !unit.isDead { views.append(makeUnitView(unit)) }

        var reach: [GridPoint: Int] = [:]
        if settings.showReach, let unit = selectedUnit(), unit.camp == currentCamp, phase == .battle {
            for (p, cell) in bf.computeReachable(unit) where p != unit.position { reach[p] = cell.cost }
        }

        var threat: [Double]?
        if settings.showThreat, phase == .battle {
            threat = bf.buildThreatMap(camp: bf.campOf(otherThan: currentCamp))
        }

        var marks: [GridPoint: String] = [:]
        if settings.showBestMark, let plan = lastPlan {
            for log in plan.logs {
                if let top = log.top.first { marks[top.action] = "★" }
            }
        }

        var deployCamp: Int?
        if case .placement(let camp) = phase { deployCamp = camp }

        // 待施法高亮：合法目标由内核那套校验算（射程 + 视线 + 阵营），
        // UI 不自己推 —— 与 `castSpell` 不一致时玩家会点到“亮了却放不出去”的格。
        var spellTargets: Set<GridPoint> = []
        if let key = pendingSpellKey, let stat = WarConfig.spells[key],
           let caster = selectedUnit(), caster.isChief, caster.camp == currentCamp,
           phase == .battle, !isAIControlled(currentCamp), !busy {
            for target in bf.units where !target.isDead {
                let p = target.position
                guard Grid.manhattan(caster.position, p) <= stat.range,
                      bf.hasLineOfSight(from: caster.position, to: p) else { continue }
                switch stat.effect {
                case .damage: if target.camp != caster.camp { spellTargets.insert(p) }
                case .stun: if target.camp != caster.camp && !target.stunned { spellTargets.insert(p) }
                case .heal: if target.camp == caster.camp && target.hp < target.maxHp { spellTargets.insert(p) }
                }
            }
        }

        let effects = pendingEffects
        pendingEffects = []
        return BoardFrame(width: bf.width, height: bf.height, terrain: bf.terrain, units: views,
                          reach: reach, threat: threat, bestMarks: marks, deployZoneCamp: deployCamp,
                          objective: settings.showBestMark ? lastPlan?.objective : nil,
                          spellTargets: spellTargets,
                          effects: effects, revision: revision)
    }

    // MARK: - 小工具

    /// 睡眠；返回 true 表示任务已被取消
    @discardableResult
    private func nap(_ ms: Double) async -> Bool {
        if ms <= 0 {
            // 0 节拍 = 极速观战：不睡，但仍要让出线程，并响应取消
            await Task.yield()
            return Task.isCancelled
        }
        try? await Task.sleep(nanoseconds: UInt64(ms * 1_000_000))
        return Task.isCancelled
    }

    private func flash(_ message: String) {
        hint = message
        hintTask?.cancel()
        hintTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.hint = nil
        }
    }

    /// 退到后台：立刻停表 + 取消动画，回到前台再续
    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background, .inactive:
            if autoRunning { stopAuto(); flash("已暂停自动对战（回到前台可继续）") }
            playback?.cancel()
        case .active:
            power.refresh()
            publish()
            resumeInterruptedAiTurn()
        @unknown default:
            break
        }
    }
}

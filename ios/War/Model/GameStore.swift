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
        case surrender     // 主动投降
    }

    /// 闯关进度（单独落盘）。currentLevel = **接下来要打的那一关**（= 尚未通过的第一关）；
    /// entrySnapshot = 入关那一刻（补贴之前）的钱包，败局/平局就整体回滚到这份 ——
    /// 于是"打不过就反复尝试"不会被扣钱惩罚，也不会靠刷败局补贴变富。
    /// unitUpgrades = 闯关专用的升级账（与永久钱包账独立、从 T0 起、跨关累积）；
    /// entryUpgrades = 入关那一刻的升级账快照，败局/平局随钱包一起回滚（失败也重置升级账）。
    /// unitGrowth = 战场成长账（键 = 基础兵种 key，值 = 该兵种练到的等级/经验/已分属性点/分支），
    /// entryGrowth = 入关那一刻的成长快照，败局/平局一起回滚 —— 与钱同一套语义：
    /// 打过才算练过，没打过的关不能靠反复失败白刷等级。
    /// maxLevelReached = 曾到达过的最高关号（只读展示用，不参与任何结算）。
    struct CampaignProgress: Codable {
        var currentLevel: Int = 1
        var entrySnapshot: Wallet?
        var unitUpgrades: [String: WarConfig.Upgrades] = [:]
        var entryUpgrades: [String: WarConfig.Upgrades]?
        var unitGrowth: [String: WarConfig.Growth.UnitGrowth] = [:]
        var entryGrowth: [String: WarConfig.Growth.UnitGrowth]?
        var maxLevelReached: Int = 1

        static let userDefaultsKey = "war.campaign.v1"
        static func load() -> CampaignProgress {
            guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
                  let saved = try? JSONDecoder().decode(CampaignProgress.self, from: data) else {
                return CampaignProgress()
            }
            return saved
        }
        func save() {
            if let data = try? JSONEncoder().encode(self) {
                UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
            }
        }

        // 与 `Wallet` 同一套理由：合成的 Decodable 不用默认值兜底缺键，
        // 加一个字段就会让旧存档整本解不开（而 `load` 包的是 `try?` → 静默归零，
        // 于是“升了十几关”一进 App 就回到第 1 关）。新字段必须逐键兜底。
        private enum CodingKeys: String, CodingKey {
            case currentLevel, entrySnapshot, unitUpgrades, entryUpgrades
            case unitGrowth, entryGrowth, maxLevelReached
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func val<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
                (try? c.decode(T.self, forKey: key)) ?? fallback
            }
            currentLevel = val(.currentLevel, 1)
            entrySnapshot = val(.entrySnapshot, nil as Wallet?)
            unitUpgrades = val(.unitUpgrades, [:])
            entryUpgrades = val(.entryUpgrades, nil as [String: WarConfig.Upgrades]?)
            // 旧存档没记成长账：那时还没有战场等级，人人 1 级 = 空账
            unitGrowth = val(.unitGrowth, [:])
            entryGrowth = val(.entryGrowth, nil as [String: WarConfig.Growth.UnitGrowth]?)
            // 旧存档没记“最高关”：当时的语义是“赢了才手点下一关”，于是当前关就是最远关
            maxLevelReached = val(.maxLevelReached, currentLevel)
        }
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
    /// 跨局军费（注入可换：冒烟需要一个干净的钱包，App 用落盘的那份）。
    /// 落盘目标由 `walletMode` 决定 —— 钱包按模式分账，所以“写哪一本”不能从 wallet 自身推出来。
    @Published private(set) var wallet: Wallet { didSet { wallet.save(for: walletMode) } }
    /// 本局结算明细（结局卡片展示；新一局开始时清空）
    @Published private(set) var lastSettlement: Wallet.Settlement?
    /// 闯关进度（当前关 + 入关钱包快照），单独落盘。
    @Published private(set) var campaign: CampaignProgress { didSet { campaign.save() } }
    /// 刚刚结束的那一关是第几关（只在闯关模式下写）。结局卡片靠它说“第 N 关通关”，
    /// 而不把 `campaign.currentLevel` 兼做两个语义（当前挑的关 / 刚打完的关）。
    @Published private(set) var lastCampaignLevel: Int?

    let power = PowerPolicy()

    // MARK: 内部
    private var bf: Battlefield
    private var ai: WarAI
    /// 当前钱包属于哪个模式（非 @Published：它不该驱动任何视图，只是落盘的路标）
    private var walletMode: GameSettings.Mode
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
        self.walletMode = settings.mode
        self.wallet = wallet ?? Wallet.load(for: settings.mode)
        self.lastSettlement = nil
        // 注入钱包 = 测试/干净账面，闯关进度也一起归零；否则读落盘进度以续关。
        self.campaign = wallet != nil ? CampaignProgress() : CampaignProgress.load()
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
        // 重开前先退钱：手动放的兵马上要随棋盘一起消失，不退就是“兵没了钱也没了”，
        // 而下面的一键编成又会再买一批（双重扣费）。必须在拍快照与发补贴之前。
        refundManualPlacement()
        switchWalletAccount()
        // 闯关：每关参数由公式固定，开局前（补贴之前）给钱包/升级账/成长账各拍一张"入关快照"，
        // 失败时三者一起整体回滚（玩家用同样的钱、同样的升级与等级原地重打）。
        if settings.mode == .campaign {
            campaign.entrySnapshot = wallet
            campaign.entryUpgrades = campaign.unitUpgrades
            campaign.entryGrowth = campaign.unitGrowth
            applyCampaignLevel()
        }
        // 军费只对"玩家真上场"的模式动账（对战 AI / 闯关）：观战与本地双人都不该刷钱。
        // beginBattle 自己在有未结算局时拒发补贴，所以反复点新开局刷不出第二份。
        if settings.mode.isPlayerVsAI {
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
        lastCampaignLevel = nil
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
        if settings.mode == .campaign {
            flash("第 \(campaign.currentLevel) 关：布置兵力后完成布阵")
        } else if settings.mode == .vsAI {
            flash("在左侧蓝色出生区点击放置兵力，然后完成布阵")
        } else {
            flash("双方轮流布阵：蓝方出生区在左、红方在右")
        }
    }

    func quickDeploy() { newGame(autoLayout: true) }

    /// 默认布阵。军费只给 AI 那一侧：
    /// • 观战（aiVsAI）：双方同档同预算，既公平又可复现；
    /// • 对站 AI：蓝方是玩家的兵（阶段 4 换成钱包编成），红方按难度拿预算；
    /// • 双人：两侧都走基线免费编成（经济只属于玩家与 AI 之间）。
    private func deployDefaultArmies() {
        switch settings.mode {
        case .aiVsAI:
            // 两边都是 AI：升级/转职瞬间自动把属性点分掉（`autoGrows` 缺省即 true）
            _ = bf.setDefaultLayout(difficultyKey: settings.difficultyKey)
        case .vsAI, .campaign:
            // 玩家侧：一键开战只花"非买不可"的钱（买兵），升档与充能留给军费面板；
            // 成长按闯关账带入（其余模式为空 = 人人 1 级），且**不**自动分点 —— 那是玩家的权力
            let plan = mutateWallet { $0.playerQuickDeployPlan(unitUpgrades: activeUpgradeMap) }
            _ = bf.placeArmy(plan, camp: 0, autoGrows: false, growth: activeGrowthMap)
            // 敌方：闯关按关卡公式的独立三线升级配兵（不读玩家钱包），其余按难度档基线预算。
            // 敌军永不带成长：否则"同关两局"会因玩家练到哪一级而分叉，难度旋钮也失真
            if settings.mode == .campaign {
                _ = bf.placeArmy(ArmyComposer.campaignEnemyPlan(level: campaign.currentLevel), camp: 1)
            } else {
                _ = bf.setDefaultLayout(difficultyKey: settings.difficultyKey, camp: 1)
            }
        case .manual:
            // 本地双人：两边都是人，点数留着由玩家自己分
            _ = bf.setDefaultLayout(autoGrows: false)
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

    /// 模式切换＝换一本账：四个模式各记自己的军费，买断/兵档/金币互不通用。
    /// 共用一本时“切个模式”就把别处刷出来的钱带进本局，而闯关败局的“回滚到入关快照”
    /// 也会连带改到对战账 —— 两个模式互相能改写对方的资产。
    /// 必须在拍入关快照与发补贴之前完成，否则新模式的开局会记到旧账上。
    private func switchWalletAccount() {
        guard settings.mode != walletMode else { return }
        wallet.save(for: walletMode)          // 旧账先落盘（didSet 已写过，这里不依赖它）
        walletMode = settings.mode
        wallet = Wallet.load(for: walletMode)
    }

    /// 手动布阵已扣的钱在重开时原路退回（只退自己那一侧的士兵，首领本来免费）。
    /// 只在“布阵期就重开”时退：开战之后这一仗已经打了，扣费属于已结算语义。
    private func refundManualPlacement() {
        guard case .placement(let camp) = phase, camp == 0, settings.mode.isPlayerVsAI else { return }
        for unit in bf.unitsOfCamp(0) where !unit.isChief {
            mutateWallet { $0.refund(Wallet.cost(ofUnit: unit.type)) }
        }
        mutateWallet { $0.spentThisBattle = 0 }   // 上一批的花费不该再出现在本局账上
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
        // 待施法是“本回合本方子”的临时态：回合一切换还留着它，
        // 下一次点棋盘会被当成施法目标而永远选不中子。
        pendingSpellKey = nil
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
        let mustPay = settings.mode.isPlayerVsAI && camp == 0 && !isChiefType
        let price = Wallet.cost(ofUnit: type)
        if mustPay, !mutateWallet({ $0.spend(price) }) {
            flash("金币不足（需 \(price)，只有 \(wallet.gold)）"); return
        }

        placementSeq += 1
        // 手工单位 id 段与默认布阵（100+/200+）错开，避免重放与快照按 id 找错人
        let unit = WarUnit(id: 500 + camp * 100 + placementSeq, type: type, camp: camp, x: p.x, y: p.y,
                           upgrades: activeUpgrades(for: type),
                           autoGrows: isAIControlled(camp),
                           growth: camp == 0 ? activeGrowth(for: type) : nil)
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
        if settings.mode.isPlayerVsAI && camp == 0 && !unit.isChief {
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
        if settings.mode.isPlayerVsAI && unitCount(camp: 1) == 0 {
            autoDeployRoster(camp: 1)
        }
        // 开战前双方都必须有首领：没放的就补到出生区，
        // 否则那一侧永远触发不了斩首判据（对方打穿它只能等歼灭）。
        for c in [0, 1] { ensureChief(camp: c) }
        // 首领携带的充能到这一刻才写死：玩家完全可能先放首领、再去军费面板买发数
        if settings.mode.isPlayerVsAI, let chief = bf.chief(of: 0) {
            chief.carrySpells(wallet.battleCharges, levels: wallet.battleSpellLevels)
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
                                x: spot.x, y: spot.y,
                                autoGrows: isAIControlled(camp),
                                growth: camp == 0 ? activeGrowth(for: WarConfig.chiefTypeKey) : nil))
    }

    /// 用默认编成给指定阵营补满（对方出生区逐个落位）。
    /// 这一条只服务“玩家布阵 vs AI”：AI 那一侧按难度军费配兵，
    /// 于是手工布阵与一键开战拿到的是同一支敌军（难度不能看入口送兵）。
    private func autoDeployRoster(camp: Int) {
        // 闯关：敌方按关卡公式的固定预算配兵（不读玩家钱包，保证每关可复现）；
        // 其余模式按难度档基线预算。
        let plan: ArmyPlan
        if settings.mode == .campaign {
            plan = ArmyComposer.campaignEnemyPlan(level: campaign.currentLevel)
        } else {
            plan = ArmyComposer.compose(difficultyKey: settings.difficultyKey) ?? ArmyComposer.baselinePlan
        }
        _ = bf.placeArmy(plan, camp: camp, autoGrows: isAIControlled(camp))
    }

    // MARK: - 军费面板（玩家侧购买）

    /// 钱包只对“玩家真上场”的模式有意义（对战 AI / 闯关）：观战与本地双人没进这条流水账，面板整块隐藏。
    var walletUsable: Bool { settings.mode.isPlayerVsAI }

    /// 当前模式下的"活跃升级账"：闯关读跨关累积的 campaign 账（从 T0 起、与永久账独立），
    /// 其余模式读永久钱包账。放兵 / 一键开战 / 升档 / 情报展示均走这一入口。
    func activeUpgrades(for typeKey: String) -> WarConfig.Upgrades {
        if settings.mode == .campaign {
            return campaign.unitUpgrades[typeKey] ?? WarConfig.Upgrades()
        }
        return wallet.upgrades(of: typeKey)
    }

    /// 活跃升级账的整张快照（一键开战编成用）。
    var activeUpgradeMap: [String: WarConfig.Upgrades] {
        settings.mode == .campaign ? campaign.unitUpgrades : wallet.unitUpgrades
    }

    /// 这个兵种**带回战场**的战场成长（闯关＝跨关累积账；其余模式一律 nil = 1 级起步，
    /// 成长只在局内有效、不污染任何账本）。与升级账分叉的原因相同：
    /// 一个花钱、一个打仗，只有闯关的仗才值得记到下一关。
    func activeGrowth(for typeKey: String) -> WarConfig.Growth.UnitGrowth? {
        guard settings.mode == .campaign else { return nil }
        return campaign.unitGrowth[typeKey]
    }

    /// 整张成长账快照（一键开战编成用；非闯关模式为空）
    var activeGrowthMap: [String: WarConfig.Growth.UnitGrowth] {
        settings.mode == .campaign ? campaign.unitGrowth : [:]
    }

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

    /// 反悔窗口：**只有本局尚未落定的布阵期**能退。开战后不退 ——
    /// 已经拿这一档打过一仗再把钱拿回来，等于白嫖一档，比刷钱隐蔽得多。
    var canRefundPermanent: Bool { walletUsable && isPlacementPhase }

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

    /// 升兵种某条线（攻/防/生命）。写哪本账看模式：
    /// • 闯关 → 写跨关累积的 campaign 升级账（与永久账独立）；
    /// • 其余 → 写钱包的永久升级账。钱都从 wallet 扣（闯关的金也是累计到本关的那份）。
    func purchaseUpgrade(_ typeKey: String, track: WarConfig.UpgradeTrack) {
        guard canBuyPermanent else { return }
        guard let stat = WarConfig.unitTypes[typeKey], !stat.isChief, stat.cost > 0 else {
            flash("首领不卖：它每局必带且免费"); return
        }
        let current = activeUpgrades(for: typeKey)
        let cost = WarConfig.upgradeCost(typeKey: typeKey, currentLevel: current.level(track))
        guard wallet.gold >= cost else {
            flash("金币不足（需 \(cost)，只有 \(wallet.gold)）"); return
        }
        var upgraded = current
        upgraded.bump(track)
        mutateWallet { w in
            w.spend(cost)
            if self.settings.mode != .campaign { w.unitUpgrades[typeKey] = upgraded }
        }
        if settings.mode == .campaign {
            campaign.unitUpgrades[typeKey] = upgraded
        }
        flash("\(stat.name)「\(track.label)」升至 T\(upgraded.level(track))（-\(cost)）")
        publish()
    }

    /// 把钱包里的充能与档位同步给尚未开战的我方首领：玩家可能先放首领、再回头买发数，
    /// 不能要求他“先买后放”（那是一条只有代码知道的隐形顺序）。
    private func syncChiefCharges() {
        guard let chief = bf.chief(of: 0) else { return }
        chief.carrySpells(wallet.battleCharges, levels: wallet.battleSpellLevels)
    }

    // MARK: - 反悔（退兵档 / 退魔法档 / 退充能）：只在布阵期，退的是当初实付

    /// 退兵种某条线一档。钱从本模式钱包回，账本走 `activeUpgrades` 的同一路由降回去：
    /// **在哪儿买的只能在哪儿退**，跨模式退不了别人账上的钱。
    func sellUpgrade(_ typeKey: String, track: WarConfig.UpgradeTrack) {
        guard canRefundPermanent else { flash("只有布阵期能退档（开战后这一档已经算用掉了）"); return }
        let current = activeUpgrades(for: typeKey)
        let name = WarConfig.unitTypes[typeKey]?.name ?? typeKey
        guard current.level(track) > 0 else {
            flash("\(name)「\(track.label)」还在 T0，没有可退的档"); return
        }
        let price = WarConfig.upgradeCost(typeKey: typeKey, currentLevel: current.level(track) - 1)
        guard price < Int.max else { flash("首领不卖，也就没有可退的档"); return }
        // 白嫖守卫：内核里 `upgrades` 是创建那一刻的快照（不可变），退档拉不回已放下去的兵，
        // 所以场上还站着按这一档放下的该型兵时不退 —— 先点掉它们（兵价另退）。
        let standing = bf.units.filter { !$0.isDead && $0.camp == 0 && $0.type == typeKey
            && $0.upgrades.level(track) > current.level(track) - 1 }
        guard standing.isEmpty else {
            flash("场上还有 \(standing.count) 个按 T\(current.level(track)) 放下的\(name)：先撤销它们再退档")
            return
        }
        if settings.mode == .campaign {
            var downgraded = current
            downgraded.lower(track)
            campaign.unitUpgrades[typeKey] = downgraded
            mutateWallet { $0.refund(price) }
        } else if mutateWallet({ $0.downgradeTrack(typeKey, track) }) == nil {
            return                              // 账本拒了（T0 / 首领线）：钱一分不动
        }
        flash("\(name)「\(track.label)」退回 T\(current.level(track) - 1)（+\(price)）")
        publish()
    }

    /// 退一档魔法。首领的携带表跟着降回去（买档时是当场写入的，退款也必须当场写回，
    /// 否则“钱回来了而本局首领还带着高档”就是一条白拿）。买断本身不退。
    func sellSpellLevel(_ spellKey: String) {
        guard canRefundPermanent else { flash("只有布阵期能退档（开战后这一档已经算用掉了）"); return }
        let name = WarConfig.spells[spellKey]?.name ?? spellKey
        guard wallet.spellLevel(spellKey) > 0 else {
            flash("\(name)还在基础档，没有可退的档"); return
        }
        guard let price = mutateWallet({ $0.downgradeSpellLevel(spellKey) }) else { return }
        syncChiefCharges()
        flash("\(name)退回 \(wallet.spellLevel(spellKey)) 档（+\(price)）")
        publish()
    }

    /// 退一发布阵期买好的充能（发数是本局携带量，退掉就当场从首领身上减下来）。
    func sellCharge(_ spellKey: String) {
        guard canRefundPermanent else { flash("充能只能在布阵期退"); return }
        let name = WarConfig.spells[spellKey]?.name ?? spellKey
        guard (wallet.charges[spellKey] ?? 0) > 0 else {
            flash("本局没带\(name)的发数，没什么可退"); return
        }
        guard let price = mutateWallet({ $0.sellCharge(spellKey) }) else { return }
        syncChiefCharges()
        flash("退回 1 发\(name)（+\(price)）")
        publish()
    }

    /// 升一档魔法（跨局永久，与买断同一本账）。与买断同为“永久资产”，
    /// 所以开战后也能买：它只影响下一局落定的首领，不吃本局的充能名额。
    /// 退档同一条链，但只限布阵期（见 `sellSpellLevel`）。
    func purchaseSpellLevel(_ spellKey: String) {
        guard canBuyPermanent else { return }
        let stat = WarConfig.spells[spellKey]
        guard wallet.isUnlocked(spellKey) else {
            flash("\(stat?.name ?? spellKey)尚未买断"); return
        }
        let current = wallet.spellLevel(spellKey)
        guard current < WarConfig.maxSpellLevel else {
            flash("\(stat?.name ?? spellKey)已是顶档"); return
        }
        let cost = Wallet.spellLevelCost(spellKey, currentLevel: current)
        guard mutateWallet({ $0.upgradeSpellLevel(spellKey) }) else {
            flash("金币不足（需 \(cost)，只有 \(wallet.gold)）"); return
        }
        syncChiefCharges()   // 尚未开战的首领当场拿到新档位（与买充能同一口径）
        flash("\(stat?.name ?? spellKey)升至 \(current + 1) 档（-\(cost)）")
        publish()
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

        // 待施法：只有点到**合法目标格**才当成施法；否则先取消待选态，
        // 并让同一次点击继续走正常路由（否则待施法期间根本选不中其它棋子）。
        if let spellKey = pendingSpellKey {
            if legalSpellTargets(spellKey).contains(p) {
                castSelectedSpell(spell: spellKey, at: p)
                return
            }
            pendingSpellKey = nil
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
        pendingSpellKey = nil      // 换选中子就等于放弃待施法
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

    // MARK: - 战场成长（属性点与转职，玩家侧）

    /// 能不能给这个子下成长指令：只有“本回合轮到自己指挥的、自己的子”。
    /// AI 侧的点数在升级/转职那瞬间就已分掉（`autoGrows`），这里插手只会把重放弄乱。
    private var canGrowSelected: Bool {
        guard let unit = selectedUnit() else { return false }
        return canCommandCurrentCamp && !busy && unit.camp == currentCamp
    }

    /// 选中子是否还能分属性点 / 是否能转职（行动面板据此决定按钮画不画）
    var canAllocateSelected: Bool { canGrowSelected && (selectedUnit()?.attrBank ?? 0) > 0 }
    var canPromoteSelected: Bool { canGrowSelected && (selectedUnit()?.canPromote ?? false) }

    /// 花 1 点属性点。校验全在内核 `allocate`，UI 不自己改 `attrAlloc`。
    /// “满 10 级未转职时加不了点”不是 bug：那是转职这个选择的分量，失败原因直陈。
    func allocateSelected(track: WarConfig.UpgradeTrack) {
        guard canGrowSelected, let unit = selectedUnit() else { return }
        guard unit.attrBank > 0 else { flash("没有待分配属性点"); return }
        if bf.allocate(unit, track: track) {
            flash("\(unit.name)「\(track.label)」+1（待分配 \(unit.attrBank)）")
        } else {
            flash("已达本形态等级上限：先转职才继续加得了点")
        }
        publish()
    }

    /// 转职（二选一、不可逆、不吃钱）。分支 key 来自 `promotionOptions`（顺序即按钮顺序）。
    func promoteSelected(to branchKey: String) {
        guard canGrowSelected, let unit = selectedUnit() else { return }
        guard unit.canPromote else { flash("未满 \(WarConfig.Growth.promoteLevel) 级或已转过职"); return }
        let branchName = WarConfig.unitTypes[branchKey]?.name ?? branchKey
        guard bf.promote(unit, to: branchKey) else {
            flash("转职失败：该分支不属于此兵种"); return
        }
        pendingEffects.append(BoardFrame.Effect(kind: .promote, x: unit.x, y: unit.y, text: "转职"))
        flash("\(unit.name) 转职完成 → \(branchName)（上限抬到 \(unit.levelCap)）")
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

    /// 待施法的合法目标格（射程 + 视线 + 阵营/状态）。
    /// 紫色高亮与点击路由共用这一份口径：两边不一致时要么“亮了却放不出去”，
    /// 要么“点别的子却把魔法丢了”，所以只能有一个推导处。
    /// 射程走**升档后的那一份**（顶档射程 +1），否则面板说 4 格而棋盘只认 3 格。
    private func legalSpellTargets(_ spellKey: String) -> Set<GridPoint> {
        guard let stat = WarConfig.spellStat(spellKey, level: selectedUnit()?.spellLevels[spellKey] ?? 0),
              let caster = selectedUnit(),
              caster.isChief, caster.camp == currentCamp, phase == .battle,
              !isAIControlled(currentCamp), caster.canCast else { return [] }
        var set: Set<GridPoint> = []
        for target in bf.units where !target.isDead {
            let p = target.position
            guard Grid.manhattan(caster.position, p) <= stat.range,
                  bf.hasLineOfSight(from: caster.position, to: p) else { continue }
            switch stat.effect {
            case .damage: if target.camp != caster.camp { set.insert(p) }
            case .stun: if target.camp != caster.camp && !target.stunned { set.insert(p) }
            case .heal: if target.camp == caster.camp && target.hp < target.maxHp { set.insert(p) }
            }
        }
        return set
    }

    /// 进入“待选目标”态；再点一次同一按钮则取消
    func armSpell(_ spellKey: String) {
        guard selectedChiefCanCast, pendingSpellKey != spellKey else { pendingSpellKey = nil; publish(); return }
        pendingSpellKey = spellKey
        // 射程读升档后的值（与 `legalSpellTargets`/内核 `castSpell` 同一个口径）
        let stat = WarConfig.spellStat(spellKey, level: selectedUnit()?.spellLevels[spellKey] ?? 0)
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

    /// 主动投降：按败局走**既有结算路径**（不另开一条发钱/回滚的口）。
    /// vsAI 吃 `settle(.loss)` 的安慰金，闯关吃败局回滚（钱包 + 升级账 + 成长账一起还原），
    /// 双人与观战不动钱 —— 这些都由 `finish` 按模式分叉，这里只负责“谁输了”。
    func surrender() {
        guard phase == .battle, !busy, canCommandCurrentCamp || settings.mode == .aiVsAI else { return }
        // 玩家真参战的模式里输的恒为玩家侧；观战则是“当前行动方认输”
        let loser = settings.mode.isPlayerVsAI ? 0 : currentCamp
        endReason = .surrender
        finish(winner: bf.campOf(otherThan: loser))
        flash("已按败局结算")
        publish()
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
        case .vsAI, .campaign: return camp == 1
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
        case .promote:
            // 与推演同一个 `bf.promote`（`Replay.apply` 里就调它）：转职不改坐标、不掉飘字之外的东西，
            // 但必须占一帧，否则玩家会在下一子动的时候完全错过“它为何突然变成枪兵”。
            guard Replay.apply(bf, event) else { return false }
            if let unit = bf.findUnitById(event.unitId) {
                pendingEffects.append(BoardFrame.Effect(kind: .promote, x: unit.x, y: unit.y, text: "转职"))
            }
            publish()
            return await nap(stepDelay / 2)
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
        case .vsAI, .campaign:
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
        case .surrender: return "主动投降"
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

    /// 结算的唯一出口：胜负在此定死，之后只剩发钱/回滚与进档。
    /// 对外可见只为了让冒烟能直接验证“胜利当场记进度”这一条（不另开一条结算口）；
    /// 对局内的所有自然结束仍走 `checkOutcome` / `finishByTurnLimit` / `surrender`。
    func finish(winner: Int) {
        stopAuto()
        selectedId = nil
        pendingSpellKey = nil      // 待施法不得活到下一局（否则新局的每一次点击先被当成选目标）
        // 结算：胜负相对玩家（camp0）换算，平局按物质分判出的 -1 走安慰金以外的档。
        // `settle` 自己在没有待结算局时返回 nil，所以重复结束/观战局都不会发钱。
        if settings.mode == .vsAI {
            let outcome: Wallet.Outcome = winner == 0 ? .win : (winner == -1 ? .draw : .loss)
            lastSettlement = mutateWallet { $0.settle(outcome: outcome, difficultyKey: settings.difficultyKey) }
        } else if settings.mode == .campaign {
            // 闯关胜负语义钉死：赢 = 结算入账 + 累计金钱带到下一关（不重置）；
            // 败 / 平 = 未过关，整体回滚到入关快照，让玩家用同样的钱原地重打。
            lastCampaignLevel = campaign.currentLevel
            if winner == 0 {
                lastSettlement = mutateWallet { $0.settle(outcome: .win, difficultyKey: settings.difficultyKey) }
                // 胜利当场记进度：旧写法把 +1 押在玩家点「下一关」那一刻，而奖金已经在这一刻入了账。
                // 赢了之后停在结局卡上切后台 / 杀进程 / 点「新开局」，关数不变而奖金已到手
                // —— 同一关可以反复刷胜利奖金。进度必须与结算同时落地。
                campaign.currentLevel += 1
                campaign.maxLevelReached = max(campaign.maxLevelReached, campaign.currentLevel)
                // 成长与奖金同时作数：只有打赢的那一关才算"练过"
                creditCampaignGrowth()
            } else {
                if let snap = campaign.entrySnapshot { wallet = snap }
                // 失败也重置升级账：回滚到入关那一份 campaign 升级快照，与钱包同步。
                campaign.unitUpgrades = campaign.entryUpgrades ?? [:]
                // 成长账一起回滚：否则"失败重试"能靠反复送死把等级练上去（与刷钱同一类漏洞）
                campaign.unitGrowth = campaign.entryGrowth ?? [:]
                lastSettlement = nil
            }
        }
        phase = .over(winner: winner)
        publish()
    }

    func restartSameSeed() { newGame(autoLayout: true) }

    /// 闯关胜利结算：把本局我方每个**兵种**的最高成长写回跨关累积账。
    ///
    /// 记账按兵种而不按单位（“这一局的步兵 3 号”活不到下一关），而且取**最强的一条**：
    /// 同时上场三个步兵时带走的是练得最凶的那个，而不是“最后一个放下去的那个”（那会越打越弱）。
    /// 阵亡的子也参与取最大：它死前换到的经验是真实发生过的，只有整关打输才会整体作废。
    private func creditCampaignGrowth() {
        var ledger = campaign.unitGrowth
        for unit in bf.units where unit.camp == 0 {
            let snap = unit.growthSnapshot()
            guard snap.level > 1 || snap.allocated > 0 || snap.promoted else {
                continue                                  // 1 级空账不值得占位
            }
            ledger[unit.type] = ledger[unit.type].map { .stronger($0, snap) } ?? snap
        }
        campaign.unitGrowth = ledger
    }

    // MARK: - 闯关（Campaign）

    /// 当前关的公式参数（供 UI 展示“第 N 关 · 难度”）
    var campaignSpec: WarConfig.LevelSpec { WarConfig.campaignLevel(campaign.currentLevel) }

    /// 把当前关卡的公式参数写回 settings（难度/地图 seed/AI seed）。
    /// 必须在 newGame 创建棋盘之前调用，于是地图与 AI 采样都跟着关数钉死。
    /// 敌方升级不再缓存预算，改由 `ArmyComposer.campaignEnemyPlan(level:)` 按关数现算（纯函数、不读钱包）。
    private func applyCampaignLevel() {
        let spec = WarConfig.campaignLevel(campaign.currentLevel)
        settings.difficultyKey = spec.difficultyKey
        settings.terrainSeed = spec.terrainSeed
        settings.aiSeed = spec.aiSeed
    }

    /// 进入 / 继续闯关：切到闯关模式并从当前关开一局（手动布阵）。
    /// `currentLevel` 始终指向“尚未通过的那一关”（胜利当场已 +1），所以这里不用判断“要不要续打”。
    func startCampaign() {
        settings.mode = .campaign
        newGame()
    }

    /// 重试本关（败/平后原地重打：那一关没被 +1，参数与入关快照都不变）。
    func retryCampaignLevel() { newGame() }

    /// 进入下一关（过关时 `finish` 已经把 currentLevel 推前了一格，这里只开局）。
    func nextCampaignLevel() { newGame() }

    /// 退出闯关，回到普通对战 AI。
    func exitCampaign() {
        settings.mode = .vsAI
        newGame()
    }

    // MARK: - 派生信息（UI 直接读）

    var stepDelay: Double { settings.stepDelayMs * power.animationScale }

    /// 当前回合是否由玩家指挥（AI 回合时禁用指令按钮）
    var canCommandCurrentCamp: Bool {
        phase == .battle && !isAIControlled(currentCamp)
    }

    func materialScore(camp: Int) -> Double { bf.materialScore(camp: camp) }

    /// 该兵种按当前活跃升级账（闯关=campaign、其余=钱包永久）取实际数值（布阵页与升档页共用）。
    /// 倍率口径归内核 `WarConfig.unitStat`，UI 不自己乘 —— 否则面板说的与棋盘上跑的不是一个兵。
    func placedStat(for typeKey: String) -> WarConfig.UnitStat {
        WarConfig.unitStat(typeKey, upgrades: activeUpgrades(for: typeKey)) ?? WarConfig.unitTypes[typeKey]!
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
        case .vsAI, .campaign: return camp == 0 ? "我方" : "敌方"
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
                                   type: unit.type, symbol: unit.symbol, name: unit.name, upgrades: unit.upgrades,
                                   hp: unit.hp, maxHp: unit.maxHp,
                                   remainingMove: unit.remainingMove, remainingAttacks: unit.remainingAttacks,
                                   // “行动完成”看全部三个配额：施法次数也计入（首领一回合只一个动作）
                                   spent: unit.remainingMove == 0 && unit.remainingAttacks == 0 && unit.remainingSpell == 0,
                                   selected: unit.id == selectedId && selectable,
                                   targetable: targetable,
                                   isChief: unit.isChief, spellCharges: unit.spellCharges,
                                   spellLevels: unit.spellLevels, stunned: unit.stunned,
                                   // 成长读数全部取内核字段（UI 不拿经验自己推等级）
                                   typeKey: unit.typeKey, level: unit.level,
                                   expIntoLevel: unit.expIntoLevel, expToNext: unit.expToNext,
                                   attrBank: unit.attrBank, attrAlloc: unit.attrAlloc,
                                   branchKey: unit.branchKey, canPromote: unit.canPromote,
                                   promotionOptions: unit.promotionOptions)
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

        // 待施法高亮：目标集合走 `legalSpellTargets`（与 `castSpell` 同一口径）。
        let spellTargets = busy ? [] : (pendingSpellKey.map { legalSpellTargets($0) } ?? [])

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

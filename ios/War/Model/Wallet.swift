import Foundation
import WarKit

/// 跨局军费（Codable + UserDefaults，套路与 `GameSettings` 一致）。
///
/// 三条不能让步的不变式（冒烟段直接对着它们断言）：
/// 1. **余额永不为负**：扣款只有 `spend` 一个口子，进去之前先判够不够；
/// 2. **补贴每局只发一次**：同一时刻最多只有一个"未结算的局"（`pendingBattleID`），
///    反复点"新开局"不会把补贴刷成提款机；同理 `settle` 对同一局只结一次；
/// 3. **只有玩家真参战的局才走钱**（vsAI）：观战 AI 互殴、本地双人都不进这条流水账。
///
/// 价目表与内核同源：兵单价读 `WarConfig.unitTypes[].cost`，升级费读
/// `WarConfig.upgradeCost`，魔法价格读 `WarConfig.spells[].unlockCost/chargeCost`。
/// 于是 AI 与玩家买同样的东西花同样的钱 —— 经济是难度旋钮，不是双标。
struct Wallet: Codable, Equatable {
    enum Outcome: String, Codable, Equatable {
        case win, draw, loss
    }

    /// 本局收支明细（结局卡片用）。胜负不由它推导，这里只记账。
    struct Settlement: Codable, Equatable {
        let outcome: Outcome
        let bonus: Int          // 胜/平/负的入账
        let spent: Int          // 本局布阵花掉的（兵 + 升档 + 买断 + 充能）
        let goldAfter: Int
    }

    // MARK: - 常量（军费规则的唯一定义处）

    static let startingGold = 120
    /// 每局固定补贴：破产保护 —— 连败到底也打得起下一仗
    static let battleStipend = 30
    static let winBonusBase = 60
    static let drawBonus = 30
    static let lossConsolation = 10
    /// 胜利奖金的难度加成：赢得越险，拿得越多
    static let difficultyBonus: [String: Int] = ["easy": 0, "normal": 20, "hard": 40, "nightmare": 70]

    static let userDefaultsKey = "war.wallet.v1"   // 对战 AI：沿用旧键，历史进度不丢

    /// 钱包按模式隔离：四个模式各记一本军费，金币/买断/兵档互不通用。
    /// 共用一本时，“切个模式”就把别的模式刷出来的钱带进本局，而闯关败局
    /// 的“回滚到入关快照”也会连带改到对战账 —— 两个模式互相能改写对方的资产。
    /// （`.vsAI` 沿用 `war.wallet.v1`，所以旧玩家的账仍是对战账。）
    static func key(for mode: GameSettings.Mode) -> String {
        switch mode {
        case .vsAI: return userDefaultsKey
        case .campaign: return "war.wallet.campaign.v1"
        case .manual: return "war.wallet.manual.v1"
        case .aiVsAI: return "war.wallet.aivs.v1"
        }
    }

    // MARK: - 状态

    var gold: Int = Wallet.startingGold
    /// 买断解锁（跨局永久）
    var unlockedSpells: Set<String> = []
    /// 兵种三线升级等级（跨局永久账）：升了步兵攻线就是所有步兵以后每局都带这一档 ——
    /// 单位本身不跨局存在，个体升级没有落点。与闯关的独立升级账互不干扰。
    var unitUpgrades: [String: WarConfig.Upgrades] = [:]
    /// 本局买好的充能（开局写进首领，结算时清空：充能是本局消耗品）
    var charges: [String: Int] = [:]
    /// 各门魔法的**等级**（跨局永久，随上面的键按模式隔离）：0 = 刚买断的基础档。
    /// 与充能分家：发数是本局消耗品，档位是花大钱买上来的资产，结算不能把它清掉。
    var spellLevels: [String: Int] = [:]

    var wins = 0
    var losses = 0
    var draws = 0
    /// 已开始的局数（单调，用于识别"同一局"）
    var battleCounter = 0
    /// 未结算的那一局 id；nil = 没有待结算的账（补贴因此发不出去第二份）
    var pendingBattleID: Int?
    /// 本局已花（给结局卡片一句"这局花了多少"）
    var spentThisBattle = 0

    // MARK: - 价格（与内核同一张价目表）

    static func cost(ofUnit typeKey: String) -> Int { WarConfig.unitTypes[typeKey]?.cost ?? 0 }
    static func unlockCost(_ spellKey: String) -> Int { WarConfig.spells[spellKey]?.unlockCost ?? 0 }
    static func chargeCost(_ spellKey: String) -> Int { WarConfig.spells[spellKey]?.chargeCost ?? 0 }
    /// 升一档魔法价（0 → 3；顶档返回 `.max` = 不卖）
    static func spellLevelCost(_ spellKey: String, currentLevel: Int) -> Int {
        WarConfig.spellUpgradeCost(spellKey, currentLevel: currentLevel)
    }
    /// 某门魔法当前档位（没买过 = 基础档 0）
    func spellLevel(_ spellKey: String) -> Int { spellLevels[spellKey] ?? 0 }
    /// 本局首领该带的档位（只给“真的携带了发数”的那几种）
    var battleSpellLevels: [String: Int] {
        var map: [String: Int] = [:]
        for (key, level) in spellLevels where level > 0 && (charges[key] ?? 0) > 0 { map[key] = level }
        return map
    }
    /// 升某条线「下一档」要交的钱（三线同价规则、无上限）
    func upgradeCost(_ typeKey: String, track: WarConfig.UpgradeTrack) -> Int {
        WarConfig.upgradeCost(typeKey: typeKey, currentLevel: upgrades(of: typeKey).level(track))
    }

    func upgrades(of typeKey: String) -> WarConfig.Upgrades { unitUpgrades[typeKey] ?? WarConfig.Upgrades() }
    func isUnlocked(_ spellKey: String) -> Bool { unlockedSpells.contains(spellKey) }
    /// 本局首领该带的充能（只剩正数的种类，士兵永远拿不到）
    var battleCharges: [String: Int] { charges.filter { $0.value > 0 } }

    // MARK: - 唯一的扣款口

    @discardableResult
    mutating func spend(_ amount: Int) -> Bool {
        guard amount >= 0, gold >= amount else { return false }
        gold -= amount
        spentThisBattle += amount
        return true
    }

    /// 扣了钱却没能把事办成（比如格子被占）：原样退回，账目不留脏数字
    mutating func refund(_ amount: Int) {
        guard amount > 0 else { return }
        gold += amount
        spentThisBattle = max(0, spentThisBattle - amount)
    }

    // MARK: - 购买

    /// 买断一门魔法（跨局永久）。没解锁的首领施不了法，所以这条也管住 AI 之外的入口。
    @discardableResult
    mutating func unlockSpell(_ spellKey: String) -> Bool {
        guard WarConfig.spells[spellKey] != nil, !isUnlocked(spellKey) else { return false }
        guard spend(Self.unlockCost(spellKey)) else { return false }
        unlockedSpells.insert(spellKey)
        return true
    }

    /// 升兵种某条线（跨局永久，该型兵一起升）。首领不卖：它免费且必带。
    @discardableResult
    mutating func upgradeTrack(_ typeKey: String, _ track: WarConfig.UpgradeTrack) -> Bool {
        guard let stat = WarConfig.unitTypes[typeKey], !stat.isChief, stat.cost > 0 else { return false }
        let cost = upgradeCost(typeKey, track: track)
        guard spend(cost) else { return false }
        var u = upgrades(of: typeKey)
        u.bump(track)
        unitUpgrades[typeKey] = u
        return true
    }

    /// 退兵种某条线一档（买错反悔）：退款额 = **当初升这一档实付的那笔**
    /// （同一个 `upgradeCost` 取上一档），所以“买 → 退 → 买”一个铜板也套不出来。
    /// T0 无可退；首领线由定价函数报 `.max` 直接拒。
    @discardableResult
    mutating func downgradeTrack(_ typeKey: String, _ track: WarConfig.UpgradeTrack) -> Int? {
        let current = upgrades(of: typeKey)
        guard current.level(track) > 0 else { return nil }
        let price = WarConfig.upgradeCost(typeKey: typeKey, currentLevel: current.level(track) - 1)
        guard price > 0, price < Int.max else { return nil }
        var downgraded = current
        downgraded.lower(track)
        unitUpgrades[typeKey] = downgraded
        refund(price)
        return price
    }

    /// 买一发充能（本局有效）。前提是该魔法已经买断。
    @discardableResult
    mutating func buyCharge(_ spellKey: String) -> Bool {
        guard let stat = WarConfig.spells[spellKey], isUnlocked(spellKey) else { return false }
        guard spend(stat.chargeCost) else { return false }
        charges[spellKey, default: 0] += 1
        return true
    }

    /// 退一发本局充能（买错反悔）：退的是发数的单价（与 `buyCharge` 同一个价）。
    /// 只管本局携带表，所以不存在“退了钱而发数还在”的可能：调用方紧跟着重写携带。
    @discardableResult
    mutating func sellCharge(_ spellKey: String) -> Int? {
        guard let stat = WarConfig.spells[spellKey], (charges[spellKey] ?? 0) > 0 else { return nil }
        charges[spellKey, default: 0] -= 1
        if charges[spellKey] == 0 { charges[spellKey] = nil }
        refund(stat.chargeCost)
        return stat.chargeCost
    }

    /// 升一档魔法威力（跨局永久）。先买断后升档，顶档不卖：
    /// 与“买断”同一条链——没拥有的东西不该能预定它的强化。
    @discardableResult
    mutating func upgradeSpellLevel(_ spellKey: String) -> Bool {
        guard isUnlocked(spellKey), spellLevel(spellKey) < WarConfig.maxSpellLevel else { return false }
        let cost = Self.spellLevelCost(spellKey, currentLevel: spellLevel(spellKey))
        guard cost < Int.max, spend(cost) else { return false }
        spellLevels[spellKey] = spellLevel(spellKey) + 1
        return true
    }

    /// 退一档魔法（买错反悔）：与 `upgradeSpellLevel` 严格互逆，退升上来时实付的那笔。
    /// **买断本身不退**：解锁是所有权变更，退掉会让已携带的发数变成无源之水。
    @discardableResult
    mutating func downgradeSpellLevel(_ spellKey: String) -> Int? {
        let level = spellLevel(spellKey)
        guard level > 0 else { return nil }
        let price = Self.spellLevelCost(spellKey, currentLevel: level - 1)
        guard price > 0, price < Int.max else { return nil }
        spellLevels[spellKey] = level - 1
        refund(price)
        return price
    }

    // MARK: - 局开始 / 局结算

    /// 开一局：发一次补贴。已经有未结算的局时不再发（反复"新开局"刷不了钱）。
    mutating func beginBattle() {
        guard pendingBattleID == nil else { return }   // 上一局未结算就不再发钱
        battleCounter += 1
        pendingBattleID = battleCounter
        spentThisBattle = 0
        gold += Self.battleStipend
    }

    /// 结算：发奖金 + 记战绩 + 清空本局没用完的充能。同一局结第二次返回 nil。
    @discardableResult
    mutating func settle(outcome: Outcome, difficultyKey: String) -> Settlement? {
        guard pendingBattleID != nil else { return nil }
        let bonus: Int
        switch outcome {
        case .win: bonus = Self.winBonusBase + (Self.difficultyBonus[difficultyKey] ?? 0)
        case .draw: bonus = Self.drawBonus
        case .loss: bonus = Self.lossConsolation
        }
        gold += bonus
        switch outcome {
        case .win: wins += 1
        case .loss: losses += 1
        case .draw: draws += 1
        }
        pendingBattleID = nil
        charges = [:]
        return Settlement(outcome: outcome, bonus: bonus, spent: spentThisBattle, goldAfter: gold)
    }

    /// 玩家侧"一键开战"的编成：按单价从默认模板买满买得起的兵，升级等级由调用方传入的账（永久/闯关）决定。
    /// **不自动升档、不自动买充能** —— 那是军费面板上的主动选择，不该被"图快"替玩家花掉。
    mutating func playerQuickDeployPlan(unitUpgrades: [String: WarConfig.Upgrades]) -> ArmyPlan {
        var bought: [ArmyPlan.Soldier] = []
        var spent = 0
        for typeKey in WarConfig.defaultRoster where bought.count < WarConfig.soldiersPerSide {
            let stat = WarConfig.unitTypes[typeKey]
            guard stat?.isChief != true, spend(Self.cost(ofUnit: typeKey)) else { continue }
            spent += Self.cost(ofUnit: typeKey)
            bought.append(ArmyPlan.Soldier(typeKey: typeKey, upgrades: unitUpgrades[typeKey] ?? WarConfig.Upgrades()))
        }
        return ArmyPlan(soldiers: bought, spellCharges: battleCharges,
                        spellLevels: battleSpellLevels,
                        spent: spent, leftover: gold)
    }

    // MARK: - 持久化

    /// 显式写了 `init(from:)` 之后，隐式的无参 init 就不再代劳了，这里手写一份：
    /// 各字段取上面声明的默认值（新号 = 120 金、无买断、无兵档）。
    init() {}

    /// 按模式读账（键见 `key(for:)`）。解不开就当新号：宁可不认旧账，
    /// 也不能让一本读不懂的账盖掉玩家已有的钱。
    static func load(for mode: GameSettings.Mode) -> Wallet {
        guard let data = UserDefaults.standard.data(forKey: key(for: mode)),
              let saved = try? JSONDecoder().decode(Wallet.self, from: data) else {
            return Wallet()
        }
        return saved
    }

    static func load() -> Wallet { load(for: .vsAI) }

    func save(for mode: GameSettings.Mode) {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key(for: mode))
        }
    }

    func save() { save(for: .vsAI) }

    // MARK: - 解码（宽容）

    /// 显式写一遍解码器：Swift 合成的 `Decodable` **不会**用属性默认值兜底缺键，
    /// 少一个键就整本抛错 —— 而 `load` 外面包的是 `try?`，于是老存档会静默变成
    /// 一本全新的账（金币、买断、兵档全清）。加字段时必须逐键兜底。
    private enum CodingKeys: String, CodingKey {
        case gold, unlockedSpells, unitUpgrades, charges, spellLevels
        case wins, losses, draws, battleCounter, pendingBattleID, spentThisBattle
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func val<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decode(T.self, forKey: key)) ?? fallback
        }
        gold = val(.gold, Self.startingGold)
        unlockedSpells = val(.unlockedSpells, [])
        unitUpgrades = val(.unitUpgrades, [:])
        charges = val(.charges, [:])
        spellLevels = val(.spellLevels, [:])
        wins = val(.wins, 0)
        losses = val(.losses, 0)
        draws = val(.draws, 0)
        battleCounter = val(.battleCounter, 0)
        pendingBattleID = val(.pendingBattleID, nil as Int?)
        spentThisBattle = val(.spentThisBattle, 0)
    }
}

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
/// 价目表与内核同源：兵单价读 `WarConfig.unitTypes[].cost`，升档费读
/// `WarConfig.tierCosts`，魔法价格读 `WarConfig.spells[].unlockCost/chargeCost`。
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

    static let userDefaultsKey = "war.wallet.v1"   // 首次落盘，无历史键

    // MARK: - 状态

    var gold: Int = Wallet.startingGold
    /// 买断解锁（跨局永久）
    var unlockedSpells: Set<String> = []
    /// 兵种档位（跨局永久）：升了步兵就是所有步兵都是 tier2 ——
    /// 单位本身不跨局存在，个体升级没有落点。
    var unitTiers: [String: Int] = [:]
    /// 本局买好的充能（开局写进首领，结算时清空：充能是本局消耗品）
    var charges: [String: Int] = [:]

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
    /// 从当前档升一档要交的钱（已满档返回 nil）
    func upgradeCost(_ typeKey: String) -> Int? {
        let current = tier(of: typeKey)
        guard current < WarConfig.maxTier else { return nil }
        return WarConfig.tierCosts[current]
    }

    func tier(of typeKey: String) -> Int { min(max(unitTiers[typeKey] ?? 1, 1), WarConfig.maxTier) }
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

    /// 升兵种档（跨局永久，该型兵一起升）。首领不卖：它免费且必带。
    @discardableResult
    mutating func upgradeUnitTier(_ typeKey: String) -> Bool {
        guard let stat = WarConfig.unitTypes[typeKey], !stat.isChief,
              let cost = upgradeCost(typeKey) else { return false }
        let current = tier(of: typeKey)
        guard spend(cost) else { return false }
        unitTiers[typeKey] = current + 1
        return true
    }

    /// 买一发充能（本局有效）。前提是该魔法已经买断。
    @discardableResult
    mutating func buyCharge(_ spellKey: String) -> Bool {
        guard let stat = WarConfig.spells[spellKey], isUnlocked(spellKey) else { return false }
        guard spend(stat.chargeCost) else { return false }
        charges[spellKey, default: 0] += 1
        return true
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

    /// 玩家侧"一键开战"的编成：按单价从默认模板买满买得起的兵，档位取钱包里已升到的档。
    /// **不自动升档、不自动买充能** —— 那是军费面板上的主动选择，不该被"图快"替玩家花掉。
    mutating func playerQuickDeployPlan() -> ArmyPlan {
        var bought: [ArmyPlan.Soldier] = []
        var spent = 0
        for typeKey in WarConfig.defaultRoster where bought.count < WarConfig.soldiersPerSide {
            let stat = WarConfig.unitTypes[typeKey]
            guard stat?.isChief != true, spend(Self.cost(ofUnit: typeKey)) else { continue }
            spent += Self.cost(ofUnit: typeKey)
            bought.append(ArmyPlan.Soldier(typeKey: typeKey, tier: tier(of: typeKey)))
        }
        return ArmyPlan(soldiers: bought, spellCharges: battleCharges,
                        spent: spent, leftover: gold)
    }

    // MARK: - 持久化

    static func load() -> Wallet {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let saved = try? JSONDecoder().decode(Wallet.self, from: data) else {
            return Wallet()
        }
        return saved
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        }
    }
}

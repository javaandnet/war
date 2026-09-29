import Foundation

/// 一支部队的编成结果：士兵清单（含档位）+ 首领携带的魔法发数。
///
/// 值类型、可 Equatable —— 配兵必须是纯函数，同样的预算要给出同样的兵，
/// 否则"同 seed 两局逐帧一致"这条复现不变式会被编成环节先打穿。
public struct ArmyPlan: Equatable, Sendable {
    public struct Soldier: Equatable, Sendable {
        public let typeKey: String
        public let tier: Int

        public init(typeKey: String, tier: Int) {
            self.typeKey = typeKey
            self.tier = tier
        }
    }

    public let soldiers: [Soldier]
    /// 首领本局携带的每种魔法发数。字典不参与输出顺序：读侧一律按
    /// `WarConfig.spellOrder` 遍历，所以这里用字典不会引入不确定性。
    public let spellCharges: [String: Int]
    public let spent: Int
    public let leftover: Int

    public init(soldiers: [Soldier], spellCharges: [String: Int], spent: Int, leftover: Int) {
        self.soldiers = soldiers
        self.spellCharges = spellCharges
        self.spent = spent
        self.leftover = leftover
    }

    /// 士兵数（首领不计入：它免费、必带、不占兵位）
    public var soldierCount: Int { soldiers.count }
}

/// 在难度预算内做**全序确定**的贪心配兵。
///
/// 三条硬要求，破坏任何一条都会让冒烟第 5 段（同设置两局逐帧一致）失效：
/// 1. 不许有随机源：这里连 `SeededRng` 都不需要，纯算术；
/// 2. 不许读玩家钱包：AI 只按难度拿钱，一旦掺进余额，两局同设置的指纹就会分叉；
/// 3. 每个循环都要有确定次序：买兵按模板顺序，升档按 `unitTypeOrder` 定序，
///    充能按（充能价, key）升序轮着买。
///
/// 采购次序固定为「兵 → 升档 → 充能」：先保证有兵可指挥，再谈质量与魔法。
public enum ArmyComposer {
    /// 买兵优先次序模板：默认沿用 `defaultRoster`（步/步/骑/骑/弓/弓），
    /// 预算不够就跳过买不起的那一档继续往后试 —— 于是钱少的难度自动买到的是
    /// "更少但仍是前排优先"的兵，而不是随机缺一两列。
    public static let defaultTemplate = WarConfig.defaultRoster

    /// 基线编成：默认 6 兵全 tier1 + 首领无充能（不花一分钱）。
    /// 内核回归、冒烟指纹与“玩家还没买过东西”的开局都等价于这一份。
    public static let baselinePlan = ArmyPlan(
        soldiers: WarConfig.defaultRoster.map { ArmyPlan.Soldier(typeKey: $0, tier: 1) },
        spellCharges: [:], spent: 0, leftover: 0)

    /// 按难度键取预算并配兵。难度键缺省/未知时返回 nil ——
    /// 基线编成（6 兵 tier1 + 首领、无充能）由调用方自己保留，
    /// 免得"忘了传难度"静默变成"一支买不起兵的空军队"。
    public static func compose(difficultyKey: String?) -> ArmyPlan? {
        guard let key = difficultyKey, let diff = WarConfig.difficulties[key] else { return nil }
        return compose(budget: diff.budget, template: defaultTemplate)
    }

    public static func compose(budget: Int, template: [String] = defaultTemplate) -> ArmyPlan {
        let wallet = max(0, budget)
        var remaining = wallet
        var soldiers: [ArmyPlan.Soldier] = []

        // 1) 买兵：首领不花钱也不占兵位（模板里混进来也一律忽略）
        for typeKey in template where soldiers.count < WarConfig.soldiersPerSide {
            guard let stat = WarConfig.unitTypes[typeKey], !stat.isChief,
                  stat.cost <= remaining else { continue }
            soldiers.append(ArmyPlan.Soldier(typeKey: typeKey, tier: 1))
            remaining -= stat.cost
        }

        // 2) 升档：升的是**兵种**（该型兵一起升），与玩家侧钱包的永久升级同价同义。
        //    选"每块钱换来的战略价值"最高的一型，同分由 unitTypeOrder 定序。
        while !soldiers.isEmpty {
            var pick: (typeKey: String, from: Int, cost: Int, ratio: Double)?
            for typeKey in WarConfig.unitTypeOrder {
                guard let current = soldiers.first(where: { $0.typeKey == typeKey })?.tier,
                      current < WarConfig.maxTier else { continue }
                let next = current + 1
                let cost = WarConfig.tierCosts[next - 1]
                guard cost <= remaining,
                      let low = WarConfig.unitStat(typeKey, tier: current),
                      let high = WarConfig.unitStat(typeKey, tier: next) else { continue }
                let gain = Double(soldiers.filter { $0.typeKey == typeKey }.count)
                    * (high.value - low.value)
                let ratio = gain / Double(cost)
                if pick == nil || ratio > pick!.ratio {
                    pick = (typeKey, current, cost, ratio)
                }
            }
            guard let upgrade = pick else { break }
            remaining -= upgrade.cost
            soldiers = soldiers.map {
                $0.typeKey == upgrade.typeKey
                    ? ArmyPlan.Soldier(typeKey: $0.typeKey, tier: upgrade.from + 1)
                    : $0
            }
        }

        // 3) 充能：按（价格, key）升序**轮着**买，一轮买不到任何东西就收手。
        //    轮着买而不是把余款全砸在最便宜的那张法术上：AI 首领因此三种都会带上点，
        //    行为更像"练过的首领"，也不会只会出现治疗这一种飘字。
        var charges: [String: Int] = [:]
        let byPrice = WarConfig.spellOrder.sorted {
            (WarConfig.spells[$0]!.chargeCost, $0) < (WarConfig.spells[$1]!.chargeCost, $1)
        }
        var boughtOne = true
        while boughtOne {
            boughtOne = false
            for key in byPrice {
                guard let stat = WarConfig.spells[key], stat.chargeCost <= remaining else { continue }
                charges[key, default: 0] += 1
                remaining -= stat.chargeCost
                boughtOne = true
            }
        }

        return ArmyPlan(soldiers: soldiers, spellCharges: charges,
                        spent: wallet - remaining, leftover: remaining)
    }
}

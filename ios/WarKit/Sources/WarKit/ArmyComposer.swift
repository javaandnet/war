import Foundation

/// 一支部队的编成结果：士兵清单（含三线升级等级）+ 首领携带的魔法发数。
///
/// 值类型、可 Equatable —— 配兵必须是纯函数，同样的预算要给出同样的兵，
/// 否则"同 seed 两局逐帧一致"这条复现不变式会被编成环节先打穿。
public struct ArmyPlan: Equatable, Sendable {
    public struct Soldier: Equatable, Sendable {
        public let typeKey: String
        public let upgrades: WarConfig.Upgrades

        public init(typeKey: String, upgrades: WarConfig.Upgrades = WarConfig.Upgrades()) {
            self.typeKey = typeKey
            self.upgrades = upgrades
        }
    }

    public let soldiers: [Soldier]
    /// 首领本局携带的每种魔法发数。字典不参与输出顺序：读侧一律按
    /// `WarConfig.spellOrder` 遍历，所以这里用字典不会引入不确定性。
    public let spellCharges: [String: Int]
    /// 首领本局的每种魔法**等级**（AI 侧取自难度档 / 关卡公式，与玩家“军费买档”同一条轴）。
    /// 不放进 `Soldier`：魔法只属于首领，而首领不占兵位。
    public let spellLevels: [String: Int]
    public let spent: Int
    public let leftover: Int

    public init(soldiers: [Soldier], spellCharges: [String: Int], spellLevels: [String: Int] = [:],
                spent: Int, leftover: Int) {
        self.soldiers = soldiers
        self.spellCharges = spellCharges
        self.spellLevels = spellLevels
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

    /// 基线编成：默认 6 兵全未升级 + 首领无充能（不花一分钱）。
    /// 内核回归、冒烟指纹与“玩家还没买过东西”的开局都等价于这一份。
    public static let baselinePlan = ArmyPlan(
        soldiers: WarConfig.defaultRoster.map { ArmyPlan.Soldier(typeKey: $0) },
        spellCharges: [:], spent: 0, leftover: 0)

    /// 按难度键取预算并配兵。难度键缺省/未知时返回 nil ——
    /// 基线编成（6 兵 tier1 + 首领、无充能）由调用方自己保留，
    /// 免得"忘了传难度"静默变成"一支买不起兵的空军队"。
    public static func compose(difficultyKey: String?) -> ArmyPlan? {
        guard let key = difficultyKey, let diff = WarConfig.difficulties[key] else { return nil }
        let plan = compose(budget: diff.budget, template: defaultTemplate)
        // 魔法档位跟着难度档走（不花预算：它是“这一档就该会几层”，而不是“它买得起”）。
        // 只对真的携带了发数的那种魔法记档，否则会出现“会 3 档冰球但一发没带”的空转。
        return ArmyPlan(soldiers: plan.soldiers, spellCharges: plan.spellCharges,
                        spellLevels: spellLevels(diff.spellLevel, carried: plan.spellCharges),
                        spent: plan.spent, leftover: plan.leftover)
    }

    /// 把“一个统一档位”展开成携带表（按 `spellOrder` 定序写入，字典因此仍可复现）。
    static func spellLevels(_ level: Int, carried: [String: Int]) -> [String: Int] {
        guard level > 0 else { return [:] }
        var map: [String: Int] = [:]
        for key in WarConfig.spellOrder where (carried[key] ?? 0) > 0 {
            map[key] = min(level, WarConfig.maxSpellLevel)
        }
        return map
    }

    public static func compose(budget: Int, template: [String] = defaultTemplate) -> ArmyPlan {
        let wallet = max(0, budget)
        var remaining = wallet
        var soldiers: [ArmyPlan.Soldier] = []

        // 1) 买兵：首领不花钱也不占兵位（模板里混进来也一律忽略）
        for typeKey in template where soldiers.count < WarConfig.soldiersPerSide {
            guard let stat = WarConfig.unitTypes[typeKey], !stat.isChief,
                  stat.cost <= remaining else { continue }
            soldiers.append(ArmyPlan.Soldier(typeKey: typeKey))
            remaining -= stat.cost
        }

        // 2) 升级：三线（攻/防/生命）各自独立、无上限。value 恒定不提供收益信号，
        //    所以这里纯按价低者先扫开：每次买全场“下一档最便宜”的那条线，
        //    同价按 unitTypeOrder → UpgradeTrack 定序（均与字典无关，保证可复现）。
        //    升的是**兵种**（该型兵一起升），与玩家侧钱包的升级同价同义。
        //    无上限会把整笔余款吃干、饿死后面的充能阶段 —— 故保留“一发最便宜充能”的额度给首领带魔法。
        let chargeReserve = WarConfig.spells.values.map { $0.chargeCost }.min() ?? 0
        while !soldiers.isEmpty {
            var pick: (typeKey: String, track: WarConfig.UpgradeTrack, cost: Int)?
            for typeKey in WarConfig.unitTypeOrder {
                guard let current = soldiers.first(where: { $0.typeKey == typeKey })?.upgrades else { continue }
                for track in WarConfig.UpgradeTrack.allCases {
                    let cost = WarConfig.upgradeCost(typeKey: typeKey, currentLevel: current.level(track))
                    guard cost <= remaining - chargeReserve else { continue }
                    if pick == nil || cost < pick!.cost {
                        pick = (typeKey, track, cost)
                    }
                }
            }
            guard let upgrade = pick else { break }
            remaining -= upgrade.cost
            soldiers = soldiers.map {
                guard $0.typeKey == upgrade.typeKey else { return $0 }
                var u = $0.upgrades
                u.bump(upgrade.track)
                return ArmyPlan.Soldier(typeKey: $0.typeKey, upgrades: u)
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

    /// 闯关敌军编成：默认名册各兵均带上关卡公式的 `enemyUpgrades`（三线独立成长），
    ///  Spell 充能取自该关难度档的基线预算配兵。**不读玩家钱包**，于是同一关永远同一支军。
    public static func campaignEnemyPlan(level: Int) -> ArmyPlan {
        let spec = WarConfig.campaignLevel(level)
        let soldiers = WarConfig.defaultRoster.map {
            ArmyPlan.Soldier(typeKey: $0, upgrades: spec.enemyUpgrades)
        }
        let charges = compose(difficultyKey: spec.difficultyKey)?.spellCharges ?? [:]
        return ArmyPlan(soldiers: soldiers, spellCharges: charges,
                        spellLevels: spellLevels(spec.spellLevel, carried: charges),
                        spent: 0, leftover: 0)
    }
}

import Foundation

/// 单位纯状态对象（不含任何移动/渲染能力）。
///
/// 与 JS 原型的关键差异：`move` 能力被彻底移除 —— 移动只能经由
/// `Battlefield.moveAlongPath` 走，那里会校验 4 邻接、地形消耗并扣减配额，
/// 从结构上杜绝"改坐标不扣点"这类规则漏洞。
public final class WarUnit {
    public let id: Int
    public let type: String
    public let name: String
    public let symbol: String
    /// 0 = 我方（蓝），1 = 敌方（红）
    public let camp: Int

    public var x: Int
    public var y: Int

    public let maxHp: Int
    public let atk: Int
    public let def: Int
    public var hp: Int
    public let moveRange: Int
    public let attackRange: Int
    public let counterAttack: Bool
    /// 兵种战略价值（AI 目标选择用）
    public let value: Double
    /// 是否首领：斩首胜利与施法资格的判据
    public let isChief: Bool
    /// 兵种档位（1~3），已体现在上面那组数值里，保留只为 UI 展示与存盘回填
    public let tier: Int

    /// 本回合剩余机动点数
    public var remainingMove: Int
    /// 本回合剩余攻击次数
    public var remainingAttacks: Int
    /// 本回合是否已反击过（一回合只反击一次）
    public var hasCountered: Bool
    /// 本局携带的魔法名单（首领专用，布阵时写入）。战斗中不再变，所以**不进快照**。
    public var spellKeys: [String]
    /// 本局携带的每种魔法剩余发数（首领专用，士兵恒为空）。
    /// 按种类分开计而不是一个总池：配置表里三种魔法的充能价不同
    /// （火球 20 / 治疗 15 / 冰冻 25），一个总数就表达不了“买了什么”。
    public var spellCharges: [String: Int]
    /// 本回合剩余施法次数（与普攻互斥，见 Battlefield.castSpell 的配额扣除）
    public var remainingSpell: Int
    /// 被冰冻：持续到它自己的下一个回合结束（不能移动/攻击/施法/反击）
    public var stunned: Bool

    public var isDead: Bool { hp <= 0 }
    public var position: GridPoint { GridPoint(x: x, y: y) }

    /// 是否有施法资格：首领 + 本回合还有施法次数 + 至少一种魔法还有发。
    /// 射程/视线/目标阵营这些还得由 `Battlefield.castSpell` 校，这里只管“能不能出手”。
    public var canCast: Bool { isChief && remainingSpell > 0 && spellCharges.values.contains { $0 > 0 } }

    /// 该种魔法本局还剩几发
    public func charges(for key: String) -> Int { spellCharges[key] ?? 0 }

    public init(id: Int, type: String, camp: Int, x: Int, y: Int, tier: Int = 1) {
        // 数值经 `unitStat(_:tier:)` 过一道档位倍率；属性仍是 `let`，
        // 于是快照/回滚与 AI 评分都不需要知道“档位”这个概念的存在。
        guard let stat = WarConfig.unitStat(type, tier: tier) else {
            fatalError("未知兵种类型: \(type)")
        }
        self.id = id
        self.type = type
        self.tier = min(max(tier, 1), WarConfig.maxTier)
        self.name = stat.name
        self.symbol = stat.symbol
        self.camp = camp
        self.x = x
        self.y = y
        maxHp = stat.hp
        atk = stat.atk
        def = stat.def
        hp = stat.hp
        moveRange = stat.moveRange
        attackRange = stat.attackRange
        counterAttack = stat.counterAttack
        value = stat.value
        isChief = stat.isChief
        remainingMove = stat.moveRange
        remainingAttacks = WarConfig.maxAttacksPerTurn
        hasCountered = false
        // 充能属于“本局携带”而非“兵种固有”，所以不在 init 里给：
        // 基线编成（内核测试/冒烟指纹）保持无充能，数值不漂移；买到的发数由布阵层写入。
        spellKeys = []
        spellCharges = [:]
        remainingSpell = 0
        stunned = false
    }

    /// 布阵时写入本局魔法携带（唯一入口：名单从“哪几种买了发数”推导，
    /// 因此不会出现“有名单没发数”或反过来的空转）。士兵永远拿不到魔法。
    public func carrySpells(_ perSpell: [String: Int]) {
        guard isChief else {
            spellKeys = []
            spellCharges = [:]
            remainingSpell = 0
            return
        }
        var map: [String: Int] = [:]
        for (key, count) in perSpell where count > 0 && WarConfig.spells[key] != nil {
            map[key] = count
        }
        spellCharges = map
        spellKeys = map.keys.sorted()
    }

    /// 一次攻击的期望伤害（消耗式）：atk − 目标有效防御（含地形加成），最低 1。
    /// 与 JS 内核逐字对齐：地形真的能减伤（森林 +12 可使步兵对步兵伤害从 28 降到 16）。
    public func damageTo(_ target: WarUnit, targetTerrainDefBonus: Int = 0) -> Int {
        max(1, atk - target.effectiveDefense(terrainDefBonus: targetTerrainDefBonus))
    }

    /// 含地形加成的有效防御（地形直接加到防御值上）
    public func effectiveDefense(terrainDefBonus: Int = 0) -> Int {
        def + terrainDefBonus
    }

    /// 目标是否在本单位射程内（仅判距离；视线由 Battlefield 负责）
    public func canAttack(_ target: WarUnit) -> Bool {
        !target.isDead && Grid.manhattan(x, y, target.x, target.y) <= attackRange
    }

    /// 受到伤害，返回**实际扣除**的血量（不超过当前 hp，供 overkill 评分用）
    @discardableResult
    public func takeDamage(_ amount: Int) -> Int {
        let applied = min(hp, max(0, amount))
        hp -= applied
        return applied
    }

    /// 恢复血量，返回**实际**回复量（不超 maxHp，溢出部分作废 —— 治疗因此不会白治）。
    /// 已死单位不给拉回来：复活不在这套规则里。
    @discardableResult
    public func heal(_ amount: Int) -> Int {
        guard !isDead else { return 0 }
        let applied = min(max(0, amount), maxHp - hp)
        hp += applied
        return applied
    }

    /// 能否对来袭攻击者反击：存活 + 允许反击 + 攻击者在自身射程内 + 本回合未反击过 + 未被冻
    public func canCounter(_ attacker: WarUnit) -> Bool {
        counterAttack && !isDead && !hasCountered && !stunned
            && Grid.manhattan(x, y, attacker.x, attacker.y) <= attackRange
    }

    /// 若攻击者站在落点 p，本单位是否能反击到它。
    /// 评分必须用这个版本：`canCounter(attacker)` 用的是攻击者**当前**站位，
    /// 对"移动后攻击"候选会低估风险（远程兵因此敢贴脸）。
    public func canCounterAttackerAt(_ p: GridPoint) -> Bool {
        counterAttack && !isDead && !hasCountered && !stunned
            && Grid.manhattan(x, y, p.x, p.y) <= attackRange
    }

    public func resetTurn() {
        if stunned {
            // 冰冻在本回合开始时“生效而非解除”：配额全部归零，但 stunned 位留着 ——
            // 它要到对手下个回合开始时才被清（见 Battlefield.beginTurn 的解冻时机），
            // 于是整个被冻回合里连反击都被 canCounter 的 !stunned 挡掉。只冻一回合，不累积。
            remainingMove = 0
            remainingAttacks = 0
            remainingSpell = 0
            hasCountered = false
            return
        }
        remainingMove = moveRange
        remainingAttacks = WarConfig.maxAttacksPerTurn
        remainingSpell = (isChief && spellCharges.values.contains { $0 > 0 })
            ? WarConfig.maxSpellsPerTurn : 0
        hasCountered = false
    }

    // MARK: - 快照（AI 前瞻 / 行动回放需要精确回滚所有可变字段）

    public func toState() -> UnitState {
        UnitState(x: x, y: y, hp: hp, remainingMove: remainingMove,
                  remainingAttacks: remainingAttacks, hasCountered: hasCountered,
                  spellCharges: spellCharges, remainingSpell: remainingSpell, stunned: stunned)
    }

    public func restoreState(_ s: UnitState) {
        x = s.x
        y = s.y
        hp = s.hp
        remainingMove = s.remainingMove
        remainingAttacks = s.remainingAttacks
        hasCountered = s.hasCountered
        spellCharges = s.spellCharges
        remainingSpell = s.remainingSpell
        stunned = s.stunned
    }
}

/// 单位可变状态快照
public struct UnitState: Equatable {
    public let x: Int
    public let y: Int
    public let hp: Int
    public let remainingMove: Int
    public let remainingAttacks: Int
    public let hasCountered: Bool
    public let spellCharges: [String: Int]
    public let remainingSpell: Int
    public let stunned: Bool
}

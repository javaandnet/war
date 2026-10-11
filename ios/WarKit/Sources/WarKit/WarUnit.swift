import Foundation

/// 单位纯状态对象（不含任何移动/渲染能力）。
///
/// 与 JS 原型的关键差异：`move` 能力被彻底移除 —— 移动只能经由
/// `Battlefield.moveAlongPath` 走，那里会校验 4 邻接、占位、地形消耗并扣减配额，
/// 从结构上杜绝"改坐标不扣点"这类规则漏洞。
///
/// 成长（等级 / 属性点 / 转职）都写在这里、并由 `UnitState` 一并快照：
/// AI 的前瞻与回合重放靠 `snapshot()/restore()` 回滚状态，成长字段若漏进快照，
/// 前瞻里"升了级的那个子"在回滚后就会带着旧数值继续算 —— 决策与动画必然分叉。
public final class WarUnit {
    public let id: Int
    /// **基础**兵种 key：军费价目、三线升级账、转职分支表都认它，转职不改写
    /// （改写之后"我升到过几档的步兵"就查无此兵了）。
    public let type: String
    /// 0 = 我方（蓝），1 = 敌方（红）
    public let camp: Int
    /// 三线军费升级等级（攻/防/生命，各自 T0 起、不限级）。`let`：它是买断资产，
    /// 战斗中永不改变，因此不进快照。
    public let upgrades: WarConfig.Upgrades
    /// AI / 观战单位的自动成长旗标：升级瞬间按兵种偏好把属性点分掉。
    /// 创建时写定、战斗中不变，所以**不进快照**。
    public let autoGrows: Bool

    /// 当前生效的兵种 key：未转职 = `type`，转职后指向分支条目。
    /// 一切战斗数值都由它 + `upgrades` + `attrAlloc` 现算（见 `stat`）。
    public var typeKey: String { didSet { refreshStats() } }

    public var x: Int
    public var y: Int
    public var hp: Int

    // MARK: 成长（可变，全部进快照）

    /// 战场等级（1 起）
    public var level: Int
    /// 当前等级内已积累的经验
    public var expIntoLevel: Int
    /// 待分配属性点（玩家侧存着由 UI 分；AI 侧在升级瞬间就分掉）
    public var attrBank: Int
    /// 已分配到攻/防/生命的点数
    public var attrAlloc: WarConfig.Upgrades { didSet { refreshStats() } }

    // MARK: 回合配额

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
    /// 本局携带的每种魔法**等级**（首领专用，士兵恒为空）。“买档”是跨局永久资产，
    /// 而它在战斗中永不改变，所以与 `spellKeys` 同理不进快照。
    public var spellLevels: [String: Int]
    /// 本回合剩余施法次数（与普攻互斥，见 Battlefield.castSpell 的配额扣除）
    public var remainingSpell: Int
    /// 被冰冻：持续到它自己的下一个回合结束（不能移动/攻击/施法/反击）
    public var stunned: Bool

    /// 当前生效的兵种数值（基础表 × 军费倍率 + 属性点）。
    /// 存起来而不是每次读都重算：AI 一个回合要读几万次数值，而写入点只有三处
    /// （创建、`attrAlloc`、`typeKey`），都走 `refreshStats`。
    private(set) var stat: WarConfig.UnitStat

    public var isDead: Bool { hp <= 0 }
    public var position: GridPoint { GridPoint(x: x, y: y) }

    // MARK: 对外数值口径（读侧一律这四个，转职/加点自然反映到评分与威胁图）

    public var name: String { stat.name }
    public var symbol: String { stat.symbol }
    public var maxHp: Int { stat.hp }
    public var atk: Int { stat.atk }
    public var def: Int { stat.def }
    public var moveRange: Int { stat.moveRange }
    public var attackRange: Int { stat.attackRange }
    public var counterAttack: Bool { stat.counterAttack }
    /// 兵种战略价值（AI 目标选择用）。取**当前**兵种的表值：转职成更强的形态，
    /// 自然更容易被对面集火。
    public var value: Double { stat.value }
    /// 是否首领：斩首胜利与施法资格的判据（分支表里王者/圣骑士同为 `isChief`）
    public var isChief: Bool { stat.isChief }

    // MARK: 成长读数

    /// 是否已转职
    public var isPromoted: Bool { typeKey != type }
    /// 当前形态的等级上限：未转职 10 / 已转职 20
    public var levelCap: Int { WarConfig.Growth.levelCap(promoted: isPromoted) }
    /// 再升一级需要多少经验（已到上限则为 0，UI 据此不再画进度）
    public var expToNext: Int { level >= levelCap ? 0 : WarConfig.Growth.expToNext(level) }
    /// 本形态还能继续升级吗
    public var canLevelUp: Bool { level < levelCap }
    /// 该兵种的转职候选（顺序即 UI 按钮顺序）
    public var promotionOptions: [String] { WarConfig.promotions[type] ?? [] }
    /// 已转职的分支 key（未转职为 nil）
    public var branchKey: String? { isPromoted ? typeKey : nil }
    /// 可以转职：满 10 级、未转职、且这兵种确实有分支
    public var canPromote: Bool {
        !isDead && !isPromoted && level >= WarConfig.Growth.promoteLevel && !promotionOptions.isEmpty
    }

    /// 是否有施法资格：首领 + 本回合还有施法次数 + 至少一种魔法还有发。
    /// 射程/视线/目标阵营这些还得由 `Battlefield.castSpell` 校，这里只管“能不能出手”。
    public var canCast: Bool { isChief && remainingSpell > 0 && spellCharges.values.contains { $0 > 0 } }

    /// 该种魔法本局还剩几发
    public func charges(for key: String) -> Int { spellCharges[key] ?? 0 }

    public init(id: Int, type: String, camp: Int, x: Int, y: Int,
                upgrades: WarConfig.Upgrades = WarConfig.Upgrades(),
                autoGrows: Bool = false,
                growth: WarConfig.Growth.UnitGrowth? = nil) {
        // 数值经 `Growth.stat` 过两道：三线军费倍率 → 属性点固定加成。
        // 未知兵种照旧直接崩（它属于配置错误，不该静默变成一支空数值军队）。
        guard let base = WarConfig.unitTypes[type] else { fatalError("未知兵种类型: \(type)") }
        self.id = id
        self.type = type
        self.upgrades = upgrades
        self.autoGrows = autoGrows
        self.camp = camp
        self.x = x
        self.y = y

        // 闯关带回的成长：分支必须是**这个兵种**的分支，否则旧存档里的脏 key
        // 会让一个步兵进来就叫"王者"。非法分支按未转职处理（宁可少给，不可给错）。
        let g = growth ?? WarConfig.Growth.UnitGrowth()
        let branch = g.branch.flatMap { WarConfig.promotions[type]?.contains($0) == true ? $0 : nil }
        typeKey = branch ?? type
        level = min(g.level, WarConfig.Growth.levelCap(promoted: branch != nil))
        expIntoLevel = g.expIntoLevel
        // 已分配点数不得多于应得点数（存盘被改也顶多回到"没多分"的状态）
        attrAlloc = WarUnit.trimmed(g.alloc, notMoreThan: WarConfig.Growth.grantedPoints(
            level: level, promoted: branch != nil))
        // 未分配点数由「应得 - 已分」回推：存盘因此少一个可以被刷的字段
        attrBank = max(0, WarConfig.Growth.grantedPoints(level: level, promoted: branch != nil)
                       - attrAlloc.atk - attrAlloc.def - attrAlloc.hp)

        // `didSet` 在 init 里不触发，所以初值自己算一遍（这也是 hp 的满血初值来源）
        stat = WarConfig.Growth.stat(typeKey: typeKey, upgrades: upgrades, alloc: attrAlloc) ?? base
        hp = stat.hp
        remainingMove = stat.moveRange
        remainingAttacks = WarConfig.maxAttacksPerTurn
        hasCountered = false
        // 充能属于“本局携带”而非“兵种固有”，所以不在 init 里给：
        // 基线编成（内核测试/冒烟指纹）保持无充能，数值不漂移；买到的发数由布阵层写入。
        spellKeys = []
        spellCharges = [:]
        spellLevels = [:]
        remainingSpell = 0
        stunned = false
    }

    /// 把已分配点数削到不超过应得点数（削序固定：攻 → 防 → 命，保证可复现）
    private static func trimmed(_ alloc: WarConfig.Upgrades, notMoreThan granted: Int) -> WarConfig.Upgrades {
        var out = alloc
        var over = out.atk + out.def + out.hp - granted
        guard over > 0 else { return out }
        for track in [WarConfig.UpgradeTrack.attack, .defense, .health] {
            guard over > 0 else { break }
            let cut = min(out.level(track), over)
            switch track {
            case .attack: out.atk -= cut
            case .defense: out.def -= cut
            case .health: out.hp -= cut
            }
            over -= cut
        }
        return out
    }

    /// 布阵时写入本局魔法携带（唯一入口：名单从“哪几种买了发数”推导，
    /// 因此不会出现“有名单没发数”或反过来的空转）。士兵永远拿不到魔法。
    /// `levels` 是每种魔法的档位（军费买档的结果），缺省即基础档 0。
    public func carrySpells(_ perSpell: [String: Int], levels: [String: Int] = [:]) {
        guard isChief else {
            spellKeys = []
            spellCharges = [:]
            spellLevels = [:]
            remainingSpell = 0
            return
        }
        var map: [String: Int] = [:]
        for (key, count) in perSpell where count > 0 && WarConfig.spells[key] != nil {
            map[key] = count
        }
        spellCharges = map
        spellKeys = map.keys.sorted()
        // 档位只给“真的携带了”的那种魔法：没发数的魔法不该在施法时算出射程/威力（也方便 UI 直接读）
        var lv: [String: Int] = [:]
        for key in map.keys {
            let level = min(max(0, levels[key] ?? 0), WarConfig.maxSpellLevel)
            if level > 0 { lv[key] = level }
        }
        spellLevels = lv
    }

    // MARK: - 成长写入点

    /// 经验入账（唯一的经验写入口）。
    ///
    /// 溢出即升级、每级发 1 点属性点；到上限后**不再积累**（未转职停在 10 级，
    /// 转职把上限抬到 20 之后才继续长 —— 否则攒着的经验会在转职瞬间连升数级）。
    /// `autoGrows` 的单位在升级那一刻按兵种偏好把点数分掉。
    public func addExp(_ amount: Int) {
        guard amount > 0, !isDead, level < levelCap else { return }
        var pending = expIntoLevel + amount
        while level < levelCap {
            let need = WarConfig.Growth.expToNext(level)
            guard pending >= need else { expIntoLevel = pending; return }
            pending -= need
            level += 1
            attrBank += 1
            if autoGrows { _ = spendAutoPoint() }
        }
        expIntoLevel = 0        // 已封顶：余下的经验作废（留着也换不到任何东西）
    }

    /// 花 1 点属性点（唯一写入口，`Battlefield.allocate` 与自动成长都走它）
    @discardableResult
    public func spendPoint(on track: WarConfig.UpgradeTrack) -> Bool {
        guard attrBank > 0 else { return false }
        attrAlloc.bump(track)
        attrBank -= 1
        return true
    }

    /// 自动分配：偏好循环取「已分点数 % 3」那一条线（纯函数，重放必然一致）。
    /// AI / 观战单位在升级与转职那一刻都走这里，手里永远不留待分点数。
    @discardableResult
    public func spendAutoPoint() -> Bool {
        guard attrBank > 0 else { return false }
        let tracks = WarConfig.Growth.preferredTracks(baseType: type)
        let used = attrAlloc.atk + attrAlloc.def + attrAlloc.hp
        return spendPoint(on: tracks[used % tracks.count])
    }

    /// 数值重算：上限涨了就把差额**补进**当前血量（升级不该变相掉血），
    /// 上限被压低（回滚/读档）就钳住，绝不留 130/100 这种脏数字。
    private func refreshStats() {
        guard let next = WarConfig.Growth.stat(typeKey: typeKey, upgrades: upgrades, alloc: attrAlloc)
        else { return }
        if next.hp > stat.hp { hp += next.hp - stat.hp }
        else if hp > next.hp { hp = next.hp }
        stat = next
    }

    /// 导出可持久化的成长账（闯关跨关带回的那一份）。
    /// 只给值不给键：键是**基础兵种** key，由调用方按 `type` 决定 ——
    /// 转职之后 `typeKey` 变了而 `type` 没变，带回下关的仍是"步兵练到了几级"。
    public func growthSnapshot() -> WarConfig.Growth.UnitGrowth {
        WarConfig.Growth.UnitGrowth(level: level, expIntoLevel: expIntoLevel,
                                    alloc: attrAlloc, branch: branchKey)
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
                  spellCharges: spellCharges, remainingSpell: remainingSpell, stunned: stunned,
                  typeKey: typeKey, level: level, expIntoLevel: expIntoLevel,
                  attrBank: attrBank, attrAlloc: attrAlloc)
    }

    public func restoreState(_ s: UnitState) {
        // 先回成长字段（`didSet` 会顺带重算数值与血量），最后一步才把 hp 钉回快照值：
        // 反过来的话中途那次重算会把别的字段带来的血量增减错当成快照本意。
        typeKey = s.typeKey
        level = s.level
        expIntoLevel = s.expIntoLevel
        attrBank = s.attrBank
        attrAlloc = s.attrAlloc
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

/// 单位可变状态快照（含成长：前瞻、回合重放、败局回滚都要能把它整个还原）
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
    /// 当前生效兵种（转职后与 `WarUnit.type` 不同）
    public let typeKey: String
    public let level: Int
    public let expIntoLevel: Int
    public let attrBank: Int
    public let attrAlloc: WarConfig.Upgrades
}

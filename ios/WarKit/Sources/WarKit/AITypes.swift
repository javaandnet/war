import Foundation

/// 候选动作类型
public enum CandidateKind: String, Sendable, Codable {
    case wait
    case move
    case attack
    case moveAttack
    /// 首领施法（与普攻互斥：一个动作）
    case spell
}

/// AI 的一个候选行动：位置 × 动作的**联合**决策。
/// "跑到哪"和"打谁"不能分开求最优，否则会出现"最优落点根本没目标"
/// 这类割裂决策 —— 这是原型 AI 显性差的首要原因。
public struct Candidate {
    public let unit: WarUnit
    public let action: GridPoint
    public let kind: CandidateKind
    public let targetId: Int?
    public let path: [GridPoint]
    /// 施法候选的魔法 key（非施法候选为 nil）。`targetId` 对施法同样适用：
    /// 三种魔法都必须打在有单位的格子上，所以不需要额外坐标字段。
    public let spellKey: String?
    public var score: Double = 0
    public var parts: [String: Double] = [:]

    public init(unit: WarUnit, action: GridPoint, kind: CandidateKind, targetId: Int?, path: [GridPoint],
                spellKey: String? = nil) {
        self.unit = unit
        self.action = action
        self.kind = kind
        self.targetId = targetId
        self.path = path
        self.spellKey = spellKey
    }
}

/// 战略评估结果
public struct StrategyInfo {
    public let rel: Double
    public let materialRatio: Double
    public let strategy: String
    public let objective: GridPoint
    public let focusId: Int?
}

/// 战略层：先判断优劣形势，再决定本回合的打法和重心。
/// 没有这一层，AI 会表现为"各自为战的散兵"；有了它，才会出现
/// 集火、侧翼包抄、占山固守这类**小队级**行为。
public enum Strategist {

    /// 视野模拟：低难度 AI 只能"看清"有限数量/距离内的敌人
    public static func visibleEnemies(for ctx: AiContext) -> [WarUnit] {
        let vision = ctx.difficulty.vision
        if vision == .max { return ctx.aliveEnemies }
        let sorted = ctx.aliveEnemies.sorted {
            Grid.manhattan($0.x, $0.y, ctx.objectiveCenter.x, ctx.objectiveCenter.y)
                < Grid.manhattan($1.x, $1.y, ctx.objectiveCenter.x, ctx.objectiveCenter.y)
        }
        return Array(sorted.prefix(vision))
    }

    public static func assess(_ ctx: AiContext) -> StrategyInfo {
        let bf = ctx.bf
        let own = bf.materialScore(camp: ctx.camp)
        let enemy = bf.materialScore(camp: bf.campOf(otherThan: ctx.camp))
        let rel = (own - enemy) / max(1.0, own + enemy)
        let materialRatio = own / max(1.0, enemy)

        let strategy: String
        let objective: GridPoint
        let enemyCenter = bf.centerOfMass(camp: bf.campOf(otherThan: ctx.camp))
        let ownCenter = bf.centerOfMass(camp: ctx.camp)
        if rel < -0.35 {
            // 大幅劣势：收拢自保
            strategy = "retreat"
            objective = ownCenter
        } else if rel < -0.10 {
            // 略处下风：依托出生区打防守反击
            strategy = "defend"
            objective = ownCenter
        } else if materialRatio > 1.6 {
            // 压倒优势：直捣敌方重心
            strategy = "rush"
            objective = enemyCenter
        } else {
            // **兵力持平 = 主动寻战**（而不是原地对峙）
            // 早先这里把 rel == 0 归入 defend，导致镜像开局双方各自后缩、整局零接战。
            strategy = "attack"
            objective = enemyCenter
        }

        // 残血高价值目标优先集火（击杀收益最大）
        let focus = ctx.aliveEnemies.max { a, b in
            a.value / Double(max(1, a.hp)) < b.value / Double(max(1, b.hp))
        }

        var info = StrategyInfo(rel: rel, materialRatio: materialRatio, strategy: strategy,
                                 objective: objective, focusId: focus?.id)
        // 简单 AI 不做战略约束，避免"看起来太聪明"
        if ctx.difficulty.temperature > 0.7 {
            info = StrategyInfo(rel: rel, materialRatio: materialRatio, strategy: "attack",
                                objective: enemyCenter, focusId: focus?.id)
        }
        return info
    }
}

/// 一个阵营回合的 AI 上下文（缓存影响图、视野、集火表）
public final class AiContext {
    public let bf: Battlefield
    public let camp: Int
    public let difficulty: WarConfig.Difficulty
    public var rng: SeededRng

    public var aliveAllies: [WarUnit]
    public var aliveEnemies: [WarUnit]
    /// 视野裁剪后的敌人（高难度 = 全图）
    public var visibleEnemies: [WarUnit]
    public var maxAlliedAtk: Int
    public var objectiveCenter: GridPoint

    // 以下由 prepareTurn 填充
    public var threat: [Double] = []
    public var ownThreat: [Double] = []
    public var strategy = "attack"
    public var objective = GridPoint(x: 0, y: 0)
    public var focusId: Int?
    /// 单位 → 锁定目标 id（集火用）
    public var locked: [Int: Int] = [:]

    public init(bf: Battlefield, camp: Int, difficulty: WarConfig.Difficulty, rng: SeededRng) {
        self.bf = bf
        self.camp = camp
        self.difficulty = difficulty
        self.rng = rng
        aliveAllies = bf.unitsOfCamp(camp)
        aliveEnemies = bf.unitsOfCamp(bf.campOf(otherThan: camp))
            .sorted { a, b in
                a.value != b.value ? a.value > b.value : a.id < b.id
            }
        maxAlliedAtk = max(1, aliveAllies.map(\.atk).max() ?? 1)
        objectiveCenter = bf.centerOfMass(camp: camp)
        visibleEnemies = []
    }

    /// 每回合开始调用一次（状态变化不频繁，缓存一整回合安全）
    public func prepareTurn() {
        visibleEnemies = Strategist.visibleEnemies(for: self)
        threat = bf.buildThreatMap(camp: bf.campOf(otherThan: camp))
        ownThreat = bf.buildThreatMap(camp: camp)
        let info = Strategist.assess(self)
        strategy = info.strategy
        objective = info.objective
        focusId = info.focusId
    }

    /// 集火目标：优先使用上一回合的锁定（保持连贯），否则用战略层焦点
    public func acquireFocus(for unit: WarUnit) -> Int? {
        if let id = locked[unit.id], let t = bf.findUnitById(id), t.isDead { locked[unit.id] = nil }
        if let id = locked[unit.id], bf.findUnitById(id) != nil { return id }
        locked[unit.id] = focusId
        return focusId
    }
}

// MARK: - 决策日志与回合计划（渲染层依赖）

public struct LogCandidate: Sendable {
    public let kind: CandidateKind
    public let targetId: Int?
    public let action: GridPoint
    public let score: Double
    public let spellKey: String?

    public init(kind: CandidateKind, targetId: Int?, action: GridPoint, score: Double, spellKey: String? = nil) {
        self.kind = kind
        self.targetId = targetId
        self.action = action
        self.score = score
        self.spellKey = spellKey
    }
}

public struct DecisionLog {
    public let unitId: Int
    public let unitName: String
    public let kind: CandidateKind
    public let targetId: Int?
    public let score: Double
    public let parts: [String: Double]
    public let top: [LogCandidate]
    public let lookaheadApplied: Bool
    public let spellKey: String?

    public init(unitId: Int, unitName: String, kind: CandidateKind, targetId: Int?, score: Double,
                parts: [String: Double], top: [LogCandidate], lookaheadApplied: Bool,
                spellKey: String? = nil) {
        self.unitId = unitId
        self.unitName = unitName
        self.kind = kind
        self.targetId = targetId
        self.score = score
        self.parts = parts
        self.top = top
        self.lookaheadApplied = lookaheadApplied
        self.spellKey = spellKey
    }
}

/// 事件类型（渲染层按顺序重放，与 AI 内部推演使用同一个 Battlefield 方法）
public enum AiEventKind: String, Sendable {
    case wait
    case move
    case attack
    /// 施法（含溅射/治疗/冻结三种子效果，统一由 `Battlefield.castSpell` 落账）
    case spell
}

public struct AiEvent {
    public let kind: AiEventKind
    public let unitId: Int
    public let from: GridPoint
    public let to: GridPoint
    /// 完整路径（渲染层据此逐格动画）
    public let path: [GridPoint]
    public let targetId: Int?
    public let damage: Int
    public let counterDamage: Int
    public let killed: Bool
    public let counterKilled: Bool
    public let spent: Int
    public let score: Double
    public let desc: String
    /// 施法事件的魔法 key
    public let spellKey: String?
    /// 施法事件的影响格（确定序）：溅射可能一次命中多格，飘字要逐格对齐
    public let affected: [GridPoint]

    public init(kind: AiEventKind, unitId: Int, from: GridPoint, to: GridPoint, path: [GridPoint],
                targetId: Int?, damage: Int, counterDamage: Int, killed: Bool, counterKilled: Bool,
                spent: Int, score: Double, desc: String,
                spellKey: String? = nil, affected: [GridPoint] = []) {
        self.kind = kind
        self.unitId = unitId
        self.from = from
        self.to = to
        self.path = path
        self.targetId = targetId
        self.damage = damage
        self.counterDamage = counterDamage
        self.killed = killed
        self.counterKilled = counterKilled
        self.spent = spent
        self.score = score
        self.desc = desc
        self.spellKey = spellKey
        self.affected = affected
    }
}

/// 回合计划：AI 真实推演出的结果 + 可重放事件序列。
/// 渲染层不自行推算伤害、不自行决定移动终点，只重放事件 ——
/// 这保证"AI 在日志里宣称的收益"与"玩家看到的动画"必然一致。
public struct TurnPlan {
    public let camp: Int
    /// 本回合战略层结论（进攻/防守/冲锋/脱离接触），供 UI 展示"AI 在想什么"
    public let strategy: String
    public let objective: GridPoint
    public let focusId: Int?
    public let before: [UnitState]
    public let final: [UnitState]
    public let events: [AiEvent]
    public let logs: [DecisionLog]
    public let decisionCount: Int
    public let elapsedMs: Double

    public init(camp: Int, strategy: String, objective: GridPoint, focusId: Int?,
                before: [UnitState], final: [UnitState], events: [AiEvent], logs: [DecisionLog],
                decisionCount: Int, elapsedMs: Double) {
        self.camp = camp
        self.strategy = strategy
        self.objective = objective
        self.focusId = focusId
        self.before = before
        self.final = final
        self.events = events
        self.logs = logs
        self.decisionCount = decisionCount
        self.elapsedMs = elapsedMs
    }
}

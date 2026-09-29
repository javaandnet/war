import Foundation

/// 前瞻层（浅层 rollout）：只对分数最高的少数候选做 1~2 回合推演。
///
/// 不做完整 minimax 的原因：战棋单回合分支是 (单位数 × 落点数 × 目标数)，
/// 20v20 全枚举要 10^6 量级；而手机上的预算只有几毫秒。
/// 实测定长：只对 top-K 做推演，把"会不会被反打"这类二阶效应捞回来，
/// 性价比远高于加深搜索深度。
public final class Lookahead {
    /// 参与推演的候选数（其余候选沿用即时评分）
    public static let topK = 4
    /// 前瞻分项在总分中的权重（与 weights 同量纲：归一化后的物质增益 × 此值）
    public static let valueWeight = 60.0
    /// 终局项：把“已斩首/被斩首”折成物质分尺度上的压倒量（全军物质分约 20，首领约 4）
    public static let winValue = 100.0

    private let bf: Battlefield
    private let ctx: AiContext

    public init(bf: Battlefield, ctx: AiContext) {
        self.bf = bf
        self.ctx = ctx
    }

    /// 对 top-K 候选推演，返回调整后的候选（其余候选原样保留）
    public func evaluate(_ candidates: [Candidate], depth: Int) -> [Candidate] {
        guard depth > 0, candidates.count > 1 else { return candidates }

        let ranked = candidates.sorted(by: higher)
        let subset = Array(ranked.prefix(Lookahead.topK))
        let rest = Array(ranked.dropFirst(subset.count))

        var adjusted: [Candidate] = []
        for candidate in subset {
            let snap = bf.snapshot()
            let base = stateValue(for: candidate.unit.camp)

            apply(candidate)
            let me = candidate.unit.camp
            let foe = bf.campOf(otherThan: me)
            for ply in 1...depth {
                // 敌方：视作"下个回合满状态行动"
                bf.beginTurn(camp: foe)
                greedyTurn(camp: foe, resetQuotas: false)
                if ply < depth {
                    // 我方：同样进入下一回合（点数重置），
                    // 否则推演会变成"敌方连动两次、我方无力还手"，
                    // 深度越大越保守，反而把高档 AI 拖成软柿子。
                    bf.beginTurn(camp: me)
                    greedyTurn(camp: me, resetQuotas: false)
                }
            }
            let delta = stateValue(for: candidate.unit.camp) - base
            bf.restore(snap)

            var c = candidate
            c.score += delta * Lookahead.valueWeight
            adjusted.append(c)
        }
        return (adjusted + rest).sorted(by: higher)
    }

    // MARK: - 状态价值

    /// 物质差（我方 − 敌方），单位约等于"100hp × 兵种价值"，再叠上终局项。
    ///
    /// 必须带终局项：只算物质分就是“第二套口径”—— 首领在物质上很值钱（value 2.5、160hp），
    /// 但它真正的面值是“它一死本局就地结束”。于是深算会拿一次换血
    /// 否掉直接赢面的着法（实测 nightmare 对 hard 因此从 25/40 掉到 18/40）。
    private func stateValue(for camp: Int) -> Double {
        let foe = bf.campOf(otherThan: camp)
        var v = bf.materialScore(camp: camp) - bf.materialScore(camp: foe)
        if bf.isChiefLost(camp: foe) { v += Lookahead.winValue }
        if bf.isChiefLost(camp: camp) { v -= Lookahead.winValue }
        return v
    }

    // MARK: - 快棋手（rollout 策略）

    /// 简单贪心：每个单位挑"期望伤害最大且尽量无反击"的动作，打不到就朝重心靠。
    /// rollout 不求精准，只求不弱于随机 —— 否则前瞻结论会被噪声淹没。
    private func greedyTurn(camp: Int, resetQuotas: Bool) {
        if resetQuotas { bf.beginTurn(camp: camp) }
        let objective = bf.centerOfMass(camp: bf.campOf(otherThan: camp))
        for unit in bf.unitsOfCamp(camp).sorted(by: { $0.id < $1.id }) {
            if unit.isDead { continue }
            let reach = bf.reachableWithBudget(unit, budget: unit.remainingMove)
            let ordered = reach.keys.sorted { a, b in
                let ca = reach[a]!.cost, cb = reach[b]!.cost
                if ca != cb { return ca < cb }
                if a.y != b.y { return a.y < b.y }
                return a.x < b.x
            }
            let enemies = bf.unitsOfCamp(bf.campOf(otherThan: camp)).sorted(by: { $0.id < $1.id })

            var bestGain = -1.0
            var best: (GridPoint, WarUnit, [GridPoint])?
            if unit.remainingAttacks > 0 {
                for p in ordered {
                    guard let cell = reach[p] else { continue }
                    for target in enemies where bf.canAttackFrom(unit, from: p, to: target) {
                        let dmg = unit.damageTo(target, targetTerrainDefBonus: bf.getTerrainDefBonus(target.position))
                        let gain = dmg >= target.hp ? Double.infinity
                            : Double(dmg) - (target.canCounterAttackerAt(p)
                                ? Double(target.damageTo(unit, targetTerrainDefBonus: bf.getTerrainDefBonus(p))) * 0.6
                                : 0)
                        if gain > bestGain {
                            bestGain = gain
                            best = (p, target, cell.path)
                        }
                    }
                }
            }
            if let (p, target, path) = best {
                if p != unit.position { bf.moveAlongPath(unit, path: path) }
                if !unit.isDead { bf.attack(unit, target) }
            } else {
                // 纯机动：向敌方重心靠，其次少花点数
                var bestScore = -Double.infinity
                var bestPath: [GridPoint]?
                for p in ordered {
                    guard let cell = reach[p], p != unit.position else { continue }
                    let score = -Double(Grid.manhattan(p, objective)) * 10 - Double(cell.cost) * 0.1
                    if score > bestScore {
                        bestScore = score
                        bestPath = cell.path
                    }
                }
                if let path = bestPath { bf.moveAlongPath(unit, path: path) }
            }
        }
    }

    // MARK: - 候选落地（与真实执行完全同一套规则）

    private func apply(_ candidate: Candidate) {
        let unit = candidate.unit
        if candidate.kind == .move || candidate.kind == .moveAttack, candidate.path.count > 1 {
            bf.moveAlongPath(unit, path: candidate.path)
        }
        if candidate.kind == .attack || candidate.kind == .moveAttack,
           let tid = candidate.targetId, let target = bf.findUnitById(tid), !target.isDead {
            bf.attack(unit, target)
        }
        // 施法候选：推演与重放调同一个 `castSpell`，否则“AI 算出来的收益”与
        // “玩家看到的飘字”会分成两套口径（本项目逐帧不变式直接拒绝这种事）。
        if candidate.kind == .spell, let tid = candidate.targetId,
           let target = bf.findUnitById(tid), let spellKey = candidate.spellKey {
            bf.castSpell(unit, spell: spellKey, at: target.position)
        }
    }

    private func higher(_ a: Candidate, _ b: Candidate) -> Bool {
        if a.score != b.score { return a.score > b.score }
        if a.action.y != b.action.y { return a.action.y < b.action.y }
        if a.action.x != b.action.x { return a.action.x < b.action.x }
        if (a.targetId ?? -1) != (b.targetId ?? -1) { return (a.targetId ?? -1) < (b.targetId ?? -1) }
        if (a.spellKey ?? "") != (b.spellKey ?? "") { return (a.spellKey ?? "") < (b.spellKey ?? "") }
        return a.kind.rawValue < b.kind.rawValue
    }
}

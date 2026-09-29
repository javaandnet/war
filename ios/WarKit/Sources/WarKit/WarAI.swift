import Foundation

/// AI 编排层：战略 → 枚举 → 评分 →（前瞻）→ softmax 采样 → 执行。
///
/// 难度不由"另一套算法"实现，而由三个正交旋钮实现：
///   - `vision`：能看清多少敌人（信息维度，不是数值补偿）
///   - `temperature`：softmax 随机度（执行维度）
///   - `lookahead`：前瞻层数（搜索维度）
/// 因此四档难度共享同一份评分代码，改一次权重全难度受益；
/// 且实测胜率随档位单调上升（见 WarKitTests 的 difficulty 用例）。
public final class WarAI {
    public let bf: Battlefield

    public init(bf: Battlefield) {
        self.bf = bf
    }

    /// 单个单位的决策：返回按分数降序的候选（首个即可执行候选由调用方挑选）
    public func decideCandidates(_ ctx: AiContext, _ unit: WarUnit) -> [Candidate] {
        var candidates = Enumerator.enumerate(ctx, unit)
        candidates = candidates.map { Scorer.score(ctx, $0) }
        if ctx.difficulty.lookahead > 0 {
            candidates = Lookahead(bf: bf, ctx: ctx).evaluate(candidates, depth: ctx.difficulty.lookahead)
        } else {
            candidates = candidates.sorted(by: higher)
        }
        return candidates
    }

    /// softmax 采样：temperature 越大越"手软"。
    /// 这是比"给低难度 AI 降属性"更好的削弱方式 —— 玩家感觉到的差异是
    /// "它偶尔会走错"，而不是"它怎么变脆了"。
    /// 公开以便回归测试直接验证"温度↑ ⇒ 平均后悔值↑"的单调性。
    public func sampleChoice(_ ranked: [Candidate], temperature: Double, rng: inout SeededRng) -> Candidate? {
        guard let best = ranked.first else { return nil }
        guard temperature > 0.001, ranked.count > 1 else { return best }

        let top = Array(ranked.prefix(6))
        let maxScore = top[0].score
        // 以分为单位的指数归一（分值量级 ~10^2，故除以尺度因子避免 exp 溢出）。
        // 尺度因子必须由 temperature 连续控制：早前的 max(1.0, T) 下限会把
        // 0.02 与 0.9 掉成同一个分布，难度旋钮直接失效（已被回归测试抓到）。
        let scaleT = max(0.02, temperature) * 40.0
        var weights: [Double] = []
        var sum = 0.0
        for c in top {
            let w = exp((c.score - maxScore) / scaleT)
            weights.append(w)
            sum += w
        }
        guard sum > 0 else { return best }

        var throwaway = rng.next() * sum
        for (i, w) in weights.enumerated() {
            throwaway -= w
            if throwaway <= 0 { return top[i] }
        }
        return top.last
    }

    /// 执行整个阵营回合：真实推进状态，并产出可重放的事件序列。
    /// - Parameters:
    ///   - seed: 决定采样与前瞻的随机序列；同一 seed + 同一局面 ⇒ 完全相同的回合
    public func executeTurn(camp: Int, difficulty: WarConfig.Difficulty, seed: Int) -> TurnPlan {
        let started = ProcessInfo.processInfo.systemUptime
        let ctx = AiContext(bf: bf, camp: camp, difficulty: difficulty, rng: SeededRng(seed: seed))
        ctx.prepareTurn()

        let before = bf.snapshot()
        var events: [AiEvent] = []
        var logs: [DecisionLog] = []
        var decisions = 0

        for unit in bf.unitsOfCamp(camp).sorted(by: { $0.id < $1.id }) {
            if unit.isDead { continue }
            let ranked = decideCandidates(ctx, unit)
            // 先过滤掉“目标已被友军击杀”的失效候选，再做 softmax 采样
            let valid = ranked.filter { c in
                guard let tid = c.targetId else { return true }
                return bf.findUnitById(tid) != nil
            }
            guard let chosen = sampleChoice(valid, temperature: difficulty.temperature, rng: &ctx.rng) else {
                continue
            }
            decisions += 1

            let from = unit.position
            var path: [GridPoint] = chosen.path
            var spent = 0
            let eventCountBefore = events.count

            // 1) 位移
            if chosen.kind == .move || chosen.kind == .moveAttack, chosen.path.count > 1 {
                let moved = bf.moveAlongPath(unit, path: chosen.path)
                spent = moved.spent
                path = moved.reached == from ? [from] : chosen.path
                if moved.success, moved.spent > 0 {
                    events.append(AiEvent(kind: .move, unitId: unit.id, from: from, to: moved.reached,
                                          path: chosen.path, targetId: nil, damage: 0, counterDamage: 0,
                                          killed: false, counterKilled: false, spent: moved.spent,
                                          score: chosen.score, desc: "\(unit.name) 移动 \(moved.spent) 点"))
                }
            }

            // 2) 攻击（只有攻击类候选才走这里；纯移动候选不再误发待命事件）
            if chosen.kind == .attack || chosen.kind == .moveAttack,
               let tid = chosen.targetId, let target = bf.findUnitById(tid) {
                let result = bf.attack(unit, target)
                events.append(AiEvent(kind: .attack, unitId: unit.id, from: unit.position,
                                      to: target.position, path: path, targetId: tid,
                                      damage: result.damage, counterDamage: result.counterDamage,
                                      killed: result.targetKilled, counterKilled: result.counterKilled,
                                      spent: spent, score: chosen.score,
                                      desc: "\(unit.name) → \(target.name) \(result.damage)"
                                            + (result.counterDamage > 0 ? "（反击 \(result.counterDamage)）" : "")
                                            + (result.targetKilled ? " 击杀" : "")))
            }

            // 2.5) 施法（与普攻互斥，所以上面那支不会同时命中）
            if chosen.kind == .spell, let tid = chosen.targetId, let target = bf.findUnitById(tid),
               let spellKey = chosen.spellKey {
                let result = bf.castSpell(unit, spell: spellKey, at: target.position)
                let stat = WarConfig.spells[spellKey]
                let isHurt = stat?.effect == .damage
                let total = result.affected.values.reduce(0) { $0 + $1 }
                events.append(AiEvent(kind: .spell, unitId: unit.id, from: unit.position,
                                      to: target.position, path: path, targetId: tid,
                                      damage: isHurt ? total : 0, counterDamage: 0,
                                      killed: !result.killed.isEmpty, counterKilled: false,
                                      spent: spent, score: chosen.score,
                                      desc: "\(unit.name) 施放 \(stat?.name ?? spellKey)：\(result.message)",
                                      spellKey: spellKey, affected: result.affectedPoints))
            }

            // 3) 兜底：本回合该单位确实什么都没做（待命，或移动未花点数）
            if events.count == eventCountBefore {
                events.append(AiEvent(kind: .wait, unitId: unit.id, from: unit.position, to: unit.position,
                                      path: [unit.position], targetId: nil, damage: 0, counterDamage: 0,
                                      killed: false, counterKilled: false, spent: spent, score: chosen.score,
                                      desc: "\(unit.name) 待命"))
            }

            // 4) 决策日志（供"AI 为什么这么走"面板展示）
            logs.append(DecisionLog(
                unitId: unit.id,
                unitName: unit.name,
                kind: chosen.kind,
                targetId: chosen.targetId,
                score: chosen.score,
                parts: chosen.parts,
                top: ranked.prefix(5).map {
                    LogCandidate(kind: $0.kind, targetId: $0.targetId, action: $0.action, score: $0.score,
                                 spellKey: $0.spellKey)
                },
                lookaheadApplied: ctx.difficulty.lookahead > 0,
                spellKey: chosen.spellKey
            ))
        }

        let final = bf.snapshot()

        return TurnPlan(camp: camp, strategy: ctx.strategy, objective: ctx.objective, focusId: ctx.focusId,
                        before: before, final: final, events: events, logs: logs,
                        decisionCount: decisions,
                        elapsedMs: (ProcessInfo.processInfo.systemUptime - started) * 1000.0)
    }

    /// 以难度 key 调用（UI 层直接拿 Settings 里的字符串即可）
    public func executeTurn(camp: Int, difficultyKey: String, seed: Int) -> TurnPlan {
        let diff = WarConfig.difficulties[difficultyKey] ?? WarConfig.difficulties[WarConfig.defaultDifficultyKey]!
        return executeTurn(camp: camp, difficulty: diff, seed: seed)
    }

    private func higher(_ a: Candidate, _ b: Candidate) -> Bool {
        if a.score != b.score { return a.score > b.score }
        if a.action.y != b.action.y { return a.action.y < b.action.y }
        if a.action.x != b.action.x { return a.action.x < b.action.x }
        if (a.targetId ?? -1) != (b.targetId ?? -1) { return (a.targetId ?? -1) < (b.targetId ?? -1) }
        // 施法候选多了两个维度，排序必须形成全序：Swift 的 sorted 不保证稳定，
        // 同分不拆开会令“同一 seed 两局逐帧一致”在首领候选上崩掉。
        if (a.spellKey ?? "") != (b.spellKey ?? "") { return (a.spellKey ?? "") < (b.spellKey ?? "") }
        return a.kind.rawValue < b.kind.rawValue
    }
}

// MARK: - 事件重放（渲染层唯一依赖的接口）

/// 把一个事件作用到战场（渲染层逐事件播放动画时调用）。
/// 与 AI 内部推演使用**同一批** Battlefield 方法，因此动画结果与决策结果必然一致。
public enum Replay {
    @discardableResult
    public static func apply(_ bf: Battlefield, _ event: AiEvent) -> Bool {
        guard let unit = bf.findUnitById(event.unitId) else { return false }
        switch event.kind {
        case .wait:
            // 待命不改变任何状态（回合结束由调用方接管）；
            // 重放必须与推演逐字段相等，这里不能顺手清零机动点。
            return true
        case .move:
            return bf.moveAlongPath(unit, path: event.path).success
        case .attack:
            guard let target = bf.findUnitById(event.targetId ?? -1) else { return false }
            return bf.attack(unit, target).damage > 0
        case .spell:
            // 与 AI 推演调的是同一个 `castSpell`（参数也从事件里取），
            // 因此动画看到的伤害/治疗/冻结与 AI 宣称的必然一致。
            guard let key = event.spellKey, let target = bf.findUnitById(event.targetId ?? -1) else {
                return false
            }
            return bf.castSpell(unit, spell: key, at: target.position).success
        }
    }
}

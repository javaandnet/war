import Foundation

/// 战术层：为单个单位把"每个可达落点 × 每种动作"摊成候选列表。
///
/// 关键设计（对 AI 质量的影响最大）：
/// 攻击候选来自 **可达域外扩射程**，而不是"当前已能打到谁"。
/// 于是"移动 + 攻击"这类组合技被完整枚举出来 —— 原型 AI 因为缺了这一层，
/// 在敌人处于机动距离内但尚不可攻击时只能原地待命，看起来非常呆。
public enum Enumerator {

    /// 候选数量上限（iPhone 上控制在百量级，配合 lookahead 仍可满足帧预算）
    public static let maxCandidatesPerUnit = 120

    public static func enumerate(_ ctx: AiContext, _ unit: WarUnit) -> [Candidate] {
        let bf = ctx.bf
        var candidates: [Candidate] = []
        var seen = Set<String>()

        let origin = unit.position
        let reach = bf.computeReachable(unit)
        // 确定性遍历顺序：先消耗小、再 (y, x) —— 保证同 seed 可复现
        let ordered = reach.keys.sorted { a, b in
            let ca = reach[a]!.cost, cb = reach[b]!.cost
            if ca != cb { return ca < cb }
            if a.y != b.y { return a.y < b.y }
            return a.x < b.x
        }

        let canAttack = unit.remainingAttacks > 0 && !unit.stunned
        let focus = ctx.acquireFocus(for: unit)

        func add(_ kind: CandidateKind, _ action: GridPoint, _ targetId: Int?, _ path: [GridPoint],
                 _ spellKey: String? = nil) {
            let key = "\(kind.rawValue)|\(spellKey ?? "-")|\(targetId ?? -1)|\(action.x),\(action.y)"
            if seen.contains(key) { return }
            seen.insert(key)
            var c = Candidate(unit: unit, action: action, kind: kind, targetId: targetId, path: path,
                              spellKey: spellKey)
            // 集火目标给一点先验加成，避免同分时摇摆
            if let tid = targetId, let f = focus, tid == f { c.score = 0.0001 }
            candidates.append(c)
        }

        if canAttack {
            for p in ordered {
                guard let cell = reach[p] else { continue }
                for target in ctx.visibleEnemies {
                    guard bf.canAttackFrom(unit, from: p, to: target) else { continue }
                    add(p == origin ? .attack : .moveAttack, p, target.id, cell.path)
                }
            }
        }

        for p in ordered {
            guard let cell = reach[p], p != origin, cell.cost > 0 else { continue }
            add(.move, p, nil, cell.path)
        }

        // 首领施法候选：只在**原地**施放。施法与普攻是"一回合一个动作"的关系，
        // 而把位移 × 魔法 × 目标 乘起来会到达三四百个候选，把 120 的预算
        // 全吃光（纯机动候选被砍完会让 AI 只会站桩）；并且法术射程本来比普攻远，
        // 原地放并不损失多少选项。玩家侧 UI 仍可先走再放（内核不禁止）。
        if unit.isChief, unit.remainingSpell > 0, unit.canCast, !unit.stunned {
            for spellKey in WarConfig.spellOrder where unit.charges(for: spellKey) > 0 {
                guard let stat = WarConfig.spells[spellKey] else { continue }
                for target in spellTargets(unit, stat, ctx) {
                    add(.spell, origin, target.id, [origin], spellKey)
                }
            }
        }

        add(.wait, origin, nil, [origin])

        // 超预算时优先保留攻击类候选（砍掉纯机动候选不会明显降低棋力）
        if candidates.count > maxCandidatesPerUnit {
            let rank: (CandidateKind) -> Int = { k in
                switch k {
                case .attack, .moveAttack: return 0
                case .spell: return 1          // 施法不能被机动候选挤掉
                case .move: return 2
                case .wait: return 3
                }
            }
            candidates = candidates
                .enumerated()
                .sorted { a, b in
                    let ra = rank(a.element.kind), rb = rank(b.element.kind)
                    if ra != rb { return ra < rb }
                    return a.offset < b.offset          // 保持稳定序（可复现）
                }
                .prefix(maxCandidatesPerUnit)
                .map(\.element)
        }
        return candidates
    }

    /// 该魔法的合法目标。必须与 `Battlefield.castSpell` 的校验同一口径，
    /// 否则 AI 会为一个根本放不出去的目标刷分（然后在执行时吃了个空）。
    private static func spellTargets(_ caster: WarUnit, _ stat: WarConfig.SpellStat,
                                     _ ctx: AiContext) -> [WarUnit] {
        let bf = ctx.bf
        let from = caster.position
        func inRange(_ t: WarUnit) -> Bool {
            !t.isDead && Grid.manhattan(from, t.position) <= stat.range
                && bf.hasLineOfSight(from: from, to: t.position)
        }
        switch stat.effect {
        case .damage:
            return ctx.visibleEnemies.filter { inRange($0) }
        case .stun:
            return ctx.visibleEnemies.filter { inRange($0) && !$0.stunned }
        case .heal:
            return ctx.aliveAllies.filter { inRange($0) && $0.hp < $0.maxHp }
        }
    }
}

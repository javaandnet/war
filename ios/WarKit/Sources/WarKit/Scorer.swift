import Foundation

/// 效用评分层。
///
/// 两条铁律：
/// 1. **分项一律取 [0,1] 的幅值**（无量纲），符号由权重决定。
///    原型里 damage 是几十点、proximity 是零点几，量纲不统一导致长线项被
///    伤害数值完全压制；而"负分项再乘负权重"则会变成加分。两者都要防。
/// 2. 伤害预估与结算使用**同一个** `WarUnit.damageTo`，
///    所以 AI 的评分依据和真实结果不会有第二套口径。
public enum Scorer {

    private static func weight(_ key: String) -> Double {
        let W = WarConfig.weights
        switch key {
        case "damage": return W.damage
        case "kill": return W.kill
        case "overkill": return W.overkill
        case "selfPreserve": return W.selfPreserve
        case "targetValue": return W.targetValue
        case "exposure": return W.exposure
        case "terrain": return W.terrain
        case "focus": return W.focus
        case "counter": return W.counterRisk
        case "mobility": return W.mobility
        case "surround": return W.surround
        case "objective": return W.objective
        case "support": return W.support
        case "waste": return W.waste
        case "rangePenalty": return W.rangePenalty
        case "engage": return W.engage
        case "proximity": return W.proximity
        case "chiefBounty": return W.chiefBounty
        case "heal": return W.heal
        case "freeze": return W.freeze
        default: return 0
        }
    }

    public static func score(_ ctx: AiContext, _ input: Candidate) -> Candidate {
        var candidate = input
        let bf = ctx.bf
        let unit = candidate.unit
        let S = WarConfig.scale
        var parts: [String: Double] = [:]

        let attackKind = candidate.kind == .attack || candidate.kind == .moveAttack
        let spellKind = candidate.kind == .spell
        let origin = unit.position
        let selfHpRatio = Double(unit.hp) / Double(max(1, unit.maxHp))

        /// 目标“残值”项（伤害与治疗共用同一个尺子）：越残血越值得处理
        func valuePart(_ target: WarUnit) -> Double {
            min(1.0, target.value / S.valueRef)
                * (1.0 - Double(target.hp) / Double(max(1, target.maxHp)) * 0.6)
        }

        // ── 收益 / 浪费 ──
        if attackKind, let tid = candidate.targetId, let target = bf.findUnitById(tid) {
            let dmg = unit.damageTo(target, targetTerrainDefBonus: bf.getTerrainDefBonus(target.position))

            parts["damage"] = min(1.0, Double(dmg) / Double(max(1, S.damageRef)))
            // 分母用 `valueRef`（一般兵种上限）而不再硬编码：首领 value 2.5 直接除
            // 会冲破上面铁律 1 的 [0,1] 约定，所以钳到 1.0，多出来的分量
            // 由 chiefBounty 单独表达 —— 士兵之间的相对分序因此完全不变。
            parts["targetValue"] = valuePart(target)
            if target.isChief {
                // 斩首即终局：打首领不是“削材料”，而是直接接近赢
                parts["chiefBounty"] = 1.0
            }

            if dmg >= target.hp {
                parts["kill"] = min(1.0, target.value)
            } else {
                // 打不死还要动手 = 自己挨反击的风险，血越少越该忍
                parts["selfPreserve"] = 1.0 - selfHpRatio
            }

            let waste = max(0, dmg - target.hp)
            parts["overkill"] = min(1.0, Double(waste) / Double(max(1, S.damageRef)))

            // 远程单位贴脸输出浪费射程优势
            if unit.attackRange > 1 {
                let d = Grid.manhattan(candidate.action, target.position)
                parts["rangePenalty"] = d <= 1 ? 0.5 : 0
            }

            // 反击风险：目标还手能扣我多少血（按我将站立的落点地形与落点距离算）
            if target.canCounterAttackerAt(candidate.action) {
                let cdmg = target.damageTo(unit, targetTerrainDefBonus: bf.getTerrainDefBonus(candidate.action))
                var risk = min(1.0, Double(cdmg) / Double(max(1, S.damageRef))) * (0.4 + selfHpRatio)
                if cdmg >= unit.hp { risk += 1.0 }   // 自杀式攻击重罚
                parts["counter"] = risk
            }
        } else if spellKind, let tid = candidate.targetId, let target = bf.findUnitById(tid),
                  let stat = WarConfig.spells[candidate.spellKey ?? ""] {
            // 施法评分。伤害/斩杀/目标价值复用普攻那套尺子（否则 AI 会在两套口径间
            // 摇摆）；但魔法**不触发反击**，因此不写 counter 项 —— 这是魔法的真实优势，
            // 不是额外奖励。heal/freeze 权重均刻意低于 kill，不会抢掉到手的击杀。
            switch stat.effect {
            case .damage:
                var splashHits = 0
                if stat.splash > 0 {
                    for p in bf.cellsInRadius(target.x, target.y, radius: stat.splashRadius)
                    where p != target.position {
                        if let v = bf.getUnitAt(p), v.camp != unit.camp { splashHits += 1 }
                    }
                }
                let burst = stat.power + stat.splash * splashHits
                parts["damage"] = min(1.0, Double(burst) / Double(max(1, S.damageRef)))
                parts["targetValue"] = valuePart(target)
                if target.isChief { parts["chiefBounty"] = 1.0 }
                if burst >= target.hp {
                    parts["kill"] = min(1.0, target.value)
                } else {
                    parts["selfPreserve"] = 1.0 - selfHpRatio
                }
                parts["overkill"] = min(1.0, Double(max(0, burst - target.hp)) / Double(max(1, S.damageRef)))
            case .heal:
                let healed = min(stat.power, max(0, target.maxHp - target.hp))
                parts["heal"] = min(1.0, Double(healed) / Double(max(1, target.maxHp)))
                parts["targetValue"] = valuePart(target)
            case .stun:
                // 封住一回合的价值按目标火力算（首领/骑兵比残血步兵值得冻）
                parts["freeze"] = min(1.0, target.value / S.valueRef)
            }
        } else {
            // 能打却不打 = 浪费行动配额
            let hasAttackOption = unit.remainingAttacks > 0
                && ctx.visibleEnemies.contains { bf.canAttackFrom(unit, from: origin, to: $0) }
            if hasAttackOption {
                parts["waste"] = 1.0
            } else if unit.remainingMove > 0, candidate.kind == .wait {
                parts["waste"] = 0.35
            }

            if !ctx.aliveEnemies.isEmpty {
                let maxDist = Double(bf.width + bf.height) / 2.0
                let nearest = Double(minDistance(from: candidate.action, to: ctx.aliveEnemies))
                let originNearest = Double(minDistance(from: origin, to: ctx.aliveEnemies))
                let closer = max(0.0, originNearest - nearest) / max(1.0, maxDist)
                let withinReach = originNearest <= Double(unit.remainingMove + unit.attackRange)
                parts["engage"] = closer * (withinReach ? 0.5 : 1.0)
                parts["proximity"] = 1.0 - min(1.0, nearest / max(1.0, maxDist))
            }
        }

        // ── 风险（下回合被打击的概率） ──
        if ctx.threat.count == bf.width * bf.height {
            let t = bf.threatAt(ctx.threat, candidate.action.x, candidate.action.y)
            parts["exposure"] = min(1.0, t / S.threatSaturation)
        } else {
            parts["exposure"] = 0
        }

        // ── 位置 ──
        parts["terrain"] = Double(bf.getTerrainDefBonus(candidate.action)) / Double(max(1, S.maxDefBonus))
        parts["focus"] = (candidate.targetId != nil && candidate.targetId == ctx.focusId) ? 1.0 : 0
        parts["surround"] = 0

        if let tid = candidate.targetId, let target = bf.findUnitById(tid), target.camp != unit.camp {
            var allies = 0
            for a in ctx.aliveAllies where a.id != unit.id {
                if Grid.manhattan(a.x, a.y, target.x, target.y) <= 2, a.canAttack(target) { allies += 1 }
            }
            parts["surround"] = min(1.0, Double(allies) * S.surroundUnit)
        }

        // 机动力使用度：用满机动点（推进到位）比挪一格更值 —— 对抗"站桩不动"的退化
        let moveCost = max(0, candidate.path.count - 1)
        parts["mobility"] = moveCost > 0
            ? min(1.0, Double(moveCost) / Double(max(1, S.moveBudgetRef)))
            : 0

        // ── 战略 ──
        if candidate.kind == .move || candidate.kind == .wait || candidate.kind == .moveAttack {
            let before = Grid.manhattan(origin, ctx.objective)
            let after = Grid.manhattan(candidate.action, ctx.objective)
            let gain = Double(before - after) * S.objectiveGain
            parts["objective"] = (ctx.strategy == "retreat") ? -gain : gain
        } else {
            parts["objective"] = 0
        }

        if attackKind {
            parts["support"] = 0
        } else {
            var endangered = false
            for a in ctx.aliveAllies where a.id != unit.id && a.hp < S.supportHpThreshold {
                if Grid.manhattan(a.position, candidate.action) <= 3 { endangered = true; break }
            }
            parts["support"] = endangered ? 0.6 : -0.3
        }

        // ── 汇总 + 评估抖动（低难度 AI "判断力"不稳，表现为偶发次优手） ──
        var total = 0.0
        for (key, value) in parts.sorted(by: { $0.key < $1.key }) {
            total += value * weight(key)
        }
        let jitter = (ctx.rng.next() * 2 - 1) * min(1.0, ctx.difficulty.temperature) * S.maxNoise
        total += jitter

        candidate.parts = parts
        candidate.score = total + candidate.score   // 保留 enumerator 的集火先验
        return candidate
    }

    private static func minDistance(from p: GridPoint, to units: [WarUnit]) -> Int {
        var best = Int.max
        for u in units {
            best = min(best, Grid.manhattan(p, u.position))
            if best == 0 { break }
        }
        return best == Int.max ? 0 : best
    }
}

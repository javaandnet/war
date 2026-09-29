/**
 * 战棋 AI（回合制）
 *
 * 分层：
 *   Strategist  战略层：本轮打什么（进攻/防守/包抄/集火），产出 squad order
 *   Enumerator  候选枚举：对每个单位生成 (落点, 动作) 组合，而不是"先决定打谁再找位置"
 *   Scorer      效用评分：所有候选用同一套归一化公式打分，附 breakdown 供可视化
 *   Lookahead   浅层推演：对 top-K 候选做 1~2 ply 模拟，用局势评估修正分数
 *   WarAI       编排：softmax 采样 → 落到真实战场 → 记录可重放事件
 *
 * 难度 = 三个正交旋钮（vision / temperature / lookahead），不再各写一套打分逻辑。
 * 全程使用 SeededRng，同 seed 必得同决策，可复现、可回归测试。
 */

/** 一次决策轮内共享的上下文 */
class AiContext {
    constructor(ai, camp) {
        this.ai = ai;
        this.bf = ai.battlefield;
        this.camp = camp;
        this.enemyCamp = this.bf.enemyCamp(camp);
        this.cfg = ai.cfg;
        this.rng = ai.rng;
        this.order = null;          // Strategist 产出
        this.threat = this.bf.buildThreatMap(camp);
        this.maxThreat = this.bf.maxThreat(camp);
        this.locked = new Map();    // targetId -> 已锁定该目标的友军数量
        this.log = [];
    }

    /** 视野裁剪：超出 vision 的敌人视为不可见（模拟不看小地图的玩家） */
    visibleEnemies(fromUnit) {
        const all = this.bf.unitsOfCamp(this.enemyCamp);
        if (!isFinite(this.cfg.vision)) return all;
        return all.filter(e => Unit.distance(fromUnit.x, fromUnit.y, e.x, e.y) <= this.cfg.vision);
    }

    alliesExcluding(unit) {
        return this.bf.unitsOfCamp(this.camp).filter(u => u !== unit);
    }
}

/** 战略层：像玩家一样先想清楚"这回合整体要干什么" */
class Strategist {
    assess(ctx) {
        const bf = ctx.bf;
        const mine = bf.unitsOfCamp(ctx.camp);
        const theirs = bf.unitsOfCamp(ctx.enemyCamp);

        if (mine.length === 0 || theirs.length === 0) {
            return { score: 0, strategy: 'defend', objective: { x: bf.width >> 1, y: bf.height >> 1 }, focusId: null, note: '无仗可打' };
        }

        // 物质差（含血量），归一化到 ±1
        const myPower = mine.reduce((s, u) => s + (u.health / u.maxHealth) * u.aiValue, 0);
        const theirPower = theirs.reduce((s, u) => s + (u.health / u.maxHealth) * u.aiValue, 0);
        const rel = (myPower - theirPower) / (myPower + theirPower);

        const myArchers = mine.filter(u => u.type === 'archer').length;
        const theirArchers = theirs.filter(u => u.type === 'archer').length;
        const myCavalry = mine.filter(u => u.type === 'cavalry').length;

        // 我方最脆的单位 —— 敌方集火的天然目标，也决定我们是否需要收缩保护
        const weakest = mine.reduce((a, b) => (a.health / a.maxHealth) < (b.health / b.maxHealth) ? a : b);

        let strategy = 'attack';
        let note = '均势推进';

        if (rel > 0.35) {
            strategy = 'rush'; note = '兵力优势明显，全面碾压';
        } else if (rel < -0.30) {
            strategy = myPower > 2 ? 'defend' : 'retreat';
            note = myPower > 2 ? '劣势，收缩利用地形' : '崩盘，脱离接触';
        } else if (theirArchers > myArchers * 1.5 && myCavalry >= 2) {
            strategy = 'flank'; note = '敌方弓兵占优，骑兵绕后点杀';
        } else if (rel > 0.10) {
            strategy = 'attack'; note = '小优，压上';
        } else {
            strategy = 'attack'; note = '均势，寻找交换比';
        }

        // 英雄式集火：优先打最残、且我方已有人能顺手打到的目标
        let focus = null;
        let bestFocusScore = -Infinity;
        for (const t of theirs) {
            const s = (1 - t.health / t.maxHealth) * 2 + t.aiValue;
            if (s > bestFocusScore) { bestFocusScore = s; focus = t; }
        }

        // 目标区域：进攻/包抄取敌方重心（flank 时偏上或偏下路），防守取己方重心
        const enemyCenter = this._centroid(theirs, bf);
        const myCenter = this._centroid(mine, bf);
        let objective = strategy === 'defend' || strategy === 'retreat' ? myCenter : enemyCenter;
        if (strategy === 'flank') {
            const side = myCenter.y < bf.height / 2 ? -1 : 1;
            objective = {
                x: enemyCenter.x,
                y: this._clamp(enemyCenter.y + side * 5, 1, bf.height - 2)
            };
        }
        if (strategy === 'retreat') {
            objective = { x: ctx.camp === 1 ? 2 : bf.width - 3, y: myCenter.y };
        }

        return {
            score: Math.round(rel * 100),
            strategy, objective,
            focusId: focus ? focus.id : null,
            weakestId: weakest.id,
            note: `${note}（物质差 ${Math.round(rel * 100)}%，我方 ${mine.length} vs 敌方 ${theirs.length}）`
        };
    }

    _centroid(units, bf) {
        if (!units.length) return { x: bf.width >> 1, y: bf.height >> 1 };
        let sx = 0, sy = 0;
        for (const u of units) { sx += u.x; sy += u.y; }
        return { x: Math.round(sx / units.length), y: Math.round(sy / units.length) };
    }

    _clamp(v, lo, hi) {
        return Math.max(lo, Math.min(hi, v));
    }
}

/** 候选动作：一切决策都是"从候选列表里挑一个" */
class Candidate {
    constructor(kind, unit) {
        this.kind = kind;            // 'attack' | 'moveAttack' | 'move' | 'wait'
        this.unitId = unit.id;
        this.dest = { x: unit.x, y: unit.y };
        this.path = [{ x: unit.x, y: unit.y }];
        this.moveCost = 0;
        this.targetId = null;
        this.damage = 0;
        this.counterDamage = 0;
        this.kills = false;
        this.score = 0;
        this.parts = {};
    }

    describe() {
        const at = `(${this.dest.x},${this.dest.y})`;
        switch (this.kind) {
            case 'attack': return `原地攻击#${this.targetId} 伤害${this.damage}`;
            case 'moveAttack': return `走到${at} 攻击#${this.targetId} 伤害${this.damage}${this.kills ? '[击杀]' : ''}${this.counterDamage ? ` 被反击${this.counterDamage}` : ''}`;
            case 'move': return `走到${at} 消耗${this.moveCost}`;
            default: return '待命';
        }
    }
}

/**
 * 候选枚举。
 * 关键修正：旧实现在"先 tryAttack 再 tryMove"的贪心顺序下，
 * 无法表达"走到位再打""为包围而放弃本轮击杀"这类真实决策。
 * 这里把 (落点 × 动作) 全部摊开，交给同一个评分器比较。
 */
class Enumerator {
    enumerate(unit, ctx) {
        const bf = ctx.bf;
        const out = [];
        const enemies = ctx.visibleEnemies(unit);
        const reach = bf.computeReachable(unit);
        const canShoot = unit.remainingAttacks > 0;

        /** 在某落点能打到哪些目标 */
        const targetsFrom = (x, y) => {
            if (!canShoot) return [];
            return enemies.filter(e => bf.canTargetFrom(unit, e, x, y));
        };

        // 1) 原地可打的目标
        for (const t of targetsFrom(unit.x, unit.y)) {
            out.push(this._makeAttack(unit, ctx, t, null));
        }

        // 2) 移动后攻击（这是战棋 AI 的主要决策面）
        for (const cell of reach.values()) {
            for (const t of targetsFrom(cell.x, cell.y)) {
                out.push(this._makeAttack(unit, ctx, t, cell));
            }
        }

        // 3) 纯机动（不开火：抢占地形、包抄、撤退、拉开射界）
        for (const cell of reach.values()) {
            const c = new Candidate('move', unit);
            c.dest = { x: cell.x, y: cell.y };
            c.path = cell.path;
            c.moveCost = cell.cost;
            out.push(c);
        }

        // 4) 待命。永远保留这个基线候选，AI 才有"不动比乱动好"的表达方式
        out.push(new Candidate('wait', unit));

        return out;
    }

    _makeAttack(unit, ctx, target, cell) {
        const bf = ctx.bf;
        const c = cell ? new Candidate('moveAttack', unit) : new Candidate('attack', unit);
        if (cell) {
            c.dest = { x: cell.x, y: cell.y };
            c.path = cell.path;
            c.moveCost = cell.cost;
        }
        c.targetId = target.id;
        c.damage = unit.damageTo(target, bf.terrainDefBonus(target.x, target.y));
        c.kills = c.damage >= target.health;

        // 反击预估：目标存活、有反击资格、且打完仍在其射程内
        const defenderAlive = !c.kills;
        const canCounter = defenderAlive && target.counterAttack &&
            Unit.distance(c.dest.x, c.dest.y, target.x, target.y) <= target.attackRange;
        if (canCounter) {
            c.counterDamage = target.damageTo(unit, bf.terrainDefBonus(c.dest.x, c.dest.y));
        }
        return c;
    }
}

/** 效用评分：所有候选同源同量纲 */
class Scorer {
    score(cand, unit, ctx) {
        const bf = ctx.bf;
        const W = WarConfig.weights;
        const S = WarConfig.scale;
        const p = {};

        const target = cand.targetId !== null ? bf.units.find(u => u.id === cand.targetId) : null;

        // ---- 伤害类
        p.damage = 0; p.kill = 0; p.overkill = 0; p.targetValue = 0; p.counter = 0;
        if (target) {
            const norm = Math.min(1, cand.damage / S.damageRef);
            p.damage = W.damage * norm;

            if (cand.kills) p.kill = W.kill * Math.min(1, target.aiValue);
            const waste = Math.max(0, cand.damage - target.health);
            p.overkill = W.overkill * Math.min(1, waste / S.damageRef);

            // 兵种价值 × 残血补刀倾向
            const hpRatio = target.health / target.maxHealth;
            p.targetValue = W.targetValue * (target.aiValue / 1.35) * (1 - hpRatio * 0.6);

            if (ctx.order.focusId === target.id) p.focus = W.focus;
            p.focus = (p.focus || 0) + W.focus * Math.min(1, (ctx.locked.get(target.id) || 0) / 2);

            if (cand.counterDamage > 0) {
                const selfHp = unit.health / unit.maxHealth;
                p.counter = W.counter * Math.min(1, cand.counterDamage / S.damageRef) * (0.4 + selfHp);
                if (cand.counterDamage >= unit.health) p.counter += W.kill * 0.6; // 自杀式攻击重罚
            }
        } else {
            p.focus = 0;
        }

        // ---- 位置类
        const exposure = ctx.threat[cand.dest.y * bf.width + cand.dest.x] / ctx.maxThreat;
        p.exposure = W.exposure * Math.min(1, exposure);
        p.terrain = W.terrain * (bf.terrainDefBonus(cand.dest.x, cand.dest.y) / S.terrainDefRef);

        // 待命候选不惩罚站位本身，但"有目标可打却待命"要扣分
        p.waste = cand.kind === 'wait' ? W.waste : 0;

        // 机动力保留：花光预算的走位在未来回合更脆弱
        p.mobility = cand.moveCost > 0
            ? W.mobility * (1 - (unit.remainingMove - cand.moveCost) / S.moveBudgetRef)
            : 0;

        // ---- 协同类
        p.surround = this._surroundScore(cand, unit, ctx, target);
        p.objective = this._objectiveScore(cand, unit, ctx);
        p.support = this._supportScore(cand, unit, ctx);

        let total = 0;
        for (const k in p) total += p[k];

        // 射程经济性：远程单位贴脸是亏的（打不出反击优势且吃反击）
        if (unit.attackRange > 1 && target && cand.dest &&
            Unit.distance(cand.dest.x, cand.dest.y, target.x, target.y) === 1) {
            total += W.exposure * 0.25;
        }

        cand.parts = p;
        cand.score = total;
        return cand;
    }

    /** 包围/集火协同：站过去后，目标周围我方数量 */
    _surroundScore(cand, unit, ctx, target) {
        const bf = ctx.bf;
        const W = WarConfig.weights;
        if (!target) return 0;
        if (unit.attackRange > 1) return 0;

        let already = 0;
        for (const ally of ctx.alliesExcluding(unit)) {
            if (Unit.distance(ally.x, ally.y, target.x, target.y) === 1) already++;
        }
        const willAdd = Unit.distance(cand.dest.x, cand.dest.y, target.x, target.y) === 1 ? 1 : 0;
        const after = already + willAdd;
        return W.support * 0.6 * Math.min(1, after / 3) * (willAdd ? 1 : 0.3);
    }

    /** 战略牵引：向本轮 objective 点靠近即加分（进攻/包抄是敌方重心，防守是己方重心，撤退是己方边路） */
    _objectiveScore(cand, unit, ctx) {
        const W = WarConfig.weights;
        const S = WarConfig.scale;
        if (!ctx.order || !ctx.order.objective) return 0;

        const obj = ctx.order.objective;
        const before = Unit.distance(unit.x, unit.y, obj.x, obj.y);
        const after = Unit.distance(cand.dest.x, cand.dest.y, obj.x, obj.y);
        const gain = Math.max(-1, Math.min(1, (before - after) / Math.max(1, S.objectiveDecay)));
        return W.objective * gain;
    }

    /** 友军支援：别单骑突到没人接应的地方 */
    _supportScore(cand, unit, ctx) {
        const W = WarConfig.weights;
        const S = WarConfig.scale;
        const allies = ctx.alliesExcluding(unit);
        if (allies.length === 0) return 0;

        let nearest = Infinity;
        for (const a of allies) {
            const d = Unit.distance(a.x, a.y, cand.dest.x, cand.dest.y);
            if (d < nearest) nearest = d;
        }
        const closeness = 1 - Math.min(1, nearest / S.supportRadius);
        return W.support * closeness;
    }
}

/**
 * 浅层推演。完整 MCTS / α-β 在战棋里不划算（分支因子大、结算含随机、有隐藏信息），
 * 只对 top-K 候选做 1~2 ply 的"对手用简单规则回一手"，性价比最高。
 */
class Lookahead {
    constructor(bf) {
        this.bf = bf;
    }

    /**
     * @param {Unit} unit
     * @param {Candidate} cand
     * @param {AiContext} ctx
     * @param {number} depth 剩余 ply
     * @returns {number} 局面增减（camp 视角）
     */
    evaluate(unit, cand, ctx, depth) {
        const snap = this.bf.snapshot();
        const baseline = this._stateValue(ctx.camp);
        try {
            if (!this._apply(unit, cand, ctx)) return 0;
            let value = this._stateValue(ctx.camp);

            for (let d = 0; d < depth; d++) {
                // 偶数层：对手回一手；奇数层：我方继续推进
                const campToMove = d % 2 === 0 ? ctx.enemyCamp : ctx.camp;
                this._greedyTurn(campToMove);
                value = this._stateValue(ctx.camp);
            }
            return value - baseline;
        } finally {
            this.bf.restore(snap);
        }
    }

    /** 快棋手：每个单位只挑"净伤害最大"的一个动作。用于 rollout 内部，不参与真实决策 */
    _greedyTurn(camp) {
        const bf = this.bf;
        const enemies = bf.unitsOfCamp(bf.enemyCamp(camp));
        if (enemies.length === 0) return;

        for (const u of bf.unitsOfCamp(camp)) {
            if (u.remainingAttacks <= 0) continue;
            let best = null, bestVal = -Infinity;
            const spots = [{ x: u.x, y: u.y, path: [{ x: u.x, y: u.y }], cost: 0 }, ...bf.reachableWithBudget(u, u.moveBudget).values()];

            for (const spot of spots) {
                for (const t of enemies) {
                    if (!bf.canTargetFrom(u, t, spot.x, spot.y)) continue;
                    const dmg = u.damageTo(t, bf.terrainDefBonus(t.x, t.y));
                    const val = dmg + (dmg >= t.health ? 40 : 0) - (t.counterAttack && Unit.distance(spot.x, spot.y, t.x, t.y) <= t.attackRange ? t.damageTo(u, bf.terrainDefBonus(spot.x, spot.y)) : 0);
                    if (val > bestVal) { bestVal = val; best = { t, spot }; }
                }
            }
            if (best) {
                if (best.spot.path.length > 1) bf.moveAlongPath(u, best.spot.path);
                bf.attack(u, best.t);
            }
        }
    }

    _apply(unit, cand, ctx) {
        if (cand.path && cand.path.length > 1) {
            const r = this.bf.moveAlongPath(unit, cand.path);
            if (!r.ok) return false;
        }
        if (cand.targetId !== null) {
            const target = this.bf.units.find(u => u.id === cand.targetId);
            if (!target || target.isDead) return false;
            this.bf.attack(unit, target);
        }
        return true;
    }

    _stateValue(camp) {
        const bf = this.bf;
        let v = bf.materialScore(camp);
        // 位置项：谁能站住高防御格，长期交换比更好
        for (const u of bf.unitsOfCamp(camp)) v += bf.terrainDefBonus(u.x, u.y) / 40;
        return v;
    }
}

/** 编排层 */
class WarAI {
    constructor(battlefield, camp, opts = {}) {
        this.battlefield = battlefield;
        this.camp = camp;
        this.difficulty = opts.difficulty || 'normal';
        this.seed = opts.seed ?? 12345;
        this.rng = new SeededRng(this.seed);
        this.strategist = new Strategist();
        this.enumerator = new Enumerator();
        this.scorer = new Scorer();
        this.lookahead = new Lookahead(battlefield);
        this.lastPlan = null;
        this.debug = opts.debug !== false;
    }

    get cfg() {
        return WarConfig.difficulty[this.difficulty] || WarConfig.difficulty.normal;
    }

    setDifficulty(d) {
        this.difficulty = d;
        return this;
    }

    setSeed(seed) {
        this.seed = seed;
        this.rng = new SeededRng(seed);
        return this;
    }

    /**
     * 执行本阵营整个回合。真实推进战场状态，并返回可重放的事件序列，
     * 渲染层可 restore 到回合前再逐事件播放动画。
     */
    executeTurn() {
        const bf = this.battlefield;
        const ctx = new AiContext(this, this.camp);
        ctx.order = this.strategist.assess(ctx, bf);
        ctx.orderScore = ctx.order.score;

        const snapshot = bf.snapshot();
        const events = [];
        const order = [...bf.unitsOfCamp(this.camp)];   // 生成顺序 = 行动顺序

        for (const unit of order) {
            if (unit.isDead) continue;
            if (unit.remainingAttacks <= 0 && unit.remainingMove <= 0) continue;

            const cand = this.decide(unit, ctx);
            if (!cand) continue;

            const before = { x: unit.x, y: unit.y };
            const applied = this._applyCandidate(unit, cand, ctx);
            if (!applied.ok) continue;

            if (cand.targetId !== null) {
                const target = bf.units.find(u => u.id === cand.targetId);
                events.push({
                    type: 'attack', unitId: unit.id, camp: this.camp,
                    from: before, to: { x: unit.x, y: unit.y },
                    path: cand.path, targetId: cand.targetId,
                    atkName: unit.name, defName: target ? target.name : '?',
                    damage: applied.damage, killed: applied.killed,
                    spent: applied.spent,
                    counterDamage: applied.counterDamage, counterKilled: applied.counterKilled,
                    score: Math.round(cand.score), desc: cand.describe()
                });
                ctx.locked.set(cand.targetId, (ctx.locked.get(cand.targetId) || 0) + 1);
            } else if (cand.kind === 'move') {
                events.push({
                    type: 'move', unitId: unit.id, camp: this.camp,
                    from: before, to: { x: unit.x, y: unit.y },
                    path: cand.path, spent: applied.spent,
                    score: Math.round(cand.score), desc: cand.describe()
                });
            } else {
                events.push({
                    type: 'wait', unitId: unit.id, camp: this.camp,
                    to: { x: unit.x, y: unit.y }, score: Math.round(cand.score), desc: '待命'
                });
            }
        }

        const plan = {
            camp: this.camp,
            difficulty: this.difficulty,
            order: { ...ctx.order },
            snapshot,
            events,
            decisions: ctx.log
        };
        this.lastPlan = plan;
        return plan;
    }

    /** 单单位决策：枚举 → 评分 → （可选）前瞻 → softmax 采样 */
    decide(unit, ctx) {
        const t0 = Date.now();
        const cands = this.enumerator.enumerate(unit, ctx);
        if (cands.length === 0) return null;

        for (const c of cands) this.scorer.score(c, unit, ctx);

        // 前瞻只加在 top-K 上，避免整片候选都做 rollout
        const cfg = ctx.cfg;
        const ranked = [...cands].sort((a, b) => b.score - a.score);
        if (cfg.lookahead > 0 && !ctx.shallow) {
            ctx.shallow = true;                 // rollout 内部不再前瞻，防指数爆炸
            const k = Math.min(4, ranked.length);
            for (let i = 0; i < k; i++) {
                const c = ranked[i];
                const delta = this.lookahead.evaluate(unit, c, ctx, cfg.lookahead);
                c.parts.followup = delta * WarConfig.weights.followup;
                c.score += c.parts.followup;
            }
            ctx.shallow = false;
            ranked.sort((a, b) => b.score - a.score);
        }

        const chosen = this._sample(ranked, cfg.temperature);

        if (this.debug) {
            ctx.log.push({
                turn: ctx.bf.version,
                unitId: unit.id,
                unit: `${unit.name}#${unit.id}@(${unit.x},${unit.y})`,
                budget: `${unit.remainingMove}/${unit.moveBudget} 机动, ${unit.remainingAttacks} 攻击`,
                candidates: cands.length,
                ms: Date.now() - t0,
                top: ranked.slice(0, 5).map(c => ({
                    desc: c.describe(),
                    score: Math.round(c.score * 10) / 10,
                    parts: this._roundParts(c.parts)
                })),
                chosen: chosen.desc = chosen.describe(),
                chosenScore: Math.round(chosen.score * 10) / 10
            });
        }
        return chosen;
    }

    _roundParts(parts) {
        const out = {};
        for (const k in parts) out[k] = Math.round(parts[k] * 10) / 10;
        return out;
    }

    /**
     * softmax 采样。温度是唯一"犯蠢"旋钮：T→0 退化为 argmax，T 越大越随机。
     * 分数先减去最大值再做指数，避免溢出。
     */
    _sample(ranked, temperature) {
        if (ranked.length === 0) return null;
        if (!temperature || temperature <= 1e-6) return ranked[0];

        const scale = 1 / Math.max(1, Math.abs(ranked[0].score));
        const maxScore = ranked[0].score;
        let sum = 0;
        const weights = ranked.map(c => {
            const w = Math.exp((c.score - maxScore) * scale / temperature);
            sum += w;
            return w;
        });

        let r = this.rng.next() * sum;
        for (let i = 0; i < ranked.length; i++) {
            r -= weights[i];
            if (r <= 0) return ranked[i];
        }
        return ranked[ranked.length - 1];
    }

    _applyCandidate(unit, cand, ctx) {
        const bf = this.battlefield;
        const res = { ok: false, damage: 0, killed: false, counterDamage: 0, counterKilled: false, spent: 0 };

        if (cand.path && cand.path.length > 1) {
            const mv = bf.moveAlongPath(unit, cand.path);
            if (!mv.ok) {
                res.reason = mv.reason;
                return res;
            }
            res.spent = mv.spent;
        }
        if (cand.targetId !== null) {
            const target = bf.units.find(u => u.id === cand.targetId);
            if (!target || target.isDead) { res.reason = 'target_gone'; return res; }
            const atk = bf.attack(unit, target);
            if (atk.rejected) { res.reason = atk.rejected; return res; }
            res.damage = atk.damage;
            res.killed = atk.killed;
            res.counterDamage = atk.counterDamage;
            res.counterKilled = atk.counterKilled;
        }
        res.ok = true;
        return res;
    }

    getInfo() {
        return {
            camp: this.camp,
            difficulty: this.difficulty,
            cfg: this.cfg,
            seed: this.seed,
            unitCount: this.battlefield.unitsOfCamp(this.camp).length
        };
    }
}

/**
 * 重放一段 AI 回合：渲染层先用 plan.snapshot 回滚，再按事件顺序调用本函数恢复状态。
 * 事件里没有坐标以外的随机性，重放结果与 AI 内部执行完全一致。
 */
function replayEvent(bf, ev) {
    const unit = bf.units.find(u => u.id === ev.unitId);
    if (!unit || unit.isDead) return null;
    if (ev.path && ev.path.length > 1) bf.moveAlongPath(unit, ev.path);
    if (ev.type === 'attack') {
        const target = bf.units.find(u => u.id === ev.targetId);
        if (target && !target.isDead) return bf.attack(unit, target);
    }
    return null;
}

if (typeof module !== 'undefined' && module.exports) {
    module.exports = { WarAI, Strategist, Enumerator, Scorer, Lookahead, AiContext, Candidate, replayEvent };
}

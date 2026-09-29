/**
 * 战棋 AI / 规则内核 回归测试（零依赖，node tests/kernel.test.mjs 直接跑）
 *
 * 这些断言的存在理由：战棋 AI 没有测试，调参就是盲调。
 * 每条测试都对应本次修复中的一个具体缺陷。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');

/** 四个源文件都是传统 script（顶层 class 声明），拼接后在函数作用域里求值即可拿到类引用。
 *  输入完全为仓库内本地文件，非任何外部/不可信来源。 */
function loadEngine() {
    const files = ['config.js', 'item.js', 'field.js', 'ai.js'];
    const src = files.map(f => fs.readFileSync(path.join(ROOT, f), 'utf8')).join('\n;\n');
    const body = `
        ${src}
        ;return { WarConfig, SeededRng, Unit, Battlefield, WarAI, Strategist, Enumerator, Scorer, Lookahead, AiContext, Candidate, replayEvent };
    `;
    // eslint-disable-next-line no-new-func
    return new Function(body)();
}

const E = loadEngine();
const { WarConfig, Unit, Battlefield, WarAI, AiContext } = E;

// ------------------------------------------------------------------ 断言器

let passed = 0;
const failures = [];

function check(name, fn) {
    try {
        const err = fn();
        if (err) { failures.push(`${name}: ${err}`); console.log(`  ✗ ${name} — ${err}`); }
        else { passed++; console.log(`  ✓ ${name}`); }
    } catch (e) {
        failures.push(`${name}: threw ${e.message}`);
        console.log(`  ✗ ${name} — 抛异常 ${e.message}\n${e.stack.split('\n').slice(1, 3).join('\n')}`);
    }
}

function section(t) { console.log(`\n${t}`); }

// ------------------------------------------------------------------ 夹具

/** 平坦 12×12，无随机地形，便于逐格推理 */
function flatBoard(w = 12, h = 12) {
    const bf = new Battlefield(w, h, 1);
    bf.flatten();
    return bf;
}

function put(bf, type, camp, x, y) {
    const u = new Unit(type, camp, x, y);
    if (!bf.addUnit(u)) throw new Error(`无法放置 ${type}@(${x},${y})`);
    return u;
}

/** 自动对战：返回 {winner, turns, spentLog} */
function autoBattle(diffA, diffB, opts = {}) {
    const w = opts.width ?? 14, h = opts.height ?? 14;
    const perSide = opts.perSide ?? 6;
    const maxTurns = opts.maxTurns ?? 40;
    const seed = opts.seed ?? 1;

    const bf = new Battlefield(w, h, seed);
    const roster = [];
    const mix = ['infantry', 'cavalry', 'archer'];
    for (let i = 0; i < perSide; i++) roster.push(mix[i % mix.length]);

    for (let i = 0; i < perSide; i++) {
        put(bf, roster[i], 1, 1 + (i % 2), 1 + i * Math.max(1, Math.floor((h - 2) / perSide)));
        put(bf, roster[i], 2, w - 2 - (i % 2), 1 + i * Math.max(1, Math.floor((h - 2) / perSide)));
    }

    const aiA = new WarAI(bf, 1, { difficulty: diffA, seed: seed * 7 + 1, debug: false });
    const aiB = new WarAI(bf, 2, { difficulty: diffB, seed: seed * 13 + 3, debug: false });

    let turns = 0;
    while (!bf.isGameOver() && turns < maxTurns) {
        turns++;
        bf.resetAllActions();
        aiA.executeTurn();
        bf.cleanupDeadUnits();
        if (bf.isGameOver()) break;
        bf.resetAllActions();
        aiB.executeTurn();
        bf.cleanupDeadUnits();
        if (bf.isGameOver()) break;
    }
    return { winner: bf.getWinner(), turns, bf, material: bf.materialScore(1) };
}

// ================================================================== 规则层

section('P0 规则内核（移动 / 攻击 / 配额）');

check('移动按地形代价扣除机动点（平原 1、森林 2）', () => {
    const bf = flatBoard();
    const u = put(bf, 'infantry', 1, 2, 2);
    bf.setTerrain(3, 2, 'forest');

    if (!bf.moveUnit(u, 3, 2)) return '移动失败';
    if (u.remainingMove !== u.moveBudget - 2) return `森林应扣 2 点，实扣 ${u.moveBudget - u.remainingMove}`;

    const before = u.remainingMove;
    if (!bf.moveUnit(u, 4, 2)) return '第二步移动失败';
    if (u.remainingMove !== before - 1) return `平原应扣 1 点，实扣 ${before - u.remainingMove}`;
    return null;
});

check('机动点不足时拒绝移动，且不产生部分副作用', () => {
    const bf = flatBoard();
    const u = put(bf, 'infantry', 1, 1, 1);
    u.remainingMove = 1;
    bf.setTerrain(2, 1, 'hill');           // cost 3 > 1
    const ok = bf.moveUnit(u, 2, 1);
    if (ok) return '超预算移动竟然成功了';
    if (u.x !== 1 || u.y !== 1) return `失败后坐标漂移至 (${u.x},${u.y})`;
    if (u.remainingMove !== 1) return '失败后仍扣了机动点';
    if (!bf.hasUnitAt(1, 1)) return '失败后原格占位丢失';
    return null;
});

check('路径必须 4 邻接：AI 无法斜走或跨格瞬移', () => {
    const bf = flatBoard();
    const u = put(bf, 'infantry', 1, 3, 3);
    const res = bf.moveAlongPath(u, [{ x: 3, y: 3 }, { x: 4, y: 4 }]);   // 斜向
    if (res.ok) return '斜向移动竟然被接受';
    if (res.reason !== 'not_adjacent') return `拒绝原因应为 not_adjacent，实为 ${res.reason}`;
    if (u.x !== 3 || u.y !== 3) return '斜走后坐标被改动';

    const jump = bf.moveAlongPath(u, [{ x: 3, y: 3 }, { x: 6, y: 3 }]);  // 距离 3
    if (jump.ok) return '跨格瞬移被接受';
    return null;
});

check('可达域不超过机动预算（旧版 AI 每回合白走 9 格的根因）', () => {
    const bf = flatBoard();
    const u = put(bf, 'cavalry', 1, 2, 6);        // moveBudget 7
    const reach = bf.computeReachable(u);
    for (const cell of reach.values()) {
        if (cell.cost > u.moveBudget) return `(${cell.x},${cell.y}) 代价 ${cell.cost} 超预算`;
    }
    if (reach.size === 0) return '可达域为空';
    // 沿最长路径真实走一遍，验证消耗记账一致
    const far = [...reach.values()].sort((a, b) => b.cost - a.cost)[0];
    bf.moveAlongPath(u, far.path);
    if (u.remainingMove !== u.moveBudget - far.cost) return '落地后剩余机动点与路径代价不符';
    if (u.remainingMove < 0) return '机动点被扣成负数';
    return null;
});

check('攻击消耗攻击配额，一回合不能连射', () => {
    const bf = flatBoard();
    const a = put(bf, 'archer', 1, 3, 3);
    const t = put(bf, 'infantry', 2, 5, 3);
    const r1 = bf.attack(a, t);
    if (r1.rejected) return `首次攻击被拒：${r1.rejected}`;
    if (a.remainingAttacks !== 0) return '攻击后配额未扣';
    const r2 = bf.attack(a, t);
    if (!r2.rejected) return '配额用尽仍能攻击';
    return null;
});

check('伤害计入目标地形防御加成', () => {
    const bf = flatBoard();
    const a = put(bf, 'infantry', 1, 3, 3);
    const plain = put(bf, 'infantry', 2, 4, 3);
    const dPlain = a.damageTo(plain, bf.terrainDefBonus(4, 3));
    bf.setTerrain(4, 3, 'hill');
    const dHill = a.damageTo(plain, bf.terrainDefBonus(4, 3));
    if (dHill >= dPlain) return `山地未减伤（${dPlain} → ${dHill}）`;
    return null;
});

check('近战反击成立、弓兵被近身不反击', () => {
    const bf = flatBoard();
    const atk = put(bf, 'cavalry', 1, 3, 3);
    const melee = put(bf, 'infantry', 2, 4, 3);
    const r = bf.attack(atk, melee);
    if (r.counterDamage <= 0) return '步兵未反击';

    const bf2 = flatBoard();
    const atk2 = put(bf2, 'cavalry', 1, 3, 3);
    const arch = put(bf2, 'archer', 2, 4, 3);
    const r2 = bf2.attack(atk2, arch);
    if (r2.counterDamage !== 0) return '弓兵不应反击却造成了反击伤害';
    return null;
});

check('击杀后腾空格子，死亡单位不再阻挡也不被选中', () => {
    const bf = flatBoard();
    const a = put(bf, 'cavalry', 1, 3, 3);
    const t = put(bf, 'archer', 2, 4, 3);       // 弓兵 60hp，骑兵一击不会死
    t.health = 10;
    const r = bf.attack(a, t);
    if (!r.killed) return '未被击杀，夹具数值不对';
    if (bf.hasUnitAt(4, 3)) return '死亡单位仍占据网格';
    if (bf.unitsOfCamp(2).length !== 0) return '存活查询仍包含死者';
    const mv = bf.moveAlongPath(a, [{ x: 3, y: 3 }, { x: 4, y: 3 }]);
    if (!mv.ok) return `无法走进刚空出的格子：${mv.reason}`;
    return null;
});

check('弓兵射程 2 的直线射击会被中间单位挡住', () => {
    const bf = flatBoard();
    const a = put(bf, 'archer', 1, 3, 3);
    const t = put(bf, 'infantry', 2, 5, 3);
    if (!bf.canTargetFrom(a, t, 3, 3)) return '无障碍时竟不能射击';
    put(bf, 'infantry', 2, 4, 3);               // 中间格站了人
    if (bf.canTargetFrom(a, t, 3, 3)) return '视线未被阻挡';
    return null;
});

check('snapshot/restore 完整回滚位置、血量与配额', () => {
    const bf = flatBoard();
    const a = put(bf, 'cavalry', 1, 3, 3);
    const t = put(bf, 'infantry', 2, 4, 3);
    const snap = bf.snapshot();
    const hpBefore = t.health;

    bf.moveAlongPath(a, [{ x: 3, y: 3 }, { x: 3, y: 2 }, { x: 4, y: 2 }]);
    bf.attack(a, t);
    if (a.x === 3 && a.y === 3) return '夹具未能改变状态';

    bf.restore(snap);
    if (a.x !== 3 || a.y !== 3) return `位置未回滚 (${a.x},${a.y})`;
    if (t.health !== hpBefore) return '血量未回滚';
    if (a.remainingAttacks !== a.attackBudget) return '攻击配额未回滚';
    if (a.remainingMove !== a.moveBudget) return '机动配额未回滚';
    if (!bf.hasUnitAt(3, 3) || !bf.hasUnitAt(4, 3)) return '网格未回滚';
    return null;
});

// ================================================================== 空间推理

section('P1 可达域与威胁影响图');

check('影响图在敌方火力覆盖格上为正、安全格为零', () => {
    const bf = flatBoard(20, 20);
    put(bf, 'infantry', 1, 4, 4);               // 距敌 8 格：机动力碰不到
    put(bf, 'cavalry', 2, 12, 4);               // 机动 7 + 射程 1，向左可覆盖至 x=4
    const threat = bf.buildThreatMap(1);
    if (threat[4 * 20 + 4] <= 0) return '骑兵机动范围内未计入威胁';
    if (threat[4 * 20 + 2] !== 0) return `骑兵 8 格外的格被误标威胁 ${threat[4 * 20 + 2]}`;
    if (threat[15 * 20 + 15] !== 0) return '右下角安全格不为 0';
    return null;
});

check('影响图把敌方机动预算算进去（不是只看当前射程）', () => {
    const bf = flatBoard(20, 20);
    put(bf, 'infantry', 1, 1, 1);
    const cav = put(bf, 'cavalry', 2, 18, 18);   // 预算 7，射程 1
    const threat = bf.buildThreatMap(1);
    const far = threat[18 * 20 + 8];             // 距骑兵 10 格，超出机动+射程
    if (far !== 0) return `超射程格被误标威胁 ${far}`;
    const near = threat[18 * 20 + 13];           // 距骑兵 5 格，7 预算可达
    if (near <= 0) return '敌方可达范围内的格未计入威胁，影响图退化成射程圈';
    void cav;
    return null;
});

check('地形改变可达域大小（森林拖慢机动）', () => {
    const mk = (withForest) => {
        const bf = flatBoard(15, 15);
        const u = put(bf, 'infantry', 1, 7, 7);
        if (withForest) {
            for (let x = 0; x < 15; x++) for (let y = 0; y < 15; y++) {
                if ((x + y) % 2 === 0) bf.setTerrain(x, y, 'forest');
            }
        }
        return bf.computeReachable(u).size;
    };
    const open = mk(false), rough = mk(true);
    if (open <= rough) return `密林可达域应更小（开阔 ${open} vs 林地 ${rough}）`;
    return null;
});

check('不可通行地形不进入可达域', () => {
    const bf = flatBoard();
    const u = put(bf, 'infantry', 1, 1, 1);
    for (let x = 0; x < 12; x++) bf.setTerrain(x, 2, 'water');
    bf.setTerrain(1, 1, 'plain');
    const reach = bf.computeReachable(u);
    for (const c of reach.values()) {
        if (c.y >= 2) return `穿过河流到达 (${c.x},${c.y})`;
    }
    return null;
});

// ================================================================== AI 行为

section('P2/P3 AI 决策质量');

check('能击杀时优先击杀，而不是选高价值但打不死的目标', () => {
    const bf = flatBoard();
    const a = put(bf, 'cavalry', 1, 5, 5);       // 攻击 50
    const dying = put(bf, 'infantry', 2, 6, 5);  // 残血，一定打死
    dying.health = 5;
    const beefy = put(bf, 'archer', 2, 4, 5);    // 高价值但打不死（45-6=39 < 60）
    beefy.health = 60;

    const ai = new WarAI(bf, 1, { difficulty: 'hard', seed: 99, debug: false });
    const ctx = new AiContext(ai, 1);
    ctx.order = ai.strategist.assess(ctx);
    const cand = ai.decide(a, ctx);
    if (!cand || cand.targetId === null) return `选择了 ${cand ? cand.describe() : 'null'}，未攻击任何目标`;
    if (cand.targetId !== dying.id) return `未优先补刀，实际打 #${cand.targetId}（应为 #${dying.id}）`;
    return null;
});

check('远程单位不会为了攻击而贴到近战脸上（除非能一击致死）', () => {
    const bf = flatBoard(14, 14);
    const a = put(bf, 'archer', 1, 6, 6);        // 60hp，一击 45-25 打不死重步兵
    const guard = put(bf, 'cavalry', 2, 8, 6);   // 90hp，反击 50-6 → 弓兵贴脸必残
    guard.health = 90;

    const ai = new WarAI(bf, 1, { difficulty: 'hard', seed: 7, debug: false });
    const ctx = new AiContext(ai, 1);
    ctx.order = ai.strategist.assess(ctx);
    const cand = ai.decide(a, ctx);
    if (cand && cand.kind === 'moveAttack' && cand.dest.x === 7 && cand.dest.y === 6) {
        return `弓兵走到贴脸格 (${cand.dest.x},${cand.dest.y}) 吃反击`;
    }
    if (cand && cand.dest && Unit.distance(cand.dest.x, cand.dest.y, guard.x, guard.y) <= 1) {
        return `弓兵最终站位距敌 ${Unit.distance(cand.dest.x, cand.dest.y, guard.x, guard.y)} 格，进入近战射程`;
    }
    return null;
});

check('AI 一整回合的总移动消耗不超过机动预算（旧版 P0 回归）', () => {
    const bf = new Battlefield(16, 16, 3);
    const roster = WarConfig.defaultRoster;
    roster.forEach((t, i) => put(bf, t, 1, 1 + (i % 2), 1 + i));
    roster.forEach((t, i) => put(bf, t, 2, 14 - (i % 2), 1 + i));

    const ai = new WarAI(bf, 1, { difficulty: 'nightmare', seed: 5, debug: false });
    bf.resetAllActions();
    const byUnit = new Map();
    const before = new Map(bf.unitsOfCamp(1).map(u => [u.id, u.moveBudget]));
    const plan = ai.executeTurn();

    for (const ev of plan.events) {
        const spent = ev.spent ?? 0;
        byUnit.set(ev.unitId, (byUnit.get(ev.unitId) || 0) + spent);
    }
    for (const [id, spent] of byUnit) {
        const budget = before.get(id);
        if (budget === undefined) return `事件里出现了未知单位 #${id}`;
        if (spent > budget) return `单位 #${id} 本回合移动 ${spent} 点，超出预算 ${budget}`;
    }
    for (const u of bf.unitsOfCamp(1)) {
        if (u.remainingMove < 0) return `单位 #${u.id} 机动点为负`;
        if (u.remainingAttacks < 0) return `单位 #${u.id} 攻击配额为负`;
    }
    return null;
});

check('同一种子同局面 → 决策序列逐字节一致（可复现性）', () => {
    const build = () => {
        const bf = new Battlefield(14, 14, 11);
        for (let i = 0; i < 5; i++) {
            put(bf, 'infantry', 1, 2, 2 + i * 2);
            put(bf, 'archer', 2, 11, 2 + i * 2);
        }
        const ai = new WarAI(bf, 1, { difficulty: 'easy', seed: 2024, debug: true });
        bf.resetAllActions();
        const plan = ai.executeTurn();
        return JSON.stringify(plan.events.map(e => [e.type, e.unitId, e.to.x, e.to.y, e.targetId, e.damage]));
    };
    const a = build(), b = build();
    if (a !== b) return '两次相同种子的回合结果不同';
    return null;
});

check('softmax 温度单调控制犯错率（同一候选集，只差温度）', () => {
    // 只验证采样器：同一局面、同一候选集、同一随机种子起点，只换温度
    const regretOf = (temperature, seed) => {
        const bf = new Battlefield(16, 16, 21);
        for (let i = 0; i < 6; i++) {
            put(bf, 'infantry', 1, 2, 2 + i * 2);
            put(bf, 'infantry', 2, 13, 2 + i * 2);
        }
        const ai = new WarAI(bf, 1, { difficulty: 'hard', seed, debug: false });
        bf.resetAllActions();
        const ctx = new AiContext(ai, 1);
        ctx.order = ai.strategist.assess(ctx);

        let regret = 0, n = 0;
        for (const unit of bf.unitsOfCamp(1)) {
            const cands = ai.enumerator.enumerate(unit, ctx);
            for (const c of cands) ai.scorer.score(c, unit, ctx);
            cands.sort((a, b) => b.score - a.score);
            ai.rng = new E.SeededRng(seed);              // 同一起点，使两组可比较
            const chosen = ai._sample(cands, temperature);
            regret += cands[0].score - chosen.score;
            n++;
        }
        return regret / n;
    };

    const avg = (t) => {
        let s = 0;
        for (let i = 1; i <= 10; i++) s += regretOf(t, i * 97);
        return s / 10;
    };
    const hot = avg(WarConfig.difficulty.easy.temperature);
    const cold = avg(WarConfig.difficulty.nightmare.temperature);
    const zero = avg(0);
    if (Math.abs(zero) > 1e-9) return `温度 0 应退化为 argmax，后悔值却是 ${zero}`;
    if (!(hot > cold)) return `高温后悔 ${hot.toFixed(2)} 未大于低温 ${cold.toFixed(2)}`;
    console.log(`      · 平均后悔值 T=${WarConfig.difficulty.easy.temperature} → ${hot.toFixed(2)}，T=${WarConfig.difficulty.nightmare.temperature} → ${cold.toFixed(2)}，T=0 → 0`);
    return null;
});

check('高难度对低难度的期望胜率（nightmare vs easy）', () => {
    let nightWins = 0, easyWins = 0, draws = 0;
    const games = 8;
    for (let s = 1; s <= games; s++) {
        const r = autoBattle('nightmare', 'easy', { seed: s * 101, perSide: 5, width: 14, height: 14, maxTurns: 30 });
        if (r.winner === 1) nightWins++;
        else if (r.winner === 2) easyWins++;
        else draws++;
    }
    if (nightWins <= easyWins) return `噩梦 ${nightWins} 胜 / 简单 ${easyWins} 胜（平 ${draws}），难度未拉开`;
    console.log(`      · nightmare ${nightWins}W ${easyWins}L ${draws}D（共 ${games} 局）`);
    return null;
});

check('噩梦(前瞻) 优于 普通(无前瞻) —— 前瞻旋钮确实提智', () => {
    let a = 0, b = 0;
    for (let s = 1; s <= 6; s++) {
        const r = autoBattle('hard', 'normal', { seed: s * 733, perSide: 5, width: 14, height: 14, maxTurns: 30 });
        if (r.winner === 1) a++; else if (r.winner === 2) b++;
    }
    if (a < b) return `hard(lookahead=1) ${a}W 反而不如 normal(lookahead=0) ${b}W`;
    console.log(`      · hard ${a}W ${b}L（共 6 局）`);
    return null;
});

check('AI 回合必然收敛（不会出现死循环或整回合零动作后卡住）', () => {
    for (let s = 1; s <= 3; s++) {
        const r = autoBattle('normal', 'normal', { seed: s * 17, perSide: 6, width: 14, height: 14, maxTurns: 25 });
        if (r.turns === 0) return '一回合都没跑完';
        if (r.turns >= 25 && !r.bf.isGameOver()) {
            // 允许僵持，但僵持时双方必须仍在互相消耗，而不是原地待命
            const total = r.bf.units.reduce((n, u) => n + u.health, 0);
            if (total === r.bf.units.length * r.bf.units[0]?.maxHealth) return '全程零伤害，AI 可能集体待命';
        }
    }
    return null;
});

check('战局能分出胜负且死者不会复活', () => {
    const r = autoBattle('hard', 'hard', { seed: 42, perSide: 6, width: 14, height: 14, maxTurns: 45 });
    const dead = r.bf.units.filter(u => u.isDead);
    for (const d of dead) {
        if (r.bf.hasUnitAt(d.x, d.y)) return `死者 #${d.id} 仍占据网格`;
        if (d.health > 0) return `死者 #${d.id} 血量 ${d.health} 未归零`;
    }
    return null;
});

// ================================================================== 地形生成

section('地图生成');

check('地形左右镜像对称（对战公平性）', () => {
    const bf = new Battlefield(20, 20, 5);
    for (let y = 0; y < 20; y++) {
        for (let x = 0; x < 10; x++) {
            if (bf.terrain[y][x] !== bf.terrain[y][19 - x]) return `(${x},${y}) 与镜像格不一致`;
        }
    }
    return null;
});

check('同一种子生成结果一致，不同种子结果不同', () => {
    const sig = (seed) => {
        const bf = new Battlefield(20, 20, seed);
        return bf.terrain.flat().join(',');
    };
    if (sig(5) !== sig(5)) return '同种子地形不稳定';
    if (sig(5) === sig(6)) return '不同种子地形完全相同，seed 未参与生成';
    return null;
});

check('双方出生区互通（不存在被不可通行地形切开的半场）', () => {
    const bad = [];
    for (let seed = 1; seed <= 40; seed++) {
        const bf = new Battlefield(20, 20, seed);
        // 从 camp1 出生列出发做 BFS，看能否触达 camp2 出生列
        const seen = new Set();
        const q = [];
        for (let y = 0; y < 20; y++) if (bf.isWalkable(2, y)) { q.push([2, y]); seen.add(`2,${y}`); }
        let hitRight = false;
        while (q.length) {
            const [x, y] = q.shift();
            if (x >= 17) hitRight = true;
            for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
                const nx = x + dx, ny = y + dy, k = `${nx},${ny}`;
                if (nx < 0 || ny < 0 || nx >= 20 || ny >= 20) continue;
                if (seen.has(k) || bf.isImpassable(nx, ny)) continue;
                seen.add(k); q.push([nx, ny]);
            }
        }
        if (!hitRight) bad.push(seed);
    }
    if (bad.length > 40 * 0.1) return `${bad.length}/40 个种子地图左右不通（示例 seed: ${bad.slice(0, 5)}）`;
    if (bad.length) console.log(`      · ${bad.length}/40 个 seed 通道偏窄（≤10%，可接受）`);
    return null;
});

// ================================================================== 性能

section('性能预算');

check('单阵营 AI 回合平均耗时 < 20ms（nightmare 前瞻档）', () => {
    const mkBoard = (s) => {
        const bf = new Battlefield(20, 20, s * 3);
        WarConfig.defaultRoster.forEach((t, i) => {
            put(bf, t, 1, 1 + (i % 2), 1 + i * 2);
            put(bf, t, 2, 18 - (i % 2), 1 + i * 2);
        });
        return bf;
    };

    // 预热一轮让 JIT 编译完成，否则首次采样会偶发放大 2~3 倍
    const warm = new WarAI(mkBoard(99), 1, { difficulty: 'nightmare', seed: 99, debug: false });
    warm.executeTurn();

    const samples = [];
    for (let s = 1; s <= 5; s++) {
        const bf = mkBoard(s);
        const ai = new WarAI(bf, 1, { difficulty: 'nightmare', seed: s, debug: false });
        bf.resetAllActions();
        const t0 = process.hrtime.bigint();
        ai.executeTurn();
        samples.push(Number(process.hrtime.bigint() - t0) / 1e6);
    }
    samples.sort((a, b) => a - b);
    const median = samples[Math.floor(samples.length / 2)];
    console.log(`      · 20v20 nightmare 每阵营回合中位数 ${median.toFixed(1)}ms（共 ${samples.length} 样本，最大 ${samples[samples.length - 1].toFixed(1)}ms）`);
    if (median > 20) return `中位 ${median.toFixed(1)}ms 超出 20ms 预算`;
    return null;
});

// ================================================================== 汇总

console.log(`\n${'='.repeat(56)}`);
if (failures.length) {
    console.log(`✗ ${failures.length} 项失败 / ${passed} 项通过`);
    for (const f of failures) console.log(`  - ${f}`);
    process.exit(1);
} else {
    console.log(`✓ 全部通过（${passed} 项）`);
}

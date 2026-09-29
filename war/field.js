/**
 * 战场：地形 + 单位占位 + 规则结算 + 空间推理（可达域 / 威胁影响图）
 *
 * 本文件是所有状态变更的唯一入口（single writer）。规则：
 *   - 坐标与占位只能通过 moveAlongPath() 改变，并同步扣除机动点；
 *   - 血量与死亡只能通过 attack() 改变，并从占位网格精确移除；
 *   - AI 做前瞻时用 snapshot()/restore() 回滚，不复制战场对象。
 * 这样杜绝旧版"Unit.move 扣点数不更新 grid / Battlefield.moveUnit 更新 grid 不扣点数"
 * 的双写不一致。
 */
class Battlefield {
    constructor(width = WarConfig.board.width, height = WarConfig.board.height, seed = 1) {
        this.width = width;
        this.height = height;

        /** terrain[y][x] = 地形 key */
        this.terrain = [];
        /** unitGrid[y][x] = Unit | null。占位与地形彻底分离，地形永不被清空 */
        this.unitGrid = [];

        /** 行动顺序即数组顺序（README：按棋子生成顺序行动） */
        this.units = [];
        this.nextUnitId = 1;

        /** 缓存失效令牌：任何位置/存活变化都要 +1 */
        this.version = 0;
        this._threatCache = new Map();   // camp -> Float32Array
        this._reachCache = new Map();    // unitId -> reachable

        this.initializeGrids();
        this.generateTerrain(seed);
    }

    // ============================================================ 网格基础

    initializeGrids() {
        this.terrain = [];
        this.unitGrid = [];
        for (let y = 0; y < this.height; y++) {
            this.terrain.push(new Array(this.width).fill('plain'));
            this.unitGrid.push(new Array(this.width).fill(null));
        }
    }

    inBounds(x, y) {
        return x >= 0 && x < this.width && y >= 0 && y < this.height;
    }

    /** 兼容旧 API 名 */
    isValidPosition(x, y) {
        return this.inBounds(x, y);
    }

    terrainAt(x, y) {
        if (!this.inBounds(x, y)) return null;
        return WarConfig.terrain[this.terrain[y][x]];
    }

    terrainDefBonus(x, y) {
        const t = this.terrainAt(x, y);
        return t ? t.defBonus : 0;
    }

    isImpassable(x, y) {
        const t = this.terrainAt(x, y);
        return !t || t.impassable;
    }

    unitAt(x, y) {
        if (!this.inBounds(x, y)) return null;
        return this.unitGrid[y][x];
    }

    /** 兼容旧 API 名。死亡单位占位格已在击杀时清空，这里再加一层兵库保护 */
    getUnitAt(x, y) {
        const u = this.unitAt(x, y);
        return u && !u.isDead ? u : null;
    }

    hasUnitAt(x, y) {
        const u = this.unitAt(x, y);
        return !!u && !u.isDead;
    }

    isWalkable(x, y) {
        return this.inBounds(x, y) && !this.isImpassable(x, y) && !this.hasUnitAt(x, y);
    }

    setTerrain(x, y, key) {
        if (this.inBounds(x, y) && WarConfig.terrain[key]) {
            this.terrain[y][x] = key;
        }
    }

    // ============================================================ 地形生成

    /**
     * 确定性地形生成：以中轴为镜像随机撒布，保证左右两半完全对称。
     * 镜像对称是回合制对战地图的公平性底线，也方便把不平衡归因到 AI 而不是地图。
     */
    generateTerrain(seed = 1, opts = {}) {
        const rng = new SeededRng(seed);
        const density = opts.density ?? 0.16;
        const half = Math.ceil(this.width / 2);

        for (let y = 0; y < this.height; y++) {
            for (let x = 0; x < half; x++) {
                // 跳过 x <= 2 同时保住了两侧：镜像格 width-1-x 正好落在 x >= width-3 的右侧出生区
                if (x <= 2) continue;
                if (rng.next() > density) continue;

                const roll = rng.next();
                let key = 'forest';
                if (roll > 0.85) key = 'wall';
                else if (roll > 0.65) key = 'hill';
                else if (roll > 0.55) key = 'water';

                this.setTerrain(x, y, key);
                this.setTerrain(this.width - 1 - x, y, key); // 镜像
            }
        }

        this.version++;
        this.clearCaches();
        return this;
    }

    /** 平坦场地（回归测试与"纯规则验证"用） */
    flatten() {
        for (let y = 0; y < this.height; y++) {
            for (let x = 0; x < this.width; x++) this.terrain[y][x] = 'plain';
        }
        this.version++;
        this.clearCaches();
        return this;
    }

    // ============================================================ 单位管理

    addUnit(unit) {
        if (!this.inBounds(unit.x, unit.y)) return false;
        if (this.isImpassable(unit.x, unit.y)) return false;
        if (this.unitAt(unit.x, unit.y) !== null) return false;

        if (unit.id === null || unit.id === undefined) {
            unit.id = this.nextUnitId++;
        } else {
            this.nextUnitId = Math.max(this.nextUnitId, unit.id + 1);
        }

        this.units.push(unit);
        this.unitGrid[unit.y][unit.x] = unit;
        this.version++;
        this.clearCaches();
        return true;
    }

    /** 精确清除单格占位（取代旧版每次死亡就 initializeGrid() 全量重建） */
    removeUnit(unit) {
        const idx = this.units.indexOf(unit);
        if (idx === -1) return false;
        this.units.splice(idx, 1);
        if (this.unitAt(unit.x, unit.y) === unit) {
            this.unitGrid[unit.y][unit.x] = null;
        }
        this.version++;
        this.clearCaches();
        return true;
    }

    aliveUnits() {
        return this.units.filter(u => !u.isDead);
    }

    unitsOfCamp(camp) {
        return this.units.filter(u => !u.isDead && u.player === camp);
    }

    /** 兼容旧 API 名 */
    getPlayerUnits(camp) { return this.unitsOfCamp(camp); }
    getAllUnits() { return this.aliveUnits(); }
    getPlayerUnitCount(camp) { return this.unitsOfCamp(camp).length; }

    enemyCamp(camp) {
        return camp === 1 ? 2 : 1;
    }

    /** 死亡单位落地：从数组与占位网格中移除 */
    cleanupDeadUnits() {
        const dead = this.units.filter(u => u.isDead);
        if (dead.length === 0) return false;
        for (const u of dead) {
            if (this.unitAt(u.x, u.y) === u) this.unitGrid[u.y][u.x] = null;
        }
        this.units = this.units.filter(u => !u.isDead);
        this.version++;
        this.clearCaches();
        return true;
    }

    resetAllActions() {
        for (const u of this.units) u.resetTurn();
        this.clearCaches();
        return this;
    }

    /** 单位数组顺序 = 生成顺序 = 行动顺序 */
    indexOfUnit(unit) {
        return this.units.indexOf(unit);
    }

    // ============================================================ 空间推理

    clearCaches() {
        this._threatCache.clear();
        this._reachCache.clear();
    }

    /**
     * 可达域入口。以机动点为预算的 Dijkstra（不是 A* —— 我们要的是整片区域及代价，
     * 不是单条路径）。地形 moveCost 累加，任意单位阻挡（不可穿越）。
     *
     * @returns {Map<number, {x:number,y:number,cost:number,path:Array<{x:number,y:number}>}>}
     */
    computeReachable(unit) {
        if (!unit || unit.isDead) return new Map();
        return this.reachableWithBudget(unit, unit.remainingMove);
    }

    /**
     * 指定机动预算的可达域。威胁影响图用满预算（评估的是"下回合"的投射范围），
     * 因此必须能绕开"当前剩余点数"，也必须绕开缓存。
     */
    reachableWithBudget(unit, budget) {
        if (!unit || unit.isDead || budget <= 0) return new Map();

        const cached = this._reachCache.get(`${unit.id}:${budget}`);
        if (cached && cached.version === this.version) return cached.cells;
        const key = (x, y) => y * this.width + x;

        const best = new Map();
        const from = new Map();
        const start = { x: unit.x, y: unit.y };
        best.set(key(start.x, start.y), 0);
        // 桶式优先队列：预算 <= 7，比二叉堆更省事且无比较器开销
        const buckets = [];
        for (let i = 0; i <= budget; i++) buckets.push([]);
        buckets[0].push(start);

        const dirs = [[0, -1], [1, 0], [0, 1], [-1, 0]];
        const results = new Map();

        for (let cost = 0; cost <= budget; cost++) {
            const bucket = buckets[cost];
            for (let bi = 0; bi < bucket.length; bi++) {
                const cur = bucket[bi];
                if (best.get(key(cur.x, cur.y)) !== cost) continue;   // 已被更优解取代

                if (cur.x !== unit.x || cur.y !== unit.y) {
                    results.set(key(cur.x, cur.y), {
                        x: cur.x, y: cur.y, cost,
                        path: this._reconstructPath(from, cur, start)
                    });
                }

                for (const [dx, dy] of dirs) {
                    const nx = cur.x + dx, ny = cur.y + dy;
                    if (!this.inBounds(nx, ny)) continue;
                    if (this.isImpassable(nx, ny)) continue;
                    const occupant = this.getUnitAt(nx, ny);
                    if (occupant !== null) continue;                  // 任何存活单位阻挡

                    const stepCost = cost + this.terrainAt(nx, ny).moveCost;
                    if (stepCost > budget) continue;

                    const nk = key(nx, ny);
                    if (best.has(nk) && best.get(nk) <= stepCost) continue;
                    best.set(nk, stepCost);
                    from.set(nk, cur);
                    buckets[stepCost].push({ x: nx, y: ny });
                }
            }
        }

        this._reachCache.set(`${unit.id}:${budget}`, { version: this.version, cells: results });
        return results;
    }

    _reconstructPath(from, endNode, start) {
        const path = [{ x: endNode.x, y: endNode.y }];
        let cur = endNode;
        while (cur.x !== start.x || cur.y !== start.y) {
            cur = from.get(cur.y * this.width + cur.x);
            if (!cur) break;
            path.unshift({ x: cur.x, y: cur.y });
        }
        return path;
    }

    /** 兼容旧 API：只返回落点列表 */
    getMovablePositions(unit) {
        return [...this.computeReachable(unit).values()];
    }

    // ============================================================ 攻击判定

    /**
     * 视线：射程 2 且同行/同列时，中间格被单位占据则无法射击。
     * L 形（dx=1,dy=1）无唯一中间格，放行。
     */
    hasLineOfSight(ax, ay, bx, by) {
        const dx = bx - ax, dy = by - ay;
        const dist = Math.abs(dx) + Math.abs(dy);
        if (dist <= 1) return true;
        if (dx !== 0 && dy !== 0) return true;

        const mx = ax + Math.sign(dx), my = ay + Math.sign(dy);
        return this.unitAt(mx, my) === null;
    }

    /** 站在 (x,y) 能否打到 target */
    canTargetFrom(attacker, target, x, y) {
        if (!attacker || !target || target.isDead || attacker.player === target.player) return false;
        if (attacker.isDead) return false;
        const dist = Unit.distance(x, y, target.x, target.y);
        if (dist > attacker.attackRange || dist === 0) return false;
        return this.hasLineOfSight(x, y, target.x, target.y);
    }

    /** 兼容旧 API：当前站位可打的目标 */
    getAttackableTargets(unit) {
        const list = [];
        if (!unit || unit.isDead || unit.remainingAttacks <= 0) return list;
        for (const t of this.units) {
            if (this.canTargetFrom(unit, t, unit.x, unit.y)) list.push(t);
        }
        return list;
    }

    /**
     * 攻击结算（唯一的伤害写入点）。返回结果对象供渲染层播放动画与日志。
     */
    attack(attacker, target) {
        const result = {
            attackerId: attacker.id, targetId: target.id,
            damage: 0, killed: false,
            counterDamage: 0, counterKilled: false,
            from: { x: attacker.x, y: attacker.y }
        };

        if (!attacker.canAttackAgain() || target.isDead) {
            result.rejected = 'not_allowed';
            return result;
        }
        if (!this.canTargetFrom(attacker, target, attacker.x, attacker.y)) {
            result.rejected = 'out_of_range';
            return result;
        }

        // 主击
        const dmg = attacker.damageTo(target, this.terrainDefBonus(target.x, target.y));
        result.damage = target.takeDamage(dmg);
        result.killed = target.isDead;
        attacker.remainingAttacks--;
        if (result.killed) {
            // 立即腾空占位格，但仍留在 units 数组中：
            // 数组下标必须稳定，snapshot()/restore() 才能按下标回滚（AI 前瞻依赖这一点）
            this.unitGrid[target.y][target.x] = null;
        }

        // 反击：目标存活且有反击资格
        if (!result.killed && target.canCounter(attacker)) {
            target.hasCountered = true;
            const cdmg = target.damageTo(attacker, this.terrainDefBonus(attacker.x, attacker.y));
            result.counterDamage = attacker.takeDamage(cdmg);
            result.counterKilled = attacker.isDead;
            if (result.counterKilled) this.unitGrid[attacker.y][attacker.x] = null;
        }

        this.version++;
        this.clearCaches();
        return result;
    }

    // ============================================================ 移动结算

    /**
     * 沿路径移动（唯一的坐标写入点）。逐步校验 4 邻接、空格、地形消耗，
     * 因此 AI 无法像旧版那样斜穿或瞬移。
     */
    moveAlongPath(unit, path) {
        const result = { ok: false, spent: 0, steps: [], reason: null, origin: { x: unit ? unit.x : 0, y: unit ? unit.y : 0 } };
        if (!unit || unit.isDead) { result.reason = 'dead'; return result; }
        if (!path || path.length < 2) { result.ok = true; return result; }   // 原地

        let curX = unit.x, curY = unit.y;
        let spent = 0;

        for (let i = 1; i < path.length; i++) {
            const next = path[i];
            if (Unit.distance(curX, curY, next.x, next.y) !== 1) {
                result.reason = 'not_adjacent'; return this._rollbackMove(unit, result);
            }
            if (!this.inBounds(next.x, next.y) || this.isImpassable(next.x, next.y)) {
                result.reason = 'blocked'; return this._rollbackMove(unit, result);
            }
            if (this.getUnitAt(next.x, next.y) !== null) {
                result.reason = 'occupied'; return this._rollbackMove(unit, result);
            }
            const cost = this.terrainAt(next.x, next.y).moveCost;
            if (spent + cost > unit.remainingMove) {
                result.reason = 'no_points'; return this._rollbackMove(unit, result);
            }

            this.unitGrid[curY][curX] = null;
            unit.x = next.x; unit.y = next.y;
            this.unitGrid[next.y][next.x] = unit;
            spent += cost;
            curX = next.x; curY = next.y;
            result.steps.push({ x: next.x, y: next.y, cost });
        }

        unit.remainingMove -= spent;
        result.spent = spent;
        result.ok = true;
        this.version++;
        this.clearCaches();
        return result;
    }

    _rollbackMove(unit, result) {
        // 撤销已走的中途步骤，回到起点（保证失败调用不产生部分副作用）
        const steps = result.steps;
        this.unitGrid[unit.y][unit.x] = null;
        for (let i = steps.length - 1; i >= 0; i--) {
            unit.x = i === 0 ? result.origin.x : steps[i - 1].x;
            unit.y = i === 0 ? result.origin.y : steps[i - 1].y;
        }
        this.unitGrid[unit.y][unit.x] = unit;
        return result;
    }

    /** 兼容旧 API：走到 (x,y)，内部自行寻路 */
    moveUnit(unit, x, y) {
        if (unit.x === x && unit.y === y) return true;
        const cell = this.computeReachable(unit).get(y * this.width + x);
        if (!cell) return false;
        const res = this.moveAlongPath(unit, cell.path);
        return res.ok;
    }

    // ============================================================ 威胁影响图

    /**
     * camp 所受影响图：每格累加"敌方单位下个回合能打到此处"的攻击力。
     * 计算方式 = 敌方单位的完整机动预算可达域，再按射程外扩。
     *
     * 用完整 moveBudget 而非剩余点数，因为这是"下一回合的威胁"；
     * 用攻击力累计而非净伤害，因为影响图只需给出风险相对高低，
     * 净伤害在候选评分阶段按实际目标防具计算。
     */
    buildThreatMap(camp) {
        const cached = this._threatCache.get(camp);
        if (cached && cached.version === this.version) return cached.cells;

        const threat = new Float32Array(this.width * this.height);
        const enemies = this.unitsOfCamp(this.enemyCamp(camp));

        for (const e of enemies) {
            // 满预算 = 下回合能站到的位置；reachableWithBudget 不吃当前剩余点数
            const reach = this.reachableWithBudget(e, e.moveBudget);
            const ring = e.attackRange;
            for (const cell of reach.values()) {
                this._stampRing(threat, cell.x, cell.y, ring, e.attack);
            }
            // 当前位置本身也可射击
            this._stampRing(threat, e.x, e.y, ring, e.attack);
        }

        this._threatCache.set(camp, { version: this.version, cells: threat });
        return threat;
    }

    _stampRing(threat, cx, cy, radius, value) {
        for (let dy = -radius; dy <= radius; dy++) {
            const rem = radius - Math.abs(dy);
            for (let dx = -rem; dx <= rem; dx++) {
                const x = cx + dx, y = cy + dy;
                if (!this.inBounds(x, y)) continue;
                if (Unit.distance(cx, cy, x, y) > radius) continue;
                threat[y * this.width + x] += value;
            }
        }
    }

    threatAt(camp, x, y) {
        if (!this.inBounds(x, y)) return 0;
        const map = this.buildThreatMap(camp);
        return map[y * this.width + x];
    }

    /** 影响图归一化用：单格最大威胁 */
    maxThreat(camp) {
        const map = this.buildThreatMap(camp);
        let max = 1;
        for (let i = 0; i < map.length; i++) if (map[i] > max) max = map[i];
        return max;
    }

    // ============================================================ 快照 / 回滚

    snapshot() {
        return {
            units: this.units.map(u => u.toState()),
            nextUnitId: this.nextUnitId,
            version: this.version
        };
    }

    restore(snap) {
        for (let i = 0; i < snap.units.length; i++) {
            const u = this.units[i];
            if (u) u.restoreState(snap.units[i]);
        }
        this.rebuildUnitGrid();
        this.version++;
        this.clearCaches();
        return this;
    }

    rebuildUnitGrid() {
        for (let y = 0; y < this.height; y++) this.unitGrid[y].fill(null);
        for (const u of this.units) {
            if (u.isDead) continue;
            if (this.inBounds(u.x, u.y)) this.unitGrid[u.y][u.x] = u;
        }
    }

    // ============================================================ 胜负与评估

    isGameOver() {
        return this.getPlayerUnitCount(1) === 0 || this.getPlayerUnitCount(2) === 0;
    }

    getWinner() {
        if (!this.isGameOver()) return null;
        const p1 = this.getPlayerUnitCount(1);
        const p2 = this.getPlayerUnitCount(2);
        if (p1 === 0 && p2 === 0) return 0;
        return p1 === 0 ? 2 : 1;
    }

    /**
     * 局面物质分：供前瞻 rollout 与难度平衡使用。
     * 血量按 aiValue 加权，残血单位贡献递减（鼓励补刀）。
     */
    materialScore(camp) {
        let mine = 0, theirs = 0;
        for (const u of this.units) {
            if (u.isDead) continue;
            const v = (u.health / u.maxHealth) * u.aiValue;
            if (u.player === camp) mine += v; else theirs += v;
        }
        return mine - theirs;
    }

    getBattlefieldInfo() {
        return {
            width: this.width,
            height: this.height,
            totalUnits: this.units.length,
            player1Units: this.getPlayerUnitCount(1),
            player2Units: this.getPlayerUnitCount(2),
            isGameOver: this.isGameOver(),
            winner: this.getWinner()
        };
    }

    clear() {
        this.units = [];
        for (let y = 0; y < this.height; y++) this.unitGrid[y].fill(null);
        this.version++;
        this.clearCaches();
    }

    /**
     * 快速布阵：左右镜像的默认编成。
     * 落点只在已方出生区（generateTerrain 保留的前 3 列）逐格扫描可通行空格，
     * 避免随机地形把出生位占掉导致编成缺子。
     */
    setDefaultLayout(roster = WarConfig.defaultRoster) {
        this.clear();
        const place = (camp, type) => {
            const spot = this.findSpawnSpot(camp, 0);   // 每次取当前第一个空位，已放子的格自动跳过
            if (spot) this.addUnit(new Unit(type, camp, spot.x, spot.y));
        };
        roster.forEach((type) => place(1, type));
        roster.forEach((type) => place(2, type));
        this.version++;
        this.clearCaches();
        return this;
    }

    /** 出生区内自上而下、由内而外的可通行空格列表（下标 0 即下一个可用出生位） */
    findSpawnSpot(camp, index = 0) {
        const zone = camp === 1
            ? [2, 1, 0]
            : [this.width - 3, this.width - 2, this.width - 1];
        const spots = [];
        for (let y = 0; y < this.height; y++) {
            for (const x of camp === 1 ? zone : [...zone].reverse()) {
                if (this.isWalkable(x, y)) spots.push({ x, y });
            }
        }
        return spots[index] ?? null;
    }
}

if (typeof module !== 'undefined' && module.exports) {
    module.exports = Battlefield;
}

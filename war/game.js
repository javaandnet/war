/**
 * 主游戏：状态机 + 渲染 + AI 回合播放
 *
 * AI 回合的播放方式（重要，决定了"看到的动画"与"AI 真实决策"一致）：
 *   1. 记录回合前快照 snapshotBefore
 *   2. ai.executeTurn() 真实推进状态，拿到可重放事件序列 plan.events
 *   3. 记录回合后快照 snapshotFinal
 *   4. restore(snapshotBefore)，然后逐事件 replayEvent() + 重绘
 *   5. 收尾 restore(snapshotFinal) 兜底，保证最终状态与决策结果完全一致
 * 之所以能这样重放：整个引擎只有 SeededRng 一个随机源，且决策已固化在事件里。
 */
class Game {
    constructor() {
        this.cfg = WarConfig;
        this.terrainSeed = 7;
        this.aiSeed = 20260928;

        this.battlefield = null;
        this.currentPlayer = 1;
        this.selectedUnit = null;
        this.gameMode = 'placement';     // placement | select | move | attack
        this.placementPhase = true;

        this.aiEnabled = false;
        this.aiPlayer1 = null;
        this.aiPlayer2 = null;
        this.aiDifficulty = 'normal';
        this.gameModePref = 'manual';
        this.autoMode = false;
        this.autoStepDelay = 260;

        this.turnCount = 0;
        this.maxTurns = WarConfig.deployment.maxTurns;
        this.lastPlan = null;
        this.busy = false;

        this.overlay = { threat: false, reach: true, candidates: false };

        this.initializeUI();
        this.setupEventListeners();
        this.startNewGame();
    }

    // ================================================================ 初始化

    initializeUI() {
        this.battlefieldElement = document.getElementById('battlefield');
        this.turnIndicator = document.getElementById('turnIndicator');
        this.unitTypeSelect = document.getElementById('unitType');
        this.placeUnitBtn = document.getElementById('placeUnit');
        this.moveUnitBtn = document.getElementById('moveUnit');
        this.attackUnitBtn = document.getElementById('attackUnit');
        this.waitUnitBtn = document.getElementById('waitUnit');
        this.endTurnBtn = document.getElementById('endTurn');
        this.newGameBtn = document.getElementById('newGame');
        this.quickDeployBtn = document.getElementById('quickDeploy');
        this.statsContent = document.getElementById('statsContent');

        this.gameModeSelect = document.getElementById('gameMode');
        this.aiDifficultySelect = document.getElementById('aiDifficulty');
        this.executeAIBtn = document.getElementById('executeAI');
        this.toggleAutoBtn = document.getElementById('toggleAuto');
        this.turnCountElement = document.getElementById('turnCount');
        this.terrainSeedInput = document.getElementById('terrainSeed');
        this.aiSeedInput = document.getElementById('aiSeed');
        this.speedInput = document.getElementById('speed');
        this.speedLabel = document.getElementById('speedLabel');

        this.overlayThreatChk = document.getElementById('ovThreat');
        this.overlayReachChk = document.getElementById('ovReach');
        this.overlayCandChk = document.getElementById('ovCand');
        this.legendEl = document.getElementById('legend');
        this.strategyEl = document.getElementById('strategyLine');
        this.logEl = document.getElementById('aiLog');

        this.renderBattlefield();
        this.updateUI();
    }

    setupEventListeners() {
        this.unitTypeSelect.addEventListener('change', (e) => { this.selectedUnitType = e.target.value; });

        this.placeUnitBtn.addEventListener('click', () => { if (this.placementPhase) this.gameMode = 'placement'; this.renderBattlefield(); });
        this.moveUnitBtn.addEventListener('click', () => { if (!this.placementPhase) { this.gameMode = 'move'; this.renderBattlefield(); } });
        this.attackUnitBtn.addEventListener('click', () => { if (!this.placementPhase) { this.gameMode = 'attack'; this.renderBattlefield(); } });
        this.waitUnitBtn.addEventListener('click', () => this.orderWait());
        this.endTurnBtn.addEventListener('click', () => this.endTurn());
        this.newGameBtn.addEventListener('click', () => this.startNewGame());
        this.quickDeployBtn.addEventListener('click', () => this.quickDeploy());

        this.gameModeSelect.addEventListener('change', (e) => { this.gameModePref = e.target.value; this.updateGameMode(); });
        this.aiDifficultySelect.addEventListener('change', (e) => {
            this.aiDifficulty = e.target.value;
            if (this.aiPlayer1) this.aiPlayer1.setDifficulty(this.aiDifficulty);
            if (this.aiPlayer2) this.aiPlayer2.setDifficulty(this.aiDifficulty);
            this.updateUI();
        });
        this.executeAIBtn.addEventListener('click', () => this.executeAITurn());
        this.toggleAutoBtn.addEventListener('click', () => this.toggleAutoMode());

        this.terrainSeedInput.addEventListener('change', (e) => {
            this.terrainSeed = parseInt(e.target.value, 10) || 1;
            this.startNewGame();
        });
        this.aiSeedInput.addEventListener('change', (e) => {
            this.aiSeed = parseInt(e.target.value, 10) || 1;
            this.rebuildAI();
        });
        this.speedInput.addEventListener('input', (e) => {
            this.autoStepDelay = Number(e.target.value);
            this.speedLabel.textContent = `${this.autoStepDelay}ms`;
        });

        this.overlayThreatChk.addEventListener('change', (e) => { this.overlay.threat = e.target.checked; this.renderBattlefield(); });
        this.overlayReachChk.addEventListener('change', (e) => { this.overlay.reach = e.target.checked; this.renderBattlefield(); });
        this.overlayCandChk.addEventListener('change', (e) => { this.overlay.candidates = e.target.checked; this.renderBattlefield(); });
    }

    rebuildAI() {
        this.aiPlayer1 = new WarAI(this.battlefield, 1, { difficulty: this.aiDifficulty, seed: this.aiSeed, debug: true });
        this.aiPlayer2 = new WarAI(this.battlefield, 2, { difficulty: this.aiDifficulty, seed: this.aiSeed + 1, debug: true });
    }

    startNewGame() {
        this.autoMode = false;
        this.placementPhase = true;
        this.gameMode = 'placement';
        this.currentPlayer = 1;
        this.selectedUnit = null;
        this.selectedUnitType = 'infantry';
        this.turnCount = 0;
        this.lastPlan = null;

        this.battlefield = new Battlefield(this.cfg.board.width, this.cfg.board.height, this.terrainSeed);
        this.rebuildAI();
        this.renderBattlefield();
        this.updateUI();
        this.setLog([]);
    }

    /** 一键按默认编成布阵，跳过手工放置 */
    quickDeploy() {
        this.battlefield.setDefaultLayout();
        this.placementPhase = false;
        this.currentPlayer = 1;
        this.battlefield.resetAllActions();
        this.turnCount = 1;
        this.gameMode = 'select';
        this.renderBattlefield();
        this.updateUI();
        if (this.gameModePref === 'auto') this.toggleAutoMode();
    }

    // ================================================================ 棋盘交互

    handleCellClick(x, y) {
        if (this.busy) return;

        if (this.placementPhase) { this.handlePlacementClick(x, y); return; }

        const clicked = this.battlefield.getUnitAt(x, y);

        if (this.gameMode === 'move' && this.selectedUnit && clicked !== this.selectedUnit) {
            this.tryPlayerMove(x, y);
            return;
        }
        if (this.gameMode === 'attack' && clicked && clicked.player !== this.currentPlayer) {
            this.tryPlayerAttack(clicked);
            return;
        }
        if (clicked && clicked.player === this.currentPlayer) {
            this.selectUnit(clicked);
            return;
        }
        this.selectedUnit = null;
        this.renderBattlefield();
        this.updateUnitStats(null);
    }

    handlePlacementClick(x, y) {
        if (!this.isInDeployZone(this.currentPlayer, x, y)) {
            this.flash(`只能在己方出生区（${this.currentPlayer === 1 ? '左侧' : '右侧'} 3 列）布阵`);
            return;
        }
        if (!this.battlefield.isWalkable(x, y)) {
            this.flash('该格不可通行或已有人');
            return;
        }
        const count = this.battlefield.getPlayerUnitCount(this.currentPlayer);
        if (count >= this.cfg.deployment.maxPerSide) {
            this.flash('本方编成已满，结束布阵吧');
            return;
        }
        this.battlefield.addUnit(new Unit(this.selectedUnitType, this.currentPlayer, x, y));
        this.renderBattlefield();
        this.updateUI();
    }

    isInDeployZone(camp, x) {
        return camp === 1 ? x <= 2 : x >= this.battlefield.width - 3;
    }

    selectUnit(unit) {
        this.selectedUnit = unit;
        this.gameMode = 'select';
        this.updateUnitStats(unit);
        this.renderBattlefield();
    }

    tryPlayerMove(x, y) {
        const unit = this.selectedUnit;
        if (!unit) return;
        const cell = this.battlefield.computeReachable(unit).get(y * this.battlefield.width + x);
        if (!cell) { this.flash('该格不在机动范围内（注意地形消耗）'); return; }

        const res = this.battlefield.moveAlongPath(unit, cell.path);
        if (!res.ok) { this.flash(`移动失败：${res.reason}`); return; }
        this.gameMode = 'select';
        this.renderBattlefield();
        this.updateUnitStats(unit);
    }

    tryPlayerAttack(target) {
        const unit = this.selectedUnit;
        if (!unit) { this.flash('先选择己方单位'); return; }
        if (!this.battlefield.canTargetFrom(unit, target, unit.x, unit.y)) {
            this.flash('打不到：超出射程、无视线或已用过攻击配额');
            return;
        }
        const r = this.battlefield.attack(unit, target);
        if (r.rejected) { this.flash(`攻击失败：${r.rejected}`); return; }

        this.showDamageEffect(target.x, target.y, r.damage);
        if (r.counterDamage > 0) this.showDamageEffect(unit.x, unit.y, r.counterDamage, true);
        this.battlefield.cleanupDeadUnits();
        this.selectedUnit = null;
        this.gameMode = 'select';
        this.renderBattlefield();
        this.updateUI();
        this.checkGameOver();
    }

    /** 待命：主动放弃本回合剩余配额（AI 评分里有这个候选，玩家也该有） */
    orderWait() {
        if (!this.selectedUnit || this.placementPhase) return;
        this.selectedUnit.remainingMove = 0;
        this.selectedUnit.remainingAttacks = 0;
        this.selectedUnit = null;
        this.renderBattlefield();
        this.updateUI();
    }

    // ================================================================ 回合流转

    endTurn() {
        if (this.busy) return;

        if (this.placementPhase) {
            if (this.currentPlayer === 1 && this.battlefield.getPlayerUnitCount(1) > 0) {
                this.currentPlayer = 2;
            } else {
                this.placementPhase = false;
                this.currentPlayer = 1;
                this.turnCount = 1;
            }
            this.battlefield.resetAllActions();
            this.selectedUnit = null;
            this.gameMode = this.placementPhase ? 'placement' : 'select';
            this.updateUI();
            this.renderBattlefield();
            if (!this.placementPhase && this.autoMode) this.runAutoBattle();
            return;
        }

        this.currentPlayer = this.currentPlayer === 1 ? 2 : 1;
        if (this.currentPlayer === 1) this.turnCount++;
        this.selectedUnit = null;
        this.gameMode = 'select';
        this.battlefield.resetAllActions();
        this.updateUI();
        this.renderBattlefield();

        if (this.autoMode) this.runAutoBattle();
        else if (this.aiEnabled && this.currentPlayer === 2) this.executeAITurn();
    }

    sleep(ms) {
        return new Promise(r => setTimeout(r, ms));
    }

    /** AI（或玩家）回合入口 */
    async executeAITurn() {
        const camp = this.currentPlayer;
        const ai = camp === 1 ? this.aiPlayer1 : this.aiPlayer2;
        if (!ai || this.placementPhase || this.busy) return;
        if (this.aiEnabled && camp === 1 && this.gameModePref === 'ai_vs_player') return;

        this.busy = true;
        this.updateUI();
        this.battlefield.resetAllActions();

        const before = this.battlefield.snapshot();
        const plan = ai.executeTurn();
        const final = this.battlefield.snapshot();
        this.lastPlan = plan;

        // 回到回合前状态，逐事件重放，使动画与决策严格对应
        this.battlefield.restore(before);
        this.renderBattlefield();

        for (const ev of plan.events) {
            const unit = this.battlefield.units.find(u => u.id === ev.unitId);
            if (unit && ev.path && ev.path.length > 1) {
                for (const step of ev.path.slice(1)) {
                    await this.sleep(Math.min(90, this.autoStepDelay / 2));
                    this.battlefield.moveAlongPath(unit, [{ x: unit.x, y: unit.y }, step]);
                }
            }
            this.renderBattlefield();
            await this.sleep(Math.max(40, this.autoStepDelay / 3));
            replayEvent(this.battlefield, ev);
            if (ev.damage) this.showDamageEffect(ev.to.x, ev.to.y, ev.damage);
            if (ev.counterDamage) this.showDamageEffect(ev.from.x, ev.from.y, ev.counterDamage, true);
            this.renderBattlefield();
            await this.sleep(Math.max(40, this.autoStepDelay / 3));
        }

        this.battlefield.restore(final);
        this.battlefield.cleanupDeadUnits();
        this.renderBattlefield();
        this.setLog(plan.decisions);
        this.updateUI();
        this.busy = false;
        this.checkGameOver();
    }

    async runAutoBattle() {
        if (!this.autoMode || this.placementPhase) return;
        if (this.turnCount >= this.maxTurns) { this.endGameByTurnLimit(); return; }

        await this.executeAITurn();
        if (this.battlefield.isGameOver()) { this.checkGameOver(); return; }
        if (!this.autoMode) return;

        this.endTurn();
    }

    toggleAutoMode() {
        this.autoMode = !this.autoMode;
        this.aiEnabled = this.autoMode || this.gameModePref === 'ai_vs_player';
        this.toggleAutoBtn.textContent = this.autoMode ? '停止自动战斗' : '开始自动战斗';
        this.updateGameMode();
        if (this.autoMode && !this.placementPhase) this.runAutoBattle();
    }

    updateGameMode() {
        switch (this.gameModePref) {
            case 'manual':
                this.autoMode = false; this.aiEnabled = false;
                break;
            case 'ai_vs_player':
                this.autoMode = false; this.aiEnabled = true;
                break;
            case 'auto':
                this.autoMode = true; this.aiEnabled = true;
                break;
        }
        if (this.toggleAutoBtn) {
            this.toggleAutoBtn.textContent = this.autoMode ? '停止自动战斗' : '开始自动战斗';
        }
        this.updateUI();
    }

    isAiControlled(camp) {
        if (this.autoMode) return true;
        return this.aiEnabled && camp === 2 && this.gameModePref === 'ai_vs_player';
    }

    checkGameOver() {
        if (!this.battlefield.isGameOver()) return false;
        const winner = this.battlefield.getWinner();
        const msg = winner === 0 ? '平局' : `玩家${winner} 获胜`;
        this.turnIndicator.textContent = `游戏结束！${msg}（总回合数 ${this.turnCount}）`;
        this.autoMode = false;
        this.updateUI();
        return true;
    }

    endGameByTurnLimit() {
        const n1 = this.battlefield.getPlayerUnitCount(1);
        const n2 = this.battlefield.getPlayerUnitCount(2);
        const winner = n1 > n2 ? 1 : n2 > n1 ? 2 : 0;
        this.autoMode = false;
        this.turnIndicator.textContent = `达到回合上限：${winner === 0 ? '平局' : '玩家' + winner + ' 优势'}（${n1} vs ${n2}）`;
        this.updateUI();
    }

    // ================================================================ 渲染

    renderBattlefield() {
        const bf = this.battlefield;
        const frag = document.createDocumentFragment();
        const reach = this.selectedUnit ? bf.computeReachable(this.selectedUnit) : new Map();
        const targets = this.selectedUnit ? new Set(bf.getAttackableTargets(this.selectedUnit).map(t => t.id)) : new Set();
        const threat = this.overlay.threat ? bf.buildThreatMap(this.currentPlayer) : null;
        const maxThreat = threat ? bf.maxThreat(this.currentPlayer) : 1;
        const best = this.overlay.candidates && this.lastPlan ? this.bestDestByUnit() : null;

        for (let y = 0; y < bf.height; y++) {
            const row = document.createElement('div');
            row.className = 'battlefield-row';

            for (let x = 0; x < bf.width; x++) {
                const cell = document.createElement('div');
                cell.className = 'battlefield-cell';
                const terr = bf.terrainAt(x, y);
                if (terr.css) cell.classList.add(terr.css);
                if (terr.symbol) {
                    const t = document.createElement('span');
                    t.className = 'terrain-mark';
                    t.textContent = terr.symbol;
                    cell.appendChild(t);
                }

                if (threat) {
                    const v = threat[y * bf.width + x] / maxThreat;
                    if (v > 0.02) {
                        cell.style.background = `rgba(255, 40, 40, ${Math.min(0.55, v * 0.55).toFixed(2)})`;
                    }
                }

                const cellKey = y * bf.width + x;
                if (this.overlay.reach && reach.has(cellKey)) {
                    cell.classList.add('movable');
                    const badge = document.createElement('span');
                    badge.className = 'cost-badge';
                    badge.textContent = String(reach.get(cellKey).cost);
                    cell.appendChild(badge);
                }

                const unit = bf.getUnitAt(x, y);
                if (unit) {
                    cell.appendChild(this.createUnitElement(unit, targets.has(unit.id)));
                    if (this.selectedUnit && unit === this.selectedUnit) cell.classList.add('selected');
                }

                if (best && best.has(`${x},${y}`)) {
                    const mark = document.createElement('span');
                    mark.className = 'ai-best';
                    mark.textContent = best.get(`${x},${y}`);
                    cell.appendChild(mark);
                }

                cell.addEventListener('click', () => this.handleCellClick(x, y));
                row.appendChild(cell);
            }
            frag.appendChild(row);
        }

        this.battlefieldElement.replaceChildren(frag);
        this.renderLegend();
        this.renderStrategyLine();
    }

    /** 上一回合 AI 每个单位的最优落点（调试可视化用） */
    bestDestByUnit() {
        const map = new Map();
        if (!this.lastPlan) return map;
        for (const d of this.lastPlan.decisions) {
            if (!d.top || !d.top.length) continue;
            const bestTop = d.top[0];
            const m = /\((\d+),(\d+)\)/.exec(bestTop.desc);
            if (m) map.set(`${m[1]},${m[2]}`, '★');
        }
        return map;
    }

    createUnitElement(unit, isTarget) {
        const el = document.createElement('div');
        el.className = `unit ${unit.type} player${unit.player}`;
        if (isTarget) el.classList.add('targeted');
        el.textContent = unit.symbol;
        el.title = `${unit.getDisplayName()} #${unit.id}`;

        const hp = document.createElement('div');
        hp.className = 'unit-info';
        hp.textContent = `${unit.health}`;
        el.appendChild(hp);

        const ap = document.createElement('div');
        ap.className = 'unit-ap';
        ap.textContent = `${unit.remainingMove}⚡${unit.remainingAttacks}⚔`;
        el.appendChild(ap);
        return el;
    }

    renderLegend() {
        if (!this.legendEl) return;
        const rows = Object.values(WarConfig.terrain).map(t =>
            `<span class="lg"><i class="lg-box ${t.css}"></i>${t.name} 消耗${t.moveCost}${t.defBonus ? ` 防御+${t.defBonus}` : ''}${t.impassable ? ' 不可通行' : ''}</span>`
        );
        this.legendEl.innerHTML = rows.join('');
    }

    renderStrategyLine() {
        if (!this.strategyEl) return;
        const p = this.lastPlan;
        if (!p) { this.strategyEl.textContent = '（尚未有 AI 回合）'; return; }
        const labels = { attack: '进攻', defend: '防守', rush: '全面冲锋', retreat: '脱离接触', flank: '侧翼包抄' };
        this.strategyEl.innerHTML =
            `<b>玩家${p.camp}</b> 难度 <b>${p.difficulty}</b>` +
            `（T=${p.order.temperature ?? WarConfig.difficulty[p.difficulty].temperature}, 前瞻=${WarConfig.difficulty[p.difficulty].lookahead}, 视野=${WarConfig.difficulty[p.difficulty].vision}）<br>` +
            `战略：<b>${labels[p.order.strategy] || p.order.strategy}</b> → 目标区 (${p.order.objective.x},${p.order.objective.y})，集火 #${p.order.focusId ?? '-'}<br>` +
            `<span class="muted">${p.order.note}</span>`;
    }

    setLog(decisions) {
        if (!this.logEl) return;
        if (!decisions || !decisions.length) { this.logEl.innerHTML = '<p class="muted">暂无 AI 决策记录</p>'; return; }

        const html = decisions.map(d => {
            const rows = (d.top || []).map((c, i) => {
                const parts = Object.entries(c.parts).filter(([, v]) => Math.abs(v) > 0.05)
                    .map(([k, v]) => `${PART_NAMES[k] || k} ${v > 0 ? '+' : ''}${v}`).join('，');
                const star = d.chosen === c.desc ? '◀ 选中' : '';
                return `<li class="${star ? 'hit' : ''}"><b>#${i + 1}</b> ${c.desc} <span class="sc">${c.score}</span> <span class="muted">${parts}</span> ${star}</li>`;
            }).join('');
            return `<div class="decision"><div class="dh">${d.unit} · ${d.budget} · 候选 ${d.candidates} 个 · ${d.ms}ms</div><ul>${rows}</ul></div>`;
        }).join('');
        this.logEl.innerHTML = html;
    }

    showDamageEffect(x, y, damage, isCounter) {
        const row = this.battlefieldElement.children[y];
        const cell = row && row.children[x];
        if (!cell) return;
        const el = document.createElement('div');
        el.className = 'damage-float' + (isCounter ? ' counter' : '');
        el.textContent = `-${damage}`;
        cell.appendChild(el);
        setTimeout(() => el.remove(), 900);
    }

    flash(msg) {
        this.turnIndicator.dataset.hint = msg;
        const old = this.turnIndicator.textContent;
        this.turnIndicator.textContent = `⚠ ${msg}`;
        clearTimeout(this._flashTimer);
        this._flashTimer = setTimeout(() => this.updateUI(), 1600);
        void old;
    }

    // ================================================================ 面板

    updateUI() {
        if (this.placementPhase) {
            this.turnIndicator.textContent = `布阵阶段：玩家${this.currentPlayer}（已放 ${this.battlefield.getPlayerUnitCount(this.currentPlayer)}/${this.cfg.deployment.maxPerSide}）`;
        } else if (!this.battlefield.isGameOver()) {
            const actor = this.isAiControlled(this.currentPlayer) ? `玩家${this.currentPlayer}（AI）` : `玩家${this.currentPlayer}`;
            this.turnIndicator.textContent = `第 ${this.turnCount} 回合：${actor}`;
        }
        if (this.turnCountElement) this.turnCountElement.textContent = this.turnCount;

        this.placeUnitBtn.disabled = !this.placementPhase;
        this.moveUnitBtn.disabled = this.placementPhase;
        this.attackUnitBtn.disabled = this.placementPhase;
        this.waitUnitBtn.disabled = this.placementPhase || !this.selectedUnit;
        this.endTurnBtn.disabled = this.placementPhase ? false : this.busy;
        this.executeAIBtn.disabled = this.placementPhase || this.busy;
        this.quickDeployBtn.disabled = !this.placementPhase || this.busy;
    }

    updateUnitStats(unit) {
        if (!unit) { this.statsContent.innerHTML = '选择一个单位查看详细信息'; return; }
        const t = this.battlefield.terrainAt(unit.x, unit.y);
        const threat = Math.round(this.battlefield.threatAt(unit.player, unit.x, unit.y));
        this.statsContent.innerHTML = `
            <div class="stat-row"><span class="stat-label">名称</span><span class="stat-value">${unit.getDisplayName()} #${unit.id}</span></div>
            <div class="stat-row"><span class="stat-label">生命</span><span class="stat-value">${unit.health}/${unit.maxHealth}</span></div>
            <div class="stat-row"><span class="stat-label">攻击 / 防御</span><span class="stat-value">${unit.attack} / ${unit.defense}${t.defBonus ? ` <span class="muted">(+${t.defBonus} 地形)</span>` : ''}</span></div>
            <div class="stat-row"><span class="stat-label">射程</span><span class="stat-value">${unit.attackRange} 格${unit.attackRange > 1 ? '（直线需视线）' : ''}</span></div>
            <div class="stat-row"><span class="stat-label">机动</span><span class="stat-value">${unit.remainingMove}/${unit.moveBudget}</span></div>
            <div class="stat-row"><span class="stat-label">攻击配额</span><span class="stat-value">${unit.remainingAttacks}/${unit.attackBudget}</span></div>
            <div class="stat-row"><span class="stat-label">所在地形</span><span class="stat-value">${t.name}</span></div>
            <div class="stat-row"><span class="stat-label">所处威胁值</span><span class="stat-value">${threat}</span></div>`;
    }
}

/** 决策日志里的分项中文名，方便非程序员调参 */
const PART_NAMES = {
    damage: '伤害', kill: '击杀', overkill: '过量', targetValue: '目标价值',
    exposure: '暴露风险', terrain: '地形', focus: '集火', counter: '反击风险',
    mobility: '机动保留', objective: '战略牵引', support: '友军支援',
    surround: '包围', waste: '待命惩罚', followup: '前瞻'
};

document.addEventListener('DOMContentLoaded', () => {
    window.game = new Game();
});

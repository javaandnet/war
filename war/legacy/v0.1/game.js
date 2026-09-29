// 主游戏类
class Game {
    constructor() {
        this.battlefield = new Battlefield(20, 20);
        this.currentPlayer = 1;
        this.selectedUnit = null;
        this.gameMode = 'placement'; // 'placement', 'game'
        this.placementPhase = true;
        this.selectedUnitType = 'infantry';
        
        // AI相关
        this.aiEnabled = false;
        this.aiPlayer1 = new AI(this.battlefield, 1);
        this.aiPlayer2 = new AI(this.battlefield, 2);
        this.aiDifficulty = 'medium';
        this.autoMode = false; // 自动模式，两方都由AI控制
        
        // 回合控制
        this.turnCount = 0;
        this.maxTurns = 100; // 最大回合数，防止死循环
        this.turnTimer = null;
        this.turnDuration = 2000; // 2秒一个回合
        
        this.initializeUI();
        this.setupEventListeners();
        this.startNewGame();
    }
    
    // 初始化用户界面
    initializeUI() {
        this.battlefieldElement = document.getElementById('battlefield');
        this.turnIndicator = document.getElementById('turnIndicator');
        this.unitTypeSelect = document.getElementById('unitType');
        this.placeUnitBtn = document.getElementById('placeUnit');
        this.moveUnitBtn = document.getElementById('moveUnit');
        this.attackUnitBtn = document.getElementById('attackUnit');
        this.endTurnBtn = document.getElementById('endTurn');
        this.newGameBtn = document.getElementById('newGame');
        this.statsContent = document.getElementById('statsContent');
        
        // AI控制元素
        this.gameModeSelect = document.getElementById('gameMode');
        this.aiDifficultySelect = document.getElementById('aiDifficulty');
        this.executeAIBtn = document.getElementById('executeAI');
        this.toggleAutoBtn = document.getElementById('toggleAuto');
        
        // 回合计数元素
        this.turnCountElement = document.getElementById('turnCount');
        
        this.renderBattlefield();
        this.updateUI();
    }
    
    // 设置事件监听器
    setupEventListeners() {
        // 兵种选择
        this.unitTypeSelect.addEventListener('change', (e) => {
            this.selectedUnitType = e.target.value;
        });
        
        // 按钮事件
        this.placeUnitBtn.addEventListener('click', () => {
            if (this.placementPhase) {
                this.gameMode = 'placement';
            }
        });
        
        this.moveUnitBtn.addEventListener('click', () => {
            if (!this.placementPhase) {
                this.gameMode = 'move';
            }
        });
        
        this.attackUnitBtn.addEventListener('click', () => {
            if (!this.placementPhase) {
                this.gameMode = 'attack';
            }
        });
        
        this.endTurnBtn.addEventListener('click', () => {
            this.endTurn();
        });
        
        this.newGameBtn.addEventListener('click', () => {
            this.startNewGame();
        });
        
        // AI控制事件
        this.gameModeSelect.addEventListener('change', (e) => {
            this.gameMode = e.target.value;
            this.updateGameMode();
        });
        
        this.aiDifficultySelect.addEventListener('change', (e) => {
            this.aiDifficulty = e.target.value;
            this.aiPlayer1.setDifficulty(this.aiDifficulty);
            this.aiPlayer2.setDifficulty(this.aiDifficulty);
        });
        
        this.executeAIBtn.addEventListener('click', () => {
            this.executeAITurn();
        });
        
        this.toggleAutoBtn.addEventListener('click', () => {
            this.toggleAutoMode();
        });
    }
    
    // 开始新游戏
    startNewGame() {
        this.battlefield.setDefaultLayout();
        this.currentPlayer = 1;
        this.selectedUnit = null;
        this.gameMode = 'placement';
        this.placementPhase = false;
        
        // 重置回合计数
        this.turnCount = 0;
        
        this.renderBattlefield();
        this.updateUI();
        this.setupBattlefieldClickHandlers();
    }
    
    // 设置战场点击处理器
    setupBattlefieldClickHandlers() {
        const cells = this.battlefieldElement.querySelectorAll('.battlefield-cell');
        cells.forEach((cell) => {
            cell.onclick = () => {
                const x = parseInt(cell.dataset.x);
                const y = parseInt(cell.dataset.y);
                this.handleCellClick(x, y);
            };
        });
    }
    
    // 处理单元格点击
    handleCellClick(x, y) {
        const unit = this.battlefield.getUnitAt(x, y);
        
        if (this.gameMode === 'placement') {
            this.handlePlacementClick(x, y);
        } else if (this.gameMode === 'move') {
            this.handleMoveClick(x, y);
        } else if (this.gameMode === 'attack') {
            this.handleAttackClick(x, y);
        } else {
            // 选择单位
            this.handleUnitSelection(x, y);
        }
    }
    
    // 处理放置点击
    handlePlacementClick(x, y) {
        if (!this.battlefield.hasUnitAt(x, y)) {
            const newUnit = new Unit(this.selectedUnitType, this.currentPlayer, x, y);
            if (this.battlefield.addUnit(newUnit)) {
                this.renderBattlefield();
                this.updateUI();
            }
        }
    }
    
    // 处理移动点击
    handleMoveClick(x, y) {
        if (this.selectedUnit && this.selectedUnit.player === this.currentPlayer) {
            const movablePositions = this.battlefield.getMovablePositions(this.selectedUnit);
            const canMove = movablePositions.some(pos => pos.x === x && pos.y === y);
            
            if (canMove) {
                this.battlefield.moveUnit(this.selectedUnit, x, y);
                this.selectedUnit = null;
                this.gameMode = 'select';
                this.renderBattlefield();
                this.updateUI();
            }
        }
    }
    
    // 处理攻击点击
    handleAttackClick(x, y) {
        if (this.selectedUnit && this.selectedUnit.player === this.currentPlayer) {
            const target = this.battlefield.getUnitAt(x, y);
            if (target && this.selectedUnit.canAttack(target)) {
                const damage = this.selectedUnit.attackTarget(target);
                if (damage > 0) {
                    this.showDamageEffect(x, y, damage);
                    this.battlefield.cleanupDeadUnits();
                    this.selectedUnit = null;
                    this.gameMode = 'select';
                    this.renderBattlefield();
                    this.updateUI();
                    this.checkGameOver();
                }
            }
        }
    }
    
    // 处理单位选择
    handleUnitSelection(x, y) {
        const unit = this.battlefield.getUnitAt(x, y);
        
        if (unit && unit.player === this.currentPlayer && !unit.isDead) {
            this.selectedUnit = unit;
            this.updateUnitStats(unit);
            this.renderBattlefield();
        } else {
            this.selectedUnit = null;
            this.updateUnitStats(null);
            this.renderBattlefield();
        }
    }
    
    // 显示伤害效果
    showDamageEffect(x, y, damage) {
        const cell = this.battlefieldElement.children[y].children[x];
        const damageElement = document.createElement('div');
        damageElement.textContent = `-${damage}`;
        damageElement.style.cssText = `
            position: absolute;
            color: red;
            font-weight: bold;
            font-size: 16px;
            z-index: 1000;
            animation: damageFloat 1s ease-out forwards;
        `;
        
        const style = document.createElement('style');
        style.textContent = `
            @keyframes damageFloat {
                0% { transform: translateY(0); opacity: 1; }
                100% { transform: translateY(-30px); opacity: 0; }
            }
        `;
        document.head.appendChild(style);
        
        cell.appendChild(damageElement);
        setTimeout(() => {
            cell.removeChild(damageElement);
        }, 1000);
    }
    
    // 结束回合
    endTurn() {
        if (this.placementPhase) {
            // 放置阶段结束
            if (this.currentPlayer === 1) {
                this.currentPlayer = 2;
                this.turnIndicator.textContent = '当前回合: 玩家2 (放置单位)';
            } else {
                this.placementPhase = false;
                this.currentPlayer = 1;
                this.battlefield.resetAllActions();
                this.turnIndicator.textContent = '当前回合: 玩家1';
                this.turnCount = 1; // 开始计数
                
                // 如果开启自动模式，开始自动战斗
                if (this.autoMode) {
                    this.startAutoBattle();
                }
            }
        } else {
            // 游戏阶段结束
            this.currentPlayer = this.currentPlayer === 1 ? 2 : 1;
            this.battlefield.resetAllActions();
            this.selectedUnit = null;
            this.gameMode = 'select';
            
            // 增加回合计数
            if (this.currentPlayer === 1) {
                this.turnCount++;
            }
            
            // 自动模式下继续AI战斗
            if (this.autoMode) {
                this.executeCurrentPlayerAI();
            }
        }
        
        this.updateUI();
        this.renderBattlefield();
    }
    
    // 检查游戏是否结束
    checkGameOver() {
        if (this.battlefield.isGameOver()) {
            const winner = this.battlefield.getWinner();
            setTimeout(() => {
                alert(`游戏结束！玩家${winner}获胜！\n总回合数: ${this.turnCount}`);
            }, 500);
        }
    }
    
    // 回合限制结束游戏
    endGameByTurnLimit() {
        const player1Units = this.battlefield.getPlayerUnitCount(1);
        const player2Units = this.battlefield.getPlayerUnitCount(2);
        
        let result = '';
        if (player1Units > player2Units) {
            result = `游戏结束！达到最大回合数限制。\n玩家1获胜！(剩余单位: ${player1Units} vs ${player2Units})\n总回合数: ${this.turnCount}`;
        } else if (player2Units > player1Units) {
            result = `游戏结束！达到最大回合数限制。\n玩家2获胜！(剩余单位: ${player2Units} vs ${player1Units})\n总回合数: ${this.turnCount}`;
        } else {
            result = `游戏结束！达到最大回合数限制。\n平局！(剩余单位: ${player1Units} vs ${player2Units})\n总回合数: ${this.turnCount}`;
        }
        
        setTimeout(() => {
            alert(result);
        }, 500);
        
        this.autoMode = false;
        this.updateUI();
    }
    
    // 渲染战场
    renderBattlefield() {
        this.battlefieldElement.innerHTML = '';
        
        for (let y = 0; y < this.battlefield.height; y++) {
            const row = document.createElement('div');
            row.className = 'battlefield-row';
            
            for (let x = 0; x < this.battlefield.width; x++) {
                const cell = document.createElement('div');
                cell.className = 'battlefield-cell';
                cell.dataset.x = x;
                cell.dataset.y = y;
                
                const unit = this.battlefield.getUnitAt(x, y);
                
                if (unit) {
                    const unitElement = this.createUnitElement(unit);
                    cell.appendChild(unitElement);
                    
                    // 添加单位信息标签
                    const infoLabel = document.createElement('div');
                    infoLabel.className = 'unit-info';
                    infoLabel.textContent = `${unit.health}/${unit.maxHealth}`;
                    cell.appendChild(infoLabel);
                }
                
                // 高亮显示
                this.highlightCell(cell, x, y);
                
                row.appendChild(cell);
            }
            
            this.battlefieldElement.appendChild(row);
        }
        
        this.setupBattlefieldClickHandlers();
    }
    
    // 创建单位元素
    createUnitElement(unit) {
        const unitElement = document.createElement('div');
        unitElement.className = `unit ${unit.type} player${unit.player}`;
        
        if (unit.isDead) {
            unitElement.classList.add('dead');
        }
        
        // 为弓兵添加特殊处理
        if (unit.type === 'archer') {
            const innerElement = document.createElement('div');
            innerElement.textContent = unit.symbol;
            innerElement.style.transform = 'rotate(-45deg)';
            innerElement.style.position = 'relative';
            innerElement.style.zIndex = '1';
            unitElement.appendChild(innerElement);
        } else {
            unitElement.textContent = unit.symbol;
        }
        
        unitElement.title = unit.getDisplayName();
        
        return unitElement;
    }
    
    // 高亮单元格
    highlightCell(cell, x, y) {
        // 清除之前的高亮
        cell.classList.remove('selected', 'movable', 'attackable');
        
        // 选中的单位
        if (this.selectedUnit && this.battlefield.isUnitAtPosition(this.selectedUnit, x, y)) {
            cell.classList.add('selected');
        }
        
        // 可移动位置
        if (this.selectedUnit && this.gameMode === 'move') {
            const movablePositions = this.battlefield.getMovablePositions(this.selectedUnit);
            if (movablePositions.some(pos => pos.x === x && pos.y === y)) {
                cell.classList.add('movable');
            }
        }
        
        // 可攻击目标
        if (this.selectedUnit && this.gameMode === 'attack') {
            const attackableTargets = this.battlefield.getAttackableTargets(this.selectedUnit);
            if (attackableTargets.some(target => target.x === x && target.y === y)) {
                cell.classList.add('attackable');
            }
        }
    }
    
    // 更新用户界面
    updateUI() {
        // 更新回合指示器
        if (this.placementPhase) {
            this.turnIndicator.textContent = `当前回合: 玩家${this.currentPlayer} (放置单位)`;
        } else {
            this.turnIndicator.textContent = `当前回合: 玩家${this.currentPlayer}`;
        }
        
        // 更新回合计数
        if (this.turnCountElement) {
            this.turnCountElement.textContent = this.turnCount;
        }
        
        // 更新按钮状态
        this.placeUnitBtn.disabled = !this.placementPhase;
        this.moveUnitBtn.disabled = this.placementPhase;
        this.attackUnitBtn.disabled = this.placementPhase;
        this.endTurnBtn.disabled = false;
        
        // 更新单位统计
        const info = this.battlefield.getBattlefieldInfo();
        if (info.isGameOver) {
            this.turnIndicator.textContent = `游戏结束！玩家${info.winner}获胜！`;
        }
    }
    
    // 更新单位统计信息
    updateUnitStats(unit) {
        if (!unit) {
            this.statsContent.innerHTML = '选择一个单位查看详细信息';
            return;
        }
        
        const info = unit.getInfo();
        this.statsContent.innerHTML = `
            <div class="stat-row">
                <span class="stat-label">名称:</span>
                <span class="stat-value">${unit.getDisplayName()}</span>
            </div>
            <div class="stat-row">
                <span class="stat-label">生命值:</span>
                <span class="stat-value">${info.health}/${info.maxHealth}</span>
            </div>
            <div class="stat-row">
                <span class="stat-label">攻击力:</span>
                <span class="stat-value">${info.attack}</span>
            </div>
            <div class="stat-row">
                <span class="stat-label">防御力:</span>
                <span class="stat-value">${info.defense}</span>
            </div>
            <div class="stat-row">
                <span class="stat-label">攻击范围:</span>
                <span class="stat-value">${info.attackRange}格</span>
            </div>
            <div class="stat-row">
                <span class="stat-label">移动范围:</span>
                <span class="stat-value">${info.moveRange}格</span>
            </div>
            <div class="stat-row">
                <span class="stat-label">剩余行动力:</span>
                <span class="stat-value">${info.remainingActionPoints}/${info.actionPoints}</span>
            </div>
        `;
    }
    
    // 执行AI回合
    executeAITurn() {
        if (!this.aiEnabled || this.currentPlayer !== 2 || this.placementPhase) {
            return;
        }
        
        this.aiPlayer2.executeTurn();
        this.renderBattlefield();
        this.updateUI();
        this.checkGameOver();
    }
    
    // 执行当前玩家的AI
    executeCurrentPlayerAI() {
        if (!this.autoMode || this.placementPhase) {
            return;
        }
        
        // 检查回合数限制
        if (this.turnCount >= this.maxTurns) {
            this.endGameByTurnLimit();
            return;
        }
        
        // 检查是否有单位可以行动
        const currentPlayerUnits = this.battlefield.getPlayerUnits(this.currentPlayer);
        const canActUnits = currentPlayerUnits.filter(unit => unit.remainingActionPoints > 0);
        
        if (canActUnits.length === 0) {
            // 如果没有单位可以行动，直接结束回合
            this.endTurn();
            return;
        }
        
        setTimeout(() => {
            if (this.currentPlayer === 1) {
                this.aiPlayer1.executeTurn();
            } else {
                this.aiPlayer2.executeTurn();
            }
            
            this.renderBattlefield();
            this.updateUI();
            this.checkGameOver();
            
            // 如果游戏没有结束，继续下一回合
            if (!this.battlefield.isGameOver()) {
                this.endTurn();
            }
        }, this.turnDuration); // 使用2秒延迟
    }
    
    // 开始自动战斗
    startAutoBattle() {
        if (this.autoMode && !this.placementPhase) {
            this.executeCurrentPlayerAI();
        }
    }
    
    // 切换自动模式
    toggleAutoMode() {
        this.autoMode = !this.autoMode;
        if (this.autoMode) {
            this.aiEnabled = true;
            this.aiPlayer1.setDifficulty(this.aiDifficulty);
            this.aiPlayer2.setDifficulty(this.aiDifficulty);
            this.toggleAutoBtn.textContent = '停止自动战斗';
            // 如果游戏已经开始，立即开始自动战斗
            if (!this.placementPhase) {
                this.startAutoBattle();
            }
        } else {
            this.aiEnabled = false;
            this.toggleAutoBtn.textContent = '开始自动战斗';
        }
        this.updateUI();
    }
    
    // 更新游戏模式
    updateGameMode() {
        switch (this.gameMode) {
            case 'manual':
                this.autoMode = false;
                this.aiEnabled = false;
                this.toggleAutoBtn.textContent = '开始自动战斗';
                break;
            case 'ai_vs_player':
                this.autoMode = false;
                this.aiEnabled = true;
                this.toggleAutoBtn.textContent = '开始自动战斗';
                break;
            case 'auto':
                this.autoMode = true;
                this.aiEnabled = true;
                this.toggleAutoBtn.textContent = '停止自动战斗';
                // 如果游戏已经开始，立即开始自动战斗
                if (!this.placementPhase) {
                    this.startAutoBattle();
                }
                break;
        }
        
        this.updateUI();
    }
}

// 启动游戏
document.addEventListener('DOMContentLoaded', () => {
    new Game();
}); 
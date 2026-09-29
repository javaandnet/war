// AI类 - 自动移动和攻击
class AI {
    constructor(battlefield, player) {
        this.battlefield = battlefield;
        this.player = player;
        this.difficulty = 'medium'; // 'easy', 'medium', 'hard'
    }
    
    // 执行AI回合
    executeTurn() {
        const units = this.battlefield.getPlayerUnits(this.player);
        // 按照生成顺序行动（数组中的顺序）
        const orderedUnits = [...units];
        
        for (let unit of orderedUnits) {
            if (!unit.isDead && unit.remainingActionPoints > 0) {
                // 使用改进版的行动执行
                this.executeUnitActionsAdvanced(unit);
            }
        }
    }
    
    // 执行单个单位的行动
    executeUnitActions(unit) {
        let actionCount = 0;
        const maxActions = 10; // 防止单个单位无限循环
        
        while (unit.remainingActionPoints > 0 && !unit.isDead && actionCount < maxActions) {
            actionCount++;
            
            // 优先攻击
            if (this.tryAttack(unit)) {
                continue;
            }
            
            // 其次移动
            if (this.tryMove(unit)) {
                continue;
            }
            
            // 如果无法行动，跳出循环
            break;
        }
    }
    
    // 执行单个单位的行动（改进版，支持多次移动）
    executeUnitActionsAdvanced(unit) {
        let actionCount = 0;
        const maxActions = 10; // 防止单个单位无限循环
        
        while (unit.remainingActionPoints > 0 && !unit.isDead && actionCount < maxActions) {
            actionCount++;
            
            // 优先攻击
            if (this.tryAttack(unit)) {
                continue;
            }
            
            // 尝试移动到能攻击敌人的位置
            if (this.tryMoveToAttackPosition(unit)) {
                continue;
            }
            
            // 尝试移动到能包围敌人的位置
            if (this.tryMoveToSurroundPosition(unit)) {
                continue;
            }
            
            // 普通移动
            if (this.tryMove(unit)) {
                continue;
            }
            
            // 如果无法行动，跳出循环
            break;
        }
    }
    
    // 尝试攻击
    tryAttack(unit) {
        const attackableTargets = this.battlefield.getAttackableTargets(unit);
        
        if (attackableTargets.length === 0) {
            return false;
        }
        
        // 选择最佳攻击目标
        const bestTarget = this.selectBestAttackTarget(unit, attackableTargets);
        
        if (bestTarget) {
            const damage = unit.attackTarget(bestTarget);
            if (damage > 0) {
                this.battlefield.cleanupDeadUnits();
                return true;
            }
        }
        
        return false;
    }
    
    // 尝试移动
    tryMove(unit) {
        const movablePositions = this.battlefield.getMovablePositions(unit);
        
        if (movablePositions.length === 0) {
            return false;
        }
        
        // 选择最佳移动位置
        const bestPosition = this.selectBestMovePosition(unit, movablePositions);
        
        if (bestPosition) {
            const success = this.battlefield.moveUnit(unit, bestPosition.x, bestPosition.y);
            return success;
        }
        
        return false;
    }
    
    // 尝试移动到目标位置（支持多次移动）
    tryMoveToTarget(unit, targetX, targetY) {
        const currentDistance = Math.abs(unit.x - targetX) + Math.abs(unit.y - targetY);
        
        if (currentDistance === 0) {
            return true; // 已经在目标位置
        }
        
        if (currentDistance === 1 && unit.remainingActionPoints > 0) {
            // 可以直接移动到目标位置
            return this.battlefield.moveUnit(unit, targetX, targetY);
        }
        
        // 需要多次移动，先移动到目标方向
        const dx = targetX > unit.x ? 1 : targetX < unit.x ? -1 : 0;
        const dy = targetY > unit.y ? 1 : targetY < unit.y ? -1 : 0;
        
        const nextX = unit.x + dx;
        const nextY = unit.y + dy;
        
        if (this.battlefield.isValidPosition(nextX, nextY) && 
            !this.battlefield.hasUnitAt(nextX, nextY) &&
            unit.remainingActionPoints > 0) {
            return this.battlefield.moveUnit(unit, nextX, nextY);
        }
        
        return false;
    }
    
    // 尝试移动到能攻击敌人的位置
    tryMoveToAttackPosition(unit) {
        const enemyUnits = this.battlefield.getAllUnits().filter(u => u.player !== this.player);
        
        for (let enemy of enemyUnits) {
            const distance = unit.getDistance(enemy);
            if (distance <= unit.attackRange) {
                continue; // 已经在攻击范围内
            }
            
            // 计算需要移动的方向
            const dx = enemy.x > unit.x ? 1 : enemy.x < unit.x ? -1 : 0;
            const dy = enemy.y > unit.y ? 1 : enemy.y < unit.y ? -1 : 0;
            
            const targetX = unit.x + dx;
            const targetY = unit.y + dy;
            
            if (this.tryMoveToTarget(unit, targetX, targetY)) {
                return true;
            }
        }
        
        return false;
    }
    
    // 尝试移动到能包围敌人的位置
    tryMoveToSurroundPosition(unit) {
        const enemyUnits = this.battlefield.getAllUnits().filter(u => u.player !== this.player);
        const allyUnits = this.battlefield.getPlayerUnits(this.player);
        
        for (let enemy of enemyUnits) {
            // 检查敌人周围的位置
            const directions = [
                {dx: 0, dy: -1}, {dx: 1, dy: 0}, {dx: 0, dy: 1}, {dx: -1, dy: 0}
            ];
            
            for (let dir of directions) {
                const posX = enemy.x + dir.dx;
                const posY = enemy.y + dir.dy;
                
                // 检查这个位置是否已经有盟友
                let hasAlly = false;
                for (let ally of allyUnits) {
                    if (ally.x === posX && ally.y === posY) {
                        hasAlly = true;
                        break;
                    }
                }
                
                // 如果这个位置没有盟友且可以移动，尝试移动过去
                if (!hasAlly && this.battlefield.isValidPosition(posX, posY) && 
                    !this.battlefield.hasUnitAt(posX, posY)) {
                    if (this.tryMoveToTarget(unit, posX, posY)) {
                        return true;
                    }
                }
            }
        }
        
        return false;
    }
    
    // 选择最佳攻击目标
    selectBestAttackTarget(unit, targets) {
        if (targets.length === 0) return null;
        
        // 根据难度选择策略
        switch (this.difficulty) {
            case 'easy':
                return this.selectRandomTarget(targets);
            case 'medium':
                return this.selectMediumTarget(unit, targets);
            case 'hard':
                return this.selectHardTarget(unit, targets);
            default:
                return this.selectMediumTarget(unit, targets);
        }
    }
    
    // 选择最佳移动位置
    selectBestMovePosition(unit, positions) {
        if (positions.length === 0) return null;
        
        // 根据难度选择策略
        switch (this.difficulty) {
            case 'easy':
                return this.selectRandomPosition(positions);
            case 'medium':
                return this.selectMediumPosition(unit, positions);
            case 'hard':
                return this.selectHardPosition(unit, positions);
            default:
                return this.selectMediumPosition(unit, positions);
        }
    }
    
    // 简单AI - 随机选择
    selectRandomTarget(targets) {
        return targets[Math.floor(Math.random() * targets.length)];
    }
    
    selectRandomPosition(positions) {
        return positions[Math.floor(Math.random() * positions.length)];
    }
    
    // 中等AI - 基于生命值和威胁度
    selectMediumTarget(unit, targets) {
        // 优先攻击生命值低的敌人
        targets.sort((a, b) => {
            const aThreat = this.calculateThreatLevel(a);
            const bThreat = this.calculateThreatLevel(b);
            const aHealth = a.health / a.maxHealth;
            const bHealth = b.health / b.maxHealth;
            
            // 综合考虑威胁度、生命值和包围情况
            const aSurrounding = this.countSurroundingAllies(a);
            const bSurrounding = this.countSurroundingAllies(b);
            
            return (bThreat * 0.6 + (1 - bHealth) * 0.3 + bSurrounding * 0.1) - 
                   (aThreat * 0.6 + (1 - aHealth) * 0.3 + aSurrounding * 0.1);
        });
        
        return targets[0];
    }
    
    selectMediumPosition(unit, positions) {
        // 优先移动到能攻击到敌人的位置
        const enemyUnits = this.battlefield.getAllUnits().filter(u => u.player !== this.player);
        
        if (enemyUnits.length === 0) {
            return this.selectRandomPosition(positions);
        }
        
        // 计算每个位置的价值
        const positionValues = positions.map(pos => {
            let value = 0;
            
            // 检查是否能攻击到敌人
            for (let enemy of enemyUnits) {
                const distance = Math.abs(pos.x - enemy.x) + Math.abs(pos.y - enemy.y);
                if (distance <= unit.attackRange) {
                    value += 10;
                }
            }
            
            // 避免被敌人攻击
            for (let enemy of enemyUnits) {
                const distance = Math.abs(pos.x - enemy.x) + Math.abs(pos.y - enemy.y);
                if (distance <= enemy.attackRange) {
                    value -= 5;
                }
            }
            
            // 包围价值
            const allyUnits = this.battlefield.getPlayerUnits(this.player);
            value += this.calculateSurroundingValue(pos, enemyUnits, allyUnits) * 0.5;
            
            return { position: pos, value: value };
        });
        
        // 选择价值最高的位置
        positionValues.sort((a, b) => b.value - a.value);
        return positionValues[0].position;
    }
    
    // 困难AI - 更复杂的策略
    selectHardTarget(unit, targets) {
        // 计算每个目标的价值
        const targetValues = targets.map(target => {
            let value = 0;
            
            // 基础伤害价值
            const potentialDamage = Math.max(1, unit.attack - target.defense);
            value += potentialDamage * 2;
            
            // 击杀价值（如果攻击能杀死目标）
            if (target.health <= potentialDamage) {
                value += 50;
            }
            
            // 威胁度价值
            value += this.calculateThreatLevel(target) * 10;
            
            // 生命值价值（优先攻击低生命值）
            value += (1 - target.health / target.maxHealth) * 20;
            
            // 包围价值 - 如果目标已经被包围，增加攻击价值
            const surroundingAllies = this.countSurroundingAllies(target);
            value += surroundingAllies * 15;
            
            return { target: target, value: value };
        });
        
        targetValues.sort((a, b) => b.value - a.value);
        return targetValues[0].target;
    }
    
    selectHardPosition(unit, positions) {
        const enemyUnits = this.battlefield.getAllUnits().filter(u => u.player !== this.player);
        const allyUnits = this.battlefield.getPlayerUnits(this.player);
        
        if (enemyUnits.length === 0) {
            return this.selectRandomPosition(positions);
        }
        
        const positionValues = positions.map(pos => {
            let value = 0;
            
            // 攻击价值
            for (let enemy of enemyUnits) {
                const distance = Math.abs(pos.x - enemy.x) + Math.abs(pos.y - enemy.y);
                if (distance <= unit.attackRange) {
                    const potentialDamage = Math.max(1, unit.attack - enemy.defense);
                    value += potentialDamage;
                    
                    // 击杀奖励
                    if (enemy.health <= potentialDamage) {
                        value += 30;
                    }
                }
            }
            
            // 防御价值
            for (let enemy of enemyUnits) {
                const distance = Math.abs(pos.x - enemy.x) + Math.abs(pos.y - enemy.y);
                if (distance <= enemy.attackRange) {
                    value -= Math.max(1, enemy.attack - unit.defense);
                }
            }
            
            // 支援价值（靠近盟友）
            for (let ally of allyUnits) {
                if (ally !== unit) {
                    const distance = Math.abs(pos.x - ally.x) + Math.abs(pos.y - ally.y);
                    if (distance <= 2) {
                        value += 2;
                    }
                }
            }
            
            // 包围价值 - 移动到能包围敌人的位置
            value += this.calculateSurroundingValue(pos, enemyUnits, allyUnits);
            
            // 位置价值（避免被包围）
            let adjacentEnemies = 0;
            for (let enemy of enemyUnits) {
                const distance = Math.abs(pos.x - enemy.x) + Math.abs(pos.y - enemy.y);
                if (distance === 1) {
                    adjacentEnemies++;
                }
            }
            value -= adjacentEnemies * 5;
            
            return { position: pos, value: value };
        });
        
        positionValues.sort((a, b) => b.value - a.value);
        return positionValues[0].position;
    }
    
    // 计算威胁度
    calculateThreatLevel(unit) {
        let threat = 0;
        
        // 攻击力威胁
        threat += unit.attack * 0.5;
        
        // 攻击范围威胁
        threat += unit.attackRange * 10;
        
        // 移动力威胁
        threat += unit.moveRange * 5;
        
        // 生命值威胁（高生命值更危险）
        threat += (unit.health / unit.maxHealth) * 20;
        
        return threat;
    }
    
    // 计算包围价值
    calculateSurroundingValue(position, enemyUnits, allyUnits) {
        let value = 0;
        
        for (let enemy of enemyUnits) {
            const distance = Math.abs(position.x - enemy.x) + Math.abs(position.y - enemy.y);
            
            if (distance === 1) { // 相邻位置
                // 计算这个敌人周围有多少盟友
                let surroundingAllies = 0;
                for (let ally of allyUnits) {
                    if (ally !== this.unit) {
                        const allyDistance = Math.abs(ally.x - enemy.x) + Math.abs(ally.y - enemy.y);
                        if (allyDistance === 1) {
                            surroundingAllies++;
                        }
                    }
                }
                
                // 如果移动到这里会增加包围效果
                if (surroundingAllies > 0) {
                    value += surroundingAllies * 10;
                }
                
                // 特别奖励完全包围（4个方向）
                if (surroundingAllies >= 3) {
                    value += 50;
                }
            }
        }
        
        return value;
    }
    
    // 计算目标周围的盟友数量
    countSurroundingAllies(target) {
        const allyUnits = this.battlefield.getPlayerUnits(this.player);
        let count = 0;
        
        for (let ally of allyUnits) {
            const distance = Math.abs(ally.x - target.x) + Math.abs(ally.y - target.y);
            if (distance === 1) {
                count++;
            }
        }
        
        return count;
    }
    
    // 设置AI难度
    setDifficulty(difficulty) {
        this.difficulty = difficulty;
    }
    
    // 数组随机排序
    shuffleArray(array) {
        for (let i = array.length - 1; i > 0; i--) {
            const j = Math.floor(Math.random() * (i + 1));
            [array[i], array[j]] = [array[j], array[i]];
        }
        return array;
    }
    
    // 获取AI信息
    getInfo() {
        return {
            player: this.player,
            difficulty: this.difficulty,
            unitCount: this.battlefield.getPlayerUnits(this.player).length
        };
    }
} 
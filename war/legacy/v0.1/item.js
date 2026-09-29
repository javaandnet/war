// 兵种基类
class Unit {
    constructor(type, player, x, y) {
        this.type = type;
        this.player = player; // 1 或 2
        this.x = x;
        this.y = y;
        this.maxHealth = 0;
        this.health = 0;
        this.attack = 0;
        this.defense = 0;
        this.attackRange = 1;
        this.moveRange = 1;
        this.actionPoints = 0; // 行动力属性
        this.remainingActionPoints = 0; // 剩余行动力
        this.isDead = false;
        
        this.initializeStats();
    }
    
    initializeStats() {
        switch(this.type) {
            case 'infantry':
                this.maxHealth = 100;
                this.health = 100;
                this.attack = 30;
                this.defense = 20;
                this.attackRange = 1;
                this.moveRange = 1;
                this.actionPoints = 1;
                this.remainingActionPoints = 1;
                this.symbol = '步';
                break;
            case 'cavalry':
                this.maxHealth = 80;
                this.health = 80;
                this.attack = 40;
                this.defense = 15;
                this.attackRange = 1;
                this.moveRange = 1;
                this.actionPoints = 2;
                this.remainingActionPoints = 2;
                this.symbol = '骑';
                break;
            case 'archer':
                this.maxHealth = 60;
                this.health = 60;
                this.attack = 35;
                this.defense = 10;
                this.attackRange = 2;
                this.moveRange = 1;
                this.actionPoints = 1;
                this.remainingActionPoints = 1;
                this.symbol = '弓';
                break;
        }
    }
    
    // 重置回合行动次数
    resetActions() {
        this.remainingActionPoints = this.actionPoints;
    }
    
    // 移动单位
    move(newX, newY) {
        if (this.remainingActionPoints > 0) {
            // 检查移动距离是否为1格
            const distance = Math.abs(this.x - newX) + Math.abs(this.y - newY);
            if (distance === 1) {
                this.x = newX;
                this.y = newY;
                this.remainingActionPoints--;
                return true;
            }
        }
        return false;
    }
    
    // 攻击目标
    attackTarget(target) {
        if (this.remainingActionPoints > 0 && !this.isDead && !target.isDead) {
            const distance = this.getDistance(target);
            if (distance <= this.attackRange) {
                const damage = Math.max(1, this.attack - target.defense);
                target.takeDamage(damage);
                this.remainingActionPoints--;
                return damage;
            }
        }
        return 0;
    }
    
    // 受到伤害
    takeDamage(damage) {
        this.health = Math.max(0, this.health - damage);
        if (this.health <= 0) {
            this.isDead = true;
        }
    }
    
    // 计算与目标的距离
    getDistance(target) {
        return Math.abs(this.x - target.x) + Math.abs(this.y - target.y);
    }
    
    // 检查是否可以攻击目标
    canAttack(target) {
        if (this.isDead || target.isDead || this.player === target.player) {
            return false;
        }
        const distance = this.getDistance(target);
        return distance <= this.attackRange;
    }
    
    // 检查是否可以移动到指定位置
    canMoveTo(x, y, battlefield) {
        if (this.isDead || this.remainingActionPoints === 0) {
            return false;
        }
        
        const distance = Math.abs(this.x - x) + Math.abs(this.y - y);
        if (distance !== 1) {
            return false;
        }
        
        // 检查目标位置是否为空
        return !battlefield.hasUnitAt(x, y);
    }
    
    // 获取可移动的位置
    getMovablePositions(battlefield) {
        const positions = [];
        // 只检查上下左右四个方向
        const directions = [
            {dx: 0, dy: -1}, // 上
            {dx: 1, dy: 0},  // 右
            {dx: 0, dy: 1},  // 下
            {dx: -1, dy: 0}  // 左
        ];
        
        for (let dir of directions) {
            const newX = this.x + dir.dx;
            const newY = this.y + dir.dy;
            
            if (battlefield.isValidPosition(newX, newY) &&
                this.canMoveTo(newX, newY, battlefield)) {
                positions.push({x: newX, y: newY});
            }
        }
        
        return positions;
    }
    
    // 获取可攻击的目标
    getAttackableTargets(battlefield) {
        const targets = [];
        const units = battlefield.getAllUnits();
        
        for (let unit of units) {
            if (this.canAttack(unit)) {
                targets.push(unit);
            }
        }
        
        return targets;
    }
    
    // 获取单位信息
    getInfo() {
        return {
            type: this.type,
            player: this.player,
            health: this.health,
            maxHealth: this.maxHealth,
            attack: this.attack,
            defense: this.defense,
            attackRange: this.attackRange,
            moveRange: this.moveRange,
            remainingActionPoints: this.remainingActionPoints,
            isDead: this.isDead,
            symbol: this.symbol
        };
    }
    
    // 获取显示名称
    getDisplayName() {
        const playerNames = ['', '玩家1', '玩家2'];
        const typeNames = {
            'infantry': '步兵',
            'cavalry': '骑兵',
            'archer': '弓兵'
        };
        return `${playerNames[this.player]} ${typeNames[this.type]}`;
    }
} 
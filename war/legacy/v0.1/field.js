// 战场类
class Battlefield {
    constructor(width = 20, height = 20) {
        this.width = width;
        this.height = height;
        this.units = []; // 存储所有单位
        this.grid = []; // 存储网格状态
        
        this.initializeGrid();
    }
    
    // 初始化网格
    initializeGrid() {
        this.grid = [];
        for (let y = 0; y < this.height; y++) {
            this.grid[y] = [];
            for (let x = 0; x < this.width; x++) {
                this.grid[y][x] = null; // null 表示空位置
            }
        }
    }
    
    // 检查位置是否有效
    isValidPosition(x, y) {
        return x >= 0 && x < this.width && y >= 0 && y < this.height;
    }
    
    // 检查指定位置是否有单位
    hasUnitAt(x, y) {
        if (!this.isValidPosition(x, y)) {
            return false;
        }
        return this.grid[y][x] !== null;
    }
    
    // 获取指定位置的单位
    getUnitAt(x, y) {
        if (!this.isValidPosition(x, y)) {
            return null;
        }
        return this.grid[y][x];
    }
    
    // 添加单位到战场
    addUnit(unit) {
        if (this.isValidPosition(unit.x, unit.y) && !this.hasUnitAt(unit.x, unit.y)) {
            this.units.push(unit);
            this.grid[unit.y][unit.x] = unit;
            return true;
        }
        return false;
    }
    
    // 移除单位
    removeUnit(unit) {
        const index = this.units.indexOf(unit);
        if (index > -1) {
            this.units.splice(index, 1);
            this.grid[unit.y][unit.x] = null;
            return true;
        }
        return false;
    }
    
    // 移动单位
    moveUnit(unit, newX, newY) {
        if (this.isValidPosition(newX, newY) && !this.hasUnitAt(newX, newY)) {
            // 清除原位置
            this.grid[unit.y][unit.x] = null;
            
            // 更新单位位置
            unit.x = newX;
            unit.y = newY;
            
            // 设置新位置
            this.grid[newY][newX] = unit;
            
            return true;
        }
        return false;
    }
    
    // 获取所有单位
    getAllUnits() {
        return this.units.filter(unit => !unit.isDead);
    }
    
    // 获取指定玩家的所有单位
    getPlayerUnits(player) {
        return this.units.filter(unit => unit.player === player && !unit.isDead);
    }
    
    // 获取指定玩家的存活单位数量
    getPlayerUnitCount(player) {
        return this.getPlayerUnits(player).length;
    }
    
    // 检查游戏是否结束
    isGameOver() {
        const player1Units = this.getPlayerUnitCount(1);
        const player2Units = this.getPlayerUnitCount(2);
        
        return player1Units === 0 || player2Units === 0;
    }
    
    // 获取获胜玩家
    getWinner() {
        if (!this.isGameOver()) {
            return null;
        }
        
        const player1Units = this.getPlayerUnitCount(1);
        const player2Units = this.getPlayerUnitCount(2);
        
        if (player1Units === 0) {
            return 2;
        } else if (player2Units === 0) {
            return 1;
        }
        
        return null;
    }
    
    // 清理死亡单位
    cleanupDeadUnits() {
        this.units = this.units.filter(unit => !unit.isDead);
        // 重新构建网格
        this.initializeGrid();
        for (let unit of this.units) {
            this.grid[unit.y][unit.x] = unit;
        }
    }
    
    // 重置所有单位的行动次数
    resetAllActions() {
        for (let unit of this.units) {
            unit.resetActions();
        }
    }
    
    // 获取可移动位置（用于高亮显示）
    getMovablePositions(unit) {
        if (!unit || unit.isDead) {
            return [];
        }
        
        return unit.getMovablePositions(this);
    }
    
    // 获取可攻击目标（用于高亮显示）
    getAttackableTargets(unit) {
        if (!unit || unit.isDead) {
            return [];
        }
        
        return unit.getAttackableTargets(this);
    }
    
    // 检查单位是否在指定位置
    isUnitAtPosition(unit, x, y) {
        return unit && unit.x === x && unit.y === y;
    }
    
    // 获取战场状态信息
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
    
    // 清空战场
    clear() {
        this.units = [];
        this.initializeGrid();
    }
    
    // 设置默认布局（用于新游戏）
    setDefaultLayout() {
        this.clear();
        
        // 玩家1的单位（左侧）
        this.addUnit(new Unit('infantry', 1, 2, 2));
        this.addUnit(new Unit('infantry', 1, 2, 4));
        this.addUnit(new Unit('infantry', 1, 2, 6));
        this.addUnit(new Unit('cavalry', 1, 2, 8));
        this.addUnit(new Unit('cavalry', 1, 2, 10));
        this.addUnit(new Unit('archer', 1, 2, 12));
        this.addUnit(new Unit('archer', 1, 2, 14));
        this.addUnit(new Unit('infantry', 1, 4, 3));
        this.addUnit(new Unit('cavalry', 1, 4, 7));
        this.addUnit(new Unit('archer', 1, 4, 11));
        
        // 玩家2的单位（右侧）
        this.addUnit(new Unit('infantry', 2, 17, 5));
        this.addUnit(new Unit('infantry', 2, 17, 7));
        this.addUnit(new Unit('infantry', 2, 17, 9));
        this.addUnit(new Unit('cavalry', 2, 17, 11));
        this.addUnit(new Unit('cavalry', 2, 17, 13));
        this.addUnit(new Unit('archer', 2, 17, 15));
        this.addUnit(new Unit('archer', 2, 17, 17));
        this.addUnit(new Unit('infantry', 2, 15, 6));
        this.addUnit(new Unit('cavalry', 2, 15, 10));
        this.addUnit(new Unit('archer', 2, 15, 14));
    }
} 
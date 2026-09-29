/**
 * 兵种单位（纯状态对象）
 *
 * 与旧版的关键差异（P0 修复）：
 * 1. 单位不再自己改坐标。旧版 Unit.move() 改坐标并扣行动力，却不更新 battlefield.grid，
 *    而 Battlefield.moveUnit() 更新 grid 却不扣行动力 —— 两条写路径各缺一半，
 *    实际生效的那条不扣点数，等于移动免费。现在坐标与 grid 的唯一写入者是 Battlefield。
 * 2. 统一 AP 池拆成 moveBudget / attackBudget 两个独立预算，
 *    "弓兵走过一格就再也打不了箭"这类伪约束消失。
 * 3. 伤害计算做成纯函数 damageTo()，AI 可以在不改变状态的前提下预估。
 */
class Unit {
    constructor(type, player, x, y, id = null) {
        const stats = WarConfig.unitTypes[type];
        if (!stats) {
            throw new Error(`未知兵种: ${type}`);
        }

        this.id = id;
        this.type = type;
        this.player = player;          // 1 或 2
        this.x = x;
        this.y = y;

        this.maxHealth = stats.maxHealth;
        this.health = stats.maxHealth;
        this.attack = stats.attack;
        this.defense = stats.defense;
        this.attackRange = stats.attackRange;
        this.moveBudget = stats.moveBudget;
        this.attackBudget = stats.attackBudget;
        this.counterAttack = stats.counterAttack;
        this.aiValue = stats.aiValue;
        this.symbol = stats.symbol;
        this.name = stats.name;

        // 本回合剩余配额
        this.remainingMove = this.moveBudget;
        this.remainingAttacks = this.attackBudget;

        this.isDead = false;
        /** 本回合是否已经因反击出手过（反击不占用攻击配额，但一回合只反击一次） */
        this.hasCountered = false;
    }

    // ---------------------------------------------------------------- 位置

    get pos() {
        return { x: this.x, y: this.y };
    }

    distanceTo(other) {
        return Math.abs(this.x - other.x) + Math.abs(this.y - other.y);
    }

    static distance(ax, ay, bx, by) {
        return Math.abs(ax - bx) + Math.abs(ay - by);
    }

    /** 该单位能否站在某格（不含机动点检查，地形与占位由 Battlefield 判定） */
    isAlive() {
        return !this.isDead;
    }

    // ---------------------------------------------------------------- 配额

    resetTurn() {
        this.remainingMove = this.moveBudget;
        this.remainingAttacks = this.attackBudget;
        this.hasCountered = false;
    }

    canMove() {
        return !this.isDead && this.remainingMove > 0;
    }

    canAttackAgain() {
        return !this.isDead && this.remainingAttacks > 0;
    }

    /** 供 UI 显示的"已行动"判定：机动与攻击都用尽 */
    isExhausted() {
        return this.remainingMove <= 0 && this.remainingAttacks <= 0;
    }

    // ---------------------------------------------------------------- 结算（纯函数）

    /** 目标在给定地形防御加成下，本单位一次攻击的期望伤害 */
    damageTo(target, targetTerrainDefBonus = 0) {
        const def = target.effectiveDefense(targetTerrainDefBonus);
        return Math.max(1, this.attack - def);
    }

    effectiveDefense(terrainDefBonus = 0) {
        return this.defense + terrainDefBonus;
    }

    /** 是否能攻击目标：只判定敌我 / 存活 / 距离 / 配额，视线与占位由 Battlefield 判定 */
    canAttack(target) {
        if (this.isDead || !target || target.isDead) return false;
        if (this.player === target.player) return false;
        if (this.remainingAttacks <= 0) return false;
        return this.distanceTo(target) <= this.attackRange;
    }

    /** 受到伤害，返回实际扣血量。唯一改 blood 的入口，便于将来接治疗/buff */
    takeDamage(amount) {
        const applied = Math.min(this.health, Math.max(0, amount));
        this.health -= applied;
        if (this.health <= 0) {
            this.health = 0;
            this.isDead = true;
        }
        return applied;
    }

    /** 反击资格：近战兵种、存活、未反击过、且攻击者在自己的射程内 */
    canCounter(attacker) {
        if (!this.counterAttack) return false;
        if (this.isDead || this.hasCountered) return false;
        return this.distanceTo(attacker) <= this.attackRange;
    }

    // ---------------------------------------------------------------- 序列化

    toState() {
        return {
            id: this.id,
            type: this.type,
            player: this.player,
            x: this.x,
            y: this.y,
            health: this.health,
            remainingMove: this.remainingMove,
            remainingAttacks: this.remainingAttacks,
            isDead: this.isDead,
            hasCountered: this.hasCountered
        };
    }

    restoreState(s) {
        this.x = s.x;
        this.y = s.y;
        this.health = s.health;
        this.remainingMove = s.remainingMove;
        this.remainingAttacks = s.remainingAttacks;
        this.isDead = s.isDead;
        this.hasCountered = s.hasCountered;
    }

    getInfo() {
        return {
            id: this.id,
            type: this.type,
            player: this.player,
            health: this.health,
            maxHealth: this.maxHealth,
            attack: this.attack,
            defense: this.defense,
            attackRange: this.attackRange,
            moveBudget: this.moveBudget,
            remainingMove: this.remainingMove,
            remainingAttacks: this.remainingAttacks,
            isDead: this.isDead,
            symbol: this.symbol
        };
    }

    getDisplayName() {
        return `玩家${this.player} ${this.name}`;
    }
}

// Node 测试下暴露给 loader（浏览器里 class 声明本身就是全局词法绑定）
if (typeof module !== 'undefined' && module.exports) {
    module.exports = Unit;
}

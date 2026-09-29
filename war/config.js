/**
 * 全局配置：棋盘 / 地形 / 兵种 / 难度旋钮 / 评分权重
 *
 * 设计原则（对应本次修复）：
 * 1. 所有数值只在这里出现一次，AI 与规则层不再各写一份，避免"三套难度 = 三份算法"。
 * 2. 难度不再是"换一套打分逻辑"，而是同一打分逻辑下的三个正交旋钮：
 *      vision      —— 信息（能看见多远，模拟不看小地图的玩家）
 *      temperature —— 随机度（softmax 温度，越大越容易犯错）
 *      lookahead   —— 前瞻（0/1/2 步推演）
 * 3. 棋盘尺寸集中定义。原 README 写 16*16、Game 构造写 20*20 的规格漂移在此收敛。
 */
const WarConfig = {
    board: {
        width: 20,
        height: 20
    },

    /** 地形：机动消耗 + 防御加成。impassable 的格子单位不可进入也不会被算进可达域 */
    terrain: {
        plain:   { key: 'plain',   name: '平原', symbol: '', defBonus: 0,  moveCost: 1, impassable: false, css: '' },
        forest:  { key: 'forest',  name: '森林', symbol: '♣', defBonus: 12, moveCost: 2, impassable: false, css: 'terrain-forest' },
        hill:    { key: 'hill',    name: '山地', symbol: '▲', defBonus: 20, moveCost: 3, impassable: false, css: 'terrain-hill' },
        water:   { key: 'water',   name: '河流', symbol: '≈', defBonus: 0,  moveCost: 1, impassable: true,  css: 'terrain-water' },
        wall:    { key: 'wall',    name: '岩壁', symbol: '■', defBonus: 0,  moveCost: 1, impassable: true,  css: 'terrain-wall' }
    },

    /**
     * 兵种。行动配额拆成两个独立预算（原实为统一 AP 池，导致"移动不扣点数"与
     * "弓兵走了就不能打"两类问题）：
     *   moveBudget   每回合机动点，按地形 moveCost 累加扣除
     *   attackBudget 每回合可攻击次数，攻击不消耗机动点
     */
    unitTypes: {
        infantry: {
            type: 'infantry', name: '步兵', symbol: '步',
            maxHealth: 100, attack: 40, defense: 12,
            attackRange: 1, moveBudget: 4, attackBudget: 1,
            counterAttack: true,   // 近战反击
            aiValue: 1.00          // 目标价值基线（越有价值的兵种越值得优先消灭）
        },
        cavalry: {
            type: 'cavalry', name: '骑兵', symbol: '骑',
            maxHealth: 90, attack: 50, defense: 10,
            attackRange: 1, moveBudget: 7, attackBudget: 1,
            counterAttack: true,
            aiValue: 1.15
        },
        archer: {
            type: 'archer', name: '弓兵', symbol: '弓',
            maxHealth: 60, attack: 45, defense: 6,
            attackRange: 2, moveBudget: 4, attackBudget: 1,
            counterAttack: false,  // 被近身不反击
            aiValue: 1.35
        }
    },

    /** 难度旋钮：同一套评分函数，只差这三个维度 */
    difficulty: {
        easy:      { label: '简单', temperature: 0.90, lookahead: 0, vision: 5,  noise: 0.35, sampleEnemies: 4 },
        normal:    { label: '普通', temperature: 0.35, lookahead: 0, vision: 9,  noise: 0.10, sampleEnemies: 6 },
        hard:      { label: '困难', temperature: 0.10, lookahead: 1, vision: Infinity, noise: 0.00, sampleEnemies: 8 },
        nightmare: { label: '噩梦', temperature: 0.02, lookahead: 2, vision: Infinity, noise: 0.00, sampleEnemies: 10 }
    },

    /**
     * 效用评分权重。每一项在归一化到 [0,1] 之后再乘权重，
     * 因此不存在"某项数量级压倒另一项"的量纲问题（原 medium 难度的病灶）。
     */
    weights: {
        damage:      100,   // 期望伤害
        kill:         80,   // 致死额外奖励
        overkill:    -45,   // 伤害远超目标剩余血量 = 浪费
        targetValue:  38,   // 兵种价值 + 残血补刀
        exposure:    -62,   // 落入敌方威胁区的风险（来自影响图）
        terrain:      22,   // 站位地形防御加成
        focus:        30,   // 集火协同：本回合已被队友锁定的目标
        counter:     -30,   // 预期反击伤害
        mobility:     14,   // 保留机动力（不为挪一格花光预算）
        objective:    18,   // 战略牵引：向本轮战略指定的区域推进
        support:      10,   // 与友邻保持互相支援的距离
        waste:       -18,   // 本回合什么都不做的惩罚
        followup:     26    // 前瞻推演得到的局势增减（lookahead > 0 时生效）
    },

    /** 归一化标尺：把不同量纲的原始值映射到 [0,1] */
    scale: {
        damageRef: 50,        // 参考伤害，约等于一次重击
        threatRef: 60,        // 参考威胁值（影响图单格累计期望伤害）
        moveBudgetRef: 7,     // 最大兵种机动点
        terrainDefRef: 20,    // 最大地形防御加成
        supportRadius: 4,     // 支援距离
        objectiveDecay: 12    // 距目标区域多远开始失去牵引分
    },

    /** 战场布局与回合上限 */
    deployment: {
        maxPerSide: 10,
        maxTurns: 100
    },

    /** 每方编成模板（自动布阵与测试 fixture 共用） */
    defaultRoster: ['infantry', 'infantry', 'infantry', 'cavalry', 'cavalry', 'cavalry', 'archer', 'archer', 'archer', 'archer']
};

/**
 * 确定性随机数（mulberry32）。AI 决策与地形生成都必须走这里，
 * 禁止再用 Math.random() —— 否则同一种局面每次结果不同，AI bug 无法复现。
 */
class SeededRng {
    constructor(seed = 1) {
        this.state = (seed >>> 0) || 1;
    }

    next() {
        this.state = (this.state + 0x6D2B79F5) >>> 0;
        let t = this.state;
        t = Math.imul(t ^ (t >>> 15), t | 1);
        t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    }

    /** [0, n) 整数 */
    int(n) {
        return Math.floor(this.next() * n);
    }

    pick(arr) {
        return arr[this.int(arr.length)];
    }

    /** 原地洗牌（Fisher-Yates） */
    shuffle(arr) {
        for (let i = arr.length - 1; i > 0; i--) {
            const j = this.int(i + 1);
            [arr[i], arr[j]] = [arr[j], arr[i]];
        }
        return arr;
    }
}

// 浏览器下挂到 window，Node 测试下由 loader 直接取用
if (typeof window !== 'undefined') {
    window.WarConfig = WarConfig;
    window.SeededRng = SeededRng;
}

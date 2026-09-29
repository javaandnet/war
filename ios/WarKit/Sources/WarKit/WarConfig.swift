import Foundation

/// 数值与规则的唯一权威定义处（对应 JS 原型 config.js）。
/// 调参只改这里：地形、兵种、难度档位、AI 权重全部集中在此。
public enum WarConfig {

    // MARK: - 棋盘（iPhone 竖屏默认 14×14：单格约 26pt，够手指点按）

    public struct BoardSize {
        public let width: Int
        public let height: Int
        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    /// 可选棋盘尺寸（由小到大），Setup 页可切换
    public static let boardSizes: [BoardSize] = [
        BoardSize(width: 10, height: 10),
        BoardSize(width: 14, height: 14),
        BoardSize(width: 18, height: 18),
    ]
    public static let defaultBoard = BoardSize(width: 14, height: 14)

    /// 每方出生区占左侧/右侧各 3 列
    public static let deployColumnCount = 3

    // MARK: - 地形

    public struct Terrain: Sendable {
        public let key: String
        public let name: String
        public let symbol: String
        public let moveCost: Int
        public let defBonus: Int      // 防御加成（%）
        public let impassable: Bool
        public let colorRGB: (red: Double, green: Double, blue: Double)

        public init(key: String, name: String, symbol: String, moveCost: Int,
                    defBonus: Int, impassable: Bool,
                    colorRGB: (red: Double, green: Double, blue: Double)) {
            self.key = key
            self.name = name
            self.symbol = symbol
            self.moveCost = moveCost
            self.defBonus = defBonus
            self.impassable = impassable
            self.colorRGB = colorRGB
        }
    }

    public static let terrains: [String: Terrain] = [
        "plain": Terrain(key: "plain", name: "平原", symbol: "·", moveCost: 1, defBonus: 0,
                         impassable: false, colorRGB: (0.30, 0.42, 0.26)),
        "forest": Terrain(key: "forest", name: "森林", symbol: "#", moveCost: 2, defBonus: 12,
                          impassable: false, colorRGB: (0.13, 0.31, 0.17)),
        "hill": Terrain(key: "hill", name: "山地", symbol: "^", moveCost: 3, defBonus: 20,
                        impassable: false, colorRGB: (0.40, 0.33, 0.22)),
        "water": Terrain(key: "water", name: "河流", symbol: "~", moveCost: 99, defBonus: 0,
                         impassable: true, colorRGB: (0.14, 0.27, 0.44)),
        "wall": Terrain(key: "wall", name: "城墙", symbol: "█", moveCost: 99, defBonus: 0,
                        impassable: true, colorRGB: (0.34, 0.34, 0.38)),
    ]
    public static let defaultTerrainKey = "plain"

    /// 地形展示顺序（字典无序，UI 图例需要一个稳定的次序）
    public static let terrainOrder = ["plain", "forest", "hill", "water", "wall"]

    // MARK: - 兵种

    public struct UnitStat: Sendable {
        public let key: String
        public let name: String
        public let symbol: String
        public let hp: Int
        public let atk: Int
        public let def: Int
        public let moveRange: Int
        public let attackRange: Int
        public let counterAttack: Bool   // 能否反击近程攻击
        public let value: Double         // 相对价值（AI 目标选择用）
        /// 首领（斩首胜利与魔法载体的判据，一个阵营只允许一个）
        public let isChief: Bool
        /// 士兵单价（军费布阵用；首领免费，它是必需单位而非可选兵力）
        public let cost: Int

        public init(key: String, name: String, symbol: String, hp: Int, atk: Int, def: Int,
                    moveRange: Int, attackRange: Int, counterAttack: Bool, value: Double,
                    isChief: Bool = false, cost: Int = 0) {
            self.key = key
            self.name = name
            self.symbol = symbol
            self.hp = hp
            self.atk = atk
            self.def = def
            self.moveRange = moveRange
            self.attackRange = attackRange
            self.counterAttack = counterAttack
            self.value = value
            self.isChief = isChief
            self.cost = cost
        }
    }

    public static let unitTypes: [String: UnitStat] = [
        // 步兵：攻守均衡，能反击
        "infantry": UnitStat(key: "infantry", name: "步兵", symbol: "I", hp: 100, atk: 40, def: 12,
                             moveRange: 4, attackRange: 1, counterAttack: true, value: 1.0,
                             cost: 20),
        // 骑兵：高机动高攻，防御薄弱
        "cavalry": UnitStat(key: "cavalry", name: "骑兵", symbol: "C", hp: 90, atk: 50, def: 10,
                            moveRange: 7, attackRange: 1, counterAttack: true, value: 1.15,
                            cost: 30),
        // 弓兵：远程 2 格，不反击 —— 对 AI 来说既是价值也是风险
        "archer": UnitStat(key: "archer", name: "弓兵", symbol: "A", hp: 60, atk: 45, def: 6,
                           moveRange: 4, attackRange: 2, counterAttack: false, value: 1.35,
                           cost: 25),
        // 首领：全军最强，且**只有它能施法**。value 2.5 刻意远高于士兵上限 1.35 ——
        // AI 的 targetValue / materialScore / centerOfMass 全部读这个字段，
        // 于是“集火敌方首领”与“护卫己方首领”不用写新规则就会自然出现。
        "commander": UnitStat(key: "commander", name: "首领", symbol: "M", hp: 160, atk: 50, def: 16,
                              moveRange: 4, attackRange: 1, counterAttack: true, value: 2.5,
                              isChief: true, cost: 0),
    ]

    /// 首领兵种 key（每阵营恰好一名，不占士兵名额）
    public static let chiefTypeKey = "commander"

    /**
     * 兵种档位（“升级兵的质量”）：倍率以纯函数形式施加，
     * 这样 WarUnit 的 maxHp/atk/def 仍是 `let`，快照与 AI 评分都不必改结构。
     */
    public struct TierStats: Sendable {
        public let hp: Double
        public let atk: Double
        public let def: Double
        public let value: Double
        public init(hp: Double, atk: Double, def: Double, value: Double) {
            self.hp = hp; self.atk = atk; self.def = def; self.value = value
        }
    }

    public static let maxTier = 3

    /// 升到该档的费用（下标 0 即 tier1 原价，不收费）
    public static let tierCosts = [0, 80, 140]

    public static let tierStats: [TierStats] = [
        TierStats(hp: 1.00, atk: 1.00, def: 1.00, value: 1.00),
        TierStats(hp: 1.15, atk: 1.15, def: 1.10, value: 1.15),
        TierStats(hp: 1.35, atk: 1.30, def: 1.20, value: 1.35),
    ]

    public static func tierScale(_ tier: Int) -> TierStats {
        tierStats[min(max(tier, 1), maxTier) - 1]
    }

    /// 按档位取实际数值（四舍五入，保证同输入同输出 —— 复现不变式依赖这点）
    public static func unitStat(_ typeKey: String, tier: Int = 1) -> UnitStat? {
        guard let base = unitTypes[typeKey] else { return nil }
        let s = tierScale(tier)
        if s.hp == 1 && s.atk == 1 && s.def == 1 && s.value == 1 { return base }
        return UnitStat(key: base.key, name: base.name, symbol: base.symbol,
                        hp: Int((Double(base.hp) * s.hp).rounded()),
                        atk: Int((Double(base.atk) * s.atk).rounded()),
                        def: Int((Double(base.def) * s.def).rounded()),
                        moveRange: base.moveRange, attackRange: base.attackRange,
                        counterAttack: base.counterAttack,
                        value: base.value * s.value,
                        isChief: base.isChief, cost: base.cost)
    }

    /// 默认布阵（每方 6 个**士兵**，iPhone 小屏节奏更快；首领另算）
    public static let defaultRoster = ["infantry", "infantry", "cavalry", "cavalry", "archer", "archer"]

    /// 兵种展示顺序（布阵选择器用，字典无序）。首领不在其中：它免费且必带。
    public static let unitTypeOrder = ["infantry", "cavalry", "archer"]

    // MARK: - 魔法（只有首领能施放）

    public struct SpellStat: Sendable {
        public enum Effect: String, Sendable {
            case damage    // 直接伤害（中心 + 溅射）
            case heal      // 治疗己方
            case stun      // 冻结：本回合禁行动、禁攻击、禁反击
        }

        public let key: String
        public let name: String
        public let symbol: String      // 取不到图标时的兜底字符
        public let effect: Effect
        public let range: Int
        /// 伤害量 / 治疗量（stun 不用）。伤害是**固定值**：
        /// 魔法不吃防御与地形减伤，否则首领自身 def 16 + 山地 +20 会把火球磨到看不出意义。
        public let power: Int
        /// 溅射伤害（0 = 无溅射）。溅射**只烧敌方**，不损己方与施法者。
        public let splash: Int
        public let splashRadius: Int
        /// 买断解锁（跨局永久，一次付费以后可携带）
        public let unlockCost: Int
        /// 每发充能（本局消耗，开局前在布阵页买）
        public let chargeCost: Int

        public init(key: String, name: String, symbol: String, effect: Effect, range: Int,
                    power: Int, splash: Int, splashRadius: Int, unlockCost: Int, chargeCost: Int) {
            self.key = key
            self.name = name
            self.symbol = symbol
            self.effect = effect
            self.range = range
            self.power = power
            self.splash = splash
            self.splashRadius = splashRadius
            self.unlockCost = unlockCost
            self.chargeCost = chargeCost
        }
    }

    public static let spells: [String: SpellStat] = [
        "fireball": SpellStat(key: "fireball", name: "火球", symbol: "*", effect: .damage,
                              range: 3, power: 60, splash: 25, splashRadius: 1,
                              unlockCost: 60, chargeCost: 20),
        "heal": SpellStat(key: "heal", name: "治疗", symbol: "+", effect: .heal,
                          range: 2, power: 45, splash: 0, splashRadius: 0,
                          unlockCost: 45, chargeCost: 15),
        "freeze": SpellStat(key: "freeze", name: "冰冻", symbol: "=", effect: .stun,
                            range: 3, power: 0, splash: 0, splashRadius: 0,
                            unlockCost: 70, chargeCost: 25),
    ]

    /// 魔法展示顺序（字典无序，商店页需要稳定次序）
    public static let spellOrder = ["fireball", "heal", "freeze"]

    /// 首领每回合可施法次数（与普攻互斥：一回合一个动作）
    public static let maxSpellsPerTurn = 1

    // MARK: - 回合规则

    /// 单回合行动配额：火焰纹章式"移动 1 次 + 攻击 1 次"，
    /// 而不是统一 AP 池（AP 池会导致移动/攻击互相白嫖）。
    public static let maxAttacksPerTurn = 1
    /// 每方士兵上限（**不含**首领）
    public static let soldiersPerSide = 6
    /// 每方单位总上限 = 士兵 + 1 名首领
    public static let maxUnitsPerSide = soldiersPerSide + 1
    public static let maxTurns = 50

    // MARK: - AI 难度（一套评分 + 四个正交旋钮：温度 / 前瞻 / 视野 / 军费）

    public struct Difficulty: Sendable {
        public let key: String
        public let name: String
        public let temperature: Double   // softmax 随机度：越大越"手软"
        public let lookahead: Int        // 前瞻 rollout 层数：0 = 只看即时收益
        public let vision: Int           // AI 能"看清"的敌方单位数：越小越盲
        public let noise: Double         // 命中随机波动幅度
        /// 本局军费（只交给 `ArmyComposer` 花）：数值强度走钱，
        /// 不走"偷偷把兵种数值改大"，所以 AI 用的都是与玩家同价同档的兵。
        public let budget: Int

        public init(key: String, name: String, temperature: Double, lookahead: Int,
                    vision: Int, noise: Double, budget: Int) {
            self.key = key
            self.name = name
            self.temperature = temperature
            self.lookahead = lookahead
            self.vision = vision
            self.noise = noise
            self.budget = budget
        }
    }

    public static let difficulties: [String: Difficulty] = [
        "easy": Difficulty(key: "easy", name: "简单", temperature: 0.90, lookahead: 0, vision: 5, noise: 0.15, budget: 40),
        "normal": Difficulty(key: "normal", name: "普通", temperature: 0.35, lookahead: 0, vision: 9, noise: 0.08, budget: 90),
        "hard": Difficulty(key: "hard", name: "困难", temperature: 0.10, lookahead: 1, vision: .max, noise: 0.04, budget: 140),
        "nightmare": Difficulty(key: "nightmare", name: "噩梦", temperature: 0.02, lookahead: 2, vision: .max, noise: 0.0, budget: 200),
    ]
    public static let defaultDifficultyKey = "normal"

    /// 难度展示顺序（由弱到强，字典无序）
    public static let difficultyOrder = ["easy", "normal", "hard", "nightmare"]

    // MARK: - 评分权重（分项均已归一化到 [0,1]，权重即最终贡献上限）

    public struct Weights: Sendable {
        public let damage: Double
        public let kill: Double
        public let overkill: Double
        public let selfPreserve: Double
        public let targetValue: Double
        public let exposure: Double
        public let terrain: Double
        public let focus: Double
        public let counterRisk: Double
        public let mobility: Double
        public let surround: Double
        public let objective: Double
        public let support: Double
        public let waste: Double
        public let rangePenalty: Double    // 远程单位贴脸惩罚
        public let engage: Double
        public let proximity: Double
        /// 斩首赏金：攻击敌方首领的额外倾向。首领 value 高于归一化参考值，
        /// 靠 `scale.valueRef` 钳到 1 之后单独用这一项拉高优先级 ——
        /// 既不破坏“分项∈[0,1]”的约定，士兵之间的相对分序也不受影响。
        public let chiefBounty: Double
        /// 治疗收益（按「救回来的血量占最大血量的比例」计分）
        public let heal: Double
        /// 冰冻收益（封住一个能行动敌人的回合，按目标价值折算）
        public let freeze: Double

        public init(damage: Double, kill: Double, overkill: Double, selfPreserve: Double,
                    targetValue: Double, exposure: Double, terrain: Double, focus: Double,
                    counterRisk: Double, mobility: Double, surround: Double, objective: Double,
                    support: Double, waste: Double, rangePenalty: Double,
                    engage: Double, proximity: Double, chiefBounty: Double,
                    heal: Double, freeze: Double) {
            self.damage = damage
            self.kill = kill
            self.overkill = overkill
            self.selfPreserve = selfPreserve
            self.targetValue = targetValue
            self.exposure = exposure
            self.terrain = terrain
            self.focus = focus
            self.counterRisk = counterRisk
            self.mobility = mobility
            self.surround = surround
            self.objective = objective
            self.support = support
            self.waste = waste
            self.rangePenalty = rangePenalty
            self.engage = engage
            self.proximity = proximity
            self.chiefBounty = chiefBounty
            self.heal = heal
            self.freeze = freeze
        }
    }

    public static let weights = Weights(
        damage: 100,          // 本次攻击造成的伤害
        kill: 80,             // 击杀奖励（一击必杀）
        overkill: -45,        // 溢出伤害惩罚：反"集火残血浪费"
        selfPreserve: -55,    // 自身存活价值（hp 越低越保守）
        targetValue: 22,      // 目标兵种战略价值
        exposure: -34,        // 落点后下回合被敌方威胁打击的概率
                              // （不能压过推进收益：实测 -62 会让双方均在威胁边界互相绕行、永不接战）
        terrain: 20,          // 落点地形防御加成
        focus: 28,            // 集火同一目标
        counterRisk: -26,     // 会被反击的风险
        mobility: 18,         // 保留机动力（反击窗口 + 走位余地）
        surround: 16,         // 与友军合围同一目标
        objective: 30,        // 向战略目标重心靠拢
        support: 14,          // 保护濒危友军
        waste: -50,           // 浪费行动配额（有目标却不打 / 机动全废）
        rangePenalty: -30,    // 远程单位贴脸输出
        engage: 30,           // 无目标时的推进意愿（本步拉近了多少）
        proximity: 48,        // 无目标时向敌情靠近（绝对距离，反僵持主力项）
        chiefBounty: 35,      // 斩首赏金：能打到敌方首领时的额外加分（≈ 1.6 个 targetValue）
        // 两个魔法项刻意低于 kill: 80 —— 再高就会让 AI 放弃到手的击杀去施法
        heal: 18,             // 治疗：救回的血不值一个击杀，只是顺手补一口
        freeze: 30            // 冰冻：封掉敌人一回合，比一次中等伤害略值
    )

    /// 归一化标尺：把不同量纲的分项统一到 [0,1]
    public struct Scale: Sendable {
        public let damageRef: Int          // 参考伤害（约等于一次重击）
        public let threatSaturation: Double
        public let moveBudgetRef: Int      // 最大机动点（机动力保留度的分母）
        public let maxDefBonus: Int
        public let exposureDecay: Double
        public let objectiveGain: Double
        public let supportHpThreshold: Int
        public let surroundUnit: Double
        public let maxNoise: Double
        /// 兵种价值的归一化参考（= 普通兵种上限）；首领 value 高于它，
        /// 分项会被钳到 1.0，多出来的分量由 `weights.chiefBounty` 表达。
        public let valueRef: Double

        public init(damageRef: Int, threatSaturation: Double, moveBudgetRef: Int,
                    maxDefBonus: Int, exposureDecay: Double,
                    objectiveGain: Double, supportHpThreshold: Int, surroundUnit: Double,
                    maxNoise: Double, valueRef: Double) {
            self.damageRef = damageRef
            self.threatSaturation = threatSaturation
            self.moveBudgetRef = moveBudgetRef
            self.maxDefBonus = maxDefBonus
            self.exposureDecay = exposureDecay
            self.objectiveGain = objectiveGain
            self.supportHpThreshold = supportHpThreshold
            self.surroundUnit = surroundUnit
            self.maxNoise = maxNoise
            self.valueRef = valueRef
        }
    }

    public static let scale = Scale(
        damageRef: 50,
        threatSaturation: 60,
        moveBudgetRef: 7,
        maxDefBonus: 20,
        exposureDecay: 0.08,
        objectiveGain: 0.20,
        supportHpThreshold: 40,
        surroundUnit: 0.5,
        maxNoise: 0.15,
        valueRef: 1.35
    )
}

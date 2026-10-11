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
        /// 只能由转职得到的分支兵种（不在 `unitTypeOrder` 里，因此军费买不到）
        public let promotable: Bool

        public init(key: String, name: String, symbol: String, hp: Int, atk: Int, def: Int,
                    moveRange: Int, attackRange: Int, counterAttack: Bool, value: Double,
                    isChief: Bool = false, cost: Int = 0, promotable: Bool = false) {
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
            self.promotable = promotable
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
        // ── 以下 8 个是**转职分支**（`promotable: true`、`cost: 0`）：只能由 10 级转职得到，
        //    军费买不到（不在 `unitTypeOrder` 里、cost 0 也让 `upgradeCost` 直接拒卖）。
        //    数值刻意与基础兵种拉开量级：一条重生存、一条重输出/机动。
        // 近卫：步兵的盾墙（HP/防最高，机动 4）
        "guard": UnitStat(key: "guard", name: "近卫", symbol: "G", hp: 140, atk: 46, def: 22,
                          moveRange: 4, attackRange: 1, counterAttack: true, value: 1.55,
                          cost: 0, promotable: true),
        // 枪兵：射程 2 的反骑兵阵线
        "lancer": UnitStat(key: "lancer", name: "枪兵", symbol: "L", hp: 115, atk: 58, def: 15,
                           moveRange: 4, attackRange: 2, counterAttack: true, value: 1.70,
                           cost: 0, promotable: true),
        // 重骑兵：装甲冲击（攻高防高，机动降到 6）
        "heavy": UnitStat(key: "heavy", name: "重骑兵", symbol: "H", hp: 130, atk: 62, def: 20,
                          moveRange: 6, attackRange: 1, counterAttack: true, value: 1.75,
                          cost: 0, promotable: true),
        // 游骑：全场最高机动 + 射程 2，但不反击
        "scout": UnitStat(key: "scout", name: "游骑", symbol: "S", hp: 100, atk: 55, def: 12,
                          moveRange: 8, attackRange: 2, counterAttack: false, value: 1.80,
                          cost: 0, promotable: true),
        // 弩兵：射程 3 的定点输出（脆、不反击）
        "crossbow": UnitStat(key: "crossbow", name: "弩兵", symbol: "X", hp: 70, atk: 62, def: 9,
                             moveRange: 3, attackRange: 3, counterAttack: false, value: 1.85,
                             cost: 0, promotable: true),
        // 游侠：能反击的半肉弓（机动与射程的折中）
        "ranger": UnitStat(key: "ranger", name: "游侠", symbol: "R", hp: 85, atk: 52, def: 12,
                           moveRange: 5, attackRange: 2, counterAttack: true, value: 1.75,
                           cost: 0, promotable: true),
        // 王者：统帅的防守路（HP/防最高，仍是首领：斩首与施法资格不变）
        "king": UnitStat(key: "king", name: "王者", symbol: "K", hp: 220, atk: 58, def: 26,
                         moveRange: 4, attackRange: 1, counterAttack: true, value: 2.9,
                         isChief: true, cost: 0, promotable: true),
        // 圣骑士：统帅的进攻路（攻高、机动 +1，仍是首领）
        "paladin": UnitStat(key: "paladin", name: "圣骑士", symbol: "P", hp: 190, atk: 70, def: 20,
                            moveRange: 5, attackRange: 1, counterAttack: true, value: 2.9,
                            isChief: true, cost: 0, promotable: true),
    ]

    /// 首领兵种 key（每阵营恰好一名，不占士兵名额）
    public static let chiefTypeKey = "commander"

    /**
     * 兵种升级：攻 / 防 / 生命三条**彼此独立**的等级线，各自从 T0 = 0（原始数值）起，**不限级别**。
     * - 攻击线 atk：只涨 atk；
     * - 防御线 def：只涨 def；
     * - 生命线 hp：只涨 hp。
     * - value（战略价值）恒定不随升级变：升级只改战斗数值，AI 的集火/物质分/重心口径保持稳定，
     *   难度阈值迁移最小。倍率以纯函数施加，所以 WarUnit 的 maxHp/atk/def 仍是 `let`，快照与评分都不改结构。
     */
    public struct Upgrades: Sendable, Equatable, Codable {
        public var atk: Int   // 攻击线等级（T0=0）
        public var def: Int   // 防御线等级（T0=0）
        public var hp: Int    // 生命线等级（T0=0）
        public init(atk: Int = 0, def: Int = 0, hp: Int = 0) {
            self.atk = Swift.max(0, atk)
            self.def = Swift.max(0, def)
            self.hp = Swift.max(0, hp)
        }

        public func level(_ track: UpgradeTrack) -> Int {
            switch track {
            case .attack: return atk
            case .defense: return def
            case .health: return hp
            }
        }
        public mutating func bump(_ track: UpgradeTrack) {
            switch track {
            case .attack: atk += 1
            case .defense: def += 1
            case .health: hp += 1
            }
        }
        /// 降一档（买错反悔用）。与 `bump` 严格互逆，钳在 T0 不再往下（负等级不参与定价与数值）。
        public mutating func lower(_ track: UpgradeTrack) {
            switch track {
            case .attack: atk = Swift.max(0, atk - 1)
            case .defense: def = Swift.max(0, def - 1)
            case .health: hp = Swift.max(0, hp - 1)
            }
        }
        /// 三条线全为 0 = 未升级（可短路回基础数值，避免无谓的四舍五入漂移）
        public var isBase: Bool { atk == 0 && def == 0 && hp == 0 }
    }

    /// 升级线（攻 / 防 / 生命，三线各自独立）
    public enum UpgradeTrack: String, Codable, CaseIterable {
        case attack, defense, health
        public var label: String {
            switch self {
            case .attack: return "攻击"
            case .defense: return "防御"
            case .health: return "生命"
            }
        }
    }

    /// 每级增益（线性，相对兵种基础值）：atk +15%、def +10%、hp +12%
    public static let atkGainPerLevel: Double = 0.15
    public static let hpGainPerLevel: Double = 0.12
    public static let defGainPerLevel: Double = 0.10

    /// 升某条线「下一档」(currentLv→currentLv+1) 的费用 = 单价 ×(0.6 + 0.4×当前等级)，最低 10，
    /// 随等级线性递增、无上限。首领不可升级（cost 0）——返回 Int.max 当作"买不起"，调用侧据此拒绝。
    public static func upgradeCost(typeKey: String, currentLevel: Int) -> Int {
        guard let s = unitTypes[typeKey], !s.isChief, s.cost > 0 else { return .max }
        return max(10, Int((Double(s.cost) * (0.6 + 0.4 * Double(max(0, currentLevel)))).rounded()))
    }

    /// 按三条升级线等级取实际数值（四舍五入，纯函数 —— 复现不变式依赖这点）。value 恒定 = 基础值。
    public static func unitStat(_ typeKey: String, upgrades: Upgrades = Upgrades()) -> UnitStat? {
        guard let base = unitTypes[typeKey] else { return nil }
        if upgrades.isBase { return base }
        return UnitStat(key: base.key, name: base.name, symbol: base.symbol,
                        hp: Int((Double(base.hp) * (1 + hpGainPerLevel * Double(upgrades.hp))).rounded()),
                        atk: Int((Double(base.atk) * (1 + atkGainPerLevel * Double(upgrades.atk))).rounded()),
                        def: Int((Double(base.def) * (1 + defGainPerLevel * Double(upgrades.def))).rounded()),
                        moveRange: base.moveRange, attackRange: base.attackRange,
                        counterAttack: base.counterAttack,
                        value: base.value,
                        isChief: base.isChief, cost: base.cost, promotable: base.promotable)
    }

    /// 默认布阵（每方 6 个**士兵**，iPhone 小屏节奏更快；首领另算）
    public static let defaultRoster = ["infantry", "infantry", "cavalry", "cavalry", "archer", "archer"]

    /// 兵种展示顺序（布阵选择器用，字典无序）。首领不在其中：它免费且必带；
    /// 转职分支也不在其中：它只能由 10 级转职得到，不是货架上的商品。
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

    /// 魔法等级上限（0 = 刚买断的基础档，3 = 顶档）
    public static let maxSpellLevel = 3

    /// 某门魔法在给定等级下的**实际生效数值**（唯一口径）：
    /// 威力与溅射 ×(1 + 0.2 × 等级)，顶档（≥3）射程 +1。纯函数、四舍五入，
    /// 于是内核结算、AI 评分、面板文案拿到的是同一个数 —— UI 不自己乘系数。
    public static func spellStat(_ key: String, level: Int) -> SpellStat? {
        guard let base = spells[key] else { return nil }
        let lv = min(max(0, level), maxSpellLevel)
        guard lv > 0 else { return base }
        let scale = 1 + 0.2 * Double(lv)
        return SpellStat(key: base.key, name: base.name, symbol: base.symbol, effect: base.effect,
                         range: base.range + (lv >= maxSpellLevel ? 1 : 0),
                         power: Int((Double(base.power) * scale).rounded()),
                         splash: Int((Double(base.splash) * scale).rounded()),
                         splashRadius: base.splashRadius,
                         unlockCost: base.unlockCost, chargeCost: base.chargeCost)
    }

    /// 升一档的价 = 买断价 ×（当前等级 + 1）：火球 60/120/180，治疗 45/90/135，冰冻 70/140/210。
    /// 已满级返回 `.max`（与 `upgradeCost` 拒卖首领同一手法：调用侧据此直接拒绝，不特判级数）。
    public static func spellUpgradeCost(_ key: String, currentLevel: Int) -> Int {
        guard let base = spells[key], currentLevel < maxSpellLevel else { return .max }
        return base.unlockCost * (max(0, currentLevel) + 1)
    }

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
        /// 敌方首领的魔法等级（与玩家“军费买档”同一条成长轴，不读玩家钱包）：
        /// 低档只会基础数值，高档才有顶档威力与射程。放在难度里而不是兵种里，
        /// 于是它是第四个旋钮之外的第五个“可复现的强度来源”。
        public let spellLevel: Int

        public init(key: String, name: String, temperature: Double, lookahead: Int,
                    vision: Int, noise: Double, budget: Int, spellLevel: Int = 0) {
            self.key = key
            self.name = name
            self.temperature = temperature
            self.lookahead = lookahead
            self.vision = vision
            self.noise = noise
            self.budget = budget
            self.spellLevel = spellLevel
        }
    }

    public static let difficulties: [String: Difficulty] = [
        "easy": Difficulty(key: "easy", name: "简单", temperature: 0.90, lookahead: 0, vision: 5, noise: 0.15, budget: 40, spellLevel: 0),
        "normal": Difficulty(key: "normal", name: "普通", temperature: 0.35, lookahead: 0, vision: 9, noise: 0.08, budget: 90, spellLevel: 1),
        "hard": Difficulty(key: "hard", name: "困难", temperature: 0.10, lookahead: 1, vision: .max, noise: 0.04, budget: 140, spellLevel: 2),
        "nightmare": Difficulty(key: "nightmare", name: "噩梦", temperature: 0.02, lookahead: 2, vision: .max, noise: 0.0, budget: 200, spellLevel: 3),
    ]
    public static let defaultDifficultyKey = "normal"

    /// 难度展示顺序（由弱到强，字典无序）
    public static let difficultyOrder = ["easy", "normal", "hard", "nightmare"]

    // MARK: - 闯关（Campaign）关卡公式
    //
    // 关卡参数全部由关数 n 的纯函数导出：固定、可复现，且不读玩家钱包/战绩。
    // 于是同一关永远同一张图、同一支敌军、同一套 AI 旋钮 —— 打不过可原地反复重打，
    // AI 不会因为玩家刚输过就变简单、也不会因为连胜就变难（那不是闯关，是动态匹配）。
    public struct LevelSpec: Sendable, Equatable {
        public let level: Int
        public let difficultyKey: String
        public let enemyUpgrades: Upgrades
        public let terrainSeed: Int
        public let aiSeed: Int
        /// 本关敌军首领的魔法等级（与难度档的 `spellLevel` 同一量纲，但走关数公式）
        public let spellLevel: Int

        public init(level: Int, difficultyKey: String, enemyUpgrades: Upgrades,
                    terrainSeed: Int, aiSeed: Int, spellLevel: Int = 0) {
            self.level = level
            self.difficultyKey = difficultyKey
            self.enemyUpgrades = enemyUpgrades
            self.terrainSeed = terrainSeed
            self.aiSeed = aiSeed
            self.spellLevel = spellLevel
        }
    }

    /// 关数 → 关卡参数。第 1…4 关依次走 简单/普通/困难/噩梦（决定 AI 的视野/温度/前瞻旋钮）；
    /// 敌军**属性按公式独立成长**：每 2 关三线（攻/防/生命）各 +1（从 T0 起，不限级），与玩家钱包无关。
    /// 地图 / AI seed 随关数线性变化（各自钉死一张可复现的图与一串采样流）。
    public static func campaignLevel(_ n: Int) -> LevelSpec {
        let level = max(1, n)
        let idx = min(max(0, level - 1), difficultyOrder.count - 1)
        let key = difficultyOrder[idx]
        let growth = (level - 1) / 2   // 每 2 关每条线 +1
        return LevelSpec(level: level, difficultyKey: key,
                         enemyUpgrades: Upgrades(atk: growth, def: growth, hp: growth),
                         terrainSeed: 1000 + level * 7, aiSeed: 20260101 + level * 13,
                         // 魔法档次与三线成长同节奏（每 2 关一档），但不跟难度档回退：
                         // 第 5 关回到噩梦档之后，顶档魔法仍然在。
                         spellLevel: min(maxSpellLevel, growth))
    }

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
        /// 自杀门禁：本次行动会让自己死掉且换不掉任何战果（反击必杀 + 打不死目标）
        public let suicide: Double
        /// 首领死亡风险：只有“落点下回合会被打死”这一条硬门槛才计，
        /// 因为首领一死就地判负，代价不是“少一个兵”而是“输掉本局”。
        /// 士兵没有对应项 —— 通用的“落点死亡风险”实测会把双方顶成绕行不接战，
        /// 详见 `Scorer` 里那段结论（调参前请先重跑量尺）。
        public let chiefPeril: Double

        public init(damage: Double, kill: Double, overkill: Double, selfPreserve: Double,
                    targetValue: Double, exposure: Double, terrain: Double, focus: Double,
                    counterRisk: Double, mobility: Double, surround: Double, objective: Double,
                    support: Double, waste: Double, rangePenalty: Double,
                    engage: Double, proximity: Double, chiefBounty: Double,
                    heal: Double, freeze: Double, suicide: Double, chiefPeril: Double) {
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
            self.suicide = suicide
            self.chiefPeril = chiefPeril
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
        freeze: 30,           // 冰冻：封掉敌人一回合，比一次中等伤害略值
        // ── 反“自动送死”两项（与 exposure 分层：exposure 只讲“会被打疼”，
        //    这里只问“会不会因此死”）。伤害类收益最高约 damage 100 + kill 80，
        //    所以自杀项必须比它们一个量级以上，否则高温度档一定会采样出必死着法。
        suicide: -320,        // 反击必杀自己且打不死目标：直接否掉（另在枚举层硬过滤）
        chiefPeril: -240      // 首领落点下回合会被打死（=本局判负）
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

import Foundation

// MARK: - 转职分支表

public extension WarConfig {
    /// 基础兵种 key → 它的两个转职分支 key。
    ///
    /// **数组顺序就是规则本身**：UI 两个按钮的次序、AI 在低难度档的"取第一个"都读它，
    /// 所以不能换成字典（字典遍历无序会让同 seed 的两局转成不同兵种）。
    /// 首领也在表里：它同样有两条路，且转职后仍保留 `isChief`（斩首与施法资格不变）。
    static let promotions: [String: [String]] = [
        "infantry": ["guard", "lancer"],       // 近卫（更硬） / 枪兵（更痛、射程 2）
        "cavalry": ["heavy", "scout"],         // 重骑兵（装甲） / 游骑（8 格机动 + 射程 2）
        "archer": ["crossbow", "ranger"],      // 弩兵（射程 3 不反击） / 游侠（可反击的半肉弓）
        "commander": ["king", "paladin"],      // 王者（防守型统帅） / 圣骑士（进攻型统帅）
    ]
}

// MARK: - 经验 / 等级 / 属性点公式

/// 战场成长体系（经验 → 等级 → 属性点 → 10 级分支转职）的数值唯一定义处。
///
/// 它与"军费三线升级"是**两条彼此独立的成长轴**：那条轴花钱、以倍率生效；
/// 这条轴打仗、以固定点数生效。分开是因为手感 —— 买档决定"这支兵出厂多强"，
/// 等级决定"这一局里它活成了什么"。
///
/// 所有公式都是纯函数、无随机：AI 回合是"真实推演 → 回滚 → 逐事件重放"，
/// 经验只要掺一点随机或时钟，同 seed 的两局就会在第一场交锋后分叉。
public extension WarConfig {
    enum Growth {

        // MARK: 属性点增量（每点固定加多少，与兵种无关）

        public static let perPointAtk = 5
        public static let perPointDef = 3
        public static let perPointHp = 12

        /// 把属性点加成施加到"已过军费倍率"的兵种数值上（唯一合成处）。
        /// 顺序固定为 倍率 → 加点：反过来会让买档的钱随等级复利，两条轴就缠在一起了。
        public static func stat(typeKey: String, upgrades: WarConfig.Upgrades,
                                alloc: WarConfig.Upgrades) -> WarConfig.UnitStat? {
            guard let base = WarConfig.unitStat(typeKey, upgrades: upgrades) else { return nil }
            guard alloc.atk > 0 || alloc.def > 0 || alloc.hp > 0 else { return base }
            return WarConfig.UnitStat(key: base.key, name: base.name, symbol: base.symbol,
                                      hp: base.hp + perPointHp * alloc.hp,
                                      atk: base.atk + perPointAtk * alloc.atk,
                                      def: base.def + perPointDef * alloc.def,
                                      moveRange: base.moveRange, attackRange: base.attackRange,
                                      counterAttack: base.counterAttack, value: base.value,
                                      isChief: base.isChief, cost: base.cost,
                                      promotable: base.promotable)
        }

        // MARK: 等级曲线与上限

        /// 从 `level` 再升一级所需的本级经验。1→10 共 360 点。
        public static func expToNext(_ level: Int) -> Int { 15 + 5 * max(1, level) }

        /// 触发转职所需的等级
        public static let promoteLevel = 10
        /// 未转职的等级上限（到 10 就必须二选一，否则成长停在半空）
        public static let baseLevelCap = 10
        /// 转职后的等级上限
        public static let promotedLevelCap = 20

        public static func levelCap(promoted: Bool) -> Int { promoted ? promotedLevelCap : baseLevelCap }

        /// 到当前等级为止**应得**的属性点总数（升级 1 点 + 转职 1 点）。
        /// 存盘只记等级与已分配点数，待分配数由这个式子回推 —— 少一个可被刷的字段。
        public static func grantedPoints(level: Int, promoted: Bool) -> Int {
            max(0, level - 1) + (promoted ? 1 : 0)
        }

        // MARK: 经验发放公式（战斗结算里唯一的五个来源，全部确定）

        /// 出手伤害：封顶 40，避免一次溅射把首领直接抬到满级
        public static func hitExp(_ damage: Int) -> Int { min(40, max(0, damage)) }
        /// 击杀：按目标战略价值折算（打首领比打折兵长经验，这是"斩首"应有的奖励）
        public static func killExp(value: Double) -> Int { Int(10 * max(0, value)) }
        /// 被打未死：挨一刀也长见识（残局拉锯里等级才不会只属于赢家）
        public static func sufferedExp(_ damage: Int) -> Int { max(1, max(0, damage) / 2) }
        /// 治疗：按**实际**回复量折半（溢出治疗不计，所以白治不长经验）
        public static func healExp(_ healed: Int) -> Int { max(0, healed) / 2 }
        /// 冰冻：封住一个敌人一回合，固定 8 点
        public static let freezeExp = 8

        // MARK: 自动成长（AI / 观战侧）

        /// 兵种偏好循环：前排先补身板、输出先补攻击。按"已分点数 % 3"取下一项，
        /// 纯函数、无随机 —— 同一支 AI 军队每次升级都走同一串分配。
        public static func preferredTracks(baseType: String) -> [WarConfig.UpgradeTrack] {
            switch baseType {
            case "infantry", "commander": return [.health, .defense, .attack]
            default: return [.attack, .health, .defense]      // cavalry / archer 系
            }
        }

        /// AI 的分支选择（必须确定，否则重放对不上）。
        /// 低两档照表取第一个分支（简单 AI 不该看起来像在"做选择"）；
        /// 高两档走偏好表 —— 困难/噩梦的兵是"练过的"，而不是"掷骰子选的"。
        public static func aiBranch(for baseType: String, difficultyKey: String) -> String? {
            guard let options = WarConfig.promotions[baseType], !options.isEmpty else { return nil }
            switch difficultyKey {
            case "hard", "nightmare":
                let preferred: [String: String] = ["infantry": "lancer", "cavalry": "heavy",
                                                   "archer": "crossbow", "commander": "king"]
                if let pick = preferred[baseType], options.contains(pick) { return pick }
                return options[0]
            default:
                return options[0]
            }
        }

        // MARK: 成长存盘快照

        /// 一个兵种的成长账（闯关跨关累积用）。
        ///
        /// 记的是**兵种**而不是单位：单位不跨关存在，"这一局的步兵 3 号"活不到下一关，
        /// 能带走的只是"步兵这个兵种最高练到了几级"。
        public struct UnitGrowth: Codable, Equatable, Sendable {
            public var level: Int
            public var expIntoLevel: Int
            public var alloc: WarConfig.Upgrades
            /// 已转职的分支 key；nil = 尚未转职
            public var branch: String?

            public init(level: Int = 1, expIntoLevel: Int = 0,
                        alloc: WarConfig.Upgrades = WarConfig.Upgrades(), branch: String? = nil) {
                self.level = max(1, level)
                self.expIntoLevel = max(0, expIntoLevel)
                self.alloc = alloc
                self.branch = branch
            }

            /// 已分配到三条线的点数合计（未分配的那部分由 `grantedPoints - allocated` 回推）
            public var allocated: Int { alloc.atk + alloc.def + alloc.hp }

            // 合成的 Decodable 不用默认值兜底缺键：加字段会让旧存档整本解不开。
            private enum CodingKeys: String, CodingKey {
                case level, expIntoLevel, alloc, branch
            }

            /// 已转职（分支非空即已走过一次二选一）
            public var promoted: Bool { branch != nil }

            /// 两条成长账里取更强的一条：先比等级，同级先比是否已转职，再比本级经验。
            /// 一关打赢时场上可能有好几个步兵，带回下关的是“这个兵种练到了什么”，
            /// 所以比较必须定序且不看运气（否则同一关两次打出来的结果会分叉）。
            public static func stronger(_ lhs: UnitGrowth, _ rhs: UnitGrowth) -> UnitGrowth {
                if lhs.level != rhs.level { return lhs.level > rhs.level ? lhs : rhs }
                // 转职比几点本级经验重得多（它换来的是永久形态 + 20 级上限），所以先比它
                if lhs.promoted != rhs.promoted { return lhs.promoted ? lhs : rhs }
                return lhs.expIntoLevel >= rhs.expIntoLevel ? lhs : rhs
            }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                func val<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
                    (try? c.decode(T.self, forKey: key)) ?? fallback
                }
                level = max(1, val(.level, 1))
                expIntoLevel = max(0, val(.expIntoLevel, 0))
                alloc = val(.alloc, WarConfig.Upgrades())
                branch = val(.branch, nil as String?)
            }
        }
    }
}

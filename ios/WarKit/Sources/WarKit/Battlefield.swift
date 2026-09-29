import Foundation

/// 一个可达格：累计消耗 + 完整路径（路径保证 4 邻接，绝不斜走）
public struct ReachCell: Sendable {
    public let cost: Int
    public let path: [GridPoint]
}

/// 移动结果（唯一的"扣点"出口）
public struct MoveResult {
    public let success: Bool
    public let spent: Int
    public let reached: GridPoint
    public let message: String
}

/// 攻击结果
public struct AttackResult {
    public var damage = 0
    public var counterDamage = 0
    public var targetKilled = false
    public var counterKilled = false
}

/// 施法结果。`affected` 用字典记每格实际生效量（伤害/治疗量，冰冻记 1），
/// 重放与飘字一律按 `affectedPoints` 的确定序走 —— 字典本身无序，
/// 直接遍历会让同 seed 的两局飘字顺序不一致。
public struct SpellResult {
    public var success = false
    public var message = ""
    public var spellKey = ""
    /// 命中中心格（未成功时为哨兵值 -1,-1）
    public var impact = GridPoint(x: -1, y: -1)
    public var affected: [GridPoint: Int] = [:]
    /// 本次施法后阵亡单位的所在格（溅射可能一次烧掉好几个）
    public var killed: [GridPoint] = []
    /// 目标是否被冻住（UI 据此画冰罩）
    public var stunnedTarget = false

    /// 确定性遍历序（先 y 后 x，与内核其它地方一致）
    public var affectedPoints: [GridPoint] {
        affected.keys.sorted { $0.y != $1.y ? $0.y < $1.y : $0.x < $1.x }
    }
}

/// 战场状态机：地形、占位、移动结算、攻击结算、可达域、威胁影响图、快照。
///
/// 设计约定（重要）：
/// 1. **单位只以 `units` 数组为准**，`unitGrid` 是派生索引；击杀后单位仍留在数组中
///    （`isDead`），只从 grid 摘除 —— 保证数组下标稳定，快照/回滚才能按下标对齐。
/// 2. 所有可变状态的唯一写入点：移动 = `moveAlongPath`，伤害 = `attack`。
///    AI 在前瞻里复用它，因此 AI 看到的规则与玩家执行的规则**必然一致**。
/// 3. 可达域/影响图带版本缓存，任何写操作都会 `version += 1` 使其失效。
public final class Battlefield {
    public let width: Int
    public let height: Int
    public private(set) var terrain: [[String]]
    public private(set) var units: [WarUnit]
    public private(set) var unitGrid: [[WarUnit?]]

    private var version = 0
    private var reachableCache: [Int: (cells: [GridPoint: ReachCell], version: Int, budget: Int)] = [:]
    private var threatCache: [Int: ([Double], Int)] = [:]

    public init(
        width: Int = WarConfig.defaultBoard.width,
        height: Int = WarConfig.defaultBoard.height,
        terrain: [[String]]? = nil,
        units: [WarUnit] = []
    ) {
        self.width = width
        self.height = height

        // 地形：**约定一律 row-major，`terrain[y][x]`**（与 unitGrid 同构）。
        // 缺格补平原，未知 key 也补平原（渲染层不会读到 nil）。
        var grid = Array(repeating: Array(repeating: WarConfig.defaultTerrainKey, count: width), count: height)
        if let custom = terrain {
            for y in 0..<height {
                for x in 0..<width {
                    let key = custom.indices.contains(y) && custom[y].indices.contains(x)
                        ? custom[y][x] : WarConfig.defaultTerrainKey
                    grid[y][x] = WarConfig.terrains[key] != nil ? key : WarConfig.defaultTerrainKey
                }
            }
        }
        self.terrain = grid

        // unitGrid 与 terrain 同构：`[height][width]`（行优先）
        self.unitGrid = Array(repeating: Array(repeating: nil, count: width), count: height)
        self.units = []
        for unit in units {
            guard isInside(unit.x, unit.y), !unit.isDead, unitGrid[unit.y][unit.x] == nil else { continue }
            self.units.append(unit)
            unitGrid[unit.y][unit.x] = unit
        }
    }

    // MARK: - 基础查询

    public func isInside(_ x: Int, _ y: Int) -> Bool { x >= 0 && x < width && y >= 0 && y < height }
    public func isInside(_ p: GridPoint) -> Bool { isInside(p.x, p.y) }

    public func terrainKey(at p: GridPoint) -> String { terrain[p.y][p.x] }

    public func getTerrain(_ x: Int, _ y: Int) -> WarConfig.Terrain {
        guard isInside(x, y), let t = WarConfig.terrains[terrain[y][x]] else {
            return WarConfig.terrains[WarConfig.defaultTerrainKey]!
        }
        return t
    }

    public func getTerrain(_ p: GridPoint) -> WarConfig.Terrain { getTerrain(p.x, p.y) }

    public func getTerrainDefBonus(_ x: Int, _ y: Int) -> Int { getTerrain(x, y).defBonus }
    public func getTerrainDefBonus(_ p: GridPoint) -> Int { getTerrain(p.x, p.y).defBonus }

    public func getMoveCost(_ p: GridPoint) -> Int { getTerrain(p).moveCost }

    public func isPassable(_ x: Int, _ y: Int) -> Bool {
        isInside(x, y) && !getTerrain(x, y).impassable
    }
    public func isPassable(_ p: GridPoint) -> Bool { isPassable(p.x, p.y) }

    /// 可通行且无单位占位
    public func isCellAvailable(_ x: Int, _ y: Int) -> Bool {
        isPassable(x, y) && unitGrid[y][x] == nil
    }
    public func isCellAvailable(_ p: GridPoint) -> Bool { isCellAvailable(p.x, p.y) }

    /// 以单位为基准的可用性（目标格等于该单位当前位置时视为可用）
    public func isAvailable(_ x: Int, _ y: Int, for unit: WarUnit) -> Bool {
        if unit.x == x && unit.y == y { return true }
        return isCellAvailable(x, y)
    }

    public func hasUnitAt(_ x: Int, _ y: Int) -> Bool {
        guard isInside(x, y), let u = unitGrid[y][x] else { return false }
        return !u.isDead
    }
    public func hasUnitAt(_ p: GridPoint) -> Bool { hasUnitAt(p.x, p.y) }

    public func getUnitAt(_ x: Int, _ y: Int) -> WarUnit? {
        guard isInside(x, y), let u = unitGrid[y][x], !u.isDead else { return nil }
        return u
    }
    public func getUnitAt(_ p: GridPoint) -> WarUnit? { getUnitAt(p.x, p.y) }

    public func findUnitById(_ id: Int) -> WarUnit? {
        units.first { $0.id == id && !$0.isDead }
    }

    public func unitsOfCamp(_ camp: Int) -> [WarUnit] { units.filter { !$0.isDead && $0.camp == camp } }

    /// 存活士兵（不含首领）。“兵全灭”这类判据用它，不能用 `unitsOfCamp`：
    /// 后者含首领，会把“只剩首领”误算成“还有兵”。
    public func unitsOfCampExcludingChief(_ camp: Int) -> [WarUnit] {
        unitsOfCamp(camp).filter { !$0.isChief }
    }

    /// 该阵营现存的首领
    public func chief(of camp: Int) -> WarUnit? {
        units.first { $0.isChief && $0.camp == camp && !$0.isDead }
    }

    /// 该阵营首领是否已阵亡。
    /// 必须同时满足“这局确实编入过首领”（`units` 里查得到，含已死）与
    /// “现已无存活首领” —— 否则未带首领的测试基线会被误判成斩首败。
    public func isChiefLost(camp: Int) -> Bool {
        chief(of: camp) == nil && units.contains { $0.isChief && $0.camp == camp }
    }

    /// 对立阵营 id（只有两队，0/1 互换）
    public func campOf(otherThan camp: Int) -> Int { camp == 0 ? 1 : 0 }

    /// 以 (cx,cy) 为中心、曼哈顿距离 ≤ radius 的所有格
    public func cellsInRadius(_ cx: Int, _ cy: Int, radius: Int) -> [GridPoint] {
        var cells: [GridPoint] = []
        for dx in -radius...radius {
            let rest = radius - abs(dx)
            for dy in -rest...rest {
                let x = cx + dx, y = cy + dy
                if isInside(x, y) { cells.append(GridPoint(x: x, y: y)) }
            }
        }
        return cells
    }

    public func resetTurns() { for u in units where !u.isDead { u.resetTurn() } }

    /// 阵营回合开始：只重置本方单位配额，并失效缓存。
    /// 解冻时机放在这里：冰冻只压住“被冻方那一个回合”，而那个回合结束的标志
    /// 就是对手重新拿到行动权 —— 于是在轮到 `camp` 行动时把**对方**的冻结位清掉。
    /// （被冻单位自己的 resetTurn 会保持 stunned，从而整个回合连反击都被挡掉。）
    public func beginTurn(camp: Int) {
        for u in units where u.stunned && u.camp != camp { u.stunned = false }
        for u in units where !u.isDead && u.camp == camp { u.resetTurn() }
        version += 1
    }

    /// 主动放弃本回合剩余配额（待命）。UI 层的"待命"按钮走这里，
    /// 不自己改字段 —— 否则缓存版本号不变，可达域会读到旧预算。
    public func wait(_ unit: WarUnit) {
        guard !unit.isDead else { return }
        unit.remainingMove = 0
        unit.remainingAttacks = 0
        unit.remainingSpell = 0
        version += 1
    }

    // MARK: - 视线

    /// 相邻格无障碍；射程 2 时中间格不能被 wall/水阻挡
    public func hasLineOfSight(from a: GridPoint, to b: GridPoint) -> Bool {
        let dx = b.x - a.x, dy = b.y - a.y
        let adx = abs(dx), ady = abs(dy)
        if adx + ady <= 1 { return true }
        if adx <= 1 && ady <= 1 { return true }
        let steps = max(adx, ady)
        for i in 1..<steps {
            let mx = (a.x * (steps - i) + b.x * i) / steps
            let my = (a.y * (steps - i) + b.y * i) / steps
            if getTerrain(mx, my).impassable { return false }
        }
        return true
    }

    public func hasLineOfSight(from a: WarUnit, to b: WarUnit) -> Bool {
        hasLineOfSight(from: a.position, to: b.position)
    }

    /// 射程 + 视线 + 目标存活的完整可攻击判定（攻击者已在落点 p）
    public func canAttackFrom(_ attacker: WarUnit, from p: GridPoint, to target: WarUnit) -> Bool {
        !attacker.isDead && !target.isDead && attacker.camp != target.camp
            && Grid.manhattan(p.x, p.y, target.x, target.y) <= attacker.attackRange
            && hasLineOfSight(from: p, to: target.position)
    }

    public func canAttackWithLineOfSight(_ attacker: WarUnit, _ target: WarUnit) -> Bool {
        canAttackFrom(attacker, from: attacker.position, to: target)
    }

    // MARK: - 可达域（Dijkstra + 版本缓存）

    public func computeReachable(_ unit: WarUnit) -> [GridPoint: ReachCell] {
        if unit.isDead { return [:] }
        // 被冻：返回空域（连"原地"都不给）。这样候选枚举自然不会为它生成任何位移，
        // UI 选中被冻单位时也不会亮起可达格 —— 状态和表现同一个口径。
        if unit.stunned { return [:] }
        // 缓存必须同时校版本号与机动力预算：只改单位剩余点数不会 bump version，
        // 光靠 version 失效会读到"满预算"的脏结果（低预算候选被误放行）。
        if let hit = reachableCache[unit.id], hit.version == version, hit.budget == unit.remainingMove {
            return hit.cells
        }
        let result = reachableWithBudget(unit, budget: unit.remainingMove)
        reachableCache[unit.id] = (result, version, unit.remainingMove)
        return result
    }

    /// 按指定机动点预算计算可达域。
    /// 影响图必须用"完整机动力"（威胁是下回合的事），而行动枚举要用"剩余机动力"，
    /// 所以这里显式参数化预算，而不是偷偷改单位状态绕缓存。
    public func reachableWithBudget(_ unit: WarUnit, budget: Int) -> [GridPoint: ReachCell] {
        let b = max(0, budget)
        let start = GridPoint(x: unit.x, y: unit.y)
        var dist: [GridPoint: Int] = [start: 0]
        var paths: [GridPoint: [GridPoint]] = [start: [start]]
        // 桶式优先队列（cost 为整数，值域极小）
        var buckets = Array(repeating: [GridPoint](), count: b + 1)
        buckets[0].append(start)
        var minCost = 0

        while true {
            while minCost <= b && buckets[minCost].isEmpty { minCost += 1 }
            if minCost > b { break }
            let current = buckets[minCost].removeFirst()
            let currentCost = dist[current]!
            if currentCost > b { continue }
            for next in Grid.neighbors4(current, width: width, height: height) {
                let cost = getMoveCost(next)
                if cost >= 99 { continue }             // 不可通行
                if hasUnitAt(next) && next != current { continue }  // 被占（自己的格子允许离开）
                let newCost = currentCost + cost
                if newCost > b { continue }
                if newCost < (dist[next] ?? .max) {
                    dist[next] = newCost
                    paths[next] = (paths[current] ?? []) + [next]
                    if newCost <= b { buckets[newCost].append(next) }
                }
            }
        }

        var result: [GridPoint: ReachCell] = [:]
        for (p, cost) in dist {
            result[p] = ReachCell(cost: cost, path: paths[p] ?? [p])
        }
        return result
    }

    // MARK: - 威胁影响图

    /// 指定阵营对全场每格造成的威胁值（按该阵营**满行动状态**计算，带缓存）。
    public func buildThreatMap(camp: Int) -> [Double] {
        let key = 1000 + camp
        if let hit = threatCache[key], hit.1 == version { return hit.0 }

        var map = [Double](repeating: 0, count: width * height)
        for enemy in units where !enemy.isDead && enemy.camp == camp {
            let reach = reachableWithBudget(enemy, budget: enemy.moveRange)
            let radius = max(1, enemy.attackRange)
            // 遍历顺序需确定：按 (y,x) 排序
            let ordered = reach.keys.sorted { $0.y != $1.y ? $0.y < $1.y : $0.x < $1.x }
            for p in ordered {
                for c in cellsInRadius(p.x, p.y, radius: radius) {
                    map[c.y * width + c.x] += Double(enemy.atk)
                }
            }
        }
        threatCache[key] = (map, version)
        return map
    }

    public func threatAt(_ map: [Double], _ x: Int, _ y: Int) -> Double {
        guard y * width + x < map.count else { return 0 }
        return map[y * width + x]
    }

    // MARK: - 移动结算（唯一扣点入口）

    /// 沿路径逐格移动：校验 4 邻接、占位、地形消耗，并真正扣减机动点。
    /// 任一步非法则回滚到起点，绝不留下"部分移动 + 未扣点"的脏状态。
    @discardableResult
    public func moveAlongPath(_ unit: WarUnit, path: [GridPoint]) -> MoveResult {
        let origin = GridPoint(x: unit.x, y: unit.y)
        guard !unit.isDead else {
            return MoveResult(success: false, spent: 0, reached: origin, message: "单位已死亡")
        }
        guard path.count > 1 else {
            return MoveResult(success: true, spent: 0, reached: origin, message: "原地不动")
        }

        var budget = unit.remainingMove
        var spent = 0
        var current = origin
        // 先腾空起点，避免把自身所在格当成障碍
        unitGrid[current.y][current.x] = nil
        var step = 1

        while step < path.count {
            let next = path[step]
            if Grid.manhattan(current.x, current.y, next.x, next.y) != 1 {
                _rollbackMove(unit, to: origin)
                return MoveResult(success: false, spent: 0, reached: origin, message: "移动必须 4 方向逐格（禁止斜走）")
            }
            if !isInside(next.x, next.y) {
                _rollbackMove(unit, to: origin)
                return MoveResult(success: false, spent: 0, reached: origin, message: "超出边界")
            }
            let cost = getMoveCost(next)
            if cost >= 99 {
                _rollbackMove(unit, to: origin)
                return MoveResult(success: false, spent: 0, reached: origin, message: "\(getTerrain(next).name)不可通行")
            }
            if cost > budget {
                break   // 机动点不足：停在当前格（合法的部分移动）
            }
            if let blocker = unitGrid[next.y][next.x], !blocker.isDead {
                break   // 被占：停住
            }
            budget -= cost
            spent += cost
            current = next
            step += 1
        }

        unitGrid[current.y][current.x] = unit
        unit.x = current.x
        unit.y = current.y
        unit.remainingMove = budget
        version += 1
        return MoveResult(success: true, spent: spent, reached: current, message: "移动完成")
    }

    /// 非法路径：不保留任何副作用，单位回到起点且不退点
    private func _rollbackMove(_ unit: WarUnit, to origin: GridPoint) {
        unitGrid[origin.y][origin.x] = unit
        unit.x = origin.x
        unit.y = origin.y
    }

    // MARK: - 攻击结算（唯一伤害写入点）

    /// 结算一次完整攻击（含反击与击杀清位）。AI 前瞻与真实执行共用本方法。
    /// 伤害完全确定（无随机波动）：同一局面重放必定得到同一结果。
    @discardableResult
    public func attack(_ attacker: WarUnit, _ target: WarUnit) -> AttackResult {
        var result = AttackResult()
        guard !attacker.isDead, !target.isDead, attacker.camp != target.camp,
              attacker.remainingAttacks > 0, !attacker.stunned,
              canAttackWithLineOfSight(attacker, target) else {
            return result
        }

        attacker.remainingAttacks -= 1
        // 一回合一个动作：动手了就把施法次数一并关掉（与 castSpell 互斥）
        attacker.remainingSpell = 0
        let dmg = attacker.damageTo(target, targetTerrainDefBonus: getTerrainDefBonus(target.position))
        result.damage = target.takeDamage(dmg)
        result.targetKilled = target.isDead

        if result.targetKilled {
            unitGrid[target.y][target.x] = nil
        } else if target.canCounter(attacker) {
            target.hasCountered = true
            let cdmg = target.damageTo(attacker, targetTerrainDefBonus: getTerrainDefBonus(attacker.position))
            result.counterDamage = attacker.takeDamage(cdmg)
            result.counterKilled = attacker.isDead
            if result.counterKilled { unitGrid[attacker.y][attacker.x] = nil }
        }

        version += 1
        return result
    }

    // MARK: - 施法结算（魔法的唯一写入点，且只有首领能调）

    /**
     结算一次施法。校验链与 `attack` 同构：任何一环不过就不扣充能、不改状态。

     与普攻的三个区别写死在这里：
     1. 伤害是**固定值**，不吃防御也不吃地形减伤；
     2. 溅射（如果有）**只烧敌方**，不损己方与施法者；
     3. 施法与普攻**互斥**：成功施法会把本回合攻击配额一并清零。
     */
    @discardableResult
    public func castSpell(_ caster: WarUnit, spell spellKey: String, at target: GridPoint) -> SpellResult {
        var r = SpellResult(spellKey: spellKey)
        guard let stat = WarConfig.spells[spellKey] else { r.message = "未知魔法"; return r }
        guard !caster.isDead, caster.isChief else { r.message = "只有首领能施法"; return r }
        guard caster.spellKeys.contains(spellKey) else { r.message = "首领未携带\(stat.name)"; return r }
        guard !caster.stunned else { r.message = "首领被冻住，无法施法"; return r }
        guard caster.remainingSpell > 0 else { r.message = "本回合已行动过了"; return r }
        guard caster.charges(for: spellKey) > 0 else { r.message = "\(stat.name)充能已用尽"; return r }
        guard Grid.manhattan(caster.position, target) <= stat.range else {
            r.message = "超出射程（\(stat.range) 格）"; return r
        }
        guard hasLineOfSight(from: caster.position, to: target) else { r.message = "没有视线"; return r }
        guard let focus = getUnitAt(target) else { r.message = "目标格上没有单位"; return r }

        switch stat.effect {
        case .damage:
            guard focus.camp != caster.camp else { r.message = "火球只能轰敌方"; return r }
        case .heal:
            guard focus.camp == caster.camp else { r.message = "治疗只能对自己人"; return r }
            guard focus.hp < focus.maxHp else { r.message = "目标已满血"; return r }
        case .stun:
            guard focus.camp != caster.camp else { r.message = "冰冻只能封敌方"; return r }
            guard !focus.stunned else { r.message = "目标已被冻住"; return r }
        }

        // 过了所有校验才扣资源：校验失败不得偷走充能（UI 可以直接把失败原因告诉玩家）
        caster.spellCharges[spellKey] = caster.charges(for: spellKey) - 1
        caster.remainingSpell -= 1
        caster.remainingAttacks = 0     // 一回合一个动作：施法吃掉攻击配额

        r.impact = target
        switch stat.effect {
        case .damage:
            applySpellDamage(focus, stat.power, caster: caster, to: &r)
            if stat.splash > 0 && stat.splashRadius > 0 {
                for p in cellsInRadius(target.x, target.y, radius: stat.splashRadius) where p != target {
                    guard let v = getUnitAt(p), v.camp != caster.camp else { continue }
                    applySpellDamage(v, stat.splash, caster: caster, to: &r)
                }
            }
            r.message = "\(stat.name)：中心 \(stat.power)" + (stat.splash > 0 ? "，溅射 \(stat.splash)" : "")
        case .heal:
            let healed = focus.heal(stat.power)
            r.affected[target] = healed
            r.message = "\(stat.name) +\(healed)"
        case .stun:
            focus.stunned = true
            r.stunnedTarget = true
            r.affected[target] = 1
            r.message = "\(focus.name) 被冻结，本回合无法行动"
        }
        version += 1
        r.success = true
        return r
    }

    /// 魔法伤害落账（固定值，不走 `damageTo`：防御与地形一律无视）
    private func applySpellDamage(_ unit: WarUnit, _ amount: Int, caster: WarUnit, to r: inout SpellResult) {
        guard unit.camp != caster.camp, !unit.isDead else { return }
        let applied = unit.takeDamage(amount)
        r.affected[unit.position] = (r.affected[unit.position] ?? 0) + applied
        if unit.isDead {
            unitGrid[unit.y][unit.x] = nil
            r.killed.append(unit.position)
        }
    }

    /// 放置一个新单位（布阵阶段用）。返回是否成功。
    @discardableResult
    public func place(_ unit: WarUnit) -> Bool {
        guard !unit.isDead, isInside(unit.x, unit.y), isCellAvailable(unit.x, unit.y) else { return false }
        units.append(unit)
        unitGrid[unit.y][unit.x] = unit
        version += 1
        return true
    }

    /// 强制放置（布阵用，不校验配额）
    @discardableResult
    public func forcePlace(_ unit: WarUnit, x: Int, y: Int) -> Bool {
        guard !unit.isDead, isCellAvailable(x, y) else { return false }
        unitGrid[unit.y][unit.x] = nil
        unit.x = x
        unit.y = y
        unitGrid[y][x] = unit
        version += 1
        return true
    }

    /// 抹掉一个布阵单位（**仅限布阵阶段**）。
    ///
    /// 战斗开始后禁止使用：`snapshot()/restore()` 是按 `units` 下标对齐的，
    /// 中途删元素会让回合计划的重放错位（所以击杀只腾空占位格、不删数组元素）。
    @discardableResult
    public func removeForPlacement(id: Int) -> Bool {
        guard let index = units.firstIndex(where: { $0.id == id }) else { return false }
        let unit = units[index]
        guard unitGrid.indices.contains(unit.y), unitGrid[unit.y][unit.x] === unit else { return false }
        unitGrid[unit.y][unit.x] = nil
        units.remove(at: index)
        version += 1
        return true
    }

    // MARK: - 战场评估（战略层输入）

    /// 兵力重心（质量 = hp × 兵种价值），用作战略目标点
    public func centerOfMass(camp: Int) -> GridPoint {
        let alive = unitsOfCamp(camp)
        guard !alive.isEmpty else { return GridPoint(x: width / 2, y: height / 2) }
        var wsum = 0.0, sx = 0.0, sy = 0.0
        for u in alive {
            let w = Double(u.hp) / 100.0 * u.value
            wsum += w
            sx += Double(u.x) * w
            sy += Double(u.y) * w
        }
        guard wsum > 0 else { return GridPoint(x: alive[0].x, y: alive[0].y) }
        return GridPoint(x: Int((sx / wsum).rounded()), y: Int((sy / wsum).rounded()))
    }

    public func materialScore(camp: Int) -> Double {
        unitsOfCamp(camp).reduce(0) { $0 + Double($1.hp) / 100.0 * $1.value }
    }

    // MARK: - 终局规则（唯一权威：App 与 AI 自对弈共用同一个口径）

    public enum EndReason: String, Sendable {
        case beheaded      // 首领阵亡（斩首）
        case wipeout       // 士兵全灭
    }

    public enum MatchOutcome: Equatable, Sendable {
        case ongoing
        /// winner = -1 为平局（两败俱伤且物质分相同）
        case ended(winner: Int, reason: EndReason)
    }

    /**
     判据优先级：首领阵亡 > 士兵全灭。
     斩首压倒歼灭：首领一死就地结束，即使它部队还剩一半 —— 士气崩了不该比丢兵慢。

     参数 `camp` 是当前行动方，只用于两败俱伤时的兜底口径（胜者 id 与它无关）。
     这条规则必须在内核而非 UI 层：AI 的 `chiefBounty` 评分项要对应真实的胜利条件，
     否则它会为了一个“不值得抢”的目标阵型变形（难度阶梯实测就是这样退化的）。
     */
    public func matchOutcome(forTurnOf camp: Int) -> MatchOutcome {
        let enemy = campOf(otherThan: camp)
        let lostSelfChief = isChiefLost(camp: camp)
        let lostEnemyChief = isChiefLost(camp: enemy)
        if lostSelfChief || lostEnemyChief {
            if lostSelfChief && lostEnemyChief {
                return .ended(winner: materialWinner(), reason: .beheaded)
            }
            return .ended(winner: lostEnemyChief ? camp : enemy, reason: .beheaded)
        }
        let mySoldiersGone = unitsOfCampExcludingChief(camp).isEmpty
        let enemySoldiersGone = unitsOfCampExcludingChief(enemy).isEmpty
        if mySoldiersGone || enemySoldiersGone {
            if mySoldiersGone && enemySoldiersGone {
                return .ended(winner: materialWinner(), reason: .wipeout)
            }
            return .ended(winner: enemySoldiersGone ? camp : enemy, reason: .wipeout)
        }
        return .ongoing
    }

    /// 两败俱伤（或打满回合上限）时的兜底：比物质分，同分计平（-1）
    public func materialWinner() -> Int {
        let s0 = materialScore(camp: 0), s1 = materialScore(camp: 1)
        return s0 > s1 ? 0 : (s1 > s0 ? 1 : -1)
    }

    // MARK: - 快照 / 回滚（AI 前瞻与行动回放共用）

    public func snapshot() -> [UnitState] { units.map { $0.toState() } }

    public func restore(_ states: [UnitState]) {
        guard states.count == units.count else { return }
        unitGrid = Array(repeating: Array(repeating: nil, count: width), count: height)
        for (i, unit) in units.enumerated() {
            unit.restoreState(states[i])
            if !unit.isDead && isInside(unit.x, unit.y) { unitGrid[unit.y][unit.x] = unit }
        }
        version += 1
    }

    // MARK: - 地图生成

    /// 左右镜像地形（保证对战公平）；x ≤ 2 留空以保住两侧出生区。
    /// 返回 **row-major** `map[y][x]`，可直接传给 `Battlefield.init(terrain:)`。
    public static func generateTerrain(width: Int, height: Int, seed: Int = 42) -> [[String]] {
        let half = width / 2
        var rng = SeededRng(seed: seed)
        var map = Array(repeating: Array(repeating: WarConfig.defaultTerrainKey, count: width), count: height)
        for y in 0..<height {
            for x in 0..<half {
                if x <= 2 { continue }                     // 出生列必须可通行
                let roll = rng.next()
                let key: String
                if roll < 0.62 { key = "plain" }
                else if roll < 0.80 { key = "forest" }
                else if roll < 0.90 { key = "hill" }
                else if roll < 0.96 { key = "water" }
                else { key = "wall" }
                map[y][x] = key
                map[y][width - 1 - x] = key               // 镜像
            }
        }
        // 保底通路：中央两列对称开敞（不能只开一列，否则破坏镜像）
        guard width >= 4, half >= 1 else { return map }
        for y in 0..<height {
            let a = WarConfig.terrains[map[y][half]]!.impassable
            let b = WarConfig.terrains[map[y][half - 1]]!.impassable
            if a || b {
                map[y][half] = "plain"
                map[y][half - 1] = "plain"
            }
        }
        return map
    }

    /// 在指定阵营的出生区内找一个可通行空格；index 用于顺序落位。
    /// camp 0 从左侧列起，camp 1 从右侧列起（镜像），保证两军不致于同侧出生。
    public func findSpawnSpot(camp: Int, _ index: Int) -> GridPoint? {
        let colCount = min(WarConfig.deployColumnCount, width)
        let orderedX: [Int] = (0..<colCount).flatMap { i -> [Int] in
            camp == 0 ? [i] : [width - 1 - i]
        }
        var seen = 0
        // 先行后列：先把出生区摊成 3 列宽的前锋线，避免单位堆成一列互相堵路
        for y in 0..<height {
            for x in orderedX {
                if !isCellAvailable(x, y) { continue }
                if seen == index { return GridPoint(x: x, y: y) }
                seen += 1
            }
        }
        // 出生区不够（单位过多）：退而求其次找全场任意空格
        if seen > 0 {
            for x in orderedX {
                for y in 0..<height where isCellAvailable(x, y) { return GridPoint(x: x, y: y) }
            }
        }
        for y in 0..<height {
            for x in 0..<width where isCellAvailable(x, y) { return GridPoint(x: x, y: y) }
        }
        return nil
    }

    /// 默认布阵：双方各放一支军队，**首领必带、免费、不占兵位**。
    /// id 规则固定（阵营 0 从 100 起、阵营 1 从 200 起），便于测试与回放对齐。
    ///
    /// `difficultyKey == nil` 走基线编成（6 兵 tier1、首领无充能）：
    /// 内核回归与冒烟指纹都钉在这条路径上，不传难度时一个数值都不该漂。
    /// 传难度键则该档军费交 `ArmyComposer` 配兵；`camp` 只编这一侧
    /// （vsAI 下玩家那侧由布阵/钱包负责，敌方那侧才按预算走）。
    @discardableResult
    public func setDefaultLayout(difficultyKey: String? = nil, camp targetCamp: Int? = nil) -> Bool {
        let plan = ArmyComposer.compose(difficultyKey: difficultyKey) ?? ArmyComposer.baselinePlan
        var allPlaced = true
        for camp in (targetCamp.map { [$0] } ?? [0, 1]) {
            if !placeArmy(plan, camp: camp) { allPlaced = false }
        }
        return allPlaced
    }

    /// 按编成落位一侧。落位顺序按数组下标逐个往后排，避免单位堆叠在同一格。
    @discardableResult
    public func placeArmy(_ plan: ArmyPlan, camp: Int) -> Bool {
        let baseId = camp == 0 ? 100 : 200
        var ok = true
        for (i, soldier) in plan.soldiers.enumerated() {
            guard let spot = findSpawnSpot(camp: camp, i) else { ok = false; continue }
            let unit = WarUnit(id: baseId + i, type: soldier.typeKey, camp: camp,
                               x: spot.x, y: spot.y, tier: soldier.tier)
            if unitGrid[spot.y][spot.x] == nil {
                units.append(unit)
                unitGrid[spot.y][spot.x] = unit
                version += 1
            } else {
                ok = false
            }
        }
        // 首领排在士兵之后（index = 士兵数），id 顺延不撞号
        guard let chiefSpot = findSpawnSpot(camp: camp, plan.soldiers.count) else { return false }
        guard unitGrid[chiefSpot.y][chiefSpot.x] == nil else { return false }
        let chief = WarUnit(id: baseId + plan.soldiers.count, type: WarConfig.chiefTypeKey,
                            camp: camp, x: chiefSpot.x, y: chiefSpot.y)
        chief.carrySpells(plan.spellCharges)   // 唯一入口：买到的发数在布阵时就钉死
        units.append(chief)
        unitGrid[chiefSpot.y][chiefSpot.x] = chief
        version += 1
        return ok
    }
}

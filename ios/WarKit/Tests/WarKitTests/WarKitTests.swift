import XCTest
@testable import WarKit

/// 内核回归测试。
///
/// 这些用例是从 JS 原型移植过来的**验收门槛**：JS 侧 27 项全绿之后才谈移植，
/// Swift 侧同样要求全绿。其中标了 [P0] 的用例对应原型里"移动免费 / AI 无限走"
/// 那一类致命规则漏洞，一旦回归说明状态机又被写坏了。
final class WarKitTests: XCTestCase {

    // MARK: - 夹具

    /// 全平原地图（row-major `m[y][x]`），可指定若干格的地形（坐标为 x, y）
    func map(_ w: Int, _ h: Int, _ marks: [(Int, Int, String)] = []) -> [[String]] {
        var m = Array(repeating: Array(repeating: "plain", count: w), count: h)
        for (x, y, k) in marks { m[y][x] = k }
        return m
    }

    func field(_ w: Int, _ h: Int, _ marks: [(Int, Int, String)] = [],
               _ units: [WarUnit] = []) -> Battlefield {
        Battlefield(width: w, height: h, terrain: map(w, h, marks), units: units)
    }

    func unit(_ id: Int, _ type: String, _ camp: Int, _ x: Int, _ y: Int, hp: Int? = nil) -> WarUnit {
        let u = WarUnit(id: id, type: type, camp: camp, x: x, y: y)
        if let hp { u.hp = hp }
        return u
    }

    func context(_ bf: Battlefield, camp: Int, difficulty: String = "normal", seed: Int = 1) -> AiContext {
        let ctx = AiContext(bf: bf, camp: camp,
                            difficulty: WarConfig.difficulties[difficulty]!,
                            rng: SeededRng(seed: seed))
        ctx.prepareTurn()
        return ctx
    }

    // MARK: - [P0] 移动与配额

    func testMoveConsumesBudgetAndUpdatesGrid() {
        let u = unit(1, "infantry", 0, 0, 0)          // mv4
        let bf = field(8, 8, [], [u])
        let r = bf.moveAlongPath(u, path: [GridPoint(x: 0, y: 0), GridPoint(x: 1, y: 0), GridPoint(x: 2, y: 0)])
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.spent, 2)
        XCTAssertEqual(u.remainingMove, 2, "[P0] 移动必须真正扣点")
        XCTAssertEqual([u.x, u.y], [2, 0])
        XCTAssertTrue(bf.getUnitAt(2, 0) === u, "占位格必须同步更新")
        XCTAssertNil(bf.getUnitAt(0, 0))
    }

    func testDiagonalMoveRejectedWithoutSideEffects() {
        let u = unit(1, "infantry", 0, 0, 0)
        let bf = field(8, 8, [], [u])
        let r = bf.moveAlongPath(u, path: [GridPoint(x: 0, y: 0), GridPoint(x: 1, y: 1)])
        XCTAssertFalse(r.success, "[P0] 禁止斜走")
        XCTAssertEqual([u.x, u.y], [0, 0])
        XCTAssertEqual(u.remainingMove, 4, "非法移动不得扣点")
        XCTAssertTrue(bf.getUnitAt(0, 0) === u, "非法移动不得留下占位脏状态")
    }

    func testTerrainMoveCostAndImpassable() {
        let u = unit(1, "infantry", 0, 0, 0)          // mv4
        let bf = field(8, 8, [(1, 0, "forest"), (2, 0, "hill"), (3, 0, "water")], [u])
        // 平原1 + 森林2 + 山地3 = 6 > 4 → 只能走到森林
        let r = bf.moveAlongPath(u, path: (0...3).map { GridPoint(x: $0, y: 0) })
        XCTAssertTrue(r.success)
        XCTAssertEqual([u.x, u.y], [1, 0], "预算不足时应停在最后可达格")
        XCTAssertEqual(u.remainingMove, 2)

        let u2 = unit(2, "infantry", 0, 0, 4)
        let bf2 = field(8, 8, [(1, 4, "water")], [u2])
        XCTAssertFalse(bf2.moveAlongPath(u2, path: [GridPoint(x: 0, y: 4), GridPoint(x: 1, y: 4)]).success,
                       "河流不可通行且不得留下副作用")
        XCTAssertEqual([u2.x, u2.y], [0, 4])
        XCTAssertEqual(u2.remainingMove, 4)
    }

    func testAttackQuotaIsOnePerTurn() {
        let a = unit(1, "infantry", 0, 3, 3)
        let t = unit(2, "infantry", 1, 4, 3)
        let bf = field(8, 8, [], [a, t])
        let first = bf.attack(a, t)
        XCTAssertGreaterThan(first.damage, 0)
        XCTAssertEqual(a.remainingAttacks, 0)
        let hpAfterFirst = t.hp
        let second = bf.attack(a, t)
        XCTAssertEqual(second.damage, 0, "[P0] 攻击配额必须真正生效")
        XCTAssertEqual(t.hp, hpAfterFirst)
    }

    func testActingEndsMovementBudget() {
        // 出手即结束本回合行动：“先走位、后出手”是唯一顺序，反过来不行。
        let a = unit(1, "infantry", 0, 3, 3)
        let t = unit(2, "infantry", 1, 4, 3)
        let bf = field(8, 8, [], [a, t])
        _ = bf.attack(a, t)
        XCTAssertEqual(a.remainingMove, 0, "[P0] 攻击后不得再移动")
        XCTAssertEqual(Set(bf.computeReachable(a).keys), [a.position], "可达域应收拾到只剩自身格")

        // 施法同口径（否则“走 → 放”与“放 → 走”会变成两套时序）
        let chief = self.chief(3, camp: 0, 0, 3, spells: ["fireball"])
        let foe = unit(4, "infantry", 1, 1, 3)
        let bf2 = field(8, 8, [], [chief, foe])
        bf2.beginTurn(camp: 0)
        XCTAssertTrue(bf2.castSpell(chief, spell: "fireball", at: foe.position).success)
        XCTAssertEqual(chief.remainingMove, 0, "[P0] 施法后不得再移动")
    }

    func testDamageIsAttritionAndTerrainMatters() {
        let a = unit(1, "infantry", 0, 0, 0)
        let t1 = unit(2, "infantry", 1, 1, 0)
        let plainBF = field(6, 6, [], [a, t1])
        XCTAssertEqual(a.damageTo(t1), 28, "步兵打步兵 = 40 - 12")
        _ = plainBF.attack(a, t1)
        XCTAssertEqual(t1.hp, 72, "[P0] 不能一刀秒：消耗式节奏才有回合博弈")

        // 目标站森林（+12 防）→ 伤害降到 16
        let t2 = unit(3, "infantry", 1, 1, 0)
        let forestBF = field(6, 6, [(1, 0, "forest")], [a, t2])
        let dmg = a.damageTo(t2, targetTerrainDefBonus: forestBF.getTerrainDefBonus(1, 0))
        XCTAssertEqual(dmg, 16)
    }

    func testCounterAttackRules() {
        // 近战打近战 → 挨反击
        let a = unit(1, "infantry", 0, 0, 0)
        let t = unit(2, "infantry", 1, 1, 0)
        let bf = field(6, 6, [], [a, t])
        let r = bf.attack(a, t)
        XCTAssertEqual(r.counterDamage, 28, "步兵应反击")
        XCTAssertEqual(a.hp, 72)

        // 近战打弓兵 → 弓兵不反击
        let archer = unit(3, "archer", 1, 1, 0)
        let bf2 = field(6, 6, [], [a, archer])
        a.hp = 100
        let r2 = bf2.attack(a, archer)
        XCTAssertEqual(r2.counterDamage, 0, "弓兵 counterAttack=false 不得反击")

        // 一回合只反击一次
        let t3 = unit(4, "infantry", 1, 1, 0)
        let a2 = unit(5, "infantry", 0, 0, 0)
        let a3 = unit(6, "infantry", 0, 3, 0)
        let bf3 = field(8, 8, [], [a2, a3, t3])
        _ = bf3.attack(a2, t3)
        XCTAssertTrue(t3.hasCountered)
        let r3 = bf3.attack(a3, t3)
        XCTAssertEqual(r3.counterDamage, 0, "同一回合不得反击两次")
    }

    func testKillClearsGridButKeepsUnitsArrayStable() {
        let a = unit(1, "infantry", 0, 0, 0)
        let t = unit(2, "infantry", 1, 1, 0, hp: 20)
        let bystander = unit(3, "cavalry", 1, 2, 0)
        let bf = field(6, 6, [], [a, t, bystander])
        let countBefore = bf.units.count
        let r = bf.attack(a, t)
        XCTAssertTrue(r.targetKilled)
        XCTAssertNil(bf.getUnitAt(1, 0), "击杀后占位格必须腾空")
        XCTAssertEqual(bf.units.count, countBefore, "单位仍留在数组中（快照按下标对齐）")
        XCTAssertTrue(bf.units[1].isDead)
    }

    func testLineOfSightBlocking() {
        let archer = unit(1, "archer", 0, 0, 0)
        let target = unit(2, "infantry", 1, 2, 0)
        let openBF = field(6, 6, [], [archer, target])
        XCTAssertTrue(openBF.canAttackWithLineOfSight(archer, target))

        let blocked = field(6, 6, [(1, 0, "wall")], [archer, target])
        XCTAssertFalse(blocked.canAttackWithLineOfSight(archer, target), "中间有城墙应阻挡射击")
        XCTAssertEqual(blocked.attack(archer, target).damage, 0, "无视线不得结算伤害")
    }

    func testSnapshotRestoreRoundTrip() {
        let a = unit(1, "infantry", 0, 0, 0)
        let t = unit(2, "infantry", 1, 1, 0)
        let bf = field(6, 6, [], [a, t])
        let snap = bf.snapshot()
        _ = bf.moveAlongPath(a, path: [GridPoint(x: 0, y: 0), GridPoint(x: 0, y: 1)])
        _ = bf.attack(a, t)
        XCTAssertNotEqual(bf.snapshot(), snap)
        bf.restore(snap)
        XCTAssertEqual(bf.snapshot(), snap, "[P0] 快照/回滚必须逐字段还原（AI 前瞻依赖）")
        XCTAssertTrue(bf.getUnitAt(0, 0) === a)
    }

    // MARK: - [P1] 可达域与影响图

    func testReachableDomainRespectsBudgetAndOccupancy() {
        let u = unit(1, "infantry", 0, 3, 3)
        let blocker = unit(2, "cavalry", 1, 4, 3)
        let bf = field(10, 10, [(5, 3, "water")], [u, blocker])
        let reach = bf.computeReachable(u)
        XCTAssertEqual(reach[GridPoint(x: 3, y: 3)]?.cost, 0, "自身所在格算可达")
        XCTAssertNil(reach[GridPoint(x: 4, y: 3)], "被友军/敌军占位的格不可停")
        XCTAssertNil(reach[GridPoint(x: 5, y: 3)], "不可通行格不得进入")
        for (p, cell) in reach {
            XCTAssertLessThanOrEqual(cell.cost, u.remainingMove, "\(p) 超出预算")
            XCTAssertEqual(Grid.manhattan(u.position, p), Grid.manhattan(u.position, p))
            // 路径必须 4 邻接连续
            for i in 1..<cell.path.count {
                XCTAssertEqual(Grid.manhattan(cell.path[i - 1], cell.path[i]), 1, "路径出现斜走")
            }
        }
        // 预算参数化：影响图用满机动力，行动枚举用剩余机动力
        u.remainingMove = 1
        let small = bf.computeReachable(u)
        let full = bf.reachableWithBudget(u, budget: u.moveRange)
        XCTAssertLessThan(small.count, full.count, "[P1] 两种预算必须区分（原型曾用 hack 绕缓存）")
    }

    func testThreatMapUsesFullMobility() {
        let enemy = unit(1, "infantry", 1, 12, 7)     // mv4 rng1
        let bf = field(14, 14, [], [enemy])
        enemy.remainingMove = 0                        // 即使本回合已耗尽机动
        let threat = bf.buildThreatMap(camp: 1)
        XCTAssertGreaterThan(bf.threatAt(threat, 12, 7), 0)
        XCTAssertGreaterThan(bf.threatAt(threat, 8, 7), 0, "[P1] 威胁=满机动可达域外扩射程")
        XCTAssertEqual(bf.threatAt(threat, 6, 7), 0, "超出威胁半径的格应为 0")
    }

    // MARK: - AI 决策质量

    func testAiPrefersLethalTarget() {
        let me = unit(1, "infantry", 0, 3, 3)
        let softKill = unit(2, "archer", 1, 4, 3, hp: 10)      // 45-6=39 ≥10 → 可杀
        let tough = unit(3, "infantry", 1, 2, 3, hp: 100)      // 打不死
        let bf = field(10, 10, [], [me, softKill, tough])
        let ctx = context(bf, camp: 0, difficulty: "nightmare")
        let ranked = WarAI(bf: bf).decideCandidates(ctx, me)
        XCTAssertEqual(ranked.first?.targetId, softKill.id, "能杀则优先杀（击杀收益最大）")
    }

    func testAiRejectsSuicidalAttack() {
        // 残血步兵（hp20）去撞满血守兵：我打它 28 打不死，它反手 28 直接把我打死。
        // 旁边给一个可无反击的残血弓兵作为“正常选项”，验证硬过滤不是一刀切掉攻击。
        let me = unit(1, "infantry", 0, 5, 5, hp: 20)
        let tough = unit(2, "infantry", 1, 5, 4)                 // 可反击且能反杀
        let soft = unit(3, "archer", 1, 6, 5, hp: 5)             // 一发带走且不反击
        let bf = field(12, 12, [], [me, tough, soft])
        let ctx = context(bf, camp: 0, difficulty: "nightmare")
        let ranked = WarAI(bf: bf).decideCandidates(ctx, me)

        XCTAssertFalse(ranked.isEmpty, "候选不得被过滤空")
        XCTAssertFalse(ranked.contains { Scorer.isSuicidalAttack(ctx, $0) },
                       "[P1] 必死又换不掉击杀的候选不得出现在候选集里")
        XCTAssertNotEqual(ranked.first?.targetId, tough.id, "AI 不应拿残血兵去撞能反杀自己的守兵")
        XCTAssertEqual(ranked.first?.targetId, soft.id, "无反击的击杀仍应排第一（过滤没误伤好棋）")
    }

    func testArcherDoesNotChargeIntoMelee() {
        let archer = unit(1, "archer", 0, 2, 5)                // rng2
        let enemy = unit(2, "infantry", 1, 5, 5)               // 距离 3
        let bf = field(12, 12, [], [archer, enemy])
        let ctx = context(bf, camp: 0, difficulty: "nightmare")
        let ranked = WarAI(bf: bf).decideCandidates(ctx, archer)
        guard let chosen = ranked.first else { return XCTFail("无候选") }
        if let tid = chosen.targetId, tid == enemy.id {
            XCTAssertGreaterThanOrEqual(Grid.manhattan(chosen.action, enemy.position), 2,
                                       "远程单位不应贴脸输出")
        }
    }

    func testSoftmaxTemperatureMonotonic() {
        let me = unit(1, "cavalry", 0, 2, 2)
        let e1 = unit(2, "archer", 1, 6, 2)
        let e2 = unit(3, "infantry", 1, 2, 6)
        let bf = field(12, 12, [], [me, e1, e2])
        let ai = WarAI(bf: bf)
        let ctx = context(bf, camp: 0, difficulty: "normal")
        let ranked = ai.decideCandidates(ctx, me)
        guard ranked.count > 2 else { return XCTFail("候选过少，夹具不成立") }
        let best = ranked[0].score

        func regret(_ temperature: Double) -> Double {
            var rng = SeededRng(seed: 4242)
            var sum = 0.0
            for _ in 0..<400 {
                if let c = ai.sampleChoice(ranked, temperature: temperature, rng: &rng) {
                    sum += best - c.score
                }
            }
            return sum / 400.0
        }
        XCTAssertEqual(regret(0.0), 0, accuracy: 0.0001, "T=0 必须纯贪心")
        XCTAssertLessThan(regret(0.02), regret(0.9), "温度越高，平均后悔值越大（难度旋钮真实有效）")
    }

    func testTurnNeverOverSpendsBudget() {
        let bf = Battlefield(width: 14, height: 14, terrain: Battlefield.generateTerrain(width: 14, height: 14, seed: 9))
        XCTAssertTrue(bf.setDefaultLayout())
        let ai = WarAI(bf: bf)
        for turn in 0..<12 {
            bf.beginTurn(camp: 1)
            let ids = bf.unitsOfCamp(1).map(\.id)
            var startAtk: [Int: Int] = [:]
            for u in bf.unitsOfCamp(1) {
                startAtk[u.id] = u.remainingAttacks
            }
            let plan = ai.executeTurn(camp: 1, difficultyKey: "hard", seed: 1000 + turn)

            var spentByMove: [Int: Int] = [:]
            for ev in plan.events where ev.kind == .move {
                spentByMove[ev.unitId, default: 0] += ev.spent
            }
            for id in ids {
                guard let u = bf.findUnitById(id) else { continue }   // 可能已阵亡
                XCTAssertGreaterThanOrEqual(u.remainingMove, 0, "[P0] 机动点不得为负")
                XCTAssertGreaterThanOrEqual(u.remainingAttacks, 0, "[P0] 攻击配额不得为负")
                XCTAssertLessThanOrEqual(spentByMove[id] ?? 0, u.moveRange,
                                         "[P0] 一回合移动总量 ≤ 机动力")
                let attacksUsed = startAtk[id]! - u.remainingAttacks
                XCTAssertLessThanOrEqual(attacksUsed, WarConfig.maxAttacksPerTurn,
                                         "[P0] 一回合攻击次数 ≤ 配额")
            }
        }
    }

    func testReplayEventsReproduceFinalStateExactly() {
        let bf = Battlefield(width: 14, height: 14, terrain: Battlefield.generateTerrain(width: 14, height: 14, seed: 21))
        XCTAssertTrue(bf.setDefaultLayout())
        let ai = WarAI(bf: bf)
        for turn in 0..<8 {
            bf.beginTurn(camp: 0)
            let plan = ai.executeTurn(camp: 0, difficultyKey: "nightmare", seed: 500 + turn)
            XCTAssertFalse(plan.events.isEmpty)
            // 渲染层的做法：回到回合前，逐事件重放动画
            bf.restore(plan.before)
            for ev in plan.events { XCTAssertTrue(Replay.apply(bf, ev), "事件重放失败: \(ev.desc)") }
            XCTAssertEqual(bf.snapshot(), plan.final, "重放结果必须与 AI 推演结果逐字段一致")
            bf.restore(plan.final)
        }
    }

    func testSameSeedReproducesWholeMatch() {
        /// 整局事件流指纹（含伤害数字）：同 seed 必须逐字符相同
        func trace(_ seed: Int) -> String {
            let bf = Battlefield(width: 14, height: 14,
                                 terrain: Battlefield.generateTerrain(width: 14, height: 14, seed: 33))
            _ = bf.setDefaultLayout()
            let ai = WarAI(bf: bf)
            var out: [String] = []
            for turn in 0..<10 {
                for camp in [0, 1] {
                    bf.beginTurn(camp: camp)
                    let plan = ai.executeTurn(camp: camp, difficultyKey: "hard", seed: seed &+ turn &* 13)
                    out += plan.events.map { "\($0.unitId)\($0.kind.rawValue)\($0.to.x),\($0.to.y):\($0.damage)" }
                }
            }
            return out.joined(separator: "|")
        }
        let t = trace(77)
        XCTAssertEqual(t, trace(77), "[P1] 同 seed 必须完全可复现（可回放/可复算的前提）")
        XCTAssertTrue(t.contains { $0 != "|" } || t.count > 50, "夹具应确实产生事件")
        XCTAssertGreaterThan(t.split(separator: "|").count, 20, "10 回合应有足量事件参与比对")
    }

    // MARK: - 整局对局

    /// 双方全 AI 对局。**camp 归谁由 seed 奇偶决定，行动顺序固定 [0,1]**，
    /// 于是先手优势在两侧平分。（旧写法让顺序跟着 leftCamp 转，left 永远先手，
    /// 200 样本下能把同档自对弈测成 82/118 —— 那是工具偏差不是强弱。）
    /// 返回 +1 = left 胜，-1 = right 胜，0 = 平（物质分相同）。
    @discardableResult
    func duel(_ seed: Int, left: String, right: String,
              width: Int = 14, height: Int = 14, maxTurns: Int = 40) -> Int {
        let leftCamp = seed % 2 == 0 ? 0 : 1
        let bf = Battlefield(width: width, height: height,
                             terrain: Battlefield.generateTerrain(width: width, height: height, seed: seed))
        // 军费是第四个难度旋钮：两侧各自拿预算配兵。都用基线编成的话，
        // 量尺测到的只有智能，经济线（兵数/档位/充能）就被测丢了。
        XCTAssertTrue(bf.setDefaultLayout(difficultyKey: left, camp: leftCamp))
        XCTAssertTrue(bf.setDefaultLayout(difficultyKey: right, camp: bf.campOf(otherThan: leftCamp)))
        let ai = WarAI(bf: bf)
        let diffL = WarConfig.difficulties[left]!, diffR = WarConfig.difficulties[right]!
        for turn in 0..<maxTurns {
            for camp in [0, 1] {
                bf.beginTurn(camp: camp)
                _ = ai.executeTurn(camp: camp,
                                   difficulty: camp == leftCamp ? diffL : diffR,
                                   seed: seed &* 31 &+ turn &* 7 &+ camp)
                // 终局口径走内核（与 App 同一个 `matchOutcome`）：
                // 自己写一套“歼灭即结束”会把斩首测不到，难度阶梯量尺失真。
                if case .ended(let winner, _) = bf.matchOutcome(forTurnOf: camp) {
                    return winner == leftCamp ? 1 : (winner == -1 ? 0 : -1)
                }
            }
        }
        let l = bf.materialScore(camp: leftCamp)
        let r = bf.materialScore(camp: bf.campOf(otherThan: leftCamp))
        return l > r ? 1 : (r > l ? -1 : 0)
    }

    /// left 在 seeds 局中的胜场数
    func wins(_ left: String, _ right: String, seeds: [Int] = Array(1...40)) -> Int {
        seeds.reduce(0) { $0 + (duel($1, left: left, right: right) == 1 ? 1 : 0) }
    }

    /// 难度档位必须构成可测量的强弱阶梯。
    ///
    /// 阈值来自实测（release，`tools/Meter` 大样本定强弱、按样本量折算 −2σ 定回归值）。军费成为第
    /// 四个旋钮后， duel 两侧各自拿预算配兵，于是量尺测的是“智能 + 经济”合起来的真实难度。
    /// 反“自动送死”门禁（`weights.suicide` + 枚举层硬过滤）落地后送死（被反击致死且未击杀目标）
    /// 从 0.45~0.60 次/局降到 0.00 次/局，这一条在战场成长上线后仍然成立（200 样本 0.00/game）。
    ///
    /// **成长体系上线后重测 200 样本（release）**：nightmare vs easy = 100%、hard vs easy = 98.8%、
    /// hard vs normal = 64%、nightmare vs hard = 84% —— 阶梯仍单调，不需要回头调自杀权重。
    /// 但相邻档确实比旧值又收窄了一截（hard vs normal 74% → 64%）：双方现在都会靠打经验升级、
    /// 到 10 级转职，弱者因此被系统托了一把，强弱差被成长压薄是这套体系的预期副作用而非 bug。
    ///
    /// 相邻两对为什么把样本量提到 80：真正的分界是 50%，而 seed 窗口本身带偏差 ——
    /// **同档自对弈**在 1...40 上只有 40%、1...80 上 46.2%、1...120 上才是 50%。
    /// 也就是说 40 个 seed 的窗口对右边（后手方）白送约 7pp，hard vs normal 在这个窗口上实测
    /// 只有 52.5%（21/40），拿旧阈值 24 去卡它，报的是窗口噪声而不是档位倒挂。
    /// 窗口拉宽后噪声底（σ）按 √n 收缩，阈值取 release 均值 − 2σ：
    /// hard vs normal 51.2 − 8.6 → 42；nightmare vs hard 67.2 − 6.6 → 60。
    /// 注：跨度最大的两对已饱和到 98~100%，它们只能报“不能输”，所以仍按 40 样本卡。
    func testDifficultyOrderingWins() {
        XCTAssertGreaterThanOrEqual(wins("nightmare", "easy"), 36, "噩梦须碾压简单（智能 + 军费双重差距）")
        XCTAssertGreaterThanOrEqual(wins("hard", "easy"), 34, "困难须碾压简单")
        let adjacent = Array(1...80)
        XCTAssertGreaterThanOrEqual(wins("hard", "normal", seeds: adjacent), 42,
                                    "困难不得弱于普通（档位倒挂）")
        XCTAssertGreaterThanOrEqual(wins("nightmare", "hard", seeds: adjacent), 60,
                                    "噩梦不得弱于困难（档位倒挂）")
    }

    func testMatchConverges() {
        for seed in [5, 13] {
            let bf = Battlefield(width: 14, height: 14,
                                 terrain: Battlefield.generateTerrain(width: 14, height: 14, seed: seed))
            XCTAssertTrue(bf.setDefaultLayout())
            let ai = WarAI(bf: bf)
            var ended = false
            for turn in 0..<40 {
                bf.beginTurn(camp: 0)
                _ = ai.executeTurn(camp: 0, difficultyKey: "normal", seed: turn &* 31)
                if case .ended = bf.matchOutcome(forTurnOf: 0) { ended = true; break }
                bf.beginTurn(camp: 1)
                _ = ai.executeTurn(camp: 1, difficultyKey: "normal", seed: turn &* 31 &+ 7)
                if case .ended = bf.matchOutcome(forTurnOf: 1) { ended = true; break }
            }
            XCTAssertTrue(ended, "seed \(seed)：对局须在 40 回合内分出胜负（不能僵持）")
        }
    }

    // MARK: - 终局判据（斩首 > 歼灭，回合上限只能兜底活局）

    /// 需求原文：“把首领击败就彻底结束（不管是否剩下兵）”。
    /// 这条是**判据顺序**测试，不是“能不能结束”测试：只验后者会放过
    /// “先看兵全灭、再看首领”的反向写法 —— 那种写法下杀掉首领还要打下半场，
    /// 而 AI 的 chiefBounty 评分项也会和真实胜利条件脱钩。
    func testBeheadingOutranksWipeout() {
        let mine = chief(1, camp: 0, 0, 0, spells: ["fireball"])
        let foe = chief(2, camp: 1, 5, 5, spells: [])
        let ally = unit(3, "infantry", 0, 1, 0)
        let a = unit(4, "infantry", 1, 5, 4)
        let b = unit(5, "cavalry", 1, 4, 5)
        let c = unit(6, "archer", 1, 6, 6)
        let bf = field(8, 8, [], [mine, foe, ally, a, b, c])

        if case .ended = bf.matchOutcome(forTurnOf: 0) {
            XCTFail("满编且双方首领俱在，不该判出结局")
        }

        // 只死首领、一个兵都没少 → 就地终局，理由必须是斩首
        foe.hp = 0
        XCTAssertEqual(bf.unitsOfCampExcludingChief(1).count, 3, "敌方士兵一支未损（前提必须成立）")
        XCTAssertEqual(bf.unitsOfCampExcludingChief(0).count, 1, "我方也还有兵（不是两光光）")
        XCTAssertTrue(bf.isChiefLost(camp: 1), "敌方首领已失")
        XCTAssertFalse(bf.isChiefLost(camp: 0), "我方首领还在，不能被连坐")
        XCTAssertEqual(bf.matchOutcome(forTurnOf: 0), .ended(winner: 0, reason: .beheaded),
                       "[P0] 敌方首领阵亡即刻判胜，理由不得写成歼灭")
        XCTAssertEqual(bf.matchOutcome(forTurnOf: 1), .ended(winner: 0, reason: .beheaded),
                       "从败方回合视角看同一帧，也必须判自己负")

        // 首领与士兵同帧全灭 → 顺序在前者生效，理由仍是斩首
        a.hp = 0; b.hp = 0; c.hp = 0
        XCTAssertTrue(bf.unitsOfCampExcludingChief(1).isEmpty, "敌方士兵此时也确实全灭了")
        XCTAssertEqual(bf.matchOutcome(forTurnOf: 0), .ended(winner: 0, reason: .beheaded),
                       "两个条件同时成立时取斩首（判据顺序即语义）")

        // 兵全灭但两边首领都活着 → 这才是歼灭局
        let bf2 = field(8, 8, [], [chief(11, camp: 0, 0, 0, spells: []),
                                   chief(12, camp: 1, 5, 5, spells: []),
                                   unit(13, "infantry", 0, 1, 1),
                                   unit(14, "infantry", 1, 5, 4, hp: 20)])
        bf2.units[3].hp = 0
        XCTAssertFalse(bf2.isChiefLost(camp: 1), "歼灭局的首领必须还站着")
        XCTAssertEqual(bf2.matchOutcome(forTurnOf: 0), .ended(winner: 0, reason: .wipeout),
                       "敌方士兵全灭、首领俱在 → 判歼灭")

        // 双方首领同帧皆失 → 不硬判某方，按物质分兜底
        let bf3 = field(8, 8, [], [chief(21, camp: 0, 0, 0, spells: []), unit(22, "cavalry", 0, 1, 0),
                                   chief(23, camp: 1, 5, 5, spells: []), unit(24, "infantry", 1, 5, 4)])
        bf3.units[0].hp = 0; bf3.units[2].hp = 0
        XCTAssertEqual(bf3.matchOutcome(forTurnOf: 0),
                       .ended(winner: bf3.materialWinner(), reason: .beheaded),
                       "两败俱伤的斩首按物质分定胜者")
        XCTAssertEqual(bf3.materialWinner(), 0, "物质分该偏向兵多的一方（camp0 有骑兵）")

        // 没编首领的基线局不能被误判成斩首（内核回归与部分测试夹具走这条）
        let noChief = field(8, 8, [], [unit(31, "infantry", 0, 0, 0),
                                       unit(32, "infantry", 1, 3, 3),
                                       unit(33, "cavalry", 1, 4, 3)])
        XCTAssertFalse(noChief.isChiefLost(camp: 1), "本局就没带首领，谈不上阵亡")
        if case .ended = noChief.matchOutcome(forTurnOf: 0) {
            XCTFail("双方都无首领且兵力俱在，不得判出结局")
        }
        noChief.units[1].hp = 0
        XCTAssertEqual(noChief.matchOutcome(forTurnOf: 0), .ongoing,
                       "无首领局里敌方死一个兵只是减员，连歼灭都算不上")
    }

    // MARK: - 魔法（首领专属：三种效果 + 配额 + 快照）

    /// 带充能的首领夹具。充能只能在布阵时写入（`carrySpells`），
    /// 所以这里不直接改字段 —— 走的正是 App/AI 将来用的那一条入口。
    /// `charges` 是**每种**魔法的发数（三种充能价不同，分开计）。
    /// `levels` 是每种魔法的档位（军费买档 / 难度档的结果），缺省即基础档 0。
    func chief(_ id: Int, camp: Int, _ x: Int, _ y: Int,
               spells: [String], charges: Int = 3, levels: [String: Int] = [:]) -> WarUnit {
        let u = unit(id, WarConfig.chiefTypeKey, camp, x, y)
        var carried: [String: Int] = [:]
        for key in spells where WarConfig.spells[key] != nil { carried[key] = charges }
        u.carrySpells(carried, levels: levels)
        return u
    }

    func testCastSpellValidationChain() {
        let soldier = unit(1, "infantry", 0, 0, 1)
        let chief = chief(2, camp: 0, 0, 0, spells: ["fireball"])
        let foe = unit(3, "infantry", 1, 2, 0)
        let far = unit(4, "infantry", 1, 7, 7)
        let bf = field(9, 9, [], [soldier, chief, foe, far])
        bf.beginTurn(camp: 0)                       // 施法次数在回合开始时才配上
        XCTAssertEqual(chief.remainingSpell, WarConfig.maxSpellsPerTurn, "带充能的首领开局应有施法次数")

        let chargesAtStart = chief.charges(for: "fireball")
        XCTAssertEqual(chief.spellCharges.count, 1, "只买了火球，携带表里就只能有一项")
        // 1) 士兵没首领身份
        XCTAssertFalse(bf.castSpell(soldier, spell: "fireball", at: foe.position).success)
        // 2) 未携带的魔法（只买了火球）
        XCTAssertFalse(bf.castSpell(chief, spell: "heal", at: soldier.position).success)
        // 3) 超出射程
        XCTAssertFalse(bf.castSpell(chief, spell: "fireball", at: far.position).success)
        // 4) 目标阵营不对（火球不能轰自己人）
        XCTAssertFalse(bf.castSpell(chief, spell: "fireball", at: soldier.position).success)
        XCTAssertEqual(chief.charges(for: "fireball"), chargesAtStart, "[P0] 校验失败不得偷走充能")

        // 5) 正常施放：扣一发、吃掉攻击配额
        let r = bf.castSpell(chief, spell: "fireball", at: foe.position)
        XCTAssertTrue(r.success, r.message)
        XCTAssertEqual(chief.charges(for: "fireball"), chargesAtStart - 1)
        XCTAssertEqual(chief.remainingSpell, 0)
        XCTAssertEqual(chief.remainingAttacks, 0, "[P0] 施法与普攻互斥：一回合一个动作")
        XCTAssertEqual(foe.hp, 100 - WarConfig.spells["fireball"]!.power, "中心格吃满固定伤害")
    }

    func testSpellLevelScalesPowerSplashAndRange() {
        let base = WarConfig.spells["fireball"]!
        // 公式只有一份（`spellStat`）：没升过档就该原样返回，越界档位被钳到顶档
        XCTAssertEqual(WarConfig.spellStat("fireball", level: 0)?.power, base.power)
        XCTAssertEqual(WarConfig.spellStat("fireball", level: -5)?.range, base.range)
        XCTAssertEqual(WarConfig.spellStat("fireball", level: 1)?.power,
                       Int((Double(base.power) * 1.2).rounded()), "每档 +20%")
        XCTAssertEqual(WarConfig.spellStat("fireball", level: 1)?.splash,
                       Int((Double(base.splash) * 1.2).rounded()))
        XCTAssertEqual(WarConfig.spellStat("fireball", level: 99)?.range,
                       WarConfig.spellStat("fireball", level: WarConfig.maxSpellLevel)?.range,
                       "顶档射程 +1，且不因越界档位继续长大")
        XCTAssertEqual(WarConfig.spellUpgradeCost("fireball", currentLevel: 0), base.unlockCost)
        XCTAssertEqual(WarConfig.spellUpgradeCost("fireball", currentLevel: WarConfig.maxSpellLevel), .max,
                       "顶档不卖（调用侧据此直接拒绝，不特判级数）")

        // 基础档打不到的格（距离 4 > 射程 3），顶档（射程 4）能打到，且伤害按档位结算
        let far = GridPoint(x: 4, y: 0)
        let plain = chief(1, camp: 0, 0, 0, spells: ["fireball"])
        let p0 = unit(2, "infantry", 1, 4, 0)
        let bf0 = field(9, 9, [], [plain, p0])
        bf0.beginTurn(camp: 0)
        XCTAssertFalse(bf0.castSpell(plain, spell: "fireball", at: far).success, "基础档射程外应被拒")
        XCTAssertEqual(plain.charges(for: "fireball"), 3, "被拒的施法不扣充能")

        let top = chief(3, camp: 0, 0, 0, spells: ["fireball"], levels: ["fireball": WarConfig.maxSpellLevel])
        let p1 = unit(4, "infantry", 1, 4, 0)
        let bf1 = field(9, 9, [], [top, p1])
        bf1.beginTurn(camp: 0)
        let r = bf1.castSpell(top, spell: "fireball", at: far)
        XCTAssertTrue(r.success, r.message)
        XCTAssertEqual(p1.hp, p1.maxHp - (WarConfig.spellStat("fireball", level: WarConfig.maxSpellLevel)?.power ?? 0),
                       "[P0] 结算按施法者自持的档位（否则面板写 96、棋盘上烧 60）")
    }

    func testEnemyChiefCarriesDifficultySpellLevel() {
        // AI 不读玩家钱包：档位从难度档/关卡公式导出，经 ArmyPlan 写进敌方首领
        let plan = ArmyComposer.compose(difficultyKey: "nightmare")!
        XCTAssertFalse(plan.spellCharges.isEmpty, "噩梦档首领应带着充能上场")
        for (key, level) in plan.spellLevels {
            XCTAssertEqual(level, WarConfig.difficulties["nightmare"]?.spellLevel,
                           "携带的档位应统一取自难度旋钮")
            XCTAssertGreaterThan(plan.spellCharges[key] ?? 0, 0, "不该给没带发数的魔法记档")
        }
        let bf = field(14, 14)
        XCTAssertTrue(bf.placeArmy(plan, camp: 1))
        let aiChief = bf.chief(of: 1)
        XCTAssertEqual(aiChief?.spellLevels, plan.spellLevels, "[P0] 首领档位只能由布阵入口写入")

        // 简单档不练魔法；关数每 2 关一档且不超顶档
        XCTAssertEqual(ArmyComposer.compose(difficultyKey: "easy")?.spellLevels.isEmpty, true)
        XCTAssertEqual(WarConfig.campaignLevel(1).spellLevel, 0)
        XCTAssertEqual(WarConfig.campaignLevel(7).spellLevel, WarConfig.maxSpellLevel,
                       "顶档之后不随关数继续长大")
    }

    func testFireballIgnoresDefenseTerrainAndOnlyBurnsEnemies() {
        let stat = WarConfig.spells["fireball"]!
        // 中心站森林（+12 防）、施法者与友军在溅射圈内：都不该掉血
        let chief = chief(1, camp: 0, 0, 0, spells: ["fireball"])
        let ally = unit(2, "infantry", 0, 1, 1)
        let center = unit(3, "infantry", 1, 1, 0)
        let nearby = unit(4, "archer", 1, 2, 0)
        let bf = field(9, 9, [(1, 0, "forest")], [chief, ally, center, nearby])
        bf.beginTurn(camp: 0)

        let r = bf.castSpell(chief, spell: "fireball", at: center.position)
        XCTAssertTrue(r.success, r.message)
        XCTAssertEqual(r.affected[center.position], stat.power,
                       "[P0] 魔法伤害不吃防御与地形减伤（森林 +12 不能抹平它）")
        XCTAssertEqual(r.affected[nearby.position], stat.splash, "相邻敌方吃溅射")
        XCTAssertNil(r.affected[ally.position], "[P0] 溅射不得伤己方")
        XCTAssertNil(r.affected[chief.position], "[P0] 施法者自己不在伤害名单里")
        XCTAssertEqual(ally.hp, ally.maxHp)
        XCTAssertEqual(chief.hp, chief.maxHp)
        XCTAssertEqual(r.affectedPoints,
                       r.affectedPoints.sorted { $0.y != $1.y ? $0.y < $1.y : $0.x < $1.x },
                       "影响格必须按确定序输出（飘字/重放逐格对齐）")
    }

    func testHealClampsAtMaxHpAndRejectsFullTarget() {
        let stat = WarConfig.spells["heal"]!
        let chief = chief(1, camp: 0, 0, 0, spells: ["heal"])
        let hurt = unit(2, "infantry", 0, 1, 0, hp: 70)
        let full = unit(3, "cavalry", 0, 0, 2)
        let bf = field(9, 9, [], [chief, hurt, full])
        bf.beginTurn(camp: 0)

        XCTAssertFalse(bf.castSpell(chief, spell: "heal", at: full.position).success,
                       "满血目标不该被施法（否则 AI 会把发数打在没用的格子上）")
        XCTAssertEqual(chief.charges(for: "heal"), 3, "被拒的施法不扣充能")

        let hpBefore = hurt.hp
        let r = bf.castSpell(chief, spell: "heal", at: hurt.position)
        XCTAssertTrue(r.success, r.message)
        XCTAssertEqual(hurt.hp, hurt.maxHp, "[P0] 治疗不得超 maxHp")
        XCTAssertEqual(r.affected[hurt.position], min(stat.power, hurt.maxHp - hpBefore),
                       "实际生效量是被残血钳过的那个数（不是配置值）")
        XCTAssertEqual(chief.charges(for: "heal"), 2)
    }

    func testFreezeBlocksWholeTurnIncludingCounter() {
        let chief = chief(1, camp: 0, 0, 0, spells: ["freeze"])
        let foe = unit(2, "infantry", 1, 2, 0)
        let mate = unit(3, "infantry", 0, 1, 0)
        let bf = field(9, 9, [], [chief, foe, mate])
        bf.beginTurn(camp: 0)
        XCTAssertTrue(bf.castSpell(chief, spell: "freeze", at: foe.position).success)
        XCTAssertTrue(foe.stunned)

        // 轮到被冻方：配额全零、不可机动、不可普攻、不可反击
        bf.beginTurn(camp: 1)
        XCTAssertEqual([foe.remainingMove, foe.remainingAttacks], [0, 0], "[P0] 被冻单位本回合无任何行动配额")
        XCTAssertTrue(bf.computeReachable(foe).isEmpty, "被冻单位的可达域必须为空")
        XCTAssertEqual(bf.attack(foe, mate).damage, 0, "被冻单位不能主动攻击")
        XCTAssertFalse(foe.canCounter(mate), "被冻单位不能反击")

        // 只冻一回合：对手再开始回合即解冻，下个本方回合恢复正常
        bf.beginTurn(camp: 0)
        XCTAssertFalse(foe.stunned, "解冻必须在被冻方那个回合过去之后")
        bf.beginTurn(camp: 1)
        XCTAssertEqual(foe.remainingMove, foe.moveRange, "冰冻不跨回合累积")
        XCTAssertEqual(foe.remainingAttacks, WarConfig.maxAttacksPerTurn)
    }

    func testAttackAlsoClosesSpellSlot() {
        let chief = chief(1, camp: 0, 0, 0, spells: ["fireball"])
        let foe = unit(2, "infantry", 1, 1, 0)
        let bf = field(9, 9, [], [chief, foe])
        bf.beginTurn(camp: 0)
        XCTAssertGreaterThan(bf.attack(chief, foe).damage, 0)
        XCTAssertEqual(chief.remainingSpell, 0, "[P0] 动手了就没施法次数（反向也要互斥）")
        XCTAssertFalse(bf.castSpell(chief, spell: "fireball", at: foe.position).success)
        XCTAssertEqual(chief.charges(for: "fireball"), 3, "失败的施法不扣充能")
    }

    func testSnapshotCarriesSpellFields() {
        let chief = chief(1, camp: 0, 0, 0, spells: ["fireball", "freeze"], charges: 3)
        let foe = unit(2, "infantry", 1, 1, 0)
        let bf = field(9, 9, [], [chief, foe])
        bf.beginTurn(camp: 0)
        XCTAssertTrue(bf.castSpell(chief, spell: "fireball", at: foe.position).success)   // 花一发
        bf.beginTurn(camp: 0)                                     // 下一回合：施法次数重置
        XCTAssertTrue(bf.castSpell(chief, spell: "freeze", at: foe.position).success)     // 再花一发并写入 stunned

        let snap = bf.snapshot()
        chief.spellCharges = ["fireball": 99, "freeze": 99, "heal": 5]
        chief.remainingSpell = 7
        foe.stunned = false
        bf.restore(snap)
        XCTAssertEqual(chief.charges(for: "fireball"), 2, "[P0] 充能必须能被快照回滚（否则前瞻会多放一发）")
        XCTAssertEqual(chief.charges(for: "freeze"), 2, "每种魔法的充能各自独立扣，也各自回滚")
        XCTAssertNil(chief.spellCharges["heal"], "快照里没有的种类不能被脏写出来")
        XCTAssertEqual(chief.remainingSpell, 0)
        XCTAssertTrue(foe.stunned, "[P0] 冻结位也必须回滚，不然推演里的冰冻不会消失")
        XCTAssertEqual(snap, bf.snapshot(), "回滚后必须逐字段等于快照")
    }

    /// AI 接入的三处同接必须可测：施法事件要能被重放逐字段复现，且同 seed 两个体完全一致。
    func testAiCastsSpellsAndReplayMatchesLookahead() {
        func run(_ seed: Int) -> (trace: String, spellEvents: Int, replayOk: Bool) {
            let bf = Battlefield(width: 14, height: 14,
                                 terrain: Battlefield.generateTerrain(width: 14, height: 14, seed: 45))
            XCTAssertTrue(bf.setDefaultLayout())
            // 双方首领都带魔法：每种 3 发，共 9 发（经济成为第四个难度旋钮之前的内核能力基线）
            var chargesBefore: [Int: Int] = [:]
            for camp in [0, 1] {
                guard let c = bf.chief(of: camp) else { continue }
                c.carrySpells(["fireball": 3, "heal": 3, "freeze": 3])
                chargesBefore[c.id] = c.spellCharges.values.reduce(0, +)
            }
            let ai = WarAI(bf: bf)
            var out: [String] = [], spells = 0, replayOk = true
            for turn in 0..<6 {
                for camp in [0, 1] {
                    bf.beginTurn(camp: camp)
                    let plan = ai.executeTurn(camp: camp, difficultyKey: "nightmare",
                                              seed: seed &* 31 &+ turn &* 7 &+ camp)
                    bf.restore(plan.before)
                    for ev in plan.events {
                        if ev.kind == .spell { spells += 1 }
                        if !Replay.apply(bf, ev) { replayOk = false }
                        out.append("\(ev.unitId)\(ev.kind.rawValue)\(ev.spellKey ?? "-")")
                    }
                    if bf.snapshot() != plan.final { replayOk = false }
                }
            }
            // 充能总量单调不增（分种类计，逐 key 比太口水）
            for camp in [0, 1] {
                if let c = bf.chief(of: camp), let start = chargesBefore[c.id] {
                    XCTAssertLessThanOrEqual(c.spellCharges.values.reduce(0, +), start,
                                            "充能只能被花掉，不能长回来")
                }
            }
            return (out.joined(separator: "|"), spells, replayOk)
        }
        let a = run(7), b = run(7)
        XCTAssertTrue(a.replayOk, "[P0] 含施法的回合事件重放必须与推演逐字段一致")
        XCTAssertEqual(a.trace, b.trace, "[P1] 同 seed 两局（含施法）必须逐事件一致")
        XCTAssertGreaterThan(a.spellEvents, 0,
                             "首领每人带着 9 发三种魔法却一次没放，说明候选/评分链路断了")
    }

    // MARK: - 战场成长（经验 → 等级 → 属性点 → 10 级分支转职）

    /// 已累计的经验（把等级换回经验点数）：断言不必关心在哪一级跨过线
    func totalExp(_ u: WarUnit) -> Int {
        (1..<u.level).map(WarConfig.Growth.expToNext).reduce(0, +) + u.expIntoLevel
    }

    /// 升级曲线与发点节奏（1→10 共 360 点，每级 1 点）
    func testExpCurveGrantsLevelsAndPoints() {
        XCTAssertEqual((1..<WarConfig.Growth.baseLevelCap).map(WarConfig.Growth.expToNext).reduce(0, +),
                       360, "转职门槛的总需求必须能一眼算清")
        let a = unit(1, "infantry", 0, 0, 0)
        a.addExp(19)
        XCTAssertEqual(a.level, 1, "差 1 点不该提前升级")
        XCTAssertEqual([a.expIntoLevel, a.attrBank], [19, 0])
        a.addExp(1)
        XCTAssertEqual([a.level, a.expIntoLevel, a.attrBank], [2, 0, 1], "升级即发 1 点（玩家侧留着由 UI 分）")
        a.addExp(360)
        XCTAssertEqual([a.level, a.attrBank], [10, 9], "溢出经验按曲线连续升级")
        XCTAssertEqual(a.expIntoLevel, 0, "封顶后不再积累（留着也换不到东西）")
        a.addExp(-5)
        XCTAssertEqual([a.level, a.attrBank], [10, 9], "负数经验不得把等级倒退")
    }

    /// 经验只在战斗结算里发（五个来源都是确定量），所以同 seed 的两局必然一致
    func testCombatAwardsDeterministicExp() {
        // 出手 + 击杀（击杀赏金按目标战略价值折算：斩首比打折兵长经验）
        let a = unit(1, "infantry", 0, 0, 0)
        let t = unit(2, "infantry", 1, 1, 0, hp: 20)
        let targetValue = t.value
        let bf = field(6, 6, [], [a, t])
        let r = bf.attack(a, t)
        XCTAssertTrue(r.targetKilled)
        XCTAssertEqual(totalExp(a), WarConfig.Growth.hitExp(r.damage) + WarConfig.Growth.killExp(value: targetValue),
                       "[P0] 击杀经验 = 出手伤害 + 目标价值折算，两者都取**实际生效量**")

        // 挨打未死也算（远程无反击，才能单独测这一个来源）
        let shooter = unit(3, "archer", 0, 0, 0)
        let victim = unit(4, "infantry", 1, 2, 0)
        let bf2 = field(6, 6, [], [shooter, victim])
        let r2 = bf2.attack(shooter, victim)
        XCTAssertEqual(r2.counterDamage, 0, "夹具需无反击：否则两个来源混在一起")
        XCTAssertEqual(totalExp(shooter), WarConfig.Growth.hitExp(r2.damage), "只拿出手经验")
        XCTAssertEqual(totalExp(victim), WarConfig.Growth.sufferedExp(r2.damage), "挨一刀也长见识")

        // 治疗按**实际**回复量折半（飘字与经验必须是同一个数）
        let chief = self.chief(5, camp: 0, 0, 0, spells: ["heal"])
        let wounded = unit(6, "infantry", 0, 1, 0)
        let bf3 = field(6, 6, [], [chief, wounded])
        bf3.beginTurn(camp: 0)
        wounded.hp = 40
        let cast = bf3.castSpell(chief, spell: "heal", at: wounded.position)
        XCTAssertTrue(cast.success)
        XCTAssertEqual(totalExp(chief), WarConfig.Growth.healExp(cast.affected[wounded.position] ?? 0),
                       "治疗经验取实际回复量（溢出部分作废）")
        XCTAssertEqual(WarConfig.Growth.hitExp(999), 40, "出手伤害封顶 40：一发溦射不该把首领直接抬到满级")
    }

    /// 未转职 = 10 级封顶：升级、经验、加点三条口必须同时收手
    func testLevelCapUntilPromoted() {
        let a = unit(1, "infantry", 0, 0, 0)
        let bf = field(6, 6, [], [a])
        a.addExp(400)
        XCTAssertEqual([a.level, a.levelCap], [WarConfig.Growth.baseLevelCap, WarConfig.Growth.baseLevelCap])
        a.addExp(500)
        XCTAssertEqual([a.level, a.expIntoLevel], [10, 0], "封顶后经验直接作废，不留“转职就连升三级”的暗账")
        XCTAssertFalse(bf.allocate(a, track: .attack), "[P0] 满级未转职不得继续加点（先转职才花得出去）")
        XCTAssertTrue(bf.promote(a, to: "guard"))
        XCTAssertEqual(a.levelCap, WarConfig.Growth.promotedLevelCap, "转职把上限抬到 20")
        XCTAssertTrue(bf.allocate(a, track: .attack), "上限抬了，点数才重新花得出去")
        a.addExp(900)
        XCTAssertEqual(a.level, WarConfig.Growth.promotedLevelCap, "转职后能继续练到 20 级封顶")
    }

    /// 属性点只有一个写入点，而且每线加多少与兵种无关
    func testAttributePointsOnlyThroughKernel() {
        let a = unit(1, "infantry", 0, 0, 0)
        let bf = field(6, 6, [], [a])
        let (hp0, atk0, def0) = (a.maxHp, a.atk, a.def)
        XCTAssertFalse(bf.allocate(a, track: .attack), "1 级没有点数，按钮不该生效")
        a.addExp(WarConfig.Growth.expToNext(1))
        XCTAssertTrue(bf.allocate(a, track: .attack))
        XCTAssertEqual(a.atk, atk0 + WarConfig.Growth.perPointAtk)
        XCTAssertEqual([a.maxHp, a.def], [hp0, def0], "加攻不得顺手动到别的线")
        XCTAssertEqual(a.attrBank, 0)
        XCTAssertFalse(bf.allocate(a, track: .attack), "[P0] 点数花完不得再白加")
        a.addExp(WarConfig.Growth.expToNext(2))
        XCTAssertTrue(bf.allocate(a, track: .health))
        XCTAssertEqual(a.maxHp, hp0 + WarConfig.Growth.perPointHp, "加生命抬上限，而且当场补进当前血量")
        XCTAssertEqual(a.hp, a.maxHp, "升级/加点不得让满血子变残")
    }

    /// 转职：只有满 10 级的**该兵种**能走自己的两条路，且不可逆、不吃钱、保留首领语义
    func testPromotionRulesAndBranchStats() {
        let a = unit(1, "infantry", 0, 0, 0)
        let bf = field(8, 8, [], [a])
        XCTAssertFalse(bf.promote(a, to: "guard"), "未满 10 级不得转职")
        a.addExp(360)
        // 分支必须属于该兵种：步兵想转“王者”就是绕过斩首与施法资格
        XCTAssertFalse(bf.promote(a, to: "king"), "[P0] 士兵不能转成首领分支")
        XCTAssertFalse(bf.promote(a, to: "infantry"), "不能原地转自己")
        let hpBefore = a.hp
        XCTAssertTrue(bf.promote(a, to: "lancer"))
        XCTAssertEqual(a.typeKey, "lancer")
        XCTAssertEqual(a.name, "枪兵", "名字跟随当前形态")
        XCTAssertEqual(a.attackRange, 2, "枪兵拿到射程 2")
        XCTAssertEqual(a.type, "infantry", "基础兵种不改写：价目与升级账仍认它")
        XCTAssertFalse(bf.promote(a, to: "guard"), "只能转一次（换路 = 反悔）")
        XCTAssertGreaterThanOrEqual(a.hp, hpBefore, "上限抬高必须把差额补进当前血量")
        XCTAssertEqual(a.attrBank, WarConfig.Growth.grantedPoints(level: 10, promoted: true),
                       "转职再发 1 点，且应得总数 = 等级-1 + 转职那一点")

        let chief = self.chief(2, camp: 0, 3, 3, spells: ["heal"])
        let bf2 = field(8, 8, [], [chief])
        chief.addExp(360)
        XCTAssertTrue(bf2.promote(chief, to: "paladin"))
        XCTAssertTrue(chief.isChief, "[P0] 圣骑士仍是首领：斩首判据与施法资格不因转职漂移")
        XCTAssertEqual(chief.charges(for: "heal"), 3, "转职不吃魔法携带")
        bf2.beginTurn(camp: 0)
        chief.hp = 100                       // 转职把上限抬到了 190，先人为造成残血才能测治疗
        XCTAssertTrue(bf2.castSpell(chief, spell: "heal", at: chief.position).success, "转职后仍能施法")
    }

    /// 转职改了机动力上限时，剩余点数按差额补偿（不白送、也不偷走）
    func testPromotionCompensatesMovementBudget() {
        let fresh = unit(1, "cavalry", 0, 0, 0)          // mv7
        let bf = field(9, 9, [], [fresh])
        fresh.addExp(360)
        XCTAssertTrue(bf.promote(fresh, to: "scout"))     // mv8：本来就没走过 → 拿满新机动
        XCTAssertEqual([fresh.remainingMove, fresh.moveRange], [8, 8])

        let rider = unit(2, "cavalry", 0, 4, 0)
        let bf2 = field(9, 9, [], [rider])
        rider.addExp(360)
        rider.remainingMove = 2                            // 已经走了 5 格
        XCTAssertTrue(bf2.promote(rider, to: "heavy"))     // mv6：扣掉差额，不倒贴
        XCTAssertEqual(rider.remainingMove, 1, "转成更慢的形态要如实扣点（不能靠转职多走一步）")
    }

    /// AI / 观战侧不留点数：升级与转职那瞬间按兵种偏好循环分掉（纯函数、无随机）
    func testAutoGrowUnitsDistributePointsByPreference() {
        let a = WarUnit(id: 1, type: "infantry", camp: 1, x: 0, y: 0, autoGrows: true)
        let (hp0, atk0, def0) = (a.maxHp, a.atk, a.def)
        a.addExp(WarConfig.Growth.expToNext(1))
        XCTAssertEqual(a.attrBank, 0, "AI 手里不留待分点数（否则它永远不成长）")
        XCTAssertEqual(a.maxHp, hp0 + WarConfig.Growth.perPointHp, "前排循环从生命起步")
        a.addExp(WarConfig.Growth.expToNext(2))
        XCTAssertEqual(a.def, def0 + WarConfig.Growth.perPointDef, "第二点补防御")
        a.addExp(WarConfig.Growth.expToNext(3))
        XCTAssertEqual(a.atk, atk0 + WarConfig.Growth.perPointAtk, "第三点才轮到攻击")

        let shooter = WarUnit(id: 2, type: "archer", camp: 0, x: 1, y: 1, autoGrows: true)
        let atk1 = shooter.atk
        shooter.addExp(WarConfig.Growth.expToNext(1))
        XCTAssertEqual(shooter.atk, atk1 + WarConfig.Growth.perPointAtk, "输出兵种相反：先补攻击")

        // 成长字段全在快照里（AI 前瞻与回合重放靠它回滚）
        let snap = a.toState()
        a.addExp(WarConfig.Growth.expToNext(4))
        XCTAssertTrue(a.attrAlloc.hp > snap.attrAlloc.hp, "自动分点也要能被快照带走")
        a.restoreState(snap)
        XCTAssertEqual(a.toState(), snap, "[P0] 成长回滚必须逐字段一致")
    }

    /// 成长存盘快照：非法分支与超额点数不能把旧存档洗成一支怪军队
    func testGrowthSnapshotIsClampedOnLoad() {
        var dirty = WarConfig.Growth.UnitGrowth(level: 30, expIntoLevel: 99,
                                                alloc: WarConfig.Upgrades(atk: 9, def: 9, hp: 9),
                                                branch: "king")
        // 步兵带首领分支 + 超过应得的点数 + 超上限的等级 → 全部逐项钳回合法
        let u = WarUnit(id: 1, type: "infantry", camp: 0, x: 0, y: 0, growth: dirty)
        XCTAssertEqual(u.level, 10, "非法分支按未转职处理 → 等级跟着钳回 10")
        XCTAssertEqual(u.typeKey, "infantry", "非法分支不能把一个步兵变成王者")
        XCTAssertEqual(u.attrBank, 0, "等级钳住后多余点数一并削掉（不得白送）")
        XCTAssertEqual(u.attrAlloc.atk + u.attrAlloc.def + u.attrAlloc.hp, 9, "已分点数不得多于应得")
        XCTAssertTrue(WarConfig.Growth.grantedPoints(level: u.level, promoted: u.isPromoted)
                      >= u.attrAlloc.atk + u.attrAlloc.def + u.attrAlloc.hp)
        dirty = WarConfig.Growth.UnitGrowth(level: 10, branch: "lancer")
        let ok = WarUnit(id: 2, type: "infantry", camp: 0, x: 1, y: 0, growth: dirty)
        XCTAssertEqual(ok.level, 10, "合法分支则照单全收")
        XCTAssertEqual(ok.typeKey, "lancer")
    }

    /// AI 回合内的转职必须可重放、可复现（事件带 branchKey，推演与重放同一个 `promote`）
    func testAiPromotionIsReplayableAndDeterministic() {
        func run(_ seed: Int) -> (promotes: Int, maxLevel: Int, trace: String, replayOk: Bool) {
            let bf = Battlefield(width: 14, height: 14,
                                 terrain: Battlefield.generateTerrain(width: 14, height: 14, seed: 77))
            XCTAssertTrue(bf.setDefaultLayout())
            let ai = WarAI(bf: bf)
            var promotes = 0, out: [String] = [], replayOk = true
            for turn in 0..<30 {
                for camp in [0, 1] {
                    bf.beginTurn(camp: camp)
                    let plan = ai.executeTurn(camp: camp, difficultyKey: "nightmare",
                                              seed: seed &* 31 &+ turn &* 7 &+ camp)
                    bf.restore(plan.before)
                    for ev in plan.events {
                        if ev.kind == .promote {
                            promotes += 1
                            XCTAssertNotNil(ev.branchKey, "转职事件必须带分支，否则重放无从下手")
                        }
                        if !Replay.apply(bf, ev) { replayOk = false }
                        out.append("\(ev.unitId)\(ev.kind.rawValue)\(ev.branchKey ?? "-")")
                    }
                    if bf.snapshot() != plan.final { replayOk = false }
                    bf.restore(plan.final)
                }
                if case .ended = bf.matchOutcome(forTurnOf: 0) { break }
            }
            return (promotes, bf.units.map(\.level).max() ?? 0, out.joined(separator: "|"), replayOk)
        }
        let a = run(9)
        XCTAssertTrue(a.replayOk, "[P0] 含成长的回合重放必须与推演逐字段一致（成长字段全在快照里）")
        XCTAssertEqual(a.trace, run(9).trace, "[P1] 同 seed 两局的成长与转职必须逐事件一致")
        XCTAssertGreaterThan(a.maxLevel, 1, "整局里老兵必须真的练起了等级（否则经验链路根本没接上）")
        // 整局能不能打到 10 级看地图与打期，不是不变式；真正的不变式是蕴含关系：
        // “有人满级”就必须“有人转职”（否则 AI 侧的成长卡在 10 级不动）。
        if a.maxLevel >= WarConfig.Growth.promoteLevel {
            XCTAssertGreaterThan(a.promotes, 0, "已到 10 级却一条转职事件都没有 = 回合内成长链路断了")
        }
    }

    /// AI 回合内的转职：事件带 branchKey 且可逐字段重放（不依赖整局运气，所以单独立夹具）
    func testAiPromotionEventIsReplayableAndDifficultyDependent() {
        func run(difficulty: String, seed: Int) -> (branch: String?, replayOk: Bool, levelCap: Int, promotes: Int) {
            let veteran = WarConfig.Growth.UnitGrowth(level: WarConfig.Growth.promoteLevel)
            let mine = WarUnit(id: 1, type: "infantry", camp: 0, x: 3, y: 3,
                               autoGrows: true, growth: veteran)
            let foe = WarUnit(id: 2, type: "infantry", camp: 1, x: 5, y: 3)
            let bf = field(8, 8, [], [mine, foe])
            let ai = WarAI(bf: bf)
            bf.beginTurn(camp: 0)
            let plan = ai.executeTurn(camp: 0, difficultyKey: difficulty, seed: seed)
            let events = plan.events.filter { $0.kind == .promote }
            bf.restore(plan.before)
            var ok = true
            for ev in plan.events where !Replay.apply(bf, ev) { ok = false }
            // 重放之后那个子必须已经是转职形态（上限抬到 20），否则事件与盘面分成两套
            return (events.first?.branchKey, ok && bf.snapshot() == plan.final,
                    bf.findUnitById(1)?.levelCap ?? 0, events.count)
        }
        let normal = run(difficulty: "normal", seed: 3)
        XCTAssertEqual(normal.promotes, 1, "[P0] 满 10 级的 AI 单位应在决策前就转职")
        XCTAssertEqual(normal.branch, "guard", "低两档照表取第一个分支（简单 AI 不该看起来像在“做选择”）")
        XCTAssertTrue(normal.replayOk, "[P0] 转职事件必须能被重放（推演与重放调同一个 promote）")
        let hard = run(difficulty: "hard", seed: 3)
        XCTAssertEqual(hard.branch, "lancer", "高两档走偏好表：困难/噩梦的兵是“练过的”")
        XCTAssertEqual(hard.levelCap, WarConfig.Growth.promotedLevelCap, "转职后上限抬到 20")
        XCTAssertEqual(run(difficulty: "hard", seed: 9).branch, hard.branch,
                       "[P1] 分支选择不能掺随机：同难度任何 seed 都转同一条路")
    }

    // MARK: - 军费配兵（经济 = 第四个难度旋钮）

    /// 每种魔法的最低充能价：配兵循环收手时余款必须买不起任何东西
    var cheapestCharge: Int { WarConfig.spells.values.map(\.chargeCost).min()! }

    func testArmyComposerIsDeterministicAndWithinBudget() {
        for key in WarConfig.difficultyOrder {
            let plan = ArmyComposer.compose(difficultyKey: key)
            XCTAssertNotNil(plan, "已知难度键就该拿到预算")
            XCTAssertEqual(plan, ArmyComposer.compose(difficultyKey: key),
                           "[P0] 同预算两次编成逐字段全等（复现不变式的地基）")
            let budget = WarConfig.difficulties[key]!.budget
            XCTAssertEqual(plan!.spent + plan!.leftover, budget, "花掉的 + 剩下的 = 预算（不能凭空生钱）")
            XCTAssertLessThanOrEqual(plan!.soldierCount, WarConfig.soldiersPerSide, "士兵不能越过兵位上限")
            XCTAssertLessThan(plan!.leftover, cheapestCharge,
                              "余款必须花到买不动为止（否则军费旋钮漏花了）")
            for soldier in plan!.soldiers {
                XCTAssertGreaterThanOrEqual(soldier.upgrades.atk, 0)
                XCTAssertGreaterThanOrEqual(soldier.upgrades.def, 0)
                XCTAssertGreaterThanOrEqual(soldier.upgrades.hp, 0)
                XCTAssertNotEqual(soldier.typeKey, WarConfig.chiefTypeKey, "首领不花钱也不占兵位")
            }
        }
        XCTAssertNil(ArmyComposer.compose(difficultyKey: nil), "缺省难度键该退回基线，而不是买出一支空军队")
        XCTAssertNil(ArmyComposer.compose(difficultyKey: "nobody"), "未知难度键同样退回 nil，由调用方兜底")
    }

    /// 预算必须真的转化为强弱：兵数随难度单调不降，高档还买得起充能。
    func testArmyBudgetScalesArmySize() {
        let sizes = WarConfig.difficultyOrder.map { ArmyComposer.compose(difficultyKey: $0)!.soldierCount }
        XCTAssertEqual(sizes, sizes.sorted(), "士兵数不得随难度倒挂（\(WarConfig.difficultyOrder) → \(sizes)）")
        XCTAssertEqual(sizes.last, WarConfig.soldiersPerSide, "最高档应满编")
        XCTAssertLessThanOrEqual(sizes.first!, WarConfig.soldiersPerSide - 2, "最低档必须明显兵少")
        let poor = ArmyComposer.compose(difficultyKey: WarConfig.difficultyOrder.first!)!
        let rich = ArmyComposer.compose(difficultyKey: WarConfig.difficultyOrder.last!)!
        XCTAssertTrue(poor.spellCharges.isEmpty || rich.spellCharges.values.reduce(0, +)
                              >= poor.spellCharges.values.reduce(0, +),
                      "钱多的档位充能不能更少")
        XCTAssertGreaterThan(rich.spent, poor.spent, "高档必须真把钱花出去")
    }

    /// 升级路径在预算充足时必须走得通（四档现行预算下余款先喂了充能，
    /// 所以这里直接给一个大预算验证“质量”这半条经济线不是死代码）。
    func testArmyComposerBuysUpgradesWhenRich() {
        let plan = ArmyComposer.compose(budget: 400)
        XCTAssertEqual(plan.soldierCount, WarConfig.soldiersPerSide, "先买满兵再谈质量")
        XCTAssertTrue(plan.soldiers.contains { !$0.upgrades.isBase },
                      "余款必须买到升级（否则军费只是数量旋钮）")
        XCTAssertEqual(plan.spent + plan.leftover, 400)
        XCTAssertLessThan(plan.leftover, cheapestCharge)
    }

    /// 三线升级各自单调：升一条线只涨对应属性，value 恒定；升档费逐级变贵。AI 与玩家共用这张价目表。
    func testUpgradeTracksAreMonotonicAndValueStable() {
        for key in WarConfig.unitTypeOrder {
            let base = WarConfig.unitStat(key)!
            // 攻击线：atk 随等级不降（小基数四舍五入可致平台），hp/def 不动，value 恒定
            var prevAtk = base.atk
            var atk6 = base.atk
            for lv in 1...6 {
                let s = WarConfig.unitStat(key, upgrades: WarConfig.Upgrades(atk: lv))!
                XCTAssertGreaterThanOrEqual(s.atk, prevAtk, "\(key) 攻线 lv\(lv) atk 不能倒退")
                XCTAssertEqual(s.hp, base.hp, "攻线不该动 hp")
                XCTAssertEqual(s.def, base.def, "攻线不该动 def")
                XCTAssertEqual(s.value, base.value, "value 必须恒定（AI 口径稳定）")
                prevAtk = s.atk; atk6 = s.atk
            }
            XCTAssertGreaterThan(atk6, base.atk, "\(key) 攻线拉到 lv6 必须真变强")
            // 防御线：只涨 def
            var prevDef = base.def
            var def6 = base.def
            for lv in 1...6 {
                let s = WarConfig.unitStat(key, upgrades: WarConfig.Upgrades(def: lv))!
                XCTAssertGreaterThanOrEqual(s.def, prevDef, "\(key) 防线 lv\(lv) def 不能倒退")
                XCTAssertEqual(s.hp, base.hp, "防线不该动 hp")
                XCTAssertEqual(s.atk, base.atk, "防线不该动 atk")
                prevDef = s.def; def6 = s.def
            }
            XCTAssertGreaterThan(def6, base.def, "\(key) 防线拉到 lv6 必须真变强")
            // 生命线：只涨 hp
            var prevHp = base.hp
            var hp6 = base.hp
            for lv in 1...6 {
                let s = WarConfig.unitStat(key, upgrades: WarConfig.Upgrades(hp: lv))!
                XCTAssertGreaterThanOrEqual(s.hp, prevHp, "\(key) 命线 lv\(lv) hp 不能倒退")
                XCTAssertEqual(s.atk, base.atk, "命线不该动 atk")
                XCTAssertEqual(s.def, base.def, "命线不该动 def")
                prevHp = s.hp; hp6 = s.hp
            }
            XCTAssertGreaterThan(hp6, base.hp, "\(key) 命线拉到 lv6 必须真变强")
        }
        // 升档费随当前等级递增、无上限
        for key in WarConfig.unitTypeOrder {
            var prev = -1
            for lv in 0...6 {
                let cost = WarConfig.upgradeCost(typeKey: key, currentLevel: lv)
                XCTAssertGreaterThan(cost, prev, "\(key) 升级费必须逐级变贵")
                prev = cost
            }
        }
        // 首领不可升级
        XCTAssertEqual(WarConfig.upgradeCost(typeKey: WarConfig.chiefTypeKey, currentLevel: 0), Int.max)
    }

    /// 布阵入口：传难度才走预算，不传一字不变（冒烟指纹与既有回归靠这条钉住）
    func testDefaultLayoutOnlyUsesBudgetWhenDifficultyGiven() {
        let terrain = Battlefield.generateTerrain(width: 14, height: 14, seed: 64)
        let base = Battlefield(width: 14, height: 14, terrain: terrain)
        XCTAssertTrue(base.setDefaultLayout())
        XCTAssertEqual(base.unitsOfCampExcludingChief(0).count, WarConfig.defaultRoster.count)
        XCTAssertEqual(base.unitsOfCampExcludingChief(1).count, WarConfig.defaultRoster.count)
        for camp in [0, 1] { XCTAssertTrue(base.chief(of: camp)!.spellCharges.isEmpty, "基线不送充能") }

        let budgeted = Battlefield(width: 14, height: 14, terrain: terrain)
        let plan = ArmyComposer.compose(difficultyKey: "nightmare")!
        XCTAssertTrue(budgeted.setDefaultLayout(difficultyKey: "nightmare", camp: 1))
        XCTAssertTrue(budgeted.unitsOfCamp(0).isEmpty, "camp 参数只编这一侧")
        XCTAssertEqual(budgeted.unitsOfCampExcludingChief(1).count, plan.soldierCount)
        XCTAssertEqual(budgeted.chief(of: 1)!.spellCharges, plan.spellCharges, "买到的发数必须真的带上")
    }

    // MARK: - 地图

    func testTerrainIsMirroredAndSeedDeterministic() {
        let w = 14, h = 14
        let a = Battlefield.generateTerrain(width: w, height: h, seed: 123)
        let b = Battlefield.generateTerrain(width: w, height: h, seed: 123)
        XCTAssertEqual(a, b, "同 seed 地形必须一致")
        for y in 0..<h {
            for x in 0..<w {
                XCTAssertEqual(a[y][x], a[y][w - 1 - x], "地形必须左右镜像（对战公平）")
                if x <= 2 { XCTAssertEqual(a[y][x], "plain", "出生列必须可通行") }
            }
        }
        // 中央通路存在
        let mid = w / 2
        XCTAssertTrue((0..<h).allSatisfy { !WarConfig.terrains[a[$0][mid]]!.impassable })
    }

    func testDefaultLayoutPutsArmiesOnOppositeSides() {
        let bf = Battlefield(width: 14, height: 14,
                             terrain: Battlefield.generateTerrain(width: 14, height: 14, seed: 3))
        XCTAssertTrue(bf.setDefaultLayout())
        let left = bf.unitsOfCamp(0), right = bf.unitsOfCamp(1)
        // 首领不占士兵名额，所以满编是 roster + 1
        XCTAssertEqual(left.count, WarConfig.defaultRoster.count + 1)
        XCTAssertEqual(right.count, WarConfig.defaultRoster.count + 1)
        XCTAssertEqual(bf.chief(of: 0)?.camp, 0, "camp0 必须带首领")
        XCTAssertEqual(bf.chief(of: 1)?.camp, 1, "camp1 必须带首领")
        XCTAssertEqual(Set(bf.units.filter(\.isChief).map(\.camp)).count, 2, "每阵营恰好一名首领")
        let maxX = left.map(\.x).max()!, minX = right.map(\.x).min()!
        XCTAssertLessThanOrEqual(maxX, WarConfig.deployColumnCount - 1, "camp0 在左侧出生区")
        XCTAssertGreaterThanOrEqual(minX, 14 - WarConfig.deployColumnCount, "camp1 在右侧出生区")
        XCTAssertEqual(Set(bf.units.map(\.id)).count, bf.units.count, "单位 id 不得重复")
    }

    // MARK: - 性能（手机功耗预算的地基）

    func testTurnTimeWithinMobileBudget() throws {
        #if DEBUG
        // debug 下未优化，同一份代码慢 4~6 倍，卡这个阈值只会制造假报。
        // 发版构建永远是 -O，所以只在 release 跑：`swift test -c release`。
        // 写 XCTSkipIf 而不写 `throw XCTSkip(...)`：后者会被编译器看成无条件退出，
        // 下面的正文在 debug 构建里落进“不可达代码”，本项目的验收线是 0 警告。
        try XCTSkipIf(true, "性能门槛只在 release 下有参考意义（swift test -c release）")
        #endif
        let w = 18, h = 18
        let bf = Battlefield(width: w, height: h, terrain: Battlefield.generateTerrain(width: w, height: h, seed: 8))
        // 满编压力。写死 7 而**不引用** `WarConfig.maxUnitsPerSide`：这个常量从 10 调到了 7，
        // 引用常量的话以后上限再变小、这条测试会静默退化成轻载。
        // 掺进首领：它 value 最高，AI 每回合为它算的候选与目标评估最贵。
        let load = 7
        let types = ["commander", "infantry", "cavalry", "archer"]
        for camp in [0, 1] {
            for i in 0..<load {
                guard let spot = bf.findSpawnSpot(camp: camp, i) else { continue }
                XCTAssertTrue(bf.place(unit(1000 + camp * 100 + i, types[i % types.count], camp, spot.x, spot.y)))
            }
        }
        let ai = WarAI(bf: bf)

        func measure(_ difficulty: String) -> Double {
            var samples: [Double] = []
            for turn in 0..<7 {
                bf.beginTurn(camp: turn % 2)
                let plan = ai.executeTurn(camp: turn % 2,
                                          difficulty: WarConfig.difficulties[difficulty]!,
                                          seed: 4000 + turn)
                samples.append(plan.elapsedMs)
            }
            samples.sort()
            return samples[samples.count / 2]        // 中位数，避开 JIT 预热抖动
        }
        _ = measure("nightmare")                     // 预热
        let hard = measure("hard")
        let nightmare = measure("nightmare")
        XCTAssertLessThan(hard, 20, "18×18 满编 7v7 普通/困难回合金位应 < 20ms（实测 \(hard)ms）")
        XCTAssertLessThan(nightmare, 40, "噩梦（含前瞻）回合金位应 < 40ms（实测 \(nightmare)ms）")
    }
}

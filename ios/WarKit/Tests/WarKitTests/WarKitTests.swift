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
    /// 阈值来自实测（release，`WAR_MEASURE_SEEDS=200` 大样本定强弱、
    /// 40 样本定回归值）。军费成为第四个旋钮后， duel 两侧各自拿预算配兵，
    /// 于是量尺测的是“智能 + 经济”合起来的真实难度：
    /// nightmare vs easy = 200/200、hard vs easy = 200/200、
    /// hard vs normal = 176/200（88%）、nightmare vs hard = 165/200（82.5%）。
    /// 注：跨度最大的两对已饱和到 100%，它们只能报“不能输”；
    /// 真正有分辨力的是相邻两对（噪声底 nightmare 自对弈 = 95/105），
    /// 所以相邻档阈值按 40 样本的均值 −2σ 定，既卡住倒挂又不误报。
    func testDifficultyOrderingWins() {
        XCTAssertGreaterThanOrEqual(wins("nightmare", "easy"), 36, "噩梦须碾压简单（智能 + 军费双重差距）")
        XCTAssertGreaterThanOrEqual(wins("hard", "easy"), 34, "困难须碾压简单")
        XCTAssertGreaterThanOrEqual(wins("hard", "normal"), 30, "困难不得弱于普通（档位倒挂）")
        XCTAssertGreaterThanOrEqual(wins("nightmare", "hard"), 27, "噩梦不得弱于困难（档位倒挂）")
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
    func chief(_ id: Int, camp: Int, _ x: Int, _ y: Int,
               spells: [String], charges: Int = 3) -> WarUnit {
        let u = unit(id, WarConfig.chiefTypeKey, camp, x, y)
        var carried: [String: Int] = [:]
        for key in spells where WarConfig.spells[key] != nil { carried[key] = charges }
        u.carrySpells(carried)
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
                XCTAssertGreaterThanOrEqual(soldier.tier, 1)
                XCTAssertLessThanOrEqual(soldier.tier, WarConfig.maxTier)
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

    /// 升档路径在预算充足时必须走得通（四档现行预算下余款先喂了充能，
    /// 所以这里直接给一个大预算验证“质量”这半条经济线不是死代码）。
    func testArmyComposerBuysUpgradesWhenRich() {
        let plan = ArmyComposer.compose(budget: 400)
        XCTAssertEqual(plan.soldierCount, WarConfig.soldiersPerSide, "先买满兵再谈质量")
        XCTAssertTrue(plan.soldiers.contains { $0.tier > 1 },
                      "余款必须买到档位（否则军费只是数量旋钮）")
        XCTAssertEqual(plan.spent + plan.leftover, 400)
        XCTAssertLessThan(plan.leftover, cheapestCharge)
    }

    /// 档位数值与价格都必须单调：AI 与玩家共用这张价目表，倒挂会让配兵决策变成笑话
    func testTierStatsAndCostsAreMonotonic() {
        for key in WarConfig.unitTypeOrder {
            var prev: WarConfig.UnitStat?
            for tier in 1...WarConfig.maxTier {
                let s = WarConfig.unitStat(key, tier: tier)!
                if let prev {
                    XCTAssertGreaterThanOrEqual(s.hp, prev.hp, "\(key) tier\(tier) hp 不能倒退")
                    XCTAssertGreaterThanOrEqual(s.atk, prev.atk)
                    XCTAssertGreaterThanOrEqual(s.def, prev.def)
                    XCTAssertGreaterThan(s.value, prev.value, "AI 评分依赖 value 单调")
                }
                prev = s
            }
        }
        XCTAssertEqual(WarConfig.tierCosts.count, WarConfig.maxTier)
        XCTAssertTrue(zip(WarConfig.tierCosts, WarConfig.tierCosts.dropFirst()).allSatisfy { $0 < $1 },
                      "升档费必须逐档变贵")
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

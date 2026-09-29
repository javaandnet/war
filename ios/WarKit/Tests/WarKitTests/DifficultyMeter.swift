import XCTest
@testable import WarKit

/// 难度档位胜率量尺（默认跳过，只在需要重新标定时打开）。
///
/// `testDifficultyOrderingWins` 里的阈值就是这里量出来的。改动评分权重、
/// 前瞻结构或地形生成后，用这条命令复测并按实测值回填阈值：
///
///     WAR_MEASURE_DIFFICULTY=1 swift test -c release --filter DifficultyMeter
///
/// 关键设计：**轮流先手**。让 camp0 永远先动的话，先手节奏优势会盖过
/// AI 强弱差异，量出来的胜率不可信。
final class DifficultyMeter: XCTestCase {
    /// 返回 +1 = left 胜，-1 = right 胜，0 = 平
    func duel(_ seed: Int, left: String, right: String, size: Int = 14, maxTurns: Int = 40) -> Int {
        let leftCamp = seed % 2 == 0 ? 0 : 1
        let diffL = WarConfig.difficulties[left]!, diffR = WarConfig.difficulties[right]!
        let bf = Battlefield(width: size, height: size,
                             terrain: Battlefield.generateTerrain(width: size, height: size, seed: seed))
        // 与 `WarKitTests.duel` 同口径：两侧各拿自己那档的军费配兵，
        // 否则量尺只测智能，回传给 testDifficultyOrderingWins 的阈值就是假的。
        XCTAssertTrue(bf.setDefaultLayout(difficultyKey: left, camp: leftCamp))
        XCTAssertTrue(bf.setDefaultLayout(difficultyKey: right, camp: bf.campOf(otherThan: leftCamp)))
        let ai = WarAI(bf: bf)
        for turn in 0..<maxTurns {
            // 行动顺序固定 [0,1]，但 camp 归谁由 seed 奇偶轮流：
            // 先手优势在 left/right 之间平分，不会恒偏向某一边。
            // （旧写法用 `leftCamp == 0 ? [0,1] : [1,0]`，让 left 永远先手：
            // 200 样本下 nightmare 自对弈得出 82/118，那不是强弱而是工具偏差。）
            for camp in [0, 1] {
                bf.beginTurn(camp: camp)
                _ = ai.executeTurn(camp: camp,
                                   difficulty: camp == leftCamp ? diffL : diffR,
                                   seed: seed &* 31 &+ turn &* 7 &+ camp)
                if case .ended(let winner, _) = bf.matchOutcome(forTurnOf: camp) {
                    // 与 `testDifficultyOrderingWins` 同口径（内核 `matchOutcome`）：
                    // 量尺与断言如果用两套规则，回填的阈值就是假的。
                    return winner == leftCamp ? 1 : (winner == -1 ? 0 : -1)
                }
            }
        }
        let l = bf.materialScore(camp: leftCamp)
        let r = bf.materialScore(camp: bf.campOf(otherThan: leftCamp))
        return l > r ? 1 : (r > l ? -1 : 0)
    }

    func report(_ left: String, _ right: String, seeds: Int = 40) {
        var lw = 0, rw = 0, dr = 0
        for seed in 1...seeds {
            switch duel(seed, left: left, right: right) {
            case 1: lw += 1
            case -1: rw += 1
            default: dr += 1
            }
        }
        print("DUEL \(left) vs \(right): \(left)胜 \(lw) \(right)胜 \(rw) 平 \(dr)")
    }

    func testMeasureDifficultyLadder() throws {
        guard ProcessInfo.processInfo.environment["WAR_MEASURE_DIFFICULTY"] == "1" else {
            throw XCTSkip("手动量尺：设 WAR_MEASURE_DIFFICULTY=1 才会跑")
        }
        // 样本数可调：斩首规则下相邻高档已贴近噪声底（40 样本的 σ≈3.2 胜），
        // 想分清真倒挂与测不出差异，用 WAR_MEASURE_SEEDS=200 加大样本重测。
        let seeds = Int(ProcessInfo.processInfo.environment["WAR_MEASURE_SEEDS"] ?? "40") ?? 40
        report("nightmare", "easy", seeds: seeds)
        report("hard", "easy", seeds: seeds)
        report("hard", "normal", seeds: seeds)
        report("nightmare", "hard", seeds: seeds)
        report("nightmare", "nightmare", seeds: seeds)   // 自对弈 = 噪声底，应接近对半
    }
}

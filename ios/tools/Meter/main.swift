import Foundation
import WarKit

/// 临时量尺（ tuning 用，不入库）：整局对局 → 收敛性 / 施流量 / 难度单调性 / 成长节奏。
/// 用法： swift run 之后由 tools/meter.sh 编译执行。

func runGame(_ seed: Int, left: String, right: String, maxTurns: Int = 40)
    -> (result: Int, turns: Int, spells: Int, suicides: Int, promotes: Int, topLevel: Int) {
    let leftCamp = seed % 2 == 0 ? 0 : 1
    let bf = Battlefield(width: 14, height: 14,
                         terrain: Battlefield.generateTerrain(width: 14, height: 14, seed: seed))
    _ = bf.setDefaultLayout(difficultyKey: left, camp: leftCamp)
    _ = bf.setDefaultLayout(difficultyKey: right, camp: bf.campOf(otherThan: leftCamp))
    let ai = WarAI(bf: bf)
    let diffL = WarConfig.difficulties[left]!, diffR = WarConfig.difficulties[right]!
    var spells = 0, suicides = 0, promotes = 0
    func top() -> Int { bf.units.map(\.level).max() ?? 1 }
    for turn in 0..<maxTurns {
        for camp in [0, 1] {
            bf.beginTurn(camp: camp)
            let plan = ai.executeTurn(camp: camp,
                                      difficulty: camp == leftCamp ? diffL : diffR,
                                      seed: seed &* 31 &+ turn &* 7 &+ camp)
            for ev in plan.events {
                if ev.kind == .spell { spells += 1 }
                if ev.kind == .promote { promotes += 1 }
                if ev.counterKilled && !ev.killed { suicides += 1 }
            }
            if case .ended(let winner, _) = bf.matchOutcome(forTurnOf: camp) {
                return (winner == leftCamp ? 1 : (winner == -1 ? 0 : -1), turn + 1, spells, suicides,
                        promotes, top())
            }
        }
    }
    let l = bf.materialScore(camp: leftCamp)
    let r = bf.materialScore(camp: bf.campOf(otherThan: leftCamp))
    return (l > r ? 1 : (r > l ? -1 : 0), maxTurns, spells, suicides, promotes, top())
}

let n = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1])! : 20
let seeds = Array(1...n)

func report(_ left: String, _ right: String) {
    var wins = 0, losses = 0, draws = 0, turns = 0, spells = 0, suicides = 0, stalled = 0
    var promotes = 0, topLevel = 0, promotedGames = 0
    for s in seeds {
        let r = runGame(s, left: left, right: right)
        if r.result == 1 { wins += 1 } else if r.result == -1 { losses += 1 }
        if r.turns >= 40 { stalled += 1 }
        turns += r.turns; spells += r.spells; suicides += r.suicides
        promotes += r.promotes; topLevel = max(topLevel, r.topLevel)
        if r.promotes > 0 { promotedGames += 1 }
    }
    let games = Double(seeds.count)
    print(String(format: "%@ vs %@ : win=%d loss=%d draw=%d  winRate=%.1f%%  "
                 + "avgTurns=%.1f stalled=%d spells=%.1f/game suicide=%.2f/game  "
                 + "promote=%.2f/game (≥1次: %d局) topLv=%d",
                 left, right, wins, losses, draws, Double(wins) / games * 100,
                 Double(turns) / games, stalled,
                 Double(spells) / games, Double(suicides) / games,
                 Double(promotes) / games, promotedGames, topLevel))
}

let onlyAdjacent = CommandLine.arguments.contains("adjacent")
if !onlyAdjacent {
    report("normal", "normal")
    report("nightmare", "easy")
    report("hard", "easy")
}
report("hard", "normal")
report("nightmare", "hard")

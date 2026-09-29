import Foundation
import Combine
import WarKit

/// 功耗预算。
///
/// 战棋内核本身很轻（release 下 18×18 满编一回合中位数 < 20ms，噩梦含前瞻 < 40ms），
/// 真正常驻耗电的是**屏幕刷新 + 连续动画 + 高温下还在跑前瞻**。所以这里只管三件事：
///   1. `thermalState` 升到 serious/critical → 砍掉前瞻层（AI 仍用同一套评分，只是少算一层）
///   2. 系统低电量模式 → 30fps + 拉长动画节拍（少画帧，不是少算逻辑）
///   3. 自己不起任何定时器，一律靠通知 + 回合边界惰性读取，避免额外唤醒
///
/// 注意：降的是**算力**，不降任何单位数值 —— 玩家不会觉得"手机烫了敌军就变脆"。
@MainActor
final class PowerPolicy: ObservableObject {
    @Published private(set) var thermalState: ProcessInfo.ThermalState
    @Published private(set) var isLowPowerMode: Bool

    private var observers: [NSObjectProtocol] = []
    private let info = ProcessInfo.processInfo

    init() {
        thermalState = info.thermalState
        isLowPowerMode = info.isLowPowerModeEnabled

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .init("NSProcessInfoThermalStateDidChangeNotification"),
                                        object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        observers.append(nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func refresh() {
        let newThermal = info.thermalState
        let newLowPower = info.isLowPowerModeEnabled
        if newThermal != thermalState { thermalState = newThermal }
        if newLowPower != isLowPowerMode { isLowPowerMode = newLowPower }
    }

    /// 需要省算力的状态：低电量模式，或机身已经发热
    var shouldReduceWorkload: Bool {
        isLowPowerMode || thermalState == .serious || thermalState == .critical
    }

    /// 交给 SKView 的帧率：动画不需要 60fps，省电状态压到 30fps
    var preferredFPS: Int { shouldReduceWorkload ? 30 : 60 }

    /// 动画节拍倍率（>1 = 更慢、每步更长，但总帧数不变）
    var animationScale: Double { shouldReduceWorkload ? 1.35 : 1.0 }

    /// 温度/低电量下把前瞻层数压到 ≤1，其余旋钮不动。
    /// 军费原样往下传：它只在布阵时花一次，省电改兵额等于篡改玩家挑好的难度。
    func budgeted(_ difficulty: WarConfig.Difficulty) -> WarConfig.Difficulty {
        guard shouldReduceWorkload, difficulty.lookahead > 1 else { return difficulty }
        return WarConfig.Difficulty(key: difficulty.key, name: difficulty.name,
                                    temperature: difficulty.temperature,
                                    lookahead: 1,
                                    vision: difficulty.vision,
                                    noise: difficulty.noise,
                                    budget: difficulty.budget)
    }

    var statusLine: String {
        var parts: [String] = []
        switch thermalState {
        case .nominal: parts.append("温度正常")
        case .fair: parts.append("温度偏高")
        case .serious: parts.append("发热：前瞻已降为 1 层")
        default: parts.append("严重过热：算力已收窄")
        }
        if isLowPowerMode { parts.append("低电量模式：30fps") }
        return parts.joined(separator: " · ")
    }
}

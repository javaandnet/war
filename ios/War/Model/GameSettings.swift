import Foundation
import WarKit

/// 玩家可调项（持久化到 UserDefaults）。
///
/// 与内核配置分开：`WarConfig` 是"规则与数值权威"，这里是"这台手机上的偏好"。
/// seed 单独存，是为了让"同一张图 + 同一串随机"可以被完整复现（复盘/报 bug 用）。
struct GameSettings: Codable, Equatable {
    enum Mode: String, CaseIterable, Codable {
        case vsAI       // 我方（camp0）手动，敌方 AI
        case manual     // 本地双人，双方手动
        case aiVsAI     // 纯观战，双方 AI 自动

        var label: String {
            switch self {
            case .vsAI: return "对战 AI"
            case .manual: return "本地双人"
            case .aiVsAI: return "AI 自动对战"
            }
        }
    }

    var boardIndex: Int = 1                       // WarConfig.boardSizes 下标
    var terrainSeed: Int = 7
    var aiSeed: Int = 20260928
    var difficultyKey: String = WarConfig.defaultDifficultyKey
    var mode: Mode = .vsAI
    var stepDelayMs: Double = 120                  // 动画节拍（越小越快越费电）
    var showReach: Bool = true
    var showThreat: Bool = false
    var showBestMark: Bool = false
    /// 聚焦模式：开战后只留棋盘 + 一条迷你操作条，面板浮层按需展开。
    /// 竖屏宽度是单格尺寸的硬瓶颈，所以真正让格子变大的手段是缩放 + 平移。
    var focusMode: Bool = true
    /// 默认缩放倍数（相对“全图刚好可见”），1 = 全图
    var boardZoom: Double = 1.35

    var board: WarConfig.BoardSize {
        WarConfig.boardSizes[min(max(boardIndex, 0), WarConfig.boardSizes.count - 1)]
    }
    var difficulty: WarConfig.Difficulty {
        WarConfig.difficulties[difficultyKey] ?? WarConfig.difficulties[WarConfig.defaultDifficultyKey]!
    }

    static let userDefaultsKey = "war.game.settings.v2"   // v1 无 focusMode/boardZoom 字段，直接换新键

    static func load() -> GameSettings {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let saved = try? JSONDecoder().decode(GameSettings.self, from: data) else {
            return GameSettings()
        }
        return saved
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        }
    }
}

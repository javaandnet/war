import Foundation
import WarKit

/// 一帧棋盘（纯值类型）。
///
/// 渲染层只吃这个结构，不碰 `Battlefield` 引用类型 ——
/// 于是 SpriteKit 可以做差异更新，也从根上杜绝了"渲染层自己推算规则/伤害"，
/// 屏幕上出现的每个数字都来自内核事件（重放），不是 UI 猜的。
struct BoardFrame {
    struct UnitView: Identifiable, Equatable {
        let id: Int
        let camp: Int
        let x: Int
        let y: Int
        let type: String         // 兵种 key（图标映射用），内核权威字段
        let symbol: String       // 内核字母，取不到图标时的兜底显示
        let name: String
        let tier: Int            // 兵种档位（军费升档的结果，情报面板显示）
        let hp: Int
        let maxHp: Int
        let remainingMove: Int
        let remainingAttacks: Int
        let spent: Bool          // 本回合已无行动点（灰显）
        let selected: Bool
        let targetable: Bool     // 当前选中单位现在就能打到
        let isChief: Bool        // 首领（金色描边；唯一能施法的单位）
        let spellCharges: [String: Int]  // 本局每种魔法剩余发数（士兵恒为空）
        let stunned: Bool        // 被冻（蓝罩 + 本回合不能动）
    }

    struct Effect: Equatable {
        enum Kind: Equatable { case damage, counter, kill, spell, heal, freeze }
        let kind: Kind
        let x: Int
        let y: Int
        let text: String
    }

    let width: Int
    let height: Int
    let terrain: [[String]]                 // row-major，与内核同构
    let units: [UnitView]
    let reach: [GridPoint: Int]             // 选中单位可达格 → 机动力消耗
    let threat: [Double]?                   // 敌方威胁影响图（叠层关闭时为 nil）
    let bestMarks: [GridPoint: String]      // 上回合 AI 评分最高的落点
    let deployZoneCamp: Int?                // 布阵阶段高亮哪一方的出生区
    let objective: GridPoint?               // 本回合 AI 战略目标点
    let spellTargets: Set<GridPoint>        // 待施法时能命中的格（内核口径算出来的合法目标）
    let effects: [Effect]                   // 本帧新增的飘字（场景播完即忘）
    let revision: Int
}

/// 单位详情面板用的展开信息（含地形与威胁，避免 UI 再查一遍内核）
struct UnitInspection: Equatable {
    let unit: BoardFrame.UnitView
    let terrainName: String
    let terrainDefBonus: Int
    let moveCost: Int
    let attack: Int
    let defense: Int
    let attackRange: Int
    let counterAttack: Bool
    let threat: Double
}

import SwiftUI
import WarKit

/// 视觉常量。地形底色直接取内核 `WarConfig.terrains` 的 RGB ——
/// 内核是唯一数值权威，UI 不复制一份色表，避免"改了配置界面不变"。
enum Theme {
    static let accent = Color(red: 0.85, green: 0.72, blue: 0.35)

    /// 阵营色：camp0 蓝（我方），camp1 红（敌方）
    static let camp0 = Color(red: 0.25, green: 0.52, blue: 0.95)
    static let camp1 = Color(red: 0.92, green: 0.34, blue: 0.28)

    static func campColor(_ camp: Int) -> Color { camp == 0 ? camp0 : camp1 }

    static let boardBackground = Color(red: 0.09, green: 0.11, blue: 0.10)

    /// 可达格 / 威胁格 / 集火格的半透明叠色
    static let reachTint = Color(red: 0.35, green: 0.85, blue: 0.45).opacity(0.30)
    static let attackTint = Color(red: 1.0, green: 0.85, blue: 0.30).opacity(0.35)
    static let deployTint = Color(red: 0.30, green: 0.60, blue: 1.0).opacity(0.16)

    static func terrainColor(_ key: String) -> Color {
        let rgb = WarConfig.terrains[key]?.colorRGB
            ?? WarConfig.terrains[WarConfig.defaultTerrainKey]!.colorRGB
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// 威胁强度 → 不透明度（饱和值与内核评分用同一条尺子）
    static func threatOpacity(_ value: Double) -> Double {
        let sat = WarConfig.scale.threatSaturation
        return min(0.55, max(0, value) / max(1, sat) * 0.55)
    }

    /// 决策日志分项中文名（对应 Scorer 的 parts key）
    static let partNames: [String: String] = [
        "damage": "伤害", "kill": "击杀", "overkill": "过量", "selfPreserve": "自保",
        "targetValue": "目标价值", "rangePenalty": "贴脸浪费", "counter": "反击风险",
        "exposure": "暴露风险", "terrain": "地形", "focus": "集火", "surround": "包围",
        "mobility": "机动使用", "objective": "战略牵引", "support": "友军支援",
        "waste": "浪费行动", "engage": "接敌推进", "proximity": "接近度",
        "chiefBounty": "斩首赏金", "heal": "治疗量", "freeze": "冻结价值",
    ]

    static let strategyNames: [String: String] = [
        "attack": "进攻", "defend": "防守", "rush": "全面冲锋",
        "retreat": "脱离接触", "flank": "侧翼包抄",
    ]

    // MARK: - 兵种 / 地形图标
    //
    // 内核只供给字母（步兵 I / 骑兵 C / 弓兵 A）和 ASCII 地形符号，在手机上
    // 跟“一个方块”没有区别。图标映射属于表现层，所以放在 UI 侧，内核保持权威数值不变。
    // 取不到图标（系统版本不带该 symbol）时一律回退到内核字母，绝不能出现空白格。

    /// 兵种 key → SF Symbol（按兵种特性选形）。
    /// 首领不在 `WarConfig.unitTypeOrder`（它不入选兵器），所以图标契约按
    /// `unitTypes` 全量比对 —— 新增兵种漏配图标会被冒烟直接报出来。
    static let unitIcons: [String: String] = [
        "infantry": "person.fill",       // 近战、攻守均衡
        "cavalry": "hare.fill",          // 7 格高机动、冲锋
        "archer": "scope",               // 2 格远程、不反击
        "commander": "crown.fill",       // 首领：全军唯一能施法者，死了就输
    ]

    /// 地形 key → SF Symbol（平原不画图标，保持素面底纹）
    static let terrainIcons: [String: String] = [
        "forest": "tree.fill",
        "hill": "mountain.2.fill",
        "water": "drop.fill",
        "wall": "square.grid.2x2.fill",
    ]

    /// 魔法 key → SF Symbol。名字已逐个用 `NSImage(systemSymbolName:)` 在 macOS 侧验过
    /// （SF Symbol 拼错不会编译报错，只会在运行时返回 nil），取不到时回退内核符号。
    static let spellIcons: [String: String] = [
        "fireball": "flame.fill",
        "heal": "cross.fill",
        "freeze": "snowflake",
    ]

    static func unitIconName(for typeKey: String) -> String? { unitIcons[typeKey] }
    static func terrainIconName(for key: String) -> String? { terrainIcons[key] }
    static func spellIconName(for key: String) -> String? { spellIcons[key] }
}

/// 兵种图标（SwiftUI 侧）。与棋盘渲染共用同一张映射表，
/// 保证面板里看到的图标和格子上的是同一个形状。
struct UnitGlyph: View {
    let type: String
    let fallback: String

    var body: some View {
        if let name = Theme.unitIconName(for: type) {
            Image(systemName: name)
        } else {
            Text(fallback).fontWeight(.bold)
        }
    }
}

/// 地形图标（SwiftUI 侧），无图标的地形退回内核符号
struct TerrainGlyph: View {
    let key: String
    let fallback: String

    var body: some View {
        if let name = Theme.terrainIconName(for: key) {
            Image(systemName: name)
        } else {
            Text(fallback)
        }
    }
}

/// 魔法图标（SwiftUI 侧）。与棋盘上的首领徽标共用 `Theme.spellIcons`，
/// 所以“面板里那个雪花”与“首领角上那个雪花”一定是同一个形状。
struct SpellGlyph: View {
    let key: String
    let fallback: String

    var body: some View {
        if let name = Theme.spellIconName(for: key) {
            Image(systemName: name)
        } else {
            Text(fallback).fontWeight(.bold)
        }
    }
}

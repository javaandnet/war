import Foundation

/// 棋盘坐标（左上角为原点，x 向右、y 向下）。
public struct GridPoint: Hashable, Sendable {
    public let x: Int
    public let y: Int
    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

public enum Grid {
    /// 曼哈顿距离（战棋标准距离：斜向不算相邻）
    public static func manhattan(_ a: GridPoint, _ b: GridPoint) -> Int {
        abs(a.x - b.x) + abs(a.y - b.y)
    }

    public static func manhattan(_ ax: Int, _ ay: Int, _ bx: Int, _ by: Int) -> Int {
        abs(ax - bx) + abs(ay - by)
    }

    /// 4 方向邻居（**绝不产生斜向移动**）
    public static func neighbors4(_ p: GridPoint, width: Int, height: Int) -> [GridPoint] {
        var out: [GridPoint] = []
        out.reserveCapacity(4)
        if p.x > 0 { out.append(GridPoint(x: p.x - 1, y: p.y)) }
        if p.x < width - 1 { out.append(GridPoint(x: p.x + 1, y: p.y)) }
        if p.y > 0 { out.append(GridPoint(x: p.x, y: p.y - 1)) }
        if p.y < height - 1 { out.append(GridPoint(x: p.x, y: p.y + 1)) }
        return out
    }
}

/// 确定性种子随机（mulberry32）。
/// AI 依赖它做 softmax 采样与前瞻 rollout：同一 seed 下整场战斗可完全复现，
/// 这是回归测试与决策日志回放的前提。
public struct SeededRng {
    private var state: UInt32

    public init(seed: Int) {
        let v = UInt64(truncatingIfNeeded: seed) & 0xFFFF_FFFF
        state = UInt32(truncatingIfNeeded: v | 1)
    }

    public mutating func next() -> Double {
        state = state &+ 0x6D2B_79F5
        var t = state
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        return Double(((t ^ (t >> 14)) >> 0) & 0xFF_FFFF) / Double(1 << 24)
    }

    /// [0, upper) 整数
    public mutating func int(_ upper: Int) -> Int {
        guard upper > 1 else { return 0 }
        return min(Int(next() * Double(upper)), upper - 1)
    }

    public mutating func bool() -> Bool { next() < 0.5 }

    public mutating func pick<T>(_ items: [T]) -> T? {
        guard !items.isEmpty else { return nil }
        return items[int(items.count)]
    }

    public mutating func shuffle<T>(_ items: inout [T]) {
        var i = items.count
        while i > 1 {
            i -= 1
            let j = int(i + 1)
            items.swapAt(i, j)
        }
    }
}

// swift-tools-version:5.9
import PackageDescription

/// 战棋规则与 AI 内核。
/// 零 UI 依赖（不 import SpriteKit / UIKit），因此可以：
///   1. 在 macOS 上 `swift test` 直接跑回归测试，不需要模拟器；
///   2. 被 iPhone App target、将来可能的 watchOS/服务端共用同一份决策逻辑。
let package = Package(
    name: "WarKit",
    defaultLocalization: "zh-Hans",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WarKit", targets: ["WarKit"])
    ],
    targets: [
        .target(name: "WarKit", path: "Sources/WarKit"),
        .testTarget(name: "WarKitTests", dependencies: ["WarKit"], path: "Tests/WarKitTests")
    ]
)

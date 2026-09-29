import SwiftUI
import WarKit

/// iPhone 版入口。
///
/// 只有一个 `GameStore`（@MainActor）持有战场状态：内核不是 Sendable 的值类型，
/// 而且回合制游戏没有跨线程写状态的需求 —— 把状态钉死在主 actor 上，
/// 比给一堆内部结构加锁更省事也不会出错。AI 单回合实测 <40ms，主线程直接算。
@main
struct WarApp: App {
    @StateObject private var store = GameStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ContentView()
            }
            .navigationTitle("战棋 AI")
            .navigationBarTitleDisplayMode(.inline)
            .environmentObject(store)
            // 功耗策略单独注入：发热/低电量状态变化时只刷新相关视图
            .environmentObject(store.power)
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
            // 退到后台立即停表：既省电，也避免动画 Task 在后台被悬挂
            .onChange(of: scenePhase) { _, phase in
                store.scenePhaseChanged(phase)
            }
        }
    }
}

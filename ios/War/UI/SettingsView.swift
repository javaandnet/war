import SwiftUI
import WarKit

/// 设置：模式、难度、棋盘、seed、动画速度，以及功耗策略的可见性。
/// 改完立即生效的项（叠层、速度）直接写 settings；改棋盘/模式需要重开局。
struct SettingsView: View {
    @EnvironmentObject private var store: GameStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = GameSettings()
    @State private var needsRestart = false

    var body: some View {
        NavigationStack {
            Form {
                Section("对局方式") {
                    Picker("模式", selection: $draft.mode) {
                        ForEach(GameSettings.Mode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Text("四个模式各记一本军费：金币、魔法买断与档位、兵档升级均互不通用（切模式就是换一本账，不会把别处刷出来的钱带进来）。闯关的升级账另记一份，与永久账无关。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Picker("AI 难度", selection: $draft.difficultyKey) {
                        ForEach(WarConfig.difficultyOrder, id: \.self) { key in
                            Text(label(for: key)).tag(key)
                        }
                    }
                    .disabled(draft.mode == .campaign)
                    if draft.mode == .campaign {
                        Text("闯关模式的难度、地图与 seed 均由关卡公式按关数固定导出（不读玩家战绩，也不会动态匹配）；以下难度/seed 项对闯关不生效。")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        // 进度是“胜利当场”就落盘的（不是点「下一关」时才 +1），所以这里报的就是存档里的实况
                        Text("闯关进度：已通过第 \(max(0, store.campaign.currentLevel - 1)) 关，接下来第 \(store.campaign.currentLevel) 关（最高到过第 \(store.campaign.maxLevelReached) 关）")
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                    }
                }

                Section("棋盘与随机") {
                    Picker("尺寸", selection: $draft.boardIndex) {
                        ForEach(Array(WarConfig.boardSizes.enumerated()), id: \.offset) { index, size in
                            Text("\(size.width)×\(size.height)").tag(index)
                        }
                    }
                    Picker("默认缩放", selection: $draft.boardZoom) {
                        Text("全图（单格最小）").tag(1.0)
                        Text("舒适 1.35×").tag(1.35)
                        Text("大 1.8×").tag(1.8)
                        Text("特大 2.4×").tag(2.4)
                    }
                    Toggle("聚焦模式（开战后隐藏面板）", isOn: $draft.focusMode)
                    Text("缩放只由双指捏合控制（点击与双击不会改动缩放）；默认缩放是每局开局时的起始倍数。放大后单指拖动地图，底部「全图」按钮一键复位。竖屏宽度是单格尺寸的硬上限，要更大只能靠缩放。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    stepper("地形 seed（决定地图）", value: $draft.terrainSeed, step: 1)
                        .disabled(draft.mode == .campaign)
                    stepper("AI seed（决定采样）", value: $draft.aiSeed, step: 1)
                        .disabled(draft.mode == .campaign)
                    Button("两个 seed 都随机") {
                        draft.terrainSeed = Int.random(in: 1...9_999)
                        draft.aiSeed = Int.random(in: 1...9_999_999)
                    }
                    .font(.caption)
                    .disabled(draft.mode == .campaign)
                }

                Section("动画与功耗") {
                    HStack {
                        Text("每步节拍")
                        Slider(value: $draft.stepDelayMs, in: 0...400, step: 20)
                        Text("\(Int(draft.stepDelayMs))ms").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Label(store.power.statusLine, systemImage: "bolt.badge.checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("发热或开启低电量模式时，AI 前瞻层数自动降到 1、帧率压到 30fps；单位数值不受影响。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Section {
                    Text("难度只由三个旋钮构成：视野（信息）、温度（softmax 随机）、前瞻（rollout 层数）。四档共享同一份评分与同一套规则，不存在「低难度 AI 属性变弱」这回事。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("关于难度")
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(needsRestart ? "应用并重开" : "应用") { apply() }
                        .fontWeight(.semibold)
                }
            }
            .onChange(of: draft) { _, next in
                needsRestart = next.boardIndex != store.settings.boardIndex
                    || next.mode != store.settings.mode
                    || next.terrainSeed != store.settings.terrainSeed
            }
            .onAppear { draft = store.settings }
        }
    }

    private func apply() {
        store.settings = draft
        if needsRestart {
            store.newGame()
        } else {
            store.publishSettingsChange()
        }
        dismiss()
    }

    private func label(for key: String) -> String {
        let d = WarConfig.difficulties[key]!
        return "\(d.name)（温度\(String(format: "%.2f", d.temperature))/前瞻\(d.lookahead)/"
            + "视野\(d.vision == .max ? "全图" : "\(d.vision)")）"
    }

    private func stepper(_ title: String, value: Binding<Int>, step: Int) -> some View {
        // 绝不能写 Int.min...Int.max：SwiftUI 的 Stepper 会算区间跨度，
        // Int.max - Int.min 直接溢出 trap（表现为打开设置页就 EXC_BREAKPOINT）。
        Stepper(value: value, in: -99_999_999...99_999_999, step: step) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.wrappedValue)").monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}

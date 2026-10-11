import SwiftUI
import WarKit

/// 主界面。
///
/// 两种形态：
/// - **聚焦模式**（开战后默认）：整屏只留棋盘 + 顶部一行状态 + 底部一条迷你操作条，
///   面板以浮层按需升起。棋盘不再被切成一半，配合缩放/平移解决"格子太小"。
/// - **完整模式**：棋盘与面板并排（横屏）或上下排（竖屏），信息常驻。
///
/// 浮层是 overlay 而非布局分支，所以开合面板不会改变场景尺寸（不触发地形重建，也不闪）。
/// 迷你操作条走 `safeAreaInset` 而不是压在棋盘上：全图缩放时棋盘是居中锁定的（拖不动），
/// 若被操作条遮住，最低一排格子就永久点不到。
struct ContentView: View {
    @EnvironmentObject private var store: GameStore
    @State private var showSettings = false
    @State private var confirmSurrender = false
    @State private var tab: PanelTab = .action
    @State private var showDrawer = false

    enum PanelTab: String, CaseIterable {
        case action = "行动"
        case intel = "情报"
        case aiLog = "AI 决策"
    }

    private var isPlacement: Bool {
        if case .placement = store.phase { return true }
        return false
    }

    /// 布阵阶段必须常驻面板（要放子），所以聚焦形态只在战斗期生效
    private var focused: Bool { store.settings.focusMode && !isPlacement }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height * 1.05
            ZStack(alignment: .bottom) {
                if focused {
                    board
                } else if landscape {
                    HStack(spacing: 8) { board; sidePanel.frame(width: geo.size.width * 0.42) }
                } else {
                    VStack(spacing: 6) { board; sidePanel }
                }

                if focused {
                    if showDrawer {
                        sidePanel
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: geo.size.height * 0.48)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(alignment: .topTrailing) {
                                Button { withAnimation(.snappy) { showDrawer = false } } label: {
                                    Image(systemName: "chevron.down.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(6)
                            }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .padding(.horizontal, focused ? 0 : 8)
            .padding(.bottom, focused ? 0 : 4)
        }
        .background(Theme.boardBackground.ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) { statusBar }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // 只在聚焦模式占位；完整模式的操作按钮在下方面板里，不需要这一条
            if focused { miniBar } else { Spacer().frame(height: 0) }
        }
        .toolbar { toolbarItems }
        .overlay { gameOverCard }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(store) }
        .confirmationDialog("确认投降？", isPresented: $confirmSurrender, titleVisibility: .visible) {
            Button("投降", role: .destructive) { store.surrender() }
            Button("再打打", role: .cancel) {}
        } message: {
            Text(store.settings.mode == .campaign
                 ? "本局按败局结算，闯关会回滚军费与升级账"
                 : "本局按败局结算，结局不可撤销")
        }
        .animation(.snappy, value: showDrawer)
        .animation(.snappy, value: focused)
        .animation(.snappy, value: isOver)
    }

    private var isOver: Bool {
        if case .over = store.phase { return true }
        return false
    }

    /// 结局卡片。歼灭判定时所有按钮都会变灰，不给出可见反馈的话，
    /// 玩家只会觉得“又卡住了”（上一轮就是这种误会）。
    @ViewBuilder
    private var gameOverCard: some View {
        if case .over(let winner) = store.phase {
            VStack(spacing: 8) {
                Text(winner == -1 ? "平局" : "\(store.campLabel(winner))获胜")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(winner == 0 ? Theme.accent
                                                        : Color(red: 1, green: 0.45, blue: 0.4))
                // 一句实话：打到哪回合、因为什么判的（斩首 / 歼灭 / 回合上限）
                Text("第 \(store.turnCount) 回合 · \(store.endReasonText)\n"
                     + "物质分 蓝\(Int(store.materialScore(camp: 0))) / 红\(Int(store.materialScore(camp: 1)))")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                settlementLine
                if store.settings.mode == .campaign {
                    // 闯关：一句关卡状态，取代“重开同 seed / 新开局”（语义已不适用）。
                    // 进度在胜利那一刻已经落盘，所以这里报的是“刚打完那一关 + 接下来要打的那一关”。
                    let played = store.lastCampaignLevel ?? store.campaign.currentLevel
                    Text(winner == 0
                         ? "第 \(played) 关通关！奖金已入账，进度已保存（下一关：第 \(store.campaign.currentLevel) 关）"
                         : "第 \(played) 关未通过 · 军费已回滚，可重试（最高到过第 \(store.campaign.maxLevelReached) 关）")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: 10) {
                    if store.settings.mode == .campaign {
                        Button("退出闯关") { store.exitCampaign() }
                        if winner == 0 {
                            Button("下一关") { store.nextCampaignLevel() }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button("重试本关") { store.retryCampaignLevel() }
                                .buttonStyle(.borderedProminent)
                        }
                    } else {
                        Button("重开（同图同 seed）") { store.restartSameSeed() }
                        Button("新开局") { store.newGame() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .font(.caption)
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(radius: 6)
            .transition(.scale.combined(with: .opacity))
        }
    }

    /// 本局军费流水。钱不是装饰：玩家得知道“输了也有安慰金、买断不会蒸发”，
    /// 否则下一局要不要买魔法就只能靠猜。
    @ViewBuilder
    private var settlementLine: some View {
        if let s = store.lastSettlement {
            VStack(spacing: 2) {
                Text("\(outcomeName(s.outcome))奖金 +\(s.bonus)　本局军费 −\(s.spent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("余额 \(s.goldAfter)（买断与兵档留着，充能随本局作废）")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func outcomeName(_ outcome: Wallet.Outcome) -> String {
        switch outcome {
        case .win: return "胜利"
        case .draw: return "平局"
        case .loss: return "败局"
        }
    }

    /// 迷你条上该显哪一门：待施法中就是那一门，否则取携带名单的第一门
    private func miniSpellKey(_ store: GameStore) -> String? {
        if let pending = store.pendingSpellKey, store.selectableSpells.contains(pending) { return pending }
        return store.selectableSpells.first
    }

    private var board: some View {
        BoardPanel().environmentObject(store)
    }

    /// 聚焦模式下的底部一条：够操作，但不跟棋盘抢高度
    private var miniBar: some View {
        HStack(spacing: 8) {
            if let unit = store.selectedUnit(), unit.camp == store.currentCamp {
                HStack(spacing: 4) {
                    UnitGlyph(type: unit.type, fallback: unit.symbol)
                        .foregroundStyle(Theme.campColor(unit.camp))
                    Text("\(unit.name) #\(unit.id) ⚡\(unit.remainingMove) ⚔\(unit.remainingAttacks)")
                        .font(.caption.monospaced())
                }
                .lineLimit(1)
                // 聚焦模式下面板是收起的，首领得在这里给一个施法入口（否则只能开面板）。
                // 这一键只做两件事：待施法中 → 取消；否则 → 上携带名单里的第一门。
                // 多门魔法的逐门选择留给行动面板（迷你条只有一格宽，做循环按钮只会误触）。
                if unit.isChief, let shown = miniSpellKey(store) {
                    Button {
                        store.armSpell(store.pendingSpellKey ?? shown)
                    } label: {
                        let stat = WarConfig.spells[shown]!
                        HStack(spacing: 2) {
                            SpellGlyph(key: shown, fallback: stat.symbol)
                            Text(store.pendingSpellKey == shown ? "取消" : stat.name)
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(store.pendingSpellKey == shown ? Theme.accent : .purple)
                    .disabled(store.busy || !store.selectedChiefCanCast)
                }
            } else {
                Text("点格子选中 · 双指缩放，放大后拖动")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 4)
            Button("待命") { store.waitSelected() }
                .disabled(store.selectedUnit() == nil || store.busy)
            Button("结束回合") { store.endTurn() }
                .buttonStyle(.borderedProminent)
                .disabled(store.busy || !store.canCommandCurrentCamp)
            Button { store.viewResetTick += 1 } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .accessibilityLabel("全图")
            Button {
                showDrawer.toggle()
            } label: {
                Image(systemName: showDrawer ? "rectangle.bottomthird.inset.filled"
                                             : "square.text.square")
            }
            .accessibilityLabel("面板")
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var sidePanel: some View {
        VStack(spacing: 6) {
            Picker("面板", selection: $tab) {
                ForEach(PanelTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Group {
                switch tab {
                case .action: ActionPanel()
                case .intel: IntelPanel()
                case .aiLog: DecisionLogView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .environmentObject(store)
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(store.statusLine).font(.subheadline.weight(.semibold))
                if store.settings.mode == .campaign {
                    // currentLevel 始终指向尚未通过的那一关（胜利当场已 +1），所以“本关”就是它
                    Text("第\(store.campaign.currentLevel)关·"
                         + "\(WarConfig.difficulties[store.campaignSpec.difficultyKey]?.name ?? "")"
                         + "·最高\(store.campaign.maxLevelReached)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                if store.walletUsable {
                    // 军费读数常驻状态条：不管面板开没开，玩家总得知道还剩多少
                    Label("\(store.wallet.gold)", systemImage: "dollarsign.circle.fill")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.accent)
                }
                Spacer()
                if store.busy { ProgressView().controlSize(.small) }
                Toggle("聚焦", isOn: $store.settings.focusMode)
                    .toggleStyle(.button)
                    .controlSize(.mini)
                    .font(.caption2)
            }
            HStack(spacing: 8) {
                Text(store.power.statusLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(store.hint ?? "")
                    .font(.caption2)
                    .foregroundStyle(Theme.accent)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                if store.settings.mode == .campaign {
                    // 闯关下“同 seed 重开/新开局”语义不适用（关卡参数由公式钉死），换成“重试本关”
                    Button("重试本关") { store.retryCampaignLevel() }
                } else {
                    Button("一键布阵开战") { store.quickDeploy() }
                    Button("重开（同图同 seed）") { store.restartSameSeed() }
                    Button("新开局（回到布阵）") { store.newGame() }
                }
                if store.phase == .battle {
                    Divider()
                    Button("投降", role: .destructive) { confirmSurrender = true }
                }
            } label: {
                Image(systemName: "arrow.clockwise.circle")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
        }
    }
}

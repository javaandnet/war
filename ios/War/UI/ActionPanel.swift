import SwiftUI
import WarKit

/// 行动面板：布阵控件（含军费）/ 单位指令（含施法）/ 叠层开关 / 自动对战。
struct ActionPanel: View {
    @EnvironmentObject private var store: GameStore

    /// 军费面板分页：升兵 vs 买魔法
    private enum WarTab: String, CaseIterable {
        case soldiers = "升兵", spells = "魔法"
    }

    @State private var warTab: WarTab = .soldiers

    private var isPlacement: Bool {
        if case .placement = store.phase { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if isPlacement { placementSection } else { commandSection }
                Divider()
                overlaySection
                outcomeBanner
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: 布阵与军费

    private var placementSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("布阵 · \(store.statusLine)").font(.caption).foregroundStyle(.secondary)
            if store.walletUsable { chestBar }

            Picker("兵种", selection: $store.placingType) {
                ForEach(WarConfig.unitTypeOrder, id: \.self) { key in
                    // 按钱包当前档取数：否则升了档这里还在讲 tier1 的 HP，玩家看不到钱花哪了
                    let stat = store.placedStat(for: key)
                    HStack(spacing: 6) {
                        UnitGlyph(type: key, fallback: stat.symbol).frame(width: 18)
                        Text("\(stat.name) T\(store.wallet.tier(of: key)) HP\(stat.hp)/攻\(stat.atk)/防\(stat.def)/动\(stat.moveRange)/射\(stat.attackRange)")
                    }
                        .tag(key)
                }
            }
            .pickerStyle(.menu)

            Text("首领每局必带、免费、不占兵位，且是全场唯一能施法的单位——它阵亡即判负")
                .font(.caption2).foregroundStyle(.tertiary)

            if store.walletUsable {
                Picker("军费", selection: $warTab) {
                    ForEach(WarTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if warTab == .soldiers { upgradeRows } else { spellShopRows }
            }

            HStack {
                Button("完成布阵") { store.finishPlacement() }
                    .buttonStyle(.borderedProminent)
                Button("一键布阵开战") { store.quickDeploy() }
                    .buttonStyle(.bordered)
            }
            Text("点击出生区放置（按单价扣费）；再点已放的单位可撤销并退款")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    /// 钱包读数：玩家得先知道“现在还能买什么”
    private var chestBar: some View {
        HStack(spacing: 10) {
            Label("\(store.wallet.gold)", systemImage: "dollarsign.circle.fill")
                .foregroundStyle(Theme.accent)
            Label("\(store.soldierCount(camp: 0))/\(WarConfig.soldiersPerSide)", systemImage: "person.2.fill")
                .foregroundStyle(.secondary)
            Spacer()
            Text("本局已花 \(store.wallet.spentThisBattle)")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .font(.caption.monospacedDigit())
    }

    /// 兵种升档（跨局永久）。钱不够时按钮直接灰掉：
    /// 点了才闪一句“金币不足”就是把校验做错了地方。
    private var upgradeRows: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(WarConfig.unitTypeOrder, id: \.self) { key in
                let stat = store.placedStat(for: key)
                let tier = store.wallet.tier(of: key)
                let next = store.wallet.upgradeCost(key)
                HStack(spacing: 6) {
                    UnitGlyph(type: key, fallback: stat.symbol).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(stat.name) · T\(tier)").font(.caption)
                        Text("单价 \(Wallet.cost(ofUnit: key))｜HP\(stat.hp)/攻\(stat.atk)/防\(stat.def)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let cost = next {
                        Button("升 T\(tier + 1) −\(cost)") { store.purchaseTierUpgrade(key) }
                            .buttonStyle(.bordered).controlSize(.mini)
                            .disabled(!store.canBuyPermanent || store.wallet.gold < cost)
                    } else {
                        Text("满档").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            Text("升档跨局生效：这一型兵以后每局都在这一档（AI 与玩家同价同档）")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    /// 魔法商店：买断是跨局永久，充能是本局消耗 —— 两笔钱买的东西不同，列在同一行里。
    private var spellShopRows: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(WarConfig.spellOrder, id: \.self) { key in
                let stat = WarConfig.spells[key]!
                HStack(spacing: 6) {
                    SpellGlyph(key: key, fallback: stat.symbol).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(stat.name) · 射程 \(stat.range)").font(.caption)
                        Text(spellEffectText(stat)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.wallet.isUnlocked(key) {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("本局携带 \(store.wallet.charges[key] ?? 0) 发")
                                .font(.caption2).monospacedDigit()
                            Button("买 1 发 −\(stat.chargeCost)") { store.purchaseCharge(key) }
                                .buttonStyle(.bordered).controlSize(.mini)
                                .disabled(!store.canBuyCharges || store.wallet.gold < stat.chargeCost)
                        }
                    } else {
                        Button("买断 −\(stat.unlockCost)") { store.purchaseSpellUnlock(key) }
                            .buttonStyle(.bordered).controlSize(.mini)
                            .disabled(!store.canBuyPermanent || store.wallet.gold < stat.unlockCost)
                    }
                }
            }
            Text(store.canBuyCharges
                 ? "只有首领能施法；充能于「完成布阵」那一刻写死在首领身上"
                 : "开战后不再卖充能：本局首领的携带发数已定，再买也不会凭空多出来")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    /// 魔法效果的口播（只把配置表读成人话，不在 UI 另写一套规则）
    private func spellEffectText(_ stat: WarConfig.SpellStat) -> String {
        switch stat.effect {
        case .damage:
            return stat.splash > 0
                ? "中心 \(stat.power) 伤害，邻格溅射 \(stat.splash)（无视地形减伤）"
                : "造成 \(stat.power) 点伤害"
        case .heal: return "恢复 \(stat.power) 生命（不超上限）"
        case .stun: return "目标本回合禁行动、禁攻击、禁反击"
        }
    }

    // MARK: 指令

    private var commandSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let unit = store.selectedUnit() {
                HStack(spacing: 6) {
                    UnitGlyph(type: unit.type, fallback: unit.symbol)
                        .frame(width: 18)
                        .foregroundStyle(Theme.campColor(unit.camp))
                    Text(unit.name).font(.body.weight(.semibold))
                    if unit.isChief { Text("首领").font(.caption2).foregroundStyle(Theme.accent) }
                    Text("#\(unit.id) · HP \(unit.hp)/\(unit.maxHp)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("⚡\(unit.remainingMove) ⚔\(unit.remainingAttacks)")
                        .font(.caption.monospaced())
                }
            } else {
                Text("未选中单位 —— 点击棋盘上的己方单位").font(.caption).foregroundStyle(.secondary)
            }

            if let unit = store.selectedUnit(), unit.isChief, unit.camp == store.currentCamp {
                Divider()
                chiefSpellRow(unit)
            }

            HStack {
                Button("待命") { store.waitSelected() }
                    .disabled(store.selectedUnit() == nil || store.busy)
                Button("结束回合") { store.endTurn() }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.busy || !store.canCommandCurrentCamp)
                Spacer()
                Button(store.autoRunning ? "停止自动" : "自动对战") {
                    store.toggleAuto()
                }
                .buttonStyle(.bordered)
                .tint(store.autoRunning ? .orange : Theme.accent)
            }

            if store.settings.mode == .aiVsAI {
                Text("AI 自动对战：双方同规则同算力，只有 softmax 温度、前瞻、视野与军费四个旋钮按难度生效")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    /// 首领施法行。名单与可命中格都来自内核口径（`selectableSpells` /
    /// `spellTargets`），UI 不再推一套射程。施法与普攻同回合互斥。
    /// 参数直接拿内核单位：只有它有 `remainingSpell`（那是回合配额，不是画面字段）。
    private func chiefSpellRow(_ unit: WarUnit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars").font(.caption)
                Text("施法").font(.caption.weight(.semibold))
                Text(unit.remainingSpell > 0 ? "本回合还能放 1 次（与普攻互斥）" : "本回合动作已用掉")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if store.selectableSpells.isEmpty {
                Text("首领本局没带充能：回布阵页在军费面板先买断、再买发数")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 6) {
                    ForEach(store.selectableSpells, id: \.self) { key in
                        let stat = WarConfig.spells[key]!
                        Button {
                            store.armSpell(key)
                        } label: {
                            HStack(spacing: 3) {
                                SpellGlyph(key: key, fallback: stat.symbol)
                                Text("\(stat.name)×\(unit.spellCharges[key] ?? 0)")
                            }
                            .font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .tint(store.pendingSpellKey == key ? Theme.accent : .purple)
                        .disabled(store.busy || !store.selectedChiefCanCast)
                    }
                }
            }
            if store.pendingSpellKey != nil {
                Text("再点棋盘上的紫色格施放；点同一按钮取消")
                    .font(.caption2).foregroundStyle(Theme.accent)
            }
        }
    }

    // MARK: 叠层

    private var overlaySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("机动范围（含地形消耗）", isOn: $store.settings.showReach)
            Toggle("敌方威胁图", isOn: $store.settings.showThreat)
            Toggle("AI 最优落点 ★ / 目标点", isOn: $store.settings.showBestMark)
            HStack {
                Text("动画节拍")
                Slider(value: $store.settings.stepDelayMs, in: 0...400, step: 20) {
                    Text("每步毫秒")
                }
                Text("\(Int(store.settings.stepDelayMs))ms").monospacedDigit()
            }
        }
        .font(.caption)
        .toggleStyle(.switch)
        .tint(Theme.accent)
    }

    @ViewBuilder
    private var outcomeBanner: some View {
        if case .over(let winner) = store.phase {
            let text = winner == -1 ? "对局结束：平局" : "\(store.campLabel(winner))获胜"
            Label(text, systemImage: winner == 0 ? "trophy.fill" : "flag.checkered")
                .font(.headline)
                .foregroundStyle(winner == 0 ? Theme.accent : .orange)
        }
    }
}

/// 情报面板：选中单位详情 + 双方兵力 + 地形图例
struct IntelPanel: View {
    @EnvironmentObject private var store: GameStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let info = store.inspection(of: store.selectedId) {
                    VStack(alignment: .leading, spacing: 4) {
                        row("单位", "\(info.unit.name) #\(info.unit.id)" + (info.unit.isChief ? "（首领）" : ""))
                        row("档位", "T\(info.unit.tier)")
                        row("生命", "\(info.unit.hp)/\(info.unit.maxHp)")
                        row("攻击 / 防御", "\(info.attack) / \(info.defense)"
                            + (info.terrainDefBonus > 0 ? "（地形+\(info.terrainDefBonus)）" : ""))
                        row("射程", info.attackRange > 1 ? "\(info.attackRange) 格（需视线）" : "1 格（相邻）")
                        row("能否反击", info.counterAttack ? "可以" : "不可（弓兵被近战不打反击）")
                        row("所在地形", "\(info.terrainName)（消耗 \(info.moveCost)）")
                        row("剩余机动 / 攻击", "\(info.unit.remainingMove) / \(info.unit.remainingAttacks)")
                        if info.unit.isChief { row("本局携带", chiefChargeText(info.unit)) }
                        if info.unit.stunned { row("状态", "被冻：本回合不能机动、不能攻击也不能反击") }
                        row("所处威胁值", String(format: "%.0f", info.threat))
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
                } else {
                    Text("点击单位查看详情").font(.caption).foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    forceChip(store.campLabel(0), camp: 0)
                    forceChip(store.campLabel(1), camp: 1)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("地形").font(.caption.weight(.semibold))
                    ForEach(WarConfig.terrainOrder, id: \.self) { key in
                        let t = WarConfig.terrains[key]!
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Theme.terrainColor(key)).frame(width: 16, height: 16)
                            TerrainGlyph(key: key, fallback: t.symbol)
                                .font(.caption).frame(width: 18)
                            Text(t.name).font(.caption)
                            Text("消耗\(t.moveCost)\(t.defBonus > 0 ? " 防御+\(t.defBonus)" : "")\(t.impassable ? " 不可通行" : "")")
                                .font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
            Text(value).font(.caption)
            Spacer()
        }
    }

    /// 首领逐 kind 的携带明细。棋盘角上只画总发数（地方太小），这里的账要给全：
    /// “买了 2 发治疗 1 发冰冻”与“买了 3 发治疗”对玩家是两个不同决定。
    private func chiefChargeText(_ unit: BoardFrame.UnitView) -> String {
        let parts = WarConfig.spellOrder.compactMap { key -> String? in
            let count = unit.spellCharges[key] ?? 0
            guard count > 0 else { return nil }
            return "\(WarConfig.spells[key]?.name ?? key)×\(count)"
        }
        return parts.isEmpty ? "未携带充能（军费面板可买）" : parts.joined(separator: " ")
    }

    private func forceChip(_ label: String, camp: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text("\(store.unitCount(camp: camp)) 个 · 物质分 \(String(format: "%.1f", store.materialScore(camp: camp)))")
                .font(.caption)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.campColor(camp).opacity(0.15)))
    }
}

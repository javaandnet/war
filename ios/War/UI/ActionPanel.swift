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
    /// 投降得二次确认：它当场就结算，没有“反悔”入口（闯关还会回滚军费）
    @State private var confirmSurrender = false

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
                    // 按当前活跃升级账取数：否则升了档这里还在讲未升级的 HP，玩家看不到钱花哪了
                    let stat = store.placedStat(for: key)
                    let ups = store.activeUpgrades(for: key)
                    HStack(spacing: 6) {
                        UnitGlyph(type: key, fallback: stat.symbol).frame(width: 18)
                        Text("\(stat.name) [攻\(ups.atk)/防\(ups.def)/命\(ups.hp)] HP\(stat.hp)/攻\(stat.atk)/防\(stat.def)/动\(stat.moveRange)/射\(stat.attackRange)\(broughtLevelText(key))")
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

    /// 闯关才能把上一关练出来的等级带回战场，兵档行必须说出来（否则带入的等级看着像 bug）。
    /// 数值预览走内核：面板不拿经验自己推等级。
    private func broughtLevelText(_ key: String) -> String {
        guard let growth = store.activeGrowth(for: key), growth.level > 1 else { return "" }
        let branch = growth.branch.flatMap { WarConfig.unitTypes[$0]?.name }
        return "｜带入 Lv\(growth.level)" + (branch.map { "·\($0)" } ?? "")
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

    /// 兵种升级（攻/防/生命 三条独立线，无上限）。钱不够时对应按钮直接灰掉：
    /// 点了才闪一句“金币不足”就是把校验做错了地方。
    /// 已经买过的线多一个「退」：买错不必将错就错，退款额由同一个定价函数给（退的是实付）。
    private var upgradeRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(WarConfig.unitTypeOrder, id: \.self) { key in
                let stat = store.placedStat(for: key)
                let ups = store.activeUpgrades(for: key)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(stat.name) [攻\(ups.atk)/防\(ups.def)/命\(ups.hp)]").font(.caption)
                    Text("单价 \(Wallet.cost(ofUnit: key))｜HP\(stat.hp)/攻\(stat.atk)/防\(stat.def)")
                        .font(.caption2).foregroundStyle(.secondary)
                    HStack(alignment: .top, spacing: 6) {
                        ForEach(WarConfig.UpgradeTrack.allCases, id: \.self) { track in
                            let cost = WarConfig.upgradeCost(typeKey: key, currentLevel: ups.level(track))
                            VStack(alignment: .leading, spacing: 2) {
                                Button("\(track.label) T\(ups.level(track) + 1) −\(cost)") {
                                    store.purchaseUpgrade(key, track: track)
                                }
                                .buttonStyle(.bordered).controlSize(.mini)
                                .disabled(!store.canBuyPermanent || store.wallet.gold < cost)
                                if ups.level(track) > 0 {
                                    // 退款额读内核定价取上一档：与买入同一把尺，UI 不另算一份
                                    let back = WarConfig.upgradeCost(typeKey: key,
                                                                     currentLevel: ups.level(track) - 1)
                                    Button("退 +\(back)") { store.sellUpgrade(key, track: track) }
                                        .buttonStyle(.bordered).controlSize(.mini).tint(.orange)
                                        .disabled(!store.canRefundPermanent)
                                }
                            }
                        }
                    }
                }
            }
            Text(store.settings.mode == .campaign
                 ? "闯关升级独立于永久账：从 T0 起、跨关累积，打输本关连同金钱与等级一起回滚（AI 与玩家同价）"
                 : "升级跨局生效：这一型兵以后每局都带这一档（AI 与玩家同价同档）")
                .font(.caption2).foregroundStyle(.tertiary)
            Text("买错了？只有布阵期内能退档，退的是当初升这一档实付的那笔；开战后不再退（打过的一仗算用掉了）")
                .font(.caption2).foregroundStyle(.secondary)
            // 两条成长轴极易混：一个花钱、一个打仗，不写清就有人问“为何升了档等级没动”
            Text("战场等级是另一条轴：靠打仗长经验，每级给 1 点属性点，满 \(WarConfig.Growth.promoteLevel) 级可转职；与这里的买档互不影响")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// 魔法商店：买断与升档是跨局永久（档位只影响以后落定的首领），充能是本局消耗。
    /// 威力/射程一律读 `WarConfig.spellStat(level:)`：面板不自己乘系数，
    /// 否则会出现“写着 72、棋盘上烧了 60”。
    private var spellShopRows: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(WarConfig.spellOrder, id: \.self) { key in
                let base = WarConfig.spells[key]!
                let level = store.wallet.spellLevel(key)
                let live = WarConfig.spellStat(key, level: level) ?? base
                let nextCost = Wallet.spellLevelCost(key, currentLevel: level)
                let atCap = level >= WarConfig.maxSpellLevel
                HStack(spacing: 6) {
                    SpellGlyph(key: key, fallback: base.symbol).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(live.name) · 射程 \(live.range)" + (level > 0 ? " · \(level) 档" : "")).font(.caption)
                        Text(spellEffectText(live)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.wallet.isUnlocked(key) {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("本局携带 \(store.wallet.charges[key] ?? 0) 发")
                                .font(.caption2).monospacedDigit()
                            HStack(spacing: 4) {
                                Button("升档 −\(nextCost)") { store.purchaseSpellLevel(key) }
                                    .buttonStyle(.bordered).controlSize(.mini)
                                    .disabled(!store.canBuyPermanent || atCap || store.wallet.gold < nextCost)
                                Button("买 1 发 −\(base.chargeCost)") { store.purchaseCharge(key) }
                                    .buttonStyle(.bordered).controlSize(.mini)
                                    .disabled(!store.canBuyCharges || store.wallet.gold < base.chargeCost)
                            }
                            // 反悔行：只有手上真有可退的东西才画（顶档/零发都不摆个死按钮）
                            if level > 0 || (store.wallet.charges[key] ?? 0) > 0 {
                                HStack(spacing: 4) {
                                    if level > 0 {
                                        Button("退档 +\(Wallet.spellLevelCost(key, currentLevel: level - 1))") {
                                            store.sellSpellLevel(key)
                                        }
                                        .buttonStyle(.bordered).controlSize(.mini).tint(.orange)
                                        .disabled(!store.canRefundPermanent)
                                    }
                                    if (store.wallet.charges[key] ?? 0) > 0 {
                                        Button("退发 +\(base.chargeCost)") { store.sellCharge(key) }
                                            .buttonStyle(.bordered).controlSize(.mini).tint(.orange)
                                            .disabled(!store.canRefundPermanent)
                                    }
                                }
                            }
                        }
                    } else {
                        Button("买断 −\(base.unlockCost)") { store.purchaseSpellUnlock(key) }
                            .buttonStyle(.bordered).controlSize(.mini)
                            .disabled(!store.canBuyPermanent || store.wallet.gold < base.unlockCost)
                    }
                }
            }
            Text(atCapHint()
                 + (store.canBuyCharges
                    ? "｜只有首领能施法；充能于「完成布阵」那一刻写死在首领身上（买错可退）"
                    : "｜开战后不再卖充能：本局首领的携带发数已定，再买也不会凭空多出来"))
                .font(.caption2).foregroundStyle(.tertiary)
            Text("买断不退（它是解锁）；升档与发数只在布阵期能退，退的都是当初实付那笔")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// 升档那一半的口播（顶档与未顶档说的是两件事，不拆行只拆文案）
    private func atCapHint() -> String {
        let allMax = WarConfig.spellOrder.allSatisfy { store.wallet.spellLevel($0) >= WarConfig.maxSpellLevel }
        if allMax { return "三门魔法均为顶档（顶档射程 +1）" }
        return "买断后可花军费升档（威力与溅射每档 +20%，顶档射程 +1，跨局永久）"
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
                    UnitGlyph(type: unit.typeKey, fallback: unit.symbol)
                        .frame(width: 18)
                        .foregroundStyle(Theme.campColor(unit.camp))
                    Text(unit.name).font(.body.weight(.semibold))
                    if unit.isChief { Text("首领").font(.caption2).foregroundStyle(Theme.accent) }
                    if unit.level > 1 { Text("Lv\(unit.level)").font(.caption2).foregroundStyle(Theme.accent) }
                    Text("#\(unit.id) · HP \(unit.hp)/\(unit.maxHp)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("⚡\(unit.remainingMove) ⚔\(unit.remainingAttacks)")
                        .font(.caption.monospaced())
                }
            } else {
                Text("未选中单位 —— 点击棋盘上的己方单位").font(.caption).foregroundStyle(.secondary)
            }

            if let unit = store.selectedUnit(), unit.camp == store.currentCamp {
                growthSection(unit)
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

            // 投降：只走既有败局结算（vsAI 吃安慰金、闯关吃入关快照回滚、双人与观战不动钱）
            HStack(spacing: 8) {
                Button("投降", role: .destructive) { confirmSurrender = true }
                    .buttonStyle(.bordered)
                    .disabled(store.busy || !(store.canCommandCurrentCamp || store.settings.mode == .aiVsAI))
                Text(store.settings.mode == .campaign
                     ? "按败局结束本局，军费/升级/等级都回到入关那一刻"
                     : "按败局结束本局（不白打：败局也有安慰金）")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .confirmationDialog("确认投降？", isPresented: $confirmSurrender, titleVisibility: .visible) {
                Button("投降", role: .destructive) { store.surrender() }
                Button("再打打", role: .cancel) {}
            } message: {
                Text(store.settings.mode == .campaign
                     ? "本局按败局结算，闯关会回滚军费、升级账与战场等级"
                     : "本局按败局结算，结局不可撤销")
            }

            if store.settings.mode == .aiVsAI {
                Text("AI 自动对战：双方同规则同算力，只有 softmax 温度、前瞻、视野与军费四个旋钮按难度生效")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    /// 战场成长区（属性点 + 转职）。存不存、能不能分都由内核定：
    /// 这里只把按钮摆出来，点下去走的都是 `Battlefield.allocate` / `promote`。
    /// 不满足“真有过成长”的单位整块不画（刚放下去的 1 级兵不需要一片噪声）。
    @ViewBuilder
    private func growthSection(_ unit: WarUnit) -> some View {
        if unit.level > 1 || unit.attrBank > 0 || unit.canPromote || unit.isPromoted {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.circle.fill").font(.caption).foregroundStyle(Theme.accent)
                    Text("等级 \(unit.level)/\(unit.levelCap)").font(.caption.weight(.semibold))
                    Text(unit.expToNext > 0 ? "本级经验 \(unit.expIntoLevel)/\(unit.expToNext)" : "经验：已到上限")
                        .font(.caption2).foregroundStyle(.secondary)
                    if unit.isPromoted {
                        Text("已转职：\(unit.name)").font(.caption2).foregroundStyle(Theme.accent)
                    }
                }

                if unit.attrBank > 0 { attributeRow(unit) }

                if unit.canPromote {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("满 \(WarConfig.Growth.promoteLevel) 级：选一条路（不可逆、不吃钱，转职后上限抬到 \(WarConfig.Growth.promotedLevelCap) 级）")
                            .font(.caption2).foregroundStyle(Theme.accent)
                        HStack(alignment: .top, spacing: 6) {
                            ForEach(unit.promotionOptions, id: \.self) { key in
                                promotionButton(key, for: unit)
                            }
                        }
                        if !store.canCommandCurrentCamp || unit.camp != store.currentCamp {
                            Text("这一侧由 AI 指挥，它会在回合开始时自己选（低两档取第一条路）")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                } else if !unit.isPromoted && unit.level >= WarConfig.Growth.promoteLevel && unit.attrBank > 0 {
                    // 点数卡在手里不是 bug：未转职就是 10 级封顶，先转职才花得出去
                    Text("已达未转职上限：先把兵种转了，待分属性点才花得出去")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }

    /// 属性点分配行。每点加多少直接读内核常量（UI 不另抄一份数值）。
    private func attributeRow(_ unit: WarUnit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("待分配属性点 \(unit.attrBank)").font(.caption2.weight(.semibold))
                ForEach(WarConfig.UpgradeTrack.allCases, id: \.self) { track in
                    Button("+\(track.label)") { store.allocateSelected(track: track) }
                        .buttonStyle(.bordered).controlSize(.mini)
                        .disabled(!store.canAllocateSelected)
                }
                Text("已分 攻\(unit.attrAlloc.atk)/防\(unit.attrAlloc.def)/命\(unit.attrAlloc.hp)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text("每点：攻+\(WarConfig.Growth.perPointAtk)／防+\(WarConfig.Growth.perPointDef)／命+\(WarConfig.Growth.perPointHp)（与军费升档是两条独立成长轴）")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    /// 转职按钮的数值预览：拿**这个单位自己的**军费档与已分属性点去算分支数值
    /// （同一个 `Growth.stat`），否则面板写“HP140”而转完实际上是 168。
    private func promotionButton(_ key: String, for unit: WarUnit) -> some View {
        let branch = WarConfig.Growth.stat(typeKey: key, upgrades: unit.upgrades, alloc: unit.attrAlloc)
            ?? WarConfig.unitTypes[key]
        return Button {
            store.promoteSelected(to: key)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text("→ \(branch?.name ?? key)").font(.caption2.weight(.semibold))
                if let branch {
                    Text("HP\(branch.hp)/攻\(branch.atk)/防\(branch.def)\n动\(branch.moveRange)/射\(branch.attackRange)/\(branch.counterAttack ? "可反击" : "不反击")")
                        .font(.caption2)
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .tint(Theme.accent)
        .disabled(!store.canPromoteSelected)
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
                        // 名称/射程读升档后的那一份：待选态提示与紫色格同一口径
                        let stat = WarConfig.spellStat(key, level: unit.spellLevels[key] ?? 0)
                            ?? WarConfig.spells[key]!
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
                Text("再点棋盘上的紫色格施放；点同一按钮取消，点其它棋子则取消并切换选中")
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
                        row("升级", "攻\(info.unit.upgrades.atk)/防\(info.unit.upgrades.def)/命\(info.unit.upgrades.hp)")
                        row("等级 / 经验", growthText(info.unit))
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

    /// 成长读数（情报面板）。字段全取 `UnitView`（即内核），这里只把人话拼起来。
    private func growthText(_ unit: BoardFrame.UnitView) -> String {
        var parts: [String] = ["Lv\(unit.level)/\(WarConfig.Growth.levelCap(promoted: unit.branchKey != nil))"]
        parts.append(unit.expToNext > 0 ? "经验 \(unit.expIntoLevel)/\(unit.expToNext)" : "经验已满")
        if unit.attrBank > 0 { parts.append("待分 \(unit.attrBank) 点") }
        if let branch = unit.branchKey, let name = WarConfig.unitTypes[branch]?.name {
            parts.append("分支：\(name)")
        } else if unit.canPromote {
            parts.append("可转职")
        }
        return parts.joined(separator: " · ")
    }

    /// 首领逐 kind 的携带明细。棋盘角上只画总发数（地方太小），这里的账要给全：
    /// “买了 2 发治疗 1 发冰冻”与“买了 3 发治疗”对玩家是两个不同决定。
    private func chiefChargeText(_ unit: BoardFrame.UnitView) -> String {
        let parts = WarConfig.spellOrder.compactMap { key -> String? in
            let count = unit.spellCharges[key] ?? 0
            guard count > 0 else { return nil }
            let level = unit.spellLevels[key] ?? 0
            return "\(WarConfig.spells[key]?.name ?? key)×\(count)" + (level > 0 ? "(\(level)档)" : "")
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

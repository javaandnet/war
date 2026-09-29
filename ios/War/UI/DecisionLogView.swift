import SwiftUI
import WarKit

/// AI 决策面板：战略结论 + 每个单位的候选评分明细。
///
/// 这里刻意把 `Scorer` 的分项原样列出（伤害/暴露风险/反击风险…），
/// 让"为什么它这么走"可被非程序员读懂 —— 调参时不用再回去读代码。
struct DecisionLogView: View {
    @EnvironmentObject private var store: GameStore

    var body: some View {
        Group {
            if let plan = store.lastPlan {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        strategyCard(plan)
                        ForEach(plan.logs, id: \.unitId) { log in
                            decisionCard(log, plan: plan)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else {
                ContentUnavailableView("尚无 AI 回合",
                                       systemImage: "brain.head.profile",
                                       description: Text("切换到「AI 自动对战」或结束本方回合即可看到决策记录"))
            }
        }
    }

    private func strategyCard(_ plan: TurnPlan) -> some View {
        let diff = store.settings.difficulty
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("\(store.campLabel(plan.camp))·\(diff.name)")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: "%.1fms", plan.elapsedMs)).font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("战略 \(Theme.strategyNames[plan.strategy] ?? plan.strategy) → 目标区 (\(plan.objective.x),\(plan.objective.y))"
                 + (plan.focusId.map { " · 集火 #\($0)" } ?? ""))
                .font(.caption)
            Text("温度 \(String(format: "%.2f", diff.temperature)) · 前瞻 \(diff.lookahead) 层 · 视野 \(diff.vision == .max ? "全图" : "\(diff.vision)")"
                 + (store.power.shouldReduceWorkload ? " · 省电：前瞻已降级" : ""))
                .font(.caption2).foregroundStyle(.secondary)
            Text("\(plan.events.count) 个事件 / \(plan.decisionCount) 次决策 · seed \(store.settings.aiSeed)")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.campColor(plan.camp).opacity(0.14)))
    }

    private func decisionCard(_ log: DecisionLog, plan: TurnPlan) -> some View {
        let chosen = plan.events.first(where: {
            $0.unitId == log.unitId && ($0.kind == .attack || $0.kind == .spell)
        })
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(log.unitName) #\(log.unitId)").font(.caption.weight(.semibold))
                Text(kindText(log)).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f 分", log.score)).font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.accent)
            }
            ForEach(Array(log.top.enumerated()), id: \.offset) { index, cand in
                HStack(alignment: .top, spacing: 6) {
                    Text("#\(index + 1)").font(.caption2).foregroundStyle(.tertiary)
                        .frame(width: 22, alignment: .leading)
                    Text("\(kindText(cand.kind, targetId: cand.targetId, spellKey: cand.spellKey)) → (\(cand.action.x),\(cand.action.y))")
                        .font(.caption2)
                    Spacer()
                    Text(String(format: "%.1f", cand.score)).font(.caption2.monospacedDigit())
                        .foregroundStyle(index == 0 ? .primary : .secondary)
                }
            }
            partsLine(log.parts)
            if let chosen, chosen.score != log.score {
                Text("采样偏移：本可 \(String(format: "%.1f", chosen.score)) 分（温度 \(String(format: "%.2f", store.settings.difficulty.temperature)) 允许它偶尔手软）")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.35)))
    }

    private func partsLine(_ parts: [String: Double]) -> some View {
        let notable = parts.filter { abs($0.value) >= 0.06 }
            .sorted { abs($0.value) > abs($1.value) }
            .prefix(6)
        return PartsSummary(items: notable.map { p in
            let name = Theme.partNames[p.key] ?? p.key
            return "\(name) \(p.value >= 0 ? "+" : "")\(String(format: "%.2f", p.value))"
        })
    }

    private func kindText(_ log: DecisionLog) -> String {
        kindText(log.kind, targetId: log.targetId, spellKey: log.spellKey)
    }

    private func kindText(_ kind: CandidateKind, targetId: Int?, spellKey: String? = nil) -> String {
        switch kind {
        case .wait: return "待命"
        case .move: return "移动"
        case .attack: return targetId.map { "攻击 #\($0)" } ?? "攻击"
        case .moveAttack: return targetId.map { "机动后攻击 #\($0)" } ?? "机动后攻击"
        case .spell:
            // 魔法名取内核配置表（UI 不另存一份名字，改了配置这里跟着变）
            let name = spellKey.flatMap { WarConfig.spells[$0]?.name } ?? "魔法"
            return targetId.map { "施放\(name) → #\($0)" } ?? "施放\(name)"
        }
    }
}

/// 评分分项摘要：取绝对值最大的几项拼成一行，能折行不截断
struct PartsSummary: View {
    let items: [String]

    var body: some View {
        if items.isEmpty {
            EmptyView()
        } else {
            Text(items.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

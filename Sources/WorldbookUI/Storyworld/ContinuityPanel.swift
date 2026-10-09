import StoryworldCore
import SwiftUI

struct ContinuityPanel: View {
  let snapshot: StorySessionSnapshot
  let propose: (ContinuityCalibrationDraft, UUID, StorySessionSnapshot) async -> String?
  let decide: (UUID, ContinuityCalibrationDecision, SessionAddress) async -> String?
  let jump: (StoryAnchorEventRef) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var showFinished = false
  @State private var visibleCount = 50
  @State private var reviewCount = 50
  @State private var target: ContinuityCalibrationTarget?
  @State private var deciding = false
  @State private var error: String?

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text("记录由模型从已提交正文提取。本地校验检查格式、引用与变更规则，不能保证语义理解正确；可查看原文核对。")
            .foregroundStyle(.secondary)
          if let notice = snapshot.continuityNotice { Text(notice).foregroundStyle(.orange) }
        }
        if let ledger = snapshot.continuity?.ledger {
          Section("玩家校准") {
            Text("提案经你确认后，仅作用于后续回合。旧正文不会改写；引用匹配不能代替你对事实的判断。")
              .font(.caption).foregroundStyle(.secondary)
            HStack {
              Button("补充事实") { target = .fact(nil) }
              Button("登记角色或物品") { target = .entity(nil) }
            }.disabled(snapshot.effectiveTurns.isEmpty)
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(Array(snapshot.calibrationReviews.reversed().prefix(reviewCount))) { review in
              VStack(alignment: .leading, spacing: 6) {
                Text(review.proposal.draft.reason).font(.headline)
                ForEach(Array(review.proposal.preview.enumerated()), id: \.offset) { _, text in
                  Text(text).font(.caption)
                }
                Text("依据：" + review.proposal.draft.quote).font(.caption).textSelection(.enabled)
                sourceButton(review.proposal.draft.source, label: "查看校准依据")
                if let decision = review.decision {
                  Text(decision == .accepted ? "已确认" : "已拒绝").font(.caption).foregroundStyle(.secondary)
                } else {
                  HStack {
                    Button("确认并用于后续回合") { decide(review, .accepted) }
                    Button("拒绝提案", role: .destructive) { decide(review, .rejected) }
                  }.disabled(deciding)
                }
              }.padding(.vertical, 4)
            }
            if snapshot.calibrationReviews.count > reviewCount {
              Button("显示更多校准提案") { reviewCount += 50 }
            }
          }
          Section("覆盖情况") {
            Text("旧版未记录 \(ledger.legacyTurnCount) 回合 · 待核对 \(ledger.unresolvedTurnCount) 回合")
            if let source = ledger.latestGap { sourceButton(source, label: "查看最近缺口") }
          }
          Section("当前场景") {
            Button("校准场景") { target = .scene }.disabled(snapshot.effectiveTurns.isEmpty)
            if let scene = ledger.scene {
              Text([scene.location, scene.time].filter { !$0.isEmpty }.joined(separator: " · "))
              Text("记录在场：" + names(scene.presentEntityIDs, ledger: ledger))
              Text(scene.source.quote).font(.caption).textSelection(.enabled)
              sourceButton(scene.source.event, label: "查看场景依据")
            } else {
              Text("尚未记录场景；不根据名字提及推断在场。")
            }
          }
          Section("事实与约定") {
            Toggle("显示已结束记录", isOn: $showFinished)
            let facts = ledger.facts.values.filter { showFinished || $0.status == .active }
              .sorted { $0.id < $1.id }
            ForEach(Array(facts.prefix(visibleCount))) { fact in
              VStack(alignment: .leading, spacing: 7) {
                Text(fact.statement).font(.headline).textSelection(.enabled)
                Text(fact.kind.displayName + " · " + fact.status.displayName).font(.caption)
                Text("主体：" + names([fact.subjectID], ledger: ledger))
                Text("明确知情：" + names(fact.knownByEntityIDs, ledger: ledger)).font(.caption)
                if let first = fact.evidence.first {
                  Text(first.quote).font(.caption).foregroundStyle(.secondary).textSelection(
                    .enabled)
                  sourceButton(first.event, label: "查看原始依据")
                }
                if let last = fact.evidence.last, last != fact.evidence.first {
                  Text("最近变化：" + last.quote).font(.caption).foregroundStyle(.secondary)
                  sourceButton(last.event, label: "查看最近变化")
                }
                if fact.status != .retracted {
                  HStack {
                    Button("校准这条事实") { target = .fact(fact) }
                    Button("撤回错误记录") { target = .withdraw(fact) }
                  }
                }
              }.padding(.vertical, 5)
            }
            if facts.count > visibleCount {
              Button("显示更多（共 \(facts.count) 条）") { visibleCount += 50 }
            }
            if facts.isEmpty { Text("尚无对应记录。") }
          }
          Section("待确认身份") {
            let provisional = ledger.entities.values.filter(\.provisional).sorted { $0.id < $1.id }
            ForEach(Array(provisional.prefix(visibleCount))) { entity in
              Button("确认「" + entity.name + "」的独立身份") { target = .entity(entity) }
            }
            if provisional.count > visibleCount { Button("显示更多身份") { visibleCount += 50 } }
            if provisional.isEmpty { Text("没有待确认的实体。") }
          }
          if let receipts = ledger.calibrations, !receipts.isEmpty {
            Section("已生效校准（含继承记录）") {
              ForEach(Array(receipts.reversed().prefix(reviewCount))) { receipt in
                VStack(alignment: .leading) {
                  Text(receipt.reason)
                  Text("确认后作用于该分支第 \(receipt.afterEventSequence + 1) 回合起").font(.caption)
                  sourceButton(receipt.source.event, label: "查看依据")
                }
              }
              if receipts.count > reviewCount { Button("显示更早校准") { reviewCount += 50 } }
            }
          }
        }
      }
      .navigationTitle("连续性记录")
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
      .sheet(item: $target) { target in
        ContinuityCalibrationEditor(snapshot: snapshot, target: target, submit: propose)
      }
    }
    #if os(macOS)
      .frame(minWidth: 560, minHeight: 580)
    #endif
  }

  private func decide(_ review: ContinuityCalibrationReview, _ decision: ContinuityCalibrationDecision) {
    let address = snapshot.context.address
    deciding = true
    Task {
      error = await decide(review.id, decision, address)
      deciding = false
    }
  }

  private func names(_ ids: [String], ledger: ContinuityLedger) -> String {
    if ids.isEmpty { return "未明确记录" }
    return ids.map { id in
      let entity = ledger.entities[id]
      return (entity?.name ?? id) + (entity?.provisional == true ? "（身份待确认）" : "")
    }.joined(separator: "、")
  }
  private func sourceButton(_ source: StoryAnchorEventRef, label: String) -> some View {
    Button(label + " · 原回合 \(source.sequence)") { jump(source) }
      .disabled(!snapshot.effectiveTurns.contains { StoryAnchorEventRef($0) == source })
  }
}

extension ContinuityFactKind {
  var displayName: String {
    switch self {
    case .condition: "状态与伤病"
    case .relationship: "关系"
    case .possession: "持有物"
    case .promise: "承诺"
    case .secret: "秘密"
    case .goal: "目标"
    case .unresolved: "未决事项"
    }
  }
}
extension ContinuityFactStatus {
  var displayName: String {
    switch self {
    case .active: "有效"
    case .superseded: "已替代"
    case .fulfilled: "已履行"
    case .broken: "已违背"
    case .released: "已解除"
    case .resolved: "已解决"
    case .retracted: "已校准撤回"
    }
  }
}

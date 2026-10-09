import StoryworldCore
import SwiftUI

enum ContinuityCalibrationTarget: Identifiable {
  case scene, fact(ContinuityFact?), entity(ContinuityEntity?),
    withdraw(ContinuityFact)
  var id: String {
    switch self {
    case .scene: "scene"
    case .fact(let fact): "fact:" + (fact?.id ?? "new")
    case .entity(let entity): "entity:" + (entity?.id ?? "new")
    case .withdraw(let fact): "withdraw:" + fact.id
    }
  }
}

/// Captures the reviewed snapshot. Switching branches or new turns never silently retargets a draft.
struct ContinuityCalibrationEditor: View {
  let snapshot: StorySessionSnapshot
  let target: ContinuityCalibrationTarget
  let submit: (ContinuityCalibrationDraft, UUID, StorySessionSnapshot) async -> String?
  @Environment(\.dismiss) private var dismiss
  @State private var requestID = UUID()
  @State private var newFactSlot = "manual." + UUID().uuidString.lowercased()
  @State private var sourceIndex: Int
  @State private var quote = ""
  @State private var reason = ""
  @State private var location = ""
  @State private var time = ""
  @State private var people = Set<String>()
  @State private var statement = ""
  @State private var kind: ContinuityFactKind = .unresolved
  @State private var subject = "player"
  @State private var object = ""
  @State private var entityName = ""
  @State private var entityKind: ContinuityEntityKind = .character
  @State private var clearScene = false
  @State private var saving = false
  @State private var error: String?

  init(snapshot: StorySessionSnapshot, target: ContinuityCalibrationTarget,
    submit: @escaping (ContinuityCalibrationDraft, UUID, StorySessionSnapshot) async -> String?) {
    self.snapshot = snapshot
    self.target = target
    self.submit = submit
    let evidence: ContinuityEvidence?
    switch target {
    case .scene:
      let scene = snapshot.continuity?.ledger.scene
      evidence = scene?.source
      _location = State(initialValue: scene?.location ?? "")
      _time = State(initialValue: scene?.time ?? "")
      _people = State(initialValue: Set(scene?.presentEntityIDs ?? []))
    case .fact(let fact):
      evidence = fact?.evidence.last
      _statement = State(initialValue: fact?.statement ?? "")
      _kind = State(initialValue: fact?.kind ?? .unresolved)
      _subject = State(initialValue: fact?.subjectID ?? "player")
      _object = State(initialValue: fact?.objectID ?? "")
      _people = State(initialValue: Set(fact?.knownByEntityIDs ?? []))
    case .withdraw(let fact): evidence = fact.evidence.last
    case .entity(let entity): evidence = entity?.source
    }
    _sourceIndex = State(initialValue: evidence.flatMap { source in
      snapshot.effectiveTurns.firstIndex { StoryAnchorEventRef($0) == source.event }
    } ?? max(0, snapshot.effectiveTurns.count - 1))
    _quote = State(initialValue: evidence?.quote ?? "")
  }

  private var entities: [ContinuityEntity] {
    (snapshot.continuity?.ledger.entities.values.map { $0 } ?? []).sorted { $0.id < $1.id }
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text("先创建提案，再返回连续性面板审阅并确认。确认仅影响后续回合，旧正文、旧存档和已有子分支不会改写。")
          TextField("校准原因（必填，最多 500 字）", text: $reason, axis: .vertical)
        }
        Section("原文依据") {
          Picker("依据回合", selection: $sourceIndex) {
            ForEach(Array(snapshot.effectiveTurns.enumerated()), id: \.offset) { index, turn in
              Text("第 \(index + 1) 段 · " + String(turn.narrative.prefix(28))).tag(index)
            }
          }
          if snapshot.effectiveTurns.indices.contains(sourceIndex) {
            DisclosureGroup("查看本段正文") {
              Text(snapshot.effectiveTurns[sourceIndex].narrative).textSelection(.enabled)
            }
          }
          TextField("逐字摘录（1–300 字）", text: $quote, axis: .vertical)
          Text("引文只用于核对出处；请自行判断这段原文是否支持拟议变更。")
            .font(.caption).foregroundStyle(.secondary)
        }
        changesForm
        if let error { Section { Text(error).foregroundStyle(.red) } }
      }
      .navigationTitle("创建校准提案")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
        ToolbarItem(placement: .confirmationAction) {
          Button(saving ? "创建中…" : "创建提案") { Task { await create() } }
            .disabled(saving || snapshot.effectiveTurns.isEmpty || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || quote.isEmpty)
        }
      }
      .interactiveDismissDisabled(saving)
    }
    #if os(macOS)
      .frame(minWidth: 540, minHeight: 580)
    #endif
  }

  @ViewBuilder private var changesForm: some View {
    switch target {
    case .scene:
      Section("校准后的场景") {
        Toggle("清空场景记录", isOn: $clearScene)
        if !clearScene {
          TextField("地点", text: $location)
          TextField("时间", text: $time)
          peoplePicker(label: "明确在场")
        }
      }
    case .fact(let existing):
      Section(existing == nil ? "补充事实" : "撤回原记录并补充正确事实") {
        if let existing { Text("原记录：" + existing.statement).foregroundStyle(.secondary) }
        Picker("类型", selection: $kind) {
          ForEach([ContinuityFactKind.condition, .relationship, .possession, .promise, .secret, .goal, .unresolved], id: \.self) {
            Text($0.displayName).tag($0)
          }
        }.disabled(existing != nil)
        entityPicker("主体", selection: $subject, optional: false)
        entityPicker("对象 / 物品", selection: $object, optional: true)
        TextField("正确事实（最多 500 字）", text: $statement, axis: .vertical)
        peoplePicker(label: "明确知情")
      }
    case .withdraw(let fact):
      Section("撤回错误记录") {
        Text(fact.statement)
        Text("撤回表示记录错误，不等于人物在剧情中履行、违背或解除了承诺。原记录和依据会保留。")
      }
    case .entity(let entity):
      Section("实体身份") {
        if let entity {
          Text("确认「" + entity.name + "」是这一独立实体，不与任何同名实体合并。")
          Text(entity.id).font(.caption).textSelection(.enabled)
        } else {
          TextField("名称", text: $entityName)
          Picker("类型", selection: $entityKind) {
            Text("人物").tag(ContinuityEntityKind.character)
            Text("物品").tag(ContinuityEntityKind.item)
            Text("地点").tag(ContinuityEntityKind.place)
            Text("团体").tag(ContinuityEntityKind.group)
          }
          Text("登记后可在事实与场景中选用；不按名字自动合并。")
        }
      }
    }
  }

  private func entityPicker(_ label: String, selection: Binding<String>, optional: Bool) -> some View {
    Picker(label, selection: selection) {
      if optional { Text("无").tag("") }
      ForEach(entities) { entity in
        Text(entity.name + " · " + String(entity.id.suffix(12))).tag(entity.id)
      }
    }
  }
  private func peoplePicker(label: String) -> some View {
    DisclosureGroup(label + "（\(people.count)）") {
      ForEach(entities.filter { $0.kind == .character }) { entity in
        Toggle(entity.name + " · " + String(entity.id.suffix(12)), isOn: Binding(
          get: { people.contains(entity.id) },
          set: { if $0 { people.insert(entity.id) } else { people.remove(entity.id) } }))
      }
    }
  }
  private func create() async {
    guard snapshot.effectiveTurns.indices.contains(sourceIndex) else { return }
    var draft = ContinuityCalibrationDraft(reason: reason,
      source: .init(snapshot.effectiveTurns[sourceIndex]), quote: quote)
    switch target {
    case .scene:
      draft.clearScene = clearScene
      if !clearScene { draft.changes.scene = .init(location: location, time: time, presentEntityIDs: people.sorted(), quote: quote) }
    case .fact(let old):
      draft.retractFactIDs = old.map { [$0.id] } ?? []
      draft.changes.facts = [.init(kind: kind, subjectID: subject, objectID: object.isEmpty ? nil : object,
        slot: old?.slot ?? newFactSlot, statement: statement, knownByEntityIDs: people.sorted(), quote: quote)]
    case .withdraw(let fact): draft.retractFactIDs = [fact.id]
    case .entity(let entity):
      if let entity { draft.confirmEntityIDs = [entity.id] }
      else { draft.changes.entities = [.init(key: "new.manual", name: entityName, kind: entityKind, quote: quote)] }
    }
    saving = true
    error = await submit(draft, requestID, snapshot)
    saving = false
    if error == nil { dismiss() }
    else { requestID = UUID() }
  }
}

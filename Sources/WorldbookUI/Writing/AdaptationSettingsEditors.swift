import StoryworldCore
import SwiftUI
import WritingCore

struct AdaptationOriginalEditor: View {
  @ObservedObject var model: AdaptationViewModel
  @State private var title = ""
  @State private var author = ""
  @State private var plan = "第一章｜主角启程，确定目标。\n第二章｜遇到阻碍，作出选择。"
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    AdaptationEditorShell(title: "原创章节计划", model: model) {
      TextField("书名", text: $title)
      TextField("作者（可选）", text: $author)
      Text("每行一章，使用“标题｜梗概”。计划会保存并按章传给模型；后续可在方向合同中补充全书要求。").font(.caption)
      TextEditor(text: $plan).frame(minHeight: 220)
      Button("保存原创计划") { Task { if await model.createOriginal(title: title, author: author, plan: plan) { dismiss() } } }
        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
  }
}

struct AdaptationConfigurationEditor: View {
  @ObservedObject var model: AdaptationViewModel
  let jobID: UUID
  let configuration: AdaptationRunConfiguration
  @State private var value: AdaptationRunConfiguration
  @State private var focus: String
  @Environment(\.dismiss) private var dismiss
  init(model: AdaptationViewModel, jobID: UUID, configuration: AdaptationRunConfiguration) {
    self.model = model; self.jobID = jobID; self.configuration = configuration
    _value = State(initialValue: configuration); _focus = State(initialValue: configuration.focusNames.joined(separator: "\n"))
  }
  var body: some View {
    AdaptationEditorShell(title: "任务配置", model: model) {
      Section("模型与续跑") {
        Picker("模型", selection: $value.providerID) {
          Text("请选择").tag(Optional<UUID>.none)
          ForEach(model.providers) { Text($0.displayName + " · " + $0.modelID).tag(Optional($0.id)) }
        }
        Stepper("本次最多 \(value.maximumNewRequests) 个新请求", value: $value.maximumNewRequests, in: 0...100)
        Text("缓存不计入上限。0 表示只使用已有结果；分批继续不会自动重发结果未知的请求。").font(.caption).foregroundStyle(.secondary)
        Picker("正文生成方式", selection: $value.writeScope) {
          Text("完整章节").tag(AdaptationRunConfiguration.WriteScope.chapters)
          Text("已批准锚点").tag(AdaptationRunConfiguration.WriteScope.anchors)
        }
      }
      Section("选材与锚点") {
        Text("聚焦名字／别名，每行一个。名字命中用于筛选，不等于人物确实在场。").font(.caption)
        TextEditor(text: $focus).frame(minHeight: 70)
        Stepper("扫描密度 \(value.density)", value: $value.density, in: 1...5)
        Toggle("已完整扫描但无位置的章节补章首点", isOn: $value.addChapterStarts)
        Stepper("提取片段上限 \(value.maximumUnitUTF16Length)", value: $value.maximumUnitUTF16Length, in: 1_000...50_000, step: 1_000)
        DisclosureGroup("章节范围：不勾选表示全部") {
          Button("使用全部章节") { value.chapterIDs = [] }
          ForEach(model.source?.chapters ?? []) { chapter in
            Toggle(chapter.title, isOn: Binding(get: { value.chapterIDs.contains(chapter.id) }, set: { selected in
              if selected { value.chapterIDs.append(chapter.id) } else { value.chapterIDs.removeAll { $0 == chapter.id } }
            }))
          }
        }
      }
      Section("本任务表达偏好") {
        Text("未覆盖时沿用个人默认。作者合同和人物／世界事实优先。").font(.caption)
        Picker("节奏", selection: $value.taskTaste.pace) {
          Text("沿用").tag(Optional<PlayerTasteProfile.Pace>.none)
          ForEach(PlayerTasteProfile.Pace.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
        }
        Picker("文风", selection: $value.taskTaste.style) {
          Text("沿用").tag(Optional<PlayerTasteProfile.Style>.none)
          ForEach(PlayerTasteProfile.Style.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
        }
        Picker("详略", selection: $value.taskTaste.detail) {
          Text("沿用").tag(Optional<PlayerTasteProfile.Detail>.none)
          ForEach(PlayerTasteProfile.Detail.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
        }
        Toggle("覆盖文风强度", isOn: Binding(get: { value.taskTaste.styleIntensity != nil }, set: { value.taskTaste.styleIntensity = $0 ? 3 : nil }))
        if value.taskTaste.styleIntensity != nil {
          Stepper("文风强度 \(value.taskTaste.styleIntensity ?? 3)", value: Binding(get: { value.taskTaste.styleIntensity ?? 3 }, set: { value.taskTaste.styleIntensity = $0 }), in: 1...5)
        }
        Toggle("覆盖避开项", isOn: Binding(get: { value.taskTaste.avoidElements != nil }, set: { value.taskTaste.avoidElements = $0 ? [] : nil }))
        if value.taskTaste.avoidElements != nil {
          TextEditor(text: Binding(get: { value.taskTaste.avoidElements?.joined(separator: "\n") ?? "" },
            set: { value.taskTaste.avoidElements = $0.components(separatedBy: .newlines) })).frame(minHeight: 70)
        }
        Toggle("覆盖补充偏好", isOn: Binding(get: { value.taskTaste.notes != nil }, set: { value.taskTaste.notes = $0 ? "" : nil }))
        if value.taskTaste.notes != nil { TextEditor(text: Binding(get: { value.taskTaste.notes ?? "" }, set: { value.taskTaste.notes = $0 })).frame(minHeight: 70) }
        Button("全部沿用个人偏好") { value.taskTaste = .init() }
      }
      Button("保存任务配置") {
        value.focusNames = adaptationLines(focus)
        if let avoided = value.taskTaste.avoidElements { value.taskTaste.avoidElements = adaptationLines(avoided.joined(separator: "\n")) }
        Task { if await model.saveConfiguration(value, jobID: jobID, expected: configuration.revision) { dismiss() } }
      }
    }
  }
}

struct AdaptationDirectionEditor: View {
  @ObservedObject var model: AdaptationViewModel
  let revision: AdaptationContractRevision?
  @State private var value: AdaptationDirectionContract
  @State private var title = ""
  @State private var bindBookcase = false
  @Environment(\.dismiss) private var dismiss
  init(model: AdaptationViewModel, revision: AdaptationContractRevision?) {
    self.model = model; self.revision = revision
    _value = State(initialValue: revision?.contract ?? .init())
  }
  var body: some View {
    AdaptationEditorShell(title: revision == nil ? "新建正文方向" : "方向合同", model: model) {
      Section("方向") {
        if revision == nil { TextField("方向名称", text: $title) }
        Picker("模式", selection: $value.mode) { ForEach(AdaptationDirectionContract.Mode.allCases, id: \.self) { Text($0.adaptationLabel).tag($0) } }
        if model.job?.approvedBookcaseID != nil {
          Toggle(revision == nil ? "使用已批准书案" : "明确绑定当前已批准书案", isOn: $bindBookcase)
        }
        Text("已有方向保留原绑定；仅在勾选后换用新书案。修改合同后，旧正文会显示依赖过期。").font(.caption).foregroundStyle(.secondary)
        TextField("视角", text: $value.viewpoint)
        Text("主角身份标识（每行一个，来自已批准书案）").font(.caption)
        TextEditor(text: adaptationArrayBinding($value.protagonistIDs)).frame(minHeight: 60)
      }
      Section("人物与情节约束") {
        Text("不可改变的身份事实，每行一项").font(.caption)
        TextEditor(text: adaptationArrayBinding($value.identityInvariants)).frame(minHeight: 80)
        TextField("关系方向", text: $value.relationshipDirection, axis: .vertical)
        Toggle("允许新增关系", isOn: $value.allowNewRelationships)
        Stepper("剧情强度 \(value.plotIntensity)", value: $value.plotIntensity, in: 1...5)
        Picker("事件顺序", selection: $value.eventMobility) {
          Text("固定").tag(AdaptationDirectionContract.EventMobility.fixed)
          Text("可重排").tag(AdaptationDirectionContract.EventMobility.reorder)
          Text("自由").tag(AdaptationDirectionContract.EventMobility.free)
        }
        Toggle("允许删减事件", isOn: $value.allowDropEvents)
        Text("必须保留的事件，每行一项").font(.caption)
        TextEditor(text: adaptationArrayBinding($value.ironEvents)).frame(minHeight: 80)
        Text("允许添加的元素，每行一项").font(.caption)
        TextEditor(text: adaptationArrayBinding($value.allowedAdditions)).frame(minHeight: 60)
        Text("禁止添加的元素，每行一项").font(.caption)
        TextEditor(text: adaptationArrayBinding($value.forbiddenAdditions)).frame(minHeight: 60)
      }
      Section("篇幅与原文") {
        TextField("目标字数", value: $value.targetCharacterCount, format: .number)
        TextField("最少字数", value: $value.minimumCharacterCount, format: .number)
        Toggle("限制最多字数", isOn: Binding(
          get: { value.maximumCharacterCount != nil },
          set: { value.maximumCharacterCount = $0 ? max(value.targetCharacterCount, value.minimumCharacterCount) : nil }))
        if value.maximumCharacterCount != nil {
          TextField("最多字数", value: Binding(
            get: { value.maximumCharacterCount ?? value.targetCharacterCount },
            set: { value.maximumCharacterCount = $0 }), format: .number)
          Text("字数包含标点和空白。最少 ≤ 目标 ≤ 最多；超限候选会显示告警，批准前需明确核对。")
            .font(.caption).foregroundStyle(.secondary)
        }
        Stepper("原文保留比例要求 \(value.originalRetentionPercent)%", value: $value.originalRetentionPercent, in: 0...100)
        Toggle("将原章正文加入生成上下文", isOn: $value.includeOriginalChapter)
        Text("比例是对模型的要求，需要人工核对；不是自动核验结论。原创章节梗概会作为作者计划单独提供。").font(.caption).foregroundStyle(.secondary)
      }
      Section("文风与补充") {
        TextField("文风要求", text: $value.style, axis: .vertical)
        TextEditor(text: $value.notes).frame(minHeight: 120)
      }
      Button("保存方向合同") {
        value.protagonistIDs = adaptationLines(value.protagonistIDs.joined(separator: "\n"))
        value.identityInvariants = adaptationLines(value.identityInvariants.joined(separator: "\n"))
        value.ironEvents = adaptationLines(value.ironEvents.joined(separator: "\n"))
        value.allowedAdditions = adaptationLines(value.allowedAdditions.joined(separator: "\n"))
        value.forbiddenAdditions = adaptationLines(value.forbiddenAdditions.joined(separator: "\n"))
        Task { if await model.saveDirection(title: title, contract: value, expected: revision, bindApprovedBookcase: bindBookcase) { dismiss() } }
      }.disabled(revision == nil && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
  }
}

extension AdaptationDirectionContract.Mode {
  var adaptationLabel: String {
    switch self { case .rewrite: "文风改写"; case .expand: "扩写"; case .abridge: "缩写"; case .annotate: "批注"; case .alternateEnding: "平行结局"; case .original: "原创" }
  }
}
extension AdaptationAnchorAction {
  var adaptationLabel: String { switch self { case .insertion: "引文前插入"; case .rewrite: "替换引文"; case .newChapter: "原章后新增一章" } }
}

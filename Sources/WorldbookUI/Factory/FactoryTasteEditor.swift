import StoryworldCore
import StoryworldFactory
import SwiftUI

struct FactoryTasteEditing: Identifiable {
  let id = UUID()
  let settings: FactoryTasteSettings
}

struct FactoryTasteEditor: View {
  let settings: FactoryTasteSettings
  let save: (PlayerTasteOverrides) async -> String?
  @Environment(\.dismiss) private var dismiss
  @State private var draft: PlayerTasteOverrides
  @State private var avoided: String
  @State private var notes: String
  @State private var busy = false
  @State private var error: String?

  init(settings: FactoryTasteSettings, save: @escaping (PlayerTasteOverrides) async -> String?) {
    self.settings = settings; self.save = save
    _draft = State(initialValue: settings.overrides)
    _avoided = State(initialValue: (settings.overrides.avoidElements ?? settings.inherited.avoidElements).joined(separator: "\n"))
    _notes = State(initialValue: settings.overrides.notes ?? settings.inherited.notes)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("只用于本任务") {
          Text("未覆盖的维度在生成时沿用个人默认；若从命令行启动，命令行选项优先于个人默认。人工确认的具体决策优先。")
            .font(.caption).foregroundStyle(.secondary)
          Picker("节奏", selection: $draft.pace) {
            Text("沿用：\(settings.inherited.pace.label)").tag(Optional<PlayerTasteProfile.Pace>.none)
            ForEach(PlayerTasteProfile.Pace.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
          }
          Picker("文风", selection: $draft.style) {
            Text("沿用：\(settings.inherited.style.label)").tag(Optional<PlayerTasteProfile.Style>.none)
            ForEach(PlayerTasteProfile.Style.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
          }
          Picker("详略", selection: $draft.detail) {
            Text("沿用：\(settings.inherited.detail.label)").tag(Optional<PlayerTasteProfile.Detail>.none)
            ForEach(PlayerTasteProfile.Detail.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
          }
          Toggle("覆盖文风强度（沿用为 \(settings.inherited.styleIntensity)）", isOn: Binding(
            get: { draft.styleIntensity != nil }, set: { draft.styleIntensity = $0 ? settings.inherited.styleIntensity : nil }))
          if draft.styleIntensity != nil {
            Stepper("文风强度：\(draft.styleIntensity ?? 3)", value: Binding(
              get: { draft.styleIntensity ?? 3 }, set: { draft.styleIntensity = $0 }), in: 1...5)
          }
        }
        Section("希望避开的描写") {
          Toggle("覆盖避开项", isOn: Binding(get: { draft.avoidElements != nil },
            set: { draft.avoidElements = $0 ? [] : nil }))
          TextEditor(text: $avoided).frame(minHeight: 90).disabled(draft.avoidElements == nil)
          Text("每行一项，最多 20 项，每项 80 字。启用覆盖后留空表示清空继承项。通过略写细节调整表达，不删除来源事实。")
            .font(.caption).foregroundStyle(.secondary)
        }
        Section("补充偏好") {
          Toggle("覆盖补充偏好", isOn: Binding(get: { draft.notes != nil }, set: { draft.notes = $0 ? "" : nil }))
          TextEditor(text: $notes).frame(minHeight: 90).disabled(draft.notes == nil)
          Text("最多 1000 字；启用覆盖后留空表示清空继承内容。") .font(.caption).foregroundStyle(.secondary)
        }
        Button("全部沿用默认来源") { draft = .init(); avoided = settings.inherited.avoidElements.joined(separator: "\n"); notes = settings.inherited.notes }
        Text("保存设置不调用模型。再次生成将复用原文分析，按新的有效偏好调整候选表达；受影响的生成块会重新请求，可能产生模型费用。")
          .font(.caption).foregroundStyle(.secondary)
        if let error { Text(error).foregroundStyle(.red) }
      }.formStyle(.grouped).disabled(busy).navigationTitle("任务表达偏好")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
          ToolbarItem(placement: .confirmationAction) { Button("保存") { saveDraft() }.disabled(busy) }
        }
    }.frame(minWidth: 320, idealWidth: 540, minHeight: 480).interactiveDismissDisabled(busy)
  }

  private func saveDraft() {
    if draft.avoidElements != nil {
      draft.avoidElements = avoided.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
    if draft.notes != nil { draft.notes = notes }
    do { draft = try draft.validated() } catch { self.error = error.localizedDescription; return }
    let value = draft
    busy = true
    Task { error = await save(value); busy = false; if error == nil { dismiss() } }
  }
}

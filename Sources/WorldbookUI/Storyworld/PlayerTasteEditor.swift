import StoryworldCore
import SwiftUI

struct PlayerTasteEditing: Identifiable {
  let id = UUID()
  let snapshot: PlayerTasteSnapshot
}

struct PlayerTasteEditor: View {
  let save: (PlayerTasteProfile) async -> String?
  @Environment(\.dismiss) private var dismiss
  @State private var draft: PlayerTasteProfile
  @State private var avoided: String
  @State private var busy = false
  @State private var error: String?

  init(profile: PlayerTasteProfile, save: @escaping (PlayerTasteProfile) async -> String?) {
    self.save = save
    _draft = State(initialValue: profile)
    _avoided = State(initialValue: profile.avoidElements.joined(separator: "\n"))
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("跨书共用") {
          Text("后续叙事与工坊生成会读取新偏好。正在生成的游玩回合沿用开始时的配置；工坊生成结束时若有效偏好变化，会保留已有成果并提示重新生成。人工具体要求及任务或游玩线配置优先。")
            .font(.caption).foregroundStyle(.secondary)
          Picker("叙事节奏", selection: $draft.pace) {
            ForEach(PlayerTasteProfile.Pace.allCases, id: \.self) { Text($0.label).tag($0) }
          }
          Picker("文风", selection: $draft.style) {
            ForEach(PlayerTasteProfile.Style.allCases, id: \.self) { Text($0.label).tag($0) }
          }
          Picker("描写详略", selection: $draft.detail) {
            ForEach(PlayerTasteProfile.Detail.allCases, id: \.self) { Text($0.label).tag($0) }
          }
          Stepper("文风强度：\(draft.styleIntensity)", value: $draft.styleIntensity, in: 1...5)
        }
        Section("希望避开的描写") {
          Text("每行一项，最多 20 项，每项 80 字。模型会按偏好略写相关细节；这不是已生成文本的自动过滤器。")
            .font(.caption).foregroundStyle(.secondary)
          TextEditor(text: $avoided).frame(minHeight: 100)
        }
        Section("补充偏好（最多 1000 字）") {
          TextEditor(text: $draft.notes).frame(minHeight: 100)
          Text("偏好只调节表达，不改写世界事实、已发生事件或存档。")
            .font(.caption).foregroundStyle(.secondary)
        }
        Button("恢复默认设置") { draft = .standard; avoided = "" }
        if let error { Text(error).foregroundStyle(.red) }
      }.formStyle(.grouped).disabled(busy)
        .navigationTitle("个人叙事偏好")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
          ToolbarItem(placement: .confirmationAction) { Button("保存") { saveDraft() }.disabled(busy) }
        }
    }.frame(minWidth: 320, idealWidth: 520, minHeight: 480)
      .interactiveDismissDisabled(busy)
  }

  private func saveDraft() {
    draft.avoidElements = avoided.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    do { draft = try draft.validated() } catch { self.error = error.localizedDescription; return }
    let profile = draft
    busy = true
    Task {
      error = await save(profile); busy = false
      if error == nil { dismiss() }
    }
  }
}

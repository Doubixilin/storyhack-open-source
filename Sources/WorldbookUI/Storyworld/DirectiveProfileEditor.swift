import StoryworldCore
import SwiftUI

struct DirectiveProfileEditing: Identifiable {
  let id = UUID()
  let profile: DirectiveProfile
  let previous: DirectiveProfile?
  let address: SessionAddress
  let revision: UUID?
}

struct DirectiveProfileEditor: View {
  let context: DirectiveProfileEditing
  let save: (DirectiveProfile) async -> String?
  let remove: () async -> String?
  @Environment(\.dismiss) private var dismiss
  @State private var draft: DirectiveProfile
  @State private var output: String
  @State private var recap: String
  @State private var busy = false
  @State private var error: String?

  init(context: DirectiveProfileEditing, save: @escaping (DirectiveProfile) async -> String?,
    remove: @escaping () async -> String?) {
    self.context = context; self.save = save; self.remove = remove
    _draft = State(initialValue: context.profile)
    _output = State(initialValue: context.profile.maximumOutputTokens.map(String.init) ?? "")
    _recap = State(initialValue: context.profile.recapInterval.map(String.init) ?? "")
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("叙事档案") {
          TextField("名称", text: $draft.name)
          TextField("简介", text: $draft.summary)
          Text("通用叙事要求")
          TextEditor(text: $draft.preamble).frame(minHeight: 100)
          Text("这些要求只补充表达与节奏，固定格式、状态权限和玩家选择规则始终保留。")
            .font(.caption).foregroundStyle(.secondary)
        }
        Section("按模式补充（可留空）") {
          ForEach(StoryPlayMode.allCases) { mode in
            Text(mode.displayName)
            TextEditor(text: Binding(get: { draft.modeRules[mode.rawValue] ?? "" },
              set: { draft.modeRules[mode.rawValue] = $0 })).frame(minHeight: 60)
          }
        }
        Section("请求设置") {
          TextField("输出上限：512–65536，留空沿用模型设置", text: $output)
          TextField("摘要间隔：0–200 回合，留空为 20，0 为关闭", text: $recap)
          Text("档案输出上限受模型设置约束。保存并应用只改变当前游玩线的后续叙事；其它游玩线保留其已选版本。")
            .font(.caption).foregroundStyle(.secondary)
        }
        if let error { Text(error).foregroundStyle(.red) }
        if context.previous != nil {
          Section {
            Button("删除公共档案", role: .destructive) {
              busy = true
              Task {
                error = await remove(); busy = false
                if error == nil { dismiss() }
              }
            }
            Text("已经选用的游玩线保留档案副本。") .font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      .formStyle(.grouped)
      .disabled(busy)
      .navigationTitle(context.previous == nil ? "新建叙事档案" : "编辑叙事档案")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
        ToolbarItem(placement: .confirmationAction) { Button("保存并应用") { saveDraft() }.disabled(busy) }
      }
    }
    .frame(minWidth: 320, idealWidth: 560, minHeight: 480)
    .interactiveDismissDisabled(busy)
  }

  private func saveDraft() {
    let outputText = output.trimmingCharacters(in: .whitespacesAndNewlines)
    let recapText = recap.trimmingCharacters(in: .whitespacesAndNewlines)
    guard outputText.isEmpty || Int(outputText) != nil, recapText.isEmpty || Int(recapText) != nil else {
      error = "输出上限与摘要间隔请输入整数或留空。"; return
    }
    draft.maximumOutputTokens = Int(outputText)
    draft.recapInterval = Int(recapText)
    do { _ = try draft.validated() } catch { self.error = error.localizedDescription; return }
    let profile = draft
    busy = true
    Task {
      error = await save(profile); busy = false
      if error == nil { dismiss() }
    }
  }
}

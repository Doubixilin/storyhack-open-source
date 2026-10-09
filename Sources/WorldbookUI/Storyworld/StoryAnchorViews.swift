import StoryworldCore
import SwiftUI

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

struct StoryAnchorEditingContext {
  let anchor: StoryAnchor
  let address: SessionAddress
  let revision: UUID?
  let isExisting: Bool
}

struct StoryAnchorJump: Equatable {
  let id = UUID()
  let ref: StoryAnchorEventRef
}

enum StoryAnchorPresentation: Identifiable {
  case list
  case edit(StoryAnchorEditingContext)
  var id: String {
    switch self {
    case .list: "list"
    case .edit(let context): context.anchor.id.uuidString
    }
  }
}

struct StoryAnchorPanel: View {
  let snapshot: StorySessionSnapshot
  let edit: (StoryAnchor) -> Void
  let jump: (StoryAnchorEventRef) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text("锚点卡和相关原文按预算进入后续上下文。分叉时复制已经历回合的锚点，后续各分支独立编辑。")
            .font(.caption).foregroundStyle(.secondary)
          if let notice = snapshot.anchorState.notice { Text(notice).foregroundStyle(.orange) }
        }
        if snapshot.anchorState.anchors.isEmpty {
          Text("在故事正文下点击“标记锚点”，记住一段重要经历。")
        }
        ForEach(snapshot.anchorState.anchors) { anchor in
          VStack(alignment: .leading, spacing: 8) {
            Label(anchor.label, systemImage: anchor.enabled ? "bookmark.fill" : "bookmark.slash")
              .font(.headline)
            Text(
              "\(anchor.kind.title) · \(anchor.eventRef.branchID == snapshot.context.address.branchID ? "当前分支" : "继承自 " + anchor.eventRef.branchID.uuidString.prefix(8)) · 原回合 \(anchor.eventRef.sequence)\(anchor.enabled ? "" : " · 已停用")"
            )
            .font(.caption).foregroundStyle(.secondary)
            if !anchor.note.isEmpty { Text(anchor.note).font(.subheadline).textSelection(.enabled) }
            HStack {
              Button("查看原文") { jump(anchor.eventRef) }
              Button("编辑") { edit(anchor) }
            }
            .buttonStyle(.borderless)
          }
          .padding(.vertical, 4)
        }
      }
      .navigationTitle("记忆锚点")
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
    }
    .frame(minWidth: 300, idealWidth: 520, minHeight: 420)
  }
}

struct StoryAnchorEditor: View {
  let context: StoryAnchorEditingContext
  let save: (StoryAnchor) async -> String?
  let remove: () async -> String?
  @Environment(\.dismiss) private var dismiss
  @State private var label: String
  @State private var note: String
  @State private var kind: StoryAnchor.Kind
  @State private var enabled: Bool
  @State private var error: String?
  @State private var isSaving = false

  init(
    context: StoryAnchorEditingContext, save: @escaping (StoryAnchor) async -> String?,
    remove: @escaping () async -> String?
  ) {
    self.context = context
    self.save = save
    self.remove = remove
    _label = State(initialValue: context.anchor.label)
    _note = State(initialValue: context.anchor.note)
    _kind = State(initialValue: context.anchor.kind)
    _enabled = State(initialValue: context.anchor.enabled)
  }

  var body: some View {
    NavigationStack {
      Form {
        TextField("标题（1–100 字）", text: $label)
        Picker("类型", selection: $kind) {
          ForEach(StoryAnchor.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        TextField("笔记（最多 1000 字）", text: $note, axis: .vertical).lineLimit(3...8)
        Toggle("用于后续上下文", isOn: $enabled)
        Text(
          "原回合 \(context.anchor.eventRef.sequence) · \(context.anchor.eventRef.branchID.uuidString.prefix(8))\n笔记不会改写原始事件。"
        )
        .font(.caption).foregroundStyle(.secondary)
        if let error { Text(error).foregroundStyle(.red) }
        if context.isExisting {
          Button("移除锚点", role: .destructive) {
            Task {
              isSaving = true
              error = await remove()
              isSaving = false
              if error == nil { dismiss() }
            }
          }
        }
      }
      .padding()
      .disabled(isSaving)
      .navigationTitle(context.isExisting ? "编辑锚点" : "标记锚点")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("保存") {
            Task {
              isSaving = true
              error = await save(
                StoryAnchor(
                  id: context.anchor.id, eventRef: context.anchor.eventRef,
                  kind: kind, label: label, note: note, enabled: enabled,
                  createdAt: context.anchor.createdAt))
              isSaving = false
              if error == nil { dismiss() }
            }
          }
          .disabled(
            isSaving || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || label.count > 100 || note.count > 1_000)
        }
      }
    }
    .frame(minWidth: 300, idealWidth: 500, minHeight: 380)
  }
}

@MainActor enum StoryAnchorClipboard {
  static func copy(_ text: String) {
    #if canImport(AppKit)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    #elseif canImport(UIKit)
      UIPasteboard.general.string = text
    #endif
  }
}

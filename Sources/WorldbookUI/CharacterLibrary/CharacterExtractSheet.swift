import CharacterLibraryCore
import StoryworldCore
import SwiftUI

/// 从世界书条目提取角色：选世界书 → 选条目 → 模型整理草稿 → 可编辑预览 → 入库
struct CharacterExtractSheet: View {
  @ObservedObject var model: CharacterLibraryViewModel
  @ObservedObject var storyworldModel: StoryworldViewModel
  @Environment(\.dismiss) private var dismiss

  @State private var sourceID: UUID?
  @State private var sourceDocument: StoryworldDocument?
  @State private var draft: CharacterExtractionDraft?
  @State private var tagsText = ""
  @State private var didStartExtraction = false

  private var sourceTitle: String {
    storyworldModel.records.first { $0.id == sourceID }?.manifest.title ?? ""
  }

  private var groupedEntries: [(title: String, entries: [LoreEntry])] {
    guard let document = sourceDocument else { return [] }
    var groups: [(String, [LoreEntry])] = []
    var categorized = Set<String>()
    for category in document.lorebook.categories {
      let entries = document.lorebook.entries.filter { $0.categoryID == category.id }
      if !entries.isEmpty {
        groups.append((category.name, entries))
        categorized.formUnion(entries.map(\.id))
      }
    }
    let rest = document.lorebook.entries.filter { !categorized.contains($0.id) }
    if !rest.isEmpty { groups.append(("未分类", rest)) }
    return groups
  }

  var body: some View {
    NavigationStack {
      Group {
        if draft != nil {
          draftForm
        } else {
          entryPicker
        }
      }
      .navigationTitle(draft == nil ? "从世界书提取" : "确认角色档案")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消") { dismiss() }
        }
      }
    }
    #if os(macOS)
      .frame(minWidth: 560, minHeight: 520)
    #endif
  }

  // MARK: - 第一步：选世界书与条目

  private var entryPicker: some View {
    List {
      Section("来源世界") {
        Picker("选择世界书", selection: $sourceID) {
          Text("请选择").tag(UUID?.none)
          ForEach(storyworldModel.records) { record in
            Text("\(record.manifest.title)（\(record.lorebookEntryCount) 条）")
              .tag(UUID?.some(record.id))
          }
        }
      }
      if model.isWorking {
        Section {
          HStack {
            ProgressView()
            Text("模型正在整理角色档案…")
              .foregroundStyle(.secondary)
          }
        }
      } else if let document = sourceDocument {
        ForEach(groupedEntries, id: \.title) { group in
          Section(group.title) {
            ForEach(group.entries) { entry in
              Button {
                startExtraction(entry: entry)
              } label: {
                VStack(alignment: .leading, spacing: 2) {
                  Text(entry.title)
                    .font(.subheadline.weight(.medium))
                  Text(preview(of: entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
              }
              .disabled(entry.content.trimmingCharacters(in: .whitespacesAndNewlines).count < 10)
          }
          }
        }
        if document.lorebook.entries.isEmpty {
          Section {
            Text("这个世界书还没有条目。")
              .foregroundStyle(.secondary)
          }
        }
      } else if sourceID != nil {
        Section {
          ProgressView("正在读取条目…")
        }
      }
    }
    .onChange(of: sourceID) { _, newValue in
      sourceDocument = nil
      guard let newValue else { return }
      Task { sourceDocument = await storyworldModel.loadDocument(newValue) }
    }
  }

  private func startExtraction(entry: LoreEntry) {
    guard !didStartExtraction else { return }
    didStartExtraction = true
    Task {
      let result = await model.extractDraft(
        entryTitle: entry.title,
        entryContent: entry.content,
        sourceTitle: sourceTitle,
        storyworldID: sourceID,
        entryID: entry.id
      )
      if let result {
        draft = result
        tagsText = result.tags.joined(separator: "，")
      }
      didStartExtraction = false
    }
  }

  // MARK: - 第二步：预览编辑草稿

  private var draftForm: some View {
    Form {
      if var value = draft {
        Section("基本") {
          TextField("角色姓名", text: binding(\.name))
          TextField("一句话简介", text: binding(\.summary))
          TextField("分类", text: binding(\.category), prompt: Text("例如：主角、配角、反派"))
          TextField("标签（逗号分隔）", text: $tagsText)
        }
        Section("设定") {
          editor("外貌", text: binding(\.appearance))
          editor("性格", text: binding(\.personality))
          editor("语言风格", text: binding(\.speechStyle))
          editor("背景经历", text: binding(\.background))
          editor("能力身份", text: binding(\.abilities))
          editor("备注", text: binding(\.notes))
        }
        Section("生成提示词（供生图模型）") {
          editor("视觉描述", text: binding(\.promptProfile))
        }
        Section {
          Button {
            value.tags = parsedTags
            Task {
              await model.importExtractedDraft(value)
              if model.errorMessage == nil { dismiss() }
            }
          } label: {
            Label("加入角色库", systemImage: "checkmark.circle.fill")
          }
          .disabled(
            model.isWorking
              || value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          )
          Button("返回重选") {
            draft = nil
          }
          .disabled(model.isWorking)
        }
      }
    }
    .disabled(model.isWorking)
  }

  private var parsedTags: [String] {
    tagsText
      .components(separatedBy: CharacterSet(charactersIn: ",，、;；"))
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private func binding(_ keyPath: WritableKeyPath<CharacterExtractionDraft, String>)
    -> Binding<String>
  {
    Binding(
      get: { draft?[keyPath: keyPath] ?? "" },
      set: { draft?[keyPath: keyPath] = $0 }
    )
  }

  /// 列表摘要：取前两行非空内容
  private func preview(of entry: LoreEntry) -> String {
    entry.content
      .components(separatedBy: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .prefix(2)
      .joined(separator: " ")
  }

  private func editor(_ label: String, text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      TextEditor(text: text)
        .frame(minHeight: 52)
    }
  }
}

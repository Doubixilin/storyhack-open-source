import LibraryCore
import StoryworldCore
import SwiftUI

private struct VisualWorkspaceSelection: Identifiable {
  let id: UUID
  let title: String
}

/// 条目 sheet 的目标世界（包一层以提供 Identifiable）
private struct EntrySheetTarget: Identifiable {
  let id: UUID
}

private extension LoreEntry {
  /// 去掉 Markdown 块级标记（标题 #、引用 >、分隔线）及与标题重复的首行后的正文
  var cleanedContent: String {
    var lines = content
      .components(separatedBy: "\n")
      .map { line in
        line
          .replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression)
          .replacingOccurrences(of: #"^>\s?"#, with: "", options: .regularExpression)
          .replacingOccurrences(of: #"^\s*[-*_]{3,}\s*$"#, with: "", options: .regularExpression)
          .replacingOccurrences(of: #"^\s*[-*+]\s+"#, with: "", options: .regularExpression)
      }
    if let first = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
      first.trimmingCharacters(in: .whitespaces) == title,
      let index = lines.firstIndex(of: first)
    {
      lines.remove(at: index)
    }
    return lines.joined(separator: "\n")
  }

  /// 条目正文：行内语法（加粗等）正常渲染
  var displayContent: AttributedString {
    let cleaned = cleanedContent
    return (try? AttributedString(
      markdown: cleaned,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(cleaned)
  }

  /// 列表摘要：取前两行非空内容
  var summary: String {
    cleanedContent
      .components(separatedBy: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .prefix(2)
      .joined(separator: " ")
  }
}

// MARK: - 条目详情

/// 设定条目完整内容页：compact 下由 NavigationStack push，宽屏下页内替换
private struct LoreEntryDetailView: View {
  let entry: LoreEntry
  var onBack: (() -> Void)? = nil
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let onBack {
          Button(action: onBack) {
            Label("全部条目", systemImage: "chevron.left")
              .font(.subheadline.weight(.medium))
          }
          .buttonStyle(WBChromeButtonStyle())
        }

        VStack(alignment: .leading, spacing: 9) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.title)
              .font(.system(.title2, design: .serif, weight: .bold))
            if entry.alwaysActive {
              Text("常驻")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.wbGold)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.wbGold.opacity(0.12), in: Capsule())
            }
            if !entry.enabled {
              Text("停用")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: Capsule())
            }
          }
          if !entry.activationKeys.isEmpty {
            HStack(spacing: 6) {
              Image(systemName: "bolt.fill")
                .font(.caption2)
              Text(entry.activationKeys.joined(separator: " · "))
            }
            .font(.caption)
            .foregroundStyle(Color.wbViolet)
          }
        }

        Rectangle()
          .fill(Color.primary.opacity(0.08))
          .frame(height: 0.5)

        Text(entry.displayContent)
          .font(.system(.body, design: .serif))
          .lineSpacing(5)
          .foregroundStyle(.primary.opacity(0.85))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, horizontalSizeClass == .compact ? 20 : 30)
      .padding(.vertical, 18)
      .frame(maxWidth: 760)
      .frame(maxWidth: .infinity)
    }
    .background { WBAmbientScenery() }
    .navigationTitle(entry.title)
    .modify { view in
      #if os(iOS)
        view.navigationBarTitleDisplayMode(.inline)
      #else
        view
      #endif
    }
  }
}

struct StoryworldOverviewView: View {
  /// 生图工作区仍处于实验阶段，完成验证后再开放入口。
  private static let visualAssetsEntryEnabled = false

  let novel: NovelLibraryRecord?
  @ObservedObject var model: StoryworldViewModel
  let startPlay: ((UUID) -> Void)?
  @State private var visualWorkspace: VisualWorkspaceSelection?
  @State private var deletionCandidate: StoryworldDocument?
  @State private var entrySearchText = ""
  @State private var selectedEntry: LoreEntry?
  @State private var isCreatingStoryworld = false
  @State private var entryImportTarget: EntrySheetTarget?
  @State private var entryCreateTarget: EntrySheetTarget?
  @State private var contractTarget: EntrySheetTarget?
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  private var isCompact: Bool {
    horizontalSizeClass == .compact
  }

  private var visibleRecords: [StoryworldLibraryRecord] {
    if let novel {
      return model.associatedRecords(for: novel)
    }
    return model.records
  }

  var body: some View {
    ZStack {
      WBAmbientScenery()
      if visibleRecords.isEmpty {
        VStack(spacing: 18) {
          WBEmptyStateView(
            title: novel == nil ? "还没有世界书" : "这本小说尚未关联世界书",
            symbol: "globe.asia.australia.fill",
            message: novel == nil
              ? "从书架导入 Lorebook 或 Storyworld，或直接新建一个空白世界。"
              : "回到书架右键小说，导入或关联一个已有世界书。",
            gradient: LinearGradient(
              colors: [.wbViolet, .wbIndigo],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
          if novel == nil {
            Button {
              isCreatingStoryworld = true
            } label: {
              Label("新建空白世界", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(.wbViolet)
          }
        }
      } else if let document = selectedVisibleDocument {
        storyworldDetail(document)
      } else {
        storyworldChooser
      }
    }
    .task(id: visibleRecords.map(\.id)) {
      if visibleRecords.count == 1,
        let only = visibleRecords.first,
        model.selectedStoryworldID != only.id
      {
        await model.selectStoryworld(only.id)
      }
    }
    .sheet(item: $visualWorkspace) { selection in
      VisualAssetWorkspaceView(storyworldID: selection.id, title: selection.title)
    }
    .sheet(isPresented: $isCreatingStoryworld) {
      StoryworldCreateSheet(model: model)
    }
    .sheet(item: $entryImportTarget) { target in
      EntryImportSheet(model: model, targetID: target.id)
    }
    .sheet(item: $entryCreateTarget) { target in
      EntryCreateSheet(model: model, storyworldID: target.id)
    }
    .sheet(item: $contractTarget) { target in
      StoryworldCharacterContractsView(model: model, storyworldID: target.id)
    }
    .confirmationDialog(
      "删除世界书",
      isPresented: Binding(
        get: { deletionCandidate != nil },
        set: { if !$0 { deletionCandidate = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("删除", role: .destructive) {
        if let target = deletionCandidate {
          Task { await model.deleteStoryworld(target.manifest.storyworldID) }
        }
        deletionCandidate = nil
      }
      Button("取消", role: .cancel) { deletionCandidate = nil }
    } message: {
      if let target = deletionCandidate {
        Text(
          "「\(target.manifest.title)」将从列表移除；设定与游玩数据会移入备份目录，可通过重新导入恢复。"
        )
      }
    }
  }

  private var selectedVisibleDocument: StoryworldDocument? {
    guard let selectedID = model.selectedStoryworldID,
      visibleRecords.contains(where: { $0.id == selectedID }),
      model.selectedDocument?.manifest.storyworldID == selectedID
    else { return nil }
    return model.selectedDocument
  }

  /// 详情副标题：修订与条目数，有节拍线时追加节拍数
  private func detailSubtitle(_ document: StoryworldDocument) -> String {
    var text = "修订 \(document.manifest.revision) · \(document.lorebook.entries.count) 条设定"
    if model.isExtractingTimeline {
      text += " · 正在提取节拍线…"
    } else if let timeline = document.timeline {
      text += " · 原著线 \(timeline.beats.count) 节拍"
    }
    return text
  }

  private var storyworldChooser: some View {
    VStack(alignment: .leading, spacing: 24) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 5) {
          Text(novel.map { "《\($0.document.title)》的世界" } ?? "故事世界")
            .font(.system(isCompact ? .title : .largeTitle, design: .serif, weight: .bold))
          Text("选择一个世界书查看设定并开始独立游玩。")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if novel == nil {
          Button {
            isCreatingStoryworld = true
          } label: {
            Label("新建世界", systemImage: "plus")
          }
          .buttonStyle(.bordered)
        }
      }

      ScrollView {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 18)],
          spacing: 18
        ) {
          ForEach(visibleRecords) { record in
            Button {
              Task { await model.selectStoryworld(record.id) }
            } label: {
              storyworldCard(record)
            }
            .buttonStyle(WBPressableButtonStyle())
          }
        }
      }
    }
    .padding(isCompact ? 18 : 34)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func storyworldCard(_ record: StoryworldLibraryRecord) -> some View {
    VStack(alignment: .leading, spacing: 13) {
      HStack {
        Image(systemName: "globe.asia.australia.fill")
          .font(.title2)
          .foregroundStyle(Color.wbViolet)
        Spacer()
        Text("v\(record.manifest.revision)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Text(record.manifest.title)
        .font(.system(.title3, design: .serif, weight: .semibold))
        .foregroundStyle(.primary)
        .lineLimit(2)
      Text("\(record.lorebookEntryCount) 条设定")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .padding(20)
    .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
    .wbGlassPanel(cornerRadius: 18, shadowOpacity: 0.08)
  }

  private func storyworldDetail(_ document: StoryworldDocument) -> some View {
    VStack(spacing: 0) {
      if isCompact {
        compactDetailHeader(document)
      } else {
        wideDetailHeader(document)
      }

      Divider()

      if !isCompact, let selectedEntry {
        // 宽屏：页内替换为条目详情
        LoreEntryDetailView(entry: selectedEntry) {
          self.selectedEntry = nil
        }
      } else {
        entryBrowser(document)
      }
    }
    .modify { view in
      if isCompact {
        view.navigationDestination(
          isPresented: Binding(
            get: { selectedEntry != nil },
            set: { if !$0 { selectedEntry = nil } }
          )
        ) {
          if let selectedEntry {
            LoreEntryDetailView(entry: selectedEntry)
          }
        }
      } else {
        view
      }
    }
  }

  /// 条目浏览器：搜索 + 按分类分组的条目列表
  private func entryBrowser(_ document: StoryworldDocument) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .font(.caption)
          .foregroundStyle(.secondary)
        TextField("搜索设定标题、关键词或内容", text: $entrySearchText)
          .textFieldStyle(.plain)
        if !entrySearchText.isEmpty {
          Button {
            entrySearchText = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .transition(.opacity.combined(with: .scale(scale: 0.6)))
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
      .background(Color.primary.opacity(0.05), in: Capsule())
      .padding(.horizontal, isCompact ? 16 : 30)
      .padding(.vertical, 10)
      .animation(WBMotion.snappy, value: entrySearchText.isEmpty)

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 18) {
          let groups = entryGroups(of: document)
          if groups.isEmpty {
            Text("没有匹配的设定条目")
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity)
              .padding(.top, 40)
          } else {
            ForEach(groups) { group in
              VStack(alignment: .leading, spacing: 10) {
                if let title = group.title {
                  HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(title)
                      .font(.system(.title3, design: .serif, weight: .semibold))
                    Text("\(group.entries.count)")
                      .font(.caption.monospacedDigit())
                      .foregroundStyle(.secondary)
                  }
                }
                ForEach(group.entries) { entry in
                  entryRow(entry)
                }
              }
            }
          }
        }
        .padding(.horizontal, isCompact ? 16 : 30)
        .padding(.bottom, isCompact ? 16 : 30)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
      }
    }
  }

  /// 条目行：标题 + 状态 + 摘要 + 触发关键词，点按进入完整内容
  private func entryRow(_ entry: LoreEntry) -> some View {
    Button {
      selectedEntry = entry
    } label: {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 5) {
          HStack(spacing: 7) {
            Text(entry.title)
              .font(.system(.headline, design: .serif))
              .foregroundStyle(.primary)
              .lineLimit(1)
            if entry.alwaysActive {
              Text("常驻")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.wbGold)
            }
            if !entry.enabled {
              Text("停用")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            }
          }
          if !entry.summary.isEmpty {
            Text(entry.summary)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(2)
              .multilineTextAlignment(.leading)
          }
          if !entry.activationKeys.isEmpty {
            Text(entry.activationKeys.joined(separator: " · "))
              .font(.caption)
              .foregroundStyle(Color.wbViolet)
              .lineLimit(1)
          }
        }
        Spacer(minLength: 6)
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      .wbGlassPanel(cornerRadius: 14, shadowOpacity: 0.04)
      .contentShape(Rectangle())
    }
    .buttonStyle(WBPressableButtonStyle())
    .accessibilityLabel("查看设定：\(entry.title)")
  }

  private struct EntryGroup: Identifiable {
    let title: String?
    let entries: [LoreEntry]

    var id: String { title ?? "__flat__" }
  }

  /// 搜索过滤 + 分类分组；搜索时平铺结果
  private func entryGroups(of document: StoryworldDocument) -> [EntryGroup] {
    let query = entrySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !query.isEmpty {
      let matched = document.lorebook.entries.filter { entry in
        entry.title.localizedCaseInsensitiveContains(query)
          || entry.content.localizedCaseInsensitiveContains(query)
          || entry.activationKeys.contains { $0.localizedCaseInsensitiveContains(query) }
      }
      return matched.isEmpty ? [] : [EntryGroup(title: nil, entries: matched)]
    }

    let entries = document.lorebook.entries
    var groups: [EntryGroup] = []
    var categorizedIDs = Set<String>()
    for category in document.lorebook.categories {
      let group = entries.filter { $0.categoryID == category.id }
      if !group.isEmpty {
        groups.append(EntryGroup(title: category.name, entries: group))
        categorizedIDs.formUnion(group.map(\.id))
      }
    }
    let rest = entries.filter { !categorizedIDs.contains($0.id) }
    if !rest.isEmpty {
      groups.append(EntryGroup(title: groups.isEmpty ? nil : "未分类", entries: rest))
    }
    return groups
  }

  /// 宽屏头部：返回 + 标题 + 全部操作按钮横排
  private func wideDetailHeader(_ document: StoryworldDocument) -> some View {
    HStack(spacing: 14) {
      Button {
        model.selectedStoryworldID = nil
      } label: {
        Label("全部世界", systemImage: "chevron.left")
      }
      .buttonStyle(.borderless)

      VStack(alignment: .leading, spacing: 2) {
        Text(document.manifest.title)
          .font(.system(.title2, design: .serif, weight: .bold))
        Text(detailSubtitle(document))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button {
        Task { await model.extractTimeline(storyworldID: document.manifest.storyworldID) }
      } label: {
        if model.isExtractingTimeline {
          Label("正在提取节拍线…", systemImage: "hourglass")
        } else {
          Label(
            document.timeline == nil ? "提取节拍线" : "重新提取节拍线",
            systemImage: "list.number"
          )
        }
      }
      .buttonStyle(.bordered)
      .disabled(model.isExtractingTimeline)
      // R18：1.0 隐藏视觉资产入口，生图 MVP 落地后翻回 true
      if Self.visualAssetsEntryEnabled {
        Button {
          visualWorkspace = VisualWorkspaceSelection(
            id: document.manifest.storyworldID,
            title: document.manifest.title
          )
        } label: {
          Label("视觉资产", systemImage: "photo.on.rectangle.angled")
        }
        .buttonStyle(.bordered)
      }
      Menu {
        Button("角色契约") {
          contractTarget = EntrySheetTarget(id: document.manifest.storyworldID)
        }
        Button {
          entryCreateTarget = EntrySheetTarget(id: document.manifest.storyworldID)
        } label: {
          Label("新建条目（世界基底等）", systemImage: "plus.square")
        }
        Button {
          entryImportTarget = EntrySheetTarget(id: document.manifest.storyworldID)
        } label: {
          Label("从其他世界导入条目…", systemImage: "square.and.arrow.down.on.square")
        }
      } label: {
        Label("条目", systemImage: "text.append")
      }
      .buttonStyle(.bordered)
      Button {
        Task { await model.prepareExport(storyworldID: document.manifest.storyworldID) }
      } label: {
        Label("导出", systemImage: "square.and.arrow.up")
      }
      .buttonStyle(.bordered)
      Button(role: .destructive) {
        deletionCandidate = document
      } label: {
        Label("删除", systemImage: "trash")
      }
      .buttonStyle(.bordered)
      if let startPlay {
        Button {
          startPlay(document.manifest.storyworldID)
        } label: {
          Label("开始游玩", systemImage: "play.fill")
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(.horizontal, 30)
    .padding(.vertical, 20)
  }

  /// 窄屏头部：返回 + 标题一行，次要操作收进菜单，主操作全宽渐变按钮
  private func compactDetailHeader(_ document: StoryworldDocument) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        Button {
          model.selectedStoryworldID = nil
        } label: {
          Image(systemName: "chevron.left")
            .font(.subheadline.weight(.semibold))
            .frame(width: 30, height: 30)
            .background(Color.primary.opacity(0.05), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("返回全部世界")

        VStack(alignment: .leading, spacing: 2) {
          Text(document.manifest.title)
            .font(.system(.headline, design: .serif, weight: .bold))
            .lineLimit(1)
          Text(detailSubtitle(document))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        Spacer(minLength: 6)

        Menu {
          Button("角色契约") {
            contractTarget = EntrySheetTarget(id: document.manifest.storyworldID)
          }
          Button {
            entryCreateTarget = EntrySheetTarget(id: document.manifest.storyworldID)
          } label: {
            Label("新建条目（世界基底等）", systemImage: "plus.square")
          }
          Button {
            entryImportTarget = EntrySheetTarget(id: document.manifest.storyworldID)
          } label: {
            Label("从其他世界导入条目…", systemImage: "square.and.arrow.down.on.square")
          }
          Divider()
          Button {
            Task { await model.extractTimeline(storyworldID: document.manifest.storyworldID) }
          } label: {
            Label(
              document.timeline == nil ? "提取节拍线" : "重新提取节拍线",
              systemImage: "list.number"
            )
          }
          .disabled(model.isExtractingTimeline)
          if Self.visualAssetsEntryEnabled {
            Button {
              visualWorkspace = VisualWorkspaceSelection(
                id: document.manifest.storyworldID,
                title: document.manifest.title
              )
            } label: {
              Label("视觉资产", systemImage: "photo.on.rectangle.angled")
            }
          }
          Button {
            Task { await model.prepareExport(storyworldID: document.manifest.storyworldID) }
          } label: {
            Label("导出", systemImage: "square.and.arrow.up")
          }
          Button(role: .destructive) {
            deletionCandidate = document
          } label: {
            Label("删除", systemImage: "trash")
          }
        } label: {
          Image(systemName: "ellipsis")
            .font(.subheadline.weight(.medium))
            .frame(width: 30, height: 30)
            .background(Color.primary.opacity(0.05), in: Circle())
        }
        .accessibilityLabel("更多操作")
      }

      if let startPlay {
        Button {
          startPlay(document.manifest.storyworldID)
        } label: {
          Label("开始游玩", systemImage: "play.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.wbOnAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background {
              Capsule()
                .fill(LinearGradient.wbBrand)
                .shadow(color: Color.wbIndigo.opacity(0.3), radius: 8, y: 4)
            }
        }
        .buttonStyle(WBPressableButtonStyle())
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }
}

// MARK: - 素材库：新建世界 / 导入条目 / 新建条目

/// 新建空白世界书
private struct StoryworldCreateSheet: View {
  @ObservedObject var model: StoryworldViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var title = ""

  var body: some View {
    NavigationStack {
      Form {
        TextField("世界名称", text: $title)
        Text("创建一个空白世界，之后可以从其他世界勾选角色与设定导入。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .navigationTitle("新建世界")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("创建") {
            let value = title
            Task {
              await model.createEmptyStoryworld(title: value)
              dismiss()
            }
          }
          .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
    #if os(macOS)
      .frame(minWidth: 380, minHeight: 160)
    #endif
  }
}

/// 从其他世界勾选条目导入：深拷贝，条目 ID 重新生成，分类按名称合并
private struct EntryImportSheet: View {
  @ObservedObject var model: StoryworldViewModel
  let targetID: UUID
  @Environment(\.dismiss) private var dismiss
  @State private var sourceID: UUID?
  @State private var sourceDocument: StoryworldDocument?
  @State private var selectedIDs: Set<String> = []
  @State private var isImporting = false

  private var sources: [StoryworldLibraryRecord] {
    model.records.filter { $0.id != targetID }
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
      List {
        Section("来源世界") {
          Picker("选择世界书", selection: $sourceID) {
            Text("请选择").tag(UUID?.none)
            ForEach(sources) { record in
              Text("\(record.manifest.title)（\(record.lorebookEntryCount) 条）")
                .tag(UUID?.some(record.id))
            }
          }
        }
        if let document = sourceDocument {
          Section {
            HStack {
              Text("已选 \(selectedIDs.count) / \(document.lorebook.entries.count) 条")
                .font(.caption)
                .foregroundStyle(.secondary)
              Spacer()
              Button("全选") {
                selectedIDs = Set(document.lorebook.entries.map(\.id))
              }
              .font(.caption)
              Button("清空") { selectedIDs.removeAll() }
                .font(.caption)
            }
          }
          ForEach(groupedEntries, id: \.title) { group in
            Section(group.title) {
              ForEach(group.entries) { entry in
                Toggle(isOn: binding(for: entry.id)) {
                  VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                      .font(.subheadline.weight(.medium))
                    Text(entry.summary)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .lineLimit(2)
                  }
                }
              }
            }
          }
        } else if sourceID != nil {
          Section {
            ProgressView("正在读取条目…")
          }
        }
      }
      .navigationTitle("导入条目")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(isImporting ? "导入中…" : "导入 \(selectedIDs.count) 条") {
            guard let sourceID else { return }
            isImporting = true
            Task {
              await model.importEntries(
                from: sourceID,
                entryIDs: selectedIDs,
                into: targetID
              )
              dismiss()
            }
          }
          .disabled(selectedIDs.isEmpty || isImporting)
        }
      }
      .onChange(of: sourceID) { _, newValue in
        selectedIDs.removeAll()
        sourceDocument = nil
        guard let newValue else { return }
        Task { sourceDocument = await model.loadDocument(newValue) }
      }
    }
    #if os(macOS)
      .frame(minWidth: 460, minHeight: 420)
    #endif
  }

  private func binding(for entryID: String) -> Binding<Bool> {
    Binding(
      get: { selectedIDs.contains(entryID) },
      set: { checked in
        if checked { selectedIDs.insert(entryID) } else { selectedIDs.remove(entryID) }
      }
    )
  }
}

/// 手工新建条目（世界基底等）
private struct EntryCreateSheet: View {
  @ObservedObject var model: StoryworldViewModel
  let storyworldID: UUID
  @Environment(\.dismiss) private var dismiss
  @State private var title = ""
  @State private var categoryName = ""
  @State private var activationKeysText = ""
  @State private var alwaysActive = false
  @State private var content = ""
  @State private var isSaving = false

  private var canSave: Bool {
    !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("条目") {
          TextField("标题（如：世界基底）", text: $title)
          TextField("分类（可选，如：世界基底、人物）", text: $categoryName)
          TextField("激活词（逗号分隔，可选）", text: $activationKeysText)
          Toggle("常驻激活（每轮都注入，适合世界基底）", isOn: $alwaysActive)
        }
        Section("正文") {
          TextEditor(text: $content)
            .frame(minHeight: 160)
        }
        Text("融合世界建议先写一条「世界基底」：这是什么世界、各角色为何同处一个时空、力量体系如何对标。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .navigationTitle("新建条目")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("保存") {
            isSaving = true
            let keys = activationKeysText
              .components(separatedBy: CharacterSet(charactersIn: ",，、;；"))
              .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
              .filter { !$0.isEmpty }
            let category = categoryName.trimmingCharacters(in: .whitespacesAndNewlines)
            Task {
              await model.addEntry(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                content: content,
                categoryName: category.isEmpty ? nil : category,
                activationKeys: keys,
                alwaysActive: alwaysActive,
                storyworldID: storyworldID
              )
              dismiss()
            }
          }
          .disabled(!canSave || isSaving)
        }
      }
    }
    #if os(macOS)
      .frame(minWidth: 460, minHeight: 420)
    #endif
  }
}

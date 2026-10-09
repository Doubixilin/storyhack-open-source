import LibraryCore
import NovelDocumentCore
import StoryworldCore
import SwiftUI

// MARK: - 书架

/// 书架显示方式
enum ShelfViewMode: String, CaseIterable, Identifiable {
  case grid
  case list

  var id: Self { self }

  var title: String {
    switch self {
    case .grid: "封面网格"
    case .list: "列表"
    }
  }

  var symbol: String {
    switch self {
    case .grid: "square.grid.2x2"
    case .list: "list.bullet"
    }
  }
}

/// 书架分组方式
enum ShelfGrouping: String, CaseIterable, Identifiable {
  case none
  case readingStatus
  case author
  case format

  var id: Self { self }

  var title: String {
    switch self {
    case .none: "不分组"
    case .readingStatus: "按阅读状态"
    case .author: "按作者"
    case .format: "按格式"
    }
  }
}

struct ShelfSection: Identifiable {
  let title: String?
  let records: [NovelLibraryRecord]

  var id: String { title ?? "__all__" }
}

struct LibraryBookshelfView: View {
  let records: [NovelLibraryRecord]
  @Binding var searchText: String
  let platform: WorldbookAppPlatform
  let storyworlds: [StoryworldLibraryRecord]
  let associatedStoryworlds: (NovelLibraryRecord) -> [StoryworldLibraryRecord]
  let openBook: (NovelLibraryRecord) -> Void
  let enterStoryworld: (NovelLibraryRecord) -> Void
  let importStoryworld: (NovelLibraryRecord) -> Void
  let associateExistingStoryworld: (NovelLibraryRecord, StoryworldLibraryRecord) -> Void
  let generateWorldbook: (NovelLibraryRecord) -> Void
  let deleteBook: (NovelLibraryRecord) -> Void

  @FocusState private var isSearchFocused: Bool
  @AppStorage("storyhack.community.shelf_view_mode") private var viewMode: ShelfViewMode = .grid
  @AppStorage("storyhack.community.shelf_grouping") private var grouping: ShelfGrouping = .none
  @State private var recordPendingDeletion: NovelLibraryRecord?

  private var visibleRecords: [NovelLibraryRecord] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return records }
    return records.filter { record in
      record.document.title.localizedCaseInsensitiveContains(query)
        || (record.document.author?.localizedCaseInsensitiveContains(query) ?? false)
    }
  }

  private var readingCount: Int {
    records.filter { ($0.readerState.currentLocator?.locations.totalProgression ?? 0) > 0 }.count
  }

  /// 分组后的书架区段
  private var sections: [ShelfSection] {
    switch grouping {
    case .none:
      return [ShelfSection(title: nil, records: visibleRecords)]
    case .readingStatus:
      let buckets: [(String, (Double) -> Bool)] = [
        ("在读", { $0 > 0 && $0 < 0.995 }),
        ("未开始", { $0 <= 0 }),
        ("已读完", { $0 >= 0.995 }),
      ]
      return buckets.compactMap { title, match in
        let group = visibleRecords.filter {
          match($0.readerState.currentLocator?.locations.totalProgression ?? 0)
        }
        return group.isEmpty ? nil : ShelfSection(title: title, records: group)
      }
    case .author:
      let grouped = Dictionary(grouping: visibleRecords) { $0.document.author ?? "未知作者" }
      return grouped.keys.sorted(by: { $0.localizedCompare($1) == .orderedAscending })
        .map { ShelfSection(title: $0, records: grouped[$0] ?? []) }
    case .format:
      let grouped = Dictionary(grouping: visibleRecords) {
        $0.document.sourceFormat.rawValue.uppercased()
      }
      return grouped.keys.sorted().map { ShelfSection(title: $0, records: grouped[$0] ?? []) }
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      if platform == .macOS {
        header
      }

      if records.isEmpty {
        WBEmptyStateView(
          title: "书架还是空的",
          symbol: "books.vertical.fill",
          message: "导入 TXT、Markdown 或无 DRM EPUB 后即可开始阅读。"
        )
      } else if visibleRecords.isEmpty {
        ContentUnavailableView.search(text: searchText)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: platform == .iOS ? 22 : 26) {
            if platform == .iOS {
              iosLeadSection
            }
            ForEach(sections) { section in
              VStack(alignment: .leading, spacing: 14) {
                if let title = section.title {
                  sectionHeader(title: title, count: section.records.count)
                }
                shelfContent(for: section.records)
              }
            }
          }
          .padding(.horizontal, platform == .iOS ? 18 : 34)
          .padding(.top, 4)
          .padding(.bottom, 44)
        }
      }
    }
    .background { WBAmbientScenery() }
    .navigationTitle("书架")
    .modify { view in
      if platform == .iOS {
        view
          .searchable(text: $searchText, prompt: "搜索书名或作者")
          .toolbar {
            ToolbarItem(placement: .primaryAction) {
              displayOptionsMenu
            }
          }
      } else {
        view
      }
    }
    .confirmationDialog(
      "删除这本书？",
      isPresented: Binding(
        get: { recordPendingDeletion != nil },
        set: { if !$0 { recordPendingDeletion = nil } }
      ),
      titleVisibility: .visible
    ) {
      if let record = recordPendingDeletion {
        Button("删除《\(record.document.title)》", role: .destructive) {
          deleteBook(record)
        }
      }
      Button("取消", role: .cancel) {}
    } message: {
      if let record = recordPendingDeletion {
        Text(deletionMessage(for: record))
      }
    }
  }

  /// 删除确认弹窗的说明文案
  private func deletionMessage(for record: NovelLibraryRecord) -> String {
    let count = associatedStoryworlds(record).count
    if count > 0 {
      return "本书的本地数据（含阅读进度）将被移除，不可撤销；关联的 \(count) 个世界书不受影响。"
    }
    return "本书的本地数据（含阅读进度）将被移除，不可撤销。"
  }

  /// 分组区段标题：书名 + 数量
  private func sectionHeader(title: String, count: Int) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 7) {
      Text(title)
        .font(.system(.title3, design: .serif, weight: .semibold))
      Text("\(count)")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
  }

  /// 网格或列表渲染一组书
  @ViewBuilder
  private func shelfContent(for records: [NovelLibraryRecord]) -> some View {
    switch viewMode {
    case .grid:
      LazyVGrid(
        columns: gridColumns,
        alignment: .leading,
        spacing: platform == .iOS ? 18 : 34
      ) {
        ForEach(records) { record in
          LibraryBookCard(
            record: record,
            storyworldCount: associatedStoryworlds(record).count,
            compact: platform == .iOS
          ) {
            openBook(record)
          }
          .contextMenu { bookContextMenu(for: record) }
        }
      }
    case .list:
      LazyVStack(spacing: 10) {
        ForEach(records) { record in
          BookListRow(
            record: record,
            storyworldCount: associatedStoryworlds(record).count
          ) {
            openBook(record)
          }
          .contextMenu { bookContextMenu(for: record) }
        }
      }
    }
  }

  @ViewBuilder
  private func bookContextMenu(for record: NovelLibraryRecord) -> some View {
    Button("打开阅读") { openBook(record) }
    let associatedIDs = Set(associatedStoryworlds(record).map(\.id))
    if !associatedIDs.isEmpty {
      Button("进入世界（\(associatedIDs.count)）") {
        enterStoryworld(record)
      }
    }
    Divider()
    Button("导入并关联世界书…") { importStoryworld(record) }
    Menu("关联已有世界书") {
      let candidates = storyworlds.filter { !associatedIDs.contains($0.id) }
      if candidates.isEmpty {
        Text("没有可关联的世界书")
      } else {
        ForEach(candidates) { storyworld in
          Button(storyworld.manifest.title) {
            associateExistingStoryworld(record, storyworld)
          }
        }
      }
    }
    Divider()
    Button("生成世界书") { generateWorldbook(record) }
    Divider()
    Button("删除…", role: .destructive) {
      recordPendingDeletion = record
    }
  }

  /// 显示方式与分组菜单
  private var displayOptionsMenu: some View {
    Menu {
      Picker("显示方式", selection: $viewMode) {
        ForEach(ShelfViewMode.allCases) { mode in
          Label(mode.title, systemImage: mode.symbol).tag(mode)
        }
      }
      Picker("分组", selection: $grouping) {
        ForEach(ShelfGrouping.allCases) { option in
          Text(option.title).tag(option)
        }
      }
    } label: {
      Label("显示选项", systemImage: "line.3.horizontal.decrease")
        .labelStyle(.iconOnly)
    }
    .accessibilityLabel("显示方式与分组")
  }

  /// 最近在读且未读完的书，用于 iOS 顶部「继续阅读」横幅
  private var resumeRecord: NovelLibraryRecord? {
    records
      .filter {
        let progress = $0.readerState.currentLocator?.locations.totalProgression ?? 0
        return progress > 0 && progress < 0.995
      }
      .max { $0.readerState.updatedAt < $1.readerState.updatedAt }
  }

  /// iOS 引导区：继续阅读横幅 + 馆藏统计
  @ViewBuilder
  private var iosLeadSection: some View {
    VStack(alignment: .leading, spacing: 15) {
      if let resumeRecord {
        ContinueReadingBanner(record: resumeRecord) {
          openBook(resumeRecord)
        }
      }
      HStack(spacing: 6) {
        Label("\(records.count) 本", systemImage: "books.vertical")
        if readingCount > 0 {
          Text("·")
          Label("\(readingCount) 本在读", systemImage: "bookmark.fill")
        }
        Text("·")
        Text("进度自动保存")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .imageScale(.small)
    }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 16) {
      titleBlock
      Spacer()
      displayOptionsMenu
        .modify { menu in
          #if os(macOS)
            menu.menuStyle(.borderlessButton)
              .menuIndicator(.hidden)
              .frame(width: 30)
          #else
            menu
          #endif
        }
      searchField
    }
    .padding(.horizontal, 34)
    .padding(.top, 30)
    .padding(.bottom, 24)
  }

  private var titleBlock: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("我的书架")
        .font(.system(.largeTitle, design: .serif, weight: .bold))
      HStack(spacing: 6) {
        Label("\(records.count) 本", systemImage: "books.vertical")
        if readingCount > 0 {
          Text("·")
          Label("\(readingCount) 本在读", systemImage: "bookmark.fill")
        }
        Text("·")
        Text("进度自动保存")
      }
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .labelStyle(.titleAndIcon)
      .imageScale(.small)
    }
  }

  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField("搜索书名或作者", text: $searchText)
        .textFieldStyle(.plain)
        .focused($isSearchFocused)
      if !searchText.isEmpty {
        Button {
          searchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .transition(.opacity.combined(with: .scale(scale: 0.6)))
      }
    }
    .padding(.horizontal, 13)
    .padding(.vertical, 10)
    .frame(width: isSearchFocused ? 300 : 250)
    .wbGlassPanel(cornerRadius: 12, shadowOpacity: isSearchFocused ? 0.14 : 0.06)
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(Color.wbAccent.opacity(isSearchFocused ? 0.55 : 0), lineWidth: 1.2)
    }
    .animation(WBMotion.snappy, value: isSearchFocused)
    .animation(WBMotion.snappy, value: searchText.isEmpty)
  }

  private var gridColumns: [GridItem] {
    if platform == .iOS {
      return [GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 12)]
    }
    return [GridItem(.adaptive(minimum: 152, maximum: 192), spacing: 28)]
  }
}

// MARK: - 书籍卡片

private struct LibraryBookCard: View {
  let record: NovelLibraryRecord
  let storyworldCount: Int
  var compact: Bool = false
  let open: () -> Void
  @State private var isHovering = false

  private var progress: Double {
    record.readerState.currentLocator?.locations.totalProgression ?? 0
  }

  var body: some View {
    Button(action: open) {
      VStack(alignment: .leading, spacing: compact ? 8 : 11) {
        BookCoverView(record: record, progress: progress, isHovering: isHovering, compact: compact)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 4) {
          Text(record.document.title)
            .font(.system(compact ? .subheadline : .headline, design: .serif, weight: compact ? .medium : .regular))
            .underline(false)
            .strikethrough(false)
            .foregroundStyle(.primary)
            .lineLimit(2)
          if !compact {
            Text(record.document.author ?? "未知作者")
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          HStack(spacing: 5) {
            Text(record.document.sourceFormat.rawValue.uppercased())
              .padding(.horizontal, 5)
              .padding(.vertical, 1.5)
              .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
              .foregroundStyle(.secondary)
            Text("\(record.document.chapters.count) 章")
            if storyworldCount > 0 {
              Text("· \(storyworldCount) 个世界")
                .foregroundStyle(.secondary)
            }
            if progress > 0 {
              Spacer(minLength: 2)
              Text("\(Int((progress * 100).rounded()))%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
          }
          .font(.caption2.weight(.medium))
          .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 2)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(WBPressableButtonStyle())
    .scaleEffect(isHovering ? 1.025 : 1)
    .animation(WBMotion.snappy, value: isHovering)
    .onHover { isHovering = $0 }
    .accessibilityLabel("打开《\(record.document.title)》")
  }
}

// MARK: - 封面配色

private enum BookCoverPalette {
  static func colors(for contentHash: String) -> [Color] {
    let value = Int(contentHash.prefix(2), radix: 16) ?? 0
    let palettes: [[Color]] = [
      [Color(red: 0.10, green: 0.11, blue: 0.18), Color(red: 0.18, green: 0.20, blue: 0.28)],  // 深靛蓝
      [Color(red: 0.16, green: 0.11, blue: 0.09), Color(red: 0.26, green: 0.19, blue: 0.14)],  // 深棕
      [Color(red: 0.10, green: 0.14, blue: 0.11), Color(red: 0.18, green: 0.24, blue: 0.17)],  // 苔绿
      [Color(red: 0.12, green: 0.11, blue: 0.18), Color(red: 0.22, green: 0.19, blue: 0.28)],  // 暮靛
      [Color(red: 0.17, green: 0.13, blue: 0.07), Color(red: 0.28, green: 0.22, blue: 0.12)],  // 暖金棕
      [Color(red: 0.08, green: 0.14, blue: 0.15), Color(red: 0.15, green: 0.24, blue: 0.24)],  // 深青
      [Color(red: 0.17, green: 0.10, blue: 0.08), Color(red: 0.27, green: 0.17, blue: 0.13)],  // 赭棕
      [Color(red: 0.11, green: 0.13, blue: 0.16), Color(red: 0.20, green: 0.23, blue: 0.27)],  // 岩灰蓝
    ]
    return palettes[value % palettes.count]
  }
}

// MARK: - 迷你封面

private struct MiniBookCover: View {
  let record: NovelLibraryRecord

  var body: some View {
    ZStack {
      LinearGradient(
        colors: BookCoverPalette.colors(for: record.document.contentHash),
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      Image(systemName: "book.fill")
        .font(.system(size: 15))
        .foregroundStyle(.white.opacity(0.85))
    }
    .frame(width: 44, height: 62)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
    }
    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
  }
}

// MARK: - 列表行（列表模式）

private struct BookListRow: View {
  let record: NovelLibraryRecord
  let storyworldCount: Int
  let open: () -> Void

  private var progress: Double {
    record.readerState.currentLocator?.locations.totalProgression ?? 0
  }

  var body: some View {
    Button(action: open) {
      HStack(spacing: 12) {
        MiniBookCover(record: record)

        VStack(alignment: .leading, spacing: 4) {
          Text(record.document.title)
            .font(.system(.headline, design: .serif))
            .foregroundStyle(.primary)
            .lineLimit(1)
          HStack(spacing: 5) {
            Text(record.document.author ?? "未知作者")
            Text("·")
            Text("\(record.document.chapters.count) 章")
            if storyworldCount > 0 {
              Text("· \(storyworldCount) 个世界")
                .foregroundStyle(.secondary)
            }
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)

          if progress > 0 {
            HStack(spacing: 8) {
              Capsule()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 3)
                .overlay(alignment: .leading) {
                  GeometryReader { geometry in
                    Capsule()
                      .fill(LinearGradient.wbBrand)
                      .frame(width: geometry.size.width * progress)
                  }
                }
              Text("\(Int((progress * 100).rounded()))%")
                .font(.caption2.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize()
            }
            .padding(.top, 2)
          }
        }

        Spacer(minLength: 4)

        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .wbGlassPanel(cornerRadius: 16, shadowOpacity: 0.05)
    }
    .buttonStyle(WBPressableButtonStyle())
    .accessibilityLabel("打开《\(record.document.title)》")
  }
}

// MARK: - 继续阅读横幅（iOS）

private struct ContinueReadingBanner: View {
  let record: NovelLibraryRecord
  let open: () -> Void

  private var progress: Double {
    record.readerState.currentLocator?.locations.totalProgression ?? 0
  }

  private var currentChapterTitle: String? {
    guard let chapterID = record.readerState.currentChapterID else { return nil }
    return record.document.chapters.first { $0.id == chapterID }?.title
  }

  var body: some View {
    Button(action: open) {
      HStack(spacing: 13) {
        MiniBookCover(record: record)

        VStack(alignment: .leading, spacing: 4) {
          Text("继续阅读")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.wbAccent)
          Text(record.document.title)
            .font(.system(.headline, design: .serif))
            .foregroundStyle(.primary)
            .lineLimit(1)
          if let currentChapterTitle {
            Text(currentChapterTitle)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          HStack(spacing: 8) {
            Capsule()
              .fill(Color.primary.opacity(0.08))
              .frame(height: 3)
              .overlay(alignment: .leading) {
                GeometryReader { geometry in
                  Capsule()
                    .fill(LinearGradient.wbBrand)
                    .frame(width: geometry.size.width * progress)
                }
              }
            Text("\(Int((progress * 100).rounded()))%")
              .font(.caption2.monospacedDigit().weight(.medium))
              .foregroundStyle(.secondary)
              .fixedSize()
          }
          .padding(.top, 2)
        }

        Spacer(minLength: 4)

        Image(systemName: "play.circle.fill")
          .font(.system(size: 30))
          .foregroundStyle(Color.wbAccent.opacity(0.85))
          .symbolRenderingMode(.hierarchical)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      .wbGlassPanel(cornerRadius: 18, shadowOpacity: 0.08)
    }
    .buttonStyle(WBPressableButtonStyle())
    .accessibilityLabel("继续阅读《\(record.document.title)》")
  }
}

// MARK: - 生成的封面

private struct BookCoverView: View {
  let record: NovelLibraryRecord
  let progress: Double
  let isHovering: Bool
  var compact: Bool = false

  private var palette: [Color] {
    BookCoverPalette.colors(for: record.document.contentHash)
  }

  var body: some View {
    ZStack(alignment: .bottom) {
      // 底色渐变
      LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)

      // 顶部光泽
      LinearGradient(
        colors: [.white.opacity(0.10), .white.opacity(0)],
        startPoint: .top,
        endPoint: .center
      )

      // 书脊高光
      HStack(spacing: 0) {
        LinearGradient(
          colors: [.white.opacity(0.16), .white.opacity(0.03), .black.opacity(0.12)],
          startPoint: .leading,
          endPoint: .trailing
        )
        .frame(width: 9)
        Spacer()
      }

      // 悬停流光
      GeometryReader { geometry in
        Rectangle()
          .fill(
            LinearGradient(
              colors: [.white.opacity(0), .white.opacity(0.10), .white.opacity(0)],
              startPoint: .leading,
              endPoint: .trailing
            )
          )
          .frame(width: geometry.size.width * 0.55)
          .rotationEffect(.degrees(16))
          .offset(x: isHovering ? geometry.size.width * 1.1 : -geometry.size.width * 0.9)
          .animation(.easeInOut(duration: 0.65), value: isHovering)
      }

      // 底部压暗，托起文字
      LinearGradient(
        colors: [.black.opacity(0.34), .black.opacity(0)],
        startPoint: .bottom,
        endPoint: .center
      )

      VStack(spacing: 0) {
        Spacer(minLength: 0)

        VStack(spacing: compact ? 8 : 12) {
          Image(systemName: "book.closed.fill")
            .font(compact ? .callout : .title3)
            .foregroundStyle(.white.opacity(0.72))

          Text(record.document.title)
            .font(.system(compact ? .callout : .title3, design: .serif, weight: .semibold))
            .underline(false)
            .strikethrough(false)
            .foregroundStyle(.white)
            .lineLimit(3)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, compact ? 9 : 14)

          if !compact, let author = record.document.author {
            Text(author)
              .font(.caption)
              .foregroundStyle(.white.opacity(0.78))
              .lineLimit(1)
          }
        }

        Spacer(minLength: 0)

        if progress > 0 {
          VStack(spacing: 6) {
            Capsule()
              .fill(.white.opacity(0.28))
              .frame(height: 3)
              .overlay(alignment: .leading) {
                GeometryReader { geometry in
                  Capsule()
                    .fill(.white)
                    .shadow(color: .white.opacity(0.7), radius: 3)
                    .frame(width: geometry.size.width * progress)
                }
              }
            Text("已读 \(Int((progress * 100).rounded()))%")
              .font(.caption2.monospacedDigit().weight(.medium))
              .foregroundStyle(.white.opacity(0.88))
          }
          .padding(.horizontal, compact ? 9 : 13)
          .padding(.top, compact ? 10 : 14)
        }
      }
      .padding(.bottom, progress > 0 ? 11 : (compact ? 18 : 30))
    }
    .aspectRatio(0.68, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 11, style: .continuous)
        .stroke(.white.opacity(0.14), lineWidth: 0.5)
    }
    .shadow(
      color: palette[0].opacity(isHovering ? 0.25 : 0.16),
      radius: isHovering ? 20 : 9,
      y: isHovering ? 12 : 5
    )
    .animation(WBMotion.snappy, value: isHovering)
  }
}

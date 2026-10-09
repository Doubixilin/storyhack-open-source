import LibraryCore
import NovelDocumentCore
import SwiftUI

enum ReaderSidebarTab: String, CaseIterable, Identifiable {
  case contents = "目录"
  case bookmarks = "书签"

  var id: Self { self }
}

// MARK: - 目录 / 书签侧栏

struct ReaderNavigationSidebar: View {
  let record: NovelLibraryRecord
  let activeChapterID: String?
  let theme: ReaderTheme
  @Binding var selectedTab: ReaderSidebarTab
  let select: (String, Double) -> Void
  @State private var chapterSearchText = ""

  var body: some View {
    VStack(spacing: 0) {
      Picker("导航", selection: $selectedTab) {
        ForEach(ReaderSidebarTab.allCases) { tab in
          Text(tab.rawValue).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(12)

      Rectangle()
        .fill(theme.separatorColor)
        .frame(height: 0.5)

      switch selectedTab {
      case .contents:
        HStack(spacing: 6) {
          Image(systemName: "magnifyingglass")
            .font(.caption)
            .foregroundStyle(.secondary)
          TextField("筛选章节", text: $chapterSearchText)
            .textFieldStyle(.plain)
          if !chapterSearchText.isEmpty {
            Button {
              chapterSearchText = ""
            } label: {
              Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .transition(.opacity.combined(with: .scale(scale: 0.6)))
          }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(theme.fieldColor, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(10)
        .animation(WBMotion.snappy, value: chapterSearchText.isEmpty)

        ReaderChapterList(
          identity: ReaderChapterListIdentity(
            record: record,
            activeChapterID: activeChapterID,
            theme: theme,
            query: chapterSearchText
          ),
          chapters: record.document.chapters,
          select: select
        )
        .equatable()

      case .bookmarks:
        if record.readerState.bookmarks.isEmpty {
          WBEmptyStateView(
            title: "还没有书签",
            symbol: "bookmark",
            message: "阅读时点按工具栏中的书签按钮。"
          )
        } else {
          List(record.readerState.bookmarks) { bookmark in
            Button {
              select(bookmark.chapterID, bookmark.locator?.locations.progression ?? 0)
            } label: {
              HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                  .fill(theme.accentColor)
                  .frame(width: 3, height: 30)
                VStack(alignment: .leading, spacing: 3) {
                  Text(bookmark.title)
                    .font(.callout)
                    .lineLimit(2)
                  Text(bookmark.createdAt, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 12))
            .listRowSeparatorTint(theme.separatorColor)
          }
          .listStyle(.plain)
          .scrollContentBackground(.hidden)
        }
      }
    }
    .foregroundStyle(theme.foregroundColor)
    .background {
      Rectangle().fill(.bar)
      Rectangle().fill(theme.sidebarColor.opacity(theme == .system ? 0.0 : 0.72))
    }
  }
}

// MARK: - 目录列表

/// 目录只在书本内容、当前章节、主题或筛选词变化时重新展开。
/// 阅读进度等 `readerState` 高频更新不会改变该身份，避免反复构造整本目录。
struct ReaderChapterListIdentity: Equatable {
  let documentID: UUID
  let contentHash: String
  let activeChapterID: String?
  let theme: ReaderTheme
  let query: String

  init(
    record: NovelLibraryRecord,
    activeChapterID: String?,
    theme: ReaderTheme,
    query: String
  ) {
    documentID = record.document.id
    contentHash = record.document.contentHash
    self.activeChapterID = activeChapterID
    self.theme = theme
    self.query = query
  }
}

private struct ReaderChapterList: View, Equatable {
  let identity: ReaderChapterListIdentity
  let chapters: [NovelChapter]
  let select: (String, Double) -> Void

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.identity == rhs.identity
  }

  private var visibleChapters: [NovelChapter] {
    let query = identity.query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return chapters }
    return chapters.filter {
      $0.title.localizedCaseInsensitiveContains(query)
    }
  }

  var body: some View {
    ScrollViewReader { proxy in
      List(visibleChapters) { chapter in
        ChapterRow(
          chapterID: chapter.id,
          ordinal: chapter.ordinal,
          title: chapter.title,
          isActive: chapter.id == identity.activeChapterID,
          theme: identity.theme
        ) {
          select(chapter.id, 0)
        }
        .equatable()
        .id(chapter.id)
        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        .listRowBackground(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(
              chapter.id == identity.activeChapterID
                ? identity.theme.selectionColor : Color.clear
            )
            .padding(.horizontal, 4)
        )
        .listRowSeparator(.hidden)
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .task(id: identity.activeChapterID) {
        guard identity.query.isEmpty, let activeChapterID = identity.activeChapterID else { return }
        await Task.yield()
        proxy.scrollTo(activeChapterID, anchor: .center)
      }
    }
  }
}

// MARK: - 章节行

private struct ChapterRow: View, Equatable {
  let chapterID: String
  let ordinal: Int
  let title: String
  let isActive: Bool
  let theme: ReaderTheme
  let select: () -> Void
  @State private var isHovering = false

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.chapterID == rhs.chapterID
      && lhs.ordinal == rhs.ordinal
      && lhs.title == rhs.title
      && lhs.isActive == rhs.isActive
      && lhs.theme == rhs.theme
  }

  var body: some View {
    Button(action: select) {
      HStack(alignment: .firstTextBaseline, spacing: 9) {
        Text("\(ordinal + 1)")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(isActive ? theme.accentColor : Color.secondary.opacity(0.7))
          .frame(minWidth: 26, alignment: .trailing)
        Text(title)
          .font(isActive ? .callout.weight(.medium) : .callout)
          .foregroundStyle(isActive ? theme.accentColor : theme.foregroundColor)
          .lineLimit(2)
        Spacer(minLength: 4)
        if isActive {
          Image(systemName: "book.fill")
            .font(.system(size: 9))
            .foregroundStyle(theme.accentColor)
            .transition(.opacity.combined(with: .scale(scale: 0.5)))
        }
      }
      .padding(.vertical, 3)
      .padding(.horizontal, 4)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(theme.foregroundColor.opacity(isHovering && !isActive ? 0.05 : 0))
    }
    .animation(WBMotion.snappy, value: isHovering)
    .animation(WBMotion.snappy, value: isActive)
    .onHover { isHovering = $0 }
  }
}

// MARK: - 搜索结果面板

struct ReaderSearchPanel: View {
  let results: [ReaderSearchResult]
  let theme: ReaderTheme
  let select: (ReaderSearchResult) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        Image(systemName: "text.magnifyingglass")
          .font(.caption2)
          .foregroundStyle(theme.accentColor)
        Text("找到 \(results.count) 处")
          .font(.caption.weight(.semibold))
        Spacer()
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 7)

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(results) { result in
            Button {
              select(result)
            } label: {
              VStack(alignment: .leading, spacing: 3) {
                Text(result.chapterTitle)
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(theme.accentColor)
                Text(result.excerpt)
                  .font(.caption)
                  .lineLimit(2)
                  .foregroundStyle(.secondary)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 14)
              .padding(.vertical, 7)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Rectangle()
              .fill(theme.separatorColor)
              .frame(height: 0.5)
              .padding(.leading, 14)
          }
        }
      }
      .frame(maxHeight: 200)
    }
    .background {
      Rectangle().fill(.bar)
      Rectangle().fill(theme.chromeColor.opacity(theme == .system ? 0.0 : 0.62))
    }
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(theme.separatorColor)
        .frame(height: 0.5)
    }
  }
}

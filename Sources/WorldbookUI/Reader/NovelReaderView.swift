import LibraryCore
import MediaCore
import NovelDocumentCore
import SpeechProviderKit
import SwiftUI

// MARK: - 阅读器

struct NovelReaderView: View {
  let record: NovelLibraryRecord
  @ObservedObject var model: LibraryViewModel
  let close: () -> Void
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var isNavigationVisible = true
  @State private var isMobileNavigationPresented = false
  @State private var isMobileSearchVisible = false
  @State private var isCompactChromeVisible = false
  @State private var navigationTab: ReaderSidebarTab = .contents
  @State private var isAppearancePresented = false
  @State private var searchText = ""
  @State private var searchResults: [ReaderSearchResult] = []
  @State private var hasSearched = false
  @State private var isSearching = false
  @State private var searchToken = UUID()
  @State private var scrubbedChapterIndex: Double?
  @State private var isScrollAtChapterTop = true
  @State private var isBookmarkPullTracking = false
  @State private var bookmarkPullStartedAtTop = false
  @State private var bookmarkFeedback: String?
  @State private var bookmarkFeedbackToken = UUID()
  @FocusState private var isSearchFocused: Bool
  @StateObject private var speechPlayer = AppleSpeechPlayer()
  private let speechPlanStore = SpeechPlanStore()
  private let speechPlaybackStore = SpeechPlaybackStore()

  private var activeChapter: NovelChapter? {
    let currentID = record.readerState.currentChapterID
    return record.document.chapters.first { $0.id == currentID }
      ?? record.document.chapters.first
  }

  private var activeChapterIndex: Int {
    guard let activeChapter else { return 0 }
    return record.document.chapters.firstIndex(where: { $0.id == activeChapter.id }) ?? 0
  }

  private var theme: ReaderTheme {
    record.readerState.preferences.theme
  }

  private var isCompact: Bool {
    horizontalSizeClass == .compact
  }

  var body: some View {
    VStack(spacing: 0) {
      if !isCompact {
        readerToolbar
        searchStatus
      }

      HStack(spacing: 0) {
        if !isCompact, isNavigationVisible {
          ReaderNavigationSidebar(
            record: record,
            activeChapterID: activeChapter?.id,
            theme: theme,
            selectedTab: $navigationTab
          ) { chapterID, progression in
            model.selectChapter(chapterID, in: record.id, progression: progression)
          }
          .frame(width: 292)
          .transition(.move(edge: .leading).combined(with: .opacity))
        }

        if let chapter = activeChapter {
          Group {
            if record.readerState.preferences.flow == .horizontalPages {
              ReaderPaginatedView(
                chapter: chapter,
                initialProgress: record.readerState.chapterProgress,
                navigationToken: model.navigationToken(for: record.id),
                preferences: record.readerState.preferences,
                theme: theme,
                isCompact: isCompact,
                hasPreviousChapter: model.canMoveChapter(by: -1, in: record.id),
                hasNextChapter: model.canMoveChapter(by: 1, in: record.id),
                progressChanged: { progress in
                  model.updateReadingProgress(progress, chapterID: chapter.id, in: record.id)
                },
                moveToPreviousChapter: {
                  moveToAdjacentChapter(by: -1, progression: 1)
                },
                moveToNextChapter: {
                  moveToAdjacentChapter(by: 1, progression: 0)
                },
                centerTapped: {
                  toggleCompactChrome()
                }
              )
            } else {
              ReaderChapterScrollView(
                chapter: chapter,
                initialProgress: record.readerState.chapterProgress,
                navigationToken: model.navigationToken(for: record.id),
                preferences: record.readerState.preferences,
                theme: theme,
                progressChanged: { progress in
                  model.updateReadingProgress(progress, chapterID: chapter.id, in: record.id)
                },
                topStateChanged: { isAtTop in
                  guard isScrollAtChapterTop != isAtTop else { return }
                  isScrollAtChapterTop = isAtTop
                }
              )
            }
          }
          .background(theme.backgroundColor)
          .foregroundStyle(theme.foregroundColor)
          .modify { content in
            if isCompact {
              if record.readerState.preferences.flow == .horizontalPages {
                // 分页的左右三区由 ReaderPaginatedView 处理；滚动模式保留原生滚动与选文。
                content
                  .contentShape(Rectangle())
                  .simultaneousGesture(compactDragHideGesture)
                  .simultaneousGesture(pullBookmarkGesture)
              } else {
                content
                  .contentShape(Rectangle())
                  .simultaneousGesture(compactTapGesture)
                  .simultaneousGesture(compactDragHideGesture)
                  .simultaneousGesture(pullBookmarkGesture)
              }
            } else {
              content
                .contentShape(Rectangle())
                .simultaneousGesture(pullBookmarkGesture)
            }
          }
        }
      }

      if !isCompact {
        ReaderProgressFooter(
          activeChapterIndex: activeChapterIndex,
          chapterCount: record.document.chapters.count,
          bookProgress: record.readerState.currentLocator?.locations.totalProgression ?? 0,
          theme: theme,
          scrubbedChapterIndex: $scrubbedChapterIndex,
          canMoveBackward: model.canMoveChapter(by: -1, in: record.id),
          canMoveForward: model.canMoveChapter(by: 1, in: record.id),
          moveBackward: { model.moveChapter(by: -1, in: record.id) },
          moveForward: { model.moveChapter(by: 1, in: record.id) },
          selectChapterAt: { index in
            guard record.document.chapters.indices.contains(index) else { return }
            model.selectChapter(record.document.chapters[index].id, in: record.id)
          }
        )
      }
    }
    .background(theme.backgroundColor)
    .foregroundStyle(theme.foregroundColor)
    .tint(theme.accentColor)
    .navigationTitle(readerTitle)
    .readerCompactSystemChromeHidden(isCompact)
    .animation(WBMotion.gentle, value: isNavigationVisible)
    .animation(WBMotion.gentle, value: isCompactChromeVisible)
    .overlay(alignment: .top) { compactTopChrome }
    .overlay(alignment: .top) { bookmarkFeedbackOverlay }
    .overlay(alignment: .bottom) { compactBottomChrome }
    .modify { view in
      if isCompact {
        view.sheet(isPresented: $isAppearancePresented) {
          NavigationStack {
            ReaderAppearancePanel(record: record, model: model)
              .navigationTitle("阅读设置")
              .readerInlineNavigationTitle()
              .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                  Button("完成") { isAppearancePresented = false }
                }
              }
          }
          .presentationDetents([.medium, .large])
          .presentationDragIndicator(.visible)
        }
      } else {
        view
      }
    }
    .sheet(isPresented: $isMobileNavigationPresented) {
      NavigationStack {
        ReaderNavigationSidebar(
          record: record,
          activeChapterID: activeChapter?.id,
          theme: theme,
          selectedTab: $navigationTab
        ) { chapterID, progression in
          model.selectChapter(chapterID, in: record.id, progression: progression)
          isMobileNavigationPresented = false
        }
        .navigationTitle("目录与书签")
        .readerInlineNavigationTitle()
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("完成") { isMobileNavigationPresented = false }
          }
        }
      }
      .presentationDetents([.medium, .large])
    }
    .onChange(of: activeChapter?.id) { _, _ in
      scrubbedChapterIndex = nil
      isCompactChromeVisible = false
      isScrollAtChapterTop = record.readerState.chapterProgress <= 0.001
      speechPlayer.stop()
    }
    .onChange(of: speechPlayer.location) { _, location in
      guard let location else { return }
      Task { try? await speechPlaybackStore.save(location) }
    }
    .onDisappear { speechPlayer.stop() }
    .readerColorScheme(theme)
  }

  // MARK: 沉浸式点按手势（compact）

  /// 点按正文唤出/隐藏控制条
  private var compactTapGesture: some Gesture {
    TapGesture().onEnded {
      toggleCompactChrome()
    }
  }

  /// 滚动/翻页拖动时自动隐藏控制条
  private var compactDragHideGesture: some Gesture {
    DragGesture(minimumDistance: 16).onChanged { _ in
      guard isCompactChromeVisible else { return }
      withAnimation(WBMotion.gentle) {
        isCompactChromeVisible = false
      }
    }
  }

  /// 仅从章节顶部开始的向下拖动才添加书签，避免截获正常滚动。
  private var pullBookmarkGesture: some Gesture {
    DragGesture(minimumDistance: 12)
      .onChanged { _ in
        guard !isBookmarkPullTracking else { return }
        isBookmarkPullTracking = true
        bookmarkPullStartedAtTop =
          record.readerState.preferences.flow == .horizontalPages || isScrollAtChapterTop
      }
      .onEnded { value in
        defer {
          isBookmarkPullTracking = false
          bookmarkPullStartedAtTop = false
        }
        guard bookmarkPullStartedAtTop,
          value.translation.height >= 60,
          value.translation.height > abs(value.translation.width) * 1.2
        else { return }
        let added = model.addBookmarkAtCurrentLocation(in: record.id)
        showBookmarkFeedback(added ? "已加书签" : "此处已有书签")
      }
  }

  private func toggleCompactChrome() {
    guard isCompact else { return }
    withAnimation(WBMotion.gentle) {
      isCompactChromeVisible.toggle()
    }
  }

  private func showBookmarkFeedback(_ message: String) {
    let token = UUID()
    bookmarkFeedbackToken = token
    withAnimation(.easeOut(duration: 0.18)) {
      bookmarkFeedback = message
    }
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(1_500))
      guard bookmarkFeedbackToken == token else { return }
      withAnimation(.easeIn(duration: 0.18)) {
        bookmarkFeedback = nil
      }
    }
  }

  @ViewBuilder
  private var bookmarkFeedbackOverlay: some View {
    if let bookmarkFeedback {
      Label(bookmarkFeedback, systemImage: "bookmark.fill")
        .font(.caption.weight(.semibold))
        .foregroundStyle(theme.accentColor)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .wbReaderChromePanel(theme: theme, cornerRadius: 18)
        .padding(.top, isCompact && isCompactChromeVisible ? 62 : 10)
        .transition(.move(edge: .top).combined(with: .opacity))
        .allowsHitTesting(false)
    }
  }

  // MARK: 工具条（毛玻璃）

  private var isBookmarked: Bool {
    model.isCurrentChapterBookmarked(in: record.id)
  }

  private var readerToolbar: some View {
    HStack(spacing: 10) {
      Button(action: close) {
        Label("书架", systemImage: "chevron.left")
          .labelStyle(.titleAndIcon)
          .font(.subheadline.weight(.medium))
      }
      .buttonStyle(WBChromeButtonStyle())
      .help("返回书架")

      Button {
        isNavigationVisible.toggle()
      } label: {
        Image(systemName: "sidebar.leading")
          .font(.subheadline.weight(.medium))
      }
      .buttonStyle(WBChromeButtonStyle())
      .help(isNavigationVisible ? "隐藏目录" : "显示目录")

      VStack(alignment: .leading, spacing: 1) {
        Text(record.document.title)
          .font(.system(.subheadline, design: .serif, weight: .semibold))
          .lineLimit(1)
        Text(activeChapter?.title ?? "")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .padding(.leading, 2)

      Spacer(minLength: 16)

      HStack(spacing: 7) {
        Image(systemName: "magnifyingglass")
          .font(.caption)
          .foregroundStyle(.secondary)
        TextField("搜索本书", text: $searchText)
          .textFieldStyle(.plain)
          .focused($isSearchFocused)
          .onSubmit { performSearch() }
          .onChange(of: searchText) { _, newValue in
            searchToken = UUID()
            isSearching = false
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              searchResults = []
              hasSearched = false
            }
          }
        if !searchText.isEmpty {
          Button {
            searchText = ""
            searchResults = []
            hasSearched = false
            searchToken = UUID()
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
      .padding(.vertical, 6)
      .frame(width: isSearchFocused ? 280 : 210)
      .background(theme.fieldColor, in: Capsule())
      .overlay {
        Capsule()
          .strokeBorder(
            theme.accentColor.opacity(isSearchFocused ? 0.6 : 0),
            lineWidth: 1.2
          )
      }
      .animation(WBMotion.snappy, value: isSearchFocused)
      .animation(WBMotion.snappy, value: searchText.isEmpty)

      Button {
        toggleNarration()
      } label: {
        Image(systemName: narrationSymbol)
          .font(.subheadline.weight(.medium))
      }
      .buttonStyle(WBChromeButtonStyle())
      .help(narrationLabel)

      Button {
        model.toggleBookmark(in: record.id)
      } label: {
        Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
          .font(.subheadline.weight(.medium))
          .foregroundStyle(isBookmarked ? theme.accentColor : Color.primary)
          .contentTransition(.symbolEffect(.replace.downUp))
      }
      .buttonStyle(WBChromeButtonStyle())
      .animation(WBMotion.bouncy, value: isBookmarked)
      .help(isBookmarked ? "删除本章书签" : "添加本章书签")
      .keyboardShortcut("b", modifiers: [.command])

      Button {
        isAppearancePresented.toggle()
      } label: {
        Image(systemName: "textformat")
          .font(.subheadline.weight(.medium))
      }
      .buttonStyle(WBChromeButtonStyle())
      .help("排版与页面宽度")
      .popover(isPresented: $isAppearancePresented, arrowEdge: .bottom) {
        ReaderAppearancePanel(record: record, model: model)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
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

  // MARK: 沉浸式浮动控制条（compact）

  /// 顶部浮动控制条：返回、书名/章节、目录、搜索、书签、更多
  @ViewBuilder
  private var compactTopChrome: some View {
    if isCompact, isCompactChromeVisible {
      VStack(spacing: 8) {
        HStack(spacing: 2) {
          Button(action: close) {
            Image(systemName: "chevron.left")
              .font(.subheadline.weight(.semibold))
          }
          .buttonStyle(WBChromeButtonStyle())
          .accessibilityLabel("返回书架")

          VStack(alignment: .leading, spacing: 1) {
            Text(record.document.title)
              .font(.subheadline.weight(.semibold))
              .lineLimit(1)
            Text(activeChapter?.title ?? "")
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          .padding(.leading, 4)

          Spacer(minLength: 4)

          Button {
            isMobileNavigationPresented = true
          } label: {
            Image(systemName: "list.bullet")
          }
          .buttonStyle(WBChromeButtonStyle())
          .accessibilityLabel("目录与书签")

          Button {
            isMobileSearchVisible.toggle()
            if isMobileSearchVisible {
              Task { @MainActor in isSearchFocused = true }
            }
          } label: {
            Image(systemName: "magnifyingglass")
          }
          .buttonStyle(WBChromeButtonStyle())
          .accessibilityLabel("搜索本书")

          Button {
            model.toggleBookmark(in: record.id)
          } label: {
            Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
              .foregroundStyle(isBookmarked ? theme.accentColor : Color.primary)
              .contentTransition(.symbolEffect(.replace.downUp))
          }
          .buttonStyle(WBChromeButtonStyle())
          .animation(WBMotion.bouncy, value: isBookmarked)
          .accessibilityLabel(isBookmarked ? "删除本章书签" : "添加本章书签")

          Menu {
            Button {
              toggleNarration()
            } label: {
              Label(narrationLabel, systemImage: narrationSymbol)
            }
            Button {
              isAppearancePresented = true
            } label: {
              Label("排版与主题", systemImage: "textformat")
            }
          } label: {
            Image(systemName: "ellipsis")
          }
          .buttonStyle(WBChromeButtonStyle())
          .accessibilityLabel("更多阅读操作")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .wbReaderChromePanel(theme: theme)

        if isMobileSearchVisible {
          mobileSearchField
        }

        searchStatus
      }
      .padding(.horizontal, 12)
      .padding(.top, 4)
      .transition(.move(edge: .top).combined(with: .opacity))
    }
  }

  /// 底部浮动控制条：章节滑杆 + 上下章；隐藏时只留一条整书进度发丝线
  @ViewBuilder
  private var compactBottomChrome: some View {
    if isCompact {
      if isCompactChromeVisible {
        VStack(spacing: 2) {
          HStack(spacing: 4) {
            Button {
              model.moveChapter(by: -1, in: record.id)
            } label: {
              Image(systemName: "chevron.left")
                .font(.caption.weight(.semibold))
            }
            .buttonStyle(WBChromeButtonStyle())
            .disabled(!model.canMoveChapter(by: -1, in: record.id))
            .accessibilityLabel("上一章")

            Slider(
              value: Binding(
                get: { scrubbedChapterIndex ?? Double(activeChapterIndex) },
                set: { scrubbedChapterIndex = $0 }
              ),
              in: 0...Double(max(record.document.chapters.count - 1, 1)),
              step: 1
            ) { editing in
              guard !editing, let scrubbedChapterIndex else { return }
              let index = Int(scrubbedChapterIndex.rounded())
              guard record.document.chapters.indices.contains(index) else { return }
              model.selectChapter(record.document.chapters[index].id, in: record.id)
              self.scrubbedChapterIndex = nil
            }
            .disabled(record.document.chapters.count < 2)
            .tint(theme.accentColor)
            .accessibilityLabel("整书章节进度")

            Button {
              model.moveChapter(by: 1, in: record.id)
            } label: {
              Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
            }
            .buttonStyle(WBChromeButtonStyle())
            .disabled(!model.canMoveChapter(by: 1, in: record.id))
            .accessibilityLabel("下一章")
          }

          Text(
            "第 \(min(activeChapterIndex + 1, max(record.document.chapters.count, 1))) / \(record.document.chapters.count) 章 · \(readerPercent)%"
          )
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
          .contentTransition(.numericText())
          .animation(WBMotion.snappy, value: activeChapterIndex)
          .animation(WBMotion.snappy, value: readerPercent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .wbReaderChromePanel(theme: theme, cornerRadius: 20)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
      } else {
        GeometryReader { geometry in
          ZStack(alignment: .leading) {
            Rectangle().fill(theme.separatorColor.opacity(0.7))
            Rectangle()
              .fill(theme.accentColor)
              .frame(
                width: geometry.size.width
                  * (record.readerState.currentLocator?.locations.totalProgression ?? 0)
              )
              .animation(
                WBMotion.gentle,
                value: record.readerState.currentLocator?.locations.totalProgression ?? 0
              )
          }
        }
        .frame(height: 2)
        .transition(.opacity)
      }
    }
  }


  private var mobileSearchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.caption)
        .foregroundStyle(.secondary)
      TextField("搜索本书", text: $searchText)
        .textFieldStyle(.plain)
        .focused($isSearchFocused)
        .submitLabel(.search)
        .onSubmit { performSearch() }
        .onChange(of: searchText) { _, newValue in
          searchToken = UUID()
          isSearching = false
          if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            searchResults = []
            hasSearched = false
          }
        }
      if !searchText.isEmpty {
        Button {
          searchText = ""
          searchResults = []
          hasSearched = false
          searchToken = UUID()
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
      }
      Button("完成") {
        isMobileSearchVisible = false
        isSearchFocused = false
      }
      .font(.caption.weight(.semibold))
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .wbReaderChromePanel(theme: theme, cornerRadius: 16)
  }

  @ViewBuilder
  private var searchStatus: some View {
    if !searchResults.isEmpty {
      ReaderSearchPanel(results: searchResults, theme: theme) { result in
        model.selectChapter(
          result.chapterID,
          in: record.id,
          progression: result.locator.locations.progression ?? 0
        )
        searchResults = []
        searchText = ""
        hasSearched = false
        if isCompact {
          isMobileSearchVisible = false
          isSearchFocused = false
        }
      }
    } else if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      HStack(spacing: 8) {
        if isSearching {
          ProgressView()
            .controlSize(.small)
          Text("正在搜索…")
        } else {
          Image(systemName: hasSearched ? "text.magnifyingglass" : "return")
            .font(.caption2)
          Text(hasSearched ? "没有找到匹配内容" : "按回车搜索本书")
        }
        Spacer()
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal)
      .padding(.vertical, 6)
      .modify { view in
        if isCompact {
          view.wbReaderChromePanel(theme: theme, cornerRadius: 12)
        } else {
          view.background {
            Rectangle().fill(.bar)
            Rectangle().fill(theme.chromeColor.opacity(theme == .system ? 0.0 : 0.62))
          }
        }
      }
    }
  }

  private var readerTitle: String {
    "\(record.document.title) · \(readerPercent)%"
  }

  private var readerPercent: Int {
    Int(((record.readerState.currentLocator?.locations.totalProgression ?? 0) * 100).rounded())
  }

  private var activeSpeechPlan: SpeechPlan? {
    activeChapter.map { chapter in
      SpeechPlanBuilder.singleNarrator(
        kind: .publishedChapter,
        sourceID: "\(record.id.uuidString.lowercased()):\(chapter.id)",
        text: chapter.content
      )
    }
  }

  private var narrationSymbol: String {
    guard let plan = activeSpeechPlan, speechPlayer.currentPlanID == plan.id else {
      return "speaker.wave.2"
    }
    switch speechPlayer.state {
    case .playing: return "pause.fill"
    case .paused: return "play.fill"
    case .idle: return "speaker.wave.2"
    }
  }

  private var narrationLabel: String {
    guard let plan = activeSpeechPlan, speechPlayer.currentPlanID == plan.id else {
      return "朗读本章"
    }
    switch speechPlayer.state {
    case .playing: return "暂停朗读"
    case .paused: return "继续朗读"
    case .idle: return "朗读本章"
    }
  }

  private func toggleNarration() {
    guard let plan = activeSpeechPlan else { return }
    Task {
      try? await speechPlanStore.save(plan)
      let saved = try? await speechPlaybackStore.load(
        sourceID: plan.source.sourceID,
        contentHash: plan.source.contentHash
      )
      speechPlayer.toggle(plan: plan, from: saved)
    }
  }

  private func moveToAdjacentChapter(by offset: Int, progression: Double) {
    let targetIndex = activeChapterIndex + offset
    guard record.document.chapters.indices.contains(targetIndex) else { return }
    model.selectChapter(
      record.document.chapters[targetIndex].id,
      in: record.id,
      progression: progression
    )
  }

  private func performSearch() {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return }
    isSearching = true
    hasSearched = false
    let token = UUID()
    searchToken = token
    Task {
      let results = await model.search(query, in: record.id)
      guard searchToken == token,
        searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query
      else { return }
      searchResults = results
      hasSearched = true
      isSearching = false
    }
  }
}

// MARK: - 底部进度条（毛玻璃）

private struct ReaderProgressFooter: View {
  let activeChapterIndex: Int
  let chapterCount: Int
  let bookProgress: Double
  let theme: ReaderTheme
  @Binding var scrubbedChapterIndex: Double?
  let canMoveBackward: Bool
  let canMoveForward: Bool
  let moveBackward: () -> Void
  let moveForward: () -> Void
  let selectChapterAt: (Int) -> Void

  private var bookPercent: Int {
    Int((bookProgress * 100).rounded())
  }

  var body: some View {
    regularFooter
  }

  private var regularFooter: some View {
    HStack(spacing: 12) {
      Button(action: moveBackward) {
        Label("上一章", systemImage: "chevron.left")
          .font(.caption.weight(.medium))
      }
      .buttonStyle(WBChromeButtonStyle())
      .disabled(!canMoveBackward)
      .keyboardShortcut(.leftArrow, modifiers: [.option])

      Slider(
        value: Binding(
          get: { scrubbedChapterIndex ?? Double(activeChapterIndex) },
          set: { scrubbedChapterIndex = $0 }
        ),
        in: 0...Double(max(chapterCount - 1, 1)),
        step: 1
      ) { editing in
        guard !editing, let scrubbedChapterIndex else { return }
        selectChapterAt(Int(scrubbedChapterIndex.rounded()))
        self.scrubbedChapterIndex = nil
      }
      .disabled(chapterCount < 2)
      .tint(theme.accentColor)
      .accessibilityLabel("整书章节进度")

      Text("第 \(min(activeChapterIndex + 1, max(chapterCount, 1))) / \(chapterCount) 章 · \(bookPercent)%")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .contentTransition(.numericText())
        .animation(WBMotion.snappy, value: activeChapterIndex)
        .animation(WBMotion.snappy, value: bookPercent)
        .frame(minWidth: 150, alignment: .trailing)

      Button(action: moveForward) {
        Label("下一章", systemImage: "chevron.right")
          .labelStyle(.titleAndIcon)
          .font(.caption.weight(.medium))
      }
      .buttonStyle(WBChromeButtonStyle())
      .disabled(!canMoveForward)
      .keyboardShortcut(.rightArrow, modifiers: [.option])
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .readerFooterBackground(theme: theme, bookProgress: bookProgress)
  }
}

// MARK: - 阅读器浮动 chrome 面板

private struct ReaderChromePanel: ViewModifier {
  let theme: ReaderTheme
  var cornerRadius: CGFloat = 22

  func body(content: Content) -> some View {
    content
      .background {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(.regularMaterial)
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(theme.chromeColor.opacity(theme == .system ? 0.22 : 0.72))
      }
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
      }
      .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
  }
}

private extension View {
  /// 沉浸式阅读器的浮动玻璃面板（主题色调制）
  func wbReaderChromePanel(theme: ReaderTheme, cornerRadius: CGFloat = 22) -> some View {
    modifier(ReaderChromePanel(theme: theme, cornerRadius: cornerRadius))
  }
}

private extension View {
  @ViewBuilder
  func readerInlineNavigationTitle() -> some View {
    #if os(iOS)
      navigationBarTitleDisplayMode(.inline)
    #else
      self
    #endif
  }

  @ViewBuilder
  func readerCompactSystemChromeHidden(_ hidden: Bool) -> some View {
    #if os(iOS)
      if hidden {
        toolbar(.hidden, for: .navigationBar)
          .toolbar(.hidden, for: .tabBar)
      } else {
        self
      }
    #else
      self
    #endif
  }

  func readerFooterBackground(theme: ReaderTheme, bookProgress: Double) -> some View {
    self
      .background {
        Rectangle().fill(.bar)
        Rectangle().fill(theme.chromeColor.opacity(theme == .system ? 0.0 : 0.62))
      }
      .overlay(alignment: .top) {
        // 顶缘发丝线 + 整书阅读进度
        VStack(spacing: 0) {
          GeometryReader { geometry in
            ZStack(alignment: .leading) {
              Rectangle().fill(theme.separatorColor)
              Rectangle()
                .fill(theme.accentColor)
                .frame(width: geometry.size.width * bookProgress)
                .animation(WBMotion.gentle, value: bookProgress)
            }
          }
          .frame(height: 2)
          Spacer()
        }
      }
  }
}

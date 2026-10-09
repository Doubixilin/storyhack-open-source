import CharacterLibraryCore
import LLMProviderKit
import LibraryCore
import NovelDocumentCore
import StoryworldCore
import StoryworldFactory
import SwiftUI
import UniformTypeIdentifiers
import WritingCore
#if os(iOS)
  import UIKit
#endif

public enum WorldbookAppPlatform: Equatable, Sendable {
  case iOS
  case macOS
}

public struct WorldbookRootView: View {
  /// 共用 fileImporter 的导入流程选择
  private enum ImportContext {
    case novel
    case storyworld
    case adaptation
  }

  enum Section: String, CaseIterable, Identifiable {
    case library = "书架"
    case writing = "写作台"
    case conversations = "世界书"
    case characters = "角色"
    case saves = "存档与分支"
    case graph = "分支图"
    case factory = "世界书工坊"
    case providers = "模型设置"

    var id: Self { self }

    var symbol: String {
      switch self {
      case .library: "books.vertical.fill"
      case .writing: "square.and.pencil"
      case .conversations: "bubble.left.and.text.bubble.right.fill"
      case .characters: "person.crop.rectangle.stack.fill"
      case .saves: "arrow.triangle.branch"
      case .graph: "point.3.connected.trianglepath.dotted"
      case .factory: "wand.and.sparkles"
      case .providers: "key.fill"
      }
    }

    var accent: Color {
      switch self {
      case .library: .wbIndigo
      case .writing: .wbGold
      case .conversations: .wbViolet
      case .characters: .wbViolet
      case .saves: .wbTeal
      case .graph: .wbTeal
      case .factory: .wbGold
      case .providers: .secondary
      }
    }

    /// iPhone 标签栏使用的短标题
    var tabTitle: String {
      switch self {
      case .saves: "存档"
      default: rawValue
      }
    }
  }

  private let platform: WorldbookAppPlatform
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var libraryModel: LibraryViewModel
  @StateObject private var storyworldModel: StoryworldViewModel
  @StateObject private var characterLibraryModel: CharacterLibraryViewModel
  @StateObject private var providerModel: ProviderSettingsViewModel
  @StateObject private var sessionModel: StorySessionViewModel
  @StateObject private var factoryModel: FactoryViewModel
  @StateObject private var writingModel: WritingViewModel
  @StateObject private var adaptationModel: AdaptationViewModel
  @AppStorage("storyhack.community.privacy_mode_enabled") private var privacyModeEnabled = false
  @State private var selection: Section? = {
    // UI 测试钩子：以 -UITestInitialTab <rawValue> 启动参数指定初始标签
    let args = ProcessInfo.processInfo.arguments
    if let index = args.firstIndex(of: "-UITestInitialTab"), args.indices.contains(index + 1) {
      return Section(rawValue: args[index + 1])
    }
    return .library
  }()
  @State private var isImporterPresented = false
  /// 当前导入流程：SwiftUI 同一视图链上只有最后一个 .fileImporter 能弹出，
  /// 因此两条导入（小说 / 世界书）共用一个 fileImporter，靠这个上下文分发。
  @State private var importContext: ImportContext = .novel
  @State private var storyworldImportTarget: NovelLibraryRecord?
  @State private var storyworldContextBookID: UUID?
  @State private var isReaderOpen = false
  @State private var librarySearchText = ""
  @State private var columnVisibility: NavigationSplitViewVisibility = .all

  public init(
    platform: WorldbookAppPlatform,
    library: NovelLibrary = NovelLibrary(),
    storyworldLibrary: StoryworldLibrary = StoryworldLibrary(),
    providerStore: ProviderProfileStore = ProviderProfileStore(),
    factoryStore: FactoryJobStore = FactoryJobStore(),
    factoryWorker: (any FactoryAnalysisWorker)? = nil,
    characterStore: CharacterLibraryStore = CharacterLibraryStore(),
    writingLibrary: WritingProjectLibrary = WritingProjectLibrary(),
    adaptationStore: AdaptationJobStore = .shared,
    directiveStore: DirectiveProfileStore = .shared,
    tasteStore: PlayerTasteStore = .shared
  ) {
    self.platform = platform
    _libraryModel = StateObject(wrappedValue: LibraryViewModel(library: library))
    let storyworldViewModel = StoryworldViewModel(
      library: storyworldLibrary,
      novelLibrary: library,
      providerStore: providerStore
    )
    _storyworldModel = StateObject(wrappedValue: storyworldViewModel)
    _characterLibraryModel = StateObject(
      wrappedValue: CharacterLibraryViewModel(
        store: characterStore,
        providerStore: providerStore
      )
    )
    _providerModel = StateObject(
      wrappedValue: ProviderSettingsViewModel(store: providerStore)
    )
    _sessionModel = StateObject(
      wrappedValue: StorySessionViewModel(
        storyworldLibrary: storyworldLibrary,
        providerStore: providerStore,
        directiveStore: directiveStore,
        tasteStore: tasteStore
      )
    )
    let resolvedWorker: any FactoryAnalysisWorker
    if let factoryWorker {
      resolvedWorker = factoryWorker
    } else {
      // 双端统一直连模型执行器：iOS 上仅保证前台运行，
      // 批次级断点续跑由 FactoryAnalysisRunner 的检查点承担。
      resolvedWorker = DefaultProviderFactoryWorker(providerStore: providerStore)
    }
    let coordinator = FactoryCoordinator(
      library: library,
      storyworldLibrary: storyworldLibrary,
      store: factoryStore,
      worker: resolvedWorker,
      tasteStore: tasteStore
    )
    let factoryViewModel = FactoryViewModel(coordinator: coordinator, store: factoryStore)
    // 工坊发布成功后立即刷新世界书列表，不用重启才能看到新世界
    factoryViewModel.onStoryworldPublished = { _ in
      Task { await storyworldViewModel.reload() }
    }
    _factoryModel = StateObject(wrappedValue: factoryViewModel)
    _writingModel = StateObject(
      wrappedValue: WritingViewModel(
        projectLibrary: writingLibrary,
        novelLibrary: library,
        providerStore: providerStore
      )
    )
    _adaptationModel = StateObject(wrappedValue: AdaptationViewModel(
      store: adaptationStore, library: library, providerStore: providerStore, tasteStore: tasteStore))
  }

  public var body: some View {
    rootNavigation
    .overlay {
      if privacyModeEnabled, scenePhase != .active {
        PrivacyModeCoverView()
          .transition(.opacity)
          .zIndex(1_000)
      }
    }
    .fileImporter(
      isPresented: $isImporterPresented,
      allowedContentTypes: importContext == .storyworld
        ? [.storyworldDocument, .lorebookDocument, .json]
        : supportedImportTypes,
      allowsMultipleSelection: true
    ) { result in
      switch importContext {
      case .novel:
        switch result {
        case .success(let urls):
          Task { await libraryModel.importDocuments(from: urls) }
        case .failure(let error):
          libraryModel.errorMessage = error.localizedDescription
        }
      case .storyworld:
        guard let target = storyworldImportTarget else { return }
        switch result {
        case .success(let urls):
          Task { await storyworldModel.importFiles(from: urls, associateWith: target) }
        case .failure(let error):
          storyworldModel.errorMessage = error.localizedDescription
        }
      case .adaptation:
        switch result {
        case .success(let urls): Task { await adaptationModel.importFiles(urls) }
        case .failure(let error): adaptationModel.errorMessage = error.localizedDescription
        }
      }
    }
    .fileExporter(
      isPresented: $storyworldModel.isExporterPresented,
      document: storyworldModel.exportDocument,
      contentType: .storyworldDocument,
      defaultFilename: storyworldModel.exportFileName
    ) { result in
      storyworldModel.handleExportCompletion(result)
    }
    .alert(
      "操作未完成",
      isPresented: Binding(
        get: { libraryModel.errorMessage != nil },
        set: { if !$0 { libraryModel.errorMessage = nil } }
      )
    ) {
      Button("好") { libraryModel.errorMessage = nil }
    } message: {
      Text(libraryModel.errorMessage ?? "未知错误")
    }
    .alert(
      "世界书操作未完成",
      isPresented: Binding(
        get: { storyworldModel.errorMessage != nil },
        set: { if !$0 { storyworldModel.errorMessage = nil } }
      )
    ) {
      Button("好") { storyworldModel.errorMessage = nil }
    } message: {
      Text(storyworldModel.errorMessage ?? "未知错误")
    }
    .confirmationDialog(
      "发现同一 Storyworld",
      isPresented: Binding(
        get: { storyworldModel.pendingConflict != nil },
        set: { if !$0 { storyworldModel.pendingConflict = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("替换本机副本并保留备份") {
        storyworldModel.resolvePendingConflict(with: .replaceWithBackup)
      }
      Button("作为新的副本导入") {
        storyworldModel.resolvePendingConflict(with: .importAsCopy)
      }
      Button("取消", role: .cancel) { storyworldModel.pendingConflict = nil }
    } message: {
      if let conflict = storyworldModel.pendingConflict {
        Text(
          "本机修订：\(conflict.localRevision)；导入修订：\(conflict.importedRevision)。不会自动合并游玩内容。"
            + (conflict.skippedCount > 0
              ? "另有 \(conflict.skippedCount) 个文件未导入，可在处理冲突后重新导入。"
              : "")
        )
      }
    }
    .task {
      await libraryModel.reload()
      await storyworldModel.reload()
      await characterLibraryModel.reload()
      await providerModel.reload()
      // UI 测试钩子：指定初始标签时，自动选中第一个世界书并准备好会话，
      // 让「存档与分支」「分支图」等依赖游玩状态的页面直接有数据
      if ProcessInfo.processInfo.arguments.contains("-UITestInitialTab"),
        storyworldModel.selectedStoryworldID == nil,
        let first = storyworldModel.records.first
      {
        await storyworldModel.selectStoryworld(first.id)
        await sessionModel.prepare(storyworldID: first.id)
      }
      // UI 测试钩子：-UITestFactoryFromFirstBook 为书架第一本书准备工坊任务
      // 并跳到工坊页（iOS 上长按菜单无法被自动化注入，用此钩子走真实建任务链路）
      if ProcessInfo.processInfo.arguments.contains("-UITestFactoryFromFirstBook"),
        libraryModel.factoryCandidate == nil,
        let firstBook = libraryModel.records.first
      {
        libraryModel.prepareFactory(for: firstBook)
        selection = .factory
        columnVisibility = .all
      }
    }
    .onChange(of: libraryModel.selectedBookID) { _, _ in
      Task { await libraryModel.loadSelectedBook() }
    }
    .onChange(of: selection) { _, newSelection in
      guard newSelection != .library else { return }
      isReaderOpen = false
      columnVisibility = .all
    }
    .onOpenURL { url in
      let pathExtension = url.pathExtension.lowercased()
      if [StoryworldPackageLayout.pathExtension, "lorebook", "json"]
        .contains(pathExtension)
      {
        Task {
          await storyworldModel.importStandaloneFiles(from: [url])
          selection = .conversations
          columnVisibility = .all
        }
      } else if ["txt", "md", "markdown", "epub"].contains(pathExtension) {
        Task {
          await libraryModel.importDocuments(from: [url])
          selection = .library
          isReaderOpen = false
          columnVisibility = .all
        }
      }
    }
    .onChange(of: scenePhase) { _, phase in
      Task {
        switch phase {
        case .active:
          await sessionModel.handleLifecycle(.active)
        case .inactive:
          await sessionModel.handleLifecycle(.inactive)
        case .background:
          await sessionModel.handleLifecycle(.background)
        @unknown default:
          await sessionModel.handleLifecycle(.inactive)
        }
      }
    }
    #if os(iOS)
      .onReceive(
        NotificationCenter.default.publisher(
          for: UIApplication.didReceiveMemoryWarningNotification
        )
      ) { _ in
        Task { await sessionModel.handleLifecycle(.memoryPressure) }
      }
    #endif
    .modifier(WBApplicationAppearance(
      readerTheme: selection == .library && isReaderOpen
        ? libraryModel.selectedRecord?.readerState.preferences.theme : nil
    ))
  }

  @ViewBuilder
  private var rootNavigation: some View {
    if platform == .iOS {
      TabView(selection: $selection) {
        ForEach(visibleSections) { section in
          NavigationStack {
            detailColumn(for: section)
              .toolbar {
                if section == .library, !isReaderOpen {
                  ToolbarItem {
                    Button {
                      importContext = .novel
                      isImporterPresented = true
                    } label: {
                      Label("导入小说", systemImage: "plus")
                    }
                    .disabled(libraryModel.isImporting)
                  }
                }
              }
          }
          .tabItem {
            Label {
              Text(section.tabTitle)
            } icon: {
              Image(systemName: section.symbol)
                .symbolRenderingMode(.monochrome)
            }
          }
          .tag(Optional(section))
        }
      }
      .tint(.wbAccent)
    } else {
      NavigationSplitView(columnVisibility: $columnVisibility) {
        List(visibleSections, selection: $selection) { section in
          Label {
            Text(section.rawValue)
          } icon: {
            Image(systemName: section.symbol)
              .symbolRenderingMode(.monochrome)
              .foregroundStyle(selection == section ? Color.wbAccent : .secondary)
          }
          .tag(section)
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
          brandHeader
        }
      } detail: {
        detailColumn(for: selection)
      }
      .navigationSplitViewStyle(.balanced)
      .toolbar {
        if selection == .library, !isReaderOpen {
          ToolbarItem {
            Button {
              importContext = .novel
              isImporterPresented = true
            } label: {
              Label("导入小说", systemImage: "plus")
            }
            .disabled(libraryModel.isImporting)
          }
        }
      }
    }
  }

  /// 侧栏顶部品牌区：渐变书标 + 衬线字标
  private var brandHeader: some View {
    HStack(spacing: 11) {
      ZStack {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(LinearGradient.wbBrand)
          .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
              .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.5)
          }
          .shadow(color: Color.wbIndigo.opacity(0.35), radius: 7, y: 3)
        Image(systemName: "book.fill")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(Color.wbOnAccent)
      }
      .frame(width: 32, height: 32)

      VStack(alignment: .leading, spacing: 1) {
        Text("Storyhack")
          .font(.system(.headline, design: .serif, weight: .bold))
      }
      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.top, 10)
    .padding(.bottom, 12)
  }

  @ViewBuilder
  private func detailColumn(for section: Section?) -> some View {
    switch section {
    case .library:
      if isReaderOpen, libraryModel.isLoadingBook {
        ZStack {
          WBAmbientScenery()
          VStack(spacing: 14) {
            ProgressView()
              .controlSize(.large)
            Text("正在打开小说…")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }
      } else if isReaderOpen, let record = libraryModel.selectedRecord {
        NovelReaderView(record: record, model: libraryModel) {
          isReaderOpen = false
          columnVisibility = .all
        }
      } else {
        LibraryBookshelfView(
          records: libraryModel.records,
          searchText: $librarySearchText,
          platform: platform,
          storyworlds: storyworldModel.records,
          associatedStoryworlds: { record in
            storyworldModel.associatedRecords(for: record)
          },
          openBook: { record in
            libraryModel.selectedBookID = record.id
            isReaderOpen = true
            columnVisibility = .detailOnly
          },
          enterStoryworld: { record in
            storyworldContextBookID = record.id
            let associated = storyworldModel.associatedRecords(for: record)
            if associated.count == 1, let storyworld = associated.first {
              Task { await storyworldModel.selectStoryworld(storyworld.id) }
            } else {
              storyworldModel.selectedStoryworldID = nil
            }
            selection = .conversations
            columnVisibility = .all
          },
          importStoryworld: { record in
            storyworldImportTarget = record
            importContext = .storyworld
            isImporterPresented = true
          },
          associateExistingStoryworld: { record, storyworld in
            Task { await storyworldModel.associate(storyworld.id, with: record) }
          },
          generateWorldbook: { record in
            libraryModel.prepareFactory(for: record)
            selection = .factory
            columnVisibility = .all
          },
          deleteBook: { record in
            Task { await libraryModel.deleteBook(record) }
          }
        )
      }
    case .factory:
      FactoryWorkspaceView(
        record: libraryModel.factoryCandidate,
        requestID: libraryModel.factoryRequest?.id,
        model: factoryModel,
        enterPublishedStoryworld: { documentID, storyworldID in
          storyworldContextBookID = documentID
          Task {
            await storyworldModel.reload()
            await storyworldModel.selectStoryworld(storyworldID)
          }
          selection = .conversations
          columnVisibility = .all
        }
      )
    case .writing:
      WritingDeskView(model: writingModel, adaptation: adaptationModel, importAdaptation: {
        importContext = .adaptation
        isImporterPresented = true
      }) {
        Task { await libraryModel.reload() }
        selection = .library
        isReaderOpen = false
        columnVisibility = .all
      }
    case .conversations:
      ConversationHubView(
        novel: libraryModel.records.first { $0.id == storyworldContextBookID },
        storyworldModel: storyworldModel,
        sessionModel: sessionModel,
        openProviderSettings: {
          selection = .providers
          columnVisibility = .all
        },
        openSaves: {
          selection = .saves
          columnVisibility = .all
        }
      )
    case .characters:
      CharacterLibraryWallView(model: characterLibraryModel, storyworldModel: storyworldModel)
    case .saves:
      SavesBranchesView(
        model: sessionModel,
        openArchive: { storyworldID, playthroughID in
          Task {
            await storyworldModel.selectStoryworld(storyworldID)
            await sessionModel.openArchive(
              storyworldID: storyworldID,
              playthroughID: playthroughID
            )
            selection = .conversations
            columnVisibility = .all
          }
        }
      )
    case .graph:
      BranchGraphContainerView(model: sessionModel)
    case .providers:
      ProviderSettingsView(
        model: providerModel,
        platform: platform,
        privacyModeEnabled: $privacyModeEnabled
      )
    case nil:
      WBEmptyStateView(
        title: "世界书",
        symbol: "book.fill",
        message: "请选择一个功能。"
      )
    }
  }

  private var visibleSections: [Section] {
    if platform == .macOS {
      return [.library, .writing, .conversations, .characters, .saves, .graph, .factory, .providers]
    }
    return [.library, .conversations, .characters, .saves, .factory, .providers]
  }

  private var supportedImportTypes: [UTType] {
    var types: [UTType] = [.plainText]
    if let markdown = UTType(filenameExtension: "md") {
      types.append(markdown)
    }
    if let markdownLong = UTType(filenameExtension: "markdown") {
      types.append(markdownLong)
    }
    if let epub = UTType(filenameExtension: "epub") {
      types.append(epub)
    }
    return types
  }

}

private struct PrivacyModeCoverView: View {
  var body: some View {
    ZStack {
      Color.wbCanvas
        .ignoresSafeArea()

      VStack(spacing: 14) {
        Image(systemName: "eye.slash.fill")
          .font(.system(size: 38, weight: .semibold))
          .foregroundStyle(Color.wbViolet)
        Text("隐私模式")
          .font(.system(.title2, design: .serif, weight: .bold))
        Text("小说、世界书和会话内容已隐藏")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      .padding(32)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("隐私模式，内容已隐藏")
  }
}

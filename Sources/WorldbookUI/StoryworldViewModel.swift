import Combine
import Foundation
import LLMProviderKit
import LibraryCore
import StoryworldCore
import StoryworldFactory
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
  static let storyworldDocument = UTType(
    exportedAs: "com.doubilin.storyworld",
    conformingTo: .package
  )
  static let lorebookDocument = UTType(
    importedAs: "com.doubilin.lorebook-import",
    conformingTo: .json
  )
}

struct StoryworldExportDocument: FileDocument, @unchecked Sendable {
  static var readableContentTypes: [UTType] { [.storyworldDocument] }

  private let package: FileWrapper

  init(package: FileWrapper) {
    self.package = package
  }

  init(configuration: ReadConfiguration) throws {
    package = configuration.file
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    package
  }
}

@MainActor
public final class StoryworldViewModel: ObservableObject {
  struct PendingConflict {
    let sourceURL: URL
    let target: StoryworldAssociationTarget?
    let storyworldID: UUID
    let localRevision: Int
    let importedRevision: Int
    let skippedCount: Int
  }

  @Published public private(set) var records: [StoryworldLibraryRecord] = []
  @Published public private(set) var selectedDocument: StoryworldDocument?
  @Published public var selectedStoryworldID: UUID?
  @Published public private(set) var isWorking = false
  @Published public private(set) var isExtractingTimeline = false
  @Published public var errorMessage: String?
  @Published var pendingConflict: PendingConflict?
  @Published var exportDocument: StoryworldExportDocument?
  @Published var exportFileName = "故事世界"
  @Published var isExporterPresented = false

  private let library: StoryworldLibrary
  private let novelLibrary: NovelLibrary?
  private let providerStore: ProviderProfileStore?

  public init(
    library: StoryworldLibrary,
    novelLibrary: NovelLibrary? = nil,
    providerStore: ProviderProfileStore? = nil
  ) {
    self.library = library
    self.novelLibrary = novelLibrary
    self.providerStore = providerStore
  }

  public func reload() async {
    do {
      records = try await library.list()
      if let selectedStoryworldID,
        !records.contains(where: { $0.id == selectedStoryworldID })
      {
        self.selectedStoryworldID = nil
        selectedDocument = nil
      }
    } catch {
      errorMessage = "读取世界书资料库失败：\(error.localizedDescription)"
    }
  }

  public func associatedRecords(for novel: NovelLibraryRecord) -> [StoryworldLibraryRecord] {
    records.filter { record in
      record.associatedDocumentIDs.contains(novel.id)
        || record.manifest.sourceReference?.contentHash == novel.document.contentHash
    }
  }

  /// 反馈 #2：删除世界书（软删除到 Backups，可从备份目录重新导入恢复）。
  public func deleteStoryworld(_ storyworldID: UUID) async {
    do {
      try await library.delete(storyworldID: storyworldID)
      if selectedStoryworldID == storyworldID {
        selectedStoryworldID = nil
        selectedDocument = nil
      }
      await reload()
    } catch {
      errorMessage = "删除世界书失败：\(error.localizedDescription)"
    }
  }

  public func selectStoryworld(_ storyworldID: UUID) async {
    selectedStoryworldID = storyworldID
    do {
      selectedDocument = try await library.load(storyworldID: storyworldID)
    } catch {
      selectedDocument = nil
      errorMessage = "无法打开世界书：\(error.localizedDescription)"
    }
  }

  /// 素材库方案：新建空白世界书（融合世界的起点），创建后直接选中。
  public func createEmptyStoryworld(title: String) async {
    do {
      let record = try await library.createEmpty(title: title)
      await reload()
      await selectStoryworld(record.id)
    } catch {
      errorMessage = "新建世界书失败：\(error.localizedDescription)"
    }
  }

  /// 供条目导入勾选页读取源世界内容；失败返回 nil。
  public func loadDocument(_ storyworldID: UUID) async -> StoryworldDocument? {
    try? await library.load(storyworldID: storyworldID)
  }

  public func characterContractState(_ storyworldID: UUID) async throws -> CharacterContractState {
    try await library.characterContractState(storyworldID: storyworldID)
  }

  public func saveCharacterContracts(_ file: CharacterContractFile, storyworldID: UUID,
    expectedFingerprint: String?) async throws {
    try await library.saveCharacterContracts(file, storyworldID: storyworldID,
      expectedFingerprint: expectedFingerprint)
    await reload()
    if selectedStoryworldID == storyworldID { await selectStoryworld(storyworldID) }
  }

  /// 素材库方案：从源世界勾选条目深拷贝进目标世界，返回拷贝数量。
  public func importEntries(
    from sourceID: UUID,
    entryIDs: Set<String>,
    into targetID: UUID
  ) async {
    do {
      _ = try await library.importEntries(from: sourceID, entryIDs: entryIDs, into: targetID)
      await reload()
      if selectedStoryworldID == targetID {
        await selectStoryworld(targetID)
      }
    } catch {
      errorMessage = "导入条目失败：\(error.localizedDescription)"
    }
  }

  /// 素材库方案：向世界书追加手工条目（如世界基底）。
  public func addEntry(
    title: String,
    content: String,
    categoryName: String?,
    activationKeys: [String],
    alwaysActive: Bool = false,
    storyworldID: UUID
  ) async {
    let entry = LoreEntry(
      title: title,
      content: content,
      activationKeys: activationKeys,
      alwaysActive: alwaysActive
    )
    do {
      try await library.addEntry(entry, categoryName: categoryName, storyworldID: storyworldID)
      await reload()
      if selectedStoryworldID == storyworldID {
        await selectStoryworld(storyworldID)
      }
    } catch {
      errorMessage = "保存条目失败：\(error.localizedDescription)"
    }
  }

  /// 端侧提取原著节拍线：用当前配置的模型分块分析关联原著，
  /// 结果写入世界书包并刷新详情。双端可用。
  public func extractTimeline(storyworldID: UUID) async {
    guard !isExtractingTimeline else { return }
    guard let novelLibrary, let providerStore else {
      errorMessage = "当前环境不支持节拍线提取。"
      return
    }
    guard let record = records.first(where: { $0.id == storyworldID }) else {
      errorMessage = "该世界书没有关联的原著小说，无法提取节拍线。"
      return
    }
    isExtractingTimeline = true
    defer { isExtractingTimeline = false }
    do {
      guard let novel = try await associatedNovel(for: record, in: novelLibrary) else {
        errorMessage = "该世界书没有关联的原著小说，无法提取节拍线。"
        return
      }
      guard let profile = try await providerStore.list().first else {
        errorMessage = "请先在“模型设置”中添加模型。"
        return
      }
      let provider = try await providerStore.makeProvider(profileID: profile.id)
      let timeline = try await StoryTimelineExtractor.extract(
        document: novel.document,
        provider: provider
      )
      try await library.saveTimeline(timeline, storyworldID: storyworldID)
      await selectStoryworld(storyworldID)
    } catch is CancellationError {
      return
    } catch {
      errorMessage = "提取节拍线失败：\(ProviderErrorMessage.message(for: error))"
    }
  }

  public func importFiles(from urls: [URL], associateWith novel: NovelLibraryRecord) async {
    await importFiles(
      from: urls,
      target: associationTarget(for: novel),
      sourceReference: sourceReference(for: novel)
    )
  }

  public func importStandaloneFiles(from urls: [URL]) async {
    await importFiles(from: urls, target: nil, sourceReference: nil)
  }

  private func importFiles(
    from urls: [URL],
    target: StoryworldAssociationTarget?,
    sourceReference: StoryworldSourceReference?
  ) async {
    guard !urls.isEmpty else { return }
    isWorking = true
    defer { isWorking = false }

    for (index, url) in urls.enumerated() {
      let hasAccess = url.startAccessingSecurityScopedResource()
      defer {
        if hasAccess { url.stopAccessingSecurityScopedResource() }
      }
      do {
        let record: StoryworldLibraryRecord
        switch url.pathExtension.lowercased() {
        case StoryworldPackageLayout.pathExtension:
          record = try await library.importPackage(from: url, associateWith: target)
        case "lorebook", "json":
          record = try await library.importLorebook(
            from: url,
            sourceReference: sourceReference,
            associateWith: target
          )
        default:
          throw LorebookImportError.unsupportedExtension
        }
        selectedStoryworldID = record.id
      } catch let StoryworldLibraryError.conflictingStoryworld(
        storyworldID,
        localRevision,
        importedRevision
      ) {
        pendingConflict = PendingConflict(
          sourceURL: url,
          target: target,
          storyworldID: storyworldID,
          localRevision: localRevision,
          importedRevision: importedRevision,
          skippedCount: urls.count - index - 1
        )
        break
      } catch {
        let skippedCount = urls.count - index - 1
        let skippedMessage = skippedCount > 0
          ? "；其余 \(skippedCount) 个文件本次未导入，可重新导入。"
          : ""
        errorMessage =
          "无法导入《\(url.lastPathComponent)》：\(error.localizedDescription)\(skippedMessage)"
        break
      }
    }
    await reload()
    if let selectedStoryworldID {
      await selectStoryworld(selectedStoryworldID)
    }
  }

  public func resolvePendingConflict(with policy: StoryworldImportConflictPolicy) {
    guard let conflict = pendingConflict else { return }
    pendingConflict = nil
    isWorking = true
    Task {
      defer { isWorking = false }
      let hasAccess = conflict.sourceURL.startAccessingSecurityScopedResource()
      defer {
        if hasAccess { conflict.sourceURL.stopAccessingSecurityScopedResource() }
      }
      do {
        let record = try await library.importPackage(
          from: conflict.sourceURL,
          conflictPolicy: policy,
          associateWith: conflict.target
        )
        selectedStoryworldID = record.id
        await reload()
        await selectStoryworld(record.id)
      } catch {
        errorMessage = "处理同名世界书失败：\(error.localizedDescription)"
      }
    }
  }

  private func associatedNovel(
    for record: StoryworldLibraryRecord,
    in library: NovelLibrary
  ) async throws -> NovelLibraryRecord? {
    let novels = try await library.list()
    if let explicit = novels.first(where: { record.associatedDocumentIDs.contains($0.id) }) {
      return explicit
    }
    guard let contentHash = record.manifest.sourceReference?.contentHash else { return nil }
    return novels.first { $0.document.contentHash == contentHash }
  }

  public func associate(_ storyworldID: UUID, with novel: NovelLibraryRecord) async {
    do {
      try await library.associate(
        storyworldID: storyworldID,
        with: associationTarget(for: novel)
      )
      await reload()
    } catch {
      errorMessage = "关联世界书失败：\(error.localizedDescription)"
    }
  }

  public func removeAssociation(_ storyworldID: UUID, from documentID: UUID) async {
    do {
      try await library.removeAssociation(
        storyworldID: storyworldID,
        documentID: documentID
      )
      await reload()
    } catch {
      errorMessage = "解除关联失败：\(error.localizedDescription)"
    }
  }

  public func prepareExport(storyworldID: UUID) async {
    do {
      guard let record = records.first(where: { $0.id == storyworldID }) else {
        throw StoryworldLibraryError.recordNotFound(storyworldID)
      }
      let url = try await library.managedPackageURL(storyworldID: storyworldID)
      exportDocument = StoryworldExportDocument(
        package: try FileWrapper(url: url, options: .immediate)
      )
      exportFileName = safeFileName(record.manifest.title) + ".storyworld"
      isExporterPresented = true
    } catch {
      errorMessage = "准备导出失败：\(error.localizedDescription)"
    }
  }

  public func handleExportCompletion(_ result: Result<URL, any Error>) {
    if case .failure(let error) = result {
      errorMessage = "导出失败：\(error.localizedDescription)"
    }
    exportDocument = nil
  }

  private func associationTarget(for novel: NovelLibraryRecord) -> StoryworldAssociationTarget {
    StoryworldAssociationTarget(
      documentID: novel.id,
      contentHash: novel.document.contentHash
    )
  }

  private func sourceReference(for novel: NovelLibraryRecord) -> StoryworldSourceReference {
    StoryworldSourceReference(
      contentHash: novel.document.contentHash,
      sourceFormat: novel.document.sourceFormat.rawValue,
      sourceFileName: novel.document.sourceFileName,
      title: novel.document.title
    )
  }

  private func safeFileName(_ value: String) -> String {
    let invalid = CharacterSet(charactersIn: "/\\:")
    let value = value.components(separatedBy: invalid).joined(separator: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? "故事世界" : value
  }
}

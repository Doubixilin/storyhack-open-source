import DirectoryJournalCore
import Foundation

public enum StoryworldImportConflictPolicy: Equatable, Sendable {
  case reject
  case replaceWithBackup
  case importAsCopy
}

public struct StoryworldAssociationTarget: Codable, Equatable, Sendable {
  public let documentID: UUID
  public let contentHash: String

  public init(documentID: UUID, contentHash: String) {
    self.documentID = documentID
    self.contentHash = contentHash
  }
}

public struct StoryworldAssociation: Codable, Equatable, Identifiable, Sendable {
  public var id: String { "\(storyworldID.uuidString):\(documentID.uuidString)" }
  public let storyworldID: UUID
  public let documentID: UUID
  public let documentContentHash: String
  public let associatedAt: Date

  public init(
    storyworldID: UUID,
    documentID: UUID,
    documentContentHash: String,
    associatedAt: Date = Date()
  ) {
    self.storyworldID = storyworldID
    self.documentID = documentID
    self.documentContentHash = documentContentHash
    self.associatedAt = associatedAt
  }

  enum CodingKeys: String, CodingKey {
    case storyworldID = "storyworld_id"
    case documentID = "document_id"
    case documentContentHash = "document_content_hash"
    case associatedAt = "associated_at"
  }
}

public struct StoryworldLibraryRecord: Equatable, Identifiable, Sendable {
  public var id: UUID { manifest.storyworldID }
  public let manifest: StoryworldManifest
  public let lorebookEntryCount: Int
  public let associatedDocumentIDs: [UUID]

  public init(
    manifest: StoryworldManifest,
    lorebookEntryCount: Int,
    associatedDocumentIDs: [UUID] = []
  ) {
    self.manifest = manifest
    self.lorebookEntryCount = lorebookEntryCount
    self.associatedDocumentIDs = associatedDocumentIDs
  }
}

public struct StoryworldDocument: Equatable, Sendable {
  public let manifest: StoryworldManifest
  public let lorebook: Lorebook
  /// 可选产物：原著节拍线
  public let timeline: StoryTimeline?
  /// 可选产物：原著主线（正史模式剧情锚）
  public let plotline: StoryPlotline?
  /// 可选产物：素材题材与节点场景映射
  public let materialProfile: MaterialProfile?
  public let characterContracts: CharacterContractFile?

  public init(
    manifest: StoryworldManifest,
    lorebook: Lorebook,
    timeline: StoryTimeline? = nil,
    plotline: StoryPlotline? = nil,
    materialProfile: MaterialProfile? = nil,
    characterContracts: CharacterContractFile? = nil
  ) {
    self.manifest = manifest
    self.lorebook = lorebook
    self.timeline = timeline
    self.plotline = plotline
    self.materialProfile = materialProfile
    self.characterContracts = characterContracts
  }
}

public enum StoryworldLibraryError: Error, LocalizedError {
  case recordNotFound(UUID)
  case conflictingStoryworld(UUID, localRevision: Int, importedRevision: Int)
  case destinationExists(String)
  case unsafePackageEntry(String)
  case tooManyPackageEntries(Int)
  case packageTooLarge(Int64)
  case invalidAssociation

  public var errorDescription: String? {
    switch self {
    case .recordNotFound(let id):
      "没有找到 Storyworld：\(id.uuidString)"
    case .conflictingStoryworld(let id, let localRevision, let importedRevision):
      "Storyworld \(id.uuidString) 已存在（本机修订 \(localRevision)，导入修订 \(importedRevision)）"
    case .destinationExists(let path):
      "导出目标已存在：\(path)"
    case .unsafePackageEntry(let path):
      "Storyworld 文档包含不安全的文件：\(path)"
    case .tooManyPackageEntries(let maximum):
      "Storyworld 文档超过 \(maximum) 个文件限制"
    case .packageTooLarge(let maximum):
      "Storyworld 文档超过 \(maximum) 字节限制"
    case .invalidAssociation:
      "小说关联缺少有效的内容指纹"
    }
  }
}

/// Owns validated app-managed Storyworld copies. External files are never used
/// in place, and replacement always moves the previous copy into Backups first.
public actor StoryworldLibrary {
  public static let maximumPackageEntryCount = 20_000
  public static let maximumPackageByteCount: Int64 = 1_024 * 1_024 * 1_024

  public static var defaultRootURL: URL {
    let base =
      FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first ?? FileManager.default.temporaryDirectory
    return
      base
      .appendingPathComponent("StoryhackCommunity", isDirectory: true)
      .appendingPathComponent("Storyworlds", isDirectory: true)
  }

  private struct AssociationStore: Codable {
    var associations: [StoryworldAssociation]
  }

  private let rootURL: URL
  private let fileManager: FileManager
  private let validator: StoryworldPackageValidator

  public init(
    rootURL: URL = StoryworldLibrary.defaultRootURL,
    fileManager: FileManager = .default
  ) {
    self.rootURL = rootURL
    self.fileManager = fileManager
    validator = StoryworldPackageValidator(fileManager: fileManager)
  }

  /// 最近一次 list() 跳过的损坏记录诊断；健康记录照常列出
  public private(set) var listDiagnostics: [String] = []

  public func list() throws -> [StoryworldLibraryRecord] {
    return try withPackageAccess {
      try ensureDirectories()
      let associations = try loadAssociations()
      let children = try fileManager.contentsOfDirectory(
        at: packagesURL,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
      )

      var diagnostics: [String] = []
      let records = children.compactMap { child -> StoryworldLibraryRecord? in
        guard child.pathExtension.lowercased() == StoryworldPackageLayout.pathExtension else {
          return nil
        }
        do {
          let document = try loadDocument(at: child)
          return StoryworldLibraryRecord(
            manifest: document.manifest,
            lorebookEntryCount: document.lorebook.entries.count,
            associatedDocumentIDs: associations
              .filter { $0.storyworldID == document.manifest.storyworldID }
              .map(\.documentID)
          )
        } catch {
          // 单个世界书包损坏不拖垮整个列表；包保留在盘上，等待人工处理
          diagnostics.append("世界书包「\(child.lastPathComponent)」读取失败：\(error.localizedDescription)")
          return nil
        }
      }
      .sorted { lhs, rhs in
        if lhs.manifest.modifiedAt == rhs.manifest.modifiedAt {
          return lhs.manifest.title.localizedStandardCompare(rhs.manifest.title) == .orderedAscending
        }
        return lhs.manifest.modifiedAt > rhs.manifest.modifiedAt
      }
      listDiagnostics = diagnostics
      return records
    }
  }

  public func load(storyworldID: UUID) throws -> StoryworldDocument {
    return try withPackageAccess {
      let url = packageURL(for: storyworldID)
      guard fileManager.fileExists(atPath: url.path) else {
        throw StoryworldLibraryError.recordNotFound(storyworldID)
      }
      return try loadDocument(at: url)
    }
  }

  /// 写入（或覆盖）包内可选的原著节拍线产物。
  public func saveTimeline(_ timeline: StoryTimeline, storyworldID: UUID) throws {
    return try withPackageAccess {
      let url = packageURL(for: storyworldID)
      guard fileManager.fileExists(atPath: url.path) else {
        throw StoryworldLibraryError.recordNotFound(storyworldID)
      }
      _ = try validator.validate(at: url)
      try StoryworldCoding.makeEncoder().encode(timeline).write(
        to: url.appendingPathComponent(StoryworldPackageLayout.timeline),
        options: .atomic
      )
    }
  }

  /// 写入（或覆盖）包内可选的素材检索配置。
  public func saveMaterialProfile(_ profile: MaterialProfile, storyworldID: UUID) throws {
    return try withPackageAccess {
      let url = packageURL(for: storyworldID)
      guard fileManager.fileExists(atPath: url.path) else {
        throw StoryworldLibraryError.recordNotFound(storyworldID)
      }
      _ = try validator.validate(at: url)
      try StoryworldCoding.makeEncoder().encode(profile).write(
        to: url.appendingPathComponent(StoryworldPackageLayout.materialProfile),
        options: .atomic
      )
    }
  }

  @discardableResult
  public func importPackage(
    from sourceURL: URL,
    conflictPolicy: StoryworldImportConflictPolicy = .reject,
    associateWith target: StoryworldAssociationTarget? = nil
  ) throws -> StoryworldLibraryRecord {
    return try withPackageAccess {
      try ensureDirectories()
      try validatePackageTree(at: sourceURL)
      let sourceDocument = try loadDocument(at: sourceURL)
      let originalID = sourceDocument.manifest.storyworldID
      let existingURL = packageURL(for: originalID)
      let hasConflict = fileManager.fileExists(atPath: existingURL.path)

      if hasConflict, conflictPolicy == .reject {
        let local = try loadDocument(at: existingURL)
        throw StoryworldLibraryError.conflictingStoryworld(
          originalID,
          localRevision: local.manifest.revision,
          importedRevision: sourceDocument.manifest.revision
        )
      }

      let stagingURL = packagesURL.appendingPathComponent(
        ".staging-\(UUID().uuidString).storyworld",
        isDirectory: true
      )
      defer {
        if fileManager.fileExists(atPath: stagingURL.path) {
          try? fileManager.removeItem(at: stagingURL)
        }
      }
      try fileManager.copyItem(at: sourceURL, to: stagingURL)
      try removeRuntimeRecaps(from: stagingURL)

      if hasConflict, conflictPolicy == .importAsCopy {
        _ = try rewriteStagedPackageAsCopy(
          at: stagingURL,
          sourceDocument: sourceDocument
        )
      }

      try validatePackageTree(at: stagingURL)
      let stagedDocument = try loadDocument(at: stagingURL)
      let finalURL = packageURL(for: stagedDocument.manifest.storyworldID)

      if hasConflict, conflictPolicy == .replaceWithBackup {
        try replaceWithBackup(stagingURL: stagingURL, finalURL: existingURL)
      } else {
        guard !fileManager.fileExists(atPath: finalURL.path) else {
          let local = try loadDocument(at: finalURL)
          throw StoryworldLibraryError.conflictingStoryworld(
            stagedDocument.manifest.storyworldID,
            localRevision: local.manifest.revision,
            importedRevision: stagedDocument.manifest.revision
          )
        }
        try fileManager.moveItem(at: stagingURL, to: finalURL)
      }

      if let target {
        try saveAssociation(storyworldID: stagedDocument.manifest.storyworldID, target: target)
      }
      return try record(for: stagedDocument)
    }
  }

  @discardableResult
  public func publishGeneratedPackage(
    from candidate: URL, associateWith target: StoryworldAssociationTarget
  ) async throws -> StoryworldLibraryRecord {
    try ensureDirectories()
    try validatePackageTree(at: candidate)
    let incoming = try loadDocument(at: candidate)
    let revision = try GeneratedPackageRevision.load(at: candidate)
    guard incoming.manifest.sourceReference?.contentHash == target.contentHash,
      try GeneratedPackageRevision.make(at: candidate, inputFingerprint: revision.inputFingerprint) == revision
    else { throw GeneratedPackageError.invalidRevision }
    let live = packageURL(for: incoming.manifest.storyworldID)
    if !fileManager.fileExists(atPath: live.path) {
      return try importPackage(from: candidate, associateWith: target)
    }
    try validatePackageTree(at: live)
    let runtime = await StoryworldRuntimeStoreRegistry.shared.store(forPackageURL: live)
    try await runtime.updateGeneratedPackage(from: candidate, libraryRoot: rootURL)
    let associations = try loadAssociations()
    if !associations.contains(where: { $0.storyworldID == incoming.manifest.storyworldID
      && $0.documentID == target.documentID && $0.documentContentHash == target.contentHash }) {
      try saveAssociation(storyworldID: incoming.manifest.storyworldID, target: target)
    }
    return try record(for: loadDocument(at: live))
  }

  @discardableResult
  public func importLorebook(
    from sourceURL: URL,
    sourceReference: StoryworldSourceReference? = nil,
    associateWith target: StoryworldAssociationTarget? = nil
  ) throws -> StoryworldLibraryRecord {
    let lorebook = try LorebookImporter().load(from: sourceURL)
    return try create(
      lorebook: lorebook,
      sourceReference: sourceReference,
      associateWith: target
    )
  }

  public func characterContractState(storyworldID: UUID) throws -> CharacterContractState {
    try withPackageAccess {
      let package = packageURL(for: storyworldID)
      _ = try validator.validate(at: package)
      return try CharacterContractStorage.read(at: package)
    }
  }

  public func saveCharacterContracts(_ file: CharacterContractFile, storyworldID: UUID,
    expectedFingerprint: String?) async throws {
    let package = packageURL(for: storyworldID)
    let runtime = await StoryworldRuntimeStoreRegistry.shared.store(forPackageURL: package)
    try await runtime.saveCharacterContracts(file, libraryRoot: rootURL,
      expectedFingerprint: expectedFingerprint)
  }

  @discardableResult
  public func importLegacyWorldbook(
    from directoryURL: URL,
    sourceReference: StoryworldSourceReference? = nil,
    associateWith target: StoryworldAssociationTarget? = nil
  ) async throws -> LegacyWorldbookMigrationReceipt {
    let migration = try LegacyWorldbookImporter(fileManager: fileManager).load(
      from: directoryURL
    )
    let record = try create(
      lorebook: migration.lorebook,
      title: migration.title,
      sourceReference: sourceReference
    )
    let managedURL = packageURL(for: record.id)
    do {
      let originalsURL = managedURL
        .appendingPathComponent("legacy", isDirectory: true)
        .appendingPathComponent("originals", isDirectory: true)
      for source in migration.sourceFiles {
        let destination = originalsURL.appendingPathComponent(source.relativePath)
        try fileManager.createDirectory(
          at: destination.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: source.url, to: destination)
      }
      try validatePackageTree(at: managedURL)
      let runtime = StoryworldRuntimeStore(packageURL: managedURL)
      let playthrough = try await runtime.createPlaythrough(
        title: "旧版迁移",
        initialState: migration.initialState
      )
      if let target {
        try saveAssociation(storyworldID: record.id, target: target)
      }
      return LegacyWorldbookMigrationReceipt(
        record: try self.record(for: try loadDocument(at: managedURL)),
        playthrough: playthrough,
        preservedFileCount: migration.sourceFiles.count
      )
    } catch {
      try? fileManager.removeItem(at: managedURL)
      throw error
    }
  }

  @discardableResult
  public func create(
    lorebook: Lorebook,
    title: String? = nil,
    sourceReference: StoryworldSourceReference? = nil,
    associateWith target: StoryworldAssociationTarget? = nil
  ) throws -> StoryworldLibraryRecord {
    return try withPackageAccess {
      try LorebookValidator().validate(lorebook)
      try ensureDirectories()
      let manifest = StoryworldManifest(
        title: title ?? lorebook.title,
        sourceReference: sourceReference
      )
      let stagingURL = packagesURL.appendingPathComponent(
        ".staging-\(UUID().uuidString).storyworld",
        isDirectory: true
      )
      defer {
        if fileManager.fileExists(atPath: stagingURL.path) {
          try? fileManager.removeItem(at: stagingURL)
        }
      }
      try writePackage(manifest: manifest, lorebook: lorebook, to: stagingURL)
      _ = try validator.validate(at: stagingURL)
      try fileManager.moveItem(at: stagingURL, to: packageURL(for: manifest.storyworldID))
      if let target {
        try saveAssociation(storyworldID: manifest.storyworldID, target: target)
      }
      return StoryworldLibraryRecord(
        manifest: manifest,
        lorebookEntryCount: lorebook.entries.count,
        associatedDocumentIDs: target.map { [$0.documentID] } ?? []
      )
    }
  }

  /// 新建空白世界书（素材库与融合世界方案的第一步）：无来源小说、空 Lorebook，
  /// 之后通过 `importEntries` / `addEntry` 逐步填充。
  @discardableResult
  public func createEmpty(title: String) throws -> StoryworldLibraryRecord {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return try create(lorebook: Lorebook(title: trimmed), title: trimmed)
  }

  /// 从源世界勾选条目深拷贝进目标世界：条目 ID 重新生成，分类按名称合并，
  /// 标题撞名时自动加后缀。不做任何引用或同步，拷贝后两边各自演化。
  @discardableResult
  public func importEntries(
    from sourceID: UUID,
    entryIDs: Set<String>,
    into targetID: UUID
  ) throws -> Int {
    return try withPackageAccess {
      let source = try load(storyworldID: sourceID)
      let selected = source.lorebook.entries.filter { entryIDs.contains($0.id) }
      guard !selected.isEmpty else { return 0 }
      var mutated = try load(storyworldID: targetID).lorebook
      var existingTitles = Set(mutated.entries.map(\.title))
      for entry in selected {
        var copy = entry
        copy = LoreEntry(
          title: uniqueTitle(entry.title, within: existingTitles),
          content: entry.content,
          activationKeys: entry.activationKeys,
          enabled: entry.enabled,
          alwaysActive: entry.alwaysActive,
          hidden: entry.hidden,
          categoryID: entry.categoryID.flatMap { sourceCategoryID in
            source.lorebook.categories.first { $0.id == sourceCategoryID }.map { sourceCategory in
              mergedCategoryID(named: sourceCategory.name, into: &mutated)
            }
          }
        )
        existingTitles.insert(copy.title)
        mutated.entries.append(copy)
      }
      try saveLorebook(mutated, storyworldID: targetID)
      return selected.count
    }
  }

  /// 追加单条手工条目（如世界基底）。categoryName 为空则不入分类。
  public func addEntry(
    _ entry: LoreEntry,
    categoryName: String?,
    storyworldID: UUID
  ) throws {
    return try withPackageAccess {
      var lorebook = try load(storyworldID: storyworldID).lorebook
      var stored = entry
      if let categoryName,
        !categoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        stored.categoryID = mergedCategoryID(named: categoryName, into: &lorebook)
      }
      lorebook.entries.append(stored)
      try saveLorebook(lorebook, storyworldID: storyworldID)
    }
  }

  private func uniqueTitle(_ title: String, within existing: Set<String>) -> String {
    guard existing.contains(title) else { return title }
    var suffix = 2
    while existing.contains("\(title) (\(suffix))") { suffix += 1 }
    return "\(title) (\(suffix))"
  }

  /// 按名称找到或新建分类，返回目标 Lorebook 内的分类 ID。
  private func mergedCategoryID(named name: String, into lorebook: inout Lorebook) -> String {
    if let existing = lorebook.categories.first(where: { $0.name == name }) {
      return existing.id
    }
    let category = LorebookCategory(name: name)
    lorebook.categories.append(category)
    return category.id
  }

  /// 覆盖包内 Lorebook 并推进修订号。游玩态（会话/存档/分支）不含条目引用，
  /// 无需联动。两个文件作为一次日志事务写入：两次单文件原子写之间掉电
  /// 会得到「新内容 + 旧修订号」，恢复时按备份回滚到更新前状态。
  private func saveLorebook(_ lorebook: Lorebook, storyworldID: UUID) throws {
    return try withPackageAccess {
      let url = packageURL(for: storyworldID)
      guard fileManager.fileExists(atPath: url.path) else {
        throw StoryworldLibraryError.recordNotFound(storyworldID)
      }
      try LorebookValidator().validate(lorebook)
      var manifest = try validator.validate(at: url)
      manifest.revision += 1
      manifest.modifiedAt = Date()
      try DirectoryReplacementJournal(rootURL: rootURL, fileManager: fileManager)
        .performFileUpdates([
          (
            url.appendingPathComponent(manifest.content.lorebookEntry),
            StoryworldCoding.makeEncoder().encode(lorebook)
          ),
          (
            url.appendingPathComponent(StoryworldPackageLayout.manifest),
            StoryworldCoding.makeEncoder().encode(manifest)
          ),
        ])
    }
  }

  public func associate(
    storyworldID: UUID,
    with target: StoryworldAssociationTarget
  ) throws {
    guard fileManager.fileExists(atPath: packageURL(for: storyworldID).path) else {
      throw StoryworldLibraryError.recordNotFound(storyworldID)
    }
    try saveAssociation(storyworldID: storyworldID, target: target)
  }

  public func removeAssociation(storyworldID: UUID, documentID: UUID) throws {
    var associations = try loadAssociations()
    associations.removeAll {
      $0.storyworldID == storyworldID && $0.documentID == documentID
    }
    try writeAssociations(associations)
  }

  public func listAssociated(
    with target: StoryworldAssociationTarget
  ) throws -> [StoryworldLibraryRecord] {
    let associations = try loadAssociations()
    let explicitlyAssociatedIDs = Set(
      associations.lazy
        .filter {
          $0.documentID == target.documentID
            || $0.documentContentHash == target.contentHash
        }
        .map(\.storyworldID)
    )
    return try list().filter { record in
      explicitlyAssociatedIDs.contains(record.id)
        || record.manifest.sourceReference?.contentHash == target.contentHash
    }
  }

  @discardableResult
  public func exportPackage(
    storyworldID: UUID,
    to destination: URL
  ) throws -> URL {
    return try withPackageAccess {
      let document = try load(storyworldID: storyworldID)
      let exportURL: URL
      if destination.pathExtension.lowercased() == StoryworldPackageLayout.pathExtension {
        exportURL = destination
      } else {
        exportURL = destination.appendingPathComponent(
          safeFileName(document.manifest.title) + ".storyworld",
          isDirectory: true
        )
      }
      guard !fileManager.fileExists(atPath: exportURL.path) else {
        throw StoryworldLibraryError.destinationExists(exportURL.path)
      }
      try fileManager.createDirectory(
        at: exportURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      do {
        try fileManager.copyItem(at: packageURL(for: storyworldID), to: exportURL)
        try removeRuntimeRecaps(from: exportURL)
        return exportURL
      } catch {
        try? fileManager.removeItem(at: exportURL)
        throw error
      }
    }
  }

  public func listBackups(storyworldID: UUID) throws -> [URL] {
    let directory = backupDirectory(for: storyworldID)
    guard fileManager.fileExists(atPath: directory.path) else { return [] }
    return try fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    )
    .filter { $0.pathExtension.lowercased() == StoryworldPackageLayout.pathExtension }
    .sorted { $0.lastPathComponent > $1.lastPathComponent }
  }

  public func managedPackageURL(storyworldID: UUID) throws -> URL {
    return try withPackageAccess {
      let url = packageURL(for: storyworldID)
      guard fileManager.fileExists(atPath: url.path) else {
        throw StoryworldLibraryError.recordNotFound(storyworldID)
      }
      return url
    }
  }

  /// 删除世界书（反馈 #2）。不做硬删除：包移入 Backups/<id>/deleted-<时间戳>.storyworld，
  /// 关联记录一并清理；需要恢复时从备份目录重新导入即可。
  public func delete(storyworldID: UUID) throws {
    return try withPackageAccess {
      let url = packageURL(for: storyworldID)
      guard fileManager.fileExists(atPath: url.path) else {
        throw StoryworldLibraryError.recordNotFound(storyworldID)
      }
      try ensureDirectories()
      let backupDirectory = backupDirectory(for: storyworldID)
      try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
      let formatter = DateFormatter()
      formatter.dateFormat = "yyyyMMdd-HHmmss"
      let destination = backupDirectory.appendingPathComponent(
        "deleted-\(formatter.string(from: Date())).storyworld",
        isDirectory: true
      )
      try fileManager.moveItem(at: url, to: destination)
      var associations = try loadAssociations()
      associations.removeAll { $0.storyworldID == storyworldID }
      try writeAssociations(associations)
    }
  }

  private var packagesURL: URL {
    rootURL.appendingPathComponent("Packages", isDirectory: true)
  }

  private var backupsURL: URL {
    rootURL.appendingPathComponent("Backups", isDirectory: true)
  }

  private var associationsURL: URL {
    rootURL.appendingPathComponent("associations.json")
  }

  private func withPackageAccess<T>(_ operation: () throws -> T) throws -> T {
    let journal = DirectoryReplacementJournal(rootURL: rootURL, fileManager: fileManager)
    return try journal.withExclusiveAccess {
      try journal.recoverPendingReplacements()
      try journal.recoverPendingFileUpdates()
      return try operation()
    }
  }

  private func ensureDirectories() throws {
    try fileManager.createDirectory(at: packagesURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: backupsURL, withIntermediateDirectories: true)
  }

  private func packageURL(for storyworldID: UUID) -> URL {
    packagesURL.appendingPathComponent(
      storyworldID.uuidString.lowercased() + ".storyworld",
      isDirectory: true
    )
  }

  private func backupDirectory(for storyworldID: UUID) -> URL {
    backupsURL.appendingPathComponent(storyworldID.uuidString.lowercased(), isDirectory: true)
  }

  private func loadDocument(at packageURL: URL) throws -> StoryworldDocument {
    let manifest = try validator.validate(at: packageURL)
    let lorebookURL = packageURL.appendingPathComponent(manifest.content.lorebookEntry)
    let lorebook = try StoryworldCoding.makeDecoder().decode(
      Lorebook.self,
      from: Data(contentsOf: lorebookURL, options: [.mappedIfSafe])
    )
    return StoryworldDocument(
      manifest: manifest,
      lorebook: lorebook,
      timeline: loadTimeline(at: packageURL),
      plotline: loadPlotline(at: packageURL),
      materialProfile: loadMaterialProfile(at: packageURL),
      characterContracts: loadCharacterContracts(at: packageURL)
    )
  }

  private func loadCharacterContracts(at packageURL: URL) -> CharacterContractFile? {
    guard let state = try? CharacterContractStorage.read(at: packageURL), state.fingerprint != nil
    else { return nil }
    return state.file
  }

  /// 可选产物，缺失或损坏都不影响文档加载。
  private func loadTimeline(at packageURL: URL) -> StoryTimeline? {
    let url = packageURL.appendingPathComponent(StoryworldPackageLayout.timeline)
    guard fileManager.fileExists(atPath: url.path),
      let data = try? Data(contentsOf: url, options: [.mappedIfSafe])
    else { return nil }
    return try? StoryworldCoding.makeDecoder().decode(StoryTimeline.self, from: data)
  }

  /// 可选产物，缺失或损坏都不影响文档加载。
  private func loadPlotline(at packageURL: URL) -> StoryPlotline? {
    let url = packageURL.appendingPathComponent(StoryworldPackageLayout.plotline)
    guard fileManager.fileExists(atPath: url.path),
      let data = try? Data(contentsOf: url, options: [.mappedIfSafe])
    else { return nil }
    return try? StoryworldCoding.makeDecoder().decode(StoryPlotline.self, from: data)
  }

  /// 可选产物，缺失或损坏都不影响文档加载。
  private func loadMaterialProfile(at packageURL: URL) -> MaterialProfile? {
    let url = packageURL.appendingPathComponent(StoryworldPackageLayout.materialProfile)
    guard fileManager.fileExists(atPath: url.path),
      let data = try? Data(contentsOf: url, options: [.mappedIfSafe])
    else { return nil }
    return try? StoryworldCoding.makeDecoder().decode(MaterialProfile.self, from: data)
  }

  private func record(for document: StoryworldDocument) throws -> StoryworldLibraryRecord {
    let associations = try loadAssociations()
    return StoryworldLibraryRecord(
      manifest: document.manifest,
      lorebookEntryCount: document.lorebook.entries.count,
      associatedDocumentIDs: associations
        .filter { $0.storyworldID == document.manifest.storyworldID }
        .map(\.documentID)
    )
  }

  private func writePackage(
    manifest: StoryworldManifest,
    lorebook: Lorebook,
    to packageURL: URL
  ) throws {
    let lorebookDirectory = packageURL.appendingPathComponent(
      StoryworldPackageLayout.lorebookDirectory,
      isDirectory: true
    )
    try fileManager.createDirectory(at: lorebookDirectory, withIntermediateDirectories: true)
    try StoryworldCoding.makeEncoder().encode(manifest).write(
      to: packageURL.appendingPathComponent(StoryworldPackageLayout.manifest),
      options: [.atomic]
    )
    try StoryworldCoding.makeEncoder().encode(lorebook).write(
      to: packageURL.appendingPathComponent(manifest.content.lorebookEntry),
      options: [.atomic]
    )
  }

  private func rewriteStagedPackageAsCopy(
    at packageURL: URL,
    sourceDocument: StoryworldDocument
  ) throws -> StoryworldDocument {
    let now = Date()
    let copiedManifest = StoryworldManifest(
      storyworldID: UUID(),
      revision: 1,
      title: sourceDocument.manifest.title + " 副本",
      createdAt: now,
      modifiedAt: now,
      minimumCoreVersion: sourceDocument.manifest.minimumCoreVersion,
      sourceReference: sourceDocument.manifest.sourceReference,
      content: sourceDocument.manifest.content,
      checksums: [:]
    )
    try StoryworldCoding.makeEncoder().encode(copiedManifest).write(
      to: packageURL.appendingPathComponent(StoryworldPackageLayout.manifest),
      options: [.atomic]
    )
    try rewriteRuntimeStoryworldID(
      at: packageURL,
      from: sourceDocument.manifest.storyworldID,
      to: copiedManifest.storyworldID
    )
    return StoryworldDocument(
      manifest: copiedManifest,
      lorebook: sourceDocument.lorebook,
      timeline: sourceDocument.timeline,
      plotline: sourceDocument.plotline,
      materialProfile: sourceDocument.materialProfile,
      characterContracts: sourceDocument.characterContracts
    )
  }

  /// Runtime files contain the Storyworld identity inside every durable
  /// session address. Importing a package as a copy must update those addresses
  /// together with the manifest, otherwise the copied turns, saves and branches
  /// become unreadable due to an address mismatch.
  private func rewriteRuntimeStoryworldID(
    at packageURL: URL,
    from oldID: UUID,
    to newID: UUID
  ) throws {
    for directoryName in [
      StoryworldPackageLayout.playthroughsDirectory,
      StoryworldPackageLayout.sessionsDirectory,
    ] {
      let directory = packageURL.appendingPathComponent(directoryName, isDirectory: true)
      guard fileManager.fileExists(atPath: directory.path) else { continue }
      guard let enumerator = fileManager.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
      ) else {
        throw StoryworldLibraryError.unsafePackageEntry(directoryName)
      }
      while let url = enumerator.nextObject() as? URL {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
          throw StoryworldLibraryError.unsafePackageEntry(url.lastPathComponent)
        }
        guard values.isRegularFile == true else { continue }
        switch url.pathExtension.lowercased() {
        case "json":
          let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
          let rewritten = replacingStoryworldID(in: object, from: oldID, to: newID)
          try JSONSerialization.data(
            withJSONObject: rewritten,
            options: [.sortedKeys, .withoutEscapingSlashes]
          ).write(to: url, options: [.atomic])
        case "jsonl":
          let data = try Data(contentsOf: url)
          guard !data.isEmpty else { continue }
          guard let text = String(data: data, encoding: .utf8) else {
            throw StoryworldRuntimeError.corruptedEventLog
          }
          var rewritten = Data()
          for line in text.split(whereSeparator: { $0.isNewline }) {
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
            let value = replacingStoryworldID(in: object, from: oldID, to: newID)
            rewritten.append(
              try JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys, .withoutEscapingSlashes]
              )
            )
            rewritten.append(0x0A)
          }
          try rewritten.write(to: url, options: [.atomic])
        default:
          continue
        }
      }
    }
  }

  private func replacingStoryworldID(
    in value: Any,
    from oldID: UUID,
    to newID: UUID
  ) -> Any {
    if var object = value as? [String: Any] {
      for (key, child) in object {
        if key == "storyworld_id",
          let encoded = child as? String,
          encoded.caseInsensitiveCompare(oldID.uuidString) == .orderedSame
        {
          object[key] = newID.uuidString
        } else {
          object[key] = replacingStoryworldID(in: child, from: oldID, to: newID)
        }
      }
      return object
    }
    if let array = value as? [Any] {
      return array.map { replacingStoryworldID(in: $0, from: oldID, to: newID) }
    }
    return value
  }

  private func replaceWithBackup(stagingURL: URL, finalURL: URL) throws {
    let current = try loadDocument(at: finalURL)
    let backupURL = backupDirectory(for: current.manifest.storyworldID)
      .appendingPathComponent(
        "revision-\(current.manifest.revision)-\(UUID().uuidString.lowercased()).storyworld",
        isDirectory: true
      )
    // 带事务日志的目录替换：进程在两次移动之间被杀时，
    // 下次列库由 recoverPendingReplacements 回滚或完成
    try DirectoryReplacementJournal(rootURL: rootURL, fileManager: fileManager)
      .replaceDirectory(stagingURL: stagingURL, finalURL: finalURL, backupURL: backupURL)
  }

  private func saveAssociation(
    storyworldID: UUID,
    target: StoryworldAssociationTarget
  ) throws {
    guard !target.contentHash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw StoryworldLibraryError.invalidAssociation
    }
    var associations = try loadAssociations()
    associations.removeAll {
      $0.storyworldID == storyworldID && $0.documentID == target.documentID
    }
    associations.append(
      StoryworldAssociation(
        storyworldID: storyworldID,
        documentID: target.documentID,
        documentContentHash: target.contentHash
      )
    )
    try writeAssociations(associations)
  }

  private func loadAssociations() throws -> [StoryworldAssociation] {
    try ensureDirectories()
    guard fileManager.fileExists(atPath: associationsURL.path) else { return [] }
    return try StoryworldCoding.makeDecoder().decode(
      AssociationStore.self,
      from: Data(contentsOf: associationsURL)
    ).associations
  }

  private func writeAssociations(_ associations: [StoryworldAssociation]) throws {
    try StoryworldCoding.makeEncoder().encode(
      AssociationStore(associations: associations)
    ).write(to: associationsURL, options: [.atomic])
  }

  private func validatePackageTree(at packageURL: URL) throws {
    let rootValues = try packageURL.resourceValues(
      forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
    )
    guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
      throw StoryworldLibraryError.unsafePackageEntry(packageURL.lastPathComponent)
    }
    guard let enumerator = fileManager.enumerator(
      at: packageURL,
      includingPropertiesForKeys: [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
      ],
      options: [],
      errorHandler: { _, _ in false }
    ) else {
      throw StoryworldLibraryError.unsafePackageEntry(packageURL.lastPathComponent)
    }

    var entryCount = 0
    var byteCount: Int64 = 0
    while let entry = enumerator.nextObject() as? URL {
      entryCount += 1
      guard entryCount <= Self.maximumPackageEntryCount else {
        throw StoryworldLibraryError.tooManyPackageEntries(Self.maximumPackageEntryCount)
      }
      let values = try entry.resourceValues(
        forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
      )
      if values.isSymbolicLink == true {
        enumerator.skipDescendants()
        throw StoryworldLibraryError.unsafePackageEntry(
          entry.path.replacingOccurrences(of: packageURL.path + "/", with: "")
        )
      }
      guard values.isRegularFile == true || values.isDirectory == true else {
        throw StoryworldLibraryError.unsafePackageEntry(entry.lastPathComponent)
      }
      if values.isRegularFile == true {
        byteCount += Int64(values.fileSize ?? 0)
        guard byteCount <= Self.maximumPackageByteCount else {
          throw StoryworldLibraryError.packageTooLarge(Self.maximumPackageByteCount)
        }
      }
    }
  }

  /// recap.json 是本机运行时缓存，不属于可分享 Storyworld 数据。
  /// 导入也主动剥离，避免第三方或旧导出包把缓存带入托管副本。
  private func removeRuntimeRecaps(from packageURL: URL) throws {
    guard
      let enumerator = fileManager.enumerator(
        at: packageURL,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
      )
    else { return }
    var recapURLs: [URL] = []
    let packageComponentCount = packageURL.standardizedFileURL.pathComponents.count
    for case let url as URL in enumerator where url.lastPathComponent == "recap.json" {
      let components = Array(
        url.standardizedFileURL.pathComponents.dropFirst(packageComponentCount)
      )
      guard components.count == 5,
        components[0] == StoryworldPackageLayout.playthroughsDirectory,
        components[2] == "branches",
        components[4] == "recap.json"
      else { continue }
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
      recapURLs.append(url)
    }
    for url in recapURLs {
      try fileManager.removeItem(at: url)
    }
  }

  private func safeFileName(_ value: String) -> String {
    let invalid = CharacterSet(charactersIn: "/\\:")
    let sanitized = value.components(separatedBy: invalid).joined(separator: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return sanitized.isEmpty ? "故事世界" : sanitized
  }
}

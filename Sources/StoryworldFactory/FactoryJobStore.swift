import Foundation
import DirectoryJournalCore
import NovelDocumentCore

public enum FactoryJobStoreError: Error, Equatable, LocalizedError {
  case jobNotFound(UUID)
  case invalidWorkspacePath(String)
  case snapshotAlreadyExists(UUID)
  case unsupportedJobSchema(Int)

  public var errorDescription: String? {
    switch self {
    case .jobNotFound(let id): "没有找到工坊任务：\(id.uuidString)"
    case .invalidWorkspacePath(let path): "工坊工作区路径无效：\(path)"
    case .snapshotAlreadyExists(let id): "工坊任务快照已存在：\(id.uuidString)"
    case .unsupportedJobSchema(let version): "不支持的工坊任务版本：\(version)"
    }
  }
}

public actor FactoryJobStore {
  public static var defaultRootURL: URL {
    let base =
      FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first ?? FileManager.default.temporaryDirectory
    return
      base
      .appendingPathComponent("StoryhackCommunity", isDirectory: true)
      .appendingPathComponent("Factory", isDirectory: true)
  }

  private let rootURL: URL
  private let fileManager: FileManager
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init(
    rootURL: URL = FactoryJobStore.defaultRootURL,
    fileManager: FileManager = .default
  ) {
    self.rootURL = rootURL.standardizedFileURL
    self.fileManager = fileManager
    encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
  }

  @discardableResult
  public func create(document: NovelDocument) throws -> FactoryJob {
    try ensureRoot()
    let job = FactoryJob(
      documentID: document.id,
      sourceName: document.sourceFileName,
      sourceFormat: FactorySourceFormat(rawValue: document.sourceFormat.rawValue) ?? .text,
      sourceTitle: document.title,
      sourceContentHash: document.contentHash
    )
    let finalURL = jobDirectory(job.id)
    guard !fileManager.fileExists(atPath: finalURL.path) else {
      throw FactoryJobStoreError.snapshotAlreadyExists(job.id)
    }
    let stagingURL = rootURL.appendingPathComponent(
      ".creating-\(job.id.uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: stagingURL) }
    try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
    try writeInputSnapshot(
      document, at: stagingURL.appendingPathComponent("input", isDirectory: true))
    try write(job, to: stagingURL.appendingPathComponent("job.json"))
    try fileManager.moveItem(at: stagingURL, to: finalURL)
    return job
  }

  /// 最近一次 list() 跳过的损坏任务诊断；健康任务照常列出
  public private(set) var listDiagnostics: [String] = []

  public func list() throws -> [FactoryJob] {
    try ensureRoot()
    let children = try fileManager.contentsOfDirectory(
      at: rootURL,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )
    var diagnostics: [String] = []
    let jobs = children.compactMap { child -> FactoryJob? in
      guard child.pathExtension == "factoryjob" else { return nil }
      do {
        return try loadJob(at: child)
      } catch {
        // 单个任务包损坏不拖垮整个工坊列表；包保留在盘上，等待人工处理
        diagnostics.append("工坊任务「\(child.lastPathComponent)」读取失败：\(error.localizedDescription)")
        return nil
      }
    }.sorted { $0.updatedAt > $1.updatedAt }
    listDiagnostics = diagnostics
    return jobs
  }

  public func load(_ jobID: UUID) throws -> FactoryJob {
    let directory = jobDirectory(jobID)
    guard fileManager.fileExists(atPath: directory.path) else {
      throw FactoryJobStoreError.jobNotFound(jobID)
    }
    return try loadJob(at: directory)
  }

  /// Coordinators retain this lease across the whole operation, including
  /// worker awaits. It is separate from short library publication transactions.
  public nonisolated func acquireOperation(_ jobID: UUID) throws -> DirectoryProcessLease {
    let directory = rootURL.appendingPathComponent("\(jobID.uuidString.lowercased()).factoryjob", isDirectory: true)
    let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true,
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("job.json").path) else {
      throw FactoryJobStoreError.jobNotFound(jobID)
    }
    return try DirectoryProcessLease(directoryURL: directory)
  }

  public func save(_ job: FactoryJob) throws {
    if let configuration = job.tasteConfiguration { _ = try configuration.overrides.validated() }
    guard job.schemaVersion == FactoryJob.currentSchemaVersion else {
      throw FactoryJobStoreError.unsupportedJobSchema(job.schemaVersion)
    }
    let directory = jobDirectory(job.id)
    guard fileManager.fileExists(atPath: directory.path) else {
      throw FactoryJobStoreError.jobNotFound(job.id)
    }
    try write(job, to: directory.appendingPathComponent("job.json"))
  }

  public func inputManifest(_ jobID: UUID) throws -> FactoryInputManifest {
    try read(
      FactoryInputManifest.self,
      from: try workspaceURL(jobID: jobID, relativePath: "input/manifest.json")
    )
  }

  public func saveAnalysis(_ analysis: FactoryAnalysis, jobID: UUID) throws {
    try write(analysis, to: try workspaceURL(jobID: jobID, relativePath: "analysis.json"))
    try saveDecisions(analysis.decisions, jobID: jobID)
  }

  public func analysis(_ jobID: UUID) throws -> FactoryAnalysis? {
    try readIfPresent(
      FactoryAnalysis.self,
      from: try workspaceURL(jobID: jobID, relativePath: "analysis.json")
    )
  }

  public func saveDecisions(_ decisions: [FactoryDecision], jobID: UUID) throws {
    try write(decisions, to: try workspaceURL(jobID: jobID, relativePath: "decisions.json"))
  }

  public func decisions(_ jobID: UUID) throws -> [FactoryDecision] {
    try readIfPresent(
      [FactoryDecision].self,
      from: try workspaceURL(jobID: jobID, relativePath: "decisions.json")
    ) ?? []
  }

  public func saveValidation(_ report: FactoryValidationReport, jobID: UUID) throws {
    try write(report, to: try workspaceURL(jobID: jobID, relativePath: "validation.json"))
  }

  public func clearCandidateReports(_ jobID: UUID) throws {
    for path in ["validation.json", "preview.json"] {
      let url = try workspaceURL(jobID: jobID, relativePath: path)
      if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }
  }

  public func validation(_ jobID: UUID) throws -> FactoryValidationReport? {
    try readIfPresent(
      FactoryValidationReport.self,
      from: try workspaceURL(jobID: jobID, relativePath: "validation.json")
    )
  }

  public func saveBakeReport(_ report: FactoryBakeReport, jobID: UUID) throws {
    try write(report, to: try safeBakeReportURL(jobID))
  }

  public func bakeReport(_ jobID: UUID) throws -> FactoryBakeReport? {
    let url = try safeBakeReportURL(jobID)
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      (values.fileSize ?? Int.max) <= 4_194_304 else { throw FactoryBakeError.invalidReport }
    return try? read(FactoryBakeReport.self, from: url)
  }

  private func safeBakeReportURL(_ jobID: UUID) throws -> URL {
    let root = try workspaceURL(jobID: jobID)
    let url = root.appendingPathComponent("bake/report.json")
    guard url.resolvingSymlinksInPath().pathComponents.starts(with: root.resolvingSymlinksInPath().pathComponents),
      (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
      throw FactoryBakeError.invalidReport
    }
    return url
  }

  public func savePreview(_ preview: FactoryDiffPreview, jobID: UUID) throws {
    try write(preview, to: try workspaceURL(jobID: jobID, relativePath: "preview.json"))
  }

  public func preview(_ jobID: UUID) throws -> FactoryDiffPreview? {
    try readIfPresent(
      FactoryDiffPreview.self,
      from: try workspaceURL(jobID: jobID, relativePath: "preview.json")
    )
  }

  public func workspaceURL(jobID: UUID, relativePath: String = "") throws -> URL {
    let jobURL = jobDirectory(jobID).standardizedFileURL
    guard fileManager.fileExists(atPath: jobURL.path) else {
      throw FactoryJobStoreError.jobNotFound(jobID)
    }
    guard !relativePath.hasPrefix("/"), !relativePath.contains("\\") else {
      throw FactoryJobStoreError.invalidWorkspacePath(relativePath)
    }
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.contains("..") else {
      throw FactoryJobStoreError.invalidWorkspacePath(relativePath)
    }
    let result =
      relativePath.isEmpty
      ? jobURL : jobURL.appendingPathComponent(relativePath).standardizedFileURL
    guard result.path == jobURL.path || result.path.hasPrefix(jobURL.path + "/") else {
      throw FactoryJobStoreError.invalidWorkspacePath(relativePath)
    }
    return result
  }

  /// Converts tasks that were running when the app stopped into explicit, retryable failures.
  @discardableResult
  public func recoverInterruptedJobs(jobID: UUID? = nil) throws -> [FactoryJob] {
    var recovered: [FactoryJob] = []
    for listed in try list() where listed.stage.isRunning && (jobID == nil || listed.id == jobID) {
      let lease: DirectoryProcessLease
      do { lease = try acquireOperation(listed.id) }
      catch DirectoryProcessLockError.busy { continue }
      defer { lease.release() }
      var job = try load(listed.id)
      guard job.stage.isRunning else { continue }
      job.stage = .failed
      job.failure = FactoryFailure(
        category: .interrupted,
        message: "上次运行在后台任务完成前中断，可以从输入快照重试。",
        retryable: true
      )
      job.updatedAt = Date()
      try save(job)
      recovered.append(job)
    }
    return recovered
  }

  private func writeInputSnapshot(_ document: NovelDocument, at inputURL: URL) throws {
    let chaptersURL = inputURL.appendingPathComponent("chapters", isDirectory: true)
    try fileManager.createDirectory(at: chaptersURL, withIntermediateDirectories: true)
    let manifest = FactoryInputManifest(document: document)
    try write(manifest, to: inputURL.appendingPathComponent("manifest.json"))
    for (chapter, descriptor) in zip(document.chapters, manifest.chapters) {
      let destination = inputURL.appendingPathComponent(descriptor.relativePath)
      try Data(chapter.content.utf8).write(to: destination, options: .atomic)
    }
    if let enumerator = fileManager.enumerator(
      at: inputURL,
      includingPropertiesForKeys: [.isDirectoryKey]
    ) {
      for case let url as URL in enumerator {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        try? fileManager.setAttributes(
          [.posixPermissions: isDirectory ? 0o555 : 0o444],
          ofItemAtPath: url.path
        )
      }
    }
    try? fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: inputURL.path)
  }

  private func ensureRoot() throws {
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
  }

  private func jobDirectory(_ id: UUID) -> URL {
    rootURL.appendingPathComponent("\(id.uuidString.lowercased()).factoryjob", isDirectory: true)
  }

  private func loadJob(at directory: URL) throws -> FactoryJob {
    let job = try read(FactoryJob.self, from: directory.appendingPathComponent("job.json"))
    guard job.schemaVersion == FactoryJob.currentSchemaVersion else {
      throw FactoryJobStoreError.unsupportedJobSchema(job.schemaVersion)
    }
    return job
  }

  private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try encoder.encode(value).write(to: url, options: .atomic)
  }

  private func read<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
    try decoder.decode(type, from: Data(contentsOf: url))
  }

  private func readIfPresent<Value: Decodable>(
    _ type: Value.Type,
    from url: URL
  ) throws -> Value? {
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    return try read(type, from: url)
  }
}

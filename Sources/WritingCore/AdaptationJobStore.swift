import DirectoryJournalCore
import Foundation
import NovelDocumentCore

/// One independent source snapshot and any number of author-owned directions.
/// Reuses the writing approval types and the shared file transaction journal.
/// No model executor receives a mutator for the direction contract.
public actor AdaptationJobStore {
  public static let shared = AdaptationJobStore()
  public static var defaultRootURL: URL {
    (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory).appendingPathComponent("StoryhackCommunity/Adaptations", isDirectory: true)
  }
  public let rootURL: URL
  let journal: DirectoryReplacementJournal
  let files = FileManager.default
  public private(set) var listDiagnostics: [String] = []

  public init(rootURL: URL = AdaptationJobStore.defaultRootURL) {
    self.rootURL = rootURL.standardizedFileURL
    journal = .init(rootURL: rootURL)
  }

  /// Copy first and parse the copy, so moving/deleting the reader book later
  /// cannot change a task. The original EPUB bytes are retained unchanged.
  @discardableResult
  public func create(from sourceURL: URL) throws -> AdaptationJob {
    try locked {
      let name = sourceURL.lastPathComponent
      guard safeName(name), !linked(sourceURL) else { throw AdaptationError.invalidSource }
      let bytes = try readData(sourceURL, maximum: 100 * 1_048_576)
      let staging = rootURL.appendingPathComponent(".creating-" + UUID().uuidString, isDirectory: true)
      defer { try? files.removeItem(at: staging) }
      let source = staging.appendingPathComponent("input/source/" + name)
      try write(bytes, to: source)
      let document = try NovelDocumentParser().parse(at: source)
      return try finishCreation(document, originalHash: AdaptationCoding.hash(bytes), staging: staging)
    }
  }

  /// For original-writing plans and synthetic sources. There is deliberately
  /// no claim of EPUB structure preservation without an archived source file.
  @discardableResult
  public func create(document: NovelDocument) throws -> AdaptationJob {
    try locked {
      let staging = rootURL.appendingPathComponent(".creating-" + UUID().uuidString, isDirectory: true)
      defer { try? files.removeItem(at: staging) }
      return try finishCreation(document, originalHash: nil, staging: staging)
    }
  }

  public func createOriginal(title: String, author: String? = nil, chapters: [NovelChapter]) throws -> AdaptationJob {
    try locked {
      let source = NovelDocument(id: UUID(), title: title, author: author, sourceFormat: .text, sourceFileName: "原创计划.txt",
        contentHash: try AdaptationCoding.fingerprint(chapters), chapters: chapters)
      let staging = rootURL.appendingPathComponent(".creating-" + UUID().uuidString, isDirectory: true)
      defer { try? files.removeItem(at: staging) }
      return try finishCreation(source, originalHash: nil, staging: staging, originalPlan: true)
    }
  }

  public func list() throws -> [AdaptationJob] {
    try locked {
      listDiagnostics = []
      var result: [AdaptationJob] = []
      for url in try files.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        where url.pathExtension == "adaptationjob" {
        do {
          guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
            throw AdaptationError.corruptPackage
          }
          result.append(try job(id))
        } catch {
          listDiagnostics.append("改编任务「\(url.lastPathComponent)」读取失败；原目录已保留。")
        }
      }
      return result.sorted { $0.createdAt > $1.createdAt }
    }
  }

  public func load(_ jobID: UUID) throws -> AdaptationJob { try locked { try job(jobID) } }
  public func source(_ jobID: UUID) throws -> NovelDocument { try locked { try document(for: job(jobID)) } }

  /// Hold for a complete extraction/scan/write run, including network awaits.
  /// Author edits still use short CAS transactions and can invalidate a run.
  public func acquireExecution(_ jobID: UUID) throws -> DirectoryProcessLease {
    try locked {
      _ = try job(jobID)
      let directory = try path(jobID, "job.json").deletingLastPathComponent()
      return try DirectoryProcessLease(directoryURL: directory)
    }
  }

  /// Revalidate the archival bytes before an exporter is allowed to read them.
  public func originalFileURL(_ jobID: UUID) throws -> URL? {
    try locked {
      let current = try job(jobID)
      guard let expected = current.originalFileHash else { return nil }
      let document = try document(for: current)
      let url = try path(jobID, "input/source/" + document.sourceFileName)
      guard AdaptationCoding.hash(try readData(url, maximum: 100 * 1_048_576)) == expected else {
        throw AdaptationError.invalidSource
      }
      return url
    }
  }

  public func bookcases(_ jobID: UUID) throws -> [BookcaseProposal] {
    try locked {
      let current = try job(jobID), source = try document(for: current)
      let folder = try path(jobID, "bookcases")
      guard files.fileExists(atPath: folder.path) else { return [] }
      let entries = try files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
      guard entries.count <= 10_000 else { throw AdaptationError.corruptPackage }
      return try entries.filter { $0.pathExtension == "json" }.map { url in
        guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
          throw AdaptationError.corruptPackage
        }
        return try bookcase(id, job: current, document: source)
      }.sorted { $0.createdAt > $1.createdAt }
    }
  }

  /// Every extracted or manually revised bookcase is a pending proposal.
  /// The source identity and proposal ID make a completed retry idempotent.
  @discardableResult
  public func proposeBookcase(_ content: NovelBookcase, jobID: UUID, expectedRevision: UUID,
    parentID: UUID? = nil, proposalID: UUID = UUID(), authorRevision: Bool = false) throws -> BookcaseProposal {
    try locked {
      var current = try job(jobID)
      guard authorRevision || (content.meta.manualCharacterIDs.isEmpty
        && content.characters.allSatisfy({ $0.origin == .extracted })) else { throw AdaptationError.invalidBookcase }
      let source = try document(for: current)
      let normalized = try content.validated(in: source, snapshotHash: current.sourceSnapshotHash)
      let hash = try AdaptationCoding.fingerprint(normalized)
      let url = try path(jobID, "bookcases/\(key(proposalID)).json")
      if files.fileExists(atPath: url.path) {
        let prior = try bookcase(proposalID, job: current, document: source)
        guard prior.contentHash == hash, prior.parentID == parentID else { throw AdaptationError.staleEdit }
        return prior
      }
      guard current.revision == expectedRevision else { throw AdaptationError.staleEdit }
      if let parentID { _ = try bookcase(parentID, job: current, document: source) }
      let proposal = BookcaseProposal(id: proposalID, parentID: parentID, content: normalized,
        contentHash: hash, status: .pending, createdAt: AdaptationCoding.timestamp())
      current.revision = UUID()
      try update(job: current, values: [("bookcases/\(key(proposalID)).json", try encode(proposal))])
      return proposal
    }
  }

  /// Approval notes and acknowledgement of extraction gaps are recorded in
  /// the same recoverable transaction as the active bookcase pointer.
  @discardableResult
  public func decideBookcase(jobID: UUID, proposalID: UUID, expectedRevision: UUID,
    action: ApprovalAction, note: String? = nil, acknowledgeMissingChapters: Bool = false) throws -> BookcaseProposal {
    try locked {
      var current = try job(jobID)
      let source = try document(for: current)
      var proposal = try bookcase(proposalID, job: current, document: source)
      if proposal.status != .pending {
        let existing = try decision(proposalID, jobID: jobID)
        guard existing.action == action else { throw AdaptationError.alreadyDecided }
        return proposal
      }
      guard current.revision == expectedRevision else { throw AdaptationError.staleEdit }
      guard (note?.count ?? 0) <= 4_000 else { throw AdaptationError.invalidBookcase }
      let missing = proposal.content.missingChapterIDs(in: source)
      if action == .approve && !missing.isEmpty && !acknowledgeMissingChapters {
        throw AdaptationError.invalidBookcase
      }
      proposal.status = action == .approve ? .approved : .rejected
      let gapNote = action == .approve && !missing.isEmpty
        ? "已知书案缺少 \(missing.count) 章：" + missing.joined(separator: ", ") : ""
      let event = ApprovalEvent(id: proposalID, proposalID: proposalID, action: action,
        note: [note ?? "", gapNote].filter { !$0.isEmpty }.joined(separator: "\n"), createdAt: AdaptationCoding.timestamp())
      if action == .approve { current.approvedBookcaseID = proposalID }
      current.revision = UUID()
      try update(job: current, values: [
        ("bookcases/\(key(proposalID)).json", try encode(proposal)),
        ("approvals/\(key(proposalID)).json", try encode(event)),
      ])
      return proposal
    }
  }

  public func approval(jobID: UUID, proposalID: UUID) throws -> ApprovalEvent {
    try locked { _ = try job(jobID); return try decision(proposalID, jobID: jobID) }
  }

  @discardableResult
  public func createVariant(jobID: UUID, title: String, contract: AdaptationDirectionContract,
    expectedRevision: UUID) throws -> AdaptationVariant {
    try locked {
      var current = try job(jobID)
      guard current.revision == expectedRevision else { throw AdaptationError.staleEdit }
      guard let bookcaseID = current.approvedBookcaseID else { throw AdaptationError.missingBookcase }
      guard current.variants.count < 100, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        title.count <= 200 else { throw AdaptationError.invalidContract }
      let bookcase = try approvedBookcase(bookcaseID, job: current)
      let contract = try contract.validated(characterIDs: Set(bookcase.content.characters.map(\.id)))
      let variant = AdaptationVariant(id: UUID(), title: title, contractRevisionID: UUID(), bookcaseID: bookcaseID)
      let revision = AdaptationContractRevision(id: variant.contractRevisionID, variantID: variant.id,
        bookcaseID: bookcaseID, parentID: nil, contentHash: try contract.fingerprint(), contract: contract, createdAt: AdaptationCoding.timestamp())
      current.variants.append(variant); current.revision = UUID()
      try update(job: current, values: [("contracts/\(key(revision.id)).json", try encode(revision))])
      return variant
    }
  }

  /// Explicit entry for anchor-only editing or original writing without an
  /// extracted bookcase. Existing createVariant still requires its approval.
  public func createStandaloneVariant(jobID: UUID, title: String, contract: AdaptationDirectionContract,
    expectedRevision: UUID) throws -> AdaptationVariant {
    try locked {
      var current = try job(jobID)
      guard current.revision == expectedRevision else { throw AdaptationError.staleEdit }
      guard current.variants.count < 100, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        title.count <= 200 else { throw AdaptationError.invalidContract }
      let contract = try contract.validated(characterIDs: [])
      let variant = AdaptationVariant(id: UUID(), title: title, contractRevisionID: UUID(), bookcaseID: nil)
      let revision = AdaptationContractRevision(id: variant.contractRevisionID, variantID: variant.id,
        bookcaseID: nil, parentID: nil, contentHash: try contract.fingerprint(), contract: contract,
        createdAt: AdaptationCoding.timestamp())
      current.variants.append(variant); current.revision = UUID()
      try update(job: current, values: [("contracts/\(key(revision.id)).json", try encode(revision))])
      return variant
    }
  }

  /// Explicitly rebinding to a newly approved bookcase is an author action.
  /// The new revision retains the former contract and binding in its parent.
  @discardableResult
  public func updateDirection(jobID: UUID, variantID: UUID, expectedContractRevisionID: UUID,
    contract: AdaptationDirectionContract, bookcaseID: UUID? = nil) throws -> AdaptationVariant {
    try locked {
      var current = try job(jobID)
      guard let index = current.variants.firstIndex(where: { $0.id == variantID }),
        current.variants[index].contractRevisionID == expectedContractRevisionID else { throw AdaptationError.staleEdit }
      var variant = current.variants[index]
      let previous = try contractRevision(expectedContractRevisionID, job: current)
      let selectedID = bookcaseID ?? variant.bookcaseID
      let bookcase = try selectedID.map { try approvedBookcase($0, job: current) }
      let contract = try contract.validated(characterIDs: Set(bookcase?.content.characters.map(\.id) ?? []))
      if contract == previous.contract, selectedID == variant.bookcaseID { return variant }
      let revision = AdaptationContractRevision(id: UUID(), variantID: variant.id, bookcaseID: selectedID,
        parentID: previous.id, contentHash: try contract.fingerprint(), contract: contract, createdAt: AdaptationCoding.timestamp())
      variant.contractRevisionID = revision.id; variant.bookcaseID = selectedID
      current.variants[index] = variant; current.revision = UUID()
      try update(job: current, values: [("contracts/\(key(revision.id)).json", try encode(revision))])
      return variant
    }
  }

  public func direction(jobID: UUID, revisionID: UUID) throws -> AdaptationContractRevision {
    try locked { try contractRevision(revisionID, job: job(jobID)) }
  }

  public func generationBasis(jobID: UUID, variantID: UUID) throws -> AdaptationGenerationBasis {
    try locked {
      let current = try job(jobID)
      _ = try document(for: current)
      guard let variant = current.variants.first(where: { $0.id == variantID }) else { throw AdaptationError.staleEdit }
      let bookcase = try variant.bookcaseID.map { try approvedBookcase($0, job: current) }
      let contract = try contractRevision(variant.contractRevisionID, job: current)
      guard contract.variantID == variant.id, contract.bookcaseID == variant.bookcaseID else { throw AdaptationError.corruptPackage }
      return .init(jobID: jobID, variantID: variantID, sourceSnapshotHash: current.sourceSnapshotHash,
        bookcaseID: bookcase?.id, bookcaseHash: bookcase?.contentHash, contractRevisionID: contract.id, contractHash: contract.contentHash)
    }
  }

  public func boundBookcase(jobID: UUID, variantID: UUID) throws -> NovelBookcase? {
    try locked {
      let current = try job(jobID)
      guard let variant = current.variants.first(where: { $0.id == variantID }) else { throw AdaptationError.staleEdit }
      return try variant.bookcaseID.map { try approvedBookcase($0, job: current).content }
    }
  }

  // Synchronous lock covers read/CAS/write across multiple store actors in the
  // same process and other processes, as well as journal recovery.
  // No network awaits under the lock; another process gets a busy error.
  func locked<T>(_ operation: () throws -> T) throws -> T {
    try journal.withExclusiveAccess {
      guard !linked(rootURL), !linked(rootURL.appendingPathComponent(".replacement-journals")) else {
        throw AdaptationError.corruptPackage
      }
      try files.createDirectory(at: rootURL, withIntermediateDirectories: true)
      try journal.recoverPendingFileUpdates()
      return try operation()
    }
  }

  private func finishCreation(_ document: NovelDocument, originalHash: String?, staging: URL, originalPlan: Bool = false) throws -> AdaptationJob {
    try validateSource(document)
    let bytes = try encode(document)
    guard bytes.count <= 200 * 1_048_576 else { throw AdaptationError.invalidSource }
    let job = AdaptationJob(document: document, snapshotHash: AdaptationCoding.hash(bytes), originalHash: originalHash, originalPlan: originalPlan)
    try write(bytes, to: staging.appendingPathComponent("input/document.json"))
    try write(try encode(job), to: staging.appendingPathComponent("job.json"))
    try files.moveItem(at: staging, to: directory(job.id))
    return job
  }

  func job(_ id: UUID) throws -> AdaptationJob {
    let value: AdaptationJob = try read(try path(id, "job.json"), maximum: 131_072)
    guard value.schemaVersion == 1, value.id == id, hashString(value.sourceSnapshotHash),
      value.originalFileHash.map(hashString) ?? true,
      (value.originalFileHash == nil) == (value.originalFileExtension == nil),
      value.originalFileExtension.map({ NovelSourceFormat(rawValue: $0) != nil }) ?? true,
      value.variants.count <= 100, Set(value.variants.map(\.id)).count == value.variants.count,
      value.variants.allSatisfy({ !$0.title.isEmpty && $0.title.count <= 200 })
    else { throw AdaptationError.corruptPackage }
    return value
  }

  func document(for job: AdaptationJob) throws -> NovelDocument {
    let bytes = try readData(try path(job.id, "input/document.json"), maximum: 200 * 1_048_576)
    guard AdaptationCoding.hash(bytes) == job.sourceSnapshotHash else { throw AdaptationError.invalidSource }
    let document = try AdaptationCoding.decoder().decode(NovelDocument.self, from: bytes)
    try validateSource(document)
    guard document.title == job.title,
      job.originalFileExtension.map({ $0 == document.sourceFormat.rawValue }) ?? true,
      job.originalFileHash.map({ $0 == document.contentHash }) ?? true else { throw AdaptationError.invalidSource }
    return document
  }

  private func validateSource(_ source: NovelDocument) throws {
    guard !source.title.isEmpty, source.title.count <= 1_000, safeName(source.sourceFileName),
      hashString(source.contentHash), !source.chapters.isEmpty, source.chapters.count <= 10_000,
      Set(source.chapters.map(\.id)).count == source.chapters.count else { throw AdaptationError.invalidSource }
    var count = 0, bytes = 0
    for (index, chapter) in source.chapters.enumerated() {
      guard chapter.ordinal == index, !chapter.id.isEmpty, chapter.id.utf8.count <= 160,
        chapter.id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
        chapter.title.count <= 2_000, chapter.characterCount == chapter.content.count
      else { throw AdaptationError.invalidSource }
      bytes += chapter.content.utf8.count; count += chapter.characterCount
      guard bytes <= 100 * 1_048_576 else { throw AdaptationError.invalidSource }
    }
    guard count == source.totalCharacterCount else { throw AdaptationError.invalidSource }
  }

  private func bookcase(_ id: UUID, job: AdaptationJob, document: NovelDocument) throws -> BookcaseProposal {
    let proposal: BookcaseProposal = try read(try path(job.id, "bookcases/\(key(id)).json"), maximum: 20 * 1_048_576)
    guard proposal.id == id else { throw AdaptationError.corruptPackage }
    let normalized = try proposal.content.validated(in: document, snapshotHash: job.sourceSnapshotHash)
    guard normalized == proposal.content, try AdaptationCoding.fingerprint(normalized) == proposal.contentHash else {
      throw AdaptationError.corruptPackage
    }
    if proposal.status != .pending {
      let decision = try decision(id, jobID: job.id)
      guard (decision.action == .approve) == (proposal.status == .approved) else { throw AdaptationError.corruptPackage }
    }
    return proposal
  }

  private func approvedBookcase(_ id: UUID, job: AdaptationJob) throws -> BookcaseProposal {
    let result = try bookcase(id, job: job, document: document(for: job))
    guard result.status == .approved else { throw AdaptationError.missingBookcase }
    return result
  }

  private func decision(_ id: UUID, jobID: UUID) throws -> ApprovalEvent {
    let result: ApprovalEvent = try read(try path(jobID, "approvals/\(key(id)).json"), maximum: 2_097_152)
    guard result.id == id, result.proposalID == id else { throw AdaptationError.corruptPackage }
    return result
  }

  private func contractRevision(_ id: UUID, job: AdaptationJob) throws -> AdaptationContractRevision {
    let result: AdaptationContractRevision = try read(try path(job.id, "contracts/\(key(id)).json"), maximum: 163_840)
    guard result.id == id, job.variants.contains(where: { $0.id == result.variantID }),
      try result.contract.fingerprint() == result.contentHash else { throw AdaptationError.corruptPackage }
    let bookcase = try result.bookcaseID.map { try approvedBookcase($0, job: job) }
    _ = try result.contract.validated(characterIDs: Set(bookcase?.content.characters.map(\.id) ?? []))
    return result
  }

  private func update(job: AdaptationJob, values: [(String, Data)]) throws {
    let updates = try (values + [("job.json", encode(job))]).map { (relative, data) in
      (url: try path(job.id, relative), data: data)
    }
    for update in updates {
      try files.createDirectory(at: update.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    try journal.performFileUpdates(updates)
  }
  private func directory(_ id: UUID) -> URL { rootURL.appendingPathComponent(key(id) + ".adaptationjob", isDirectory: true) }
  private func key(_ id: UUID) -> String { id.uuidString.lowercased() }
  func path(_ id: UUID, _ relative: String) throws -> URL {
    let directory = directory(id)
    guard !linked(directory), files.fileExists(atPath: directory.path),
      !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\\") else { throw AdaptationError.corruptPackage }
    var result = directory
    for part in relative.split(separator: "/", omittingEmptySubsequences: false) {
      guard !part.isEmpty, part != ".", part != ".." else { throw AdaptationError.corruptPackage }
      result.appendPathComponent(String(part))
      guard !linked(result) else { throw AdaptationError.corruptPackage }
    }
    return result
  }
  private func linked(_ url: URL) -> Bool { (try? files.destinationOfSymbolicLink(atPath: url.path)) != nil }
  private func safeName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
      && !name.contains("\0") && name.utf8.count <= 255
  }
  private func hashString(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
  private func encode(_ value: some Encodable) throws -> Data { try AdaptationCoding.encoder().encode(value) }
  private func read<T: Decodable>(_ url: URL, maximum: Int) throws -> T {
    do { return try AdaptationCoding.decoder().decode(T.self, from: readData(url, maximum: maximum)) }
    catch { throw AdaptationError.corruptPackage }
  }
  func readData(_ url: URL, maximum: Int) throws -> Data {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      (values.fileSize ?? Int.max) <= maximum else { throw AdaptationError.corruptPackage }
    let bytes = try Data(contentsOf: url)
    guard bytes.count <= maximum else { throw AdaptationError.corruptPackage }
    return bytes
  }
  private func write(_ bytes: Data, to url: URL) throws {
    try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try bytes.write(to: url, options: .atomic)
  }
}

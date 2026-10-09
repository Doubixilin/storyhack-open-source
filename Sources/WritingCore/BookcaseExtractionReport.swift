import Foundation

public struct BookcaseExtractionGap: Codable, Equatable, Sendable {
  public let unitID: String
  public let chapterID: String
  public let reason: String
  public init(unitID: String, chapterID: String, reason: String) {
    self.unitID = unitID; self.chapterID = chapterID; self.reason = reason
  }
  enum CodingKeys: String, CodingKey { case unitID = "unit_id", chapterID = "chapter_id", reason }
}

public struct BookcaseExtractionReport: Codable, Equatable, Sendable {
  public enum Stage: String, Codable, Sendable { case running, partial, completed, cancelled, failed, awaitingConfirmation = "awaiting_confirmation" }
  public var stage: Stage
  public let sourceSnapshotHash: String
  public let planFingerprint: String
  public let selectedChapterIDs: [String]
  public let excludedChapterIDs: [String]
  public let totalUnits: Int
  public var completedUnitIDs: [String]
  public var gaps: [BookcaseExtractionGap]
  public var newRequestCount: Int
  public var cacheHitCount: Int
  public var proposalID: UUID?
  public var warnings: [String]

  public init(sourceSnapshotHash: String, planFingerprint: String, selectedChapterIDs: [String],
    excludedChapterIDs: [String], totalUnits: Int) {
    stage = .running; self.sourceSnapshotHash = sourceSnapshotHash; self.planFingerprint = planFingerprint
    self.selectedChapterIDs = selectedChapterIDs; self.excludedChapterIDs = excludedChapterIDs
    self.totalUnits = totalUnits; completedUnitIDs = []; gaps = []; newRequestCount = 0; cacheHitCount = 0; warnings = []
  }
  enum CodingKeys: String, CodingKey {
    case stage, sourceSnapshotHash = "source_snapshot_hash", planFingerprint = "plan_fingerprint"
    case selectedChapterIDs = "selected_chapter_ids", excludedChapterIDs = "excluded_chapter_ids"
    case totalUnits = "total_units", completedUnitIDs = "completed_unit_ids", gaps
    case newRequestCount = "new_request_count", cacheHitCount = "cache_hit_count", proposalID = "proposal_id", warnings
  }
}

extension AdaptationJobStore {
  /// Shared by every extractor entry point, including App and CLI. Preserve
  /// explicit author identities without promoting new model facts to approved.
  public func retainingApprovedManualCards(_ report: BookcaseExtractionReport, jobID: UUID) throws -> BookcaseExtractionReport {
    try locked {
      let current = try job(jobID)
      guard report.sourceSnapshotHash == current.sourceSnapshotHash else { throw AdaptationError.invalidSource }
      guard let extractedID = report.proposalID else { return report }
      let proposals = try bookcases(jobID)
      guard let extracted = proposals.first(where: { $0.id == extractedID }) else { throw AdaptationError.invalidBookcase }
      guard let approved = proposals.first(where: { $0.id == current.approvedBookcaseID }) else { return report }
      let manual = approved.content.characters.filter { $0.origin == .author }
      guard !manual.isEmpty else { return report }
      let source = try document(for: current)
      let merged = try extracted.content.applyingManualCharacters(manual).validated(in: source, snapshotHash: current.sourceSnapshotHash)
      let hash = try AdaptationCoding.fingerprint(merged)
      let proposalID: UUID
      if let previous = proposals.first(where: { $0.contentHash == hash && $0.parentID == extractedID }) { proposalID = previous.id }
      else {
        proposalID = try proposeBookcase(merged, jobID: jobID, expectedRevision: current.revision,
          parentID: extractedID, authorRevision: true).id
      }
      var updated = report
      updated.proposalID = proposalID
      updated.warnings.append("已沿用批准书案中的人工角色卡。不同身份标识仍需人工核对，不按同名自动合并。")
      return updated
    }
  }

  public func saveBookcaseExtractionReport(_ report: BookcaseExtractionReport, jobID: UUID) throws {
    try locked {
      guard report.sourceSnapshotHash == (try job(jobID).sourceSnapshotHash) else { throw AdaptationError.invalidSource }
      let bytes = try AdaptationCoding.encoder().encode(report)
      guard bytes.count <= 8_388_608, report.totalUnits >= 0,
        report.completedUnitIDs.count <= report.totalUnits else { throw AdaptationError.corruptPackage }
      let url = try path(jobID, "bookcase-extraction.json")
      try bytes.write(to: url, options: .atomic)
    }
  }
  public func bookcaseExtractionReport(_ jobID: UUID) throws -> BookcaseExtractionReport? {
    try locked {
      let current = try job(jobID), url = try path(jobID, "bookcase-extraction.json")
      guard files.fileExists(atPath: url.path) else { return nil }
      let value = try AdaptationCoding.decoder().decode(BookcaseExtractionReport.self, from: readData(url, maximum: 8_388_608))
      guard value.sourceSnapshotHash == current.sourceSnapshotHash else { throw AdaptationError.corruptPackage }
      return value
    }
  }
}

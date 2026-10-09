import Foundation

public struct AnchorScanReport: Codable, Equatable, Sendable {
  public var stage: BookcaseExtractionReport.Stage
  public let sourceSnapshotHash: String
  public let planFingerprint: String
  public let selectedChapterIDs: [String]
  public let totalUnits: Int
  public var completedUnitIDs: [String]
  public var gaps: [BookcaseExtractionGap]
  public var newRequestCount: Int
  public var cacheHitCount: Int
  public var mapRevision: UUID?
  public var addedAnchorCount: Int
  public var filteredAnchorCount: Int
  public init(sourceSnapshotHash: String, planFingerprint: String, selectedChapterIDs: [String], totalUnits: Int) {
    stage = .running; self.sourceSnapshotHash = sourceSnapshotHash; self.planFingerprint = planFingerprint
    self.selectedChapterIDs = selectedChapterIDs; self.totalUnits = totalUnits
    completedUnitIDs = []; gaps = []; newRequestCount = 0; cacheHitCount = 0; addedAnchorCount = 0; filteredAnchorCount = 0
  }
  enum CodingKeys: String, CodingKey {
    case stage, sourceSnapshotHash = "source_snapshot_hash", planFingerprint = "plan_fingerprint"
    case selectedChapterIDs = "selected_chapter_ids", totalUnits = "total_units", completedUnitIDs = "completed_unit_ids", gaps
    case newRequestCount = "new_request_count", cacheHitCount = "cache_hit_count", mapRevision = "map_revision"
    case addedAnchorCount = "added_anchor_count", filteredAnchorCount = "filtered_anchor_count"
  }
}

extension AdaptationJobStore {
  public func saveAnchorScanReport(_ report: AnchorScanReport, jobID: UUID) throws {
    try locked {
      guard report.sourceSnapshotHash == (try job(jobID).sourceSnapshotHash) else { throw AdaptationError.invalidSource }
      let data = try AdaptationCoding.encoder().encode(report)
      guard data.count <= 8_388_608 else { throw AdaptationError.invalidAnchor }
      try data.write(to: path(jobID, "anchor-scan.json"), options: .atomic)
    }
  }
  public func anchorScanReport(_ jobID: UUID) throws -> AnchorScanReport? {
    try locked {
      let current = try job(jobID), url = try path(jobID, "anchor-scan.json")
      guard files.fileExists(atPath: url.path) else { return nil }
      let report = try AdaptationCoding.decoder().decode(AnchorScanReport.self, from: readData(url, maximum: 8_388_608))
      guard report.sourceSnapshotHash == current.sourceSnapshotHash else { throw AdaptationError.invalidSource }
      return report
    }
  }
}

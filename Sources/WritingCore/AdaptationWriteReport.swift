import Foundation

public struct AdaptationWriteReport: Codable, Equatable, Sendable {
  public var stage: BookcaseExtractionReport.Stage = .running
  public let variantID: UUID
  public var targets: [AdaptationDraftTarget]
  public var completedDraftIDs: [UUID] = []
  public var newRequestCount = 0
  public var cacheHitCount = 0
  public var reusedDraftCount = 0
  public var gaps: [String] = []
  public init(variantID: UUID, targets: [AdaptationDraftTarget]) { self.variantID = variantID; self.targets = targets }
  enum CodingKeys: String, CodingKey {
    case stage, targets, gaps, variantID = "variant_id", completedDraftIDs = "completed_draft_ids"
    case newRequestCount = "new_request_count", cacheHitCount = "cache_hit_count", reusedDraftCount = "reused_draft_count"
  }
}

extension AdaptationJobStore {
  public func saveWriteReport(_ report: AdaptationWriteReport, jobID: UUID) throws {
    try locked {
      guard try job(jobID).variants.contains(where: { $0.id == report.variantID }) else { throw AdaptationError.staleEdit }
      let data = try AdaptationCoding.encoder().encode(report)
      guard data.count <= 4_000_000 else { throw AdaptationError.invalidDraft }
      try data.write(to: path(jobID, "write-\(report.variantID.uuidString.lowercased()).json"), options: .atomic)
    }
  }
  public func writeReport(jobID: UUID, variantID: UUID) throws -> AdaptationWriteReport? {
    try locked {
      _ = try job(jobID)
      let url = try path(jobID, "write-\(variantID.uuidString.lowercased()).json")
      guard files.fileExists(atPath: url.path) else { return nil }
      let value = try AdaptationCoding.decoder().decode(AdaptationWriteReport.self, from: readData(url, maximum: 4_000_000))
      guard value.variantID == variantID else { throw AdaptationError.invalidDraft }
      return value
    }
  }
}

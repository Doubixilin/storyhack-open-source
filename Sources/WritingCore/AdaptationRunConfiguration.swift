import Foundation
import StoryworldCore

public struct AdaptationRunConfiguration: Codable, Equatable, Sendable {
  public enum WriteScope: String, Codable, CaseIterable, Sendable { case chapters, anchors }
  public var revision: UUID?
  public var providerID: UUID?
  public var chapterIDs: [String] = []
  public var focusNames: [String] = []
  public var maximumNewRequests = 20
  public var maximumUnitUTF16Length = 12_000
  public var density = 2
  public var addChapterStarts = true
  public var writeScope: WriteScope = .chapters
  public var taskTaste = PlayerTasteOverrides()
  public var regenerationID: UUID?
  public init() {}
  enum CodingKeys: String, CodingKey {
    case revision, density, providerID = "provider_id", chapterIDs = "chapter_ids", focusNames = "focus_names"
    case maximumNewRequests = "maximum_new_requests", maximumUnitUTF16Length = "maximum_unit_utf16_length"
    case addChapterStarts = "add_chapter_starts", writeScope = "write_scope", taskTaste = "task_taste", regenerationID = "regeneration_id"
  }
}

extension AdaptationJobStore {
  /// Start an explicitly requested paid generation round only while idle and
  /// after all unknown requests have been reviewed. Continuation keeps this ID.
  public func beginRegeneration(jobID: UUID, expectedConfigurationRevision: UUID?) throws -> AdaptationRunConfiguration {
    try locked {
      let lease = try acquireExecution(jobID)
      defer { lease.release() }
      if let pending = try pendingRequest(jobID) { throw AdaptationRequestError.uncertain(pending) }
      let current = try runConfiguration(jobID)
      guard current.revision == expectedConfigurationRevision else { throw AdaptationError.staleEdit }
      var configuration = current
      configuration.regenerationID = UUID()
      return try persistConfiguration(configuration, jobID: jobID, replacing: current)
    }
  }

  public func runConfiguration(_ jobID: UUID) throws -> AdaptationRunConfiguration {
    try locked {
      let source = try document(for: job(jobID)), url = try path(jobID, "run-configuration.json")
      guard files.fileExists(atPath: url.path) else { return .init() }
      let value = try AdaptationCoding.decoder().decode(AdaptationRunConfiguration.self, from: readData(url, maximum: 1_048_576))
      guard value.revision != nil else { throw AdaptationError.corruptPackage }
      try validateConfiguration(value, chapterIDs: Set(source.chapters.map(\.id)))
      return value
    }
  }
  public func saveRunConfiguration(_ configuration: AdaptationRunConfiguration, jobID: UUID,
    expectedRevision: UUID?) throws -> AdaptationRunConfiguration {
    try locked {
      let current = try runConfiguration(jobID)
      guard current.revision == expectedRevision else { throw AdaptationError.staleEdit }
      // A config-file edit must not bypass the explicit idle/pending checks.
      guard configuration.regenerationID == current.regenerationID else { throw AdaptationError.invalidContract }
      return try persistConfiguration(configuration, jobID: jobID, replacing: current)
    }
  }
  private func persistConfiguration(_ configuration: AdaptationRunConfiguration, jobID: UUID,
    replacing current: AdaptationRunConfiguration) throws -> AdaptationRunConfiguration {
    let source = try document(for: job(jobID))
    try validateConfiguration(configuration, chapterIDs: Set(source.chapters.map(\.id)))
    var value = configuration; value.revision = current.revision
    if value == current { return current }
    value.revision = UUID()
    let data = try AdaptationCoding.encoder().encode(value)
    guard data.count <= 1_048_576 else { throw AdaptationError.invalidContract }
    try data.write(to: path(jobID, "run-configuration.json"), options: .atomic)
    return value
  }
  private func validateConfiguration(_ value: AdaptationRunConfiguration, chapterIDs: Set<String>) throws {
    guard value.chapterIDs.count <= 10_000, Set(value.chapterIDs).isSubset(of: chapterIDs),
      Set(value.chapterIDs).count == value.chapterIDs.count, value.focusNames.count <= 32,
      value.focusNames.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 80 }),
      (0...100).contains(value.maximumNewRequests), (1...50_000).contains(value.maximumUnitUTF16Length), (1...5).contains(value.density)
    else { throw AdaptationError.invalidContract }
    _ = try value.taskTaste.validated()
  }
}

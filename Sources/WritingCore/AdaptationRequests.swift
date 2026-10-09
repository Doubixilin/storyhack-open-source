import Foundation

public struct AdaptationRequestIdentity: Codable, Equatable, Sendable {
  public let sourceSnapshotHash: String
  public let purpose: String
  public let unitID: String
  public let executorFingerprint: String
  public let inputFingerprint: String
  public init(sourceSnapshotHash: String, purpose: String, unitID: String,
    executorFingerprint: String, inputFingerprint: String) {
    self.sourceSnapshotHash = sourceSnapshotHash; self.purpose = purpose; self.unitID = unitID
    self.executorFingerprint = executorFingerprint; self.inputFingerprint = inputFingerprint
  }
  public func cacheKey() throws -> String {
    guard [sourceSnapshotHash, executorFingerprint, inputFingerprint].allSatisfy({ value in
      value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }), !purpose.isEmpty, purpose.count <= 80, !unitID.isEmpty, unitID.count <= 256
    else { throw AdaptationError.corruptPackage }
    return try AdaptationCoding.fingerprint(self)
  }
  enum CodingKeys: String, CodingKey {
    case sourceSnapshotHash = "source_snapshot_hash", purpose, unitID = "unit_id"
    case executorFingerprint = "executor_fingerprint", inputFingerprint = "input_fingerprint"
  }
}

public struct AdaptationRequestCheckpoint: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let jobID: UUID
  public let identity: AdaptationRequestIdentity
  public let startedAt: Date
  enum CodingKeys: String, CodingKey { case id, jobID = "job_id", identity, startedAt = "started_at" }
}

public struct AdaptationResponseRecord: Codable, Equatable, Sendable {
  public let checkpoint: AdaptationRequestCheckpoint
  public let text: String
  public let textHash: String
  enum CodingKeys: String, CodingKey { case checkpoint, text, textHash = "text_hash" }
}

public enum AdaptationRequestStart: Sendable {
  case cached(AdaptationResponseRecord)
  case send(AdaptationRequestCheckpoint)
}

public enum AdaptationRequestError: Error, Equatable, LocalizedError {
  case uncertain(AdaptationRequestCheckpoint)
  case staleCheckpoint
  case responseTooLarge
  public var errorDescription: String? {
    switch self {
    case .uncertain: "上次改编请求的结果尚未确认。重新发送可能重复计费，请核对后明确确认。"
    case .staleCheckpoint: "请求检查点已变化，请重新核对。"
    case .responseTooLarge: "模型回复超过本地接收上限，已停止接收并保留请求检查点。"
    }
  }
}

extension AdaptationJobStore {
  /// The one pending slot covers all pipelines and configurations of this job.
  /// It is not removed by cancellation, replanning or changing the model.
  public func pendingRequest(_ jobID: UUID) throws -> AdaptationRequestCheckpoint? {
    try locked { try pendingRequestLocked(jobID) }
  }

  public func cachedResponse(jobID: UUID, identity: AdaptationRequestIdentity) throws -> AdaptationResponseRecord? {
    try locked { try cachedResponseLocked(jobID: jobID, identity: identity) }
  }

  public func beginRequest(jobID: UUID, identity: AdaptationRequestIdentity) throws -> AdaptationRequestStart {
    try locked {
      guard try job(jobID).sourceSnapshotHash == identity.sourceSnapshotHash else { throw AdaptationError.invalidSource }
      if let pending = try pendingRequestLocked(jobID) { throw AdaptationRequestError.uncertain(pending) }
      if let cached = try cachedResponseLocked(jobID: jobID, identity: identity) { return .cached(cached) }
      let checkpoint = AdaptationRequestCheckpoint(id: UUID(), jobID: jobID, identity: identity, startedAt: AdaptationCoding.timestamp())
      try requestChanges(jobID, [("requests/pending.json", AdaptationCoding.encoder().encode(checkpoint))])
      return .send(checkpoint)
    }
  }

  /// Save completed bytes before parsing. A crash after reception can resume
  /// from these bytes without paying again. No source or contract is mutated.
  @discardableResult
  public func completeRequest(_ checkpoint: AdaptationRequestCheckpoint, text: String) throws -> AdaptationResponseRecord {
    try locked {
      guard text.utf8.count <= 1_048_576 else { throw AdaptationRequestError.responseTooLarge }
      guard try pendingRequestLocked(checkpoint.jobID) == checkpoint else { throw AdaptationRequestError.staleCheckpoint }
      let record = AdaptationResponseRecord(checkpoint: checkpoint, text: text,
        textHash: AdaptationCoding.hash(Data(text.utf8)))
      try requestChanges(checkpoint.jobID, [
        (responsePath(checkpoint.identity), AdaptationCoding.encoder().encode(record)), ("requests/pending.json", nil),
      ])
      return record
    }
  }

  /// Only a completed response can be rejected automatically for invalid
  /// structure/evidence. Keep the bytes for inspection; a later user-initiated
  /// continuation can request that failed unit again.
  public func rejectCompletedResponse(_ record: AdaptationResponseRecord, reason: String) throws {
    try locked {
      let checkpoint = record.checkpoint
      guard reason.count <= 2_000,
        try cachedResponseLocked(jobID: checkpoint.jobID, identity: checkpoint.identity) == record else {
        throw AdaptationRequestError.staleCheckpoint
      }
      struct Rejection: Codable { let response: AdaptationResponseRecord; let reason: String }
      try requestChanges(checkpoint.jobID, [
        ("requests/rejected/\(checkpoint.id.uuidString.lowercased()).json",
          AdaptationCoding.encoder().encode(Rejection(response: record, reason: reason))),
        (responsePath(checkpoint.identity), nil),
      ])
    }
  }

  /// Call only after the author has reviewed this exact pending request.
  /// Late completion of an abandoned request fails its checkpoint CAS.
  public func acknowledgeUnknownRequest(_ expected: AdaptationRequestCheckpoint, note: String = "确认重新发送") throws {
    try locked {
      // A pending slot from a still-running App/CLI is not an abandoned request.
      let lease = try acquireExecution(expected.jobID)
      defer { lease.release() }
      guard note.count <= 2_000, try pendingRequestLocked(expected.jobID) == expected else {
        throw AdaptationRequestError.staleCheckpoint
      }
      struct Acknowledgement: Codable {
        let checkpoint: AdaptationRequestCheckpoint
        let note: String
        let acknowledgedAt: Date
        enum CodingKeys: String, CodingKey { case checkpoint, note, acknowledgedAt = "acknowledged_at" }
      }
      let value = Acknowledgement(checkpoint: expected, note: note, acknowledgedAt: AdaptationCoding.timestamp())
      try requestChanges(expected.jobID, [
        ("requests/retry-approved/\(expected.id.uuidString.lowercased()).json", AdaptationCoding.encoder().encode(value)),
        ("requests/pending.json", nil),
      ])
    }
  }

  /// Authentication/rate-limit rejection has a known outcome. Keep metadata,
  /// omit the server body, and allow a later explicit continuation to retry.
  public func recordRejectedRequest(_ expected: AdaptationRequestCheckpoint, statusCode: Int) throws {
    try locked {
      guard [401, 403, 429].contains(statusCode), try pendingRequestLocked(expected.jobID) == expected else {
        throw AdaptationRequestError.staleCheckpoint
      }
      struct Rejection: Codable { let checkpoint: AdaptationRequestCheckpoint; let statusCode: Int }
      try requestChanges(expected.jobID, [
        ("requests/rejected/\(expected.id.uuidString.lowercased()).json",
          AdaptationCoding.encoder().encode(Rejection(checkpoint: expected, statusCode: statusCode))),
        ("requests/pending.json", nil),
      ])
    }
  }

  private func pendingRequestLocked(_ jobID: UUID) throws -> AdaptationRequestCheckpoint? {
    let current = try job(jobID), url = try path(jobID, "requests/pending.json")
    guard files.fileExists(atPath: url.path) else { return nil }
    guard let result = try? AdaptationCoding.decoder().decode(AdaptationRequestCheckpoint.self, from: readData(url, maximum: 16_384)),
      result.jobID == jobID, result.identity.sourceSnapshotHash == current.sourceSnapshotHash else {
      throw AdaptationError.corruptPackage
    }
    _ = try result.identity.cacheKey()
    return result
  }

  private func responsePath(_ identity: AdaptationRequestIdentity) throws -> String {
    "requests/responses/\(try identity.cacheKey()).json"
  }

  private func cachedResponseLocked(jobID: UUID, identity: AdaptationRequestIdentity) throws -> AdaptationResponseRecord? {
    guard try job(jobID).sourceSnapshotHash == identity.sourceSnapshotHash else { throw AdaptationError.invalidSource }
    let url = try path(jobID, responsePath(identity))
    guard files.fileExists(atPath: url.path) else { return nil }
    // JSON escaping can expand the bounded raw response by up to six times.
    let bytes = try readData(url, maximum: 6_400_000)
    guard let value = try? AdaptationCoding.decoder().decode(AdaptationResponseRecord.self,
      from: bytes), value.checkpoint.jobID == jobID,
      value.checkpoint.identity == identity, value.text.utf8.count <= 1_048_576,
      AdaptationCoding.hash(Data(value.text.utf8)) == value.textHash else {
      // A completed-response cache is derived, unlike the pending slot.
      // Quarantine bounded regular-file bytes, then treat it as a miss. A
      // caller may spend only its explicitly allowed new-request budget.
      try requestChanges(jobID, [
        ("requests/rejected/corrupt-\(try identity.cacheKey())-\(UUID().uuidString.lowercased()).bin", bytes),
        (responsePath(identity), nil),
      ])
      return nil
    }
    return value
  }

  private func requestChanges(_ jobID: UUID, _ changes: [(String, Data?)]) throws {
    let updates = try changes.map { (relative, data) in (url: try path(jobID, relative), data: data) }
    for update in updates where update.data != nil {
      try files.createDirectory(at: update.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    try journal.performFileChanges(updates)
  }
}

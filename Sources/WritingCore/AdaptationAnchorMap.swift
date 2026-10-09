import Foundation
import NovelDocumentCore

public enum AdaptationAnchorAction: String, Codable, CaseIterable, Sendable {
  case insertion, rewrite, newChapter = "new_chapter"
}

public struct AdaptationAnchorCandidate: Codable, Equatable, Sendable {
  public let chapterID: String
  public let quote: String
  public let utf16Location: Int?
  public let note: String
  public let action: AdaptationAnchorAction
  public let focusNames: [String]
  public init(chapterID: String, quote: String, utf16Location: Int? = nil, note: String,
    action: AdaptationAnchorAction = .insertion, focusNames: [String] = []) {
    self.chapterID = chapterID; self.quote = quote; self.utf16Location = utf16Location
    self.note = note; self.action = action; self.focusNames = focusNames
  }
  enum CodingKeys: String, CodingKey {
    case chapterID = "chapter_id", quote, utf16Location = "utf16_location", note, action, focusNames = "focus_names"
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    chapterID = try c.decode(String.self, forKey: .chapterID); quote = try c.decode(String.self, forKey: .quote)
    utf16Location = try c.decodeIfPresent(Int.self, forKey: .utf16Location)
    note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    action = try c.decodeIfPresent(AdaptationAnchorAction.self, forKey: .action) ?? .insertion
    focusNames = try c.decodeIfPresent([String].self, forKey: .focusNames) ?? []
  }
}

public struct AdaptationAnchor: Codable, Equatable, Identifiable, Sendable {
  public enum Origin: String, Codable, Sendable { case automatic = "a", fallback = "f", manual = "m" }
  public var id: String { source.chapterID + "-" + origin.rawValue + "-" + String(format: "%05d", serial) }
  public let serial: Int
  public let origin: Origin
  public let source: TextAnchor
  public let quote: String
  public internal(set) var note: String
  public let suggestedAction: AdaptationAnchorAction
  public let focusNames: [String]
  public let scanFingerprint: String?
  public func fingerprint() throws -> String { try AdaptationCoding.fingerprint(self) }
  enum CodingKeys: String, CodingKey {
    case serial, origin, source, quote, note, suggestedAction = "suggested_action"
    case focusNames = "focus_names", scanFingerprint = "scan_fingerprint"
  }
}

public struct AdaptationAnchorReview: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let anchorID: String
  public let anchorFingerprint: String
  public let action: ApprovalAction
  public let generationAction: AdaptationAnchorAction
  public let intensity: Int
  public let note: String
  public let createdAt: Date
  enum CodingKeys: String, CodingKey {
    case id, anchorID = "anchor_id", anchorFingerprint = "anchor_fingerprint", action
    case generationAction = "generation_action", intensity, note, createdAt = "created_at"
  }
}

public struct AdaptationAnchorMap: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let sourceSnapshotHash: String
  public internal(set) var revision: UUID?
  public internal(set) var anchors: [AdaptationAnchor]
  public internal(set) var reviews: [String: AdaptationAnchorReview]
  init(sourceHash: String) {
    schemaVersion = 1; sourceSnapshotHash = sourceHash; revision = nil; anchors = []; reviews = [:]
  }
  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version", sourceSnapshotHash = "source_snapshot_hash", revision, anchors, reviews
  }
}

extension AdaptationJobStore {
  public func anchorMap(_ jobID: UUID) throws -> AdaptationAnchorMap {
    try locked { try anchorMapLocked(jobID) }
  }

  /// Scan results add pending locations only; they never reset author reviews.
  /// Chapter-local counters keep IDs stable across batches and continuations.
  @discardableResult
  public func commitAnchorScan(jobID: UUID, expectedRevision: UUID?, candidates: [AdaptationAnchorCandidate],
    completedChapterIDs: [String], scanFingerprint: String, addChapterStarts: Bool,
    fallbackFocusNames: [String] = []) throws -> AdaptationAnchorMap {
    try locked {
      var map = try anchorMapLocked(jobID)
      guard map.revision == expectedRevision else { throw AdaptationError.staleEdit }
      guard candidates.count <= 10_000, scanFingerprint.utf8.count == 64,
        fallbackFocusNames.count <= 32, fallbackFocusNames.allSatisfy({ !$0.isEmpty && $0.count <= 80 }) else { throw AdaptationError.invalidAnchor }
      let source = try document(for: job(jobID))
      guard Set(completedChapterIDs).isSubset(of: Set(source.chapters.map(\.id))) else { throw AdaptationError.invalidAnchor }
      let original = map
      for candidate in candidates {
        let anchor = try makeAnchor(candidate, origin: .automatic, fingerprint: scanFingerprint, source: source, map: map)
        if map.anchors.contains(where: { $0.origin == .automatic && $0.source.chapterID == anchor.source.chapterID
          && $0.source.range == anchor.source.range && $0.quote == anchor.quote && $0.suggestedAction == anchor.suggestedAction }) { continue }
        map.anchors.append(anchor)
      }
      if addChapterStarts {
        for chapter in source.chapters where completedChapterIDs.contains(chapter.id)
          && !chapter.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && !map.anchors.contains(where: { $0.source.chapterID == chapter.id }) {
          let candidate = AdaptationAnchorCandidate(chapterID: chapter.id, quote: "",
            note: "本章扫描未找到锚点。可在章首先作过渡；不得新增人物或用梦境填充，须接回原章开头。",
            focusNames: fallbackFocusNames.filter { chapter.content.range(of: $0, options: .literal) != nil })
          map.anchors.append(try makeAnchor(candidate, origin: .fallback, fingerprint: scanFingerprint, source: source, map: map))
        }
      }
      guard map != original else { return map }
      map.revision = UUID(); try saveAnchorMap(map, jobID: jobID)
      return map
    }
  }

  @discardableResult
  public func addManualAnchor(jobID: UUID, expectedRevision: UUID?, candidate: AdaptationAnchorCandidate) throws -> AdaptationAnchorMap {
    try locked {
      var map = try anchorMapLocked(jobID)
      guard map.revision == expectedRevision else { throw AdaptationError.staleEdit }
      let source = try document(for: job(jobID))
      map.anchors.append(try makeAnchor(candidate, origin: .manual, fingerprint: nil, source: source, map: map))
      map.revision = UUID(); try saveAnchorMap(map, jobID: jobID)
      return map
    }
  }

  @discardableResult
  public func reviewAnchor(jobID: UUID, anchorID: String, expectedRevision: UUID?, action: ApprovalAction,
    generationAction: AdaptationAnchorAction, intensity: Int = 3, note: String = "") throws -> AdaptationAnchorMap {
    try locked {
      var map = try anchorMapLocked(jobID)
      guard map.revision == expectedRevision else { throw AdaptationError.staleEdit }
      guard let anchor = map.anchors.first(where: { $0.id == anchorID }), (1...5).contains(intensity), note.count <= 2_000
      else { throw AdaptationError.invalidAnchor }
      if let old = map.reviews[anchorID], old.action == action, old.generationAction == generationAction,
        old.intensity == intensity, old.note == note { return map }
      let review = AdaptationAnchorReview(id: UUID(), anchorID: anchorID, anchorFingerprint: try anchor.fingerprint(),
        action: action, generationAction: generationAction, intensity: intensity, note: note, createdAt: AdaptationCoding.timestamp())
      map.reviews[anchorID] = review; map.revision = UUID()
      try saveAnchorMap(map, jobID: jobID, review: review)
      return map
    }
  }

  @discardableResult
  public func editAnchorNote(jobID: UUID, anchorID: String, expectedRevision: UUID?, note: String) throws -> AdaptationAnchorMap {
    try locked {
      var map = try anchorMapLocked(jobID)
      guard map.revision == expectedRevision else { throw AdaptationError.staleEdit }
      guard let index = map.anchors.firstIndex(where: { $0.id == anchorID }), note.count <= 2_000 else { throw AdaptationError.invalidAnchor }
      if map.anchors[index].note == note { return map }
      map.anchors[index].note = note
      map.reviews.removeValue(forKey: anchorID)
      map.revision = UUID(); try saveAnchorMap(map, jobID: jobID)
      return map
    }
  }

  private func makeAnchor(_ candidate: AdaptationAnchorCandidate, origin: AdaptationAnchor.Origin,
    fingerprint: String?, source: NovelDocument, map: AdaptationAnchorMap) throws -> AdaptationAnchor {
    guard let chapter = source.chapters.first(where: { $0.id == candidate.chapterID }),
      candidate.note.count <= 2_000, candidate.focusNames.count <= 32,
      candidate.focusNames.allSatisfy({ !$0.isEmpty && $0.count <= 80 }), candidate.quote.count <= 2_000 else {
      throw AdaptationError.invalidAnchor
    }
    let anchor: TextAnchor
    if candidate.quote.isEmpty {
      guard origin != .automatic, candidate.utf16Location == nil || candidate.utf16Location == 0 else { throw AdaptationError.invalidAnchor }
      anchor = try TextAnchor(document: source, chapter: chapter, range: .init(location: 0, length: 0))
    } else {
      let evidence = try BookcaseEvidence(chapterID: chapter.id, quote: candidate.quote, utf16Location: candidate.utf16Location).anchored(in: source)
      guard let value = evidence.anchor else { throw AdaptationError.invalidAnchor }
      anchor = value
    }
    let serial = (map.anchors.filter { $0.source.chapterID == chapter.id && $0.origin == origin }.map(\.serial).max() ?? 0) + 1
    guard serial <= 99_999, map.anchors.count <= 10_000 else { throw AdaptationError.invalidAnchor }
    return .init(serial: serial, origin: origin, source: anchor, quote: candidate.quote, note: candidate.note,
      suggestedAction: candidate.action, focusNames: candidate.focusNames, scanFingerprint: fingerprint)
  }

  private func anchorMapLocked(_ jobID: UUID) throws -> AdaptationAnchorMap {
    let current = try job(jobID), source = try document(for: current), url = try path(jobID, "anchor-map.json")
    guard files.fileExists(atPath: url.path) else { return .init(sourceHash: current.sourceSnapshotHash) }
    let value = try AdaptationCoding.decoder().decode(AdaptationAnchorMap.self, from: readData(url, maximum: 32_000_000))
    guard value.schemaVersion == 1, value.sourceSnapshotHash == current.sourceSnapshotHash, value.revision != nil,
      value.anchors.count <= 10_000, Set(value.anchors.map(\.id)).count == value.anchors.count,
      Set(value.reviews.keys).isSubset(of: Set(value.anchors.map(\.id))) else { throw AdaptationError.invalidAnchor }
    for anchor in value.anchors {
      guard (1...99_999).contains(anchor.serial), anchor.note.count <= 2_000, anchor.quote.count <= 2_000,
        anchor.focusNames.count <= 32, anchor.focusNames.allSatisfy({ !$0.isEmpty && $0.count <= 80 }),
        let chapter = source.chapters.first(where: { $0.id == anchor.source.chapterID }),
        anchor.source.range.location >= 0, anchor.source.range.length >= 0,
        anchor.source.range.location <= chapter.content.utf16.count,
        anchor.source.range.length <= chapter.content.utf16.count - anchor.source.range.location,
        !anchor.quote.isEmpty || (anchor.origin != .automatic && anchor.source.range.location == 0 && anchor.source.range.length == 0),
        try anchor.source.resolve(in: source).utf8.elementsEqual(anchor.quote.utf8) else { throw AdaptationError.invalidAnchor }
      if let review = value.reviews[anchor.id] {
        let bytes = try readData(try path(jobID, "anchor-reviews/\(review.id.uuidString.lowercased()).json"), maximum: 32_768)
        guard review.anchorID == anchor.id, review.anchorFingerprint == (try anchor.fingerprint()),
          (1...5).contains(review.intensity), review.note.count <= 2_000,
          try AdaptationCoding.decoder().decode(AdaptationAnchorReview.self, from: bytes) == review else { throw AdaptationError.invalidAnchor }
      }
    }
    return value
  }

  private func saveAnchorMap(_ map: AdaptationAnchorMap, jobID: UUID, review: AdaptationAnchorReview? = nil) throws {
    let data = try AdaptationCoding.encoder().encode(map)
    guard data.count <= 32_000_000, map.anchors.count <= 10_000 else { throw AdaptationError.invalidAnchor }
    var updates = [(url: try path(jobID, "anchor-map.json"), data: data)]
    if let review {
      let url = try path(jobID, "anchor-reviews/\(review.id.uuidString.lowercased()).json")
      try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      updates.append((url, try AdaptationCoding.encoder().encode(review)))
    }
    try journal.performFileUpdates(updates)
  }
}

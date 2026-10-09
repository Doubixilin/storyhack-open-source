import Foundation
import NovelDocumentCore

/// Exact quotation and stable source location. Matching proves location only,
/// not that the accompanying interpretation is correct.
public struct BookcaseEvidence: Codable, Equatable, Sendable {
  public let chapterID: String
  public let quote: String
  public let utf16Location: Int?
  public internal(set) var anchor: TextAnchor?

  public init(chapterID: String, quote: String, utf16Location: Int? = nil) {
    self.chapterID = chapterID; self.quote = quote; self.utf16Location = utf16Location
  }
  enum CodingKeys: String, CodingKey {
    case chapterID = "chapter_id", quote, utf16Location = "utf16_location", anchor
  }

  public func anchored(in document: NovelDocument) throws -> Self {
    guard !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, quote.count <= 2_000,
      let chapter = document.chapters.first(where: { $0.id == chapterID })
    else { throw AdaptationError.evidenceMismatch }
    let range: NSRange
    if let offset = utf16Location {
      let length = quote.utf16.count, total = chapter.content.utf16.count
      guard offset >= 0, offset <= total, length <= total - offset,
        let indices = Range(NSRange(location: offset, length: length), in: chapter.content),
        chapter.content[indices].utf8.elementsEqual(quote.utf8) else { throw AdaptationError.evidenceMismatch }
      range = NSRange(location: offset, length: length)
    } else {
      guard let first = chapter.content.range(of: quote, options: .literal) else {
        throw AdaptationError.evidenceMismatch
      }
      // Search after the first start, including overlapping repeated quotes.
      let afterStart = chapter.content.index(after: first.lowerBound)
      guard chapter.content.range(of: quote, options: .literal, range: afterStart..<chapter.content.endIndex) == nil
      else { throw AdaptationError.evidenceMismatch }
      range = NSRange(first, in: chapter.content)
    }
    var result = Self(chapterID: chapterID, quote: quote, utf16Location: range.location)
    result.anchor = try TextAnchor(document: document, chapter: chapter,
      range: .init(location: range.location, length: range.length))
    return result
  }
}

public struct BookcaseMilestone: Codable, Equatable, Sendable {
  public var note: String
  public var evidence: [BookcaseEvidence]
  public init(note: String, evidence: [BookcaseEvidence]) { self.note = note; self.evidence = evidence }
}

public struct BookcaseCharacter: Codable, Equatable, Identifiable, Sendable {
  public enum Origin: String, Codable, Sendable { case extracted, author }
  public let id: String
  public var name: String
  public var identityCore = ""
  public var speechStyle = ""
  public var relationStance = ""
  public var sampleLines: [String] = []
  public var hardFacts: [String] = []
  public var relationshipProgress: [BookcaseMilestone] = []
  public var prominence: Int?
  public var evidence: [BookcaseEvidence] = []
  public internal(set) var origin: Origin = .extracted

  public init(id: String, name: String, evidence: [BookcaseEvidence] = []) {
    self.id = id; self.name = name; self.evidence = evidence
  }
  /// Legacy cards have no reliable identity. The caller must explicitly choose
  /// a stable ID; importing two equal names never silently merges them.
  public static func importLegacy(_ data: Data, characterID: String) throws -> Self {
    guard data.count <= 131_072, var object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw AdaptationError.invalidBookcase }
    object["id"] = characterID
    if object["speech_style"] == nil { object["speech_style"] = object["voice_style"] }
    object["origin"] = Origin.author.rawValue
    let result = try AdaptationCoding.decoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: object))
    guard !result.id.isEmpty, !result.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AdaptationError.invalidBookcase
    }
    return result
  }
  enum CodingKeys: String, CodingKey {
    case id, name, prominence, evidence, origin
    case identityCore = "identity_core", speechStyle = "speech_style", relationStance = "relation_stance"
    case sampleLines = "sample_lines", hardFacts = "hard_facts", relationshipProgress = "relationship_progress"
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
    identityCore = try c.decodeIfPresent(String.self, forKey: .identityCore) ?? ""
    speechStyle = try c.decodeIfPresent(String.self, forKey: .speechStyle) ?? ""
    relationStance = try c.decodeIfPresent(String.self, forKey: .relationStance) ?? ""
    sampleLines = try c.decodeIfPresent([String].self, forKey: .sampleLines) ?? []
    hardFacts = try c.decodeIfPresent([String].self, forKey: .hardFacts) ?? []
    relationshipProgress = try c.decodeIfPresent([BookcaseMilestone].self, forKey: .relationshipProgress) ?? []
    prominence = try c.decodeIfPresent(Int.self, forKey: .prominence)
    evidence = try c.decodeIfPresent([BookcaseEvidence].self, forKey: .evidence) ?? []
    origin = try c.decodeIfPresent(Origin.self, forKey: .origin) ?? .extracted
  }
}

public struct BookcaseRelationship: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let a: String
  public let b: String
  public var summary: String
  public var milestones: [BookcaseMilestone]
  public var evidence: [BookcaseEvidence]
  public init(id: String, a: String, b: String, summary: String,
    milestones: [BookcaseMilestone] = [], evidence: [BookcaseEvidence]) {
    self.id = id; self.a = a; self.b = b; self.summary = summary
    self.milestones = milestones; self.evidence = evidence
  }
  enum CodingKeys: String, CodingKey { case id, a, b, summary, milestones, evidence }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id); a = try c.decode(String.self, forKey: .a)
    b = try c.decode(String.self, forKey: .b); summary = try c.decode(String.self, forKey: .summary)
    milestones = try c.decodeIfPresent([BookcaseMilestone].self, forKey: .milestones) ?? []
    evidence = try c.decodeIfPresent([BookcaseEvidence].self, forKey: .evidence) ?? []
  }
}

public struct BookcaseWorldRule: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public var name: String
  public var facts: [String]
  public var binding: String
  public var evidence: [BookcaseEvidence]
  public init(id: String, name: String, facts: [String], binding: String = "", evidence: [BookcaseEvidence]) {
    self.id = id; self.name = name; self.facts = facts; self.binding = binding; self.evidence = evidence
  }
  enum CodingKeys: String, CodingKey { case id, name, facts, binding, evidence }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
    facts = try c.decodeIfPresent([String].self, forKey: .facts) ?? []
    binding = try c.decodeIfPresent(String.self, forKey: .binding) ?? ""
    evidence = try c.decodeIfPresent([BookcaseEvidence].self, forKey: .evidence) ?? []
  }
}

public struct BookcaseMoment: Codable, Equatable, Sendable {
  public var note: String
  public var involvedCharacterIDs: [String]
  public var evidence: BookcaseEvidence
  public init(note: String, involvedCharacterIDs: [String] = [], evidence: BookcaseEvidence) {
    self.note = note; self.involvedCharacterIDs = involvedCharacterIDs; self.evidence = evidence
  }
  enum CodingKeys: String, CodingKey { case note, evidence, involvedCharacterIDs = "involved_character_ids" }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    note = try c.decode(String.self, forKey: .note)
    evidence = try c.decode(BookcaseEvidence.self, forKey: .evidence)
    involvedCharacterIDs = try c.decodeIfPresent([String].self, forKey: .involvedCharacterIDs) ?? []
  }
}

public struct BookcaseChapter: Codable, Equatable, Identifiable, Sendable {
  public var id: String { chapterID }
  public let chapterID: String
  public internal(set) var ordinal: Int?
  public internal(set) var title: String?
  public var summary: String
  public var moments: [BookcaseMoment]
  public var evidence: [BookcaseEvidence]
  public init(chapterID: String, summary: String, moments: [BookcaseMoment] = [], evidence: [BookcaseEvidence]) {
    self.chapterID = chapterID; self.summary = summary; self.moments = moments; self.evidence = evidence
  }
  enum CodingKeys: String, CodingKey { case chapterID = "chapter_id", ordinal, title, summary, moments, evidence }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    chapterID = try c.decode(String.self, forKey: .chapterID)
    ordinal = try c.decodeIfPresent(Int.self, forKey: .ordinal); title = try c.decodeIfPresent(String.self, forKey: .title)
    summary = try c.decode(String.self, forKey: .summary)
    moments = try c.decodeIfPresent([BookcaseMoment].self, forKey: .moments) ?? []
    evidence = try c.decodeIfPresent([BookcaseEvidence].self, forKey: .evidence) ?? []
  }
}

public struct NovelBookcase: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public var characters: [BookcaseCharacter]
  public var relationships: [BookcaseRelationship]
  public var worldRules: [BookcaseWorldRule]
  public var chapters: [BookcaseChapter]
  public var meta: Metadata

  public struct Metadata: Codable, Equatable, Sendable {
    public let sourceSnapshotHash: String
    public let extractorVersion: String
    public internal(set) var manualCharacterIDs: [String]
    public init(sourceSnapshotHash: String, extractorVersion: String) {
      self.sourceSnapshotHash = sourceSnapshotHash; self.extractorVersion = extractorVersion
      manualCharacterIDs = []
    }
    enum CodingKeys: String, CodingKey {
      case sourceSnapshotHash = "source_snapshot_hash", extractorVersion = "extractor_version"
      case manualCharacterIDs = "manual_character_ids"
    }
    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      sourceSnapshotHash = try c.decode(String.self, forKey: .sourceSnapshotHash)
      extractorVersion = try c.decode(String.self, forKey: .extractorVersion)
      manualCharacterIDs = try c.decodeIfPresent([String].self, forKey: .manualCharacterIDs) ?? []
    }
  }
  public init(meta: Metadata, characters: [BookcaseCharacter] = [], relationships: [BookcaseRelationship] = [],
    worldRules: [BookcaseWorldRule] = [], chapters: [BookcaseChapter] = []) {
    schemaVersion = 1; self.meta = meta; self.characters = characters; self.relationships = relationships
    self.worldRules = worldRules; self.chapters = chapters
  }
  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version", characters, relationships, worldRules = "world_rules", chapters, meta
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
    meta = try c.decode(Metadata.self, forKey: .meta)
    characters = try c.decodeIfPresent([BookcaseCharacter].self, forKey: .characters) ?? []
    relationships = try c.decodeIfPresent([BookcaseRelationship].self, forKey: .relationships) ?? []
    worldRules = try c.decodeIfPresent([BookcaseWorldRule].self, forKey: .worldRules) ?? []
    chapters = try c.decodeIfPresent([BookcaseChapter].self, forKey: .chapters) ?? []
  }

  /// Human cards replace only explicitly selected stable IDs, including empty
  /// fields. Equal names never merge. The retained origin distinguishes author
  /// additions from extracted source claims.
  public func applyingManualCharacters(_ replacements: [BookcaseCharacter]) throws -> Self {
    guard Set(replacements.map(\.id)).count == replacements.count else { throw AdaptationError.invalidBookcase }
    var result = self
    for var replacement in replacements {
      replacement.origin = .author
      if let index = result.characters.firstIndex(where: { $0.id == replacement.id }) {
        result.characters[index] = replacement
      } else {
        result.characters.append(replacement)
      }
    }
    result.meta.manualCharacterIDs = result.characters.filter { $0.origin == .author }.map(\.id).sorted()
    return result
  }

  /// The author supplies the complete retained card after reviewing all
  /// selected source cards. References follow the explicit identity decision;
  /// a relationship becoming self-referential requires separate correction.
  public func mergingCharacters(_ selectedIDs: Set<String>, replacement: BookcaseCharacter) throws -> Self {
    let known = Set(characters.map(\.id))
    guard !selectedIDs.isEmpty, selectedIDs.isSubset(of: known),
      !known.contains(replacement.id) || selectedIDs.contains(replacement.id) else { throw AdaptationError.invalidBookcase }
    var result = self
    result.characters.removeAll { selectedIDs.contains($0.id) }
    result = try result.applyingManualCharacters([replacement])
    result.relationships = try relationships.map { relation in
      let a = selectedIDs.contains(relation.a) ? replacement.id : relation.a
      let b = selectedIDs.contains(relation.b) ? replacement.id : relation.b
      guard a != b else { throw AdaptationError.invalidBookcase }
      return .init(id: relation.id, a: a, b: b, summary: relation.summary,
        milestones: relation.milestones, evidence: relation.evidence)
    }
    for index in result.chapters.indices {
      for momentIndex in result.chapters[index].moments.indices {
        var seen: Set<String> = []
        result.chapters[index].moments[momentIndex].involvedCharacterIDs = result.chapters[index].moments[momentIndex]
          .involvedCharacterIDs.map { selectedIDs.contains($0) ? replacement.id : $0 }.filter { seen.insert($0).inserted }
      }
    }
    return result
  }

  public func missingChapterIDs(in document: NovelDocument) -> [String] {
    let present = Set(chapters.map(\.chapterID))
    return document.chapters.filter { !present.contains($0.id) }.map(\.id)
  }

  /// Recompute ordinals/titles from stable IDs. Unknown IDs and ambiguous
  /// quotations fail closed; batch position and display names are never IDs.
  public func validated(in document: NovelDocument, snapshotHash: String) throws -> Self {
    guard schemaVersion == 1, meta.sourceSnapshotHash == snapshotHash,
      Set(document.chapters.map(\.id)).count == document.chapters.count,
      document.chapters.enumerated().allSatisfy({ $0.offset == $0.element.ordinal }),
      !meta.extractorVersion.isEmpty, meta.extractorVersion.count <= 256,
      characters.count <= 2_000, relationships.count <= 4_000, worldRules.count <= 2_000,
      chapters.count <= 10_000, try AdaptationCoding.encoder().encode(self).count <= 16_777_216
    else { throw AdaptationError.invalidBookcase }
    let ids = characters.map(\.id) + relationships.map(\.id) + worldRules.map(\.id)
    guard Set(ids).count == ids.count, ids.allSatisfy(validID),
      Set(chapters.map(\.chapterID)).count == chapters.count,
      Set(meta.manualCharacterIDs) == Set(characters.filter { $0.origin == .author }.map(\.id)),
      Set(meta.manualCharacterIDs).count == meta.manualCharacterIDs.count
    else { throw AdaptationError.invalidBookcase }
    let characterIDs = Set(characters.map(\.id))
    var result = self
    for index in result.characters.indices {
      var card = result.characters[index]
      guard short(card.name, 200), [card.identityCore, card.speechStyle, card.relationStance].allSatisfy({ $0.count <= 4_000 }),
        strings(card.sampleLines), strings(card.hardFacts), (card.prominence.map { (0...100).contains($0) } ?? true)
      else { throw AdaptationError.invalidBookcase }
      card.evidence = try evidence(card.evidence, in: document, required: card.origin == .extracted)
      card.relationshipProgress = try milestones(card.relationshipProgress, in: document)
      // Extracted sample lines also require a verbatim source occurrence.
      if card.origin == .extracted {
        guard card.sampleLines.allSatisfy({ line in card.evidence.contains { $0.quote.range(of: line, options: .literal) != nil } }) else {
          throw AdaptationError.evidenceMismatch
        }
      }
      result.characters[index] = card
    }
    for index in result.relationships.indices {
      var relation = result.relationships[index]
      guard relation.a != relation.b, characterIDs.contains(relation.a), characterIDs.contains(relation.b),
        short(relation.summary, 4_000) else { throw AdaptationError.invalidBookcase }
      relation.evidence = try evidence(relation.evidence, in: document)
      relation.milestones = try milestones(relation.milestones, in: document)
      result.relationships[index] = relation
    }
    for index in result.worldRules.indices {
      var rule = result.worldRules[index]
      guard short(rule.name, 200), !rule.facts.isEmpty, strings(rule.facts), rule.binding.count <= 2_000
      else { throw AdaptationError.invalidBookcase }
      rule.evidence = try evidence(rule.evidence, in: document)
      result.worldRules[index] = rule
    }
    let sources = Dictionary(uniqueKeysWithValues: document.chapters.map { ($0.id, $0) })
    for index in result.chapters.indices {
      var chapter = result.chapters[index]
      guard let original = sources[chapter.chapterID], short(chapter.summary, 8_000), chapter.moments.count <= 80
      else { throw AdaptationError.invalidBookcase }
      chapter.ordinal = original.ordinal; chapter.title = original.title
      chapter.evidence = try evidence(chapter.evidence, in: document,
        required: !original.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      guard chapter.evidence.allSatisfy({ $0.chapterID == chapter.chapterID }) else { throw AdaptationError.evidenceMismatch }
      for momentIndex in chapter.moments.indices {
        var moment = chapter.moments[momentIndex]
        guard short(moment.note, 2_000), moment.involvedCharacterIDs.count <= 32,
          Set(moment.involvedCharacterIDs).isSubset(of: characterIDs), moment.evidence.chapterID == chapter.chapterID
        else { throw AdaptationError.invalidBookcase }
        moment.evidence = try moment.evidence.anchored(in: document)
        chapter.moments[momentIndex] = moment
      }
      result.chapters[index] = chapter
    }
    result.chapters.sort { ($0.ordinal ?? 0) < ($1.ordinal ?? 0) }
    guard try AdaptationCoding.encoder().encode(result).count <= 16_777_216 else {
      throw AdaptationError.invalidBookcase
    }
    return result
  }
  private func validID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 160 && value.utf8.allSatisfy {
      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
    }
  }
  private func short(_ text: String, _ maximum: Int) -> Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= maximum
  }
  private func strings(_ values: [String]) -> Bool { values.count <= 40 && values.allSatisfy { short($0, 2_000) } }
  private func evidence(_ values: [BookcaseEvidence], in document: NovelDocument, required: Bool = true) throws -> [BookcaseEvidence] {
    guard (!required || !values.isEmpty), values.count <= 40 else { throw AdaptationError.invalidBookcase }
    return try values.map { try $0.anchored(in: document) }
  }
  private func milestones(_ values: [BookcaseMilestone], in document: NovelDocument) throws -> [BookcaseMilestone] {
    guard values.count <= 80 else { throw AdaptationError.invalidBookcase }
    return try values.map {
      guard short($0.note, 2_000) else { throw AdaptationError.invalidBookcase }
      return .init(note: $0.note, evidence: try evidence($0.evidence, in: document))
    }
  }
}

public struct BookcaseProposal: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let parentID: UUID?
  public let content: NovelBookcase
  public let contentHash: String
  public internal(set) var status: WritingProposalStatus
  public let createdAt: Date
  enum CodingKeys: String, CodingKey {
    case id, content, status, parentID = "parent_id", contentHash = "content_hash", createdAt = "created_at"
  }
}

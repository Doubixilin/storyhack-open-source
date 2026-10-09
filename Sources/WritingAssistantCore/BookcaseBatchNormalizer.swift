import Foundation
import NovelDocumentCore
import WritingCore

struct BookcaseRawBatch: Decodable {
  var characters: [BookcaseCharacter]
  var relationships: [BookcaseRelationship]
  var worldRules: [BookcaseWorldRule]
  var chapters: [BookcaseChapter]
  enum CodingKeys: String, CodingKey { case characters, relationships, worldRules = "world_rules", chapters }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    characters = try c.decodeIfPresent([BookcaseCharacter].self, forKey: .characters) ?? []
    relationships = try c.decodeIfPresent([BookcaseRelationship].self, forKey: .relationships) ?? []
    worldRules = try c.decodeIfPresent([BookcaseWorldRule].self, forKey: .worldRules) ?? []
    chapters = try c.decodeIfPresent([BookcaseChapter].self, forKey: .chapters) ?? []
  }
}

struct BookcaseBatchResult: Sendable {
  let unit: BookcaseExtractionUnit
  let bookcase: NovelBookcase
  let discardedCount: Int
  var complete: Bool { discardedCount == 0 && bookcase.chapters.count == 1 }
}

struct BookcaseBatchNormalizer {
  let document: NovelDocument
  let sourceHash: String
  let extractorVersion: String
  private var meta: NovelBookcase.Metadata { .init(sourceSnapshotHash: sourceHash, extractorVersion: extractorVersion) }

  func normalize(_ text: String, unit: BookcaseExtractionUnit) throws -> BookcaseBatchResult {
    let raw = try AdaptationCoding.decoder().decode(BookcaseRawBatch.self, from: Data(text.utf8))
    guard raw.characters.count <= 24, raw.relationships.count <= 32, raw.worldRules.count <= 16,
      raw.chapters.count <= 1 else { throw AdaptationExecutionError.invalidResponse }
    var result = NovelBookcase(meta: meta), discarded = 0
    var characterIDs: [String: String] = [:]
    // IDs are namespaced by immutable source segment, not names or batch index.
    let prefix = "auto-" + AdaptationCoding.hash(Data((sourceHash + "|" + unit.id).utf8)).prefix(16)
    func id(_ local: String, kind: String) throws -> String {
      guard !local.isEmpty, local.utf8.count <= 80, local.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
      }) else { throw AdaptationError.invalidBookcase }
      return prefix + "-" + kind + "-" + local
    }
    let duplicatedCharacters = Set(Dictionary(grouping: raw.characters, by: \.id).filter { $0.value.count > 1 }.keys)
    for character in raw.characters {
      do {
        guard character.origin == .extracted, !duplicatedCharacters.contains(character.id) else { throw AdaptationError.invalidBookcase }
        let stableID = try id(character.id, kind: "c")
        var card = BookcaseCharacter(id: stableID, name: character.name, evidence: try evidence(character.evidence, unit: unit))
        card.identityCore = character.identityCore; card.speechStyle = character.speechStyle
        card.relationStance = character.relationStance; card.sampleLines = character.sampleLines
        card.hardFacts = character.hardFacts; card.prominence = character.prominence
        card.relationshipProgress = try milestones(character.relationshipProgress, unit: unit)
        let checked = try NovelBookcase(meta: meta, characters: [card]).validated(in: document, snapshotHash: sourceHash)
        result.characters += checked.characters; characterIDs[character.id] = stableID
      } catch { discarded += 1 }
    }
    for relation in raw.relationships {
      do {
        guard let a = characterIDs[relation.a], let b = characterIDs[relation.b] else { throw AdaptationError.invalidBookcase }
        let value = BookcaseRelationship(id: try id(relation.id, kind: "r"), a: a, b: b, summary: relation.summary,
          milestones: try milestones(relation.milestones, unit: unit), evidence: try evidence(relation.evidence, unit: unit))
        guard !result.relationships.contains(where: { $0.id == value.id }) else { throw AdaptationError.invalidBookcase }
        let checked = try NovelBookcase(meta: meta, characters: result.characters, relationships: [value])
          .validated(in: document, snapshotHash: sourceHash)
        result.relationships += checked.relationships
      } catch { discarded += 1 }
    }
    for rule in raw.worldRules {
      do {
        let value = BookcaseWorldRule(id: try id(rule.id, kind: "w"), name: rule.name, facts: rule.facts,
          binding: rule.binding, evidence: try evidence(rule.evidence, unit: unit))
        guard !result.worldRules.contains(where: { $0.id == value.id }) else { throw AdaptationError.invalidBookcase }
        let checked = try NovelBookcase(meta: meta, worldRules: [value]).validated(in: document, snapshotHash: sourceHash)
        result.worldRules += checked.worldRules
      } catch { discarded += 1 }
    }
    if let chapter = raw.chapters.first {
      do {
        guard chapter.chapterID == unit.chapterID, chapter.moments.count <= 24 else { throw AdaptationError.invalidBookcase }
        var moments: [BookcaseMoment] = []
        for moment in chapter.moments {
          do {
            let ids = try moment.involvedCharacterIDs.map { localID in
              guard let value = characterIDs[localID] else { throw AdaptationError.invalidBookcase }
              return value
            }
            moments.append(.init(note: moment.note, involvedCharacterIDs: ids, evidence: try quote(moment.evidence, unit: unit)))
          } catch { discarded += 1 }
        }
        let value = BookcaseChapter(chapterID: unit.chapterID, summary: chapter.summary, moments: moments,
          evidence: try evidence(chapter.evidence, unit: unit))
        let checked = try NovelBookcase(meta: meta, characters: result.characters, chapters: [value])
          .validated(in: document, snapshotHash: sourceHash)
        result.chapters = checked.chapters
      } catch { discarded += 1 }
    }
    return .init(unit: unit, bookcase: result, discardedCount: discarded)
  }

  private func evidence(_ values: [BookcaseEvidence], unit: BookcaseExtractionUnit) throws -> [BookcaseEvidence] {
    try values.map { try quote($0, unit: unit) }
  }
  private func milestones(_ values: [BookcaseMilestone], unit: BookcaseExtractionUnit) throws -> [BookcaseMilestone] {
    try values.map { .init(note: $0.note, evidence: try evidence($0.evidence, unit: unit)) }
  }
  private func quote(_ evidence: BookcaseEvidence, unit: BookcaseExtractionUnit) throws -> BookcaseEvidence {
    try unit.anchoredEvidence(evidence, in: document)
  }
}

extension BookcaseExtractionUnit {
  func anchoredEvidence(_ evidence: BookcaseEvidence, in document: NovelDocument) throws -> BookcaseEvidence {
    let unit = self
    guard evidence.chapterID == unit.chapterID, !evidence.quote.isEmpty else { throw AdaptationError.evidenceMismatch }
    let offset: Int
    if let supplied = evidence.utf16Location { offset = supplied }
    else {
      guard let first = unit.text.range(of: evidence.quote, options: .literal),
        unit.text.range(of: evidence.quote, options: .literal,
          range: unit.text.index(after: first.lowerBound)..<unit.text.endIndex) == nil else { throw AdaptationError.evidenceMismatch }
      offset = unit.offset + NSRange(first, in: unit.text).location
    }
    guard offset >= unit.offset, offset <= unit.end, evidence.quote.utf16.count <= unit.end - offset else {
      throw AdaptationError.evidenceMismatch
    }
    return try BookcaseEvidence(chapterID: unit.chapterID, quote: evidence.quote, utf16Location: offset).anchored(in: document)
  }
}

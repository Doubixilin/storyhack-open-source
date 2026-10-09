import CryptoKit
import Foundation

public enum SpeechSourceKind: String, Codable, Equatable, Sendable {
  case publishedChapter = "published_chapter"
  case committedTurn = "committed_turn"
}

public struct SpeechSource: Codable, Equatable, Sendable {
  public let kind: SpeechSourceKind
  public let sourceID: String
  public let contentHash: String

  public init(kind: SpeechSourceKind, sourceID: String, contentHash: String) {
    self.kind = kind
    self.sourceID = sourceID
    self.contentHash = contentHash
  }

  enum CodingKeys: String, CodingKey {
    case kind
    case sourceID = "source_id"
    case contentHash = "content_hash"
  }
}

public struct SpeechSegment: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let text: String
  public let utf16Location: Int
  public let utf16Length: Int

  public init(id: String, text: String, utf16Location: Int, utf16Length: Int) {
    self.id = id
    self.text = text
    self.utf16Location = utf16Location
    self.utf16Length = utf16Length
  }

  enum CodingKeys: String, CodingKey {
    case id
    case text
    case utf16Location = "utf16_location"
    case utf16Length = "utf16_length"
  }
}

public struct SpeechPlan: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let source: SpeechSource
  public let segments: [SpeechSegment]
  public let pronunciationHints: [String: String]
  public let language: String
  public let semanticVoice: String
  public let rate: Float
  public let plannerVersion: String
  public let createdAt: Date

  public init(
    id: String,
    source: SpeechSource,
    segments: [SpeechSegment],
    pronunciationHints: [String: String],
    language: String,
    semanticVoice: String,
    rate: Float,
    plannerVersion: String,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.source = source
    self.segments = segments
    self.pronunciationHints = pronunciationHints
    self.language = language
    self.semanticVoice = semanticVoice
    self.rate = rate
    self.plannerVersion = plannerVersion
    self.createdAt = createdAt
  }

  enum CodingKeys: String, CodingKey {
    case id
    case source
    case segments
    case pronunciationHints = "pronunciation_hints"
    case language
    case semanticVoice = "semantic_voice"
    case rate
    case plannerVersion = "planner_version"
    case createdAt = "created_at"
  }
}

public struct SpeechPlaybackLocation: Codable, Equatable, Sendable {
  public let sourceID: String
  public let sourceContentHash: String
  public var segmentIndex: Int
  public var characterOffset: Int
  public var updatedAt: Date

  public init(
    sourceID: String,
    sourceContentHash: String,
    segmentIndex: Int = 0,
    characterOffset: Int = 0,
    updatedAt: Date = Date()
  ) {
    self.sourceID = sourceID
    self.sourceContentHash = sourceContentHash
    self.segmentIndex = max(segmentIndex, 0)
    self.characterOffset = max(characterOffset, 0)
    self.updatedAt = updatedAt
  }

  enum CodingKeys: String, CodingKey {
    case sourceID = "source_id"
    case sourceContentHash = "source_content_hash"
    case segmentIndex = "segment_index"
    case characterOffset = "character_offset"
    case updatedAt = "updated_at"
  }
}

public enum SpeechPlanBuilder {
  public static let plannerVersion = "apple-single-narrator-v1"

  public static func singleNarrator(
    kind: SpeechSourceKind,
    sourceID: String,
    text: String,
    language: String = "zh-CN",
    semanticVoice: String = "系统中文旁白",
    rate: Float = 0.48,
    pronunciationHints: [String: String] = [:],
    maximumSegmentCharacterCount: Int = 900
  ) -> SpeechPlan {
    let contentHash = sha256(text)
    let source = SpeechSource(kind: kind, sourceID: sourceID, contentHash: contentHash)
    let segmentTexts = splitPreservingText(
      text,
      maximumCharacterCount: maximumSegmentCharacterCount
    )
    var utf16Location = 0
    let segments = segmentTexts.enumerated().map { index, segmentText in
      let length = segmentText.utf16.count
      defer { utf16Location += length }
      return SpeechSegment(
        id: "\(sourceID)-\(index)",
        text: segmentText,
        utf16Location: utf16Location,
        utf16Length: length
      )
    }
    let cacheKeyMaterial = [
      plannerVersion,
      kind.rawValue,
      sourceID,
      contentHash,
      language,
      semanticVoice,
      String(rate),
      pronunciationHints.sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }
        .joined(separator: "&"),
    ].joined(separator: "|")
    return SpeechPlan(
      id: sha256(cacheKeyMaterial),
      source: source,
      segments: segments,
      pronunciationHints: pronunciationHints,
      language: language,
      semanticVoice: semanticVoice,
      rate: rate,
      plannerVersion: plannerVersion
    )
  }

  private static func splitPreservingText(
    _ text: String,
    maximumCharacterCount: Int
  ) -> [String] {
    guard !text.isEmpty else { return [] }
    let maximum = max(maximumCharacterCount, 80)
    let preferredBreaks = CharacterSet(charactersIn: "。！？!?；;\n")
    var result: [String] = []
    var start = text.startIndex
    while start < text.endIndex {
      let hardEnd = text.index(start, offsetBy: maximum, limitedBy: text.endIndex)
        ?? text.endIndex
      var end = hardEnd
      if hardEnd < text.endIndex {
        let searchStart = text.index(start, offsetBy: max(maximum - 180, 1), limitedBy: hardEnd)
          ?? start
        var cursor = hardEnd
        while cursor > searchStart {
          let previous = text.index(before: cursor)
          let scalar = text[previous].unicodeScalars.first
          if let scalar, preferredBreaks.contains(scalar) {
            end = cursor
            break
          }
          cursor = previous
        }
      }
      guard end > start else { break }
      result.append(String(text[start..<end]))
      start = end
    }
    return result
  }

  private static func sha256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

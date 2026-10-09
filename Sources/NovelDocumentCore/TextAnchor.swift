import Foundation

public struct TextUTF16Range: Codable, Equatable, Sendable {
  public let location: Int
  public let length: Int

  public init(location: Int, length: Int) {
    self.location = max(0, location)
    self.length = max(0, length)
  }

  public var upperBound: Int { location + length }
}

/// A version-pinned source reference shared by reading, factory evidence and future media.
public struct TextAnchor: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public let contentHash: String
  public let chapterID: String
  public let range: TextUTF16Range
  public let before: String
  public let after: String

  public init(
    schemaVersion: Int = TextAnchor.currentSchemaVersion,
    contentHash: String,
    chapterID: String,
    range: TextUTF16Range,
    before: String = "",
    after: String = ""
  ) {
    self.schemaVersion = schemaVersion
    self.contentHash = contentHash
    self.chapterID = chapterID
    self.range = range
    self.before = before
    self.after = after
  }

  public init(
    document: NovelDocument,
    chapter: NovelChapter,
    range: TextUTF16Range,
    contextLength: Int = 32
  ) throws {
    guard document.chapters.contains(where: { $0.id == chapter.id }) else {
      throw TextAnchorError.chapterNotFound(chapter.id)
    }
    let utf16Count = chapter.content.utf16.count
    guard range.location >= 0, range.upperBound <= utf16Count else {
      throw TextAnchorError.rangeOutOfBounds
    }
    guard
      Range(
        NSRange(location: range.location, length: range.length),
        in: chapter.content
      ) != nil
    else { throw TextAnchorError.rangeOutOfBounds }
    let beforeStart = max(0, range.location - max(0, contextLength))
    let afterEnd = min(utf16Count, range.upperBound + max(0, contextLength))
    self.init(
      contentHash: document.contentHash,
      chapterID: chapter.id,
      range: range,
      before: chapter.content.utf16Substring(
        location: beforeStart,
        length: range.location - beforeStart
      ),
      after: chapter.content.utf16Substring(
        location: range.upperBound,
        length: afterEnd - range.upperBound
      )
    )
  }

  public func resolve(in document: NovelDocument) throws -> String {
    guard schemaVersion == Self.currentSchemaVersion else {
      throw TextAnchorError.unsupportedSchema(schemaVersion)
    }
    guard document.contentHash == contentHash else {
      throw TextAnchorError.contentVersionMismatch
    }
    guard let chapter = document.chapters.first(where: { $0.id == chapterID }) else {
      throw TextAnchorError.chapterNotFound(chapterID)
    }
    guard range.upperBound <= chapter.content.utf16.count else {
      throw TextAnchorError.rangeOutOfBounds
    }
    guard
      Range(
        NSRange(location: range.location, length: range.length),
        in: chapter.content
      ) != nil
    else { throw TextAnchorError.rangeOutOfBounds }
    let actualBefore = chapter.content.utf16Substring(
      location: max(0, range.location - before.utf16.count),
      length: min(before.utf16.count, range.location)
    )
    let actualAfter = chapter.content.utf16Substring(
      location: range.upperBound,
      length: min(after.utf16.count, chapter.content.utf16.count - range.upperBound)
    )
    guard actualBefore == before, actualAfter == after else {
      throw TextAnchorError.contextMismatch
    }
    return chapter.content.utf16Substring(location: range.location, length: range.length)
  }
}

public enum TextAnchorError: Error, Equatable, LocalizedError {
  case unsupportedSchema(Int)
  case contentVersionMismatch
  case chapterNotFound(String)
  case rangeOutOfBounds
  case contextMismatch

  public var errorDescription: String? {
    switch self {
    case .unsupportedSchema(let version): "不支持的文本锚点版本：\(version)"
    case .contentVersionMismatch: "来源版本不一致"
    case .chapterNotFound(let id): "来源章节不存在：\(id)"
    case .rangeOutOfBounds: "来源字符区间无效"
    case .contextMismatch: "来源正文上下文不一致"
    }
  }
}

extension String {
  fileprivate func utf16Substring(location: Int, length: Int) -> String {
    let view = utf16
    let start = view.index(view.startIndex, offsetBy: location)
    let end = view.index(start, offsetBy: length)
    return String(decoding: view[start..<end], as: UTF16.self)
  }
}

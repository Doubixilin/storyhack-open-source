import Foundation
import NovelDocumentCore

public enum ReaderLocatorAnchorError: Error, Equatable, LocalizedError {
  case missingChapter
  case missingUTF16Range
  case contentVersionMismatch

  public var errorDescription: String? {
    switch self {
    case .missingChapter: "阅读位置缺少章节身份"
    case .missingUTF16Range: "阅读位置缺少稳定字符区间"
    case .contentVersionMismatch: "来源版本不一致"
    }
  }
}

extension ReaderLocator {
  public init(anchor: TextAnchor, type: String, title: String? = nil) {
    self.init(
      href: "text/\(anchor.chapterID)",
      type: type,
      title: title,
      locations: .init(fragments: [
        "chapter=\(anchor.chapterID)",
        "utf16=\(anchor.range.location):\(anchor.range.length)",
        "content=\(anchor.contentHash)",
      ]),
      text: .init(before: anchor.before, after: anchor.after)
    )
  }

  public func textAnchor(expectedContentHash: String? = nil) throws -> TextAnchor {
    let pairs: [(String, String)] = locations.fragments.compactMap { fragment in
      guard let separator = fragment.firstIndex(of: "=") else { return nil }
      return (
        String(fragment[..<separator]),
        String(fragment[fragment.index(after: separator)...])
      )
    }
    let values = Dictionary(uniqueKeysWithValues: pairs)
    guard let chapterID = values["chapter"] else {
      throw ReaderLocatorAnchorError.missingChapter
    }
    guard let rawRange = values["utf16"]?.split(separator: ":", maxSplits: 1),
      rawRange.count == 2,
      let location = Int(rawRange[0]),
      let length = Int(rawRange[1])
    else { throw ReaderLocatorAnchorError.missingUTF16Range }
    let contentHash = values["content"] ?? expectedContentHash ?? ""
    if let expectedContentHash, contentHash != expectedContentHash {
      throw ReaderLocatorAnchorError.contentVersionMismatch
    }
    return TextAnchor(
      contentHash: contentHash,
      chapterID: chapterID,
      range: .init(location: location, length: length),
      before: text?.before ?? "",
      after: text?.after ?? ""
    )
  }
}

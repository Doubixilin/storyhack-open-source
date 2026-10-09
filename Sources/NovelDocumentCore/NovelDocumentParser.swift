import Foundation

public struct NovelDocumentParser: Sendable {
  private let textParser: TextNovelParser
  private let epubParser: EPUBNovelParser

  public init(maximumBytes: Int = 100 * 1_048_576) {
    textParser = TextNovelParser(maximumBytes: maximumBytes)
    epubParser = EPUBNovelParser(maximumBytes: maximumBytes)
  }

  public func parse(at sourceURL: URL, documentID: UUID = UUID()) throws -> NovelDocument {
    if sourceURL.pathExtension.lowercased() == NovelSourceFormat.epub.rawValue {
      return try epubParser.parse(at: sourceURL, documentID: documentID)
    }
    return try textParser.parse(at: sourceURL, documentID: documentID)
  }
}

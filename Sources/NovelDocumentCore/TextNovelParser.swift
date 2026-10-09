import CoreFoundation
import CryptoKit
import Foundation

public enum NovelDocumentParserError: Error, Equatable, LocalizedError {
  case unsupportedFormat(String)
  case sourceTooLarge(Int)
  case unreadableText
  case emptyDocument

  public var errorDescription: String? {
    switch self {
    case .unsupportedFormat(let fileExtension):
      "暂不支持 .\(fileExtension) 格式"
    case .sourceTooLarge(let maximumBytes):
      "文件超过当前单文件上限 \(maximumBytes / 1_048_576) MB"
    case .unreadableText:
      "无法识别小说文本编码"
    case .emptyDocument:
      "小说正文为空"
    }
  }
}

public struct TextNovelParser: Sendable {
  public let maximumBytes: Int
  private let fallbackSectionTargetLength = 30_000
  private let fallbackSectionMaximumLength = 50_000

  public init(maximumBytes: Int = 100 * 1_048_576) {
    self.maximumBytes = maximumBytes
  }

  public func parse(at sourceURL: URL, documentID: UUID = UUID()) throws -> NovelDocument {
    let sourceFormat = try format(for: sourceURL)
    let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
    let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
    guard byteCount <= maximumBytes else {
      throw NovelDocumentParserError.sourceTooLarge(maximumBytes)
    }

    let data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
    guard let text = decode(data), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw data.isEmpty
        ? NovelDocumentParserError.emptyDocument : NovelDocumentParserError.unreadableText
    }

    let chapters = splitIntoChapters(text, format: sourceFormat)
    guard !chapters.isEmpty else {
      throw NovelDocumentParserError.emptyDocument
    }

    return NovelDocument(
      id: documentID,
      title: sourceURL.deletingPathExtension().lastPathComponent,
      sourceFormat: sourceFormat,
      sourceFileName: sourceURL.lastPathComponent,
      contentHash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
      chapters: chapters
    )
  }

  private func format(for sourceURL: URL) throws -> NovelSourceFormat {
    switch sourceURL.pathExtension.lowercased() {
    case "txt":
      .text
    case "md", "markdown":
      .markdown
    default:
      throw NovelDocumentParserError.unsupportedFormat(sourceURL.pathExtension.lowercased())
    }
  }

  private func decode(_ data: Data) -> String? {
    let gb18030 = String.Encoding(
      rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(0x0632)
      )
    )

    if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
      return String(data: data, encoding: .utf16)
    }
    if let utf8 = String(data: data, encoding: .utf8) {
      return utf8
    }
    if let chineseText = String(data: data, encoding: gb18030) {
      return chineseText
    }
    return [String.Encoding.utf16LittleEndian, .utf16BigEndian]
      .lazy
      .compactMap { String(data: data, encoding: $0) }
      .first
  }

  private func splitIntoChapters(_ source: String, format: NovelSourceFormat) -> [NovelChapter] {
    let normalized =
      source
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    let lines = normalized.components(separatedBy: "\n")
    var sections: [(title: String, lines: [String])] = []
    var currentTitle: String?
    var currentLines: [String] = []

    func flush() {
      let content = currentLines.joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard currentTitle != nil || !content.isEmpty else { return }
      let title = currentTitle ?? (sections.isEmpty ? "正文" : "未命名章节")
      sections.append((title, content.isEmpty ? [""] : [content]))
      currentLines.removeAll(keepingCapacity: true)
    }

    for line in lines {
      if let heading = chapterHeading(from: line, format: format) {
        flush()
        currentTitle = heading
      } else {
        currentLines.append(line)
      }
    }
    flush()

    if format == .text, chapterSplitLooksLikeTableOfContents(sections) {
      let content = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
      return fallbackChaptersIfNeeded(content, baseTitle: "正文")
    }

    let chapters = sections.enumerated().map { index, section in
      NovelChapter(
        id: String(format: "chapter-%06d", index + 1),
        ordinal: index,
        title: section.title,
        content: section.lines.joined(separator: "\n")
      )
    }
    if chapters.count == 1, let chapter = chapters.first {
      return fallbackChaptersIfNeeded(chapter.content, baseTitle: chapter.title)
    }
    return chapters
  }

  private func fallbackChaptersIfNeeded(
    _ content: String,
    baseTitle: String
  ) -> [NovelChapter] {
    guard content.utf16.count > fallbackSectionMaximumLength else {
      return [
        NovelChapter(id: "chapter-000001", ordinal: 0, title: baseTitle, content: content)
      ]
    }

    let lines = content.components(separatedBy: "\n")
    var chunks: [String] = []
    var currentLines: [String] = []
    var currentLength = 0

    func flush() {
      let chunk = currentLines.joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !chunk.isEmpty else { return }
      chunks.append(chunk)
      currentLines.removeAll(keepingCapacity: true)
      currentLength = 0
    }

    for line in lines {
      let isParagraphStart = !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && currentLines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
      if currentLength >= fallbackSectionTargetLength, isParagraphStart {
        flush()
      } else if currentLength >= fallbackSectionMaximumLength, !currentLines.isEmpty {
        flush()
      }
      currentLines.append(line)
      currentLength += line.utf16.count + 1
    }
    flush()

    guard chunks.count > 1 else {
      return [
        NovelChapter(id: "chapter-000001", ordinal: 0, title: baseTitle, content: content)
      ]
    }
    return chunks.enumerated().map { index, chunk in
      NovelChapter(
        id: String(format: "chapter-%06d", index + 1),
        ordinal: index,
        title: "\(baseTitle) \(index + 1)",
        content: chunk
      )
    }
  }

  private func chapterSplitLooksLikeTableOfContents(
    _ sections: [(title: String, lines: [String])]
  ) -> Bool {
    guard sections.count >= 8 else { return false }
    let lengths = sections.map { $0.lines.joined(separator: "\n").utf16.count }
    let emptyCount = lengths.filter { $0 == 0 }.count
    let totalLength = lengths.reduce(0, +)
    let largestLength = lengths.max() ?? 0
    guard totalLength > 0 else { return false }
    return emptyCount * 2 >= sections.count
      && Double(largestLength) / Double(totalLength) >= 0.8
  }

  private func chapterHeading(from line: String, format: NovelSourceFormat) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if format == .markdown, let heading = markdownHeading(from: trimmed) {
      return heading
    }

    guard line.first?.isWhitespace != true else { return nil }
    return isChineseChapterHeading(trimmed) ? trimmed : nil
  }

  private func markdownHeading(from value: String) -> String? {
    let hashCount = value.prefix { $0 == "#" }.count
    guard (1...3).contains(hashCount) else { return nil }
    let headingStart = value.index(value.startIndex, offsetBy: hashCount)
    guard headingStart < value.endIndex, value[headingStart].isWhitespace else { return nil }
    var title = value[headingStart...].trimmingCharacters(in: .whitespaces)
    while title.last == "#" {
      title.removeLast()
      title = title.trimmingCharacters(in: .whitespaces)
    }
    return title.isEmpty ? nil : title
  }

  private func isChineseChapterHeading(_ value: String) -> Bool {
    var candidate = value[...]
    if candidate.hasPrefix("正文") {
      candidate = candidate.dropFirst(2)
      while candidate.first?.isWhitespace == true { candidate = candidate.dropFirst() }
    }
    guard candidate.first == "第" else { return false }
    let numeralStart = candidate.index(after: candidate.startIndex)
    let units = Set("章节回卷部篇集")
    guard let unitIndex = candidate[numeralStart...].firstIndex(where: { units.contains($0) })
    else { return false }
    let numeral = candidate[numeralStart..<unitIndex].filter { !$0.isWhitespace }
    let numeralCharacters = Set("0123456789０１２３４５６７８９零〇一二三四五六七八九十百千万两")
    guard !numeral.isEmpty, numeral.allSatisfy({ numeralCharacters.contains($0) }) else {
      return false
    }
    let suffix = candidate[candidate.index(after: unitIndex)...].trimmingCharacters(
      in: .whitespaces)
    guard suffix.count <= 60 else { return false }
    return true
  }
}

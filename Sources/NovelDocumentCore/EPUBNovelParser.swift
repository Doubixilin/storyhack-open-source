import CryptoKit
import Foundation
import ZIPFoundation

public enum EPUBParserError: Error, Equatable, LocalizedError {
  case invalidContainer
  case invalidPackage
  case encryptedPublication
  case missingSpine
  case unsafeArchivePath(String)
  case entryTooLarge(String)
  case emptyDocument

  public var errorDescription: String? {
    switch self {
    case .invalidContainer:
      "EPUB 缺少有效的 META-INF/container.xml"
    case .invalidPackage:
      "EPUB 的书目信息或正文清单无效"
    case .encryptedPublication:
      "暂不支持加密或受 DRM 保护的 EPUB"
    case .missingSpine:
      "EPUB 没有可读取的正文顺序"
    case .unsafeArchivePath:
      "EPUB 包含不安全的内部路径"
    case .entryTooLarge(let path):
      "EPUB 内部文件过大：\(path)"
    case .emptyDocument:
      "EPUB 中没有可读取的正文"
    }
  }
}

public struct EPUBNovelParser: Sendable {
  public let maximumBytes: Int
  public let maximumEntryBytes: Int
  public let maximumExtractedBytes: Int

  public init(
    maximumBytes: Int = 100 * 1_048_576,
    maximumEntryBytes: Int = 20 * 1_048_576,
    maximumExtractedBytes: Int = 200 * 1_048_576
  ) {
    self.maximumBytes = maximumBytes
    self.maximumEntryBytes = maximumEntryBytes
    self.maximumExtractedBytes = maximumExtractedBytes
  }

  public func parse(at sourceURL: URL, documentID: UUID = UUID()) throws -> NovelDocument {
    let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
    let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
    guard byteCount <= maximumBytes else {
      throw NovelDocumentParserError.sourceTooLarge(maximumBytes)
    }

    let sourceData = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
    let archive = try Archive(url: sourceURL, accessMode: .read)
    guard archive["META-INF/rights.xml"] == nil else {
      throw EPUBParserError.encryptedPublication
    }

    var extractedBytes = 0
    let containerData = try data(
      in: archive,
      path: "META-INF/container.xml",
      extractedBytes: &extractedBytes
    )
    let container = ContainerXMLParser()
    guard container.parse(containerData), let packagePath = container.packagePath else {
      throw EPUBParserError.invalidContainer
    }
    let safePackagePath = try normalize(path: packagePath)
    let packageData = try data(
      in: archive,
      path: safePackagePath,
      extractedBytes: &extractedBytes
    )
    let package = PackageXMLParser()
    guard package.parse(packageData), !package.manifest.isEmpty else {
      throw EPUBParserError.invalidPackage
    }
    guard !package.spine.isEmpty else {
      throw EPUBParserError.missingSpine
    }

    let packageDirectory = directory(of: safePackagePath)
    var chapters: [NovelChapter] = []
    for idref in package.spine {
      guard let item = package.manifest[idref], isReadableDocument(item.mediaType) else {
        continue
      }
      let resourcePath = try resolve(path: item.href, relativeTo: packageDirectory)
      let resourceData = try data(
        in: archive,
        path: resourcePath,
        extractedBytes: &extractedBytes
      )
      let extracted = XHTMLTextParser()
      guard extracted.parse(resourceData) else { continue }
      let body = extracted.body.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !body.isEmpty else { continue }

      let ordinal = chapters.count
      let title =
        extracted.heading?.trimmingCharacters(in: .whitespacesAndNewlines)
        ?? extracted.documentTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        ?? "第 \(ordinal + 1) 章"
      chapters.append(
        NovelChapter(
          id: String(format: "chapter-%06d", ordinal + 1),
          ordinal: ordinal,
          title: title.isEmpty ? "第 \(ordinal + 1) 章" : title,
          content: body,
          sourceHref: resourcePath,
          mediaType: item.mediaType
        )
      )
    }

    guard !chapters.isEmpty else {
      throw EPUBParserError.emptyDocument
    }

    let fallbackTitle = sourceURL.deletingPathExtension().lastPathComponent
    return NovelDocument(
      id: documentID,
      title: package.title?.nonEmpty ?? fallbackTitle,
      author: package.author?.nonEmpty,
      sourceFormat: .epub,
      sourceFileName: sourceURL.lastPathComponent,
      contentHash: SHA256.hash(data: sourceData).map { String(format: "%02x", $0) }.joined(),
      chapters: chapters
    )
  }

  private func data(
    in archive: Archive,
    path: String,
    extractedBytes: inout Int
  ) throws -> Data {
    let safePath = try normalize(path: path)
    guard let entry = archive[safePath], entry.type == .file else {
      throw safePath == "META-INF/container.xml"
        ? EPUBParserError.invalidContainer : EPUBParserError.invalidPackage
    }
    guard entry.uncompressedSize <= UInt32(maximumEntryBytes) else {
      throw EPUBParserError.entryTooLarge(safePath)
    }
    guard extractedBytes + Int(entry.uncompressedSize) <= maximumExtractedBytes else {
      throw EPUBParserError.entryTooLarge(safePath)
    }
    extractedBytes += Int(entry.uncompressedSize)
    var result = Data()
    result.reserveCapacity(Int(entry.uncompressedSize))
    _ = try archive.extract(entry) { chunk in
      result.append(chunk)
    }
    return result
  }

  private func isReadableDocument(_ mediaType: String) -> Bool {
    mediaType == "application/xhtml+xml" || mediaType == "text/html"
  }

  private func resolve(path: String, relativeTo base: String) throws -> String {
    let pathWithoutFragment =
      path.split(separator: "#", maxSplits: 1).first.map(String.init) ?? path
    let decoded = pathWithoutFragment.removingPercentEncoding ?? pathWithoutFragment
    return try normalize(path: base.isEmpty ? decoded : "\(base)/\(decoded)")
  }

  private func directory(of path: String) -> String {
    path.split(separator: "/").dropLast().joined(separator: "/")
  }

  private func normalize(path: String) throws -> String {
    guard !path.isEmpty, !path.hasPrefix("/") else {
      throw EPUBParserError.unsafeArchivePath(path)
    }
    var components: [Substring] = []
    for component in path.split(separator: "/", omittingEmptySubsequences: true) {
      switch component {
      case ".":
        continue
      case "..":
        guard !components.isEmpty else {
          throw EPUBParserError.unsafeArchivePath(path)
        }
        components.removeLast()
      default:
        components.append(component)
      }
    }
    guard !components.isEmpty else {
      throw EPUBParserError.unsafeArchivePath(path)
    }
    return components.joined(separator: "/")
  }
}

private struct EPUBManifestItem: Sendable {
  let href: String
  let mediaType: String
}

private final class ContainerXMLParser: NSObject, XMLParserDelegate {
  private(set) var packagePath: String?

  func parse(_ data: Data) -> Bool {
    let parser = XMLParser(data: data)
    parser.shouldResolveExternalEntities = false
    parser.delegate = self
    return parser.parse()
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String]
  ) {
    if localName(elementName) == "rootfile", packagePath == nil {
      packagePath = attributeDict["full-path"]
    }
  }
}

private final class PackageXMLParser: NSObject, XMLParserDelegate {
  private(set) var title: String?
  private(set) var author: String?
  private(set) var manifest: [String: EPUBManifestItem] = [:]
  private(set) var spine: [String] = []
  private var capturedElement: String?
  private var capturedText = ""

  func parse(_ data: Data) -> Bool {
    let parser = XMLParser(data: data)
    parser.shouldResolveExternalEntities = false
    parser.delegate = self
    return parser.parse()
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String]
  ) {
    switch localName(elementName) {
    case "title", "creator":
      capturedElement = localName(elementName)
      capturedText = ""
    case "item":
      if let id = attributeDict["id"],
        let href = attributeDict["href"],
        let mediaType = attributeDict["media-type"]
      {
        manifest[id] = EPUBManifestItem(href: href, mediaType: mediaType)
      }
    case "itemref":
      if attributeDict["linear"]?.lowercased() != "no", let idref = attributeDict["idref"] {
        spine.append(idref)
      }
    default:
      break
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    if capturedElement != nil { capturedText += string }
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    let name = localName(elementName)
    guard name == capturedElement else { return }
    let value = capturedText.trimmingCharacters(in: .whitespacesAndNewlines)
    if name == "title", title == nil { title = value }
    if name == "creator", author == nil { author = value }
    capturedElement = nil
    capturedText = ""
  }
}

private final class XHTMLTextParser: NSObject, XMLParserDelegate {
  private(set) var body = ""
  private(set) var heading: String?
  private(set) var documentTitle: String?
  private var bodyDepth = 0
  private var skippedDepth = 0
  private var capture: String?
  private var captureText = ""

  func parse(_ data: Data) -> Bool {
    let repaired =
      String(data: data, encoding: .utf8)?
      .replacingOccurrences(of: "&nbsp;", with: "&#160;")
      .data(using: .utf8) ?? data
    let parser = XMLParser(data: repaired)
    parser.shouldResolveExternalEntities = false
    parser.delegate = self
    guard parser.parse() else { return false }
    body = normalizeText(body)
    if let heading, body.hasPrefix(heading) {
      let remainder = body.dropFirst(heading.count)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      body = remainder
    }
    return true
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String]
  ) {
    let name = localName(elementName)
    if name == "body" { bodyDepth += 1 }
    if name == "script" || name == "style" { skippedDepth += 1 }
    if (name == "title" && documentTitle == nil)
      || (headingElements.contains(name) && heading == nil)
    {
      capture = name
      captureText = ""
    }
    if bodyDepth > 0, skippedDepth == 0, blockElements.contains(name) {
      appendBreak()
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    if capture != nil { captureText += string }
    if bodyDepth > 0, skippedDepth == 0 { body += string }
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    let name = localName(elementName)
    if name == capture {
      let value = normalizeText(captureText)
      if name == "title", documentTitle == nil { documentTitle = value.nonEmpty }
      if headingElements.contains(name), heading == nil { heading = value.nonEmpty }
      capture = nil
      captureText = ""
    }
    if bodyDepth > 0, skippedDepth == 0, blockElements.contains(name) {
      appendBreak()
    }
    if name == "script" || name == "style" { skippedDepth = max(skippedDepth - 1, 0) }
    if name == "body" { bodyDepth = max(bodyDepth - 1, 0) }
  }

  private func appendBreak() {
    if !body.hasSuffix("\n") { body.append("\n") }
  }

  private var blockElements: Set<String> {
    [
      "address", "article", "aside", "blockquote", "br", "div", "h1", "h2", "h3", "h4", "h5", "h6",
      "hr", "li", "p", "pre", "section",
    ]
  }

  private var headingElements: Set<String> {
    ["h1", "h2", "h3", "h4", "h5", "h6"]
  }

  private func normalizeText(_ value: String) -> String {
    value
      .replacingOccurrences(of: "[ \\t\\u{00a0}]+", with: " ", options: .regularExpression)
      .replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
      .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

private func localName(_ qualifiedName: String) -> String {
  qualifiedName.split(separator: ":").last.map(String.init)?.lowercased()
    ?? qualifiedName.lowercased()
}

extension String {
  fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}

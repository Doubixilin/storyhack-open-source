import CoreFoundation
import Foundation
import Testing
import ZIPFoundation

@testable import NovelDocumentCore

struct TextNovelParserTests {
  @Test
  func parsesChineseTextChaptersDeterministically() throws {
    let source = """
      序言内容
      第一章 初见
      这里是第一章正文。
      第二章 重逢
      这里是第二章正文。
      """
    let url = try makeTemporaryFile(name: "示例.txt", contents: source)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let documentID = UUID(uuidString: "B16B4101-16F7-4715-9540-F26FB0287E67")!
    let document = try TextNovelParser().parse(at: url, documentID: documentID)

    #expect(document.id == documentID)
    #expect(document.chapters.map(\.title) == ["正文", "第一章 初见", "第二章 重逢"])
    #expect(document.chapters.map(\.id) == ["chapter-000001", "chapter-000002", "chapter-000003"])
    #expect(document.chapters[1].content == "这里是第一章正文。")
    #expect(document.contentHash.count == 64)
  }

  @Test
  func parsesMarkdownHeadings() throws {
    let source = """
      # 开篇
      第一段。
      ## 第二节
      第二段。
      """
    let url = try makeTemporaryFile(name: "示例.md", contents: source)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let document = try TextNovelParser().parse(at: url)

    #expect(document.sourceFormat == .markdown)
    #expect(document.chapters.map(\.title) == ["开篇", "第二节"])
    #expect(document.chapters[1].content == "第二段。")
  }

  @Test
  func parsesChapterTitlesWithSpacingAndPunctuationWithoutTreatingIndentedProseAsHeading() throws {
    let source = """
      第1 章 开局穿书，反派退婚。
      第一段正文。
      　　第一章看完了？这只是正文中的一句话。
      第 2章 两人都嘎了！
      第二段正文。
      """
    let url = try makeTemporaryFile(name: "标题变体.txt", contents: source)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let document = try TextNovelParser().parse(at: url)

    #expect(document.chapters.map(\.title) == ["第1 章 开局穿书，反派退婚。", "第 2章 两人都嘎了！"])
    #expect(document.chapters[0].content.contains("第一章看完了"))
  }

  @Test
  func collapsesTableOfContentsMisdetectedAsMostlyEmptyChapters() throws {
    let headings = (1...10).map { "第\($0)章 目录标题" }.joined(separator: "\n")
    let body = String(repeating: "这是一段没有章节标题标记的连续正文。", count: 500)
    let source = headings + "\n" + body
    let url = try makeTemporaryFile(name: "目录误判.txt", contents: source)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let document = try TextNovelParser().parse(at: url)

    #expect(document.chapters.count == 1)
    #expect(document.chapters[0].title == "正文")
    #expect(document.chapters[0].content == source)
  }

  @Test
  func splitsVeryLongTableOfContentsFallbackAtParagraphBoundaries() throws {
    let headings = (1...10).map { "第\($0)章 目录标题" }.joined(separator: "\n")
    let paragraphs = (1...80).map { index in
      "第\(index)段 " + String(repeating: "这是没有可靠章节标题的长篇正文。", count: 180)
    }
    let source = headings + "\n\n" + paragraphs.joined(separator: "\n\n")
    let url = try makeTemporaryFile(name: "超长目录误判.txt", contents: source)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let document = try TextNovelParser().parse(at: url)

    #expect(document.chapters.count > 1)
    #expect(document.chapters.first?.title == "正文 1")
    #expect(document.chapters.last?.content.contains("第80段") == true)
    #expect(document.chapters.allSatisfy { !$0.content.isEmpty })
    #expect(document.chapters.allSatisfy { $0.content.utf16.count <= 55_000 })
  }

  @Test
  func decodesGB18030Text() throws {
    let encoding = String.Encoding(
      rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0632))
    )
    let source = "第一章 开始\n这是中文正文。"
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("国标编码.txt")
    try #require(source.data(using: encoding)).write(to: url)

    let document = try TextNovelParser().parse(at: url)

    #expect(document.chapters.first?.title == "第一章 开始")
    #expect(document.chapters.first?.content == "这是中文正文。")
  }

  @Test
  func parsesEPUBMetadataSpineAndText() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sourceRoot = directory.appendingPathComponent("epub-source", isDirectory: true)
    try FileManager.default.createDirectory(
      at: sourceRoot.appendingPathComponent("META-INF", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: sourceRoot.appendingPathComponent("OEBPS/Text", isDirectory: true),
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    try write(
      """
      <?xml version="1.0" encoding="UTF-8"?>
      <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
      </container>
      """,
      to: sourceRoot.appendingPathComponent("META-INF/container.xml")
    )
    try write(
      """
      <?xml version="1.0" encoding="UTF-8"?>
      <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:title>测试 EPUB</dc:title><dc:creator>测试作者</dc:creator>
        </metadata>
        <manifest>
          <item id="c1" href="Text/chapter1.xhtml" media-type="application/xhtml+xml"/>
          <item id="c2" href="Text/chapter2.xhtml" media-type="application/xhtml+xml"/>
        </manifest>
        <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
      </package>
      """,
      to: sourceRoot.appendingPathComponent("OEBPS/content.opf")
    )
    try write(
      "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>第一章</title></head><body><h1>第一章 初见</h1><p>第一段正文。</p><p>第二段正文。</p></body></html>",
      to: sourceRoot.appendingPathComponent("OEBPS/Text/chapter1.xhtml")
    )
    try write(
      "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>第二章</title></head><body><h2>第二章 重逢</h2><p>后续正文。</p></body></html>",
      to: sourceRoot.appendingPathComponent("OEBPS/Text/chapter2.xhtml")
    )

    let epubURL = directory.appendingPathComponent("fixture.epub")
    try FileManager.default.zipItem(
      at: sourceRoot,
      to: epubURL,
      shouldKeepParent: false,
      compressionMethod: .deflate
    )
    let document = try NovelDocumentParser().parse(at: epubURL)

    #expect(document.title == "测试 EPUB")
    #expect(document.author == "测试作者")
    #expect(document.sourceFormat == .epub)
    #expect(document.chapters.map(\.title) == ["第一章 初见", "第二章 重逢"])
    #expect(document.chapters[0].content == "第一段正文。\n第二段正文。")
    #expect(document.chapters[0].sourceHref == "OEBPS/Text/chapter1.xhtml")
  }

  private func makeTemporaryFile(name: String, contents: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try Data(contents.utf8).write(to: url)
    return url
  }

  private func write(_ contents: String, to url: URL) throws {
    try Data(contents.utf8).write(to: url)
  }
}

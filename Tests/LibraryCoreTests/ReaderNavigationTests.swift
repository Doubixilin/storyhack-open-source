import Foundation
import NovelDocumentCore
import Testing

@testable import LibraryCore

struct ReaderNavigationTests {
  @Test
  func paginatedReadingRestoresProgressAndCrossesChapterBoundaries() {
    let ranges = [
      ReaderPageRange(location: 0, length: 100),
      ReaderPageRange(location: 100, length: 80),
      ReaderPageRange(location: 180, length: 70),
    ]

    #expect(
      ReaderPageNavigation.pageIndex(
        for: 0.48,
        ranges: ranges,
        totalUTF16Length: 250
      ) == 1
    )
    #expect(
      ReaderPageNavigation.progression(
        for: ranges[2],
        totalUTF16Length: 250
      ) == 0.72
    )
    #expect(
      ReaderPageNavigation.turn(
        from: 1,
        pageCount: 3,
        direction: 1,
        hasPreviousChapter: true,
        hasNextChapter: true
      ) == .page(2)
    )
    #expect(
      ReaderPageNavigation.turn(
        from: 2,
        pageCount: 3,
        direction: 1,
        hasPreviousChapter: true,
        hasNextChapter: true
      ) == .nextChapter
    )
    #expect(
      ReaderPageNavigation.turn(
        from: 0,
        pageCount: 3,
        direction: -1,
        hasPreviousChapter: true,
        hasNextChapter: true
      ) == .previousChapter
    )
  }

  @Test
  func searchReturnsShareableLocatorAndContext() throws {
    let document = NovelDocument(
      id: UUID(uuidString: "A9E12709-C260-42B5-B726-960A1FE14706")!,
      title: "测试书",
      sourceFormat: .text,
      sourceFileName: "测试书.txt",
      contentHash: String(repeating: "a", count: 64),
      chapters: [
        NovelChapter(
          id: "chapter-000001",
          ordinal: 0,
          title: "第一章",
          content: "她走进雨里。后来两人在桥边再次相遇。"
        ),
        NovelChapter(
          id: "chapter-000002",
          ordinal: 1,
          title: "第二章",
          content: "相遇之后，故事继续。"
        ),
      ]
    )

    let results = ReaderNavigation.search("相遇", in: document)
    let first = try #require(results.first)

    #expect(results.count == 2)
    #expect(first.chapterID == "chapter-000001")
    #expect(first.locator.href == "text/chapter-000001")
    #expect(first.locator.locations.position == 1)
    #expect(first.locator.text?.highlight == "相遇")
    #expect(first.excerpt.contains("桥边再次相遇"))
  }

  @Test
  func sourceReferencePinsDocumentVersionAndLocation() throws {
    let document = NovelDocument(
      id: UUID(),
      title: "版本测试",
      sourceFormat: .epub,
      sourceFileName: "版本测试.epub",
      contentHash: String(repeating: "b", count: 64),
      chapters: [
        NovelChapter(
          id: "chapter-000001",
          ordinal: 0,
          title: "开篇",
          content: "正文",
          sourceHref: "Text/start.xhtml",
          mediaType: "application/xhtml+xml"
        )
      ]
    )
    let chapter = try #require(document.chapters.first)
    let locator = ReaderNavigation.locator(in: document, chapter: chapter, progression: 0.5)
    let reference = ReaderSourceReference(document: document, locator: locator)
    let encoded = try NovelDocumentCoding.makeEncoder().encode(reference)
    let decoded = try NovelDocumentCoding.makeDecoder().decode(
      ReaderSourceReference.self,
      from: encoded
    )

    #expect(decoded.contentHash == document.contentHash)
    #expect(decoded.locator?.href == "Text/start.xhtml")
    #expect(decoded.locator?.locations.progression == 0.5)
  }

  @Test
  func textAnchorRoundTripsThroughReaderLocatorAndRejectsWrongVersion() throws {
    let document = NovelDocument(
      id: UUID(),
      title: "锚点测试",
      sourceFormat: .text,
      sourceFileName: "锚点.txt",
      contentHash: String(repeating: "c", count: 64),
      chapters: [
        NovelChapter(id: "chapter-1", ordinal: 0, title: "开篇", content: "甲😀乙丙丁")
      ]
    )
    let chapter = try #require(document.chapters.first)
    let anchor = try TextAnchor(
      document: document,
      chapter: chapter,
      range: .init(location: 1, length: 2),
      contextLength: 2
    )
    let locator = ReaderLocator(anchor: anchor, type: "text/plain", title: chapter.title)
    let decoded = try locator.textAnchor(expectedContentHash: document.contentHash)

    #expect(decoded == anchor)
    #expect(try decoded.resolve(in: document) == "😀")
    #expect(throws: ReaderLocatorAnchorError.contentVersionMismatch) {
      try locator.textAnchor(expectedContentHash: String(repeating: "d", count: 64))
    }
  }
}

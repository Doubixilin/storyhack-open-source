import Foundation
import NovelDocumentCore

public enum ReaderNavigation {
  public static func locator(
    in document: NovelDocument,
    chapter: NovelChapter,
    progression: Double,
    text: ReaderLocatorText? = nil
  ) -> ReaderLocator {
    let normalizedProgression = min(max(progression, 0), 1)
    let precedingCharacters = document.chapters.prefix(chapter.ordinal).reduce(0) {
      $0 + $1.characterCount
    }
    let characterOffset = Int(Double(chapter.characterCount) * normalizedProgression)
    let totalProgression: Double
    if document.totalCharacterCount > 0 {
      totalProgression =
        Double(precedingCharacters + characterOffset)
        / Double(document.totalCharacterCount)
    } else {
      totalProgression = 0
    }
    return ReaderLocator(
      href: chapter.sourceHref ?? "text/\(chapter.id)",
      type: chapter.mediaType ?? "text/plain",
      title: chapter.title,
      locations: ReaderLocatorLocations(
        progression: normalizedProgression,
        position: chapter.ordinal + 1,
        totalProgression: totalProgression
      ),
      text: text
    )
  }

  public static func search(
    _ query: String,
    in document: NovelDocument,
    limit: Int = 100
  ) -> [ReaderSearchResult] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty, limit > 0 else { return [] }

    var results: [ReaderSearchResult] = []
    for chapter in document.chapters {
      var searchRange = chapter.content.startIndex..<chapter.content.endIndex
      var occurrence = 0
      while let match = chapter.content.range(
        of: needle,
        options: [.caseInsensitive, .diacriticInsensitive],
        range: searchRange
      ) {
        occurrence += 1
        let offset = chapter.content.distance(
          from: chapter.content.startIndex, to: match.lowerBound)
        let progression =
          chapter.content.isEmpty
          ? 0 : Double(offset) / Double(chapter.content.count)
        let beforeStart = chapter.content.index(
          match.lowerBound,
          offsetBy: -min(32, offset)
        )
        let remaining = chapter.content.distance(
          from: match.upperBound, to: chapter.content.endIndex)
        let afterEnd = chapter.content.index(
          match.upperBound,
          offsetBy: min(48, remaining)
        )
        let before = cleanExcerpt(String(chapter.content[beforeStart..<match.lowerBound]))
        let highlight = String(chapter.content[match])
        let after = cleanExcerpt(String(chapter.content[match.upperBound..<afterEnd]))
        let context = ReaderLocatorText(before: before, highlight: highlight, after: after)
        let locator = locator(
          in: document,
          chapter: chapter,
          progression: progression,
          text: context
        )
        results.append(
          ReaderSearchResult(
            id: "\(chapter.id)-\(occurrence)-\(offset)",
            chapterID: chapter.id,
            chapterTitle: chapter.title,
            excerpt: "\(before)\(highlight)\(after)",
            locator: locator
          )
        )
        if results.count >= limit { return results }
        guard match.upperBound < chapter.content.endIndex else { break }
        searchRange = match.upperBound..<chapter.content.endIndex
      }
    }
    return results
  }

  private static func cleanExcerpt(_ text: String) -> String {
    text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
  }
}

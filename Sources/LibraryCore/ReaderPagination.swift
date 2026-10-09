import Foundation

public struct ReaderPageRange: Equatable, Sendable {
  public let location: Int
  public let length: Int

  public init(location: Int, length: Int) {
    self.location = max(location, 0)
    self.length = max(length, 0)
  }

  public var upperBound: Int { location + length }
}

public enum ReaderPageTurnResult: Equatable, Sendable {
  case page(Int)
  case previousChapter
  case nextChapter
  case unavailable
}

public enum ReaderPageNavigation {
  public static func pageIndex(
    for progression: Double,
    ranges: [ReaderPageRange],
    totalUTF16Length: Int
  ) -> Int {
    guard !ranges.isEmpty else { return 0 }
    let normalized = min(max(progression, 0), 1)
    let offset = Int((normalized * Double(max(totalUTF16Length, 1))).rounded(.down))
    return ranges.firstIndex { offset < $0.upperBound }
      ?? max(ranges.count - 1, 0)
  }

  public static func progression(
    for range: ReaderPageRange,
    totalUTF16Length: Int
  ) -> Double {
    guard totalUTF16Length > 0 else { return 0 }
    return min(max(Double(range.location) / Double(totalUTF16Length), 0), 1)
  }

  public static func turn(
    from currentPage: Int,
    pageCount: Int,
    direction: Int,
    hasPreviousChapter: Bool,
    hasNextChapter: Bool
  ) -> ReaderPageTurnResult {
    guard pageCount > 0, direction != 0 else { return .unavailable }
    if direction < 0 {
      if currentPage > 0 { return .page(currentPage - 1) }
      return hasPreviousChapter ? .previousChapter : .unavailable
    }
    if currentPage + 1 < pageCount { return .page(currentPage + 1) }
    return hasNextChapter ? .nextChapter : .unavailable
  }
}

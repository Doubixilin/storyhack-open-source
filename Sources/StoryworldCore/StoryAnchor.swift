import Foundation

/// References the original event's branch-local sequence, never its position
/// in projected history. It remains valid when a package is imported as a copy.
public struct StoryAnchorEventRef: Codable, Hashable, Sendable {
  public let branchID: UUID
  public let sequence: Int
  public let turnID: UUID

  public init(branchID: UUID, sequence: Int, turnID: UUID) {
    self.branchID = branchID
    self.sequence = sequence
    self.turnID = turnID
  }

  public init(_ turn: CommittedStoryTurn) {
    self.init(branchID: turn.address.branchID, sequence: turn.sequence, turnID: turn.turnID)
  }

  public var scrollID: String {
    "anchor-\(branchID.uuidString.lowercased())-\(sequence)-\(turnID.uuidString.lowercased())"
  }
}

public struct StoryAnchor: Codable, Equatable, Identifiable, Sendable {
  public enum Kind: String, Codable, CaseIterable, Sendable {
    case relation, pledge, plot, voice, other
    public var title: String {
      switch self {
      case .relation: "关系"
      case .pledge: "承诺"
      case .plot: "剧情"
      case .voice: "声音"
      case .other: "其他"
      }
    }
  }

  public let id: UUID
  public let eventRef: StoryAnchorEventRef
  public var kind: Kind
  public var label: String
  public var note: String
  public var enabled: Bool
  public let createdAt: Date

  public init(
    id: UUID = UUID(), eventRef: StoryAnchorEventRef, kind: Kind = .other,
    label: String, note: String = "", enabled: Bool = true, createdAt: Date = Date()
  ) {
    self.id = id
    self.eventRef = eventRef
    self.kind = kind
    self.label = label
    self.note = note
    self.enabled = enabled
    self.createdAt = createdAt
  }
}

public struct StoryAnchorState: Codable, Equatable, Sendable {
  public let revision: UUID?
  public let anchors: [StoryAnchor]
  public let notice: String?

  public init(revision: UUID? = nil, anchors: [StoryAnchor] = [], notice: String? = nil) {
    self.revision = revision
    self.anchors = anchors
    self.notice = notice
  }
}

public enum StoryAnchorError: Error, Equatable, LocalizedError {
  case unreadable
  case staleRevision
  case invalidReference
  case invalidText
  case tooManyAnchors
  case duplicateEvent
  case fileTooLarge
  public var errorDescription: String? {
    switch self {
    case .unreadable: "锚点文件损坏或无法安全读取，已保留原文件。故事仍可阅读，请检查 anchors.json 后再编辑锚点。"
    case .staleRevision: "锚点已在另一端更新，请刷新后再编辑。"
    case .invalidReference: "锚点只能指向当前分支实际经历的回合。请刷新后重新选择。"
    case .invalidText: "锚点标题需为 1–100 字，笔记不能超过 1000 字。"
    case .tooManyAnchors: "每个分支最多保存 100 个锚点，请先整理已有锚点。"
    case .duplicateEvent: "这一回合已有锚点，请编辑已有锚点。"
    case .fileTooLarge: "锚点文件超过 1 MB，请缩短笔记后再保存。"
    }
  }
}

/// A mutable player annotation file. Neither changes nor copies touch events.
struct StoryAnchorFileStore {
  static let maximumCount = 100
  struct File: Codable {
    let schema_version: Int
    let revision: UUID
    let anchors: [StoryAnchor]
  }
  let url: URL

  func read() throws -> File? {
    if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
      throw StoryAnchorError.unreadable
    }
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    do {
      let values = try url.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        (values.fileSize ?? Int.max) <= 1_024 * 1_024
      else { throw StoryAnchorError.unreadable }
      let file = try StoryworldCoding.makeDecoder().decode(File.self, from: Data(contentsOf: url))
      guard file.schema_version == 1, file.anchors.count <= Self.maximumCount,
        Set(file.anchors.map(\.id)).count == file.anchors.count,
        Set(file.anchors.map(\.eventRef)).count == file.anchors.count
      else { throw StoryAnchorError.unreadable }
      for anchor in file.anchors {
        guard (1...100).contains(anchor.label.count), anchor.note.count <= 1_000,
          anchor.eventRef.sequence > 0
        else { throw StoryAnchorError.unreadable }
      }
      return file
    } catch { throw StoryAnchorError.unreadable }
  }

  func state(visible: Set<StoryAnchorEventRef>) -> StoryAnchorState {
    do {
      guard let file = try read() else { return .init() }
      let valid = file.anchors.filter { visible.contains($0.eventRef) }
      return .init(
        revision: file.revision, anchors: valid,
        notice: valid.count == file.anchors.count ? nil : "部分锚点不属于当前有效历史，已停止注入这些锚点；原文件保留。")
    } catch { return .init(notice: error.localizedDescription) }
  }

  func write(_ anchors: [StoryAnchor]) throws {
    let file = File(schema_version: 1, revision: UUID(), anchors: anchors)
    let data = try StoryworldCoding.makeEncoder().encode(file)
    guard data.count <= 1_024 * 1_024 else { throw StoryAnchorError.fileTooLarge }
    try data.write(to: url, options: .atomic)
  }

  func upsert(_ incoming: StoryAnchor, expectedRevision: UUID?, visible: Set<StoryAnchorEventRef>)
    throws
  {
    let file = try read()
    guard file?.revision == expectedRevision else { throw StoryAnchorError.staleRevision }
    guard visible.contains(incoming.eventRef) else { throw StoryAnchorError.invalidReference }
    let label = incoming.label.trimmingCharacters(in: .whitespacesAndNewlines)
    let note = incoming.note.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...100).contains(label.count), note.count <= 1_000 else {
      throw StoryAnchorError.invalidText
    }
    var anchors = file?.anchors ?? []
    let previous = anchors.first { $0.id == incoming.id }
    guard previous == nil || previous?.eventRef == incoming.eventRef else {
      throw StoryAnchorError.invalidReference
    }
    guard !anchors.contains(where: { $0.id != incoming.id && $0.eventRef == incoming.eventRef })
    else {
      throw StoryAnchorError.duplicateEvent
    }
    guard previous != nil || anchors.count < Self.maximumCount else {
      throw StoryAnchorError.tooManyAnchors
    }
    let normalized = StoryAnchor(
      id: incoming.id, eventRef: incoming.eventRef, kind: incoming.kind,
      label: label, note: note, enabled: incoming.enabled, createdAt: previous?.createdAt ?? Date())
    if previous == normalized { return }
    anchors.removeAll { $0.id == incoming.id }
    anchors.append(normalized)
    anchors.sort {
      $0.createdAt == $1.createdAt
        ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
    }
    try write(anchors)
  }

  func remove(id: UUID, expectedRevision: UUID?) throws {
    let file = try read()
    guard file?.revision == expectedRevision else { throw StoryAnchorError.staleRevision }
    guard let file, file.anchors.contains(where: { $0.id == id }) else { return }
    try write(file.anchors.filter { $0.id != id })
  }
}

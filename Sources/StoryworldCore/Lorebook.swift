import Foundation

/// Static setting knowledge that can be attached to one or more storyworlds.
/// Runtime state, saves, branches and sessions do not belong in this model.
public struct Lorebook: Codable, Equatable, Sendable, Identifiable {
  public static let currentFormatVersion = 1

  public let formatVersion: Int
  public let id: UUID
  public var title: String
  public var entries: [LoreEntry]
  public var categories: [LorebookCategory]

  public init(
    formatVersion: Int = Self.currentFormatVersion,
    id: UUID = UUID(),
    title: String,
    entries: [LoreEntry] = [],
    categories: [LorebookCategory] = []
  ) {
    self.formatVersion = formatVersion
    self.id = id
    self.title = title
    self.entries = entries
    self.categories = categories
  }

  enum CodingKeys: String, CodingKey {
    case formatVersion = "format_version"
    case id
    case title
    case entries
    case categories
  }
}

public struct LoreEntry: Codable, Equatable, Sendable, Identifiable {
  /// String IDs preserve identifiers from external lorebook ecosystems.
  public let id: String
  public var title: String
  public var content: String
  public var activationKeys: [String]
  public var enabled: Bool
  public var alwaysActive: Bool
  public var hidden: Bool
  public var categoryID: String?

  public init(
    id: String = UUID().uuidString.lowercased(),
    title: String,
    content: String,
    activationKeys: [String] = [],
    enabled: Bool = true,
    alwaysActive: Bool = false,
    hidden: Bool = false,
    categoryID: String? = nil
  ) {
    self.id = id
    self.title = title
    self.content = content
    self.activationKeys = activationKeys
    self.enabled = enabled
    self.alwaysActive = alwaysActive
    self.hidden = hidden
    self.categoryID = categoryID
  }

  enum CodingKeys: String, CodingKey {
    case id
    case title
    case content
    case activationKeys = "activation_keys"
    case enabled
    case alwaysActive = "always_active"
    case hidden
    case categoryID = "category_id"
  }
}

public struct LorebookCategory: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public var name: String
  public var enabled: Bool

  public init(
    id: String = UUID().uuidString.lowercased(),
    name: String,
    enabled: Bool = true
  ) {
    self.id = id
    self.name = name
    self.enabled = enabled
  }
}

public enum LorebookValidationError: Error, Equatable, LocalizedError {
  case unsupportedFormat(Int)
  case emptyTitle
  case duplicateEntryID(String)
  case emptyEntryContent(String)

  public var errorDescription: String? {
    switch self {
    case .unsupportedFormat(let version):
      "不支持 Lorebook 格式版本 \(version)"
    case .emptyTitle:
      "Lorebook 标题不能为空"
    case .duplicateEntryID(let id):
      "Lorebook 条目 ID 重复：\(id)"
    case .emptyEntryContent(let id):
      "Lorebook 条目内容为空：\(id)"
    }
  }
}

public struct LorebookValidator {
  public init() {}

  public func validate(_ lorebook: Lorebook) throws {
    guard lorebook.formatVersion == Lorebook.currentFormatVersion else {
      throw LorebookValidationError.unsupportedFormat(lorebook.formatVersion)
    }
    guard !lorebook.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw LorebookValidationError.emptyTitle
    }

    var entryIDs = Set<String>()
    for entry in lorebook.entries {
      guard entryIDs.insert(entry.id).inserted else {
        throw LorebookValidationError.duplicateEntryID(entry.id)
      }
      guard !entry.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw LorebookValidationError.emptyEntryContent(entry.id)
      }
    }
  }
}

import Foundation

public enum LorebookImportError: Error, Equatable, LocalizedError {
  case unsupportedExtension
  case notRegularFile
  case fileTooLarge(Int)
  case unreadableJSON
  case unsupportedContainer
  case noUsableEntries

  public var errorDescription: String? {
    switch self {
    case .unsupportedExtension:
      "仅支持 .lorebook 或兼容的 .json 文件"
    case .notRegularFile:
      "Lorebook 必须是普通文件"
    case .fileTooLarge(let maximum):
      "Lorebook 文件超过 \(maximum) 字节限制"
    case .unreadableJSON:
      "Lorebook 不是可读取的 JSON"
    case .unsupportedContainer:
      "无法识别 Lorebook 条目容器"
    case .noUsableEntries:
      "Lorebook 中没有可导入的有效条目"
    }
  }
}

/// Imports the stable entry fields published by NovelAI's Lorebook API and the
/// common SillyTavern World Info entry shape. External container schemas vary,
/// so this reader deliberately accepts arrays and both array/dictionary
/// `entries` containers while preserving only the shared semantics.
public struct LorebookImporter {
  public static let defaultMaximumByteCount = 32 * 1_024 * 1_024

  private let maximumByteCount: Int

  public init(maximumByteCount: Int = Self.defaultMaximumByteCount) {
    self.maximumByteCount = maximumByteCount
  }

  public func load(from url: URL) throws -> Lorebook {
    guard ["lorebook", "json"].contains(url.pathExtension.lowercased()) else {
      throw LorebookImportError.unsupportedExtension
    }

    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values?.isRegularFile == true else {
      throw LorebookImportError.notRegularFile
    }
    if let fileSize = values?.fileSize, fileSize > maximumByteCount {
      throw LorebookImportError.fileTooLarge(maximumByteCount)
    }

    let data: Data
    let root: Any
    do {
      data = try Data(contentsOf: url, options: [.mappedIfSafe])
      root = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw LorebookImportError.unreadableJSON
    }

    let container = root as? [String: Any]
    let rawEntries = try extractEntries(from: root)
    let entries = rawEntries.compactMap { raw in
      makeEntry(from: raw.value, fallbackID: raw.id)
    }
    guard !entries.isEmpty else {
      throw LorebookImportError.noUsableEntries
    }

    let title = firstString(in: container, keys: ["title", "name", "displayName"])
      ?? url.deletingPathExtension().lastPathComponent
    let categories = extractCategories(from: container?["categories"])
    let lorebook = Lorebook(title: title, entries: entries, categories: categories)
    try LorebookValidator().validate(lorebook)
    return lorebook
  }

  private func extractEntries(from root: Any) throws -> [(id: String, value: [String: Any])] {
    if let array = root as? [[String: Any]] {
      return array.enumerated().map { index, value in
        (entryID(from: value) ?? "entry-\(index + 1)", value)
      }
    }

    guard let object = root as? [String: Any], let entries = object["entries"] else {
      throw LorebookImportError.unsupportedContainer
    }
    if let array = entries as? [[String: Any]] {
      return array.enumerated().map { index, value in
        (entryID(from: value) ?? "entry-\(index + 1)", value)
      }
    }
    if let dictionary = entries as? [String: Any] {
      return dictionary.keys.sorted().compactMap { key in
        guard let value = dictionary[key] as? [String: Any] else { return nil }
        return (entryID(from: value) ?? key, value)
      }
    }
    throw LorebookImportError.unsupportedContainer
  }

  private func makeEntry(from object: [String: Any], fallbackID: String) -> LoreEntry? {
    guard let content = firstString(in: object, keys: ["text", "content"])?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !content.isEmpty
    else { return nil }

    let keys = firstStringArray(in: object, keys: ["keys", "key", "activation_keys"])
    let title = firstString(
      in: object,
      keys: ["displayName", "display_name", "title", "name", "comment"]
    ) ?? keys.first ?? "未命名条目"
    let enabled = boolValue(object["enabled"])
      ?? boolValue(object["disable"]).map { !$0 }
      ?? true

    return LoreEntry(
      id: fallbackID,
      title: title,
      content: content,
      activationKeys: keys,
      enabled: enabled,
      alwaysActive: firstBool(
        in: object,
        keys: ["forceActivation", "force_activation", "constant", "always_active"]
      ) ?? false,
      hidden: boolValue(object["hidden"]) ?? false,
      categoryID: firstString(in: object, keys: ["category", "category_id"])
    )
  }

  private func extractCategories(from value: Any?) -> [LorebookCategory] {
    let rawCategories: [(String, [String: Any])]
    if let array = value as? [[String: Any]] {
      rawCategories = array.enumerated().map { index, category in
        (stringValue(category["id"]) ?? "category-\(index + 1)", category)
      }
    } else if let dictionary = value as? [String: Any] {
      rawCategories = dictionary.keys.sorted().compactMap { key in
        guard let category = dictionary[key] as? [String: Any] else { return nil }
        return (stringValue(category["id"]) ?? key, category)
      }
    } else {
      return []
    }

    return rawCategories.compactMap { id, category in
      guard let name = firstString(in: category, keys: ["name", "title"]) else { return nil }
      return LorebookCategory(
        id: id,
        name: name,
        enabled: boolValue(category["enabled"]) ?? true
      )
    }
  }

  private func entryID(from object: [String: Any]) -> String? {
    firstString(in: object, keys: ["id", "uid"])
  }

  private func firstString(in object: [String: Any]?, keys: [String]) -> String? {
    guard let object else { return nil }
    return keys.lazy.compactMap { stringValue(object[$0]) }.first
  }

  private func firstStringArray(in object: [String: Any], keys: [String]) -> [String] {
    for key in keys {
      if let values = object[key] as? [Any] {
        return values.compactMap(stringValue)
      }
      if let value = stringValue(object[key]) {
        return [value]
      }
    }
    return []
  }

  private func firstBool(in object: [String: Any], keys: [String]) -> Bool? {
    keys.lazy.compactMap { boolValue(object[$0]) }.first
  }

  private func stringValue(_ value: Any?) -> String? {
    if let value = value as? String, !value.isEmpty { return value }
    if let value = value as? NSNumber { return value.stringValue }
    return nil
  }

  private func boolValue(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    return nil
  }
}

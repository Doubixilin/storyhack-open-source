import Foundation

public enum LegacyWorldbookImportError: Error, Equatable, LocalizedError {
  case notDirectory
  case symbolicLinkNotAllowed
  case noStaticLore
  case sourceTooLarge(Int)
  case unreadableFile(String)
  case invalidState

  public var errorDescription: String? {
    switch self {
    case .notDirectory:
      "旧版世界书必须是目录"
    case .symbolicLinkNotAllowed:
      "旧版世界书目录不允许符号链接"
    case .noStaticLore:
      "目录中没有找到世界书、人物或地区等静态设定 Markdown"
    case .sourceTooLarge(let maximum):
      "旧版静态设定超过 \(maximum) 字节限制"
    case .unreadableFile(let name):
      "无法读取旧版文件：\(name)"
    case .invalidState:
      "旧版状态.json 不是有效的 JSON 对象"
    }
  }
}

public struct LegacyWorldbookSourceFile: Equatable, Sendable {
  public let url: URL
  public let relativePath: String

  public init(url: URL, relativePath: String) {
    self.url = url
    self.relativePath = relativePath
  }
}

public struct LegacyWorldbookMigration: Equatable, Sendable {
  public let title: String
  public let lorebook: Lorebook
  public let initialState: [String: JSONValue]
  public let sourceFiles: [LegacyWorldbookSourceFile]

  public init(
    title: String,
    lorebook: Lorebook,
    initialState: [String: JSONValue],
    sourceFiles: [LegacyWorldbookSourceFile]
  ) {
    self.title = title
    self.lorebook = lorebook
    self.initialState = initialState
    self.sourceFiles = sourceFiles
  }
}

public struct LegacyWorldbookImporter {
  public static let maximumStaticLoreByteCount = 32 * 1_024 * 1_024

  private let fileManager: FileManager

  public init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  public func load(from directoryURL: URL) throws -> LegacyWorldbookMigration {
    let values = try? directoryURL.resourceValues(
      forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
    )
    guard values?.isDirectory == true else {
      throw LegacyWorldbookImportError.notDirectory
    }
    guard values?.isSymbolicLink != true else {
      throw LegacyWorldbookImportError.symbolicLinkNotAllowed
    }

    let children = try fileManager.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
      options: [.skipsHiddenFiles]
    ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    var loreSources = children.compactMap { url -> LegacyWorldbookSourceFile? in
      guard url.pathExtension.lowercased() == "md", isStaticLoreFile(url.lastPathComponent)
      else { return nil }
      return .init(url: url, relativePath: url.lastPathComponent)
    }
    let indexDirectory = directoryURL.appendingPathComponent("索引", isDirectory: true)
    if fileManager.fileExists(atPath: indexDirectory.path) {
      let indexValues = try indexDirectory.resourceValues(
        forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
      )
      guard indexValues.isDirectory == true, indexValues.isSymbolicLink != true else {
        throw LegacyWorldbookImportError.symbolicLinkNotAllowed
      }
      for name in ["术语规范表.md", "名场面库.md"] {
        let url = indexDirectory.appendingPathComponent(name)
        if fileManager.fileExists(atPath: url.path) {
          loreSources.append(.init(url: url, relativePath: "索引/\(name)"))
        }
      }
    }
    guard !loreSources.isEmpty else {
      throw LegacyWorldbookImportError.noStaticLore
    }

    var totalBytes = 0
    var entries: [LoreEntry] = []
    var sourceFiles: [LegacyWorldbookSourceFile] = []
    for source in loreSources {
      let url = source.url
      let resourceValues = try url.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
      )
      guard resourceValues.isRegularFile == true, resourceValues.isSymbolicLink != true else {
        throw LegacyWorldbookImportError.symbolicLinkNotAllowed
      }
      totalBytes += resourceValues.fileSize ?? 0
      guard totalBytes <= Self.maximumStaticLoreByteCount else {
        throw LegacyWorldbookImportError.sourceTooLarge(Self.maximumStaticLoreByteCount)
      }
      guard let content = try? String(contentsOf: url, encoding: .utf8) else {
        throw LegacyWorldbookImportError.unreadableFile(url.lastPathComponent)
      }
      let title = url.deletingPathExtension().lastPathComponent
      entries.append(
        LoreEntry(
          id: "legacy-\(entries.count + 1)",
          title: title,
          content: content,
          activationKeys: activationKeys(title: title, content: content),
          alwaysActive: title == "世界书" || title == "AGENTS"
        )
      )
      sourceFiles.append(source)
    }

    let stateURL = directoryURL.appendingPathComponent("状态.json")
    let initialState: [String: JSONValue]
    if fileManager.fileExists(atPath: stateURL.path) {
      let stateValues = try stateURL.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
      )
      guard stateValues.isRegularFile == true, stateValues.isSymbolicLink != true else {
        throw LegacyWorldbookImportError.symbolicLinkNotAllowed
      }
      let stateData = try Data(contentsOf: stateURL)
      guard case .object(let object) = try? JSONDecoder().decode(JSONValue.self, from: stateData) else {
        throw LegacyWorldbookImportError.invalidState
      }
      initialState = object
      sourceFiles.append(.init(url: stateURL, relativePath: "状态.json"))
    } else {
      initialState = [:]
    }

    for name in ["事件日志.jsonl", "章节摘要.md"] {
      let url = directoryURL.appendingPathComponent(name)
      if fileManager.fileExists(atPath: url.path) {
        let values = try url.resourceValues(
          forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
          throw LegacyWorldbookImportError.symbolicLinkNotAllowed
        }
        sourceFiles.append(.init(url: url, relativePath: name))
      }
    }
    let savesDirectory = directoryURL.appendingPathComponent("存档", isDirectory: true)
    if fileManager.fileExists(atPath: savesDirectory.path) {
      let saves = try fileManager.contentsOfDirectory(
        at: savesDirectory,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
      )
      for save in saves.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let saveValues = try save.resourceValues(
          forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        if saveValues.isRegularFile == true, saveValues.isSymbolicLink != true {
          sourceFiles.append(
            .init(url: save, relativePath: "存档/\(save.lastPathComponent)")
          )
        }
      }
    }

    let title = inferredTitle(from: entries, fallback: directoryURL.lastPathComponent)
    return LegacyWorldbookMigration(
      title: title,
      lorebook: Lorebook(title: title, entries: entries),
      initialState: initialState,
      sourceFiles: sourceFiles
    )
  }

  private func isStaticLoreFile(_ name: String) -> Bool {
    let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
    if stem == "章节摘要" || stem.hasPrefix("存档") || stem.contains("测试") {
      return false
    }
    return stem == "世界书"
      || stem == "AGENTS"
      || stem.hasPrefix("人物")
      || stem.hasPrefix("地区")
      || stem.hasPrefix("势力")
      || stem.contains("时间线")
      || stem.contains("基准世界线")
      || stem.hasPrefix("关系网")
      || stem == "伏笔登记簿"
      || stem.hasPrefix("素材索引")
  }

  private func activationKeys(title: String, content: String) -> [String] {
    var keys: [String] = title == "世界书" || title == "AGENTS" ? [] : [title]
    for line in content.split(whereSeparator: { $0.isNewline }) {
      let value = line.trimmingCharacters(in: .whitespaces)
      guard value.hasPrefix("## ") || value.hasPrefix("### ") else { continue }
      let heading = value.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
      guard (2...32).contains(heading.count), !keys.contains(heading) else { continue }
      keys.append(heading)
      if keys.count >= 80 { break }
    }
    return keys
  }

  private func inferredTitle(from entries: [LoreEntry], fallback: String) -> String {
    guard let main = entries.first(where: { $0.title == "世界书" }) else { return fallback }
    guard let firstHeading = main.content.split(whereSeparator: { $0.isNewline }).first(where: {
      $0.trimmingCharacters(in: .whitespaces).hasPrefix("# ")
    }) else { return fallback }
    let heading = firstHeading.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
    let cleaned = heading
      .replacingOccurrences(of: "《", with: "")
      .replacingOccurrences(of: "》", with: "")
      .replacingOccurrences(of: "世界书", with: "")
      .trimmingCharacters(in: CharacterSet(charactersIn: " -—–·：:vV0123456789."))
    return cleaned.isEmpty ? fallback : cleaned
  }
}

public struct LegacyWorldbookMigrationReceipt: Sendable {
  public let record: StoryworldLibraryRecord
  public let playthrough: PlaythroughContext
  public let preservedFileCount: Int

  public init(
    record: StoryworldLibraryRecord,
    playthrough: PlaythroughContext,
    preservedFileCount: Int
  ) {
    self.record = record
    self.playthrough = playthrough
    self.preservedFileCount = preservedFileCount
  }
}

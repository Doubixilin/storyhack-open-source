import Foundation

public enum StoryworldPackageLayout {
  public static let pathExtension = "storyworld"
  public static let manifest = "manifest.json"
  public static let lorebookDirectory = "lorebook"
  public static let playthroughsDirectory = "playthroughs"
  public static let sessionsDirectory = "sessions"
  public static let assetsDirectory = "assets"
  /// 可选产物：原著节拍线
  public static let timeline = "timeline.json"
  /// 可选产物：原著主线（正史模式按序游玩的剧情锚）
  public static let plotline = "plotline.json"
  /// 可选产物：运行时素材题材与节点场景映射
  public static let materialProfile = "material_profile.json"
  public static let characterContracts = "character_contracts.json"
}

public enum StoryworldTransferScope: String, Codable, CaseIterable, Sendable {
  case lorebookOnly = "lorebook_only"
  case fullCopy = "full_copy"
}

public enum StoryworldPackageValidationError: Error, Equatable, LocalizedError {
  case wrongExtension
  case notDirectory
  case missingManifest
  case unreadableManifest
  case unsupportedFormat(Int)
  case invalidRevision
  case emptyTitle
  case unsafeLorebookEntry
  case missingLorebookEntry(String)
  case symbolicLinkNotAllowed(String)
  case lorebookTooLarge(Int)
  case unreadableLorebook
  case invalidLorebook(LorebookValidationError)

  public var errorDescription: String? {
    switch self {
    case .wrongExtension:
      "文件扩展名必须是 .storyworld"
    case .notDirectory:
      "当前 v1 格式要求 .storyworld 是目录型文档包"
    case .missingManifest:
      "文档包缺少 manifest.json"
    case .unreadableManifest:
      "manifest.json 无法解析"
    case .unsupportedFormat(let version):
      "不支持 Storyworld 格式版本 \(version)"
    case .invalidRevision:
      "revision 必须大于或等于 1"
    case .emptyTitle:
      "Storyworld 标题不能为空"
    case .unsafeLorebookEntry:
      "Lorebook 入口不是安全的包内相对路径"
    case .missingLorebookEntry(let path):
      "缺少 Lorebook 入口：\(path)"
    case .symbolicLinkNotAllowed(let path):
      "Storyworld 文档包不允许符号链接：\(path)"
    case .lorebookTooLarge(let maximum):
      "Storyworld 中的 Lorebook 超过 \(maximum) 字节限制"
    case .unreadableLorebook:
      "Lorebook 入口无法解析"
    case .invalidLorebook:
      "世界书条目文件损坏或格式不受支持，无法读取。"
    }
  }
}

public struct StoryworldPackageValidator {
  private let fileManager: FileManager

  public init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  public func validate(at packageURL: URL) throws -> StoryworldManifest {
    guard packageURL.pathExtension.lowercased() == StoryworldPackageLayout.pathExtension else {
      throw StoryworldPackageValidationError.wrongExtension
    }

    let packageValues = try? packageURL.resourceValues(
      forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
    )
    guard packageValues?.isDirectory == true else {
      throw StoryworldPackageValidationError.notDirectory
    }
    guard packageValues?.isSymbolicLink != true else {
      throw StoryworldPackageValidationError.symbolicLinkNotAllowed(packageURL.lastPathComponent)
    }

    let manifestURL = packageURL.appendingPathComponent(StoryworldPackageLayout.manifest)
    guard fileManager.fileExists(atPath: manifestURL.path) else {
      throw StoryworldPackageValidationError.missingManifest
    }
    let manifestValues = try? manifestURL.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
    )
    guard manifestValues?.isRegularFile == true else {
      throw StoryworldPackageValidationError.unreadableManifest
    }
    guard manifestValues?.isSymbolicLink != true else {
      throw StoryworldPackageValidationError.symbolicLinkNotAllowed(
        StoryworldPackageLayout.manifest
      )
    }

    let manifest: StoryworldManifest
    do {
      let data = try Data(contentsOf: manifestURL)
      manifest = try StoryworldCoding.makeDecoder().decode(StoryworldManifest.self, from: data)
    } catch {
      throw StoryworldPackageValidationError.unreadableManifest
    }

    guard manifest.formatVersion == StoryworldManifest.currentFormatVersion else {
      throw StoryworldPackageValidationError.unsupportedFormat(manifest.formatVersion)
    }
    guard manifest.revision >= 1 else {
      throw StoryworldPackageValidationError.invalidRevision
    }
    guard !manifest.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw StoryworldPackageValidationError.emptyTitle
    }

    let lorebookEntry = manifest.content.lorebookEntry
    guard isSafeRelativePath(lorebookEntry) else {
      throw StoryworldPackageValidationError.unsafeLorebookEntry
    }
    let lorebookURL = packageURL.appendingPathComponent(lorebookEntry)
    guard fileManager.fileExists(atPath: lorebookURL.path) else {
      throw StoryworldPackageValidationError.missingLorebookEntry(lorebookEntry)
    }
    let resolvedPackageURL = packageURL.resolvingSymlinksInPath().standardizedFileURL
    let resolvedLorebookURL = lorebookURL.resolvingSymlinksInPath().standardizedFileURL
    guard resolvedLorebookURL.path.hasPrefix(resolvedPackageURL.path + "/") else {
      throw StoryworldPackageValidationError.unsafeLorebookEntry
    }
    let lorebookValues = try? lorebookURL.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    )
    guard lorebookValues?.isRegularFile == true else {
      throw StoryworldPackageValidationError.unreadableLorebook
    }
    guard lorebookValues?.isSymbolicLink != true else {
      throw StoryworldPackageValidationError.symbolicLinkNotAllowed(lorebookEntry)
    }
    if let fileSize = lorebookValues?.fileSize,
      fileSize > LorebookImporter.defaultMaximumByteCount
    {
      throw StoryworldPackageValidationError.lorebookTooLarge(
        LorebookImporter.defaultMaximumByteCount
      )
    }

    let lorebook: Lorebook
    do {
      let data = try Data(contentsOf: lorebookURL)
      lorebook = try StoryworldCoding.makeDecoder().decode(Lorebook.self, from: data)
    } catch {
      throw StoryworldPackageValidationError.unreadableLorebook
    }
    do {
      try LorebookValidator().validate(lorebook)
    } catch let error as LorebookValidationError {
      throw StoryworldPackageValidationError.invalidLorebook(error)
    } catch {
      throw StoryworldPackageValidationError.unreadableLorebook
    }

    return manifest
  }

  private func isSafeRelativePath(_ path: String) -> Bool {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else {
      return false
    }
    return !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
  }
}

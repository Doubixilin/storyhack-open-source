import CryptoKit
import Foundation

public actor CharacterLibraryStore {
  public static func defaultRootURL() -> URL {
    let base = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? FileManager.default.temporaryDirectory
    return base
      .appendingPathComponent("StoryhackCommunity", isDirectory: true)
      .appendingPathComponent("CharacterLibrary", isDirectory: true)
  }

  private let rootURL: URL
  private let fileManager: FileManager

  public init(
    rootURL: URL? = nil,
    fileManager: FileManager = .default
  ) {
    self.rootURL = rootURL ?? Self.defaultRootURL()
    self.fileManager = fileManager
  }

  public func listCharacters() throws -> [CharacterProfile] {
    try loadIndex().characters.sorted { $0.updatedAt > $1.updatedAt }
  }

  @discardableResult
  public func createCharacter(
    name: String,
    summary: String = "",
    origin: CharacterOrigin = .manual,
    fields: CharacterFields = CharacterFields(),
    category: String? = nil,
    tags: [String] = []
  ) throws -> CharacterProfile {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else { throw CharacterLibraryError.emptyName }

    let now = Date()
    let profile = CharacterProfile(
      name: trimmedName,
      summary: summary,
      origin: origin,
      fields: fields,
      category: category,
      tags: tags,
      createdAt: now,
      updatedAt: now
    )
    var index = try loadIndex()
    try ensureCharacterDirectories(characterID: profile.id)
    try saveAssets([], characterID: profile.id)
    index.characters.append(profile)
    do {
      try saveIndex(index)
      return profile
    } catch {
      try? fileManager.removeItem(at: characterDirectory(characterID: profile.id))
      throw error
    }
  }

  public func updateProfile(_ profile: CharacterProfile) throws {
    var index = try loadIndex()
    guard let position = index.characters.firstIndex(where: { $0.id == profile.id }) else {
      throw CharacterLibraryError.characterNotFound(profile.id)
    }
    var updated = profile
    updated.updatedAt = Date()
    index.characters[position] = updated
    try saveIndex(index)
  }

  public func deleteCharacter(id: UUID) throws {
    var index = try loadIndex()
    guard let position = index.characters.firstIndex(where: { $0.id == id }) else {
      throw CharacterLibraryError.characterNotFound(id)
    }
    index.characters.remove(at: position)
    try saveIndex(index)
    let directory = characterDirectory(characterID: id)
    if fileManager.fileExists(atPath: directory.path) {
      try fileManager.removeItem(at: directory)
    }
  }

  @discardableResult
  public func importImage(
    from sourceURL: URL,
    characterID: UUID,
    prompt: String? = nil
  ) throws -> CharacterAsset {
    let index = try loadIndex()
    guard index.characters.contains(where: { $0.id == characterID }) else {
      throw CharacterLibraryError.characterNotFound(characterID)
    }

    let fileExtension = sourceURL.pathExtension.lowercased()
    let mimeType: String
    switch fileExtension {
    case "png": mimeType = "image/png"
    case "jpg", "jpeg": mimeType = "image/jpeg"
    case "heic": mimeType = "image/heic"
    case "webp": mimeType = "image/webp"
    default: throw CharacterLibraryError.unsupportedFile
    }

    let values: URLResourceValues
    do {
      values = try sourceURL.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
      )
    } catch {
      throw CharacterLibraryError.unsafeFile
    }
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw CharacterLibraryError.unsafeFile
    }
    guard (values.fileSize ?? 0) <= 100 * 1_024 * 1_024 else {
      throw CharacterLibraryError.fileTooLarge
    }

    let oldAssets = try loadAssets(characterID: characterID)
    let id = UUID()
    let relativePath = "images/\(id.uuidString.lowercased()).\(fileExtension)"
    let destination = characterDirectory(characterID: characterID)
      .appendingPathComponent(relativePath)
    try ensureCharacterDirectories(characterID: characterID)
    try fileManager.copyItem(at: sourceURL, to: destination)
    do {
      let asset = CharacterAsset(
        id: id,
        characterID: characterID,
        kind: .image,
        status: .candidate,
        relativePath: relativePath,
        mimeType: mimeType,
        fileSHA256: try sha256(destination),
        provider: "local_import",
        prompt: prompt
      )
      var assets = oldAssets
      assets.append(asset)
      try saveAssets(assets, characterID: characterID)
      try saveIndex(index)
      return asset
    } catch {
      try? saveAssets(oldAssets, characterID: characterID)
      try? fileManager.removeItem(at: destination)
      throw error
    }
  }

  public func listAssets(characterID: UUID) throws -> [CharacterAsset] {
    try requireCharacter(characterID)
    return try loadAssets(characterID: characterID)
      .sorted { $0.createdAt > $1.createdAt }
  }

  @discardableResult
  public func approveAsset(characterID: UUID, assetID: UUID) throws -> CharacterAsset {
    let index = try requireCharacter(characterID)
    let oldAssets = try loadAssets(characterID: characterID)
    var assets = oldAssets
    guard let position = assets.firstIndex(where: { $0.id == assetID }) else {
      throw CharacterLibraryError.assetNotFound(assetID)
    }
    guard assets[position].status == .candidate else {
      throw CharacterLibraryError.invalidTransition
    }
    assets[position].status = .approved
    assets[position].approvedAt = Date()
    do {
      try saveAssets(assets, characterID: characterID)
      try saveIndex(index)
      return assets[position]
    } catch {
      try? saveAssets(oldAssets, characterID: characterID)
      throw error
    }
  }

  @discardableResult
  public func rejectAsset(characterID: UUID, assetID: UUID) throws -> CharacterAsset {
    let index = try requireCharacter(characterID)
    let oldAssets = try loadAssets(characterID: characterID)
    var assets = oldAssets
    guard let position = assets.firstIndex(where: { $0.id == assetID }) else {
      throw CharacterLibraryError.assetNotFound(assetID)
    }
    guard assets[position].status == .candidate else {
      throw CharacterLibraryError.invalidTransition
    }
    assets[position].status = .rejected
    do {
      try saveAssets(assets, characterID: characterID)
      try saveIndex(index)
      return assets[position]
    } catch {
      try? saveAssets(oldAssets, characterID: characterID)
      throw error
    }
  }

  @discardableResult
  public func setPortrait(characterID: UUID, assetID: UUID) throws -> CharacterProfile {
    var index = try loadIndex()
    guard let profilePosition = index.characters.firstIndex(where: { $0.id == characterID }) else {
      throw CharacterLibraryError.characterNotFound(characterID)
    }
    let assets = try loadAssets(characterID: characterID)
    guard let asset = assets.first(where: { $0.id == assetID }),
          asset.characterID == characterID,
          asset.kind == .image,
          asset.status == .approved else {
      throw CharacterLibraryError.portraitRequiresApprovedImage
    }
    index.characters[profilePosition].portraitAssetID = assetID
    index.characters[profilePosition].updatedAt = Date()
    try saveIndex(index)
    return index.characters[profilePosition]
  }

  /// 资产相对路径在消费时重新校验：标准化后必须仍位于角色目录内，
  /// 拒绝绝对路径与 `..` 越界（索引未来可能来自导入/同步，不能盲信）。
  /// 返回 nil 表示路径非法，调用方按「资产不可用」跳过即可。
  public func assetFileURL(characterID: UUID, asset: CharacterAsset) -> URL? {
    let directory = characterDirectory(characterID: characterID)
    let candidate = directory.appendingPathComponent(asset.relativePath).standardizedFileURL
    let rootPath = directory.standardizedFileURL.path
    guard candidate.path.hasPrefix(rootPath + "/") else { return nil }
    return candidate
  }

  public func allCategories() throws -> [String] {
    Array(Set(try loadIndex().characters.compactMap(\.category))).sorted()
  }

  public func allTags() throws -> [String] {
    Array(Set(try loadIndex().characters.flatMap(\.tags))).sorted()
  }

  private func requireCharacter(_ characterID: UUID) throws -> CharacterLibraryIndex {
    let index = try loadIndex()
    guard index.characters.contains(where: { $0.id == characterID }) else {
      throw CharacterLibraryError.characterNotFound(characterID)
    }
    return index
  }

  /// 最近一次 loadIndex 的诊断（如跳过无法解析的角色记录），仅供 UI 展示；
  /// 健康记录照常列出，坏记录不会被自动删除或静默吞掉。
  public private(set) var loadDiagnostics: [String] = []

  /// 容损解码：单条角色记录损坏不拖垮整个索引；未知的更高版本则整体拒绝，
  /// 防止旧代码把新格式写坏（所有写路径都先经 loadIndex，天然阻断写入）。
  private struct LossyIndex: Decodable {
    let formatVersion: Int
    let updatedAt: Date
    let characters: [CharacterProfile]
    let droppedCharacterCount: Int

    private struct LossyCharacter: Decodable {
      let profile: CharacterProfile?

      init(from decoder: any Decoder) throws {
        profile = try? CharacterProfile(from: decoder)
      }
    }

    private enum CodingKeys: String, CodingKey {
      case formatVersion = "format_version"
      case characters
      case updatedAt = "updated_at"
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion)
        ?? CharacterLibraryIndex.currentFormatVersion
      updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
      let raw = try container.decodeIfPresent([LossyCharacter].self, forKey: .characters) ?? []
      characters = raw.compactMap(\.profile)
      droppedCharacterCount = raw.count - characters.count
    }
  }

  private func loadIndex() throws -> CharacterLibraryIndex {
    try ensureRootDirectory()
    let url = rootURL.appendingPathComponent("library.json")
    guard fileManager.fileExists(atPath: url.path) else {
      return CharacterLibraryIndex()
    }
    let decoded = try decoder.decode(LossyIndex.self, from: Data(contentsOf: url))
    guard decoded.formatVersion <= CharacterLibraryIndex.currentFormatVersion else {
      throw CharacterLibraryError.unsupportedFormatVersion(found: decoded.formatVersion)
    }
    loadDiagnostics = decoded.droppedCharacterCount > 0
      ? ["角色库索引中有 \(decoded.droppedCharacterCount) 条记录无法解析，已跳过（文件未改动）；其余角色不受影响。"]
      : []
    return CharacterLibraryIndex(
      formatVersion: decoded.formatVersion,
      characters: decoded.characters,
      updatedAt: decoded.updatedAt
    )
  }

  private func saveIndex(_ value: CharacterLibraryIndex) throws {
    try ensureRootDirectory()
    var index = value
    index.updatedAt = Date()
    try encoder.encode(index).write(
      to: rootURL.appendingPathComponent("library.json"),
      options: [.atomic]
    )
  }

  private func loadAssets(characterID: UUID) throws -> [CharacterAsset] {
    let url = assetsIndexURL(characterID: characterID)
    guard fileManager.fileExists(atPath: url.path) else { return [] }
    return try decoder.decode([CharacterAsset].self, from: Data(contentsOf: url))
  }

  private func saveAssets(_ assets: [CharacterAsset], characterID: UUID) throws {
    try ensureCharacterDirectories(characterID: characterID)
    try encoder.encode(assets).write(
      to: assetsIndexURL(characterID: characterID),
      options: [.atomic]
    )
  }

  private func ensureRootDirectory() throws {
    try fileManager.createDirectory(
      at: rootURL,
      withIntermediateDirectories: true
    )
  }

  private func ensureCharacterDirectories(characterID: UUID) throws {
    let directory = characterDirectory(characterID: characterID)
    try fileManager.createDirectory(
      at: directory.appendingPathComponent("images", isDirectory: true),
      withIntermediateDirectories: true
    )
    try fileManager.createDirectory(
      at: directory.appendingPathComponent("videos", isDirectory: true),
      withIntermediateDirectories: true
    )
  }

  private func characterDirectory(characterID: UUID) -> URL {
    rootURL.appendingPathComponent(
      characterID.uuidString.lowercased(),
      isDirectory: true
    )
  }

  private func assetsIndexURL(characterID: UUID) -> URL {
    characterDirectory(characterID: characterID)
      .appendingPathComponent("assets.json")
  }

  private func sha256(_ url: URL) throws -> String {
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  private var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

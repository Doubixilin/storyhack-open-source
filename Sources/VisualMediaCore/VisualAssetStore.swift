import CryptoKit
import Foundation

public enum VisualAssetError: Error, Equatable, LocalizedError {
  case unsupportedFile
  case unsafeFile
  case fileTooLarge
  case assetNotFound(UUID)
  case invalidTransition
  case corruptedAsset(UUID)

  public var errorDescription: String? {
    switch self {
    case .unsupportedFile: "只支持 PNG、JPEG、HEIC 和 WebP 图片"
    case .unsafeFile: "图片文件不安全或不可读取"
    case .fileTooLarge: "单张图片不能超过 100 MB"
    case .assetNotFound(let id): "没有找到视觉资产：\(id.uuidString)"
    case .invalidTransition: "当前资产状态不能执行此操作"
    case .corruptedAsset(let id): "视觉资产哈希不一致：\(id.uuidString)"
    }
  }
}

public actor VisualAssetStore {
  public static func defaultRootURL(storyworldID: UUID) -> URL {
    let base = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? FileManager.default.temporaryDirectory
    return base
      .appendingPathComponent("StoryhackCommunity", isDirectory: true)
      .appendingPathComponent("VisualAssets", isDirectory: true)
      .appendingPathComponent(storyworldID.uuidString.lowercased() + ".visualassets", isDirectory: true)
  }

  private let storyworldID: UUID
  private let rootURL: URL
  private let fileManager: FileManager

  public init(
    storyworldID: UUID,
    rootURL: URL? = nil,
    fileManager: FileManager = .default
  ) {
    self.storyworldID = storyworldID
    self.rootURL = rootURL ?? Self.defaultRootURL(storyworldID: storyworldID)
    self.fileManager = fileManager
  }

  public func loadBible() throws -> VisualBible {
    try ensureDirectories()
    let url = rootURL.appendingPathComponent("visual-bible.json")
    guard fileManager.fileExists(atPath: url.path) else {
      return VisualBible(storyworldID: storyworldID)
    }
    let bible = try decoder.decode(VisualBible.self, from: Data(contentsOf: url))
    guard bible.storyworldID == storyworldID else { throw VisualAssetError.unsafeFile }
    return bible
  }

  public func saveBible(_ bible: VisualBible) throws {
    guard bible.storyworldID == storyworldID else { throw VisualAssetError.unsafeFile }
    try ensureDirectories()
    var value = bible
    value.updatedAt = Date()
    try encoder.encode(value).write(
      to: rootURL.appendingPathComponent("visual-bible.json"),
      options: [.atomic]
    )
  }

  public func loadIndex(validatingFiles: Bool = false) throws -> VisualAssetIndex {
    try ensureDirectories()
    let url = rootURL.appendingPathComponent("asset-index.json")
    guard fileManager.fileExists(atPath: url.path) else { return VisualAssetIndex() }
    let index = try decoder.decode(VisualAssetIndex.self, from: Data(contentsOf: url))
    if validatingFiles {
      for asset in index.assets where asset.status != .rejected {
        let file = rootURL.appendingPathComponent(asset.relativePath)
        guard fileManager.fileExists(atPath: file.path), try sha256(file) == asset.fileSHA256 else {
          throw VisualAssetError.corruptedAsset(asset.id)
        }
      }
    }
    return index
  }

  @discardableResult
  public func registerLocalCandidate(
    from sourceURL: URL,
    subjectIDs: [String],
    cue: VisualCue,
    spoilerBoundary: SpoilerBoundary = .immediate,
    aiGenerated: Bool = false
  ) throws -> VisualAssetRecord {
    try ensureDirectories()
    let values = try sourceURL.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    )
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw VisualAssetError.unsafeFile
    }
    guard (values.fileSize ?? 0) <= 100 * 1_024 * 1_024 else {
      throw VisualAssetError.fileTooLarge
    }
    let fileExtension = sourceURL.pathExtension.lowercased()
    let mimeType: String
    switch fileExtension {
    case "png": mimeType = "image/png"
    case "jpg", "jpeg": mimeType = "image/jpeg"
    case "heic": mimeType = "image/heic"
    case "webp": mimeType = "image/webp"
    default: throw VisualAssetError.unsupportedFile
    }
    let id = UUID()
    let relativePath = "candidates/\(id.uuidString.lowercased()).\(fileExtension)"
    let destination = rootURL.appendingPathComponent(relativePath)
    try fileManager.copyItem(at: sourceURL, to: destination)
    do {
      let record = VisualAssetRecord(
        id: id,
        subjectIDs: subjectIDs,
        cue: cue,
        spoilerBoundary: spoilerBoundary,
        provider: "local_import",
        mimeType: mimeType,
        fileSHA256: try sha256(destination),
        relativePath: relativePath,
        aiGenerated: aiGenerated
      )
      var index = try loadIndex()
      index.assets.append(record)
      try saveIndex(index)
      return record
    } catch {
      try? fileManager.removeItem(at: destination)
      throw error
    }
  }

  @discardableResult
  public func approve(assetID: UUID) throws -> VisualAssetRecord {
    var index = try loadIndex()
    guard let position = index.assets.firstIndex(where: { $0.id == assetID }) else {
      throw VisualAssetError.assetNotFound(assetID)
    }
    guard index.assets[position].status == .candidate else {
      throw VisualAssetError.invalidTransition
    }
    let old = rootURL.appendingPathComponent(index.assets[position].relativePath)
    let fileExtension = old.pathExtension.lowercased()
    let relativePath = "approved/\(assetID.uuidString.lowercased()).\(fileExtension)"
    let destination = rootURL.appendingPathComponent(relativePath)
    try fileManager.moveItem(at: old, to: destination)
    index.assets[position].status = .approved
    index.assets[position].approvedAt = Date()
    let approved = VisualAssetRecord(
      id: index.assets[position].id,
      subjectIDs: index.assets[position].subjectIDs,
      status: .approved,
      cue: index.assets[position].cue,
      spoilerBoundary: index.assets[position].spoilerBoundary,
      provider: index.assets[position].provider,
      model: index.assets[position].model,
      modelVersion: index.assets[position].modelVersion,
      seed: index.assets[position].seed,
      referenceImageHashes: index.assets[position].referenceImageHashes,
      mimeType: index.assets[position].mimeType,
      pixelWidth: index.assets[position].pixelWidth,
      pixelHeight: index.assets[position].pixelHeight,
      fileSHA256: index.assets[position].fileSHA256,
      relativePath: relativePath,
      aiGenerated: index.assets[position].aiGenerated,
      createdAt: index.assets[position].createdAt,
      approvedAt: index.assets[position].approvedAt
    )
    index.assets[position] = approved
    do {
      try saveIndex(index)
      return approved
    } catch {
      try? fileManager.moveItem(at: destination, to: old)
      throw error
    }
  }

  @discardableResult
  public func reject(assetID: UUID) throws -> VisualAssetRecord {
    var index = try loadIndex()
    guard let position = index.assets.firstIndex(where: { $0.id == assetID }) else {
      throw VisualAssetError.assetNotFound(assetID)
    }
    guard index.assets[position].status == .candidate else {
      throw VisualAssetError.invalidTransition
    }
    index.assets[position].status = .rejected
    try saveIndex(index)
    return index.assets[position]
  }

  public func visibleApprovedAssets(
    chapterOrdinal: Int? = nil,
    visibleTurnIDs: Set<UUID> = []
  ) throws -> [VisualAssetRecord] {
    try loadIndex(validatingFiles: true).assets.filter {
      $0.status == .approved
        && $0.spoilerBoundary.isUnlocked(
          chapterOrdinal: chapterOrdinal,
          visibleTurnIDs: visibleTurnIDs
        )
    }
  }

  public func fileURL(for asset: VisualAssetRecord) -> URL {
    rootURL.appendingPathComponent(asset.relativePath)
  }

  private func ensureDirectories() throws {
    try fileManager.createDirectory(
      at: rootURL.appendingPathComponent("candidates", isDirectory: true),
      withIntermediateDirectories: true
    )
    try fileManager.createDirectory(
      at: rootURL.appendingPathComponent("approved", isDirectory: true),
      withIntermediateDirectories: true
    )
  }

  private func saveIndex(_ value: VisualAssetIndex) throws {
    var index = value
    index.updatedAt = Date()
    try encoder.encode(index).write(
      to: rootURL.appendingPathComponent("asset-index.json"),
      options: [.atomic]
    )
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

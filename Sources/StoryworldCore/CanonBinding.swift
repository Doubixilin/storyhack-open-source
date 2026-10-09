import CryptoKit
import Foundation

public struct CanonFingerprints: Codable, Equatable, Sendable {
  /// Stable logical asset names; missing optional files have no entry.
  public let assets: [String: String]
}

public struct CanonPlotReference: Codable, Equatable, Sendable {
  public let id: String
  public let order: Int
  public let chapterOrdinal: Int

  init(_ node: StoryPlotNode) {
    id = node.id
    order = node.order
    chapterOrdinal = node.chapterOrdinal
  }

  enum CodingKeys: String, CodingKey {
    case id, order
    case chapterOrdinal = "chapter_ordinal"
  }
}

public struct CanonRebindRecord: Codable, Equatable, Sendable {
  public let previousBindingID: UUID?
  public let previousFingerprints: CanonFingerprints?
  public let reboundAt: Date

  enum CodingKeys: String, CodingKey {
    case previousBindingID = "previous_binding_id"
    case previousFingerprints = "previous_fingerprints"
    case reboundAt = "rebound_at"
  }
}

public struct CanonBinding: Codable, Equatable, Sendable {
  public let id: UUID
  public let fingerprints: CanonFingerprints
  public let plotNodes: [CanonPlotReference]
  public let boundAt: Date
  public let history: [CanonRebindRecord]

  init(assets: CanonAssets, previous: CanonBinding? = nil, isConfirmation: Bool = false) {
    let now = Date()
    id = UUID()
    fingerprints = assets.fingerprints
    plotNodes = assets.plotline?.nodes.map(CanonPlotReference.init) ?? []
    boundAt = now
    history =
      (previous?.history ?? [])
      + (isConfirmation
        ? [
          CanonRebindRecord(
            previousBindingID: previous?.id, previousFingerprints: previous?.fingerprints,
            reboundAt: now)
        ] : [])
  }

  enum CodingKeys: String, CodingKey {
    case id, fingerprints, history
    case plotNodes = "plot_nodes"
    case boundAt = "bound_at"
  }
}

public struct CanonBindingStatus: Codable, Equatable, Sendable {
  public enum State: String, Codable, Sendable { case matched, changed, legacyUnbound, unavailable }
  public let state: State
  public let address: SessionAddress
  public let current: CanonFingerprints?
  public let bindingID: UUID?
  public let canRebind: Bool
  public let notice: String

  public var requiresConfirmation: Bool { state != .matched }
}

/// Carries both asset identity and the user's binding decision through a model
/// request. A rebind during generation invalidates an earlier request as well.
public struct CanonTurnToken: Equatable, Sendable {
  public let address: SessionAddress
  public let fingerprints: CanonFingerprints
  public let bindingID: UUID
}

public enum CanonBindingError: Error, Equatable, LocalizedError {
  case confirmationRequired
  case changedDuringTurn
  case staleDocument
  case incompatiblePlotline
  case invalidAsset(String)

  public var errorDescription: String? {
    switch self {
    case .confirmationRequired:
      "这条游玩线尚未确认当前世界设定，请先处理设定绑定提示。"
    case .changedDuringTurn:
      "生成期间世界设定或绑定已变化，本轮没有提交。请刷新并确认后重新生成。"
    case .staleDocument:
      "当前界面的世界设定已过期，请刷新后重新生成。"
    case .incompatiblePlotline:
      "主线节点已删除或重排，旧进度无法可靠对应。请保留旧线并使用新设定新开游玩线。"
    case .invalidAsset(let name):
      "世界设定文件无法安全读取或格式损坏：\(name)。请修复文件后再继续。"
    }
  }
}

/// Reads each asset once and derives both its fingerprint and semantic value
/// from those same bytes. Does not load any content outside this package.
struct CanonAssets {
  let fingerprints: CanonFingerprints
  let lorebook: Lorebook
  let timeline: StoryTimeline?
  let plotline: StoryPlotline?
  let materialProfile: MaterialProfile?
  let characterContracts: CharacterContractFile?

  static func read(at packageURL: URL) throws -> CanonAssets {
    let manifest = try StoryworldPackageValidator().validate(at: packageURL)
    var hashes: [String: String] = [:]
    func data(_ name: String, path: String, required: Bool = false) throws -> Data? {
      let url = packageURL.appendingPathComponent(path)
      let values = try? url.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
      guard values?.isSymbolicLink != true else { throw CanonBindingError.invalidAsset(name) }
      guard FileManager.default.fileExists(atPath: url.path) else {
        if required { throw CanonBindingError.invalidAsset(name) }
        return nil
      }
      guard values?.isRegularFile == true,
        (values?.fileSize ?? Int.max) <= 16 * 1_024 * 1_024
      else { throw CanonBindingError.invalidAsset(name) }
      let bytes = try Data(contentsOf: url)
      hashes[name] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
      return bytes
    }
    func decode<T: Decodable>(_ type: T.Type, name: String, path: String) throws -> T? {
      guard let bytes = try data(name, path: path) else { return nil }
      guard let result = try? StoryworldCoding.makeDecoder().decode(type, from: bytes) else {
        throw CanonBindingError.invalidAsset(name)
      }
      return result
    }
    guard let bytes = try data("lorebook", path: manifest.content.lorebookEntry, required: true),
      let lorebook = try? StoryworldCoding.makeDecoder().decode(Lorebook.self, from: bytes)
    else { throw CanonBindingError.invalidAsset("lorebook") }
    let timeline = try decode(
      StoryTimeline.self, name: "timeline", path: StoryworldPackageLayout.timeline)
    let plotline = try decode(
      StoryPlotline.self, name: "plotline", path: StoryworldPackageLayout.plotline)
    let material = try decode(
      MaterialProfile.self, name: "material_profile", path: StoryworldPackageLayout.materialProfile)
    var characterContracts: CharacterContractFile?
    if let contracts = try data(
      "character_contracts", path: StoryworldPackageLayout.characterContracts)
    {
      guard let decoded = try? CharacterContractFile.decode(contracts) else {
        throw CanonBindingError.invalidAsset("character_contracts")
      }
      characterContracts = decoded
    }
    return CanonAssets(
      fingerprints: .init(assets: hashes), lorebook: lorebook,
      timeline: timeline, plotline: plotline, materialProfile: material,
      characterContracts: characterContracts)
  }

  func matches(_ document: StoryworldDocument) -> Bool {
    lorebook == document.lorebook && timeline == document.timeline
      && plotline == document.plotline && materialProfile == document.materialProfile
      && characterContracts == document.characterContracts
  }

  func canPreservePlotReferences(from binding: CanonBinding?) -> Bool {
    guard let binding else { return true }
    let current = plotline?.nodes.map(CanonPlotReference.init) ?? []
    return binding.plotNodes.allSatisfy { current.contains($0) }
  }
}

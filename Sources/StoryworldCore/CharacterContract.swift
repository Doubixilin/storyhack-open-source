import CryptoKit
import DirectoryJournalCore
import Foundation

/// Static, world-local author decisions. Names and aliases are labels, never identity keys.
public struct CharacterContract: Codable, Equatable, Identifiable, Sendable {
  public var id: String { entityID }
  public let entityID: String
  public var displayName: String
  public var aliases: [String]
  public var immutableTraits: [String]
  public var baselineMotivations: [String]
  public var speechRules: [String]
  public var sampleLines: [String]
  public var neverDo: [String]
  public var sourceLoreEntryIDs: [String]
  public var sourceLibraryID: UUID?

  public init(
    entityID: String = UUID().uuidString.lowercased(), displayName: String,
    aliases: [String] = [], immutableTraits: [String] = [], baselineMotivations: [String] = [],
    speechRules: [String] = [], sampleLines: [String] = [], neverDo: [String] = [],
    sourceLoreEntryIDs: [String] = [], sourceLibraryID: UUID? = nil
  ) {
    self.entityID = entityID
    self.displayName = displayName
    self.aliases = aliases
    self.immutableTraits = immutableTraits
    self.baselineMotivations = baselineMotivations
    self.speechRules = speechRules
    self.sampleLines = sampleLines
    self.neverDo = neverDo
    self.sourceLoreEntryIDs = sourceLoreEntryIDs
    self.sourceLibraryID = sourceLibraryID
  }

  enum CodingKeys: String, CodingKey {
    case entityID = "entity_id"
    case displayName = "display_name"
    case aliases
    case immutableTraits = "immutable_traits"
    case baselineMotivations = "baseline_motivations"
    case speechRules = "speech_rules"
    case sampleLines = "sample_lines"
    case neverDo = "never_do"
    case sourceLoreEntryIDs = "source_lore_entry_ids"
    case sourceLibraryID = "source_library_id"
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    entityID = try c.decode(String.self, forKey: .entityID)
    displayName = try c.decode(String.self, forKey: .displayName)
    aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
    immutableTraits = try c.decodeIfPresent([String].self, forKey: .immutableTraits) ?? []
    baselineMotivations = try c.decodeIfPresent([String].self, forKey: .baselineMotivations) ?? []
    speechRules = try c.decodeIfPresent([String].self, forKey: .speechRules) ?? []
    sampleLines = try c.decodeIfPresent([String].self, forKey: .sampleLines) ?? []
    neverDo = try c.decodeIfPresent([String].self, forKey: .neverDo) ?? []
    sourceLoreEntryIDs = try c.decodeIfPresent([String].self, forKey: .sourceLoreEntryIDs) ?? []
    sourceLibraryID = try c.decodeIfPresent(UUID.self, forKey: .sourceLibraryID)
  }
}

public struct CharacterContractFile: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public var contracts: [CharacterContract]

  public init(contracts: [CharacterContract] = []) {
    schemaVersion = 1
    self.contracts = contracts
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case contracts
  }

  public func validate() throws {
    guard schemaVersion == 1, contracts.count <= 100,
      Set(contracts.map(\.entityID)).count == contracts.count
    else { throw CharacterContractError.invalidFile }
    for contract in contracts {
      let id = contract.entityID
      guard !id.isEmpty, id.utf8.count <= 100, id != "player",
        !["new.", "entity.", "fact."].contains(where: { id.hasPrefix($0) }),
        id.unicodeScalars.allSatisfy({
          CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
          ).contains($0)
        }),
        !contract.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        contract.displayName.count <= 100,
        contract.aliases.count <= 20,
        contract.aliases.allSatisfy({ !$0.isEmpty && $0.count <= 100 }),
        contract.sampleLines.count <= 4,
        contract.sampleLines.allSatisfy({ !$0.isEmpty && $0.count <= 200 })
      else { throw CharacterContractError.invalidFile }
      for list in [
        contract.immutableTraits, contract.baselineMotivations, contract.speechRules,
        contract.neverDo, contract.sourceLoreEntryIDs,
      ] {
        guard list.count <= 20,
          list.allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 500
          })
        else { throw CharacterContractError.invalidFile }
      }
    }
    guard try StoryworldCoding.makeEncoder().encode(self).count <= 1_024 * 1_024
    else { throw CharacterContractError.invalidFile }
  }

  static func decode(_ data: Data) throws -> Self {
    guard data.count <= 1_024 * 1_024 else { throw CharacterContractError.invalidFile }
    do {
      let file = try StoryworldCoding.makeDecoder().decode(Self.self, from: data)
      try file.validate()
      return file
    } catch { throw CharacterContractError.invalidFile }
  }
}

public struct CharacterContractState: Equatable, Sendable {
  public let file: CharacterContractFile
  public let fingerprint: String?
}

public enum CharacterContractError: Error, Equatable, LocalizedError {
  case invalidFile, staleRevision
  public var errorDescription: String? {
    switch self {
    case .invalidFile:
      "角色契约格式无效或超过限制。请检查独立 ID、标题、条目数量和文字长度；原文件未覆盖。"
    case .staleRevision:
      "角色契约已变化，请关闭编辑页，重新查看当前版本后再保存。"
    }
  }
}

enum CharacterContractStorage {
  static func read(at package: URL) throws -> CharacterContractState {
    let url = package.appendingPathComponent(StoryworldPackageLayout.characterContracts)
    let values = try? url.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard values?.isSymbolicLink != true else { throw CharacterContractError.invalidFile }
    guard FileManager.default.fileExists(atPath: url.path) else {
      return .init(file: .init(), fingerprint: nil)
    }
    guard values?.isRegularFile == true, (values?.fileSize ?? Int.max) <= 1_024 * 1_024
    else { throw CharacterContractError.invalidFile }
    let data = try Data(contentsOf: url)
    return .init(
      file: try CharacterContractFile.decode(data),
      fingerprint: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
  }

  static func save(
    _ file: CharacterContractFile, at package: URL, libraryRoot: URL,
    expectedFingerprint: String?
  ) throws {
    let journal = DirectoryReplacementJournal(rootURL: libraryRoot)
    try journal.withExclusiveAccess {
      try journal.recoverPendingReplacements()
      let old = try read(at: package)
      guard old.fingerprint == expectedFingerprint else {
        throw CharacterContractError.staleRevision
      }
      try file.validate()
      guard file != old.file else { return }
      var manifest = try StoryworldPackageValidator().validate(at: package)
      manifest.revision += 1
      manifest.modifiedAt = Date()
      let bytes = try StoryworldCoding.makeEncoder().encode(file)
      manifest.checksums[StoryworldPackageLayout.characterContracts] =
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
      try journal.performFileChanges([
        (
          url: package.appendingPathComponent(StoryworldPackageLayout.characterContracts),
          data: bytes
        ),
        (
          url: package.appendingPathComponent(StoryworldPackageLayout.manifest),
          data: try StoryworldCoding.makeEncoder().encode(manifest)
        ),
      ])
    }
  }
}

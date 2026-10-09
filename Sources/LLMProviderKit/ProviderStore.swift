import Foundation
import Security

public enum ProviderConfigurationError: Error, Equatable, LocalizedError {
  case emptyDisplayName
  case emptyModelID
  case missingBaseURL
  case invalidBaseURL
  case profileNotFound(UUID)
  case missingCredential(String)
  case unsupportedProviderKind
  case invalidTimeoutInterval
  case invalidContextBudget
  case keychainFailure(OSStatus)
  case unreadableCredential

  public var errorDescription: String? {
    switch self {
    case .emptyDisplayName:
      "模型配置名称不能为空"
    case .emptyModelID:
      "模型 ID 不能为空"
    case .missingBaseURL:
      "OpenAI-compatible 配置必须填写 Base URL"
    case .invalidBaseURL:
      "Base URL 必须使用 HTTPS；HTTP 仅允许 localhost 回环地址"
    case .profileNotFound(let id):
      "没有找到模型配置：\(id.uuidString)"
    case .missingCredential:
      "没有找到该模型配置的 API Key"
    case .unsupportedProviderKind:
      "当前阶段只支持 OpenAI-compatible 模型服务"
    case .invalidTimeoutInterval:
      "超时设置必须是 3600 秒以内的正数"
    case .invalidContextBudget:
      "上下文窗口须为 2048–2000000 tokens；输出上限须为正数并为输入保留至少 1024 tokens。"
    case .keychainFailure:
      "系统钥匙串操作失败，请重试；若持续失败，请重启设备后再试。"
    case .unreadableCredential:
      "Keychain 中的 API Key 无法读取"
    }
  }
}

public protocol ProviderCredentialStore: Sendable {
  func save(_ secret: String, reference: String) throws
  func load(reference: String) throws -> String
  func delete(reference: String) throws
}

public struct KeychainCredentialStore: ProviderCredentialStore {
  public let service: String

  public init(service: String = "org.doubixilin.storyhack.community.llm") {
    self.service = service
  }

  public func save(_ secret: String, reference: String) throws {
    let data = Data(secret.utf8)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: reference,
    ]
    let attributes: [String: Any] = [kSecValueData as String: data]
    let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else {
      throw ProviderConfigurationError.keychainFailure(updateStatus)
    }

    var insert = query
    insert[kSecValueData as String] = data
    let addStatus = SecItemAdd(insert as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw ProviderConfigurationError.keychainFailure(addStatus)
    }
  }

  public func load(reference: String) throws -> String {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: reference,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound {
      throw ProviderConfigurationError.missingCredential(reference)
    }
    guard status == errSecSuccess else {
      throw ProviderConfigurationError.keychainFailure(status)
    }
    guard let data = item as? Data, let secret = String(data: data, encoding: .utf8) else {
      throw ProviderConfigurationError.unreadableCredential
    }
    return secret
  }

  public func delete(reference: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: reference,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw ProviderConfigurationError.keychainFailure(status)
    }
  }
}

public actor ProviderProfileStore {
  public static var defaultRootURL: URL {
    let base =
      FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first ?? FileManager.default.temporaryDirectory
    return
      base
      .appendingPathComponent("StoryhackCommunity", isDirectory: true)
      .appendingPathComponent("Providers", isDirectory: true)
  }

  private struct Store: Codable {
    var profiles: [ProviderProfile]
  }

  private let rootURL: URL
  private let fileManager: FileManager
  private let credentialStore: any ProviderCredentialStore

  public init(
    rootURL: URL = ProviderProfileStore.defaultRootURL,
    credentialStore: any ProviderCredentialStore = KeychainCredentialStore(),
    fileManager: FileManager = .default
  ) {
    self.rootURL = rootURL
    self.credentialStore = credentialStore
    self.fileManager = fileManager
  }

  public func list() throws -> [ProviderProfile] {
    try loadProfiles().sorted {
      $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
    }
  }

  @discardableResult
  public func save(profile: ProviderProfile, apiKey: String?) async throws -> ProviderProfile {
    try validate(profile)
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    var profiles = try loadProfiles()
    var oldReferenceToDelete: String?
    let isExisting = profiles.contains(where: { $0.id == profile.id })
    if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
      let oldReference = profiles[index].credentialReference
      profiles[index] = profile
      if oldReference != profile.credentialReference {
        oldReferenceToDelete = oldReference
      }
    } else {
      profiles.append(profile)
    }
    if !isExisting, apiKey?.isEmpty ?? true {
      throw ProviderConfigurationError.missingCredential(profile.credentialReference)
    }
    if let apiKey, !apiKey.isEmpty {
      try credentialStore.save(apiKey, reference: profile.credentialReference)
    }
    try writeProfiles(profiles)
    if let oldReferenceToDelete {
      try credentialStore.delete(reference: oldReferenceToDelete)
    }
    await LLMToolCapabilityProbe.shared.invalidate(profileID: profile.id)
    return profile
  }

  public func delete(profileID: UUID) async throws {
    var profiles = try loadProfiles()
    guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
      throw ProviderConfigurationError.profileNotFound(profileID)
    }
    let profile = profiles.remove(at: index)
    try writeProfiles(profiles)
    try credentialStore.delete(reference: profile.credentialReference)
    await LLMToolCapabilityProbe.shared.invalidate(profileID: profileID)
  }

  public func apiKey(for profileID: UUID) throws -> String {
    guard let profile = try loadProfiles().first(where: { $0.id == profileID }) else {
      throw ProviderConfigurationError.profileNotFound(profileID)
    }
    return try credentialStore.load(reference: profile.credentialReference)
  }

  public func makeProvider(profileID: UUID) throws -> any LLMProvider {
    guard let profile = try loadProfiles().first(where: { $0.id == profileID }) else {
      throw ProviderConfigurationError.profileNotFound(profileID)
    }
    switch profile.kind {
    case .openAICompatible:
      return try OpenAICompatibleProvider(
        profile: profile,
        apiKey: credentialStore.load(reference: profile.credentialReference)
      )
    case .anthropic, .gemini:
      throw ProviderConfigurationError.unsupportedProviderKind
    }
  }

  private var profilesURL: URL {
    rootURL.appendingPathComponent("profiles.json")
  }

  private func loadProfiles() throws -> [ProviderProfile] {
    guard fileManager.fileExists(atPath: profilesURL.path) else { return [] }
    return try JSONDecoder().decode(
      Store.self,
      from: Data(contentsOf: profilesURL)
    ).profiles
  }

  private func writeProfiles(_ profiles: [ProviderProfile]) throws {
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(Store(profiles: profiles)).write(to: profilesURL, options: [.atomic])
  }

  private func validate(_ profile: ProviderProfile) throws {
    let window = profile.capabilities.contextWindow ?? 32_768
    let output = profile.maximumOutputTokens ?? min(4_096, window / 4)
    guard (2_048...2_000_000).contains(window), output > 0, output <= window - 1_024 else {
      throw ProviderConfigurationError.invalidContextBudget
    }
    guard !profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ProviderConfigurationError.emptyDisplayName
    }
    guard !profile.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ProviderConfigurationError.emptyModelID
    }
    if profile.kind == .openAICompatible {
      guard let baseURL = profile.baseURL else {
        throw ProviderConfigurationError.missingBaseURL
      }
      guard let scheme = baseURL.scheme?.lowercased(),
        ["http", "https"].contains(scheme),
        let host = baseURL.host?.lowercased()
      else {
        throw ProviderConfigurationError.invalidBaseURL
      }
      if scheme == "http", !["localhost", "127.0.0.1", "::1"].contains(host) {
        throw ProviderConfigurationError.invalidBaseURL
      }
    }
    // 超时数值可被 JSON 解码成任意值（负数/NaN/Inf 会让看门狗直接运行时错误），
    // 保存时必须先拦住；构造 Provider 时另有 clamp 兜底
    for timeout in [profile.requestTimeoutInterval, profile.stallTimeoutInterval] {
      if let timeout, !(timeout.isFinite && timeout > 0 && timeout <= 3_600) {
        throw ProviderConfigurationError.invalidTimeoutInterval
      }
    }
  }
}

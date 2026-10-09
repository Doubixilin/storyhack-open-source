import Combine
import Foundation
import LLMProviderKit

@MainActor
public final class ProviderSettingsViewModel: ObservableObject {
  @Published public private(set) var profiles: [ProviderProfile] = []
  @Published public var errorMessage: String?
  @Published public private(set) var isWorking = false

  let store: ProviderProfileStore

  public init(store: ProviderProfileStore) {
    self.store = store
  }

  public func reload() async {
    do {
      profiles = try await store.list()
    } catch {
      errorMessage = "读取模型配置失败：\(error.localizedDescription)"
    }
  }

  @discardableResult
  public func save(
    id: UUID?,
    displayName: String,
    baseURL: String,
    modelID: String,
    apiKey: String,
    factoryConcurrency: Int? = nil,
    contextWindow: Int? = nil,
    maximumOutputTokens: Int? = nil,
    chapterToolCalling: Bool? = nil
  ) async -> ProviderProfile? {
    isWorking = true
    defer { isWorking = false }
    let existing = id.flatMap { id in profiles.first(where: { $0.id == id }) }
    let profileID = existing?.id ?? UUID()
    var capabilities = existing?.capabilities ?? .init()
    capabilities.contextWindow = contextWindow
    if let chapterToolCalling { capabilities.toolCalling = chapterToolCalling }
    let profile = ProviderProfile(
      id: profileID,
      displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
      kind: .openAICompatible,
      baseURL: URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
      modelID: modelID.trimmingCharacters(in: .whitespacesAndNewlines),
      credentialReference: existing?.credentialReference
        ?? "provider-\(profileID.uuidString.lowercased())",
      capabilities: capabilities,
      requestTimeoutInterval: existing?.requestTimeoutInterval,
      stallTimeoutInterval: existing?.stallTimeoutInterval,
      factoryConcurrency: factoryConcurrency,
      maximumOutputTokens: maximumOutputTokens
    )
    do {
      let saved = try await store.save(
        profile: profile,
        apiKey: apiKey.isEmpty ? nil : apiKey
      )
      await reload()
      return saved
    } catch {
      errorMessage = "保存模型配置失败：\(error.localizedDescription)"
      return nil
    }
  }

  public func delete(_ profileID: UUID) async {
    isWorking = true
    defer { isWorking = false }
    do {
      try await store.delete(profileID: profileID)
      await reload()
    } catch {
      errorMessage = "删除模型配置失败：\(error.localizedDescription)"
    }
  }
}

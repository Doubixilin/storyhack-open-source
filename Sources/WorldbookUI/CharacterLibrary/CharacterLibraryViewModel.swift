import CharacterLibraryCore
import Combine
import Foundation
import LLMProviderKit

@MainActor
final class CharacterLibraryViewModel: ObservableObject {
  @Published private(set) var characters: [CharacterProfile] = []
  @Published private(set) var assetsByCharacter: [UUID: [CharacterAsset]] = [:]
  @Published var searchText = ""
  @Published var selectedCategory: String?
  @Published var selectedTag: String?
  @Published var isWorking = false
  @Published var notice: String?
  @Published var errorMessage: String?

  private let store: CharacterLibraryStore
  private let providerStore: ProviderProfileStore?
  private var fileURLsByAsset: [UUID: URL] = [:]

  init(
    store: CharacterLibraryStore = CharacterLibraryStore(),
    providerStore: ProviderProfileStore? = nil
  ) {
    self.store = store
    self.providerStore = providerStore
  }

  var filteredCharacters: [CharacterProfile] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    return characters.filter { profile in
      let matchesSearch = query.isEmpty
        || profile.name.localizedCaseInsensitiveContains(query)
        || profile.summary.localizedCaseInsensitiveContains(query)
      let matchesCategory = selectedCategory == nil || profile.category == selectedCategory
      let matchesTag = selectedTag == nil || profile.tags.contains(selectedTag!)
      return matchesSearch && matchesCategory && matchesTag
    }
  }

  var allCategories: [String] {
    Array(Set(characters.compactMap(\.category))).sorted()
  }

  var allTags: [String] {
    Array(Set(characters.flatMap(\.tags))).sorted()
  }

  func reload() async {
    await perform {
      try await refreshLibrary()
    }
  }

  func createCharacter(name: String) async {
    await perform {
      _ = try await store.createCharacter(name: name)
      try await refreshLibrary()
      notice = "角色已创建。"
    }
  }

  /// 调文本模型把 lore 条目整理成角色档案草稿；失败时写 errorMessage 并返回 nil。
  /// storyworldID/entryID 作为来源身份随草稿携带（不参与模型输入），
  /// 入库时保存为 `.extracted` 来源。
  func extractDraft(
    entryTitle: String,
    entryContent: String,
    sourceTitle: String,
    storyworldID: UUID? = nil,
    entryID: String? = nil
  ) async -> CharacterExtractionDraft? {
    guard !isWorking else { return nil }
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      guard let providerStore,
        let profile = try await providerStore.list().first
      else {
        throw CharacterExtractionError.noProviderConfigured
      }
      let provider = try await providerStore.makeProvider(profileID: profile.id)
      var draft = try await CharacterExtractionService.extract(
        entryTitle: entryTitle,
        entryContent: entryContent,
        sourceTitle: sourceTitle,
        provider: provider
      )
      draft.sourceStoryworldID = storyworldID
      draft.sourceEntryID = entryID
      return draft
    } catch {
      errorMessage = ProviderErrorMessage.message(for: error)
      return nil
    }
  }

  /// 提取草稿确认后入角色库
  func importExtractedDraft(_ draft: CharacterExtractionDraft) async {
    await perform {
      let origin: CharacterOrigin =
        if let storyworldID = draft.sourceStoryworldID,
          let entryID = draft.sourceEntryID
        {
          .extracted(storyworldID: storyworldID, entryID: entryID)
        } else {
          .imported
        }
      var profile = try await store.createCharacter(
        name: draft.name,
        summary: draft.summary,
        origin: origin,
        fields: CharacterFields(
          appearance: draft.appearance,
          personality: draft.personality,
          speechStyle: draft.speechStyle,
          background: draft.background,
          abilities: draft.abilities,
          notes: draft.notes
        ),
        category: draft.category.isEmpty ? nil : draft.category,
        tags: draft.tags
      )
      if !draft.promptProfile.isEmpty {
        profile.promptProfile = draft.promptProfile
        try await store.updateProfile(profile)
      }
      try await refreshLibrary()
      notice = "已加入角色库。"
    }
  }

  func updateProfile(_ profile: CharacterProfile) async {
    await perform {
      try await store.updateProfile(profile)
      try await refreshLibrary()
      notice = "角色资料已保存。"
    }
  }

  func deleteCharacter(id: UUID) async {
    await perform {
      try await store.deleteCharacter(id: id)
      try await refreshLibrary()
      notice = "角色已删除。"
    }
  }

  func importImage(from url: URL, characterID: UUID) async {
    let hasAccess = url.startAccessingSecurityScopedResource()
    defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
    // 手动导入的图不走"批准"闸门（那是给 AI 生图留的）：导入即批准；
    // 角色还没有主形象时直接设为头像，省掉两步小字操作。
    let hadPortrait = characters.first { $0.id == characterID }?.portraitAssetID != nil
    await perform {
      let asset = try await store.importImage(from: url, characterID: characterID)
      _ = try await store.approveAsset(characterID: characterID, assetID: asset.id)
      if !hadPortrait {
        _ = try await store.setPortrait(characterID: characterID, assetID: asset.id)
      }
      try await refreshLibrary()
      notice = hadPortrait ? "图片已导入，可设为头像。" : "图片已导入并设为头像。"
    }
  }

  func approveAsset(characterID: UUID, assetID: UUID) async {
    await perform {
      _ = try await store.approveAsset(characterID: characterID, assetID: assetID)
      try await refreshLibrary()
      notice = "图片已批准。"
    }
  }

  func rejectAsset(characterID: UUID, assetID: UUID) async {
    await perform {
      _ = try await store.rejectAsset(characterID: characterID, assetID: assetID)
      try await refreshLibrary()
      notice = "图片已拒绝。"
    }
  }

  func setPortrait(characterID: UUID, assetID: UUID) async {
    await perform {
      _ = try await store.setPortrait(characterID: characterID, assetID: assetID)
      try await refreshLibrary()
      notice = "主形象已更新。"
    }
  }

  func assets(for characterID: UUID) async -> [CharacterAsset] {
    if let cached = assetsByCharacter[characterID] { return cached }
    do {
      let assets = try await store.listAssets(characterID: characterID)
      assetsByCharacter[characterID] = assets
      for asset in assets {
        fileURLsByAsset[asset.id] = await store.assetFileURL(characterID: characterID, asset: asset)
      }
      return assets
    } catch {
      errorMessage = error.localizedDescription
      return []
    }
  }

  func portraitURL(for profile: CharacterProfile) -> URL? {
    guard let portraitAssetID = profile.portraitAssetID,
          assetsByCharacter[profile.id]?.contains(where: {
            $0.id == portraitAssetID && $0.kind == .image && $0.status == .approved
          }) == true
    else { return nil }
    return fileURLsByAsset[portraitAssetID]
  }

  func fileURL(for asset: CharacterAsset) -> URL? {
    fileURLsByAsset[asset.id]
  }

  private func refreshLibrary() async throws {
    let loadedCharacters = try await store.listCharacters()
    var loadedAssets: [UUID: [CharacterAsset]] = [:]
    var loadedURLs: [UUID: URL] = [:]
    for character in loadedCharacters {
      let assets = try await store.listAssets(characterID: character.id)
      loadedAssets[character.id] = assets
      for asset in assets {
        loadedURLs[asset.id] = await store.assetFileURL(characterID: character.id, asset: asset)
      }
    }
    characters = loadedCharacters
    assetsByCharacter = loadedAssets
    fileURLsByAsset = loadedURLs
    if let selectedCategory, !allCategories.contains(selectedCategory) {
      self.selectedCategory = nil
    }
    if let selectedTag, !allTags.contains(selectedTag) {
      self.selectedTag = nil
    }
  }

  private func perform(_ operation: () async throws -> Void) async {
    guard !isWorking else { return }
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      try await operation()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

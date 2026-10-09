import Combine
import Foundation
import VisualMediaCore

@MainActor
final class VisualAssetViewModel: ObservableObject {
  @Published private(set) var bible: VisualBible
  @Published private(set) var assets: [VisualAssetRecord] = []
  @Published var styleGuide = ""
  @Published var charactersJSON = "[]"
  @Published var locationsJSON = "[]"
  @Published var prompt = ""
  @Published var visibleFacts = ""
  @Published var subjectIDs = ""
  @Published var spoilerChapter = ""
  @Published var isWorking = false
  @Published var notice: String?
  @Published var errorMessage: String?

  let storyworldID: UUID
  private let store: VisualAssetStore
  private let rootURL: URL

  init(storyworldID: UUID) {
    self.storyworldID = storyworldID
    rootURL = VisualAssetStore.defaultRootURL(storyworldID: storyworldID)
    store = VisualAssetStore(storyworldID: storyworldID)
    bible = VisualBible(storyworldID: storyworldID)
  }

  func reload() async {
    await perform {
      let bible = try await store.loadBible()
      self.bible = bible
      styleGuide = bible.styleGuide
      charactersJSON = try prettyJSON(bible.characters)
      locationsJSON = try prettyJSON(bible.locations)
      assets = try await store.loadIndex(validatingFiles: true).assets
        .sorted { $0.createdAt > $1.createdAt }
    }
  }

  func saveBible() async {
    await perform {
      let characters = try JSONDecoder().decode(
        [VisualCharacterProfile].self,
        from: Data(charactersJSON.utf8)
      )
      let locations = try JSONDecoder().decode(
        [VisualLocationProfile].self,
        from: Data(locationsJSON.utf8)
      )
      let value = VisualBible(
        storyworldID: storyworldID,
        styleGuide: styleGuide,
        characters: characters,
        locations: locations
      )
      try await store.saveBible(value)
      bible = value
      notice = "VisualBible 已保存。"
    }
  }

  func importCandidate(from url: URL) async {
    let hasAccess = url.startAccessingSecurityScopedResource()
    defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
    await perform {
      let spoiler: SpoilerBoundary
      if let ordinal = Int(spoilerChapter.trimmingCharacters(in: .whitespacesAndNewlines)) {
        spoiler = .afterChapter(ordinal)
      } else {
        spoiler = .immediate
      }
      let cue = VisualCue(
        source: VisualSource(
          kind: .storyworld,
          sourceID: storyworldID.uuidString,
          storyworldID: storyworldID
        ),
        visibleFacts: visibleFacts.split(separator: "\n").map(String.init),
        prompt: prompt.isEmpty ? "本地导入候选" : prompt
      )
      _ = try await store.registerLocalCandidate(
        from: url,
        subjectIDs: subjectIDs.split(separator: ",").map {
          $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty },
        cue: cue,
        spoilerBoundary: spoiler,
        aiGenerated: false
      )
      assets = try await store.loadIndex(validatingFiles: true).assets
        .sorted { $0.createdAt > $1.createdAt }
      notice = "图片已进入候选区，批准前不会成为正式视觉资产。"
    }
  }

  func approve(_ id: UUID) async {
    await perform {
      _ = try await store.approve(assetID: id)
      assets = try await store.loadIndex(validatingFiles: true).assets
        .sorted { $0.createdAt > $1.createdAt }
      notice = "候选已批准并移动到正式资产区。"
    }
  }

  func reject(_ id: UUID) async {
    await perform {
      _ = try await store.reject(assetID: id)
      assets = try await store.loadIndex(validatingFiles: true).assets
        .sorted { $0.createdAt > $1.createdAt }
      notice = "候选已拒绝，不会进入可见资产。"
    }
  }

  func fileURL(for asset: VisualAssetRecord) -> URL {
    rootURL.appendingPathComponent(asset.relativePath)
  }

  private func prettyJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(data: try encoder.encode(value), encoding: .utf8) ?? "[]"
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
